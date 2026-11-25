import XCTest
@testable import QuotaBar

/// Proves the in-process Freebuff Desktop read serves the same scan and rendered metric lines as
/// the `/usr/bin/sqlite3` oracle on the store shape Desktop actually writes (threads, messages,
/// auto-run manager receipts, WAL revision cache), and that a healthy fold spawns no subprocess.
final class FreebuffRustParityTests: XCTestCase {
    private let now = OpenUsageISO8601.date(from: "2026-07-12T12:00:00.000Z")!
    private var persistenceDirectory: URL!

    override func setUp() {
        super.setUp()
        persistenceDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("freebuff-rust-parity-\(UUID().uuidString)", isDirectory: true)
        FreebuffDesktopTurnPersistence.directoryOverride = persistenceDirectory
    }

    override func tearDown() {
        FreebuffDesktopTurnPersistence.directoryOverride = nil
        if let persistenceDirectory {
            try? FileManager.default.removeItem(at: persistenceDirectory)
        }
        persistenceDirectory = nil
        super.tearDown()
    }

    private func makeStore(suffix: String = "a") throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("freebuff-rust-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.trashItem(at: directory, resultingItemURL: nil) }
        let path = directory.appendingPathComponent("desktop-v2.db").path
        let twoHoursAgo = Int(now.addingTimeInterval(-7_200).timeIntervalSince1970 * 1_000)
        let future = Int(now.addingTimeInterval(3_600).timeIntervalSince1970 * 1_000)
        try SQLiteCLIAccessor().execute(path: path, sql: """
        CREATE TABLE threads(id TEXT, model TEXT, harness_id TEXT, world_snapshot TEXT,
                             freebuff_instance_id TEXT, title TEXT, project_path TEXT);
        CREATE TABLE messages(thread_id TEXT, seq INTEGER, request_id TEXT, ts INTEGER,
                              metrics_json TEXT, role TEXT);
        CREATE TABLE auto_run_decision_receipts(id INTEGER PRIMARY KEY, thread_id TEXT,
                                                created_at INTEGER, manager_json TEXT);
        INSERT INTO threads VALUES
          ('snapshot-\(suffix)', NULL, 'codebuff',
           '{"model":"deepseek/deepseek-v4-flash","unrelated":"never projected"}',
           'inst-1', 'Fix The Parser', '/work/a'),
          ('explicit-\(suffix)', 'm-fast', 'codebuff', NULL, NULL, 'Session', '/work/b'),
          ('foreign-\(suffix)', 'm-slow', 'other-harness', NULL, NULL, 'Foreign', '/work/c');
        INSERT INTO messages VALUES
          ('snapshot-\(suffix)', 1, NULL, \(twoHoursAgo),
           '{"usage":{"inputTokens":100,"outputTokens":50,"cachedInputTokens":80}}', 'assistant'),
          ('explicit-\(suffix)', 2, 'cloud:run-\(suffix)', \(twoHoursAgo),
           '{"usage":{"inputTokens":200,"outputTokens":20,"cachedInputTokens":0,"totalTokens":220}}', 'assistant'),
          ('explicit-\(suffix)', 3, NULL, \(twoHoursAgo), '', 'assistant'),
          ('snapshot-\(suffix)', 4, NULL, \(future),
           '{"usage":{"inputTokens":1,"outputTokens":1}}', 'assistant'),
          ('snapshot-\(suffix)', 5, NULL, \(twoHoursAgo),
           '{"usage":{"inputTokens":999,"outputTokens":999}}', 'user'),
          ('foreign-\(suffix)', 1, NULL, \(twoHoursAgo),
           '{"usage":{"inputTokens":1000,"outputTokens":1000}}', 'assistant');
        INSERT INTO auto_run_decision_receipts VALUES
          (1, 'snapshot-\(suffix)', \(twoHoursAgo),
           '{"harnessId":"codebuff","model":"vendor/model-\(suffix)","startedAt":\(twoHoursAgo),\
        "usage":{"inputTokens":30,"outputTokens":10}}'),
          (2, 'explicit-\(suffix)', \(twoHoursAgo),
           '{"harnessId":"other-harness","model":"m-fast","usage":{"inputTokens":40,"outputTokens":40}}'),
          (3, 'snapshot-\(suffix)', \(twoHoursAgo),
           '{"harnessId":"codebuff","model":"m-slow","usage":null}');
        """)
        return path
    }

    private func scanner(
        paths: [String],
        engine: FreebuffDesktopDatabaseEngine,
        fallback: SQLiteAccessing = SQLiteCLIAccessor()
    ) -> FreebuffDesktopUsageScanner {
        let sqlite = engine == .rust
            ? FreebuffDesktopDatabaseAccess(engine: .rust, sqlite: fallback)
            : fallback
        return FreebuffDesktopUsageScanner(
            sqlite: sqlite, databasePaths: { paths }, sessionEndsPath: { nil }
        )
    }

