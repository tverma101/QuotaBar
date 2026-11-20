import XCTest
@testable import QuotaBar

/// Temporary slice benchmark used to locate the OpenCode fold's CPU; not part of the suite.
final class TempRouterBenchmark: XCTestCase {
    func testSliceTimings() throws {
        let path = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".codex/codex-router/usage-events.jsonl").path
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        print("BENCH bytes=\(data.count)")

        for pass in 0..<3 {
            OpenCodeRouterLedgerAggregate.removePersistedAggregate(path: path)
            let ledger = OpenCodeRouterLedger()
            let start = Date()
            let rows = ledger.rows(atPath: path, since: Date(timeIntervalSince1970: 0))
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            print("BENCH routerRowsCold pass\(pass) ms=\(ms) rows=\(rows.count)")
        }

        for pass in 0..<3 {
            let start = Date()
            let rows = OpenCodeRouterLedger().rows(atPath: path, since: Date(timeIntervalSince1970: 0))
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            print("BENCH routerRowsWarm pass\(pass) ms=\(ms) rows=\(rows.count)")
        }
    }
}
