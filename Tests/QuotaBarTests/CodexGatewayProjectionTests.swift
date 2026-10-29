import Foundation
import XCTest
@testable import QuotaBar

final class CodexGatewayProjectionTests: XCTestCase {
    func testProjectionReturnsGatewayEventsWithoutReplacingNativeRecords() async throws {
        let fixture = try await GatewayProjectionFixture(rowCount: 4_096)
        defer { fixture.cleanup() }
        let file = try XCTUnwrap(CodexLogUsageScanner.sessionFiles(homes: [fixture.home]).first)
        let projection = CodexGatewayCacheProjection.load(persistence: fixture.native,
            identity: fixture.identity, files: [file])
        let events = try XCTUnwrap(projection.read(at: URL(fileURLWithPath: file.path)))
        XCTAssertEqual(events, fixture.events.filter { OpenCodeUsageScanner.isHostedGatewayModel($0.model) })
        let metadata = try XCTUnwrap(projection.metadata[file.path])
        let original = try XCTUnwrap(JSONLScanCacheWriter.shared.loadRecord(persistence: fixture.native,
            identity: fixture.identity, path: file.path, metadata: metadata,
            itemType: CodexLogUsageScanner.Event.self))
        XCTAssertEqual(original.items, fixture.events)
    }

    func testProductionGatewayFoldPersistsSlimRowsAndWarmRelaunchReadsNoSourceBytes() async throws {
        let fixture = try await GatewayProjectionFixture(rowCount: 4_096)
        defer { fixture.cleanup() }
        let scanner = fixture.gatewayScanner()
        let first = await fixture.fold(using: scanner)
        XCTAssertEqual(first, fixture.events.filter { OpenCodeUsageScanner.isHostedGatewayModel($0.model) })
        XCTAssertNil(CodexLogUsageScanner.incrementalReadStatisticsForTesting(path: fixture.source.path))
        await scanner.flushPendingWrites()
        let file = try XCTUnwrap(CodexLogUsageScanner.sessionFiles(homes: [fixture.home]).first)
        let projection = CodexGatewayCacheProjection.load(persistence: fixture.native,
            identity: fixture.identity, files: [file])
        let nativeMetadata = try XCTUnwrap(projection.metadata[file.path])
        try FileManager.default.removeItem(at: JSONLScanCachePaths.recordURL(
            persistence: fixture.native, identity: fixture.identity, fileName: nativeMetadata.recordFileName))
        let relaunched = fixture.gatewayScanner()
        for _ in 0..<20 {
            let warm = await fixture.fold(using: relaunched)
            XCTAssertEqual(warm, first)
        }
        XCTAssertNil(CodexLogUsageScanner.incrementalReadStatisticsForTesting(path: fixture.source.path),
                     "gateway cache must not reparse the native rollout")
        let resident = await relaunched.residentItemCountForTesting()
        XCTAssertLessThanOrEqual(resident, 16_000)
    }

    func testStaleNativeProjectionFallsBackAndSameSizeRewriteInvalidatesGatewayCache() async throws {
        let fixture = try await GatewayProjectionFixture(rowCount: 128)
        defer { fixture.cleanup() }
        let scanner = fixture.gatewayScanner()
        _ = await fixture.fold(using: scanner)
        let stamp = OpenUsageISO8601.string(from: fixture.now.addingTimeInterval(-1))
        let source = CodexLogFixture.turnContext(timestamp: stamp, model: "anthropic/opencode_go/new-model")
            + "\n" + CodexLogFixture.tokenCount(timestamp: stamp,
                last: CodexLogFixture.usage(input: 100, cached: 25, output: 50)) + "\n"
        try source.write(to: fixture.source, atomically: true, encoding: .utf8)
        let changed = await fixture.fold(using: scanner)
        XCTAssertEqual(changed.map(\.input), [100])
        XCTAssertEqual(changed.map(\.model), ["anthropic/opencode_go/new-model"])
        let before = try XCTUnwrap(CodexLogUsageScanner.incrementalReadStatisticsForTesting(path: fixture.source.path))
        let replaced = source.replacingOccurrences(of: "100", with: "200")
        XCTAssertEqual(replaced.utf8.count, source.utf8.count)
        let handle = try FileHandle(forWritingTo: fixture.source)
        try handle.write(contentsOf: Data(replaced.utf8))
        try handle.close()
        let rewritten = await fixture.fold(using: scanner)
        XCTAssertEqual(rewritten.map(\.input), [200])
        let after = try XCTUnwrap(CodexLogUsageScanner.incrementalReadStatisticsForTesting(path: fixture.source.path))
        XCTAssertGreaterThan(after.fullParses, before.fullParses)
    }
}