    private func hostedReceipt() -> FreebuffUsageReceipt {
        FreebuffUsageReceipt(
            id: "cloud:run-a",
            timestampMs: now.addingTimeInterval(-7_200).timeIntervalSince1970 * 1_000,
            metricsJSON: #"{"usage":{"inputTokens":250,"outputTokens":20,"cachedInputTokens":0}}"#,
            model: "m-fast"
        )
    }

    private func coldOracle(
        paths: [String],
        hostedReceipts: [FreebuffUsageReceipt] = []
    ) async throws -> FreebuffDesktopUsageScanner.Scan {
        // The oracle must read SQLite: point persistence at a fresh directory so the Rust run's
        // disk record cannot satisfy it.
        FreebuffDesktopTurnPersistence.directoryOverride = persistenceDirectory
            .appendingPathComponent("oracle-\(UUID().uuidString)", isDirectory: true)
        defer { FreebuffDesktopTurnPersistence.directoryOverride = persistenceDirectory }
        let value = try await scanner(paths: paths, engine: .sqliteCLI).scan(
            now: now, pricing: TestPricing.bundled, modelCatalog: [:], hostedReceipts: hostedReceipts
        )
        return try XCTUnwrap(value)
    }

    private func spendLines(_ scan: FreebuffDesktopUsageScanner.Scan) -> [MetricLine] {
        var lines: [MetricLine] = []
        SpendTileMapper.appendTokenUsage(
            scan.usage.series,
            to: &lines,
            now: now,
            estimated: true,
            unknownModelsByDay: scan.usage.unknownModelsByDay,
            modelUsage: scan.usage.modelUsage,
            modelSourceNote: "From your Freebuff Desktop history",
            partialDays: scan.partialDays,
            apiEstimateByDay: scan.usage.apiEstimateByDay,
            estimatedCostDays: scan.usage.estimatedCostDays
        )
        SpendTileMapper.appendUsageTrend(
            scan.usage.series,
            to: &lines,
            now: now,
            note: "From your Freebuff Desktop history",
            partialDays: scan.partialDays,
            partialNote: "incomplete Freebuff history is shown as a lower bound"
        )
        return lines
    }

    /// The whole fold — measured totals, per-model rows, partial days, future-row deferral, the
    /// mission-manager receipts, the harness filter, and the hosted-receipt dedupe — must match the
    /// CLI oracle, and the rendered spend lines must match too.
    func testWholeScanAndRenderedLinesMatchSwiftOracle() async throws {
        let path = try makeStore()
        #if DEBUG
        let queriesBefore = FreebuffDesktopRustScan.completedQueriesForTesting
        #endif
        let rustValue = try await scanner(paths: [path], engine: .rust).scan(
            now: now, pricing: TestPricing.bundled, modelCatalog: [:], hostedReceipts: [hostedReceipt()]
        )
        let rust = try XCTUnwrap(rustValue)
        #if DEBUG
        XCTAssertGreaterThan(
            FreebuffDesktopRustScan.completedQueriesForTesting, queriesBefore,
            "the fold never reached sqlite.query"
        )
        #endif

        let oracle = try await coldOracle(paths: [path], hostedReceipts: [hostedReceipt()])
        XCTAssertEqual(rust.usage, oracle.usage)
        XCTAssertEqual(rust.partialDays, oracle.partialDays)
        XCTAssertEqual(spendLines(rust), spendLines(oracle))
        // Hosted cloud:run-a (250 + 20) replaces the Desktop copy (200 + 20), plus the attributed
        // assistant turn (100 + 50) and the mission-manager receipt (30 + 10).
        XCTAssertEqual(rust.usage.series.daily.reduce(0) { $0 + $1.totalTokens }, 460)
        XCTAssertEqual(rust.partialDays.count, 1, "the receipt without usage keeps its day partial")
        XCTAssertEqual(
            rust.usage.series.daily.reduce(0) { $0 + $1.totalTokens }, 460,
            "the future-dated turn (1 + 1 tokens) must not be folded in"
        )
    }

