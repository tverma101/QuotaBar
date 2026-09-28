import XCTest
@testable import QuotaBar

/// Hermes sessions billed to the OpenCode hosted account never reach `opencode*.db`, so the OpenCode
/// provider folds them from Hermes' own `state.db`. These tests run against a REAL SQLite database
/// with Hermes' schema — validating the actual fold SQL (LIKE billing filters, COALESCE zero-fill,
/// json_group_array payload) rather than a stub's idea of it.
final class OpenCodeHermesGatewayTests: XCTestCase {
    private var hermesDB: String!
    private var opencodeDB: String!
    private var now: Date!

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("openusage-oc-hermes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        hermesDB = dir.appendingPathComponent("state.db").path
        opencodeDB = dir.appendingPathComponent("opencode.db").path
        // Local-anchored, not a hardcoded epoch. This fixture pairs the clock with sessions "hours
        // earlier" and asserts one of them buckets to *yesterday*, which only holds for some local
        // times of day: the fixed epoch 1_784_800_000 is 05:46 in New York (both offsets land on the
        // previous day, test passes) but 20:16 in Lord Howe, where `now - 20h` is 00:16 the *same* day
        // and the Yesterday tile vanishes. Late-evening local anchoring plus >= 24h offsets removes the
        // dependency entirely.
        now = TestLocalInstant.date(2026, 7, 23, 23)

        // Minimal faithful subset of Hermes' `sessions` columns the fold queries.
        try sqlite(hermesDB, """
            CREATE TABLE sessions (
                id TEXT PRIMARY KEY,
                model TEXT,
                started_at REAL NOT NULL,
                billing_provider TEXT,
                billing_base_url TEXT,
                input_tokens INTEGER DEFAULT 0,
                output_tokens INTEGER DEFAULT 0,
                cache_read_tokens INTEGER DEFAULT 0,
                cache_write_tokens INTEGER DEFAULT 0,
                reasoning_tokens INTEGER DEFAULT 0,
                ended_at REAL
            );
            """)
        // Minimal faithful subset of OpenCode's `message` table the main scan queries.
        try sqlite(opencodeDB, """
            CREATE TABLE message (
                time_created INTEGER,
                data TEXT
            );
            """)
    }

    func testHermesGatewaySQLSelectsOnlyOpencodeBilledSessions() async throws {
        try sqlite(hermesDB, """
            INSERT INTO sessions (id, model, started_at, billing_provider, billing_base_url, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, reasoning_tokens, ended_at) VALUES
              ('go-session',  'deepseek-v4-flash', \(now.timeIntervalSince1970 - 3600), 'opencode-go', 'https://opencode.ai/zen/go/v1', 1000, 200, 8000, 0, 0, \(now.timeIntervalSince1970 - 1800)),
              ('zen-session', 'glm-5.2',          \(now.timeIntervalSince1970 - 7200), 'opencode',    'https://opencode.ai/zen/go/v1', 300, 100, 0, 0, 50, \(now.timeIntervalSince1970 - 5400)),
              ('live-session', 'deepseek-v4-flash', \(now.timeIntervalSince1970 - 600), 'opencode-go', 'https://opencode.ai/zen/go/v1', 500, 50, 4000, 0, 10, NULL),
              ('nous-session', 'kimi-k2.7',       \(now.timeIntervalSince1970 - 3600), 'nous',        'https://inference-api.nousresearch.com/v1', 999, 999, 0, 0, 0, \(now.timeIntervalSince1970 - 1800)),
              ('nous-deepseek', 'deepseek/deepseek-v4-flash', \(now.timeIntervalSince1970 - 1800), 'nous', 'https://inference-api.nousresearch.com/v1', 1000000, 100000, 5000000, 0, 0, \(now.timeIntervalSince1970 - 900)),
              ('null-provider', 'some-model',     \(now.timeIntervalSince1970 - 3600), NULL,          NULL, 1, 1, 0, 0, 0, \(now.timeIntervalSince1970 - 1800)),
              ('null-tokens',  'm2',              \(now.timeIntervalSince1970 - 3600), 'opencode-go', 'https://opencode.ai/zen/go/v1', NULL, NULL, NULL, NULL, NULL, \(now.timeIntervalSince1970 - 1800));
            """)

        let accessor = SQLiteCLIAccessor()
        guard let json = try accessor.queryValue(path: hermesDB, sql: OpenCodeUsageScanner.hermesGatewaySQL(cutoffSeconds: 0)) else {
            return XCTFail("expected a payload")
        }
        let rows = OpenCodeUsageScanner.parseHermesGatewayRows(json)
        // opencode-go + opencode sessions only; BOTH nous sessions (incl. the big deepseek one)
        // and the NULL-provider session are excluded; NULL tokens zero-filled.
        XCTAssertEqual(rows.count, 4)
        // The Nous-portal deepseek session must never fold into OpenCode — only opencode* billing
        // counts. Its ~6.1M tokens would otherwise inflate the DeepSeek spend on this card.
        XCTAssertFalse(rows.contains { $0.model == "deepseek/deepseek-v4-flash" })
        XCTAssertEqual(rows.filter { $0.model.contains("deepseek") }.count, 2) // Go one + live one

        let go = rows.first { $0.model == "deepseek-v4-flash" && !$0.isInProgress }
        XCTAssertEqual(go?.input, 1000)
        XCTAssertEqual(go?.output, 200)
        XCTAssertEqual(go?.cacheRead, 8000)
        XCTAssertEqual(go?.cacheWrite, 0)
        XCTAssertEqual(go?.tokens, 9200)
        XCTAssertFalse(go?.isInProgress == true, "a session with ended_at set is not partial")

        let live = rows.first { $0.isInProgress }
        XCTAssertEqual(live?.model, "deepseek-v4-flash")
        XCTAssertEqual(live?.tokens, 4560) // 500 + 50 + 10 reasoning (bills at output) + 4000
        XCTAssertTrue(live?.burnsGoQuota == true)

        let zen = rows.first { $0.model == "glm-5.2" }
        XCTAssertEqual(zen?.input, 300)
        // Reasoning bills at the output rate.
        XCTAssertEqual(zen?.output, 150)
        XCTAssertEqual(zen?.tokens, 450)

        let zero = rows.first { $0.model == "m2" }
        XCTAssertEqual(zero?.tokens, 0)
        // Go-cap attribution: opencode-go billing burns the subscription's caps; the Zen gateway's
        // opencode billing is pay-as-you-go and must not.
        XCTAssertTrue(go?.burnsGoQuota == true)
        XCTAssertFalse(zen?.burnsGoQuota == true)
        XCTAssertTrue(zero?.burnsGoQuota == true)
    }

