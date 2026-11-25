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

    func testAppendedRowBeyondRetentionIsNotAbsorbed() throws {
        // Large ledgers fold into the compact aggregate; its append path must apply the same
        // retention cutoff the other readers use, or an old row lands in a bucket the next
        // materialize(since:) can return for a full-history window.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.trashItem(at: directory, resultingItemURL: nil) }
        let ledger = directory.appendingPathComponent("usage-events.jsonl")
        // Pad past the 1 MB compact threshold with rows the byte-scan rejects as non-OpenCode.
        let filler = #"{"at":"2026-10-21T12:00:00Z","model":"other/model","provider":"unrelated","status":200,"inputTokens":1,"outputTokens":1,"totalTokens":2}"# + "\n"
        var contents = line
        while contents.utf8.count <= 1_048_576 { contents += filler }
        try contents.write(to: ledger, atomically: true, encoding: .utf8)

        let reader = OpenCodeRouterLedger()
        let staleDays = OpenCodeRouterLedger.retentionDays + 400
        let staleLine = #"{"at":""# + timestamp(daysAgo: staleDays)
            + #"","model":"opencode-free/test-model","provider":"opencode-free","status":200,"inputTokens":10,"outputTokens":5,"totalTokens":15}"# + "\n"
        _ = try XCTUnwrap(reader.rowsWithSourceSnapshotIfComplete(atPath: ledger.path, since: .distantPast))
        try append(Data(staleLine.utf8), to: ledger)
        try append(Data(line.utf8), to: ledger)

        let next = try XCTUnwrap(reader.rowsWithSourceSnapshotIfComplete(atPath: ledger.path, since: .distantPast))
        XCTAssertEqual(next.rows.map(\.tokens).reduce(0, +), 30,
                       "the stale append must be rejected, not folded into a retained bucket")
    }

    private func timestamp(daysAgo: Int) -> String {
        let date = Date().addingTimeInterval(-Double(daysAgo) * 86_400)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02dZ", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
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
