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
        guard case .progress(_, let used, let limit, let format, _, _, _, _) = weekendLine else {
            return XCTFail("Weekend Build line is not a progress line")
        }
        XCTAssertEqual(used, 194_069_327)
        XCTAssertEqual(limit, 500_000_000)
        XCTAssertEqual(format, ProgressFormat.count(suffix: "tokens"), "Weekend Build MUST NOT be formatted as percentage")

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
}
