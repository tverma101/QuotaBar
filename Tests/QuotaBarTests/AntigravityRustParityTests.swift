import XCTest
@testable import QuotaBar

/// Proves the in-process Antigravity query engine serves the same scan and rendered metric lines as
/// the `/usr/bin/sqlite3` oracle, and that a healthy provider refresh spawns no subprocess.
final class AntigravityRustParityTests: XCTestCase {
    private let now = OpenUsageISO8601.date(from: "2026-07-12T12:00:00.000Z")!
    private var persistenceDirectory: URL!

    override func setUp() {
        super.setUp()
        persistenceDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("antigravity-rust-parity-\(UUID().uuidString)", isDirectory: true)
        AntigravityAggregatePersistence.directoryOverride = persistenceDirectory
    }

    override func tearDown() {
        AntigravityAggregatePersistence.directoryOverride = nil
        if let persistenceDirectory {
            try? FileManager.default.removeItem(at: persistenceDirectory)
        }
        persistenceDirectory = nil
        super.tearDown()
    }

    private func antigravityVarint(_ value: UInt64) -> [UInt8] {
        var remaining = value
        var encoded: [UInt8] = []
        repeat {
            var byte = UInt8(remaining & 0x7f)
            remaining >>= 7
            if remaining != 0 { byte |= 0x80 }
            encoded.append(byte)
        } while remaining != 0
        return encoded
    }

    private func antigravityVarintField(_ number: UInt32, _ value: UInt64) -> [UInt8] {
        antigravityVarint(UInt64(number) << 3) + antigravityVarint(value)
    }

    private func antigravityBytesField(_ number: UInt32, _ bytes: [UInt8]) -> [UInt8] {
        antigravityVarint(UInt64(number) << 3 | 2) + antigravityVarint(UInt64(bytes.count)) + bytes
    }

    private func generationBlob(
        model: String?,
        input: UInt64,
        output: UInt64,
        timestamp: UInt64?,
        stepUUID: String? = "turn-1",
        botID: String? = "bot-1"
    ) -> [UInt8] {
        var usage = antigravityVarintField(1, 0)
            + antigravityVarintField(2, input)
            + antigravityVarintField(3, output)
        if let botID { usage += antigravityBytesField(7, Array(botID.utf8)) }
        var event: [UInt8] = []
        if let model { event += antigravityBytesField(19, Array(model.utf8)) }
        event += antigravityBytesField(4, usage)
        if let timestamp {
            let wallClock = antigravityVarintField(1, timestamp)
            event += antigravityBytesField(9, antigravityBytesField(4, wallClock))
        }
        var generation = antigravityBytesField(1, event)
        if let stepUUID { generation += antigravityBytesField(4, Array(stepUUID.utf8)) }
        return generation
    }

    private func stepMetadata(timestamp: UInt64, stepUUID: String?, botID: String?) -> [UInt8] {
        var metadata = antigravityBytesField(1, antigravityVarintField(1, timestamp))
        if let botID { metadata += antigravityBytesField(9, antigravityBytesField(7, Array(botID.utf8))) }
        if let stepUUID { metadata += antigravityBytesField(12, Array(stepUUID.utf8)) }
        return metadata
    }

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func makeDatabase(
        rows: [(index: Int, blob: [UInt8])],
        steps: [(index: Int, metadata: [UInt8])] = []
    ) throws -> (directory: String, path: String) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("antigravity-rust-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.trashItem(at: directory, resultingItemURL: nil) }
        let path = directory.appendingPathComponent("conversation.db").path
        var sql = "CREATE TABLE gen_metadata(idx INTEGER PRIMARY KEY, data BLOB);"
        if !steps.isEmpty {
            sql += "CREATE TABLE steps(idx INTEGER PRIMARY KEY, metadata BLOB);"
        }
        for row in rows {
            sql += "INSERT INTO gen_metadata VALUES(\(row.index), x'\(hex(row.blob))');"
        }
        for step in steps {
            sql += "INSERT INTO steps VALUES(\(step.index), x'\(hex(step.metadata))');"
        }
        try SQLiteCLIAccessor().execute(path: path, sql: sql)
        return (directory.path, path)
    }

