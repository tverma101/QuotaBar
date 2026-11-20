import XCTest
import SwiftUI
@testable import QuotaBar

/// Covers the Share card export pipeline: `image(for:)` rasterizes the flexible-height card, and
/// `pngData(from:)` round-trips to a valid PNG. `ImageRenderer` is MainActor-only, so the whole case
/// runs on the main actor. Pixel dimensions are checked scale-agnostically (the bitmap width is a
/// multiple of the authored card width) because `ImageRenderer.scale` is not honored in headless CI.
@MainActor
final class ShareCardRendererTests: XCTestCase {
    private func sampleCard() -> ShareCardView {
        let provider = MockData.claude
        let rows = MockData.descriptors(for: provider.id).map { $0.sample }
        return ShareCardView(provider: provider, plan: "Max", rows: rows, appearance: .light)
    }

    func testImageRasterizesAtAuthoredWidthMultiple() throws {
        let image = try XCTUnwrap(ShareCardRenderer.image(for: sampleCard()))

        // The bitmap width is the authored card width times the render scale. `ImageRenderer.scale` is
        // not honored in headless CI (it rasterizes at ×1), so assert a scale-agnostic multiple rather
        // than an exact `width * scale` — it holds at ×1 in CI and ×4 locally.
        let rep = try XCTUnwrap(image.representations.first)
        let width = Int(ShareCardView.width)
        XCTAssertGreaterThan(rep.pixelsWide, 0)
        XCTAssertEqual(rep.pixelsWide % width, 0, "bitmap width should be a whole multiple of the authored card width")
        XCTAssertGreaterThan(rep.pixelsHigh, 0, "flexible-height card should rasterize with a positive height")
    }

    func testPNGDataRoundTripsToValidPNG() throws {
        let image = try XCTUnwrap(ShareCardRenderer.image(for: sampleCard()))
        let png = try XCTUnwrap(ShareCardRenderer.pngData(from: image))

        XCTAssertFalse(png.isEmpty)
        // PNG magic bytes: 89 50 4E 47 0D 0A 1A 0A.
        let magic: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        XCTAssertEqual(Array(png.prefix(magic.count)), magic)
        // The PNG must decode back into an image (a non-empty Data alone isn't proof it's valid).
        XCTAssertNotNil(NSImage(data: png))
    }

    func testRendersEmptyProviderWithoutCrashing() throws {
        let card = ShareCardView(provider: MockData.cursor, plan: nil, rows: [], appearance: .dark)
        let image = try XCTUnwrap(ShareCardRenderer.image(for: card))
        let rep = try XCTUnwrap(image.representations.first)
        // Same scale-agnostic width check; the point is it doesn't crash on an empty provider.
        XCTAssertEqual(rep.pixelsWide % Int(ShareCardView.width), 0)
        XCTAssertGreaterThan(rep.pixelsHigh, 0)
    }

    func testFailureSoundIsDisabledInTheXCTestHarness() {
        XCTAssertFalse(ShareCardRenderer.isFailureSoundEnabled)
    }

    /// The neighbor-aware condensing rule on a fixed fixture: a text-only row condenses only under
    /// another text-only row, and the expand caret is a hard boundary a run never bridges.
    func testCondensedTextRowIndicesFollowNeighborRuleAndRespectExpandBoundary() {
        func row(bounded: Bool) -> WidgetData {
            WidgetData(title: "Row", icon: .providerMark("claude"), kind: .percent, used: 0, limit: bounded ? 100 : nil)
        }
        // Meter, then a run of three text-only rows.
        let rows = [row(bounded: true), row(bounded: false), row(bounded: false), row(bounded: false)]

        XCTAssertEqual(ShareCardView.condensedTextRowIndices(rows), [2, 3])
        // With the caret between rows 1 and 2, row 2 starts the expanded segment (never condensed);
        // only row 3 still condenses.
        XCTAssertEqual(ShareCardView.condensedTextRowIndices(rows, boundary: 2), [3])
    }

    // MARK: - Clipboard write result

    /// `copyToPasteboard` reports `false` when the image can't be PNG-encoded, so `share` can gate the
    /// "Copied to clipboard" confirmation on a real successful write instead of claiming success after a
    /// silent encode/pasteboard failure. Regression guard for the success-pill-after-copy-failure bug.
    func testCopyToPasteboardReturnsFalseForUnencodableImage() {
        // An empty NSImage has no representations, so tiffRepresentation is nil and PNG encoding fails.
        let empty = NSImage()
        XCTAssertFalse(ShareCardRenderer.copyToPasteboard(empty),
                       "a failed encode must report false, not silently return success")
    }

    /// `copyToPasteboard` reports `true` and actually writes PNG data onto the pasteboard for a valid
    /// image — the success contract the confirmation gates on.
    func testCopyToPasteboardWritesPNGAndReturnsTrueForValidImage() throws {
        let image = try XCTUnwrap(ShareCardRenderer.image(for: sampleCard()))
        XCTAssertTrue(ShareCardRenderer.copyToPasteboard(image))

        let png = try XCTUnwrap(NSPasteboard.general.data(forType: .png))
        XCTAssertFalse(png.isEmpty)
        // PNG magic bytes confirm the pasteboard holds an actual PNG, not just non-empty data.
        let magic: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        XCTAssertEqual(Array(png.prefix(magic.count)), magic)
    }

    // MARK: - Exported-row parity