/// Synthetic native records in a private temp directory; reusable by the hosted production benchmark.
struct GatewayProjectionFixture: Sendable {
    let directory: URL
    let home: URL
    let source: URL
    let native: JSONLScanCachePersistence
    let gateway: JSONLScanCachePersistence
    let identity: String
    let now: Date
    let events: [CodexLogUsageScanner.Event]

    init(rowCount: Int) async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("gateway-projection-\(UUID().uuidString)")
        home = directory.appendingPathComponent("codex-home")
        let sessions = home.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        source = sessions.appendingPathComponent("rollout-synthetic.jsonl")
        let fixtureNow = Date()
        now = fixtureNow
        identity = home.resolvingSymlinksInPath().standardizedFileURL.path + "\nretention-days=35"
        native = JSONLScanCachePersistence(namespace: "codex", schemaVersion: 4, directory: directory)
        gateway = JSONLScanCachePersistence(namespace: "codex-opencode-gateway", schemaVersion: 1,
            directory: directory, writeDebounce: .milliseconds(1))
        events = (0..<rowCount).map { index in
            .init(timestamp: fixtureNow.addingTimeInterval(-Double(rowCount - index)),
                model: index % 256 == 0 ? "anthropic/opencode_go/space-bunny-free" : "gpt-5.5",
                input: 100, cached: 25, output: 50, reasoning: 0, total: 150)
        }
        var lines = ""
        for event in events {
            let stamp = OpenUsageISO8601.string(from: event.timestamp)
            lines += CodexLogFixture.turnContext(timestamp: stamp, model: event.model) + "\n"
            lines += CodexLogFixture.tokenCount(timestamp: stamp,
                last: CodexLogFixture.usage(input: 100, cached: 25, output: 50)) + "\n"
        }
        try lines.write(to: source, atomically: true, encoding: .utf8)
        let file = try XCTUnwrap(CodexLogUsageScanner.sessionFiles(homes: [home]).first)
        let metadata = JSONLScanCacheFileMetadata(size: file.size, mtime: file.mtime,
            attributeMtime: file.attributeMtime, recordFileName: JSONLScanCachePaths.recordFileName(path: file.path))
        let record = JSONLScanCacheRecord(path: file.path, size: file.size, mtime: file.mtime,
            attributeMtime: file.attributeMtime, items: events)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        _ = try await JSONLScanCacheWriter.shared.commit(.init(persistence: native, identity: identity,
            upserts: [file.path: .init(metadata: metadata, recordData: encoder.encode(record))], removals: [:]))
    }

    func gatewayScanner() -> IncrementalJSONLScanner<CodexLogUsageScanner.Event> {
        .init(maxResidentIdentities: 2, maxResidentItems: 16_000, persistence: gateway)
    }

    func fold(using scanner: IncrementalJSONLScanner<CodexLogUsageScanner.Event>) async -> [CodexLogUsageScanner.Event] {
        let box = GatewayEventBox()
        _ = await CodexLogUsageScanner().foldHostedGatewayEvents(now: now, homes: [home],
            gatewayScanner: scanner, nativeCachePersistence: native, visit: { box.append($0) })
        return box.events
    }

    func cleanup() {
        CodexLogUsageScanner.clearSharedTailCacheForTesting(path: source.path)
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class GatewayEventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CodexLogUsageScanner.Event] = []
    func append(_ event: CodexLogUsageScanner.Event) { lock.withLock { storage.append(event) } }
    var events: [CodexLogUsageScanner.Event] { lock.withLock { storage } }
}