    private func scanner(
        directory: String,
        engine: AntigravityDatabaseEngine,
        fallback: SQLiteAccessing = SQLiteCLIAccessor(allowsReadWriteFallback: false)
    ) -> AntigravityDbUsageScanner {
        let sqlite = engine == .rust
            ? AntigravityDatabaseAccess(engine: .rust, sqlite: fallback)
            : fallback
        return AntigravityDbUsageScanner(
            sqlite: sqlite,
            conversationsDirectory: { directory }
        )
    }

    private func fixture() throws -> String {
        let past = UInt64(now.addingTimeInterval(-3_600 * 24).timeIntervalSince1970)
        let dayAgo = UInt64(now.addingTimeInterval(-86_400).timeIntervalSince1970)
        let step = stepMetadata(timestamp: past, stepUUID: "turn-1", botID: "bot-1")
        let (directory, _) = try makeDatabase(
            rows: [
                (0, generationBlob(model: "gemini-3.6-flash", input: 1_000, output: 500, timestamp: past)),
                (1, generationBlob(model: "unknown-antigravity-model", input: 300, output: 100, timestamp: dayAgo)),
                (2, generationBlob(model: "gemini-3.6-flash", input: 50, output: 25, timestamp: nil, stepUUID: "turn-1"))
            ],
            steps: [(1, step)]
        )
        return directory
    }

    private func spendLines(_ scan: LogUsageScan) -> [MetricLine] {
        var lines: [MetricLine] = []
        SpendTileMapper.appendTokenUsage(
            scan.series,
            to: &lines,
            now: now,
            unknownModelsByDay: scan.unknownModelsByDay,
            modelUsage: scan.modelUsage,
            modelSourceNote: "From your Antigravity conversations",
            partialDays: scan.unmeasuredUsageDays ?? [],
            apiEstimateByDay: scan.apiEstimateByDay
        )
        SpendTileMapper.appendUsageTrend(
            scan.series,
            to: &lines,
            now: now,
            note: "From your Antigravity conversations",
            partialDays: scan.unmeasuredUsageDays ?? [],
            partialNote: "incomplete Antigravity history is shown as a lower bound"
        )
        return lines
    }

    func testWholeScanAndRenderedLinesMatchSwiftOracle() async throws {
        let directory = try fixture()
        #if DEBUG
        let queriesBefore = AntigravityRustScan.completedQueriesForTesting
        #endif
        let rustValue = await scanner(directory: directory, engine: .rust)
            .scan(now: now, pricing: TestPricing.bundled)
        let rust = try XCTUnwrap(rustValue)
        #if DEBUG
        XCTAssertGreaterThan(
            AntigravityRustScan.completedQueriesForTesting, queriesBefore,
            "the scan never reached sqlite.query"
        )
        #endif
        let oracleValue = await scanner(directory: directory, engine: .sqliteCLI)
            .scan(now: now, pricing: TestPricing.bundled)
        let oracle = try XCTUnwrap(oracleValue)

        XCTAssertEqual(rust, oracle)
        XCTAssertEqual(spendLines(rust), spendLines(oracle))
        XCTAssertEqual(rust.series.daily.reduce(0) { $0 + $1.totalTokens }, 1_975)
        XCTAssertEqual(rust.unmeasuredUsageDays ?? [], oracle.unmeasuredUsageDays ?? [])
    }

