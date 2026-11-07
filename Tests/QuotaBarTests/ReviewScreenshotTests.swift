import AppKit
import SwiftUI
import XCTest
@testable import QuotaBar

/// Renders synthetic values only, for PR review without exposing a user's account data.
@MainActor
final class ReviewScreenshotTests: XCTestCase {
    func testPriorityAndSessionStripRenderWithSyntheticData() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "quotabar.review.\(UUID().uuidString)"))
        let provider = Provider(id: "zai", displayName: "Z.ai", icon: .providerMark("zai"))
        let session = WidgetDescriptor.percent(id: "zai.session", provider: provider, title: "Session")
        let weekly = WidgetDescriptor.percent(id: "zai.weekly", provider: provider, title: "Weekly")
        let snapshot = ProviderSnapshot.make(provider: provider, plan: nil, lines: [
            .progress(label: "Session", used: 93, limit: 100, format: .percent),
            .progress(label: "Weekly", used: 43, limit: 100, format: .percent)
        ], refreshedAt: Date())
        let runtime = SequenceProviderRuntime(provider: provider, descriptors: [session, weekly], snapshots: [snapshot])
        let registry = WidgetRegistry(providers: [provider], descriptors: [session, weekly])
        let layout = LayoutStore(registry: registry, defaults: defaults, storageKey: "review.layout",
                                 defaultMetricIDs: [session.id, weekly.id], defaultPinnedMetricIDs: [weekly.id])
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "review.cache", ttl: 60)
        let dataStore = WidgetDataStore(registry: registry, providers: [runtime], cache: cache, defaults: defaults)
        await dataStore.refresh(providerID: provider.id, force: true)
        let priority = VStack(spacing: 0) {
            PopoverTopBar(layout: layout, height: 44, horizontalPadding: 14, onResetAll: {},
                          isPresentingResetAllConfirm: .constant(false))
            PriorityDashboardView { _ in }.padding(14)
        }
        .frame(width: 320).background(Theme.traySurface)
        .environment(layout).environment(dataStore).defaultAppStorage(defaults)
        let image = try XCTUnwrap(ImageRenderer(content: priority).nsImage)
        XCTAssertGreaterThan(image.size.height, 44)
        let icon = IconSource.providerMark("freebuff")
        func metric(_ id: String, _ value: String) -> MenuBarContent.Metric {
            MenuBarContent.Metric(id: id, label: id, value: value, fraction: 0, isBounded: false, hasData: true)
        }
        let finalClocks = MenuBarContent(groups: [
            .init(providerID: "freebuff", displayName: "Freebuff", icon: icon,
                  metrics: [metric("Session 1", "18m"), metric("Session 2", "51m"), metric("Session 3", "1h 15m")],
                  usesCompactValues: true)
        ], bars: [])
        let finalStrip = try XCTUnwrap(MenuBarStripRenderer.textImage(for: finalClocks))
        let finalImage = try XCTUnwrap(ImageRenderer(content: Image(nsImage: finalStrip).renderingMode(.original)
            .padding(12).background(Color.white)).nsImage)
        if let dir = ProcessInfo.processInfo.environment["QUOTABAR_REVIEW_IMAGE_DIR"] {
            for (name, render) in [("priority.png", image), ("sessions.png", finalImage)] {
                let data = try XCTUnwrap(ShareCardRenderer.pngData(from: render))
                try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
            }
        }
    }
}
