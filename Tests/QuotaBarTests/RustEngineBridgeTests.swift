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
    func testDevinRefreshRoundTripsThroughTheEngine() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuotaBarTests.RustEngine.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        RustEngine.prepare()
        _ = await RustEngine.call(["method": "configure", "params": ["home": home.path, "appData": home.path]])
        defer {
            try? FileManager.default.removeItem(at: home)
        }

        let provider = DevinProvider()
        let detected = await provider.hasLocalCredentials()
        let snapshot = await provider.refresh()

        // Restore the real home for anything else in this process that uses the engine.
        _ = await RustEngine.call(["method": "configure", "params": [
            "home": FileManager.default.homeDirectoryForCurrentUser.path,
            "appData": FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("QuotaBar").path
        ]])

        XCTAssertFalse(detected, "an empty home has no Devin credentials")
        XCTAssertEqual(snapshot.providerID, "devin")
        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
        guard case .badge(let label, let text, _, _) = snapshot.lines.first else {
            return XCTFail("expected an error badge, got \(snapshot.lines)")
        }
        XCTAssertEqual(label, MetricLine.errorBadgeLabel)
        XCTAssertEqual(text, "Run devin auth login or sign in to Devin and try again.")
    }

    func testUnknownMethodsFailLoudly() async {
        RustEngine.prepare()
        let reply = await RustEngine.call(["method": "definitely-not-a-method"])
        guard case .failure(let error) = reply else { return XCTFail("expected a failure") }
        XCTAssertEqual(error.localizedDescription, "unknown method: definitely-not-a-method")
    }
}
