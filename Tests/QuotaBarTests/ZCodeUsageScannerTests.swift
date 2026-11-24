import XCTest
@testable import QuotaBar

final class ZCodeUsageScannerTests: XCTestCase {
    func testCountsInputAndOutputWithoutAddingCachedTokensAgain() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("quotabar-zcode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("db.sqlite").path
        try NativeSQLiteAccessor().execute(path: path, sql: """
            CREATE TABLE model_usage (input_tokens INTEGER, output_tokens INTEGER,
                                      cache_read_input_tokens INTEGER, cache_creation_input_tokens INTEGER,
                                      provider_id TEXT, started_at INTEGER);
            INSERT INTO model_usage VALUES (100, 20, 70, 10, 'account:zai-start-plan', 1000), (40, 5, 20, 0, 'account:zai-start-plan', 1001), (0, 0, 0, 0, 'account:zai-start-plan', 1002);
            """)
        let scanner = ZCodeUsageScanner(path: path)
        XCTAssertTrue(scanner.hasHistory())
        XCTAssertEqual(try scanner.totalTokens(), 165)
        let usage = try scanner.usage()
        XCTAssertEqual(usage?.totalTokens, 165)
        XCTAssertEqual(usage?.planName, "Start Plan")
    }

    func testMissingDatabaseIsNotCreated() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let scanner = ZCodeUsageScanner(path: path, leveldbPath: "/nonexistent-quotabar-zcode-test/leveldb")
        XCTAssertFalse(scanner.hasHistory())
        XCTAssertNil(try scanner.totalTokens())
        XCTAssertNil(try scanner.usage())
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    /// A corrupt `model_usage` row (negative/non-integer tokens) must not throw away the whole
    /// card: it is excluded from totals and reported via `damagedRows`, so the provider can
    /// surface a history warning instead of silently reading low.
    func testInvalidTokenCountsAreExcludedAndReported() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try NativeSQLiteAccessor().execute(path: path, sql: """
            CREATE TABLE model_usage (input_tokens INTEGER, output_tokens INTEGER, provider_id TEXT, started_at INTEGER);
            INSERT INTO model_usage VALUES (100, 20, 'account:zai-start-plan', 1000), (-1, 2, 'account:zai-start-plan', 1001);
            """)
        let scanner = ZCodeUsageScanner(path: path, leveldbPath: "/nonexistent-quotabar-zcode-test/leveldb")
        XCTAssertEqual(try scanner.totalTokens(), 120)
        let usage = try XCTUnwrap(scanner.usage())
        XCTAssertEqual(usage.totalTokens, 120)
        XCTAssertEqual(usage.damagedRows, 1)
        XCTAssertEqual(usage.planName, "Start Plan")
    }

    /// A fresh plan (or cleared db) has no local sqlite history yet — the LevelDB entitlement
    /// alone must still surface the plan and its promotional allowance instead of the scanner
    /// returning nil and hiding the Weekend Build meter.
    func testEntitlementSurvivesMissingSqliteDatabase() throws {
        let levelDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quotabar-zcode-nosqlite-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: levelDir, withIntermediateDirectories: true)
        let payload = """
        zcode:usage-entitlement:subscription-v2:account:zai-start-plan:["hash",{}]:auth:1\u{0001}{"cachedAt":1794163892440,"snapshot":{"quota":{"level":"Start","limits":[{"planId":"zcode-v3-start-plan-1106-wk","period":"one_time","unit":500000000,"usage":100000000,"remaining":400000000,"nextResetTime":1794186000000}]}}}
        """
        try Data(payload.utf8).write(to: levelDir.appendingPathComponent("000001.log"))

        let scanner = ZCodeUsageScanner(path: "/nonexistent-quotabar-zcode-test/db.sqlite", leveldbPath: levelDir.path)
        XCTAssertTrue(scanner.hasHistory())
        let usage = try XCTUnwrap(scanner.usage())
        XCTAssertNil(usage.totalTokens)
        XCTAssertNil(usage.logScan)
        XCTAssertEqual(usage.planName, "Start Plan")
        XCTAssertEqual(usage.weekendBuild?.label, "Weekend Build")
        XCTAssertEqual(usage.weekendBuild?.remaining, 400_000_000)
        XCTAssertEqual(usage.damagedRows, 0)
    }

    /// Implausible promo reset instants — zero, or seconds reported where milliseconds were
    /// expected (landing in 1970) — are dropped rather than rendered as "Resets soon"/"expired".
    func testBogusPromoResetInstantsAreDropped() throws {
        let levelDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quotabar-zcode-reset-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: levelDir, withIntermediateDirectories: true)
        let payload = """
        zcode:usage-entitlement:subscription-v2:account:zai-start-plan:["hash",{}]:auth:1\u{0001}{"cachedAt":1794163892440,"snapshot":{"quota":{"level":"Start","limits":[{"planId":"zcode-v3-start-plan-zero","period":"one_time","unit":100000000,"usage":0,"remaining":100000000,"nextResetTime":0},{"planId":"zcode-v3-start-plan-secs","period":"one_time","unit":100000000,"usage":0,"remaining":100000000,"nextResetTime":1794186000}]}}}
        """
        try Data(payload.utf8).write(to: levelDir.appendingPathComponent("000001.log"))

        let scanner = ZCodeUsageScanner(path: "/nonexistent-quotabar-zcode-test/db.sqlite", leveldbPath: levelDir.path)
        let now = Date(timeIntervalSince1970: 1_794_166_000)
        let usage = try XCTUnwrap(scanner.usage(now: now))
        // The selected (first) allowance carries a zero `nextResetTime`; the seconds-as-ms variant
        // would land in 1970. Either way the allowance still surfaces, just without a date.
        XCTAssertNotNil(usage.weekendBuild, "An allowance with an implausible reset must still surface")
        XCTAssertNil(usage.weekendBuild?.resetsAt)
        XCTAssertNil(usage.weekendBuild?.expiresAt)
    }

    func testIncompatibleDatabaseThrows() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try NativeSQLiteAccessor().execute(path: path, sql: "CREATE TABLE other (id INTEGER);")
        // A sqlite failure still throws when there is no LevelDB entitlement to fall back on.
        let scanner = ZCodeUsageScanner(path: path, leveldbPath: "/nonexistent-quotabar-zcode-test/leveldb")
        XCTAssertThrowsError(try scanner.totalTokens())
    }

    func testTotalTokensCachesAndUnloadsForMemoryPressure() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("quotabar-zcode-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("db.sqlite").path
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        try NativeSQLiteAccessor().execute(path: path, sql: """
            CREATE TABLE model_usage (input_tokens INTEGER, output_tokens INTEGER, provider_id TEXT, started_at INTEGER);
            INSERT INTO model_usage VALUES (100, 20, 'account:zai-start-plan', \(nowMs));
            """)
        let scanner = ZCodeUsageScanner(path: path)
        XCTAssertEqual(try scanner.totalTokens(), 120)

        // Memory pressure unloads cache
        scanner.unloadCachesForMemoryPressure()
        XCTAssertEqual(try scanner.totalTokens(), 120)
    }

    func testDetectsCodingPlanFromProviderID() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("quotabar-zcode-coding-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("db.sqlite").path
        try NativeSQLiteAccessor().execute(path: path, sql: """
            CREATE TABLE model_usage (input_tokens INTEGER, output_tokens INTEGER, provider_id TEXT, started_at INTEGER);
            INSERT INTO model_usage VALUES (500, 100, 'account:zai-coding-plan', 2000);
            """)
        let scanner = ZCodeUsageScanner(path: path)
        let usage = try scanner.usage()
        XCTAssertEqual(usage?.totalTokens, 600)
        XCTAssertEqual(usage?.planName, "Coding Plan")
    }

    /// A dead sqlite source must not hide a valid LevelDB entitlement: the scan records the
    /// failure for the provider to surface and still returns the entitlement's data.
    func testSqliteFailureStillSurfacesLevelDBEntitlement() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("quotabar-zcode-sqlfail-\(UUID().uuidString)")
        let dbDir = directory.appendingPathComponent("db")
        let levelDir = directory.appendingPathComponent("leveldb")
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: levelDir, withIntermediateDirectories: true)
        let sqlitePath = dbDir.appendingPathComponent("db.sqlite").path
        try NativeSQLiteAccessor().execute(path: sqlitePath, sql: "CREATE TABLE other (id INTEGER);")
        let payload = """
        zcode:usage-entitlement:subscription-v2:account:zai-start-plan:["h",{}]:auth:1\u{0001}{"cachedAt":1794254217417,"snapshot":{"quota":{"level":"Start","limits":[{"planId":"zcode-v3-start-plan-1106-wk","period":"one_time","unit":300000000,"usage":1,"remaining":299999999,"nextResetTime":1794272400000}]}}}
        """
        try Data(payload.utf8).write(to: levelDir.appendingPathComponent("000001.log"))

        let scanner = ZCodeUsageScanner(path: sqlitePath, leveldbPath: levelDir.path)
        let usage = try XCTUnwrap(scanner.usage(), "LevelDB entitlement must survive a dead sqlite source")
        XCTAssertNotNil(usage.sqliteReadFailure)
        XCTAssertNil(usage.totalTokens)
        XCTAssertEqual(usage.planName, "Start Plan")
        XCTAssertEqual(usage.weekendBuild?.remaining, 299_999_999)
    }

    /// A live-but-unused promo used to invalidate the cache on every call (effectiveAt <= now and
    /// used == 0 always holds), forcing a full LevelDB rescan each refresh for the promo's whole
    /// life. The invalidation is one-shot: only the scheduled→live transition rescans.
    func testActiveUnusedPromoDoesNotRescanEveryCall() throws {
        let levelDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quotabar-zcode-onetime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: levelDir, withIntermediateDirectories: true)
        let logPath = levelDir.appendingPathComponent("000001.log")
        // Identical size+mtime across rewrites: the file stamp stays equal so only the
        // effectiveAt invalidation logic decides whether a call rescans.
        func writePayload(expireDay: Int) throws {
            let payload = """
            zcode:usage-entitlement:subscription-v2:account:zai-start-plan:["h",{}]:auth:1\u{0001}{"cachedAt":1794163892440,"snapshot":{"quota":{"level":"Start","limits":[]},"subscription":{"details":[{"productId":"zcode-v3-start-plan-1110-nt","productName":"ZCODE GLOBAL BUILD","billingCycle":"one_time","expireTime":"2026-11-\(expireDay)T01:00:00.000Z","entitlements":[{"entitlementId":"ent-1","effectiveTime":"2026-11-01T15:00:00.000Z"}]}]}}}
            """
            try Data(payload.utf8).write(to: logPath)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_794_000_000)],
                ofItemAtPath: logPath.path
            )
        }
        try writePayload(expireDay: 11)

        let scanner = ZCodeUsageScanner(path: "/nonexistent-quotabar-zcode-test/db.sqlite", leveldbPath: levelDir.path)
        // effectiveTime (Nov 1) precedes the first scan's `now` (Nov 5): the promo is already active.
        let t0 = Date(timeIntervalSince1970: 1_793_840_400)
        let first = try XCTUnwrap(scanner.usage(now: t0))
        XCTAssertEqual(first.weekendBuild?.expiresAt, Date(timeIntervalSince1970: 1_794_358_800))

        try writePayload(expireDay: 12)
        let cached = try XCTUnwrap(scanner.usage(now: t0.addingTimeInterval(3_600)))
        XCTAssertEqual(cached.weekendBuild?.expiresAt, Date(timeIntervalSince1970: 1_794_358_800),
                       "an already-active unused promo must hit the cache, not rescan on every call")
    }

    /// The one case that still invalidates: a promo scanned while scheduled goes live between the
    /// scan and `now` — exactly once. After the rescan the new scan stamp is past effectiveAt and
    /// the cache is trusted again.
    func testScheduledPromoTransitionInvalidatesExactlyOnce() throws {
        let levelDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quotabar-zcode-transition-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: levelDir, withIntermediateDirectories: true)
        let logPath = levelDir.appendingPathComponent("000001.log")
        func writePayload(expireDay: Int) throws {
            let payload = """
            zcode:usage-entitlement:subscription-v2:account:zai-start-plan:["h",{}]:auth:1\u{0001}{"cachedAt":1794163892440,"snapshot":{"quota":{"level":"Start","limits":[]},"subscription":{"details":[{"productId":"zcode-v3-start-plan-1110-nt","productName":"ZCODE GLOBAL BUILD","billingCycle":"one_time","expireTime":"2026-11-\(expireDay)T01:00:00.000Z","entitlements":[{"entitlementId":"ent-1","effectiveTime":"2026-11-01T15:00:00.000Z"}]}]}}}
            """
            try Data(payload.utf8).write(to: logPath)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_794_000_000)],
                ofItemAtPath: logPath.path
            )
        }
        try writePayload(expireDay: 11)

        let scanner = ZCodeUsageScanner(path: "/nonexistent-quotabar-zcode-test/db.sqlite", leveldbPath: levelDir.path)
        // Oct 31 23:00 — before effectiveTime Nov 1 15:00, so the promo is scanned as scheduled.
        let first = try XCTUnwrap(scanner.usage(now: Date(timeIntervalSince1970: 1_793_487_600)))
        XCTAssertEqual(first.weekendBuild?.expiresAt, Date(timeIntervalSince1970: 1_794_358_800))

        // Promo went live between the first scan and this call → exactly one rescan.
        try writePayload(expireDay: 12)
        let live = Date(timeIntervalSince1970: 1_793_840_400)
        let transitioned = try XCTUnwrap(scanner.usage(now: live))
        XCTAssertEqual(transitioned.weekendBuild?.expiresAt, Date(timeIntervalSince1970: 1_794_445_200),
                       "the scheduled→live transition must rescan once")

        try writePayload(expireDay: 13)
        let cached = try XCTUnwrap(scanner.usage(now: live.addingTimeInterval(3_600)))
        XCTAssertEqual(cached.weekendBuild?.expiresAt, Date(timeIntervalSince1970: 1_794_445_200),
                       "after the transition rescan the cache must be trusted again")
    }

    /// WAL-mode writes land in db.sqlite-wal and only merge at checkpoint time; the stamp must
    /// include the sidecar or the cache serves stale totals between checkpoints.
    func testWALSidecarInvalidatesTheCache() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("quotabar-zcode-wal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sqlitePath = directory.appendingPathComponent("db.sqlite").path
        try Data().write(to: URL(fileURLWithPath: sqlitePath))

        let sqlite = ZCodeCountingSQLite()
        let scanner = ZCodeUsageScanner(
            sqlite: sqlite,
            path: sqlitePath,
            leveldbPath: "/nonexistent-quotabar-zcode-test/leveldb"
        )
        _ = try scanner.usage()
        let firstCount = sqlite.queries
        _ = try scanner.usage()
        XCTAssertEqual(sqlite.queries, firstCount, "an unchanged db must hit the cache")

        try Data("wal-bytes".utf8).write(to: directory.appendingPathComponent("db.sqlite-wal"))
        _ = try scanner.usage()
        XCTAssertGreaterThan(sqlite.queries, firstCount,
                             "a WAL write between checkpoints must invalidate the cache")
    }

    /// A REAL (non-integer) token value used to pass the `>= 0` filter, then made the whole
    /// day+model group's SUM non-integer so the parse dropped it — taking valid rows with it.
    /// The daily query now excludes non-integer rows exactly like the totals query.
    func testNonIntegerTokenRowDoesNotPoisonItsDailyGroup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("quotabar-zcode-real-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("db.sqlite").path
        try NativeSQLiteAccessor().execute(path: path, sql: """
            CREATE TABLE model_usage (input_tokens, output_tokens, cache_read_input_tokens,
                                      cache_creation_input_tokens, model_id, provider_id, started_at);
            INSERT INTO model_usage VALUES (1.5, 2, 0, 0, 'glm-4', 'account:zai-start-plan', 1794160000000),
                                          (100, 20, 0, 0, 'glm-4', 'account:zai-start-plan', 1794160000000);
            """)
        let scanner = ZCodeUsageScanner(path: path, leveldbPath: "/nonexistent-quotabar-zcode-test/leveldb")
        let usage = try XCTUnwrap(scanner.usage())
        XCTAssertEqual(usage.totalTokens, 120)
        XCTAssertEqual(usage.damagedRows, 1)
        XCTAssertEqual(usage.logScan?.series.daily.first?.totalTokens, 120,
                       "the REAL row must not take its whole day+model group down with it")
    }

    /// The scan-worker child is a fresh process every fold: the persisted record must let an
    /// unchanged fold answer without spawning sqlite3 again, just like the in-memory cache does
    /// inside one process.
    func testFreshProcessServesUnchangedFoldFromPersistedRecord() throws {
        let records = FileManager.default.temporaryDirectory
            .appendingPathComponent("quotabar-zcode-persist-\(UUID().uuidString)")
        ZCodeUsageCachePersistence.directoryOverride = records
        defer {
            ZCodeUsageCachePersistence.directoryOverride = nil
            try? FileManager.default.removeItem(at: records)
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("quotabar-zcode-persist-db-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sqlitePath = directory.appendingPathComponent("db.sqlite").path
        try Data().write(to: URL(fileURLWithPath: sqlitePath))

        let counting = ZCodeCountingSQLite()
        let first = ZCodeUsageScanner(
            sqlite: counting, path: sqlitePath,
            leveldbPath: "/nonexistent-quotabar-zcode-test/leveldb"
        )
        _ = try first.usage()
        let scanned = counting.queries
        XCTAssertGreaterThan(scanned, 0)

        let worker = ZCodeUsageScanner(
            sqlite: counting, path: sqlitePath,
            leveldbPath: "/nonexistent-quotabar-zcode-test/leveldb"
        )
        let usage = try XCTUnwrap(worker.usage())
        XCTAssertEqual(counting.queries, scanned,
                       "a fresh process with unchanged stamps must not respawn sqlite3")
        XCTAssertEqual(usage.totalTokens, 120)

        try Data("wal-bytes".utf8).write(to: directory.appendingPathComponent("db.sqlite-wal"))
        _ = try worker.usage()
        XCTAssertGreaterThan(counting.queries, scanned,
                             "a stamp change must invalidate the persisted record too")
    }
}

/// Counts sqlite reads so a test can tell a cache hit from a real rescan.
private final class ZCodeCountingSQLite: SQLiteAccessing, @unchecked Sendable {
    private(set) var queries = 0
    func queryValue(path: String, sql: String) throws -> String? {
        queries += 1
        // Answer the totals probe; the per-day series probes get nil — the test exercises the
        // stamp/invalidation path, not the parse path.
        return sql.contains("SUM(CASE") ? "120|0|account:zai-start-plan" : nil
    }
    func execute(path: String, sql: String) throws {}
}

@MainActor
final class ZCodeProviderIntegrationTests: XCTestCase {
    func testLocalUsageRemainsAvailableWithoutCodingPlanKey() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        try NativeSQLiteAccessor().execute(path: path, sql: """
            CREATE TABLE model_usage (input_tokens INTEGER, output_tokens INTEGER, provider_id TEXT, started_at INTEGER);
            INSERT INTO model_usage VALUES (100, 20, 'account:zai-start-plan', \(nowMs));
            """)
        let provider = ZAIProvider(
            zcodeScanner: ZCodeUsageScanner(path: path),
            authStore: ZAIAuthStore(files: FakeFiles(), environment: FakeEnvironment())
        )
        let detected = await provider.hasLocalCredentials()
        let snapshot = await provider.refresh()
        XCTAssertTrue(detected)
        XCTAssertNil(snapshot.warning)
        XCTAssertEqual(snapshot.plan, "Start Plan")
        guard case .values(_, let values, _, _, _, _) = snapshot.line(label: "Today") ?? snapshot.line(label: "Last 30 Days") else {
            return XCTFail("Missing local token spend tile")
        }
        XCTAssertEqual(values.first?.number, 120)
    }

    /// A local promo row must not vouch for the live quota API: when the quota half fails, the
    /// appended promo stays but quotaRefreshedAt keeps the failure stamp (.distantPast) so the
    /// store does not treat the meters as freshly answered.
    func testFailedQuotaKeepsDistantPastStampWhenLocalPromoAppends() async throws {
        let (sqlitePath, levelDir) = try makeZCodeFixture(
            sqliteRow: "INSERT INTO model_usage VALUES (1000, 500, 'account:zai-start-plan', 1794160000000)",
            entitlementPayload: """
            {"cachedAt":1794163892440,"snapshot":{"quota":{"level":"Start","limits":[{"planId":"zcode-v3-start-plan-1106-wk","period":"one_time","unit":500000000,"usage":194069327,"remaining":305930673,"nextResetTime":1794186000000}]}}}
            """
        )
        let provider = ZAIProvider(
            zcodeScanner: ZCodeUsageScanner(path: sqlitePath, leveldbPath: levelDir.path),
            authStore: ZAIAuthStore(files: FakeFiles(), environment: FakeEnvironment(["ZAI_API_KEY": "zai-test"])),
            usageClient: ZAIUsageClient(http: RoutingHTTPClient { request in
                if request.url == ZAIUsageClient.quotaURL {
                    return HTTPResponse(statusCode: 500, headers: [:], body: Data())
                }
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"data":[{"productName":"GLM Coding Max"}]}"#.utf8))
            }),
            now: { Date(timeIntervalSince1970: 1794160000) }
        )
        let snapshot = await provider.refresh()
        XCTAssertNotNil(snapshot.line(label: "Weekend Build"), "local promo rows still render on a quota failure")
        XCTAssertEqual(snapshot.quotaRefreshedAt, .distantPast,
                       "a failed quota half must not be stamped fresh by the local promo row")
    }

    /// A plan name carried only by the LevelDB entitlement (no tokens, no promo) is still a real
    /// result — the provider must not drop it at the "is there any local usage" gate.
    func testEntitlementOnlyPlanNameIsNotDiscarded() async throws {
        let levelDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quotabar-zcode-planonly-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: levelDir, withIntermediateDirectories: true)
        let payload = """
        zcode:usage-entitlement:subscription-v2:account:zai-start-plan:["h",{}]:auth:1\u{0001}{"cachedAt":1794254217417,"snapshot":{"quota":{"level":"Start","limits":[]}}}
        """
        try Data(payload.utf8).write(to: levelDir.appendingPathComponent("000001.log"))

        let provider = ZAIProvider(
            zcodeScanner: ZCodeUsageScanner(path: "/nonexistent-quotabar-zcode-test/db.sqlite", leveldbPath: levelDir.path),
            authStore: ZAIAuthStore(files: FakeFiles(), environment: FakeEnvironment())
        )
        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.plan, "Start Plan")
    }

    /// With the sqlite history dead, the entitlement still renders and the failure shows up as a
    /// history warning — the same message the all-out failure path uses.
    func testSqliteFailureSetsHistoryWarningButKeepsEntitlement() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("quotabar-zai-sqlfail-\(UUID().uuidString)")
        let dbDir = directory.appendingPathComponent("db")
        let levelDir = directory.appendingPathComponent("leveldb")
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: levelDir, withIntermediateDirectories: true)
        let sqlitePath = dbDir.appendingPathComponent("db.sqlite").path
        try NativeSQLiteAccessor().execute(path: sqlitePath, sql: "CREATE TABLE other (id INTEGER);")
        let payload = """
        zcode:usage-entitlement:subscription-v2:account:zai-start-plan:["h",{}]:auth:1\u{0001}{"cachedAt":1794254217417,"snapshot":{"quota":{"level":"Start","limits":[]}}}
        """
        try Data(payload.utf8).write(to: levelDir.appendingPathComponent("000001.log"))

        let provider = ZAIProvider(
            zcodeScanner: ZCodeUsageScanner(path: sqlitePath, leveldbPath: levelDir.path),
            authStore: ZAIAuthStore(files: FakeFiles(), environment: FakeEnvironment())
        )
        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.plan, "Start Plan")
        XCTAssertEqual(snapshot.historyWarning, "Couldn't read ZCode token usage.")
    }

    /// Once the promo's expiry has passed, the row reads "Expired" instead of a countdown — the
    /// entitlement snapshot can lag the grant's end, and a stale countdown would lie about time left.
    func testExpiredPromoAutoRemoves() async throws {
        let (sqlitePath, levelDir) = try makeZCodeFixture(
            sqliteRow: "INSERT INTO model_usage VALUES (1000, 500, 'account:zai-start-plan', 1794160000000)",
            entitlementPayload: """
            {"cachedAt":1794254217417,"snapshot":{"quota":{"level":"Start","limits":[{"planId":"zcode-v3-start-plan-1109","period":"one_time","unit":300000000,"usage":30023335,"remaining":269976665,"nextResetTime":1794272400000}]},"subscription":{"details":[{"productId":"zcode-v3-start-plan-1109","expireTime":"2026-11-10T01:00:00.000Z"}]}}}
            """
        )
        let provider = ZAIProvider(
            zcodeScanner: ZCodeUsageScanner(path: sqlitePath, leveldbPath: levelDir.path),
            authStore: ZAIAuthStore(files: FakeFiles(), environment: FakeEnvironment()),
            now: { Date(timeIntervalSince1970: 1794300000) }
        )
        let snapshot = await provider.refresh()
        XCTAssertNil(snapshot.line(label: "Weekend Build"), "Expired allowance must auto-remove itself")
    }

    /// The Usage History stats screen (cross-provider totals, "At Public API Rates" line, model
    /// breakdown) reads `snapshot.usageHistory` — ZCode's recorded days must land there, with the
    /// same per-day estimate provenance the spend tiles show.
    func testUsageHistoryFeedsTheStatsScreen() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("quotabar-zcode-stats-\(UUID().uuidString)")
        let dbDir = tempDir.appendingPathComponent("db")
        let levelDir = tempDir.appendingPathComponent("leveldb")
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: levelDir, withIntermediateDirectories: true)
        let sqlitePath = dbDir.appendingPathComponent("db.sqlite").path
        try NativeSQLiteAccessor().execute(path: sqlitePath, sql: """
            CREATE TABLE model_usage (input_tokens INTEGER, output_tokens INTEGER,
                                      cache_read_input_tokens INTEGER, cache_creation_input_tokens INTEGER,
                                      provider_id TEXT, model_id TEXT, started_at INTEGER);
            INSERT INTO model_usage VALUES (1000, 500, 0, 0, 'account:zai-start-plan', 'GLM-5.3-Flash', 1794160000000);
            """)
        let payload = """
        zcode:usage-entitlement:subscription-v2:account:zai-start-plan:["h",{}]:auth:1\u{0001}{"cachedAt":1794254217417,"snapshot":{"quota":{"level":"Start","limits":[]}}}
        """
        try Data(payload.utf8).write(to: levelDir.appendingPathComponent("000001.log"))

        let provider = ZAIProvider(
            zcodeScanner: ZCodeUsageScanner(path: sqlitePath, leveldbPath: levelDir.path),
            authStore: ZAIAuthStore(files: FakeFiles(), environment: FakeEnvironment()),
            now: { Date(timeIntervalSince1970: 1794160000) }
        )
        let snapshot = await provider.refresh()
        let history = try XCTUnwrap(snapshot.usageHistory, "ZCode history must feed the Usage History stats screen")
        XCTAssertEqual(history.series.daily.first?.totalTokens, 1500)
        XCTAssertTrue(history.unknownModelsByDay.values.allSatisfy(\.isEmpty), "GLM models are priced, so no unknown-model warnings")
        // The store reads this stamp to vouch for the history's freshness; attaching the history
        // after construction must still stamp it or a full pass looks undated.
        XCTAssertEqual(snapshot.historyRefreshedAt, Date(timeIntervalSince1970: 1794160000))
    }

    func testParsesWeekendBuildAllowanceWithoutPercentage() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("quotabar-zcode-wk-\(UUID().uuidString)")
        let dbDir = tempDir.appendingPathComponent("db")
        let levelDir = tempDir.appendingPathComponent("leveldb")
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: levelDir, withIntermediateDirectories: true)

        let sqlitePath = dbDir.appendingPathComponent("db.sqlite").path
        try NativeSQLiteAccessor().execute(path: sqlitePath, sql: """
            CREATE TABLE model_usage (input_tokens INTEGER, output_tokens INTEGER, provider_id TEXT, started_at INTEGER);
            INSERT INTO model_usage VALUES (1000, 500, 'account:zai-start-plan', 1794160000000);
            """)

        let jsonPayload = """
        zcode:usage-entitlement:subscription-v2:account:zai-start-plan:["hash",{"providerId":"account:zai-start-plan"}]:auth:1\u{0001}{"cachedAt":1794163892440,"snapshot":{"quota":{"level":"Start","limits":[{"planId":"zcode-v3-start-plan-1106-wk","period":"one_time","unit":500000000,"usage":194069327,"remaining":305930673,"nextResetTime":1794186000000}]}}}
        """
        let logPath = levelDir.appendingPathComponent("000001.log")
        try Data(jsonPayload.utf8).write(to: logPath)

        let scanner = ZCodeUsageScanner(path: sqlitePath, leveldbPath: levelDir.path)
        let usage = try scanner.usage()
        XCTAssertEqual(usage?.planName, "Start Plan")
        XCTAssertEqual(usage?.weekendBuild?.label, "Weekend Build")
        XCTAssertEqual(usage?.weekendBuild?.limit, 500_000_000)
        XCTAssertEqual(usage?.weekendBuild?.used, 194_069_327)
        XCTAssertEqual(usage?.weekendBuild?.remaining, 305_930_673)
        // A one-time grant expires instead of resetting: the `nextResetTime` stamp becomes the
        // expiry fallback when the snapshot carries no purchase record for the bucket.
        XCTAssertNil(usage?.weekendBuild?.resetsAt)
        XCTAssertEqual(usage?.weekendBuild?.expiresAt, Date(timeIntervalSince1970: 1794186000))

        let provider = ZAIProvider(
            zcodeScanner: scanner,
            authStore: ZAIAuthStore(files: FakeFiles(), environment: FakeEnvironment()),
            now: { Date(timeIntervalSince1970: 1794160000) }
        )
        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.plan, "Start Plan")

        // Weekend Build must be formatted as count of tokens, NOT percent!
        guard let weekendLine = snapshot.line(label: "Weekend Build") else {
            return XCTFail("Missing Weekend Build line")
        }
        guard case .progress(_, let used, let limit, let format, let expiry, _, _, let detail) = weekendLine else {
            return XCTFail("Weekend Build line is not a progress line")
        }
        XCTAssertEqual(used, 194_069_327)
        XCTAssertEqual(limit, 500_000_000)
        XCTAssertEqual(format, ProgressFormat.count(suffix: "tokens"), "Weekend Build MUST NOT be formatted as percentage")
        // The published deadline carries the grant's expiry instant so render-time expiry
        // filtering can retire the row even when the quota refresh cannot run.
        XCTAssertEqual(expiry, OpenUsageISO8601.date(from: "2026-11-09T01:00:00.000Z"))
        XCTAssertTrue(detail?.hasPrefix("Expires") == true, "A live promotional grant carries its expiry: \(detail ?? "nil")")

        // Spend tiles must be emitted for Today
        guard let todayLine = snapshot.line(label: "Today") else {
            return XCTFail("Missing Today spend tile line")
        }
        guard case .values(_, let todayVals, _, _, _, _) = todayLine else {
            return XCTFail("Today line is not values")
        }
        XCTAssertEqual(todayVals.first?.number, 1500)

        // TotalSpendAggregator must include ZAI in total tokens
        let totalSpend = TotalSpendAggregator.total(
            for: .today,
            providers: [provider.provider],
            snapshots: ["zai": snapshot],
            now: Date(timeIntervalSince1970: 1794160000)
        )
        XCTAssertEqual(totalSpend.totalTokens, 1500)
        let proj = totalSpend.projection(for: .tokens)
        XCTAssertTrue(proj.slices.contains { $0.provider.id == "zai" })
    }

    /// The purchase record (`subscription.details[].expireTime`) is the authoritative end of a
    /// promotional one-time grant; the allowance inherits it instead of the quota bucket's
    /// `nextResetTime`, and the grant never reads as a resetting cycle.
    func testParsesPromoExpiryFromSubscriptionDetails() async throws {
        let (sqlitePath, levelDir) = try makeZCodeFixture(
            sqliteRow: "INSERT INTO model_usage VALUES (1000, 500, 'account:zai-start-plan', 1794160000000)",
            entitlementPayload: """
            {"cachedAt":1794254217417,"snapshot":{"quota":{"level":"Start","limits":[{"planId":"zcode-v3-start-plan-1109","period":"one_time","unit":300000000,"usage":30023335,"remaining":269976665,"nextResetTime":1794272400000}]},"subscription":{"details":[{"productId":"zcode-v3-start-plan-1109","productName":"ZCODE GLOBAL BUILD","billingCycle":"one_time","expireTime":"2026-11-10T01:00:00.000Z"}]}}}
            """
        )
        let scanner = ZCodeUsageScanner(path: sqlitePath, leveldbPath: levelDir.path)
        let usage = try scanner.usage()
        XCTAssertEqual(usage?.weekendBuild?.limit, 300_000_000)
        XCTAssertEqual(usage?.weekendBuild?.remaining, 269_976_665)
        XCTAssertEqual(usage?.weekendBuild?.expiresAt, Date(timeIntervalSince1970: 1794272400))
        XCTAssertNil(usage?.weekendBuild?.resetsAt)
    }

    /// LevelDB compaction keeps several entitlement snapshots around (older account keys, stale
    /// copies in `.ldb` files). The scan must read every occurrence and keep the one with the
    /// highest `cachedAt`, not whichever file or copy sorts first.
    func testPicksFreshestEntitlementSnapshotAcrossKeysAndFiles() async throws {
        let (sqlitePath, levelDir) = try makeZCodeFixture(
            sqliteRow: "INSERT INTO model_usage VALUES (1000, 500, 'account:zai-start-plan', 1794160000000)",
            entitlementPayload: """
            {"cachedAt":1000,"snapshot":{"quota":{"level":"Start","limits":[{"planId":"old-wk","period":"one_time","unit":100,"usage":10,"remaining":90,"nextResetTime":0}]}}}
            """
        )
        // A second, newer snapshot for a differently-suffixed account key in an `.ldb` file — the
        // fresher copy must win even though the `.log` file sorts before it by name.
        let ldbPayload = """
        zcode:usage-entitlement:subscription-v2:account:zai-coding-plan:["h",{}]:auth:2\u{0001}{"cachedAt":2000,"snapshot":{"quota":{"level":"Start","limits":[{"planId":"zcode-v3-start-plan-1109","period":"one_time","unit":300000000,"usage":1,"remaining":299999999,"nextResetTime":0}]}}}
        """
        try Data(ldbPayload.utf8).write(to: levelDir.appendingPathComponent("000002.ldb"))

        let scanner = ZCodeUsageScanner(path: sqlitePath, leveldbPath: levelDir.path)
        let usage = try scanner.usage()
        XCTAssertEqual(usage?.weekendBuild?.limit, 300_000_000)
        XCTAssertEqual(usage?.weekendBuild?.used, 1)
        XCTAssertEqual(usage?.weekendBuild?.remaining, 299_999_999)
    }

    /// A drained promo bucket (remaining 0) still surfaces so the row can report its state instead
    /// of vanishing while the snapshot lags the provider's own end-of-grant bookkeeping.
    func testDrainedPromoBucketIsStillSurfaced() async throws {
        let (sqlitePath, levelDir) = try makeZCodeFixture(
            sqliteRow: "INSERT INTO model_usage VALUES (1000, 500, 'account:zai-start-plan', 1794160000000)",
            entitlementPayload: """
            {"cachedAt":1794254217417,"snapshot":{"quota":{"level":"Start","limits":[{"planId":"zcode-v3-start-plan-1109","period":"one_time","unit":300000000,"usage":300000000,"remaining":0,"nextResetTime":1794272400000}]}}}
            """
        )
        let scanner = ZCodeUsageScanner(path: sqlitePath, leveldbPath: levelDir.path)
        let usage = try scanner.usage()
        XCTAssertEqual(usage?.weekendBuild?.used, 300_000_000)
        XCTAssertEqual(usage?.weekendBuild?.remaining, 0)
        XCTAssertEqual(usage?.weekendBuild?.expiresAt, Date(timeIntervalSince1970: 1794272400))
    }

    func testZCodeCalculatesCostForTokensWhenPriced() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("quotabar-zcode-pricing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("db.sqlite").path
        let now = Date()
        let nowMs = Int(now.timeIntervalSince1970 * 1000)
        try NativeSQLiteAccessor().execute(path: path, sql: """
            CREATE TABLE model_usage (
                id TEXT PRIMARY KEY,
                input_tokens INTEGER,
                output_tokens INTEGER,
                cache_read_input_tokens INTEGER,
                cache_creation_input_tokens INTEGER,
                model_id TEXT,
                provider_id TEXT,
                started_at INTEGER
            );
            INSERT INTO model_usage VALUES ('1', 1000000, 200000, 500000, 0, 'GLM-5.3-Flash', 'account:zai-start-plan', \(nowMs));
            """)

        let provider = ZAIProvider(
            zcodeScanner: ZCodeUsageScanner(path: path),
            authStore: ZAIAuthStore(files: FakeFiles(), environment: FakeEnvironment()),
            pricing: { TestPricing.bundled },
            now: { now }
        )

        let snapshot = await provider.refresh()
        guard let todayLine = snapshot.line(label: "Today") else {
            return XCTFail("Missing Today spend tile line")
        }
        guard case .values(_, let vals, _, _, _, let breakdown) = todayLine else {
            return XCTFail("Today line is not values")
        }

        // Must have both dollar cost and token count
        let dollars = vals.first(where: { $0.kind == .dollars })
        let tokens = vals.first(where: { $0.kind == .count && $0.label == "tokens" })
        XCTAssertNotNil(dollars, "Today tile must include dollar cost for priced ZCode tokens")
        XCTAssertNotNil(tokens, "Today tile must include token count")
        XCTAssertEqual(tokens?.number, 1_200_000)
        XCTAssertEqual(try XCTUnwrap(dollars?.number), 0.1895, accuracy: 0.001)

        // Model breakdown tooltip must be populated
        XCTAssertNotNil(breakdown, "Model breakdown should be present on hover")
        XCTAssertEqual(breakdown?.models.first?.model.lowercased(), "glm-5.3-flash")

        // TotalSpendAggregator must project ZAI under both Cost and Tokens
        let totalSpend = TotalSpendAggregator.total(
            for: .today,
            providers: [provider.provider],
            snapshots: ["zai": snapshot],
            now: now
        )
        XCTAssertEqual(totalSpend.totalUSD, 0.1895, accuracy: 0.001)
        XCTAssertEqual(totalSpend.totalTokens, 1_200_000)

        let costProj = totalSpend.projection(for: .cost)
        XCTAssertTrue(costProj.slices.contains { $0.provider.id == "zai" })
        XCTAssertEqual(try XCTUnwrap(costProj.slices.first?.displayAmount), 0.1895, accuracy: 0.001)

        let tokenProj = totalSpend.projection(for: .tokens)
        XCTAssertTrue(tokenProj.slices.contains { $0.provider.id == "zai" })
        XCTAssertEqual(try XCTUnwrap(tokenProj.slices.first?.displayAmount), 1_200_000)
    }
}

