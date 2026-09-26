import XCTest
@testable import OpenUsage

/// The Hermes scanner against a REAL SQLite database with Hermes' schema — this is what validates the
/// actual SQL (json_* functions, date() localtime bucketing, COALESCE sums) rather than a stub's
/// idea of it.
final class HermesUsageScannerRealDBTests: XCTestCase {
    private var dbPath: String!
    private var scanner: HermesUsageScanner!

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("openusage-hermes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dbPath = dir.appendingPathComponent("state.db").path

        // Minimal faithful subset of Hermes' `sessions` + `session_model_usage` columns the scanner
        // queries. `started_at` is a REAL epoch-seconds column like Hermes writes.
        try sqlite("""
            CREATE TABLE sessions (
                id TEXT PRIMARY KEY,
                model TEXT,
                started_at REAL NOT NULL,
                input_tokens INTEGER DEFAULT 0,
                output_tokens INTEGER DEFAULT 0,
                cache_read_tokens INTEGER DEFAULT 0,
                cache_write_tokens INTEGER DEFAULT 0,
                reasoning_tokens INTEGER DEFAULT 0,
                api_call_count INTEGER DEFAULT 0,
                estimated_cost_usd REAL DEFAULT 0
            );
            CREATE TABLE session_model_usage (
                session_id TEXT NOT NULL,
                model TEXT NOT NULL,
                input_tokens INTEGER DEFAULT 0,
                output_tokens INTEGER DEFAULT 0,
                cache_read_tokens INTEGER DEFAULT 0,
                cache_write_tokens INTEGER DEFAULT 0,
                reasoning_tokens INTEGER DEFAULT 0,
                estimated_cost_usd REAL DEFAULT 0
            );
            """)
        // Local copy for the @Sendable closure — test cases are not Sendable.
        let dbPath: String = self.dbPath
        scanner = HermesUsageScanner(
            sqlite: SQLiteCLIAccessor(),
            databasePaths: { [dbPath] },
            calendar: .current
        )
    }

    func testPeriodTotalsAndDailySeries() async throws {
        let now = Date(timeIntervalSince1970: 1_784_800_000) // fixed instant
        // One recent session (inside every period) and one ancient session (outside all of them).
        try sqlite("""
            INSERT INTO sessions (id, model, started_at, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, reasoning_tokens, api_call_count, estimated_cost_usd) VALUES
              ('recent', 'kimi/kimi-k2.7', \(now.timeIntervalSince1970 - 3600), 1000, 200, 8000, 0, 50, 12, 0.42),
              ('ancient', 'glm/glm-5', \(now.timeIntervalSince1970 - 45 * 86_400), 9000, 900, 0, 0, 0, 99, 9.99);
            INSERT INTO session_model_usage (session_id, model, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, reasoning_tokens, estimated_cost_usd) VALUES
              ('recent', 'kimi/kimi-k2.7', 1000, 200, 8000, 0, 50, 0.42),
              ('recent', 'deepseek/deepseek-v4-flash', 300, 100, 0, 0, 10, 0.05);
            """)

        let scan = try await scanner.scan(now: now)
        XCTAssertNotNil(scan)

        // The ancient row is outside every period: all three periods equal the recent session only.
        let today = scan!.periods.first { $0.period == .today }!
        XCTAssertEqual(today.counts.input, 1000)
        XCTAssertEqual(today.counts.output, 200)
        XCTAssertEqual(today.counts.cacheRead, 8000)
        XCTAssertEqual(today.counts.cacheWrite, 0)
        XCTAssertEqual(today.counts.reasoning, 50)
        XCTAssertEqual(today.counts.total, 9250)
        XCTAssertEqual(today.apiCallCount, 12)
        XCTAssertEqual(today.costUSD ?? 0, 0.42, accuracy: 0.0001)

        let week = scan!.periods.first { $0.period == .thisWeek }!
        let month = scan!.periods.first { $0.period == .thisMonth }!
        XCTAssertEqual(week.counts.total, 9250)
        XCTAssertEqual(month.counts.total, 9250)
        XCTAssertEqual(today.costUSD, week.costUSD)

        // Model attribution comes from session_model_usage, ranked by tokens.
        let models = scan!.modelUsageByPeriod[.today]!
        XCTAssertEqual(models.map(\.model), ["kimi/kimi-k2.7", "deepseek/deepseek-v4-flash"])
        XCTAssertEqual(models[0].tokens, 9250)
        XCTAssertEqual(models[1].tokens, 410)

        // Daily series covers the recent day only (the ancient row is outside the 30-day window).
        XCTAssertEqual(scan!.daily.daily.count, 1)
        XCTAssertEqual(scan!.daily.daily[0].totalTokens, 9250)
    }

    func testModelFallbackToSessionsColumnWithoutAttributionTable() async throws {
        try sqlite("""
            DROP TABLE session_model_usage;
            INSERT INTO sessions (id, model, started_at, input_tokens, output_tokens) VALUES
              ('recent', 'kimi/kimi-k2.7', \(Date().timeIntervalSince1970 - 3600), 1000, 200);
            """)
        let scan = try await scanner.scan(now: Date())
        let models = scan!.modelUsageByPeriod[.today] ?? []
        XCTAssertEqual(models.map(\.model), ["kimi/kimi-k2.7"])
        XCTAssertEqual(models[0].tokens, 1200)
    }

    func testEmptyDatabaseYieldsZeroPeriodsAndNoDaily() async throws {
        let scan = try await scanner.scan(now: Date())
        XCTAssertNotNil(scan)
        XCTAssertEqual(scan!.periods.count, 3)
        XCTAssertTrue(scan!.periods.allSatisfy { $0.counts.total == 0 })
        XCTAssertTrue(scan!.daily.daily.isEmpty)
    }

    // MARK: - Fixture helper

    @discardableResult
    private func sqlite(_ sql: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [dbPath, sql]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
    }
}