    func testHermesSessionsFoldIntoTilesWithEstimatedCost() async throws {
        try sqlite(hermesDB, """
            INSERT INTO sessions (id, model, started_at, billing_provider, billing_base_url, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, reasoning_tokens) VALUES
              ('go-session',  'deepseek-v4-flash', \(now.timeIntervalSince1970 - 3600), 'opencode-go', 'https://opencode.ai/zen/go/v1', 1000, 200, 8000, 0, 0),
              ('zen-session', 'glm-5.2',          \(now.timeIntervalSince1970 - 7200), 'opencode',    'https://opencode.ai/zen/go/v1', 300, 100, 0, 0, 50);
            """)
        let ms = Int(now.timeIntervalSince1970 * 1000)
        try sqlite(opencodeDB, """
            INSERT INTO message (time_created, data) VALUES
              (\(ms), '{"role":"assistant","providerID":"opencode-go","cost":2.0,"tokens":{"total":500},"modelID":"glm-5.2"}');
            """)

        // Local copies for the @Sendable closures — test cases are not Sendable.
        let dbPath: String = self.opencodeDB
        let hermesPath: String = self.hermesDB
        let scanner = OpenCodeUsageScanner(
            sqlite: SQLiteCLIAccessor(),
            databasePaths: { [dbPath] },
            hermesStateDBPath: { hermesPath }
        )
        let scan = try await scanner.scan(now: now, hasGoKey: true, pricing: TestPricing.bundled)
        XCTAssertNotNil(scan)
        XCTAssertTrue(scan!.includesEstimatedCost, "imputed Hermes dollars must mark the series estimated")

        var lines: [MetricLine] = []
        SpendTileMapper.appendTokenUsage(scan!.logScan.series, to: &lines, now: now, estimated: scan!.includesEstimatedCost)
        guard case let .values(_, values, _, _, _, _)? = lines.first(where: { $0.label == "Today" }) else {
            return XCTFail("expected a Today tile")
        }
        // opencode.db row (500) + Hermes opencode-billed sessions (9200 + 450).
        let tokens = values.first(where: { $0.kind == .count })?.number ?? 0
        XCTAssertEqual(tokens, 10150)
        XCTAssertTrue(values.contains(where: \.estimated), "imputed dollars must carry the ⓘ marker")
    }

