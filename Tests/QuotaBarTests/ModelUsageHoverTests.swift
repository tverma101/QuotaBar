import XCTest
import SwiftUI
@testable import QuotaBar

@MainActor
final class ModelUsageHoverTests: XCTestCase {
    func testValuesLineCodableRoundTripsModelBreakdown() throws {
        let breakdown = sampleBreakdown()
        let line = MetricLine.values(
            label: "Today",
            values: [MetricValue(number: 3, kind: .dollars), MetricValue(number: 300, kind: .count, label: "tokens")],
            modelBreakdown: breakdown
        )

        let data = try JSONEncoder().encode(line)
        let decoded = try JSONDecoder().decode(MetricLine.self, from: data)

        XCTAssertEqual(decoded, line)
    }

    func testDataStoreResolvesSingleAndMultipleModelBreakdowns() {
        let cases: [(providerID: String, breakdown: ModelUsageBreakdown, models: [String])] = [
            ("claude", sampleBreakdown(), ["alpha", "beta"]),
            ("codex", ModelUsageBreakdown(
                totalTokens: 300, totalCostUSD: 3,
                models: [ModelUsageEntry(model: "gpt-5.5", totalTokens: 300, costUSD: 3)],
                sourceNote: "From Codex test logs"
            ), ["gpt-5.5"])
        ]

        for item in cases {
            let provider = Provider(
                id: item.providerID, displayName: item.providerID.capitalized, icon: .providerMark(item.providerID)
            )
            let descriptor = WidgetDescriptor.spendTiles(provider: provider).first { $0.id == "\(provider.id).today" }!
            let store = WidgetDataStore(
                registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
                providers: [],
                defaults: makeDefaults(item.providerID)
            )
            store.snapshots[provider.id] = ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.values(
                    label: "Today",
                    values: [
                        MetricValue(number: 3, kind: .dollars, estimated: true),
                        MetricValue(number: 300, kind: .count, label: "tokens")
                    ],
                    modelBreakdown: item.breakdown
                )]
            )

