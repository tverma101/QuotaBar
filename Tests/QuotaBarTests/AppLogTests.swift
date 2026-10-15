import XCTest
@testable import QuotaBar

/// Covers the crux of #604: the user's log level is a single floor that decides what actually reaches
/// the file sink. The sink is pointed at a per-test temp file so we can read back exactly what the gate
/// wrote. `AppLog.reloadLevel(_:)` applies a level without touching `UserDefaults.standard`, so these
/// tests never race on global state.
final class AppLogTests: XCTestCase {
    private var tempDir: URL!
    private var sink: LogFile!
    private var originalSink: LogFile!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsageTests.AppLog.\(UUID().uuidString)", isDirectory: true)
        sink = LogFile(directory: tempDir, fileName: "OpenUsage.log")
        sink.open()
        originalSink = AppLog.sink
        AppLog.sink = sink
    }

    override func tearDownWithError() throws {
        AppLog.sink = originalSink
        AppLog.reloadLevel() // restore the real persisted floor for any later code
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.removeItem(at: tempDir)
        }
    }

    private func fileContents() throws -> String {
        try String(contentsOf: tempDir.appendingPathComponent("OpenUsage.log"), encoding: .utf8)
    }

    func testInfoFloorSuppressesDebugButKeepsInfoAndError() throws {
        AppLog.reloadLevel(.info)
        AppLog.debug(.cache, "debug-below-floor")
        AppLog.info(.refresh, "info-at-floor")
        AppLog.error(.http, "error-always")

        let contents = try fileContents()
        XCTAssertFalse(contents.contains("debug-below-floor"), contents)
        XCTAssertTrue(contents.contains("info-at-floor"), contents)
        XCTAssertTrue(contents.contains("error-always"), contents)
    }

    func testDebugFloorLetsDebugThrough() throws {
        AppLog.reloadLevel(.debug)
        AppLog.debug(.cache, "debug-now-visible")
        XCTAssertTrue(try fileContents().contains("debug-now-visible"))
    }

    func testErrorFloorSuppressesEverythingButError() throws {
        AppLog.reloadLevel(.error)
        AppLog.warn(.http, "warn-below-error-floor")
        AppLog.info(.refresh, "info-below-error-floor")
        AppLog.error(.http, "error-still-written")

        let contents = try fileContents()
        XCTAssertFalse(contents.contains("warn-below-error-floor"), contents)
        XCTAssertFalse(contents.contains("info-below-error-floor"), contents)
        XCTAssertTrue(contents.contains("error-still-written"), contents)
    }

    func testWrittenLineCarriesLevelAndTag() throws {
        AppLog.reloadLevel(.info)
        AppLog.info(.refresh, "hello")
        // Grep-friendly shape: `<timestamp> [INFO] [refresh] hello`.
        let contents = try fileContents()
        XCTAssertTrue(contents.contains("[INFO] [refresh] hello"), contents)
    }

    func testAutoclosureIsNotEvaluatedBelowFloor() {
        AppLog.reloadLevel(.info)
        var built = false
        // `@autoclosure` wraps this call; the side effect fires only if `emit` actually builds the message.
        func expensiveMessage() -> String {
            built = true
            return "expensive"
        }
        AppLog.debug(.cache, expensiveMessage())
        XCTAssertFalse(built, "a below-floor debug line must not build its message")
    }

    func testSecretInLineIsRedactedBeforeWrite() throws {
        AppLog.reloadLevel(.info)
        AppLog.info(.auth, "refreshing with token=sk-1234567890abcdefghij")
        let contents = try fileContents()
        XCTAssertFalse(contents.contains("sk-1234567890abcdefghij"), contents)
    }

    @MainActor
    func testSlowProviderRefreshWritesWarningAtDefaultLogLevel() async throws {
        AppLog.reloadLevel(.info)
        let provider = Provider(id: "slow-test", displayName: "Slow Test", icon: .providerMark("codex"))
        let runtime = TestProviderRuntime(
            provider: provider,
            descriptors: [],
            snapshot: ProviderSnapshot(providerID: provider.id, displayName: provider.displayName, lines: [])
        )
        let defaultsName = "OpenUsageTests.AppLog.slow.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        var ticks = [100.0, 112.5]
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: []),
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots"),
            defaults: defaults,
            monotonicNow: { ticks.removeFirst() }
        )

        _ = await store.refresh(providerID: provider.id, force: true)

        let contents = try fileContents()
        XCTAssertTrue(
            contents.contains("[WARN] [refresh] slow-test slow refresh (12500ms, threshold=10000ms)"),
            contents
        )
    }

    @MainActor
    func testRepeatedScheduledProviderFailureLogIsDeduplicatedUntilForcedRetry() async throws {
        AppLog.reloadLevel(.info)
        let provider = Provider(id: "keychain-spam-test", displayName: "Keychain Spam Test", icon: .providerMark("codex"))
        let message = "macOS needs permission to read this Keychain item."
        let runtime = TestProviderRuntime(
            provider: provider,
            descriptors: [],
            snapshot: ProviderSnapshot.error(
                provider: provider,
                message: message,
                category: .credentialAccess
            )
        )
        let suiteName = "OpenUsageTests.AppLog.keychainSpam.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let registry = WidgetRegistry(providers: [provider], descriptors: [])
        let store = WidgetDataStore(
            registry: registry,
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots"),
            defaults: defaults,
            now: { now },
            monotonicNow: { 0 }
        )

        _ = await store.refresh(providerID: provider.id, force: true)
        now.addTimeInterval(61)
        _ = await store.refresh(providerID: provider.id, force: false)
        _ = await store.refresh(providerID: provider.id, force: true)

        let failureLines = try fileContents().components(separatedBy: .newlines).filter {
            $0.contains("[WARN] [refresh] keychain-spam-test failed: \(message)")
        }
        XCTAssertEqual(failureLines.count, 2, "scheduled retries dedupe; an explicit force retry is logged")
    }
}
