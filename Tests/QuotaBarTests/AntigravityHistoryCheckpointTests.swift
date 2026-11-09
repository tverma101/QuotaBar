import Foundation
import XCTest
@testable import QuotaBar

private final class CheckpointRecheckCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

final class AntigravityHistoryCheckpointTests: XCTestCase {
    func testCorruptManifestFailsClosedWithoutClaimingEmptyHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.plist")
        try Data("broken".utf8).write(to: url)
        let scanner = AntigravityDbUsageScanner(conversationsDirectories: { [] }, checkpointURL: url)
        let result = await scanner.scanWithStatus(now: Date(), pricing: TestPricing.bundled)
        XCTAssertNil(result.scan)
        XCTAssertTrue(result.hasReadFailures)
    }

    func testUnavailableStepDatedSourceInAnotherTimeZoneRemainsIncomplete() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.plist")
        let now = Date()
        let record = AntigravityHistoryCheckpoint.Record(
            path: "/missing/conversation.db", device: 1, inode: 2, revision: "r1",
            observedAt: now, windowStart: now.addingTimeInterval(-86_400), stepTimeZone: "Different/Zone",
            events: [.init(model: "gemini-3.6-flash", inputTokens: 10, outputTokens: 5, cacheReadTokens: 0,
                           timestampSeconds: Int64(now.timeIntervalSince1970))],
            undated: [], oversized: [], invalidTokens: [], malformed: []
        )
        _ = try AntigravityHistoryCheckpoint.update(at: url, records: [record],
            excluding: { _, _ in false }, valid: { _ in true })
        let scanner = AntigravityDbUsageScanner(conversationsDirectories: { [] }, checkpointURL: url)
        let result = await scanner.scan(now: now, pricing: TestPricing.bundled)
        let scan = try XCTUnwrap(result)
        XCTAssertTrue(scan.series.daily.isEmpty, "A previously ambiguous step date cannot be assigned in another zone")
        XCTAssertTrue(scan.unmeasuredUsageDays?.contains(DailyUsageAccumulator.dayKey(from: now)) == true)
    }

    func testUnavailableSourceIsRepricedWhenCatalogChanges() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.plist")
        let now = Date()
        let model = "checkpoint-test-model"
        let record = AntigravityHistoryCheckpoint.Record(
            path: "/missing/conversation.db", device: 1, inode: 2, revision: "r1", observedAt: now,
            windowStart: now.addingTimeInterval(-86_400), stepTimeZone: nil,
            events: [.init(model: model, inputTokens: 1_000, outputTokens: 1_000, cacheReadTokens: 0,
                           timestampSeconds: Int64(now.timeIntervalSince1970))],
            undated: [], oversized: [], invalidTokens: [], malformed: []
        )
        _ = try AntigravityHistoryCheckpoint.update(at: url, records: [record],
            excluding: { _, _ in false }, valid: { _ in true })
        let scanner = AntigravityDbUsageScanner(conversationsDirectories: { [] }, checkpointURL: url)
        let unknown = ModelPricing(supplement: PricingSupplement(), primary: PricingCatalog(), secondary: PricingCatalog())
        let rates = ModelRates(inputPerMillion: 1, outputPerMillion: 2, cacheWritePerMillion: 0, cacheReadPerMillion: 0)
        let priced = ModelPricing(supplement: PricingSupplement(), primary: PricingCatalog(entries: [model: rates]),
                                  secondary: PricingCatalog())
        let unpricedScan = await scanner.scan(now: now, pricing: unknown)
        XCTAssertNil(try XCTUnwrap(unpricedScan).series.daily.first?.costUSD)
        let counter = CheckpointRecheckCounter()
        let equivalent = ModelPricing(supplement: PricingSupplement(), primary: PricingCatalog(), secondary: PricingCatalog(),
                                      onOpenRouterRecheckModel: { _ in counter.increment() })
        let cachedScan = await scanner.scan(now: now, pricing: equivalent)
        XCTAssertEqual(try XCTUnwrap(cachedScan).series.daily.first?.totalTokens, 2_000)
        XCTAssertEqual(counter.value, 0, "An unchanged missing source should reuse its priced fold")
        let repricedScan = await scanner.scan(now: now, pricing: priced)
        XCTAssertEqual(try XCTUnwrap(repricedScan?.series.daily.first?.costUSD), 0.003, accuracy: 0.000_001)
    }

    func testSourceUpdatesAreIsolatedAndAnInterruptedSlotDoesNotReplaceTheManifest() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.plist")
        func record(_ inode: UInt64, revision: String, tokens: Int, at: TimeInterval = 10) -> AntigravityHistoryCheckpoint.Record {
            AntigravityHistoryCheckpoint.Record(
                path: "/source/\(inode).db", device: 1, inode: inode, revision: revision,
                observedAt: Date(timeIntervalSince1970: at), windowStart: Date(timeIntervalSince1970: 0),
                stepTimeZone: nil, events: [.init(model: "model", inputTokens: tokens, outputTokens: 0,
                                                cacheReadTokens: 0, timestampSeconds: 5)],
                undated: [], oversized: [], invalidTokens: [], malformed: []
            )
        }
        let first = record(2, revision: "r1", tokens: 10)
        let second = record(3, revision: "r1", tokens: 20)
        _ = try AntigravityHistoryCheckpoint.update(at: url, records: [first], excluding: { _, _ in false }, valid: { _ in true })
        _ = try AntigravityHistoryCheckpoint.update(at: url, records: [second], excluding: { _, _ in false }, valid: { _ in true })
        let privateFiles = [url, directory.appendingPathComponent("antigravity-1-2-0.plist"),
                            directory.appendingPathComponent("antigravity-1-3-0.plist")]
        for file in privateFiles {
            let permissions = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)
            XCTAssertEqual(permissions.intValue & 0o777, 0o600)
        }
        let manifestBefore = try Data(contentsOf: url)
        var futureManifest = try XCTUnwrap(PropertyListSerialization.propertyList(from: manifestBefore, format: nil) as? [String: Any])
        futureManifest["version"] = 2
        try PropertyListSerialization.data(fromPropertyList: futureManifest, format: .binary, options: 0).write(to: url)
        XCTAssertThrowsError(try AntigravityHistoryCheckpoint.update(at: url, records: [],
            excluding: { _, _ in false }, valid: { _ in true }))
        try manifestBefore.write(to: url)
        var revisionChecks = 0
        _ = try AntigravityHistoryCheckpoint.update(at: url, records: [first, second], excluding: { _, _ in true }, valid: { _ in
            revisionChecks += 1
            return true
        })
        XCTAssertEqual(revisionChecks, 0, "Unchanged sources must not be restatted or rewritten")
        XCTAssertEqual(try Data(contentsOf: url), manifestBefore)
        let inactive = directory.appendingPathComponent("antigravity-1-2-1.plist")
        try Data("interrupted write".utf8).write(to: inactive)
        let before = try AntigravityHistoryCheckpoint.update(at: url, records: [], excluding: { _, _ in false }, valid: { _ in true })
        XCTAssertEqual(before.map { $0.events[0].inputTokens }.sorted(), [10, 20])

        let newer = record(2, revision: "r2", tokens: 30, at: 20)
        _ = try AntigravityHistoryCheckpoint.update(at: url, records: [newer], excluding: { _, _ in false }, valid: { _ in true })
        let afterStaleWriter = try AntigravityHistoryCheckpoint.update(
            at: url, records: [first], excluding: { _, _ in false }, valid: { $0.revision != "r1" }
        )
        XCTAssertEqual(afterStaleWriter.map { $0.events[0].inputTokens }.sorted(), [20, 30])

        // A damaged retained checkpoint fails closed even while a caller has a cached fold.
        try Data("corrupt active slot".utf8).write(to: inactive)
        XCTAssertThrowsError(try AntigravityHistoryCheckpoint.update(at: url, records: [],
            excluding: { _, _ in true }, valid: { _ in true }))
        XCTAssertThrowsError(try AntigravityHistoryCheckpoint.update(at: url, records: [],
            excluding: { _, _ in false }, valid: { _ in true }))
        let repaired = try AntigravityHistoryCheckpoint.update(at: url, records: [newer],
            excluding: { _, _ in false }, valid: { _ in true })
        XCTAssertEqual(repaired.map { $0.events[0].inputTokens }.sorted(), [20, 30],
                       "A readable source repairs its damaged checkpoint without requiring a source edit")
    }

    func testConcurrentWritersKeepBothSources() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.plist")
        let records = (1...2).map { number in
            AntigravityHistoryCheckpoint.Record(
                path: "/source/\(number).db", device: 1, inode: UInt64(number), revision: "r1",
                observedAt: Date(), windowStart: Date(timeIntervalSince1970: 0), stepTimeZone: nil,
                events: [], undated: [], oversized: [], invalidTokens: [], malformed: []
            )
        }
        let errors = CheckpointRecheckCounter()
        DispatchQueue.concurrentPerform(iterations: 2) { index in
            do {
                _ = try AntigravityHistoryCheckpoint.update(at: url, records: [records[index]],
                    excluding: { _, _ in true }, valid: { _ in true })
            } catch {
                errors.increment()
            }
        }
        XCTAssertEqual(errors.value, 0)
        let loaded = try AntigravityHistoryCheckpoint.update(at: url, records: [],
            excluding: { _, _ in false }, valid: { _ in true })
        XCTAssertEqual(Set(loaded.map(\.inode)), Set([1, 2]))
    }

    func testMissingRecoverableCheckpointDoesNotBlockLiveSource() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.plist")
        let record = AntigravityHistoryCheckpoint.Record(
            path: "/source/1.db", device: 1, inode: 1, revision: "r1", observedAt: Date(),
            windowStart: Date(timeIntervalSince1970: 0), stepTimeZone: nil,
            events: [], undated: [], oversized: [], invalidTokens: [], malformed: []
        )
        _ = try AntigravityHistoryCheckpoint.update(at: url, records: [record],
            excluding: { _, _ in false }, valid: { _ in true })
        let payload = directory.appendingPathComponent("antigravity-1-1-0.plist")
        try FileManager.default.moveItem(at: payload, to: directory.appendingPathComponent("temporarily-away"))
        let result = try AntigravityHistoryCheckpoint.update(at: url, records: [record],
            excluding: { _, _ in false }, valid: { _ in true })
        XCTAssertEqual(result.map(\.inode), [1], "A readable source recreates a missing checkpoint")
        let repairedPayload = directory.appendingPathComponent("antigravity-1-1-1.plist")
        try FileManager.default.moveItem(at: repairedPayload, to: directory.appendingPathComponent("also-away"))
        XCTAssertThrowsError(try AntigravityHistoryCheckpoint.update(at: url, records: [],
            excluding: { _, _ in false }, valid: { _ in true }))
    }

    func testCancelledUpdateDoesNotPublishCheckpoint() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.plist")
        let record = AntigravityHistoryCheckpoint.Record(
            path: "/source/1.db", device: 1, inode: 1, revision: "r1", observedAt: Date(),
            windowStart: Date(timeIntervalSince1970: 0), stepTimeZone: nil,
            events: [], undated: [], oversized: [], invalidTokens: [], malformed: []
        )
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try AntigravityHistoryCheckpoint.update(at: url, records: [record],
                excluding: { _, _ in false }, valid: { _ in true })
        }
        do {
            _ = try await task.value
            XCTFail("A cancelled checkpoint update should not succeed")
        } catch is CancellationError {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testFailedBatchDoesNotPublishAnyOfItsPartialUpdates() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.plist")
        func record(_ inode: UInt64, revision: String) -> AntigravityHistoryCheckpoint.Record {
            .init(path: "/source/\(inode)", device: 1, inode: inode, revision: revision,
                  observedAt: Date(), windowStart: Date(timeIntervalSince1970: 0), stepTimeZone: nil,
                  events: [], undated: [], oversized: [], invalidTokens: [], malformed: [])
        }
        _ = try AntigravityHistoryCheckpoint.update(at: url, records: [record(1, revision: "old"), record(2, revision: "old")],
            excluding: { _, _ in false }, valid: { _ in true })
        let originalManifest = try Data(contentsOf: url)
        let brokenSecond = directory.appendingPathComponent("antigravity-1-2-0.plist")
        try Data("damaged".utf8).write(to: brokenSecond)
        XCTAssertThrowsError(try AntigravityHistoryCheckpoint.update(at: url, records: [record(1, revision: "new")],
            excluding: { _, _ in false }, valid: { _ in true }))
        XCTAssertEqual(try Data(contentsOf: url), originalManifest,
                       "A failed batch must leave the prior source manifest intact")
    }
}
