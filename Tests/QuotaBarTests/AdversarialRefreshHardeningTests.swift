import Foundation
import UserNotifications
import XCTest
@testable import QuotaBar

/// Adversarial follow-ups after the menuBar merge / force-wait fixes (sha 0beab021).
@MainActor
final class AdversarialRefreshHardeningTests: XCTestCase {

    // MARK: - A) UNUserNotificationCenter crash guard

    func testUserNotificationsRequireAppBundlePredicateIsSafe() {
        // Production `.app` launches satisfy this; naked binaries / missing bundle id must not
        // call `UNUserNotificationCenter.current()` (Sep 22 SIGABRT cold.2).
        _ = AppNotifications.canUseUserNotifications
        if Bundle.main.bundleIdentifier == nil {
            XCTAssertFalse(AppNotifications.canUseUserNotifications)
        }
    }

    func testRegisterAsDelegateNeverTouchesCenterUnderTests() {
        let probe = CenterProbe()
        let notifications = AppNotifications(centerProvider: {
            probe.touched = true
            return UNUserNotificationCenter.current()
        })
        notifications.registerAsDelegate()
        XCTAssertFalse(probe.touched)
    }

    // MARK: - B) Routine unload must not force router full reparse

    func testUnloadAfterRefreshCycleKeepsRouterTailItemsForAppend() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OU-RouterTail-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ledger = directory.appendingPathComponent("usage-events.jsonl")

        let accountID = "1118f6f1-8697-4e7b-9112-1771b3e36099"
        let fingerprint = try XCTUnwrap(CodexProxyUsageScanner.accountFingerprint(for: accountID))
        let pricing = ModelPricing(
            supplement: PricingSupplement(),
            primary: PricingCatalog(entries: [
                "gpt-5.6-terra": ModelRates(
                    inputPerMillion: 1_000,
                    outputPerMillion: 3_000,
                    cacheWritePerMillion: 1_000,
                    cacheReadPerMillion: 100
                )
            ]),
            secondary: PricingCatalog(entries: [:])
        )
        let now = try XCTUnwrap(OpenUsageISO8601.date(from: "2026-09-03T12:00:00.000Z"))

        func line(at: String, tokens: Int) -> String {
            let object: [String: Any] = [
                "at": at,
                "model": "gpt-5.6-terra",
                "provider": "openai",
                "status": 200,
                "inputTokens": tokens,
                "cachedInputTokens": 0,
                "outputTokens": 0,
                "reasoningTokens": 0,
                "totalTokens": tokens,
                "accountFingerprint": fingerprint,
                "accountId": accountID
            ]
            let data = try! JSONSerialization.data(withJSONObject: object)
            return String(decoding: data, as: UTF8.self)
        }

        try Data((line(at: "2026-09-02T15:00:00.000Z", tokens: 100) + "\n").utf8).write(to: ledger)

        let scanner = CodexRouterUsageScanner(
            ledgerPaths: { [ledger.path] },
            identityAliases: { [:] }
        )
        let first = await scanner.scan(
            accountIdentityKey: accountID,
            allowsUnscopedEvents: false,
            daysBack: 30,
            now: now,
            pricing: pricing
        )
        XCTAssertNotNil(first)
        let afterFirst = try XCTUnwrap(CodexRouterUsageScanner.incrementalReadStatisticsForTesting(path: ledger.path))
        XCTAssertEqual(afterFirst.fullParses, 1)

        // Routine post-cycle unload must NOT clear router items (that forced full reparse on open).
        await PersistentJSONLScanCaches.unloadAfterRefreshCycle()

