import AppKit
import SwiftUI
import XCTest
@testable import QuotaBar

/// Headless render of the real `HistoryDashboardView` against fixture data — the screen's live proof
/// without needing to click the menu bar. Renders through `NSHostingView.cacheDisplay` (AppKit's
/// production renderer, no window, no GUI automation — `ImageRenderer` blanks out when the view
/// reads `@Observable` objects from the environment in this xctest process), saves a PNG, and
/// asserts the report the view shows.
@MainActor
final class HistoryDashboardViewSnapshotTests: XCTestCase {
    func testRendersHistoryScreenWithFixtureData() throws {
        let suiteName = "HistoryDashboardViewSnapshotTests"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let providers: [any ProviderRuntime] = [ClaudeProvider(), CodexProvider(), GrokProvider()]
        let registry = WidgetRegistry.from(providers)
        let layout = LayoutStore(registry: registry, defaults: defaults, storageKey: "layout")
        let dataStore = WidgetDataStore(registry: registry, providers: providers, defaults: defaults)

        // Fixture: Claude fully priced; Codex with a priced model plus the stealth codename row —
        // tokens counted, cost dashed (it backfills automatically once discovery prices it). Days
        // older than the 30-day window (-200, -90) prove the lifetime hero counts what the period
        // rows can't: they lift `lifetime` above `last30` and set the "since" caption.
        dataStore.snapshots = [
            "claude": ProviderSnapshot(
                providerID: "claude",
                displayName: "Claude",
                lines: [],
                usageHistory: Self.history(
                    daily: [
                        (0, 96_700_000, 3.05), (-1, 578_100_000, 25.15), (-9, 1_240_000_000, 51.40),
                        (-90, 3_400_000_000, 140.10), (-200, 6_100_000_000, 260.75)
                    ],
                    models: [(0, "claude-sonnet-5", 96_700_000, 3.05), (-1, "claude-opus-4.7", 578_100_000, 25.15)],
                    estimates: [(0, 4.10), (-1, 31.80), (-9, 70.02), (-90, 190.40), (-200, 350.10)]
                )
            ),
            "codex": ProviderSnapshot(
                providerID: "codex",
                displayName: "Codex",
                lines: [],
                usageHistory: Self.history(
                    daily: [
                        (0, 204_400_000, 5.22), (-2, 88_900_000, 2.88), (-12, 2_000_000_000, 74.55),
                        (-150, 4_400_000_000, 180.20)
                    ],
                    models: [
                        (0, "gpt-5.2", 204_400_000, 5.22),
                        (-2, "space bunny", 88_900_000, nil),
                        (-12, "gpt-5.2", 2_000_000_000, 74.55)
                    ],
                    estimates: [(0, 6.90), (-2, 3.02), (-12, 98.60), (-150, 240.55)]
                )
            )
        ]

        // The report the view must show: three period cards, the estimate line, and Codex's dashed
        // codename row. Assert the model first — a silently-empty render would prove nothing.
        let report = HistoryDashboardAggregator.report(.init(
            enabledProviderIDs: layout.orderedProviderIDs().filter { layout.isProviderEnabled($0) },
            displayNameByProviderID: [:],
            historyByProviderID: ["claude": dataStore.snapshots["claude"]!.usageHistory!,
                                  "codex": dataStore.snapshots["codex"]!.usageHistory!]
        ))
        XCTAssertFalse(report.isEmpty, "fixture must produce sections")
        XCTAssertNotNil(report.apiEstimateTotal)
        XCTAssertGreaterThan(report.lifetime.tokens, report.last30.tokens,
                             "pre-window days must count toward lifetime but not the 30-day total")
        XCTAssertGreaterThan(report.lifetime.cost ?? 0, report.last30.cost ?? 0)
        XCTAssertEqual(report.lifetimeSinceLabel, "Mar 2026", "earliest fixture day (-200d) sets the since caption")
        XCTAssertTrue(report.sections.contains { section in
            section.rows.contains { $0.slug == "space bunny" && $0.cost == nil && $0.tokens > 0 }
        }, "the stealth codename row must show tokens with a dashed cost")

        let view = HistoryDashboardView()
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
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("quotabar_history_render.png")
        try png.write(to: url)
        print("history render saved to: \(url.path), size: \(hosting.bounds.size), bytes: \(png.count)")
        XCTAssertGreaterThan(png.count, 20_000, "a real history screen renders far more than a blank bitmap")
    }

    private static func history(
        daily: [(offset: Int, tokens: Int, cost: Double?)],
        models: [(offset: Int, name: String, tokens: Int, cost: Double?)],
        estimates: [(offset: Int, estimate: Double)]
    ) -> ProviderUsageHistory {
        let calendar = Calendar.current
        let now = TestLocalInstant.date(2026, 10, 5, 12)
        func key(_ offset: Int) -> String {
            DailyUsageAccumulator.dayKey(
                from: calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))!,
                calendar: calendar
            )
        }
        return ProviderUsageHistory(
            series: DailyUsageSeries(daily: daily.map {
                DailyUsageEntry(date: key($0.offset), totalTokens: $0.tokens, costUSD: $0.cost)
            }),
            modelUsage: ModelUsageSeries(daily: models.map {
                DailyModelUsageEntry(
                    date: key($0.offset),
                    models: [ModelUsageEntry(model: $0.name, totalTokens: $0.tokens, costUSD: $0.cost)]
                )
            }),
            unknownModelsByDay: [:],
            apiEstimateByDay: Dictionary(uniqueKeysWithValues: estimates.map { (key($0.offset), $0.estimate) })
        )
    }
}