    func testMalformedAndFutureRowsMatchSwiftOracle() async throws {
        let future = UInt64(now.addingTimeInterval(3_600).timeIntervalSince1970)
        let (directory, _) = try makeDatabase(
            rows: [
                (3, generationBlob(model: "gemini-3.6-flash", input: 1_000, output: 500, timestamp: future)),
                (4, [0x08, 0x01]),
                (5, generationBlob(model: "gemini-3.6-flash", input: 1, output: 1, timestamp: nil))
            ]
        )
        #if DEBUG
        let queriesBefore = AntigravityRustScan.completedQueriesForTesting
        #endif
        let rustValue = await scanner(directory: directory, engine: .rust)
            .scan(now: now, pricing: TestPricing.bundled)
        #if DEBUG
        XCTAssertGreaterThan(
            AntigravityRustScan.completedQueriesForTesting, queriesBefore,
            "the malformed/future fixture never reached sqlite.query"
        )
        #endif
        let oracleValue = await scanner(directory: directory, engine: .sqliteCLI)
            .scan(now: now, pricing: TestPricing.bundled)
        let rust = try XCTUnwrap(rustValue)
        let oracle = try XCTUnwrap(oracleValue)
        XCTAssertEqual(rust, oracle)
        XCTAssertEqual(rust.unmeasuredUsageDays ?? [], oracle.unmeasuredUsageDays ?? [])
        XCTAssertEqual(spendLines(rust), spendLines(oracle))
    }

    func testHealthyRefreshSpawnsNoSQLiteSubprocess() async throws {
        let directory = try fixture()
        let tripwire = AntigravityTripwireSQLite()
        let rustScanner = scanner(directory: directory, engine: .rust, fallback: tripwire)
        #if DEBUG
        let queriesBefore = AntigravityRustScan.completedQueriesForTesting
        #endif
        let result = await rustScanner.scanWithStatus(
            now: now, pricing: TestPricing.bundled
        )
        #if DEBUG
        XCTAssertGreaterThan(
            AntigravityRustScan.completedQueriesForTesting, queriesBefore,
            "the refresh never reached the Rust engine"
        )
        #endif
        XCTAssertNotNil(result.scan)
        XCTAssertEqual(tripwire.queryCount, 0, "the healthy Rust path must not spawn /usr/bin/sqlite3")
    }

    /// Cache fingerprints are SHA3 digests computed inside SQLite. If the in-process engine's
    /// digests differed from `/usr/bin/sqlite3`'s by one byte, a cache written by one engine could
    /// keep stale rows after a rewrite. Pin both functions over adversarial values and the
    /// composite, ordered shape Antigravity actually hashes.
    func testSHA3MatchesSQLiteCLIOverAdversarialInputs() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("antigravity-sha3-parity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.trashItem(at: directory, resultingItemURL: nil) }
        let path = directory.appendingPathComponent("digest.db").path
        let seed = """
        CREATE TABLE digest_values(id INTEGER PRIMARY KEY, text_value TEXT, blob_value BLOB, int_value INTEGER, real_value REAL);
        INSERT INTO digest_values VALUES
            (1, '', x'', 0, 0.0),
            (2, 'abc', x'68656C6C6F', 1, 2.0),
            (3, printf('%.*c', 134, 'A'), zeroblob(134), -7, 1.5),
            (4, printf('%.*c', 135, 'A'), zeroblob(135), 9007199254740993, 100.015625),
            (5, printf('%.*c', 136, 'A'), zeroblob(136), 9223372036854775807, NULL),
            (6, printf('%.*c', 137, 'A'), zeroblob(137), NULL, NULL),
            (7, 'héllo — 漢字', x'00FF8000', -9223372036854775808, NULL),
            (8, 'a' || char(0) || 'b', x'', NULL, NULL),
            (9, 'quote''s \\ slash' || char(10) || 'next', NULL, 0, NULL),
            (10, NULL, NULL, NULL, NULL);
        """
        try SQLiteCLIAccessor().execute(path: path, sql: seed)
        let cli = SQLiteCLIAccessor(allowsReadWriteFallback: false)
        let statements = [
            "SELECT COALESCE(group_concat(COALESCE(hex(sha3(blob_value)), 'null'), ','), '') FROM (SELECT blob_value FROM digest_values ORDER BY id);",
            "SELECT COALESCE(group_concat(COALESCE(hex(sha3(text_value)), 'null'), ','), '') FROM (SELECT text_value FROM digest_values ORDER BY id);",
            "SELECT COALESCE(group_concat(hex(sha3(int_value)), ','), '') FROM (SELECT int_value FROM digest_values WHERE int_value IS NOT NULL ORDER BY id);",
            "SELECT hex(sha3(text_value, 224)) || '|' || hex(sha3(text_value, 384)) || '|' || hex(sha3(text_value, 512)) FROM digest_values WHERE id = 7;",
            "SELECT hex(sha3_agg(text_value)) FROM (SELECT text_value FROM digest_values ORDER BY id);",
            "SELECT hex(sha3_agg(blob_value)) FROM (SELECT blob_value FROM digest_values ORDER BY id);",
            "SELECT hex(sha3_agg(int_value)) FROM (SELECT int_value FROM digest_values ORDER BY id);",
            "SELECT hex(sha3_agg(real_value)) FROM (SELECT real_value FROM digest_values ORDER BY id);",
            "SELECT COALESCE(hex(sha3_agg(printf('%d:%d:%s;', id, length(blob_value), COALESCE(hex(sha3(blob_value, 256)), 'null')) ORDER BY id)), '') FROM digest_values;",
            "SELECT hex(sha3_agg(text_value)) FROM (SELECT text_value FROM digest_values WHERE 0);"
        ]

        #if DEBUG
        let queriesBefore = AntigravityRustScan.completedQueriesForTesting
        #endif
        for sql in statements {
            let oracle = try cli.queryValue(path: path, sql: sql)
            let inProcess = try AntigravityRustScan.queryValue(path: path, sql: sql)
            XCTAssertEqual(inProcess, oracle, sql)
        }
        #if DEBUG
        XCTAssertEqual(
            AntigravityRustScan.completedQueriesForTesting, queriesBefore + statements.count,
            "the digest comparison never reached sqlite.query"
        )
        #endif
        // An aggregate over zero rows is NULL on both engines, not the digest of nothing.
        XCTAssertNil(try cli.queryValue(path: path, sql: statements[9]))
    }

