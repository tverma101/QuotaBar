import AppKit
import SwiftUI
import XCTest
@testable import QuotaBar

@MainActor
final class SpendPeriodSettingsTests: XCTestCase {
    func testRendersAllSpendPeriodControlsHeadlessly() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "QuotaBarTests.SpendPeriods.UI.\(UUID())"))
        let store = WidgetDataStore(
            registry: .init(providers: [], descriptors: []), providers: [], defaults: defaults
        )
        store.spendPeriods.last = .init(preset: .custom, customDays: 45)
        let view = SpendPeriodSettingsSection()
            .environment(store)
            .environment(\.colorScheme, .dark)
            .frame(width: 320)
            .padding(14)
            .background(Theme.traySurface)
        let host = NSHostingView(rootView: view)
        host.setFrameSize(host.fittingSize)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let image = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(host.bounds.height, 130)
        if let directory = ProcessInfo.processInfo.environment["QUOTABAR_REVIEW_IMAGE_DIR"] {
            try image.write(
                to: URL(fileURLWithPath: directory).appendingPathComponent("spend-periods.png"),
                options: .atomic
            )
        }
    }

    func testDashboardAndTotalSpendUseTheSameWindowAndPreserveTheMetricID() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "QuotaBarTests.SpendPeriods.\(UUID())"))
        let now = TestLocalInstant.date(2026, 11, 25, 12)
        let provider = Provider(id: "devin", displayName: "Devin", icon: .providerMark("devin"))
        let descriptors = WidgetDescriptor.spendTiles(provider: provider)
        let registry = WidgetRegistry(providers: [provider], descriptors: descriptors)
        let store = WidgetDataStore(registry: registry, providers: [], defaults: defaults, now: { now })
        let history = ProviderUsageHistory(series: .init(daily: [
            .init(date: "2026-11-25", totalTokens: 10, costUSD: 1),
            .init(date: "2026-11-24", totalTokens: 20, costUSD: 2),
            .init(date: "2026-11-19", totalTokens: 30, costUSD: 3),
            .init(date: "2026-11-18", totalTokens: 40, costUSD: 4)
        ]))
        var lines: [MetricLine] = []
        SpendTileMapper.appendTokenUsage(history.series, to: &lines, now: now)
        store.snapshots = [provider.id: ProviderSnapshot(
            providerID: provider.id, displayName: provider.displayName, lines: lines, usageHistory: history
        )]
        let middle = try XCTUnwrap(registry.descriptor(id: "devin.yesterday"))
        let first = try XCTUnwrap(registry.descriptor(id: "devin.today"))
        let last = try XCTUnwrap(registry.descriptor(id: "devin.last30"))

        XCTAssertEqual(store.data(for: middle).title, "Last 7 Days")
        XCTAssertEqual(tokenCount(store.data(for: middle)), 60)
        let total = TotalSpendAggregator.total(
            for: .yesterday, providers: [provider], snapshots: store.snapshots, now: now,
            selection: store.spendPeriods.middle
        )
        XCTAssertEqual(total.slices.first?.tokenCount, 60)
        XCTAssertEqual(total.slices.first?.amountUSD, 6)

        store.spendPeriods.middle.preset = .yesterday
        XCTAssertEqual(store.data(for: middle).title, "Yesterday")
        XCTAssertEqual(tokenCount(store.data(for: middle)), 20)
        store.spendPeriods.first = .init(preset: .custom, customDays: 2)
        store.spendPeriods.last = .init(preset: .custom, customDays: 8)
        XCTAssertEqual(store.data(for: first).title, "Last 2 Days")
        XCTAssertEqual(tokenCount(store.data(for: first)), 30)
        XCTAssertEqual(tokenCount(store.data(for: last)), 100)

        let relaunched = WidgetDataStore(registry: registry, providers: [], defaults: defaults, now: { now })
        XCTAssertEqual(relaunched.spendPeriods, store.spendPeriods)
    }

    func testCustomPeriodNeverRelabelsAnUnrelatedLegacySnapshot() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "QuotaBarTests.SpendPeriods.Legacy.\(UUID())"))
        let provider = Provider(id: "devin", displayName: "Devin", icon: .providerMark("devin"))
        let descriptors = WidgetDescriptor.spendTiles(provider: provider)
        let registry = WidgetRegistry(providers: [provider], descriptors: descriptors)
        let store = WidgetDataStore(registry: registry, providers: [], defaults: defaults)
        store.snapshots = [provider.id: ProviderSnapshot(
            providerID: provider.id, displayName: provider.displayName,
            lines: [.values(label: "Yesterday", values: [.init(number: 50, kind: .count)])]
        )]
        let middle = try XCTUnwrap(registry.descriptor(id: "devin.yesterday"))
        XCTAssertEqual(store.data(for: middle).title, "Last 7 Days")
        XCTAssertFalse(store.data(for: middle).hasData)
        store.spendPeriods.middle.preset = .yesterday
        XCTAssertEqual(tokenCount(store.data(for: middle)), 50)
    }

    private func tokenCount(_ data: WidgetData) -> Double? {
        data.selectedValues.first { $0.kind == .count }?.number
    }
}
