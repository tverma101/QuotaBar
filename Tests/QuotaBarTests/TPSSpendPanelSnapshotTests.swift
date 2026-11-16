import AppKit
import SwiftUI
import XCTest
@testable import QuotaBar

/// Headless render of the Total Spend card's TPS lens — the screen's live proof without needing to
/// click the menu bar. `NSHostingView.cacheDisplay` (AppKit's production renderer, same technique the
/// share cards use) renders with the real card chrome, ring and model list, saves a PNG, and the
/// test asserts the content rendered. The TPS metric selection is pinned in UserDefaults for the
/// duration of the render and restored afterwards, like the share renderer pins density.
@MainActor
final class TPSSpendPanelSnapshotTests: XCTestCase {
    private let metricKey = "openusage.totalSpend.metric"

    func testRendersTPSPanelWithFixtureData() throws {
        let suiteName = "TPSSpendPanelSnapshotTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.removePersistentDomain(forName: suiteName)

        let priorMetric = UserDefaults.standard.string(forKey: metricKey)
        UserDefaults.standard.set("tps", forKey: metricKey)
        defer {
            if let priorMetric { UserDefaults.standard.set(priorMetric, forKey: metricKey) } else {
                UserDefaults.standard.removeObject(forKey: metricKey)
            }
        }

        let registry = WidgetRegistry.from([])
        let layout = LayoutStore(registry: registry, defaults: defaults, storageKey: "layout")
        let dataStore = WidgetDataStore(registry: registry, providers: [], defaults: defaults)
        dataStore.snapshots = [
            "tps": TPSFixture.snapshot(
                combinedRate: 33.2,
                combinedTokens: 1_987_000_000,
                slices: [
                    ("claude", 24.1, 412_000_000, 5),
                    ("codex", 40.8, 755_000_000, 5),
                    ("grok", 38.2, 380_000_000, 5),
                    ("muse", 19.4, 290_000_000, 5),
                    ("pi", 12.7, 150_000_000, 5)
                ],
                models: [
                    ("gpt-6.1-terra", 755_000_000, 14.3),
                    ("grok-4.6-build", 380_000_000, 38.2),
                    ("claude-sonnet-4-5", 289_000_000, 51.8),
                    ("muse-spark-1.2-contributor", 290_000_000, 19.4),
                    ("gpt-5.2-codex", 150_000_000, 12.7),
                    ("claude-opus-4-7", 123_000_000, 9.4),
                    ("grok-4.5-fast", 96_000_000, 61.2),
                    ("muse-spark-1.1", 74_000_000, 9.1)
                ]
            )
        ]

        let view = TotalSpendCard()
            .environment(layout)
            .environment(dataStore)
            .environment(\.colorScheme, .dark)
            .background(Color(red: 0.09, green: 0.09, blue: 0.11))
            .frame(width: 320)

        let hosting = NSHostingView(rootView: view)
        hosting.setFrameSize(hosting.fittingSize)
        let rep = try XCTUnwrap(
            hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds),
            "headless render must produce a bitmap"
        )
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("quotabar_tps_render-\(UUID().uuidString).png")
        try png.write(to: url)
        print("tps render saved to: \(url.path), size: \(hosting.bounds.size), bytes: \(png.count)")

