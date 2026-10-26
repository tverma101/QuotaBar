import XCTest
@testable import QuotaBar

final class OpenCodeRouterAppendValidationTests: XCTestCase {
    private let line = #"{"at":"2026-10-21T12:00:00Z","model":"opencode-free/test-model","provider":"opencode-free","status":200,"inputTokens":10,"outputTokens":5,"totalTokens":15}"# + "\n"

    func testOrdinaryAppendKeepsVerifiedPrefixUsableWithoutReparsing() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.trashItem(at: fixture.directory, resultingItemURL: nil) }
        let reader = OpenCodeRouterLedger()
        let initial = try XCTUnwrap(reader.rowsWithSourceSnapshotIfComplete(atPath: fixture.ledger.path, since: .distantPast))
        let bytes = reader.statistics(path: fixture.ledger.path)?.bytesRead
        try append(Data(line.utf8), to: fixture.ledger)

        XCTAssertTrue(OpenCodeRouterLedger.sourceSnapshotIsCurrent(initial.source, atPath: fixture.ledger.path))
        XCTAssertEqual(reader.statistics(path: fixture.ledger.path)?.bytesRead, bytes, "validation reads only the bounded prefix anchor")
        let next = try XCTUnwrap(reader.rowsWithSourceSnapshotIfComplete(atPath: fixture.ledger.path, since: .distantPast))
        XCTAssertEqual(initial.rows.map(\.tokens).reduce(0, +), 15)
        XCTAssertEqual(next.rows.map(\.tokens).reduce(0, +), 30)
    }

    func testRewriteTruncationAndReplacementStillRejectSnapshots() throws {
        for mutation in ["rewrite", "truncate", "replace"] {
            let fixture = try fixture()
            defer { try? FileManager.default.trashItem(at: fixture.directory, resultingItemURL: nil) }
            let source = try XCTUnwrap(OpenCodeRouterLedger().rowsWithSourceSnapshotIfComplete(
                atPath: fixture.ledger.path, since: .distantPast
            )?.source)
            switch mutation {
            case "rewrite":
                let handle = try FileHandle(forWritingTo: fixture.ledger)
                defer { try? handle.close() }
                try handle.write(contentsOf: Data(line.replacingOccurrences(of: "12:00", with: "13:00").utf8))
            case "truncate":
                let handle = try FileHandle(forWritingTo: fixture.ledger)
                defer { try? handle.close() }
                try handle.truncate(atOffset: 0)
            default:
                try line.write(to: fixture.ledger, atomically: true, encoding: .utf8)
            }
            XCTAssertFalse(OpenCodeRouterLedger.sourceSnapshotIsCurrent(source, atPath: fixture.ledger.path), mutation)
        }
    }

    func testAppendDuringGatewayFoldPublishesPrefixAndConsumesTailNextPass() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.trashItem(at: fixture.directory, resultingItemURL: nil) }
        let data = Data(line.utf8)
        let ledger = fixture.ledger
        let now = OpenUsageISO8601.date(from: "2026-10-21T16:00:00Z")!
        let scanner = OpenCodeUsageScanner(databasePaths: { [] }, codexHomes: {
            // Discovery runs after Router rows are captured and before final source validation.
            let handle = try! FileHandle(forWritingTo: ledger)
            defer { try? handle.close() }
            _ = try! handle.seekToEnd()
            try! handle.write(contentsOf: data)
            return []
        }, routerLedgerPaths: { [ledger.path] })
        let first = try await scanner.scan(now: now, gatewaySources: [.codex])
        XCTAssertEqual(first?.logScan.series.daily.first?.totalTokens, 15)
        let next = try await OpenCodeUsageScanner(databasePaths: { [] }, routerLedgerPaths: { [ledger.path] })
            .scan(now: now, gatewaySources: [.codex])
        XCTAssertEqual(next?.logScan.series.daily.first?.totalTokens, 30)
    }

    private func fixture() throws -> (directory: URL, ledger: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ledger = directory.appendingPathComponent("usage-events.jsonl")
        try line.write(to: ledger, atomically: true, encoding: .utf8)
        return (directory, ledger)
    }

    private func append(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}
