import AppKit
import SwiftUI
import XCTest
@testable import QuotaBar

/// Renders synthetic values only, for PR review without exposing a user's account data.
@MainActor
final class ReviewScreenshotTests: XCTestCase {
    func testSnoozeAndSessionStripRenderWithSyntheticData() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "quotabar.review.\(UUID().uuidString)"))
        let snooze = MenuBarSnoozeStore(defaults: defaults)
        snooze.isEnabled = true
        snooze.threshold = .tenPercent
        let snoozeView = SnoozeControls(snooze: snooze) { EmptyView() }
            .frame(width: 320).padding(14).background(Theme.traySurface).defaultAppStorage(defaults)
        let snoozeImage = try XCTUnwrap(ImageRenderer(content: snoozeView).nsImage)
        XCTAssertGreaterThan(snoozeImage.size.height, 20)
        let provider = Provider(id: "zai", displayName: "Z.ai", icon: .providerMark("zai"))
        let row = WidgetData(title: "Session", icon: provider.icon, kind: .percent, used: 35, limit: 100)
        let card = VStack(alignment: .leading, spacing: 6) {
            ProviderSectionHeader(provider: provider, cardIsHovered: true, onCopyScreenshot: { true })
            DashboardMetricCard { WidgetRowView(data: row) }
        }
        .frame(width: 320).padding(14).background(Theme.traySurface).defaultAppStorage(defaults)
        let cardImage = try XCTUnwrap(ImageRenderer(content: card).nsImage)
        XCTAssertGreaterThan(cardImage.size.height, 20)
        let sampleProviders = ["Claude", "Codex", "Cursor", "Freebuff", "Z.ai"].map {
            Provider(id: $0.lowercased(), displayName: $0, icon: .providerMark($0.lowercased()))
        }
        let registry = WidgetRegistry(providers: sampleProviders, descriptors: [])
        let layout = LayoutStore(registry: registry, defaults: defaults, storageKey: "review.layout")
        let providerList = ProviderReorderListView(reorderSpaceName: "review", reorderLift: .constant(nil),
                                                  frameStore: ReorderFrameStore())
            .frame(width: 320).padding(14).background(Theme.traySurface).environment(layout)
            .coordinateSpace(name: "review").defaultAppStorage(defaults)
        let orderImage = try XCTUnwrap(ImageRenderer(content: providerList).nsImage)
        XCTAssertGreaterThan(orderImage.size.height, 100)
        let icon = IconSource.providerMark("freebuff")
        func metric(_ id: String, _ value: String) -> MenuBarContent.Metric {
            MenuBarContent.Metric(id: id, label: id, value: value, fraction: 0, isBounded: false, hasData: true)
        }
        let clocks = MenuBarContent(groups: [
            .init(providerID: "freebuff", displayName: "Freebuff", icon: icon,
                  metrics: [metric("Session 1", "18m"), metric("Session 2", "51m"), metric("Session 3", "1h 15m")],
                  usesCompactValues: true)
        ], bars: [])
        let strip = try XCTUnwrap(MenuBarStripRenderer.textImage(for: clocks))
        let sessionImage = try XCTUnwrap(ImageRenderer(content: Image(nsImage: strip).renderingMode(.original)
            .padding(12).background(Color.white)).nsImage)
        if let dir = ProcessInfo.processInfo.environment["QUOTABAR_REVIEW_IMAGE_DIR"] {
            for (name, render) in [("sessions.png", sessionImage), ("snooze.png", snoozeImage), ("dashboard.png", cardImage), ("reorder.png", orderImage)] {
                let data = try XCTUnwrap(ShareCardRenderer.pngData(from: render))
                try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
            }
        }
    }
}