    /// Two project databases fold independently; a WAL-sidecar change invalidates the per-database
    /// cache, and the Rust engine must produce the same combined history on the cold re-read.
    func testMultipleDatabasesAndChangedRevisionMatchOracle() async throws {
        let first = try makeStore(suffix: "a")
        let second = try makeStore(suffix: "b")
        let rustScanner = scanner(paths: [first, second].sorted(), engine: .rust)
        let rustValue = try await rustScanner.scan(
            now: now, pricing: TestPricing.bundled, modelCatalog: [:], hostedReceipts: []
        )
        let rust = try XCTUnwrap(rustValue)
        let oracle = try await coldOracle(paths: [first, second].sorted())
        XCTAssertEqual(rust.usage, oracle.usage)
        XCTAssertEqual(rust.partialDays, oracle.partialDays)
        XCTAssertEqual(spendLines(rust), spendLines(oracle))
        XCTAssertEqual(rust.usage.series.daily.reduce(0) { $0 + $1.totalTokens }, 820)

        // A changed database re-reads through the same engine and still matches the oracle.
        let persisted = FreebuffDesktopTurnPersistence.directoryOverride
        FreebuffDesktopTurnPersistence.directoryOverride = persistenceDirectory
            .appendingPathComponent("changed-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { FreebuffDesktopTurnPersistence.directoryOverride = persisted }
        try SQLiteCLIAccessor().execute(path: first, sql: """
        INSERT INTO messages VALUES ('snapshot-a', 9, NULL, \(Int(now.addingTimeInterval(-3_600).timeIntervalSince1970 * 1_000)),
          '{"usage":{"inputTokens":1000,"outputTokens":0}}', 'assistant');
        """)
        let changedValue = try await scanner(paths: [first, second].sorted(), engine: .rust).scan(
            now: now, pricing: TestPricing.bundled, modelCatalog: [:], hostedReceipts: []
        )
        let changedRust = try XCTUnwrap(changedValue)
        let changedOracle = try await coldOracle(paths: [first, second].sorted())
        XCTAssertEqual(changedRust.usage, changedOracle.usage)
        XCTAssertEqual(spendLines(changedRust), spendLines(changedOracle))
    }

    func testHealthyFoldSpawnsNoSQLiteSubprocess() async throws {
        let path = try makeStore()
        let tripwire = FreebuffTripwireSQLite()
        let rustScanner = scanner(paths: [path], engine: .rust, fallback: tripwire)
        #if DEBUG
        let queriesBefore = FreebuffDesktopRustScan.completedQueriesForTesting
        #endif
        let result = try await rustScanner.scan(
            now: now, pricing: TestPricing.bundled, modelCatalog: [:], hostedReceipts: [hostedReceipt()]
        )
        #if DEBUG
        XCTAssertGreaterThan(
            FreebuffDesktopRustScan.completedQueriesForTesting, queriesBefore,
            "the healthy fold never reached the Rust engine"
        )
        #endif
        XCTAssertNotNil(result)
        XCTAssertEqual(tripwire.queryCount, 0, "the healthy Rust path must not spawn /usr/bin/sqlite3")
    }

    func testCLIEngineKeepsTheSwiftPath() async throws {
        let path = try makeStore()
        let tripwire = FreebuffCountingSQLite()
        _ = try await scanner(paths: [path], engine: .sqliteCLI, fallback: tripwire).scan(
            now: now, pricing: TestPricing.bundled, modelCatalog: [:], hostedReceipts: []
        )
        XCTAssertGreaterThan(tripwire.queryCount, 0, "the explicit CLI oracle must use the injected accessor")
    }

    /// One bad bridge response must downgrade only the statement that hit it. The next statement has
    /// to try Rust again, and a later cold scan must still reach Rust, so a transient bridge failure
    /// cannot silently restore sqlite3 spawning for the rest of the session.
    func testBridgeFailureFallsBackForOneStatementThenReturnsToRust() async throws {
        let path = try makeStore()
        let fallback = FreebuffCountingSQLite()
        let rust = FreebuffFailingRustQuery(failures: 1)
        let accessor = FreebuffDesktopDatabaseAccess(
            engine: .rust,
            sqlite: fallback,
            rustQuery: { path, sql in try rust.query(path: path, sql: sql) }
        )
        let rustScanner = FreebuffDesktopUsageScanner(
            sqlite: accessor, databasePaths: { [path] }, sessionEndsPath: { nil }
        )

        let value = try await rustScanner.scan(
            now: now, pricing: TestPricing.bundled, modelCatalog: [:], hostedReceipts: []
        )
        let scan = try XCTUnwrap(value)
        let oracle = try await coldOracle(paths: [path])
        XCTAssertEqual(scan.usage, oracle.usage)
        XCTAssertEqual(spendLines(scan), spendLines(oracle))
        XCTAssertEqual(fallback.queryCount, 1, "only the failed statement should use the CLI")
        let attemptsAfterFirstScan = rust.attemptCount
        XCTAssertEqual(attemptsAfterFirstScan, 1, "one statement per database in a fold")

        // The next statement in the same session — the active-session title query — must try Rust
        // again; the downgrade is per statement, not sticky.
        let sessions = await rustScanner.resolveLocalSessions(
            [FreebuffActiveSession(instanceID: "inst-1", expiresAt: now.addingTimeInterval(3_600))],
            now: now
        )
        XCTAssertEqual(sessions.first?.chatTitle, "Fix The Parser")
        XCTAssertGreaterThan(rust.attemptCount, attemptsAfterFirstScan, "the next statement should try Rust again")
        XCTAssertEqual(fallback.queryCount, 1, "a recovered statement must not touch the CLI")

        FreebuffDesktopTurnPersistence.directoryOverride = persistenceDirectory
            .appendingPathComponent("recovery-\(UUID().uuidString)", isDirectory: true)
        let secondScanner = FreebuffDesktopUsageScanner(
            sqlite: accessor, databasePaths: { [path] }, sessionEndsPath: { nil }
        )
        let secondValue = try await secondScanner.scan(
            now: now, pricing: TestPricing.bundled, modelCatalog: [:], hostedReceipts: []
        )
        let second = try XCTUnwrap(secondValue)
        XCTAssertEqual(second.usage, oracle.usage)
        XCTAssertEqual(fallback.queryCount, 1, "the next scan must not reuse the failed statement's CLI fallback")
    }

    func testRustEngineRefusesExecuteWithoutSpawningTheCLI() {
        let fallback = FreebuffCountingSQLite()
        let accessor = FreebuffDesktopDatabaseAccess(engine: .rust, sqlite: fallback)

        XCTAssertThrowsError(
            try accessor.execute(path: "/tmp/quotabar-freebuff-execute.db", sql: "CREATE TABLE t(v);")
        ) { error in
            XCTAssertTrue(error is SQLiteError)
        }
        XCTAssertEqual(fallback.executeCount, 0)
    }

    /// The active-session title query is the second statement the scanner issues. It must use the
    /// same engine policy, so a healthy title lookup spawns nothing either.
    func testSessionTitleLookupUsesTheRustEngine() async throws {
        let path = try makeStore()
        let tripwire = FreebuffTripwireSQLite()
        let scanner = scanner(paths: [path], engine: .rust, fallback: tripwire)
        #if DEBUG
        let queriesBefore = FreebuffDesktopRustScan.completedQueriesForTesting
        #endif
        let sessions = await scanner.resolveLocalSessions(
            [FreebuffActiveSession(instanceID: "inst-1", expiresAt: now.addingTimeInterval(3_600))],
            now: now
        )
        #if DEBUG
        XCTAssertGreaterThan(
            FreebuffDesktopRustScan.completedQueriesForTesting, queriesBefore,
            "the title lookup never reached the Rust engine"
        )
        #endif
        XCTAssertEqual(sessions.first?.chatTitle, "Fix The Parser")
        XCTAssertEqual(tripwire.queryCount, 0)
    }
}

private final class FreebuffTripwireSQLite: SQLiteAccessing, @unchecked Sendable {
    private let lock = NSLock()
    private var queries = 0