    /// A changed database must take the digest path on the in-process engine: every digest the
    /// scanner asks for is answered by Rust, the refresh spawns no subprocess, and the whole scan
    /// still matches the CLI oracle.
    func testChangedModernDatabaseUsesInProcessDigestsAndMatchesOracle() async throws {
        let past = UInt64(now.addingTimeInterval(-3_600 * 24).timeIntervalSince1970)
        let rows = (0..<300).map { row in
            (
                index: row,
                blob: generationBlob(
                    model: "gemini-3.6-flash", input: 10, output: 5,
                    timestamp: nil, stepUUID: "turn-\(row)"
                )
            )
        }
        let steps = (0..<300).map { row in
            (
                index: row,
                metadata: stepMetadata(
                    timestamp: past - UInt64(row % 5) * 86_400,
                    stepUUID: "turn-\(row)", botID: "bot-1"
                )
            )
        }
        let (directory, path) = try makeDatabase(rows: rows, steps: steps)

        let tripwire = AntigravityTripwireSQLite()
        let spy = AntigravityRecordingSQLite(
            inner: AntigravityDatabaseAccess(engine: .rust, sqlite: tripwire)
        )
        let firstScan = await AntigravityDbUsageScanner(sqlite: spy, conversationsDirectory: { directory })
            .scan(now: now, pricing: TestPricing.bundled)
        let first = try XCTUnwrap(firstScan)
        XCTAssertFalse(first.series.daily.isEmpty)

        // Append to both tables so the cached prefix has to be re-validated by digest.
        let appendedTimestamp = UInt64(now.addingTimeInterval(-1_800).timeIntervalSince1970)
        let appendedBlob = generationBlob(
            model: "gemini-3.6-flash", input: 7, output: 3,
            timestamp: nil, stepUUID: "turn-appended"
        )
        let appendedStep = stepMetadata(
            timestamp: appendedTimestamp, stepUUID: "turn-appended", botID: "bot-1"
        )
        try SQLiteCLIAccessor().execute(
            path: path,
            sql: "INSERT INTO gen_metadata VALUES(300, x'\(hex(appendedBlob))');"
                + "INSERT INTO steps VALUES(300, x'\(hex(appendedStep))');"
        )

        spy.reset()
        let secondScan = await AntigravityDbUsageScanner(sqlite: spy, conversationsDirectory: { directory })
            .scan(now: now, pricing: TestPricing.bundled)
        let second = try XCTUnwrap(secondScan)
        let digestQueries = spy.records.filter { $0.sql.lowercased().contains("sha3") }
        XCTAssertFalse(digestQueries.isEmpty, "the changed scan never asked for a digest")
        XCTAssertTrue(
            digestQueries.allSatisfy { $0.error == nil && $0.value != nil },
            "a digest came back empty or failed: \(digestQueries)"
        )
        XCTAssertEqual(tripwire.queryCount, 0, "the changed Rust scan must not spawn /usr/bin/sqlite3")

        let originalPersistence = AntigravityAggregatePersistence.directoryOverride
        let oraclePersistence = FileManager.default.temporaryDirectory
            .appendingPathComponent("antigravity-digest-oracle-\(UUID().uuidString)", isDirectory: true)
        AntigravityAggregatePersistence.directoryOverride = oraclePersistence
        defer {
            AntigravityAggregatePersistence.directoryOverride = originalPersistence
            try? FileManager.default.removeItem(at: oraclePersistence)
        }
        let oracleScan = await scanner(directory: directory, engine: .sqliteCLI)
            .scan(now: now, pricing: TestPricing.bundled)
        let oracle = try XCTUnwrap(oracleScan)
        XCTAssertEqual(second, oracle)
        XCTAssertEqual(spendLines(second), spendLines(oracle))
    }