@MainActor
final class ZCodeLayoutTests: XCTestCase {
    func testLayoutSeedsSpendTilesAndPrunesRedundantTokens() throws {
        let suite = "ZCodeLayoutTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let provider = ZAIProvider(zcodeScanner: ZCodeUsageScanner(path: "/missing-zcode-test"))
        let registry = WidgetRegistry(providers: [provider.provider], descriptors: provider.widgetDescriptors)
        let persistence = LayoutPersistence(defaults: defaults, storageKey: "layout")
        persistence.savePlaced([PlacedWidget(descriptorID: "zai.session"), PlacedWidget(descriptorID: "zai.zcodeTokens")])
        persistence.saveExpandedMetrics(["zai.zcodeTokens"])
        let store = LayoutStore(registry: registry, defaults: defaults, storageKey: "layout")
        XCTAssertFalse(store.placed.contains { $0.descriptorID == "zai.zcodeTokens" }, "legacy duplicate zai.zcodeTokens must be pruned")
        XCTAssertTrue(store.placed.contains { $0.descriptorID == "zai.today" })
        XCTAssertTrue(store.expandedMetricIDs.contains("zai.today"))
    }

    func testExpiredPromoIsAutoRemoved() async throws {
        let (sqlitePath, levelDir) = try makeZCodeFixture(
            sqliteRow: "INSERT INTO model_usage VALUES (1000, 500, 'account:zai-start-plan', 1794160000000)",
            entitlementPayload: """
            {"cachedAt":1794254217417,"snapshot":{"quota":{"level":"Start","limits":[{"planId":"zcode-v3-start-plan-1109","period":"one_time","unit":300000000,"usage":30023335,"remaining":269976665,"nextResetTime":1794272400000}]},"subscription":{"details":[{"productId":"zcode-v3-start-plan-1109","productName":"ZCODE GLOBAL BUILD","billingCycle":"one_time","expireTime":"2026-11-10T01:00:00.000Z"}]}}}
            """
        )
        let scanner = ZCodeUsageScanner(path: sqlitePath, leveldbPath: levelDir.path)
        let expiredNow = Date(timeIntervalSince1970: 1794272500)
        let usage = try scanner.usage(now: expiredNow)
        XCTAssertNil(usage?.weekendBuild, "Expired allowance must auto-remove")

        let provider = ZAIProvider(
            zcodeScanner: scanner,
            authStore: ZAIAuthStore(files: FakeFiles(), environment: FakeEnvironment()),
            now: { expiredNow }
        )
        let snapshot = await provider.refresh()
        XCTAssertNil(snapshot.line(label: "Weekend Build"), "Expired allowance line must not be added")
        XCTAssertNil(snapshot.line(label: "Global Build"), "Expired allowance line must not be added")
    }