        XCTAssertGreaterThan(png.count, 25_000, "a real TPS panel renders far more than a blank bitmap")
        XCTAssertGreaterThan(hosting.bounds.height, 200)
    }

    /// The failure path: fold failure leaves the error affordance with a Retry, not a silent zero.
    func testRendersTPSErrorState() throws {
        let suiteName = "TPSSpendPanelSnapshotTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.removePersistentDomain(forName: suiteName)

        let priorMetric = UserDefaults.standard.string(forKey: metricKey)
        UserDefaults.standard.set("tps", forKey: metricKey)
        defer {
            if let priorMetric { UserDefaults.standard.set(priorMetric, forKey: metricKey) } else {
                UserDefaults.standard.removeObject(forKey: metricKey)
            }
        }

        let registry = WidgetRegistry.from([])
        let layout = LayoutStore(registry: registry, defaults: defaults, storageKey: "layout")
        let dataStore = WidgetDataStore(registry: registry, providers: [], defaults: defaults)
        dataStore.snapshots = [:]
        dataStore.providerErrors["tps"] = "Couldn't finish reading the local session logs"

        let view = TotalSpendCard()
            .environment(layout)
            .environment(dataStore)
            .environment(\.colorScheme, .dark)
            .background(Color(red: 0.09, green: 0.09, blue: 0.11))
            .frame(width: 320)

        let hosting = NSHostingView(rootView: view)
        hosting.setFrameSize(hosting.fittingSize)
        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("quotabar_tps_error-\(UUID().uuidString).png")
        try png.write(to: url)
        print("tps error render saved to: \(url.path), size: \(hosting.bounds.size), bytes: \(png.count)")

        XCTAssertGreaterThan(png.count, 10_000)
    }

    /// The empty state: TPS mode selected, nothing computed yet.
    func testRendersTPSEmptyState() throws {
        let suiteName = "TPSSpendPanelSnapshotTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.removePersistentDomain(forName: suiteName)

        let priorMetric = UserDefaults.standard.string(forKey: metricKey)
        UserDefaults.standard.set("tps", forKey: metricKey)
        defer {
            if let priorMetric { UserDefaults.standard.set(priorMetric, forKey: metricKey) } else {
                UserDefaults.standard.removeObject(forKey: metricKey)
            }
        }

        let registry = WidgetRegistry.from([])
        let layout = LayoutStore(registry: registry, defaults: defaults, storageKey: "layout")
        let dataStore = WidgetDataStore(registry: registry, providers: [], defaults: defaults)
        dataStore.snapshots = [:]

        let view = TotalSpendCard()
            .environment(layout)
            .environment(dataStore)
            .environment(\.colorScheme, .dark)
            .background(Color(red: 0.09, green: 0.09, blue: 0.11))
            .frame(width: 320)

        let hosting = NSHostingView(rootView: view)
        hosting.setFrameSize(hosting.fittingSize)
        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("quotabar_tps_empty-\(UUID().uuidString).png")
        try png.write(to: url)
        print("tps empty render saved to: \(url.path), size: \(hosting.bounds.size), bytes: \(png.count)")

        XCTAssertGreaterThan(png.count, 10_000)
    }
}

private enum TPSFixture {
    static func snapshot(
        combinedRate: Double,
        combinedTokens: Double,
        slices: [(id: String, rate: Double, tokens: Double, intervals: Int)],
        models: [(name: String, tokens: Int, rate: Double)]
    ) -> ProviderSnapshot {
        let breakdown = ModelUsageBreakdown(
            totalTokens: Int(combinedTokens),
            models: models.map {
                ModelUsageEntry(
                    model: $0.name,
                    totalTokens: $0.tokens,
                    costUSD: nil,
                    tokensPerSecond: $0.rate
                )
            },
            sourceNote: "Estimated from local session logs"
        )
        func valuesLine(_ label: String, rate: Double?, tokens: Double?, breakdown: ModelUsageBreakdown?) -> MetricLine {
            var values: [MetricValue] = []
            if let rate {
                values.append(MetricValue(number: rate, kind: .count, label: "tok/s", estimated: true))
            }
            if let tokens {
                values.append(MetricValue(number: tokens, kind: .count, label: "tokens", estimated: true))
            }
            return .values(label: label, values: values, modelBreakdown: breakdown)
        }
        let sliceLines: [(String, Double, Double, ModelUsageBreakdown?)] = slices.map {
            let label = TokensPerSecondMapper.providerLabels[$0.id] ?? $0.id.capitalized
            return (label, $0.rate, $0.tokens, nil)
        }
        return ProviderSnapshot(
            providerID: "tps",
            displayName: "TPS Tracker",
            lines: [
                valuesLine("Est. TPS", rate: combinedRate, tokens: combinedTokens, breakdown: breakdown)
            ] + sliceLines.map { valuesLine($0.0, rate: $0.1, tokens: $0.2, breakdown: $0.3) },
            refreshedAt: Date()
        )
    }
}
