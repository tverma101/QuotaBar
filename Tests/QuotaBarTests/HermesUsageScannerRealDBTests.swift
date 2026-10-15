import XCTest
@testable import QuotaBar

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
                estimated_cost_usd REAL DEFAULT 0,
                billing_provider TEXT,
                billing_base_url TEXT
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

        // The daily series keeps the ten-year lifetime window (the same retention the other local
        // scanners use), so the 45-day-old session still owns its own day instead of being dropped.
        XCTAssertEqual(scan!.daily.daily.map(\.totalTokens).sorted(), [9250, 9900])
    }

    func testOpenCodeBilledSessionsBelongToOpenCodeSpendOnly() async throws {
        let now = Date()
        let started = now.timeIntervalSince1970 - 60
        try sqlite("""
            INSERT INTO sessions (id, model, started_at, input_tokens, output_tokens, estimated_cost_usd, billing_provider, billing_base_url) VALUES
              ('direct', 'claude-sonnet-5', \(started), 100, 20, 0.25, 'anthropic', 'https://api.anthropic.com'),
              ('gateway', 'deepseek-v4-flash', \(started), 500, 60, 0.75, 'opencode-go', 'https://opencode.ai/zen/go/v1');
            INSERT INTO session_model_usage (session_id, model, input_tokens, output_tokens, estimated_cost_usd) VALUES
              ('direct', 'claude-sonnet-5', 100, 20, 0.25),
              ('gateway', 'deepseek-v4-flash', 500, 60, 0.75);
            """)

        let maybeScan = try await scanner.scan(now: now)
        let scan = try XCTUnwrap(maybeScan)
        let today = try XCTUnwrap(scan.periods.first { $0.period == .today })
        XCTAssertEqual(today.counts.total, 120)
        XCTAssertEqual(today.costUSD ?? 0, 0.25, accuracy: 0.0001)
        XCTAssertEqual(scan.modelUsageByPeriod[.today]?.map(\.model), ["claude-sonnet-5"])
        XCTAssertEqual(scan.daily.daily.reduce(0) { $0 + $1.totalTokens }, 120)
    }

    func testNullSessionCostMakesPeriodModelAndDailyTotalsIncomplete() async throws {
        let now = Date()
        let started = now.timeIntervalSince1970 - 60
        try sqlite("""
            INSERT INTO sessions (id, model, started_at, input_tokens, output_tokens, estimated_cost_usd) VALUES
              ('priced', 'priced-model', \(started), 100, 20, 0.25),
              ('missing-cost', 'missing-cost-model', \(started + 1), 300, 30, NULL);
            INSERT INTO session_model_usage (session_id, model, input_tokens, output_tokens, estimated_cost_usd) VALUES
              ('priced', 'priced-model', 100, 20, 0.25),
              ('missing-cost', 'missing-cost-model', 300, 30, NULL);
            """)

        let maybeScan = try await scanner.scan(now: now)
        let scan = try XCTUnwrap(maybeScan)
        let today = try XCTUnwrap(scan.periods.first { $0.period == .today })
        XCTAssertEqual(today.counts.total, 450)
        XCTAssertNil(today.costUSD, "a positive subtotal must not hide a token row without a cost")

        let models = try XCTUnwrap(scan.modelUsageByPeriod[.today])
        XCTAssertEqual(models.first { $0.model == "priced-model" }?.costUSD ?? 0, 0.25, accuracy: 0.0001)
        XCTAssertNil(models.first { $0.model == "missing-cost-model" }?.costUSD)

        let day = try XCTUnwrap(scan.daily.daily.first)
        XCTAssertEqual(day.totalTokens, 450)
        XCTAssertNil(day.costUSD)
        XCTAssertFalse(day.costIsComplete)
    }

    func testCostOnlySessionRemainsInDailyHistory() async throws {
        let now = Date()
        try sqlite("""
            INSERT INTO sessions (id, model, started_at, input_tokens, output_tokens, estimated_cost_usd) VALUES
              ('cost-only', 'unattributed', \(now.timeIntervalSince1970 - 60), 0, 0, 0.25);
            """)

        let scanned = try await scanner.scan(now: now)
        let scan = try XCTUnwrap(scanned)
        let today = try XCTUnwrap(scan.periods.first { $0.period == .today })
        XCTAssertEqual(today.counts.total, 0)
        XCTAssertEqual(today.costUSD ?? 0, 0.25, accuracy: 0.0001)

        let day = try XCTUnwrap(scan.daily.daily.first)
        XCTAssertEqual(day.totalTokens, 0)
        XCTAssertEqual(day.costUSD ?? 0, 0.25, accuracy: 0.0001)
        XCTAssertTrue(day.costIsComplete)
    }

    func testHermesTokenDaysMarkPublicAPIRateEstimateIncomplete() {
        let now = Date()
        let today = DailyUsageAccumulator.dayKey(from: now, calendar: .current)
        let yesterday = DailyUsageAccumulator.dayKey(
            from: Calendar.current.date(byAdding: .day, value: -1, to: now)!,
            calendar: .current
        )
        let scan = HermesUsageScan(
            periods: [],
            daily: DailyUsageSeries(daily: [
                DailyUsageEntry(date: today, totalTokens: 120, costUSD: 0.5),
                DailyUsageEntry(date: yesterday, totalTokens: 0, costUSD: nil)
            ]),
            modelUsageByPeriod: [:]
        )

        let history = HermesProvider.usageHistory(from: scan)

        XCTAssertNil(history.apiEstimateByDay)
        XCTAssertEqual(history.apiEstimateIncompleteDays, [today])

        let otherProviderHistory = ProviderUsageHistory(
            series: DailyUsageSeries(daily: [DailyUsageEntry(date: today, totalTokens: 80, costUSD: 0.2)]),
            apiEstimateByDay: [today: 1.25]
        )
        let report = HistoryDashboardAggregator.report(
            .init(
                enabledProviderIDs: ["hermes", "other"],
                displayNameByProviderID: ["hermes": "Hermes", "other": "Other"],
                historyByProviderID: ["hermes": history, "other": otherProviderHistory]
            ),
            now: now
        )
        XCTAssertNil(report.apiEstimateTotal, "an estimate from other providers must not imply full coverage")
    }

    func testModelFallbackToSessionsColumnWithoutAttributionTable() async throws {
        // One `now`, used for both the fixture row and the scan.
        //
        // This used to write `Date() - 3600` and scan at a separately-sampled `Date()`, which made the
        // test depend on the wall clock: the scanner buckets by *local calendar day*, so a row written
        // one hour before midnight belongs to the previous day and `.today` comes back empty. That never
        // failed locally (this machine is UTC-4, so "one hour ago" stays in the same day except for a
        // one-hour window around 23:00) but failed on every UTC GitHub runner whose run started just
        // after midnight — which is exactly what happened, at 00:42 UTC. Deriving both ends from a single
        // instant removes the dependency entirely, and the row is then always inside the day being
        // scanned.
        let now = Date()
        try sqlite("""
            DROP TABLE session_model_usage;
            INSERT INTO sessions (id, model, started_at, input_tokens, output_tokens) VALUES
              ('recent', 'kimi/kimi-k2.7', \(now.timeIntervalSince1970 - 60), 1000, 200);
            """)
        let scan = try await scanner.scan(now: now)
        let models = scan!.modelUsageByPeriod[.today] ?? []
        XCTAssertEqual(models.map(\.model), ["kimi/kimi-k2.7"])
        // Guarded: an unguarded `models[0]` raised `Index out of range`, which traps and takes down the
        // whole xctest process — so a single fragile assertion discarded the result of all 1462 tests
        // instead of reporting one failure.
        let first = try XCTUnwrap(models.first, "expected one model row for today, got \(models)")
        XCTAssertEqual(first.tokens, 1200)
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