    func testScheduledPromoIsSurfacedWithStartsAtCountdown() async throws {
        let (sqlitePath, levelDir) = try makeZCodeFixture(
            sqliteRow: "INSERT INTO model_usage VALUES (1000, 500, 'account:zai-start-plan', 1794160000000)",
            entitlementPayload: """
            {"cachedAt":1794317209046,"snapshot":{"quota":{"level":"Start","limits":[]},"subscription":{"details":[{"productId":"zcode-v3-start-plan-1110-nt","productName":"ZCODE GLOBAL BUILD","billingCycle":"one_time","expireTime":"2026-11-11T01:00:00.000Z","entitlements":[{"entitlementId":"ent-1","showName":"GLM-5.3-Flash","effectiveTime":"2026-11-10T15:00:00.000Z"}]}]}}}
            """
        )
        let scanner = ZCodeUsageScanner(path: sqlitePath, leveldbPath: levelDir.path)
        let currentNow = Date(timeIntervalSince1970: 1794317209)
        let usage = try scanner.usage(now: currentNow)
        XCTAssertNotNil(usage?.weekendBuild)
        XCTAssertEqual(usage?.weekendBuild?.label, "Global Build")
        XCTAssertEqual(usage?.weekendBuild?.limit, 500_000_000)
        XCTAssertEqual(usage?.weekendBuild?.used, 0)
        XCTAssertEqual(usage?.weekendBuild?.remaining, 500_000_000)
        XCTAssertEqual(usage?.weekendBuild?.effectiveAt, OpenUsageISO8601.date(from: "2026-11-10T15:00:00.000Z"))

        let provider = ZAIProvider(
            zcodeScanner: scanner,
            authStore: ZAIAuthStore(files: FakeFiles(), environment: FakeEnvironment()),
            now: { currentNow }
        )
        let snapshot = await provider.refresh()
        guard let line = snapshot.line(label: "Weekend Build") else {
            return XCTFail("Expected line matching Weekend Build descriptor")
        }
        guard case .progress(let label, let used, let limit, _, let resetsAt, _, _, let detail) = line else {
            return XCTFail("Line is not progress")
        }
        XCTAssertEqual(label, "Global Build")
        XCTAssertEqual(used, 0)
        XCTAssertEqual(limit, 500_000_000)
        // The persisted deadline is the grant's END (expireTime), not its start — the store's
        // expiry sweep retires the row against this stamp, so a start date could never expire it.
        XCTAssertEqual(resetsAt, OpenUsageISO8601.date(from: "2026-11-11T01:00:00.000Z"))
        XCTAssertTrue(detail?.hasPrefix("Starts") == true, "Scheduled promo must show Starts countdown: \(detail ?? "")")
    }
}

