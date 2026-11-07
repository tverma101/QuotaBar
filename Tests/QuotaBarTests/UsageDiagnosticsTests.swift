import XCTest
@testable import QuotaBar

@MainActor
final class UsageDiagnosticsTests: XCTestCase {
    private let now = TestLocalInstant.date(2026, 11, 2, 12)

    private func defaults() -> UserDefaults { UserDefaults(suiteName: "UsageDiagnosticsTests.\(UUID())")! }

    func testBackendReportUsesProductionWidgetAndSessionResolversWithoutOpeningAWindow() throws {
        let provider = FreebuffProvider()
        let registry = WidgetRegistry.from([provider])
        let snapshot = ProviderSnapshot(providerID: "freebuff", displayName: "Freebuff", lines: [
            .progress(label: "Daily Hours", used: 5, limit: 53, format: .count(suffix: "hours"),
                      resetsAt: now.addingTimeInterval(12 * 3600)),
            .values(label: "Hours Balance", values: [MetricValue(number: 73, kind: .count, label: "hours")]),
            .values(label: "Active Sessions", values: [], expiriesAt: [now.addingTimeInterval(42 * 60)])
        ], refreshedAt: now, historyWarning: "Missing receipt",
        activeSessions: [FreebuffActiveSession(instanceID: "sess-1", expiresAt: now.addingTimeInterval(42 * 60), model: "fast", chatTitle: "Refactor Widget")])
        let report = UsageDiagnostics.make(providerIDs: ["freebuff"], snapshots: ["freebuff": snapshot], errors: [:],
                                           registry: registry, runtimes: [provider], defaults: defaults(), now: now)
        let entry = try XCTUnwrap(report.providers["freebuff"])
        XCTAssertFalse(entry.stale)
        XCTAssertEqual(entry.quotaAgeSeconds, 0)
        let wallet = try XCTUnwrap(entry.widgets.first { $0.metricLabel == "Hours Balance" })
        XCTAssertTrue(wallet.hasData)
        XCTAssertTrue(wallet.headline.contains("73"))
        let timer = try XCTUnwrap(entry.widgets.first { $0.metricLabel == "Daily Hours" })
        XCTAssertEqual(timer.activeSessionExpiries, [now.addingTimeInterval(42 * 60)])
        XCTAssertEqual(timer.activeSessions?.first?.chatTitle, "Refactor Widget")
        XCTAssertEqual(report.menuBar.first { $0.providerID == "freebuff" }?.values, ["42m"])
        XCTAssertTrue(report.findings.contains { $0.message == "Missing receipt" })
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: UsageDiagnostics.encode(report)) as? [String: Any])
        XCTAssertEqual(object["schema"] as? String, "quotabar.diagnostics.v1")
        XCTAssertTrue(object["generatedAt"] is String)
    }

    func testDiagnosticFindsDuplicateMetersMissingDataStaleQuotaAndCachedErrors() throws {
        let provider = FreebuffProvider()
        let registry = WidgetRegistry.from([provider])
        var snapshot = ProviderSnapshot.error(provider: provider.provider, message: "Quota unavailable")
        snapshot.refreshedAt = now.addingTimeInterval(-3600)
        snapshot.quotaRefreshedAt = snapshot.refreshedAt
        snapshot.lines += [.values(label: "Duplicate", values: []), .values(label: "Duplicate", values: [])]
        let report = UsageDiagnostics.make(providerIDs: ["freebuff", "missing"], snapshots: ["freebuff": snapshot], errors: [:],
                                           registry: registry, runtimes: [provider], defaults: defaults(), now: now)
        XCTAssertTrue(report.providers["freebuff"]?.stale == true)
        XCTAssertTrue(report.findings.contains { $0.message.contains("Duplicate metric") && $0.severity == "error" })
        XCTAssertTrue(report.findings.contains { $0.message == "Quota unavailable" })
        XCTAssertTrue(report.findings.contains { $0.providerID == "missing" && $0.severity == "error" })
        let daily = try XCTUnwrap(report.providers["freebuff"]?.widgets.first { $0.metricLabel == "Daily Hours" })
        XCTAssertFalse(daily.hasData)
        XCTAssertNil(daily.limit, "the diagnostic must not invent limits from widget sample data")
    }

    func testReaderReturnsCachedDiagnosticsAndCoverageWarningsInsteadOfEmptyLimits() async throws {
        let provider = FreebuffProvider()
        var saved = ProviderSnapshot(providerID: "freebuff", displayName: "Freebuff", lines: [
            .values(label: "Hours Balance", values: [MetricValue(number: 73, kind: .count, label: "hours")])
        ], historyWarning: "Coverage is incomplete")
        saved.historyRefreshedAt = saved.refreshedAt
        let defaults = defaults()
        ProviderSnapshotCache(userDefaults: defaults).store(saved)
        let result = try await UsageReader(userDefaults: defaults, providers: [provider])
            .read(providerID: "freebuff", diagnostic: true)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: result.data) as? [String: Any])
        XCTAssertEqual(json["schema"] as? String, "quotabar.diagnostics.v1")
        XCTAssertTrue(result.warnings.contains { $0.contains("Coverage is incomplete") })
        XCTAssertTrue(String(decoding: result.data, as: UTF8.self).contains("Hours Balance"))
    }

    func testOnlyAllowlistedFreebuffSourceNumbersEnterTheReport() throws {
        let response = HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"status":"active","instanceId":"PRIVATE-ID","token":"PRIVATE-TOKEN","freebucks":{"balance":633,"daily":{"limit":265,"spent":0,"remaining":265},"wallet":{"balance":368},"secret":"PRIVATE-PAYLOAD"}}"#.utf8))
        let observation = FreebuffQuotaObservation(response: response)
        XCTAssertEqual(observation.combinedFreebucks, 633)
        XCTAssertEqual(observation.walletFreebucks, 368)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(observation), as: UTF8.self).contains("PRIVATE"))
    }
}