            let data = store.data(for: descriptor)
            XCTAssertTrue(data.hasModelBreakdown, item.providerID)
            XCTAssertEqual(data.modelBreakdown?.models.map(\.model), item.models, item.providerID)
            XCTAssertEqual(data.modelBreakdown?.sourceNote, item.breakdown.sourceNote, item.providerID)
        }
    }

    func testWholePercentsAlwaysSumToOneHundred() {
        // Independent rounding would print 33 / 33 / 33 = 99; the largest remainder takes the leftover point.
        XCTAssertEqual(ModelUsageDetail.wholePercents([1.0 / 3, 1.0 / 3, 1.0 / 3]), [34, 33, 33])
        // Independent rounding would print 62 + 34 + 5 = 101 (0.045 rounds up); flooring plus
        // remainder distribution keeps the column at exactly 100.
        XCTAssertEqual(ModelUsageDetail.wholePercents([0.62, 0.335, 0.045]), [62, 34, 4])
        XCTAssertEqual(ModelUsageDetail.wholePercents([1.0]), [100])
        XCTAssertEqual(ModelUsageDetail.wholePercents([0, 0]), [0, 0], "an empty period stays all zero")

    }

    func testSharesUseCostWhenEveryModelIsPriced() {
        let models = [
            ModelUsageEntry(model: "alpha", totalTokens: 10, costUSD: 3),
            ModelUsageEntry(model: "beta", totalTokens: 90, costUSD: 1)
        ]

        XCTAssertEqual(ModelUsageDetail.shares(for: models), [0.75, 0.25])
    }

    func testSharesUseTokensForEveryModelWhenOneIsUnpriced() {
        let models = [
            ModelUsageEntry(model: "alpha", totalTokens: 25, costUSD: 9),
            ModelUsageEntry(model: "beta", totalTokens: 75, costUSD: nil)
        ]

        XCTAssertEqual(ModelUsageDetail.shares(for: models), [0.25, 0.75])
    }

    func testSharesAreZeroWhenThereIsNoCostOrTokenTotal() {
        let models = [
            ModelUsageEntry(model: "alpha", totalTokens: 0, costUSD: nil),
            ModelUsageEntry(model: "beta", totalTokens: 0, costUSD: nil)
        ]

        XCTAssertEqual(ModelUsageDetail.shares(for: models), [0, 0])
    }

    func testSaturatedModelCountsDoNotClaimPreciseShares() {
        let models = [
            ModelUsageEntry(model: "alpha", totalTokens: .max, costUSD: nil, tokenCountSaturated: true),
            ModelUsageEntry(model: "beta", totalTokens: .max, costUSD: nil, tokenCountSaturated: true)
        ]

        XCTAssertFalse(ModelUsageDetail.sharesAreReliable(for: models))
        XCTAssertEqual(ModelUsageDetail.shares(for: models), [0, 0])
        XCTAssertEqual(ModelUsageDetail.wholePercents(ModelUsageDetail.shares(for: models)), [0, 0])
    }

    func testSaturatedPeriodTotalSuppressesSharesWhenEachModelIsIndividuallyExact() {
        let models = [
            ModelUsageEntry(model: "alpha", totalTokens: 6_000_000_000_000_000_000, costUSD: nil),
            ModelUsageEntry(model: "beta", totalTokens: 6_000_000_000_000_000_000, costUSD: nil)
        ]

        XCTAssertFalse(ModelUsageDetail.sharesAreReliable(for: models),
                       "the sum of exact model counts can still overflow Int.max")
        XCTAssertEqual(ModelUsageDetail.shares(for: models), [0, 0])
    }

    func testOtherRowSummaryNamesItsLargestFoldedModel() {
        let other = ModelUsageEntry(model: "Other", totalTokens: 10_500_000_100, costUSD: 0, variants: [
            ModelUsageVariant(model: "small-tail", totalTokens: 100, costUSD: 0),
            ModelUsageVariant(model: "space-bunny-free", totalTokens: 10_500_000_000, costUSD: 0)
        ])

        XCTAssertEqual(ModelUsageDetail.otherContributors(for: other).map(\.model), ["space-bunny-free", "small-tail"])
        XCTAssertTrue(ModelUsageDetail.otherContributors(for: ModelUsageEntry(
            model: "space-bunny-free", totalTokens: 10, costUSD: 0
        )).isEmpty)
    }

    func testOtherContributorsIncludeEveryKnownModelAndUnidentifiedUsageWithoutInventingModelCount() {
        let names = ["GPT-6.1 Terra", "Older Freebuff Usage", "Claude Haiku 5.5", "GLM 5.3 Flash",
                     "Muse Spark 1.3", "MiMo v2.6 Flash", "upstage/solar-pro4", "Unattributed"]
        let variants = names.enumerated().map { index, name in
            ModelUsageVariant(model: name, totalTokens: 100 - index, costUSD: index == 1 ? nil : 1)
        }
        let other = ModelUsageEntry(model: "Other", totalTokens: 772, costUSD: 7, variants: variants,
                                    costIsComplete: false)
        let contributors = ModelUsageDetail.otherContributors(for: other)
        XCTAssertEqual(contributors.map(\.model), names)
        XCTAssertEqual(contributors.map(\.totalTokens), variants.map(\.totalTokens))
        XCTAssertNil(contributors[1].costUSD)
        XCTAssertTrue(contributors[1].hasIncompleteCost)
    }

    func testOtherContributorDetailsRenderInABoundedNativePopover() throws {
        let variants = ["GPT-6.1 Terra", "Older Freebuff Usage", "Claude Haiku 5.5", "GLM 5.3 Flash",
                        "Muse Spark 1.3", "MiMo v2.6 Flash", "upstage/solar-pro4"].map {
            ModelUsageVariant(model: $0, totalTokens: 1_000_000, costUSD: $0 == "Older Freebuff Usage" ? nil : 1)
        }
        let breakdown = ModelUsageBreakdown(totalTokens: 100_000_000, totalCostUSD: 90, models: [
            .init(model: "DeepSeek V4.1 Flash", totalTokens: 93_000_000, costUSD: 84),
            .init(model: "Other", totalTokens: 7_000_000, costUSD: 6, variants: variants, costIsComplete: false)
        ], sourceNote: "Measured usage; dollars are public API estimates.")
        let renderer = ImageRenderer(content: ModelUsageDetail(title: "Last 30 Days", breakdown: breakdown,
            onHoverChange: { _ in }).environment(\.colorScheme, .dark))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage)
        XCTAssertEqual(image.width, 560)
        XCTAssertLessThan(image.height, 1_200, "large contributor lists scroll instead of growing beyond the display")
        if let path = ProcessInfo.processInfo.environment["QUOTABAR_MODEL_DETAIL_RENDER_PATH"] {
            let bitmap = NSBitmapImageRep(cgImage: image)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
        }
    }

    func testHoverPopoverStateOpensThenClosesAroundBothRegions() async {
        let state = HoverPopoverState(revealDelay: .milliseconds(1), hideGrace: .milliseconds(1))
        XCTAssertFalse(state.isPresented)

        state.inlineHover(true)
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(state.isPresented, "opens after the reveal dwell while the row is hovered")

        state.inlineHover(false)
        state.detailHover(true)
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(state.isPresented, "stays open while the cursor is inside the popover")

        state.detailHover(false)
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertFalse(state.isPresented, "closes once the cursor has left both the row and the popover")
    }

    func testHoverPopoverStateQuickPassDoesNotOpen() async {
        let state = HoverPopoverState(revealDelay: .milliseconds(60), hideGrace: .milliseconds(1))
        state.inlineHover(true)
        state.inlineHover(false)
        try? await Task.sleep(for: .milliseconds(90))
        XCTAssertFalse(state.isPresented, "a quick pass over the row never opens the popover")
    }

    func testHoverPopoverStateDismissForcesClosed() async {
        let state = HoverPopoverState(revealDelay: .milliseconds(1), hideGrace: .milliseconds(1))
        state.inlineHover(true)
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(state.isPresented)

        state.dismiss()
        XCTAssertFalse(state.isPresented, "teardown closes it immediately")
    }

    private func sampleBreakdown() -> ModelUsageBreakdown {
        ModelUsageBreakdown(
            totalTokens: 300,
            totalCostUSD: 3,
            models: [
                ModelUsageEntry(model: "alpha", totalTokens: 100, costUSD: 1),
                ModelUsageEntry(model: "beta", totalTokens: 200, costUSD: 2)
            ],
            sourceNote: "From test logs"
        )
    }

    private func makeDefaults(_ name: String) -> UserDefaults {
        let suiteName = "OpenUsageTests.ModelUsageHover.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