/// Shared fixture for the entitlement scan: a minimal sqlite usage database plus a LevelDB
/// directory holding one entitlement key whose record value wraps the given JSON snapshot body
/// (the framing prefix mimics the real record's `["hash",…]:auth:…` wrapper).
func makeZCodeFixture(sqliteRow: String, entitlementPayload: String) throws -> (sqlitePath: String, levelDir: URL) {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("quotabar-zcode-fixture-\(UUID().uuidString)")
    let dbDir = tempDir.appendingPathComponent("db")
    let levelDir = tempDir.appendingPathComponent("leveldb")
    try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: levelDir, withIntermediateDirectories: true)

    let sqlitePath = dbDir.appendingPathComponent("db.sqlite").path
    try NativeSQLiteAccessor().execute(path: sqlitePath, sql: """
        CREATE TABLE model_usage (input_tokens INTEGER, output_tokens INTEGER, provider_id TEXT, started_at INTEGER);
        \(sqliteRow);
        """)
    let payload = """
    zcode:usage-entitlement:subscription-v2:account:zai-start-plan:["hash",{"providerId":"account:zai-start-plan"}]:auth:1\u{0001}\(entitlementPayload)
    """
    try Data(payload.utf8).write(to: levelDir.appendingPathComponent("000001.log"))
    return (sqlitePath, levelDir)
}
