import XCTest
@testable import QuotaBar

final class ZCodeUsageScannerTests: XCTestCase {
    func testCountsInputAndOutputWithoutAddingCachedTokensAgain() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("quotabar-zcode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("db.sqlite").path
        try SQLiteCLIAccessor().execute(path: path, sql: """
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
        let scanner = ZCodeUsageScanner(path: path)
        XCTAssertFalse(scanner.hasHistory())
        XCTAssertNil(try scanner.totalTokens())
        XCTAssertNil(try scanner.usage())
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testInvalidTokenCountsAreReported() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try SQLiteCLIAccessor().execute(path: path, sql: """
            CREATE TABLE model_usage (input_tokens INTEGER, output_tokens INTEGER, provider_id TEXT, started_at INTEGER);
            INSERT INTO model_usage VALUES (100, 20, 'account:zai-start-plan', 1000), (-1, 2, 'account:zai-start-plan', 1001);
            """)
        XCTAssertThrowsError(try ZCodeUsageScanner(path: path).totalTokens())
    }

    func testIncompatibleDatabaseThrows() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try SQLiteCLIAccessor().execute(path: path, sql: "CREATE TABLE other (id INTEGER);")
        XCTAssertThrowsError(try ZCodeUsageScanner(path: path).totalTokens())
    }

    func testTotalTokensCachesAndUnloadsForMemoryPressure() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("quotabar-zcode-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("db.sqlite").path
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        try SQLiteCLIAccessor().execute(path: path, sql: """
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
        try SQLiteCLIAccessor().execute(path: path, sql: """
            CREATE TABLE model_usage (input_tokens INTEGER, output_tokens INTEGER, provider_id TEXT, started_at INTEGER);
            INSERT INTO model_usage VALUES (500, 100, 'account:zai-coding-plan', 2000);
            """)
        let scanner = ZCodeUsageScanner(path: path)
        let usage = try scanner.usage()
        XCTAssertEqual(usage?.totalTokens, 600)
        XCTAssertEqual(usage?.planName, "Coding Plan")
    }
}

@MainActor
final class ZCodeProviderIntegrationTests: XCTestCase {
    func testLocalUsageRemainsAvailableWithoutCodingPlanKey() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        try SQLiteCLIAccessor().execute(path: path, sql: """
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
        try SQLiteCLIAccessor().execute(path: sqlitePath, sql: """
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
    }

    func testParsesWeekendBuildAllowanceWithoutPercentage() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("quotabar-zcode-wk-\(UUID().uuidString)")
        let dbDir = tempDir.appendingPathComponent("db")
        let levelDir = tempDir.appendingPathComponent("leveldb")
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: levelDir, withIntermediateDirectories: true)

        let sqlitePath = dbDir.appendingPathComponent("db.sqlite").path
        try SQLiteCLIAccessor().execute(path: sqlitePath, sql: """
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
        guard case .progress(_, let used, let limit, let format, _, _, _, let detail) = weekendLine else {
            return XCTFail("Weekend Build line is not a progress line")
        }
        XCTAssertEqual(used, 194_069_327)
        XCTAssertEqual(limit, 500_000_000)
        XCTAssertEqual(format, ProgressFormat.count(suffix: "tokens"), "Weekend Build MUST NOT be formatted as percentage")
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
        try SQLiteCLIAccessor().execute(path: path, sql: """
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
        XCTAssertEqual(resetsAt, OpenUsageISO8601.date(from: "2026-11-10T15:00:00.000Z"))
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
    try SQLiteCLIAccessor().execute(path: sqlitePath, sql: """
        CREATE TABLE model_usage (input_tokens INTEGER, output_tokens INTEGER, provider_id TEXT, started_at INTEGER);
        \(sqliteRow);
        """)
    let payload = """
    zcode:usage-entitlement:subscription-v2:account:zai-start-plan:["hash",{"providerId":"account:zai-start-plan"}]:auth:1\u{0001}\(entitlementPayload)
    """
    try Data(payload.utf8).write(to: levelDir.appendingPathComponent("000001.log"))
    return (sqlitePath, levelDir)
}
