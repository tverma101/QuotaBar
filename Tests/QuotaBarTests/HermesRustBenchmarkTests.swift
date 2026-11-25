import XCTest
@testable import QuotaBar

/// Compares the Rust backend and the Swift reference scan on a synthetic Hermes database.
///
/// This is opt-in because it builds a 30,000-session corpus and runs both engines several times:
///
/// ```sh
/// QUOTABAR_HERMES_BENCH=1 swift test --filter testHermesRustVsSwiftScanBenchmark
/// ```
final class HermesRustBenchmarkTests: XCTestCase {
    func testHermesRustVsSwiftScanBenchmark() async throws {
        guard ProcessInfo.processInfo.environment["QUOTABAR_HERMES_BENCH"] == "1" else {
            throw XCTSkip("Set QUOTABAR_HERMES_BENCH=1 to run the Hermes backend benchmark.")
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("quotabar-hermes-bench-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("state.db").path
        defer { try? FileManager.default.removeItem(at: directory) }

        try createCorpus(path: path, sessions: 30_000, days: 60)
        let now = Date(timeIntervalSince1970: 1_784_800_000)

        let rust = HermesUsageScanner(databasePaths: { [path] }, engine: .rust)
        let swift = HermesUsageScanner(databasePaths: { [path] }, engine: .swift)

        // Warm both engines so process startup and SQLite page cache do not skew the comparison.
        let expectedScan = try await rust.scan(now: now)
        let oracleScan = try await swift.scan(now: now)
        let expected = try XCTUnwrap(expectedScan)
        let oracle = try XCTUnwrap(oracleScan)
        XCTAssertEqual(
            expected.daily.daily.sorted { $0.date < $1.date },
            oracle.daily.daily.sorted { $0.date < $1.date }
        )

        let iterations = 3
        var rustTimes: [Double] = []
        var swiftTimes: [Double] = []
        for _ in 0..<iterations {
            rustTimes.append(try await measure { _ = try await rust.scan(now: now) })
            swiftTimes.append(try await measure { _ = try await swift.scan(now: now) })
        }
        let rustMedian = rustTimes.sorted()[iterations / 2]
        let swiftMedian = swiftTimes.sorted()[iterations / 2]
        print(
            "HERMES_BENCH sessions=30000 rust_ms=\(String(format: "%.1f", rustMedian * 1_000)) "
                + "swift_ms=\(String(format: "%.1f", swiftMedian * 1_000)) "
                + "speedup=\(String(format: "%.2f", swiftMedian / rustMedian))x "
                + "rust_runs=\(rustTimes.map { String(format: "%.1f", $0 * 1_000) }) "
                + "swift_runs=\(swiftTimes.map { String(format: "%.1f", $0 * 1_000) })"
        )
    }

    private func measure(_ work: () async throws -> Void) async rethrows -> Double {
        let clock = ContinuousClock()
        let elapsed = try await clock.measure(work)
        return Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
    }

    private func createCorpus(path: String, sessions: Int, days: Int) throws {
        let schema = """
            PRAGMA journal_mode = OFF;
            PRAGMA synchronous = OFF;
            CREATE TABLE sessions (
                id TEXT PRIMARY KEY,
                model TEXT,
                started_at REAL NOT NULL,
                ended_at REAL DEFAULT 0,
                input_tokens INTEGER DEFAULT 0,
                output_tokens INTEGER DEFAULT 0,
                cache_read_tokens INTEGER DEFAULT 0,
                cache_write_tokens INTEGER DEFAULT 0,
                reasoning_tokens INTEGER DEFAULT 0,
                api_call_count INTEGER DEFAULT 0,
                estimated_cost_usd REAL DEFAULT 0,
                billing_provider TEXT,
                billing_base_url TEXT
            );
            """
        try runSQLite(path: path, sql: schema)

        let now = 1_784_800_000.0
        let models = ["kimi/kimi-k2.7", "claude-opus-4-6", "gpt-5.6", "glm-5", "deepseek-v4"]
        var sql = ""
        for index in 0..<sessions {
            let started = now - Double(index % days) * 86_400 - Double(index % 3_600)
            let model = models[index % models.count]
            let input = 1_000 + index % 4_000
            let output = 200 + index % 800
            let cacheRead = index % 2 == 0 ? 8_000 : 0
            let cost = Double(index % 1_000) / 1_000.0 * 0.5
            let ended = index % 500 == 0 ? "NULL" : String(format: "%.3f", started + 30)
            sql += "INSERT INTO sessions (id, model, started_at, ended_at, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, reasoning_tokens, api_call_count, estimated_cost_usd) VALUES ('s\(index)', '\(model)', \(String(format: "%.3f", started)), \(ended), \(input), \(output), \(cacheRead), 0, 50, 3, \(String(format: "%.4f", cost)));\n"
            if sql.utf8.count > 512 * 1024 {
                try runSQLite(path: path, sql: "BEGIN;\n\(sql)COMMIT;")
                sql = ""
            }
        }
        if !sql.isEmpty {
            try runSQLite(path: path, sql: "BEGIN;\n\(sql)COMMIT;")
        }
    }

    private func runSQLite(path: String, sql: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [path]
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        input.fileHandleForWriting.write(Data(sql.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "sqlite3 fixture load failed")
    }
}
