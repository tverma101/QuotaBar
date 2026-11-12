import XCTest
@testable import QuotaBar

@MainActor
final class VMBoxUsageHistoryTests: XCTestCase {
    private var directory: URL!
    private let now = Date()

    override func setUpWithError() throws {
        directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/tmp/vmbox-quotabar-tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        let trash = Process()
        trash.executableURL = URL(fileURLWithPath: "/usr/bin/trash")
        trash.arguments = [directory.path]
        try trash.run()
        trash.waitUntilExit()
        XCTAssertEqual(trash.terminationStatus, 0)
    }

    private func write(tokens: Int = 30, providers: [String] = ["zai"],
                       accounts: [String: String] = [:], age: TimeInterval = 0,
                       filename: String = "vmbox-fixture.json") throws {
        let day = DailyUsageAccumulator.dayKey(from: now)
        let history: [String: Any] = [
            "series": ["daily": [["date": day, "totalTokens": tokens, "costIsComplete": false]]],
            "unknownModelsByDay": [day: ["glm"]]
        ]
        let data: [String: Any] = [
            "schema": "openusage.history.v1", "deviceID": "vmbox-fixture", "deviceName": "VM Box",
            "updatedAt": OpenUsageISO8601.string(from: now.addingTimeInterval(-age)),
            "providers": Dictionary(uniqueKeysWithValues: providers.map { ($0, history) }),
            "vmboxAccounts": accounts
        ]
        try JSONSerialization.data(withJSONObject: data).write(to: directory.appendingPathComponent(filename), options: .atomic)
    }

    func testDailyImportContainsNoInventedDollars() throws {
        try write(providers: ["zai", "opencode", "antigravity"])
        let result = VMBoxUsageHistory(directory: directory).load(identityKeys: [:],
            providerIDs: ["zai", "opencode", "antigravity"], now: now)
        XCTAssertEqual(result.documents.count, 1)
        XCTAssertEqual(result.documents[0].providers.count, 3)
        XCTAssertEqual(result.documents[0].providers["zai"]?.series.daily.first?.totalTokens, 30)
        XCTAssertNil(result.documents[0].providers["zai"]?.series.daily.first?.costUSD)
    }

    func testAccountScopedUsageOnlyGoesToMatchingCard() throws {
        try write(providers: ["claude", "codex"], accounts: ["claude": "work", "codex": "codex-work"])
        let result = VMBoxUsageHistory(directory: directory).load(
            identityKeys: ["claude": "personal", "claude@1234abcd": "WORK", "codex@aabbccdd": "codex-work"],
            providerIDs: ["claude", "claude@1234abcd", "codex@aabbccdd"], now: now)
        let document = try XCTUnwrap(result.documents.first)
        XCTAssertNil(document.providers["claude"])
        XCTAssertNotNil(document.providers["claude@1234abcd"])
        XCTAssertNotNil(document.providers["codex@aabbccdd"])
    }

    func testMissingAccountIdentityDoesNotMixUsage() throws {
        try write(providers: ["codex", "claude"])
        let result = VMBoxUsageHistory(directory: directory).load(identityKeys: ["codex": "personal"],
            providerIDs: ["codex", "claude"], now: now)
        XCTAssertTrue(result.documents.isEmpty)
        XCTAssertNotNil(result.warnings["codex"])
        XCTAssertNotNil(result.warnings["claude"])
    }

    func testOfflineAndCorruptReplacementRetainLastGoodReceipt() throws {
        try write(age: 600)
        let reader = VMBoxUsageHistory(directory: directory)
        let first = reader.load(identityKeys: [:], providerIDs: ["zai"], now: now)
        XCTAssertNotNil(first.warnings["zai"])
        try Data("{invalid".utf8).write(to: directory.appendingPathComponent("vmbox-fixture.json"), options: .atomic)
        let second = reader.load(identityKeys: [:], providerIDs: ["zai"], now: now)
        XCTAssertEqual(first.documents, second.documents)
        XCTAssertNotNil(second.warnings["zai"])
    }