        let handle = try FileHandle(forWritingTo: ledger)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line(at: "2026-09-02T16:00:00.000Z", tokens: 50) + "\n").utf8))
        try handle.close()

        let second = await scanner.scan(
            accountIdentityKey: accountID,
            allowsUnscopedEvents: false,
            daysBack: 30,
            now: now,
            pricing: pricing
        )
        XCTAssertNotNil(second)
        let afterSecond = try XCTUnwrap(CodexRouterUsageScanner.incrementalReadStatisticsForTesting(path: ledger.path))
        XCTAssertEqual(afterSecond.fullParses, 1, "routine unload must not force a second full parse")
        XCTAssertEqual(afterSecond.tailParses, 1, "append after routine unload should tail-parse")
    }

    // MARK: - C) Cursor transport failure keeps last-good meters (menuBar)

    func testFailedRefreshKeepsLastGoodMetersUnderMenuBarScope() async {
        let provider = Provider(id: "cursor", displayName: "Cursor", icon: .providerMark("cursor"))
        let meter = WidgetDescriptor(
            id: "cursor.auto",
            providerID: provider.id,
            metricLabel: "Cursor Models",
            sample: WidgetData(title: "Cursor Models", icon: provider.icon, kind: .percent, used: 0, limit: 100)
        )
        let runtime = SequenceProviderRuntime(
            provider: provider,
            descriptors: [meter],
            snapshots: [
                ProviderSnapshot(
                    providerID: provider.id,
                    displayName: provider.displayName,
                    plan: "Pro",
                    lines: [.progress(label: "Cursor Models", used: 42, limit: 100, format: .percent)]
                ),
                ProviderSnapshot.error(provider: provider, message: "Usage request failed. Check your connection.")
            ]
        )
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [meter]),
            providers: [runtime],
            defaults: makeUserDefaults("cursor-menubar-keep"),
            pinnedMetricIDs: { ["cursor.auto"] }
        )

        // Seed last-good, then fail under .menuBar. Error snapshots return before merge, so the
        // strip keeps Session/plan from localSnapshots (same path menuBar and full share).
        await store.refreshAll(force: true)
        XCTAssertEqual(store.data(for: meter).used, 42)
        XCTAssertEqual(store.snapshots[provider.id]?.plan, "Pro")

        await ProviderRefreshContext.$scope.withValue(.menuBar) {
            await store.refreshAll(force: true)
        }
        XCTAssertEqual(store.data(for: meter).used, 42, "failed menuBar must keep last-good meters")
        XCTAssertEqual(store.snapshots[provider.id]?.plan, "Pro")
        XCTAssertEqual(store.errorMessage(for: provider.id), "Usage request failed. Check your connection.")
    }

    // MARK: - D) Memory-pressure unload waits for in-flight refresh

    func testMemoryPressureHandlerDefersWhileShouldDeferIsTrue() async {
        let unloaded = expectation(description: "unload ran after defer cleared")
        let gate = DeferGate(deferring: true)
        let handler = AppContainer.makeMemoryPressureHandler(
            unload: { unloaded.fulfill() },
            shouldDefer: { await gate.isDeferring() }
        )
        handler()
        try? await Task.sleep(for: .milliseconds(250))
        let checksWhileDeferred = await gate.checks
        XCTAssertGreaterThan(checksWhileDeferred, 0, "handler should poll shouldDefer while blocked")
        await gate.setDeferring(false)
        await fulfillment(of: [unloaded], timeout: 5)
    }

    // MARK: - Session discovery: no whole-home walk when sessions dirs missing

    func testSessionFilesSkipsHomesWithoutSessionsDirectories() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OU-NoSessions-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let plugins = directory.appendingPathComponent("plugins", isDirectory: true)
        try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: plugins.appendingPathComponent("decoy.jsonl"))

        let files = CodexLogUsageScanner.sessionFiles(homes: [directory])
        XCTAssertTrue(
            files.isEmpty,
            "homes without sessions/archived_sessions must not fall back to walking CODEX_HOME"
        )
    }

    // MARK: - Helpers

    private func makeUserDefaults(_ name: String) -> UserDefaults {
        let suiteName = "OpenUsageTests.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private final class CenterProbe: @unchecked Sendable {
        var touched = false
    }

    private actor DeferGate {
        private var deferring: Bool
        private(set) var checks = 0
        init(deferring: Bool) { self.deferring = deferring }
        func isDeferring() -> Bool {
            checks += 1
            return deferring
        }
        func setDeferring(_ value: Bool) { deferring = value }
    }
}
