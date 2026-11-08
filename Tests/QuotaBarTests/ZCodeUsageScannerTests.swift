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
        try SQLiteCLIAccessor().execute(path: path, sql: """
            CREATE TABLE model_usage (input_tokens INTEGER, output_tokens INTEGER, provider_id TEXT, started_at INTEGER);
            INSERT INTO model_usage VALUES (100, 20, 'account:zai-start-plan', 1000);
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
        try SQLiteCLIAccessor().execute(path: path, sql: """
            CREATE TABLE model_usage (input_tokens INTEGER, output_tokens INTEGER, provider_id TEXT, started_at INTEGER);
            INSERT INTO model_usage VALUES (100, 20, 'account:zai-start-plan', 1000);
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
        XCTAssertEqual(snapshot.quotaRefreshedAt, .distantPast)
        guard case .values(_, let values, _, _, _, _) = snapshot.line(label: "ZCode Tokens") else {
            return XCTFail("Missing local token total")
        }
        XCTAssertEqual(values.first?.number, 120)
    }
}

@MainActor
final class ZCodeLayoutTests: XCTestCase {
    func testLayoutSeedsZCodeTokens() throws {
        let suite = "ZCodeLayoutTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let provider = ZAIProvider(zcodeScanner: ZCodeUsageScanner(path: "/missing-zcode-test"))
        let registry = WidgetRegistry(providers: [provider.provider], descriptors: provider.widgetDescriptors)
        let persistence = LayoutPersistence(defaults: defaults, storageKey: "layout")
        persistence.savePlaced([PlacedWidget(descriptorID: "zai.session")])
        persistence.saveExpandOnEnable(["zai.zcodeTokens"])
        let store = LayoutStore(registry: registry, defaults: defaults, storageKey: "layout")
        XCTAssertTrue(store.placed.contains { $0.descriptorID == "zai.zcodeTokens" })
        XCTAssertTrue(store.expandedMetricIDs.contains("zai.zcodeTokens"))
    }
}