    var queryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return queries
    }

    func queryValue(path: String, sql: String) throws -> String? {
        lock.lock()
        queries += 1
        lock.unlock()
        throw SQLiteError.queryFailed("subprocess tripwire: \(path)")
    }

    func execute(path: String, sql: String) throws {
        lock.lock()
        queries += 1
        lock.unlock()
        throw SQLiteError.queryFailed("subprocess tripwire: \(path)")
    }
}

private final class FreebuffCountingSQLite: SQLiteAccessing, @unchecked Sendable {
    private let lock = NSLock()
    private let inner = SQLiteCLIAccessor()
    private var queries = 0
    private var executes = 0

    var queryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return queries
    }

    var executeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return executes
    }

    func queryValue(path: String, sql: String) throws -> String? {
        lock.lock()
        queries += 1
        lock.unlock()
        return try inner.queryValue(path: path, sql: sql)
    }

    func execute(path: String, sql: String) throws {
        lock.lock()
        executes += 1
        lock.unlock()
        try inner.execute(path: path, sql: sql)
    }
}

private final class FreebuffFailingRustQuery: @unchecked Sendable {
    private let lock = NSLock()
    private var remainingFailures: Int
    private var calls = 0

    init(failures: Int) {
        remainingFailures = failures
    }

    var attemptCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func query(path: String, sql: String) throws -> String? {
        lock.lock()
        calls += 1
        let fails = remainingFailures > 0
        if fails { remainingFailures -= 1 }
        lock.unlock()
        if fails {
            throw RustBackend.BackendError(kind: "internal", message: "injected bridge failure")
        }
        return try FreebuffDesktopRustScan.queryValue(path: path, sql: sql)
    }
}
