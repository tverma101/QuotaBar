import XCTest
@testable import QuotaBar

/// The Swift side of the Rust engine bridge. Provider behavior itself is tested in Rust
/// (`Rust/quotabar-engine`, `cargo test`); these tests pin the JSON contract and the C ABI round trip.
final class RustEngineBridgeTests: XCTestCase {
    /// Exactly what the engine emits for a successful Devin refresh (see the Rust test
    /// `snapshot_serializes_like_swift`).
    private let devinSnapshotJSON = """
    {"ok":{"providerID":"devin","displayName":"Devin","plan":"Max","lines":[\
    {"type":"progress","label":"Daily quota","used":0.0,"limit":100.0,"format":{"kind":"percent"},"resetsAt":1774080000.0,"periodDurationMs":86400000},\
    {"type":"progress","label":"Weekly quota","used":60.0,"limit":100.0,"format":{"kind":"percent"},"resetsAt":1774166400.0,"periodDurationMs":604800000},\
    {"type":"values","label":"Extra usage balance","values":[{"number":964.22,"kind":"dollars","estimated":false}]}],\
    "refreshedAt":1773000000.0,"quotaRefreshedAt":1773000000.0}}
    """

    private struct Reply: Decodable { let ok: ProviderSnapshot }

    func testEngineSnapshotDecodesIntoTheSwiftModel() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let snapshot = try decoder.decode(Reply.self, from: Data(devinSnapshotJSON.utf8)).ok

        XCTAssertEqual(snapshot.providerID, "devin")
        XCTAssertEqual(snapshot.plan, "Max")
        XCTAssertEqual(snapshot.refreshedAt, Date(timeIntervalSince1970: 1_773_000_000))
        XCTAssertEqual(snapshot.quotaRefreshedAt, Date(timeIntervalSince1970: 1_773_000_000))
        XCTAssertNil(snapshot.errorCategory)
        guard case .progress(let label, let used, let limit, let format, let resetsAt, let period, _, _) = snapshot.lines[1] else {
            return XCTFail("weekly line is not a progress line: \(snapshot.lines[1])")
        }
        XCTAssertEqual(label, "Weekly quota")
        XCTAssertEqual(used, 60)
        XCTAssertEqual(limit, 100)
        XCTAssertEqual(format, .percent)
        XCTAssertEqual(resetsAt, Date(timeIntervalSince1970: 1_774_166_400))
        XCTAssertEqual(period, MetricPeriod.weekMs)
        guard case .values(let valuesLabel, let values, _, _, _, _) = snapshot.lines[2] else {
            return XCTFail("balance line is not a values line: \(snapshot.lines[2])")
        }
        XCTAssertEqual(valuesLabel, "Extra usage balance")
        XCTAssertEqual(values.first?.kind, .dollars)
        XCTAssertEqual(values.first?.number ?? 0, 964.22, accuracy: 0.0001)
    }

    @MainActor
    func testBatch3AProvidersRoundTripThroughTheEngine() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuotaBarTests.RustEngine.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        RustEngine.prepare()
        _ = await RustEngine.call(["method": "configure", "params": ["home": home.path, "appData": home.path]])
        defer {
            try? FileManager.default.removeItem(at: home)
        }

        let devin = DevinProvider()
        let hermes = HermesProvider()
        let grok = GrokProvider()
        let copilot = CopilotProvider()
        let openRouter = OpenRouterProvider()

        let devinDetected = await devin.hasLocalCredentials()
        let devinSnapshot = await devin.refresh()
        let hermesDetected = await hermes.hasLocalCredentials()
        let hermesSnapshot = await hermes.refresh()
        let grokDetected = await grok.hasLocalCredentials()
        let grokSnapshot = await grok.refresh()
        let copilotDetected = await copilot.hasLocalCredentials()
        let openRouterInitialStatus = openRouter.apiKeyStatus
        var savedStatus: APIKeyStatus?
        var revealedKey: String?
        var emptySaveThrew = false
        var clearedStatus: APIKeyStatus?
        var keyActionError: Error?
        do {
            try openRouter.saveAPIKey("sk-or-bridge-test")
            savedStatus = openRouter.apiKeyStatus
            revealedKey = openRouter.currentAPIKey()
            do {
                try openRouter.saveAPIKey("   ")
            } catch {
                emptySaveThrew = true
            }
            try openRouter.deleteAPIKey()
            clearedStatus = openRouter.apiKeyStatus
        } catch {
            keyActionError = error
        }
        let openRouterDetected = await openRouter.hasLocalCredentials()
        let openRouterSnapshot = await openRouter.refresh()

        // Restore the real home for anything else in this process that uses the engine.
        _ = await RustEngine.call(["method": "configure", "params": [
            "home": FileManager.default.homeDirectoryForCurrentUser.path,
            "appData": FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("QuotaBar").path
        ]])

        if let keyActionError {
            XCTFail("unexpected OpenRouter API key error: \(keyActionError)")
        }
        XCTAssertFalse(devinDetected, "an empty home has no Devin credentials")
        XCTAssertEqual(devinSnapshot.providerID, "devin")
        XCTAssertEqual(devinSnapshot.errorCategory, .notLoggedIn)
        guard case .badge(let label, let text, _, _) = devinSnapshot.lines.first else {
            return XCTFail("expected an error badge, got \(devinSnapshot.lines)")
        }
        XCTAssertEqual(label, MetricLine.errorBadgeLabel)
        XCTAssertEqual(text, "Run devin auth login or sign in to Devin and try again.")

        XCTAssertFalse(hermesDetected, "an empty home has no Hermes database")
        XCTAssertEqual(hermesSnapshot.providerID, "hermes")
        XCTAssertEqual(hermesSnapshot.errorCategory, .notLoggedIn)

        XCTAssertFalse(grokDetected, "an empty home has no Grok auth")
        XCTAssertEqual(grokSnapshot.providerID, "grok")
        XCTAssertEqual(grokSnapshot.errorCategory, .notLoggedIn)

        _ = copilotDetected
        _ = copilot

        XCTAssertTrue(openRouterInitialStatus == .notSet || openRouterInitialStatus == .fromEnvironment)
        XCTAssertEqual(savedStatus, openRouterInitialStatus == .fromEnvironment ? .overrideActive : .saved)
        XCTAssertEqual(revealedKey, "sk-or-bridge-test")
        XCTAssertTrue(emptySaveThrew)
        XCTAssertEqual(clearedStatus, openRouterInitialStatus)
        if openRouterInitialStatus == .notSet {
            XCTAssertFalse(openRouterDetected)
            XCTAssertEqual(openRouterSnapshot.errorCategory, .notLoggedIn)
        }
    }

    func testUnknownMethodsFailLoudly() async {
        RustEngine.prepare()
        let reply = await RustEngine.call(["method": "definitely-not-a-method"])
        guard case .failure(let error) = reply else { return XCTFail("expected a failure") }
        XCTAssertEqual(error.localizedDescription, "unknown method: definitely-not-a-method")
    }

    func testCursorAndZAIAreRegisteredInTheLinkedEngine() async throws {
        RustEngine.prepare()
        struct ProviderEntry: Decodable { let id: String }
        struct RegistryReply: Decodable { let ok: [ProviderEntry] }
        let data = try await RustEngine.call(["method": "providers"]).get()
        let ids = Set(try JSONDecoder().decode(RegistryReply.self, from: data).ok.map(\.id))
        XCTAssertTrue(ids.contains("cursor"))
        XCTAssertTrue(ids.contains("zai"))
    }
}
