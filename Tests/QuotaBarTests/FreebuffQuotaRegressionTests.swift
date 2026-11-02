import XCTest
import SwiftUI
@testable import QuotaBar

@MainActor
final class FreebuffQuotaRegressionTests: XCTestCase {
    private func response(_ bucks: Any?, extras: [String: Any] = [:]) throws -> HTTPResponse {
        var root: [String: Any] = ["status": "none"]
        root.merge(extras, uniquingKeysWith: { _, new in new })
        if let bucks { root["freebucks"] = bucks }
        return HTTPResponse(statusCode: 200, headers: [:], body: try JSONSerialization.data(withJSONObject: root))
    }

    private var daily: [String: Any] { ["limit": 265, "spent": 0, "remaining": 265] }

    private func balance(_ mapped: FreebuffMappedUsage) -> Double? {
        guard case .values(_, let values, _, _, _, _) = mapped.lines.first(where: { $0.label == "Hours Balance" }) else { return nil }
        return values.first?.number
    }

    func testDailyPoolAndWalletRemainDisjointAndRoundedWalletDoesNotOverstateBuyingPower() throws {
        let mapped = try FreebuffUsageMapper.map(response: response([
            "balance": 633, "daily": daily, "wallet": ["balance": 368]
        ]))
        XCTAssertEqual(balance(mapped), 73, "daily 53 hours must not be included in the wallet's 73 hours")
        guard case .progress(_, let used, let limit, _, _, _, _, _) = mapped.lines.first(where: { $0.label == "Daily Hours" }) else {
            return XCTFail("daily meter missing")
        }
        XCTAssertEqual(used, 0)
        XCTAssertEqual(limit, 53)
    }

    func testExhaustedDailyPoolAndZeroWalletAreRealZeroBalances() throws {
        let mapped = try FreebuffUsageMapper.map(response: response([
            "balance": 0, "daily": ["limit": 265, "spent": 300, "remaining": 0], "wallet": ["balance": 0]
        ]))
        XCTAssertEqual(balance(mapped), 0)
        XCTAssertNil(mapped.warning)
    }

    func testOlderCombinedMeterSubtractsDailyRemainderEvenWithoutRemainingField() throws {
        let mapped = try FreebuffUsageMapper.map(response: response([
            "balance": 633, "daily": ["limit": 265, "spent": 5]
        ]))
        XCTAssertEqual(balance(mapped), 74)
    }

    func testNullMeterClearsPreviousWalletMonthlySpendDailyAndSessionClocks() throws {
        let now = TestLocalInstant.date(2026, 11, 2, 12)
        let prior = try FreebuffUsageMapper.map(response: response([
            "balance": 633, "daily": daily, "wallet": ["balance": 368],
            "monthly": ["spentUsd": 3]
        ], extras: ["status": "active", "expiresAt": "2026-11-02T18:00:00Z"]))
        let fresh = try FreebuffUsageMapper.map(response: response(NSNull(), extras: [
            "freeWindows": ["dayUsed": 0, "dayLimit": 3]
        ]))
        let previous = ProviderSnapshot(providerID: "freebuff", displayName: "Freebuff", lines: prior.lines, refreshedAt: now)
        let updated = ProviderSnapshot(providerID: "freebuff", displayName: "Freebuff", lines: fresh.lines, refreshedAt: now,
                                       warning: fresh.warning, clearsPriorMenuBarQuotaState: true)
            .mergingMenuBarUpdate(over: previous)
        for label in ["Hours Balance", "Monthly Spend", "Active Sessions"] {
            guard case .values(_, let values, _, let expiries, _, _) = updated.line(label: label) else {
                return XCTFail("missing explicit clear for \(label)")
            }
            XCTAssertTrue(values.isEmpty)
            XCTAssertTrue(expiries.isEmpty)
        }
        XCTAssertNil(updated.line(label: "Daily Hours"))
        XCTAssertNil(updated.line(label: "Daily"), "legacy caps cannot replace an unavailable hours meter")
        XCTAssertNotNil(updated.warning)
    }

    func testMalformedPresentMeterIsAnErrorInsteadOfSuccessfulMissingData() throws {
        let invalid: [Any] = ["garbled", ["balance": 633],
                              ["balance": 633, "daily": daily, "wallet": NSNull()],
                              ["balance": 633, "daily": ["limit": true, "spent": 0]],
                              ["balance": 633, "daily": daily, "wallet": ["balance": -1]],
                              ["balance": 1, "daily": daily]]
        for bucks in invalid {
            XCTAssertThrowsError(try FreebuffUsageMapper.map(response: response(bucks))) {
                XCTAssertEqual($0 as? FreebuffUsageError, .invalidResponse)
            }
        }
    }

    func testOmittedMeterAlsoReplacesAnOldWalletWithNoData() throws {
        let mapped = try FreebuffUsageMapper.map(response: response(nil))
        XCTAssertNil(balance(mapped))
        XCTAssertTrue(mapped.lines.contains(.noUsageData))
    }

    func testHeadlessWalletAndDailyCardUsesTheResolvedProductionRows() throws {
        let provider = FreebuffProvider()
        let registry = WidgetRegistry.from([provider])
        let mapped = try FreebuffUsageMapper.map(response: response([
            "balance": 633, "daily": daily, "wallet": ["balance": 368]
        ]))
        let store = WidgetDataStore(registry: registry, providers: [], defaults: UserDefaults(suiteName: "FreebuffCard.\(UUID())")!)
        store.snapshots["freebuff"] = .make(provider: provider.provider, plan: "Fixture", lines: mapped.lines,
                                          refreshedAt: TestLocalInstant.date(2026, 11, 2, 12))
        let rows = registry.descriptors(for: "freebuff")
            .filter { ["Daily Hours", "Hours Balance"].contains($0.metricLabel) }.map(store.data(for:))
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].limit, 53)
        XCTAssertEqual(rows[1].values.first?.number, 73)
        guard let directory = ProcessInfo.processInfo.environment["QUOTABAR_RENDER_EVIDENCE_DIR"] else { return }
        let image = try XCTUnwrap(ShareCardRenderer.image(for: ShareCardView(provider: provider.provider, plan: "Fixture",
                                                                          rows: rows, appearance: .dark)))
        let png = try XCTUnwrap(ShareCardRenderer.pngData(from: image))
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("freebuff-hours.png"))
    }
}