    func testCLIEngineKeepsTheSwiftPath() async throws {
        let directory = try fixture()
        let tripwire = AntigravityTripwireSQLite()
        let cliScanner = scanner(directory: directory, engine: .sqliteCLI, fallback: tripwire)
        _ = await cliScanner.scan(now: now, pricing: TestPricing.bundled)
        XCTAssertGreaterThan(tripwire.queryCount, 0, "the explicit CLI oracle must use the injected accessor")
    }

    /// One bad bridge response must downgrade only the statement that hit it. The next statement
    /// has to try Rust again; otherwise a transient failure silently restores sqlite3 spawning for
    /// the rest of the app session.
    func testBridgeFailureFallsBackForOneStatementThenReturnsToRust() async throws {
        let directory = try fixture()
        let fallback = AntigravityCountingSQLite()
        let rust = AntigravityFailingRustQuery(failures: 1)
        let accessor = AntigravityDatabaseAccess(
            engine: .rust,
            sqlite: fallback,
            rustQuery: { path, sql in try rust.query(path: path, sql: sql) }
        )
        let rustScanner = AntigravityDbUsageScanner(
            sqlite: accessor,
            conversationsDirectory: { directory }
        )

        let rustValue = await rustScanner.scan(now: now, pricing: TestPricing.bundled)
        let rustScan = try XCTUnwrap(rustValue)
        let oracleValue = await scanner(directory: directory, engine: .sqliteCLI)
            .scan(now: now, pricing: TestPricing.bundled)
        let oracle = try XCTUnwrap(oracleValue)
        XCTAssertEqual(rustScan, oracle)
        XCTAssertEqual(spendLines(rustScan), spendLines(oracle))
        XCTAssertEqual(fallback.queryCount, 1, "only the failed statement should use the CLI")
        let attemptsAfterFirstScan = rust.attemptCount
        XCTAssertGreaterThan(attemptsAfterFirstScan, 1, "the next statement should try Rust again")

        // A second, cold scan must also try Rust; the fallback is not sticky across scans.
        let originalPersistence = AntigravityAggregatePersistence.directoryOverride
        let secondPersistence = FileManager.default.temporaryDirectory
            .appendingPathComponent("antigravity-fallback-recovery-\(UUID().uuidString)", isDirectory: true)
        AntigravityAggregatePersistence.directoryOverride = secondPersistence
        defer {
            AntigravityAggregatePersistence.directoryOverride = originalPersistence
            try? FileManager.default.removeItem(at: secondPersistence)
        }
        let secondScanner = AntigravityDbUsageScanner(
            sqlite: accessor,
            conversationsDirectory: { directory }
        )
        let secondValue = await secondScanner.scan(now: now, pricing: TestPricing.bundled)
        let secondScan = try XCTUnwrap(secondValue)
        XCTAssertEqual(secondScan, oracle)
        XCTAssertEqual(fallback.queryCount, 1, "the next scan must not reuse the failed statement's CLI fallback")
        XCTAssertGreaterThan(rust.attemptCount, attemptsAfterFirstScan, "the next scan should reach Rust")
    }

