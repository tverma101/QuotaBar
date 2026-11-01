import AppKit
import XCTest
@testable import QuotaBar

@MainActor
final class FreebuffSessionTimerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testDailyResetWithoutAnActiveSessionNeverBecomesATimer() throws {
        let (content, daily) = try content(payload: ["status": "none"])
        XCTAssertTrue(content.isEmpty)
        XCTAssertEqual(daily.used, 3)
        XCTAssertEqual(daily.limit, 33)
        XCTAssertEqual(daily.resetsAt, now.addingTimeInterval(4 * 3600))
        XCTAssertNil(MenuBarStripRenderer.textImage(for: content))
    }

    func testOneSessionUsesItsExpiryInsteadOfDailyResetAndPreservesDashboard() throws {
        let (content, daily) = try content(payload: [
            "status": "active", "instanceId": "cli", "expiresAt": iso(42 * 60)
        ])
        XCTAssertEqual(content.groups.first?.metrics.map(\.value), ["42m"])
        XCTAssertTrue(content.groups[0].usesCompactValues)
        let image = try XCTUnwrap(MenuBarStripRenderer.textImage(for: content))
        XCTAssertLessThan(image.size.width, 38, "one session must keep the compact percentage-row type size")
        XCTAssertLessThanOrEqual(image.size.height, 14)
        XCTAssertTrue(content.bars.isEmpty, "a clock must not draw the daily-budget bar")
        XCTAssertEqual(daily.used, 3)
        XCTAssertEqual(daily.limit, 33)
        XCTAssertTrue(daily.expiriesAt.isEmpty, "menu-bar timers must not add dashboard expiry tooltips")
    }

    func testTwoDesktopSessionsStackAndUnoccupiedOrExpiredPurchasesDisappear() throws {
        let (content, _) = try content(payload: [
            "status": "none",
            "desktopPurchases": [
                ["holderInstanceId": "b", "model": "fast", "expiresAt": iso(51 * 60)],
                ["holderInstanceId": "a", "model": "fast", "expiresAt": iso(18 * 60)],
                ["model": "fast", "expiresAt": iso(55 * 60)],
                ["holderInstanceId": "expired", "expiresAt": iso(-60)]
            ]
        ])
        XCTAssertEqual(content.groups.first?.metrics.map(\.value), ["18m", "51m"])
        XCTAssertEqual(Set(content.groups[0].metrics.map(\.id)).count, 2)
        let image = try XCTUnwrap(MenuBarStripRenderer.textImage(for: content))
        XCTAssertLessThanOrEqual(image.size.height, 22)
        XCTAssertLessThan(image.size.width, 60)
        XCTAssertEqual(image.accessibilityDescription, "Freebuff Session 1 18m, Session 2 51m")
        if let directory = ProcessInfo.processInfo.environment["QUOTABAR_RENDER_EVIDENCE_DIR"] {
            let tiff = try XCTUnwrap(image.tiffRepresentation)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("freebuff-two-session-render.png"))
        }
    }

    func testDuplicateHolderIsCountedOnceButEqualExpirySessionsStaySeparate() throws {
        let (content, _) = try content(payload: [
            "status": "active", "instanceId": "a", "expiresAt": iso(30 * 60),
            "desktopPurchases": [
                ["holderInstanceId": "a", "expiresAt": iso(30 * 60)],
                ["holderInstanceId": "b", "expiresAt": iso(30 * 60)]
            ]
        ])
        XCTAssertEqual(content.groups.first?.metrics.map(\.value), ["30m", "30m"])
    }

    func testTimersAdvanceAndDisappearWithoutAnotherNetworkResponse() throws {
        let (advanced, _) = try content(payload: [
            "status": "active", "instanceId": "cli", "expiresAt": iso(42 * 60)
        ], elapsed: 60)
        XCTAssertEqual(advanced.groups.first?.metrics.map(\.value), ["41m"])
        let (expired, _) = try content(payload: [
            "status": "active", "instanceId": "cli", "expiresAt": iso(42 * 60)
        ], elapsed: 42 * 60)
        XCTAssertTrue(expired.isEmpty)
    }

    func testInvalidActiveExpiryIsReportedAsUnreadableData() {
        XCTAssertThrowsError(try content(payload: ["status": "active", "expiresAt": "bad"])) {
            XCTAssertEqual($0 as? FreebuffUsageError, .invalidResponse)
        }
    }

    func testSuccessfulIdlePollClearsPreviouslyActiveExpiryAfterMenuBarMerge() throws {
        let active = try snapshot(payload: [
            "status": "active", "instanceId": "cli", "expiresAt": iso(42 * 60)
        ])
        let idle = try snapshot(payload: ["status": "none"]).mergingMenuBarUpdate(over: active)
        guard case .values(_, _, _, let expiries, _, _) = idle.line(label: "Active Sessions") else {
            return XCTFail("missing explicit idle session metadata")
        }
        XCTAssertTrue(expiries.isEmpty)
    }

    private func iso(_ seconds: TimeInterval) -> String {
        ISO8601DateFormatter().string(from: now.addingTimeInterval(seconds))
    }

    private func snapshot(payload: [String: Any]) throws -> ProviderSnapshot {
        var payload = payload
        payload["freebucks"] = ["balance": 65, "daily": [
            "spent": 15, "limit": 165, "resetAt": iso(4 * 3600)
        ]] as [String: Any]
        let mapped = try FreebuffUsageMapper.map(response: HTTPResponse(
            statusCode: 200, headers: [:], body: JSONSerialization.data(withJSONObject: payload)
        ))
        return ProviderSnapshot(providerID: "freebuff", displayName: "Freebuff", lines: mapped.lines,
                                refreshedAt: now, clearsPriorMenuBarQuotaState: true)
    }

    private func content(payload: [String: Any], elapsed: TimeInterval = 0) throws -> (MenuBarContent, WidgetData) {
        let provider = FreebuffProvider()
        let descriptors = provider.widgetDescriptors
        let daily = try XCTUnwrap(descriptors.first { $0.id == "freebuff.freebucksDaily" })
        let balance = try XCTUnwrap(descriptors.first { $0.id == "freebuff.freebucksBalance" })
        let defaults = UserDefaults(suiteName: "FreebuffSessionTimerTests.\(UUID())")!
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider.provider], descriptors: descriptors), providers: [], defaults: defaults
        )
        store.snapshots["freebuff"] = try snapshot(payload: payload)
        let group = ProviderMetrics(provider: provider.provider, alwaysShownMetrics: [daily, balance], expandedMetrics: [])
        let content = MenuBarContentBuilder.build(groups: [group], now: now.addingTimeInterval(elapsed)) {
            store.data(for: $0)
        }
        return (content, store.data(for: daily))
    }
}