    func testDuplicateDeviceFilesUseNewestWholeReceipt() throws {
        try write(tokens: 10, age: 60, filename: "vmbox-old.json")
        try write(tokens: 30, filename: "vmbox-new.json")
        let result = VMBoxUsageHistory(directory: directory).load(identityKeys: [:], providerIDs: ["zai"], now: now)
        XCTAssertEqual(result.documents.count, 1)
        XCTAssertEqual(result.documents[0].providers["zai"]?.series.daily.first?.totalTokens, 30)
    }

    func testAccountWideProviderIsNeverImported() throws {
        try write(providers: ["cursor"])
        XCTAssertTrue(VMBoxUsageHistory(directory: directory)
            .load(identityKeys: [:], providerIDs: ["cursor"], now: now).documents.isEmpty)
    }

    func testFutureAndNegativeDataAreRejected() throws {
        try write(tokens: -2)
        let reader = VMBoxUsageHistory(directory: directory)
        XCTAssertTrue(reader.load(identityKeys: [:], providerIDs: ["zai"], now: now).documents.isEmpty)
        try write(age: -1000)
        XCTAssertTrue(reader.load(identityKeys: [:], providerIDs: ["zai"], now: now).documents.isEmpty)
    }

    func testStoreAddsVMHistoryOnceAndPreservesQuotaAndLocalExport() throws {
        try write()
        let provider = Provider(id: "zai", displayName: "Z.ai", icon: .providerMark("zai"))
        let descriptor = WidgetDescriptor.usageTrend(provider: provider)
            .exportingHistory(scope: .machineLocal, estimatedCost: false, sourceNote: "accounting")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "vmbox-tests-\(UUID().uuidString)"))
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots")
        let meter = MetricLine.progress(label: "Session", used: 18, limit: 100, format: .percent)
        cache.store(ProviderSnapshot(providerID: "zai", displayName: "Z.ai", lines: [meter], usageHistory:
            ProviderUsageHistory(series: .init(daily: [.init(date: DailyUsageAccumulator.dayKey(from: now), totalTokens: 20, costUSD: nil)]))))
        let store = WidgetDataStore(registry: .init(providers: [provider], descriptors: [descriptor]),
            providers: [], cache: cache, defaults: defaults, now: { self.now }, vmBoxHistoryDirectory: directory)
        XCTAssertEqual(store.snapshots["zai"]?.usageHistory?.series.daily.first?.totalTokens, 50)
        XCTAssertTrue(store.snapshots["zai"]?.lines.contains(meter) == true)
        store.setPeerHistoryDocuments([], ownDeviceID: "this-mac")
        XCTAssertEqual(store.snapshots["zai"]?.usageHistory?.series.daily.first?.totalTokens, 50)
        XCTAssertEqual(store.localHistoryDocument(deviceID: "this-mac", deviceName: "This Mac", updatedAt: now)
            .providers["zai"]?.series.daily.first?.totalTokens, 20)
        try write(tokens: 40)
        store.setPeerHistoryDocuments([], ownDeviceID: "this-mac")
        XCTAssertEqual(store.snapshots["zai"]?.usageHistory?.series.daily.first?.totalTokens, 60)
    }

    func testLegacyZCodeTokensTileKeepsItsExistingMetric() throws {
        try write()
        let provider = Provider(id: "zai", displayName: "Z.ai", icon: .providerMark("zai"))
        let descriptor = WidgetDescriptor.values(id: "zai.zcodeTokens", provider: provider, title: "ZCode Tokens",
                                                 metricLabel: "ZCode Tokens", selection: .kind(.count))
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "vmbox-tests-\(UUID().uuidString)"))
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots")
        cache.store(ProviderSnapshot(providerID: "zai", displayName: "Z.ai", lines: [
            .values(label: "ZCode Tokens", values: [.init(number: 20, kind: .count)])
        ]))
        let store = WidgetDataStore(registry: .init(providers: [provider], descriptors: [descriptor]),
            providers: [], cache: cache, defaults: defaults, now: { self.now }, vmBoxHistoryDirectory: directory)
        func tokens() -> Double? {
            guard case let .values(_, values, _, _, _, _) = store.snapshots["zai"]?.lines.first else { return nil }
            return values.first?.number
        }
        XCTAssertEqual(tokens(), 50)
        store.setPeerHistoryDocuments([], ownDeviceID: "this-mac")
        XCTAssertEqual(tokens(), 50)
    }
}