    func testRustEngineRefusesExecuteWithoutSpawningTheCLI() {
        let fallback = AntigravityCountingSQLite()
        let accessor = AntigravityDatabaseAccess(engine: .rust, sqlite: fallback)

        XCTAssertThrowsError(
            try accessor.execute(path: "/tmp/quotabar-antigravity-execute.db", sql: "CREATE TABLE t(v);")
        ) { error in
            XCTAssertTrue(error is SQLiteError)
        }
        XCTAssertEqual(fallback.executeCount, 0)
    }

    @MainActor
    func testProviderRefreshUsesTheRustRead() async throws {
        let directory = try fixture()
        let tripwire = AntigravityTripwireSQLite()
        let scanner = scanner(directory: directory, engine: .rust, fallback: tripwire)
        let http = FakeHTTPClient(
            response: HTTPResponse(statusCode: 503, headers: [:], body: Data())
        )
        let fixedNow = now
        let provider = AntigravityProvider(
            authStore: AntigravityAuthStore(keychain: FakeKeychain(nil), files: FakeFiles()),
            usageClient: AntigravityUsageClient(lsHTTP: http, http: http),
            discovery: LanguageServerDiscovery(processRunner: EmptyProcessRunner()),
            dbUsageScanner: scanner,
            now: { fixedNow },
            pricing: { TestPricing.bundled }
        )

        #if DEBUG
        let queriesBefore = AntigravityRustScan.completedQueriesForTesting
        #endif
        let snapshot = await provider.refresh()
        #if DEBUG
        XCTAssertGreaterThan(
            AntigravityRustScan.completedQueriesForTesting, queriesBefore,
            "the provider refresh never reached sqlite.query"
        )
        #endif
        XCTAssertNotNil(snapshot.usageHistory)
        XCTAssertEqual(tripwire.queryCount, 0)
    }
}

private final class AntigravityTripwireSQLite: SQLiteAccessing, @unchecked Sendable {
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

/// Records each statement so a test can assert which engine answered it and whether a digest
/// query actually returned a value. The wrapped accessor owns engine selection and fallback.
private final class AntigravityRecordingSQLite: SQLiteAccessing, @unchecked Sendable {
    struct Record {
        let sql: String
        let value: String?
        let error: String?
    }

    private let lock = NSLock()
    private let inner: SQLiteAccessing
    private var entries: [Record] = []

    init(inner: SQLiteAccessing) {
        self.inner = inner
    }

    var records: [Record] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    func reset() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }

    func queryValue(path: String, sql: String) throws -> String? {
        do {
            let value = try inner.queryValue(path: path, sql: sql)
            lock.lock()
            entries.append(Record(sql: sql, value: value, error: nil))
            lock.unlock()
            return value
        } catch {
            lock.lock()
            entries.append(Record(sql: sql, value: nil, error: "\(error)"))
            lock.unlock()
            throw error
        }
    }

    func execute(path: String, sql: String) throws {
        try inner.execute(path: path, sql: sql)
    }
}

private final class AntigravityCountingSQLite: SQLiteAccessing, @unchecked Sendable {
    private let lock = NSLock()
    private let inner = SQLiteCLIAccessor(allowsReadWriteFallback: false)
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

private final class AntigravityFailingRustQuery: @unchecked Sendable {
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
        return try AntigravityRustScan.queryValue(path: path, sql: sql)
    }
}