    func testInProgressHermesSessionMarksDayAndTilesPartial() async throws {
        // Hermes finalizes a running session's ledger in delayed bursts, so an in-progress session
        // (ended_at NULL) means the day's fold is real but NOT final — the scan must mark the day
        // partial and the mapper must carry the ⓘ marker on the token value, never presenting the
        // live number as a settled total.
        try sqlite(hermesDB, """
            INSERT INTO sessions (id, model, started_at, billing_provider, billing_base_url, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, reasoning_tokens, ended_at) VALUES
              ('finished-yesterday', 'deepseek-v4-flash', \(now.timeIntervalSince1970 - 90_000), 'opencode-go', 'https://opencode.ai/zen/go/v1', 1000, 200, 8000, 0, 0, \(now.timeIntervalSince1970 - 86_400)),
              ('live-today',         'deepseek-v4-flash', \(now.timeIntervalSince1970 - 600), 'opencode-go', 'https://opencode.ai/zen/go/v1', 500, 50, 4000, 0, 10, NULL);
            """)
        let hermesPath: String = self.hermesDB
        let opencodePath: String = self.opencodeDB
        let scanner = OpenCodeUsageScanner(
            sqlite: SQLiteCLIAccessor(),
            databasePaths: { [opencodePath] },
            hermesStateDBPath: { hermesPath }
        )
        let scan = try await scanner.scan(now: now, hasGoKey: true, pricing: TestPricing.bundled)
        XCTAssertNotNil(scan)
        let today = DailyUsageAccumulator.dayKey(from: now)
        let yesterday = DailyUsageAccumulator.dayKey(from: now.addingTimeInterval(-86400))
        XCTAssertEqual(scan!.partialDays, [today])
        XCTAssertFalse(scan!.partialDays.contains(yesterday), "finished sessions must not mark their day partial")

        var lines: [MetricLine] = []
        SpendTileMapper.appendTokenUsage(scan!.logScan.series, to: &lines, now: now,
                                         estimated: scan!.includesEstimatedCost,
                                         partialDays: scan!.partialDays)
        guard case let .values(_, todayValues, _, _, _, _)? = lines.first(where: { $0.label == "Today" }) else {
            return XCTFail("expected a Today tile")
        }
        // Today's tokens carry the ⓘ-estimated marker because the live session is partial.
        XCTAssertTrue(todayValues.contains { $0.kind == .count && $0.estimated },
                      "partial day's token count must carry the ⓘ marker")
        guard case let .values(_, yesterdayValues, _, _, _, _)? = lines.first(where: { $0.label == "Yesterday" }) else {
            return XCTFail("expected a Yesterday tile")
        }
        XCTAssertFalse(yesterdayValues.contains { $0.kind == .count && $0.estimated },
                       "finished day's token count must stay measured (no ⓘ)")
    }

    func testHermesReadFailureWarnsInsteadOfSilentlyDroppingTheFold() async throws {
        // A WAL-locked Hermes database during a busy write burst must not silently zero the day:
        // the fold is skipped (supplementary source), but the failure is reported loudly through
        // the edge-triggered reporter instead of vanishing into `try?`.
        final class ThrowingSQLite: SQLiteAccessing, @unchecked Sendable {
            var warned: Int = 0
            func queryValue(path: String, sql: String) throws -> String? {
                if sql.contains("billing_provider") { throw SQLiteError.queryFailed("database is locked") }
                return nil
            }
            func execute(path: String, sql: String) throws {}
        }
        let stub = ThrowingSQLite()
        let warning: UsageLogReadFailureReporter.Warning = { [weak stub] count in
            stub?.warned = count
        }
        let scanner = OpenCodeUsageScanner(
            sqlite: stub,
            databasePaths: { ["/oc/opencode.db"] },
            hermesStateDBPath: { "/hermes/state.db" },
            readFailureWarning: warning
        )
        let scan = try await scanner.scan(now: now, hasGoKey: true, pricing: TestPricing.bundled)
        XCTAssertNotNil(scan, "a failed Hermes read must not fail the whole scan")
        XCTAssertTrue(scan!.partialDays.isEmpty)
        XCTAssertFalse(scan!.includesEstimatedCost)
        XCTAssertEqual(stub.warned, 1, "the Hermes read failure must warn (edge-triggered), not vanish")

        // Second scan: same persistent failure must NOT warn again (edge-triggered).
        let scan2 = try await scanner.scan(now: now, hasGoKey: true, pricing: TestPricing.bundled)
        XCTAssertNotNil(scan2)
        XCTAssertEqual(stub.warned, 1, "persistent failure warns once per run, not every refresh")
    }

    func testNoHermesDatabaseFoldsNothing() async throws {
        let ms = Int(now.timeIntervalSince1970 * 1000)
        try sqlite(opencodeDB, """
            INSERT INTO message (time_created, data) VALUES
              (\(ms), '{"role":"assistant","providerID":"opencode-go","cost":2.0,"tokens":{"total":500},"modelID":"glm-5.2"}');
            """)
        let dbPath: String = self.opencodeDB
        let scanner = OpenCodeUsageScanner(
            sqlite: SQLiteCLIAccessor(),
            databasePaths: { [dbPath] },
            hermesStateDBPath: { nil }
        )
        let scan = try await scanner.scan(now: now, pricing: TestPricing.bundled)
        XCTAssertFalse(scan!.includesEstimatedCost)
        let totalTokens = scan!.logScan.series.daily.reduce(0) { $0 + $1.totalTokens }
        XCTAssertEqual(totalTokens, 500)
    }

    // MARK: - Fixture helper

    @discardableResult
    private func sqlite(_ path: String, _ sql: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [path, sql]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
    }
}