    /// The export used to resolve each placed row twice: once inside the `visibleRows` predicate and
    /// again in the mapping that built the card. The optimized path resolves once; this locks its
    /// output to the old selection — same rows, same order, same values, filtered rows dropped — and
    /// asserts a collapsed provider's On Demand rows are never resolved (they cannot be exported).
    func testExportedRowsMatchThePreChangeSelectionAndDoNotResolveCollapsedRows() throws {
        let suiteName = "ShareCardRowParity.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }

        let provider = Provider(id: "parity", displayName: "Parity", icon: .providerMark("parity"))
        func descriptor(
            _ id: String,
            _ title: String,
            hidesWhenEmpty: Bool = false
        ) -> WidgetDescriptor {
            WidgetDescriptor(
                id: id,
                providerID: provider.id,
                metricLabel: title,
                sample: WidgetData(title: title, icon: provider.icon, kind: .percent, used: 0, limit: 100),
                hidesWhenEmpty: hidesWhenEmpty
            )
        }
        let registry = WidgetRegistry(providers: [provider], descriptors: [
            descriptor("parity.session", "Session"),
            descriptor("parity.weekly", "Weekly"),
            // Feature-dependent row with no data: filtered out by `showsRow`, so the parity check
            // covers the selection rule as well as order and values.
            descriptor("parity.extra", "Extra usage", hidesWhenEmpty: true),
            descriptor("parity.today", "Today")
        ])
        let layout = LayoutStore(
            registry: registry,
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: ["parity.session", "parity.weekly", "parity.extra", "parity.today"],
            migrationBaselineMetricIDs: [],
            defaultPinnedMetricIDs: [],
            migrationBaselinePinnedMetricIDs: [],
            defaultExpandedMetricIDs: ["parity.today"],
            isProviderEnabled: { _ in true }
        )

        let group = try XCTUnwrap(layout.displayGroups.first { $0.provider.id == "parity" })
        func descriptorIDs(_ widgets: [PlacedWidget]) -> [String] {
            widgets.compactMap { layout.descriptor(for: $0)?.id }
        }
        XCTAssertEqual(
            descriptorIDs(group.alwaysShownWidgets),
            ["parity.session", "parity.weekly", "parity.extra"],
            "fixture must place the hidden row above the caret"
        )
        XCTAssertEqual(descriptorIDs(group.expandedWidgets), ["parity.today"])

        // Distinct per-row values, so equality proves the right data reached the right row.
        var extraEmpty = WidgetData(title: "Extra usage", icon: provider.icon, kind: .percent, used: 0, limit: 100)
        extraEmpty.hasData = false
        let resolvedByID: [String: WidgetData] = [
            "parity.session": WidgetData(title: "Session", icon: provider.icon, kind: .percent, used: 25, limit: 100),
            "parity.weekly": WidgetData(title: "Weekly", icon: provider.icon, kind: .percent, used: 40, limit: 100),
            "parity.extra": extraEmpty,
            "parity.today": WidgetData(title: "Today", icon: provider.icon, kind: .percent, used: 7, limit: 100)
        ]
        func resolved(_ descriptor: WidgetDescriptor) -> WidgetData {
            resolvedByID[descriptor.id] ?? descriptor.sample
        }

        /// The pre-change algorithm: resolve inside the visibility predicate, then resolve each kept
        /// widget again when mapping it into the card's row list.
        func preChangeRows(_ widgets: [PlacedWidget]) -> [WidgetData] {
            let kept = widgets.filter { widget in
                guard let descriptor = layout.descriptor(for: widget) else { return false }
                let data = resolved(descriptor)
                return ProviderSectionVisibility.shouldRenderMetricRow(
                    providerID: descriptor.providerID,
                    descriptorID: descriptor.id,
                    hasData: data.hasData,
                    errorCategory: nil,
                    explicitlyEnabled: layout.explicitlyEnabledMetricIDs.contains(descriptor.id)
                ) && layout.showsRow(descriptor, hasData: data.hasData)
            }
            return kept.compactMap { widget in
                guard let descriptor = layout.descriptor(for: widget) else { return nil }
                return resolved(descriptor)
            }
        }
        let expectedAlways = preChangeRows(group.alwaysShownWidgets)
        let expectedExpanded = preChangeRows(group.expandedWidgets)
        XCTAssertEqual(expectedAlways.map(\.title), ["Session", "Weekly"])
        XCTAssertEqual(expectedExpanded.map(\.title), ["Today"])

        final class ResolutionCounter {
            var ids: [String] = []
        }
        let counter = ResolutionCounter()
        func countedData(_ descriptor: WidgetDescriptor) -> WidgetData {
            counter.ids.append(descriptor.id)
            return resolved(descriptor)
        }

        counter.ids.removeAll()
        let collapsed = ShareCardRenderer.exportedRows(
            for: group, isExpanded: false, layout: layout,
            errorCategory: { _ in nil }, data: countedData
        )
        XCTAssertEqual(collapsed.rows, expectedAlways,
                       "collapsed export must match the old selection's rows, order and values")
        XCTAssertNil(collapsed.expandBoundaryIndex)
        XCTAssertEqual(
            counter.ids, ["parity.session", "parity.weekly", "parity.extra"],
            "a collapsed provider must not resolve On Demand rows it cannot export"
        )

        counter.ids.removeAll()
        let expanded = ShareCardRenderer.exportedRows(
            for: group, isExpanded: true, layout: layout,
            errorCategory: { _ in nil }, data: countedData
        )
        XCTAssertEqual(expanded.rows, expectedAlways + expectedExpanded,
                       "expanded export must match the old selection's rows, order and values")
        XCTAssertEqual(expanded.rows.map(\.title), ["Session", "Weekly", "Today"])
        XCTAssertEqual(expanded.rows.map(\.used), [25, 40, 7])
        XCTAssertEqual(expanded.expandBoundaryIndex, 2,
                       "the caret boundary must stay at the Always Visible row count")
        XCTAssertEqual(
            counter.ids,
            ["parity.session", "parity.weekly", "parity.extra", "parity.today"],
            "each exported row is resolved exactly once"
        )
    }
}
