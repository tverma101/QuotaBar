import XCTest
@testable import QuotaBar

final class ZCodeUsageScannerTests: XCTestCase {
    func testCountsInputAndOutputWithoutAddingCachedTokensAgain() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("quotabar-zcode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("db.sqlite").path
        try SQLiteCLIAccessor().execute(path: path, sql: """
            CREATE TABLE model_usage (input_tokens INTEGER, output_tokens INTEGER,
                                      cache_read_input_tokens INTEGER, cache_creation_input_tokens INTEGER);
            INSERT INTO model_usage VALUES (100, 20, 70, 10), (40, 5, 20, 0), (0, 0, 0, 0);
            """)
        let scanner = ZCodeUsageScanner(path: path)
        XCTAssertTrue(scanner.hasHistory())
        XCTAssertEqual(try scanner.totalTokens(), 165)
    }

    func testMissingDatabaseIsNotCreated() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let scanner = ZCodeUsageScanner(path: path)
        XCTAssertFalse(scanner.hasHistory())
        XCTAssertNil(try scanner.totalTokens())
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testInvalidTokenCountsAreReported() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try SQLiteCLIAccessor().execute(path: path, sql: """
            CREATE TABLE model_usage (input_tokens INTEGER, output_tokens INTEGER);
            INSERT INTO model_usage VALUES (100, 20), (-1, 2);
            """)
        XCTAssertThrowsError(try ZCodeUsageScanner(path: path).totalTokens())
    }

    func testIncompatibleDatabaseThrows() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try SQLiteCLIAccessor().execute(path: path, sql: "CREATE TABLE other (id INTEGER);")
        XCTAssertThrowsError(try ZCodeUsageScanner(path: path).totalTokens())
    }
}

@MainActor
final class ZCodeProviderIntegrationTests: XCTestCase {
    func testLocalUsageRemainsAvailableWithoutCodingPlanKey() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try SQLiteCLIAccessor().execute(path: path, sql: """
            CREATE TABLE model_usage (input_tokens INTEGER, output_tokens INTEGER);
            INSERT INTO model_usage VALUES (100, 20);
            """)
        let provider = ZAIProvider(
            zcodeScanner: ZCodeUsageScanner(path: path),
            authStore: ZAIAuthStore(files: FakeFiles(), environment: FakeEnvironment())
        )
        let detected = await provider.hasLocalCredentials()
        let snapshot = await provider.refresh()
        XCTAssertTrue(detected)
        XCTAssertNotNil(snapshot.warning)
        XCTAssertEqual(snapshot.quotaRefreshedAt, .distantPast)
        guard case .values(_, let values, _, _, _, _) = snapshot.line(label: "ZCode Tokens") else {
            return XCTFail("Missing local token total")
        }
        XCTAssertEqual(values.first?.number, 120)
    }
}

@MainActor
final class ZCodeLayoutTests: XCTestCase {
    func testExistingLayoutSeedsOnDemandOnlyOnce() throws {
        let suite = "ZCodeLayoutTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let provider = ZAIProvider(zcodeScanner: ZCodeUsageScanner(path: "/missing-zcode-test"))
        let registry = WidgetRegistry(providers: [provider.provider], descriptors: provider.widgetDescriptors)
        let persistence = LayoutPersistence(defaults: defaults, storageKey: "layout")
        persistence.savePlaced([PlacedWidget(descriptorID: "zai.session")])
        persistence.saveExpandOnEnable([])
        let store = LayoutStore(registry: registry, defaults: defaults, storageKey: "layout")
        XCTAssertFalse(store.placed.contains { $0.descriptorID == "zai.zcodeTokens" })
        store.setMetricEnabled("zai.zcodeTokens", true)
        XCTAssertTrue(store.expandedMetricIDs.contains("zai.zcodeTokens"))
        store.expandedMetricIDs.remove("zai.zcodeTokens")
        store.persistExpanded()
        store.setMetricEnabled("zai.zcodeTokens", false)
        let reloaded = LayoutStore(registry: registry, defaults: defaults, storageKey: "layout")
        reloaded.setMetricEnabled("zai.zcodeTokens", true)
        XCTAssertFalse(reloaded.expandedMetricIDs.contains("zai.zcodeTokens"))
    }
}
