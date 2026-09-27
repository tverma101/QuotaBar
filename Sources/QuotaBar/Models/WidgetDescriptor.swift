import Foundation

/// A provider metric's identity and presentation template. Live provider lines supply the values;
/// `sample` carries stable display metadata such as title, icon, kind, and descriptor opt-ins.
struct WidgetDescriptor: Identifiable, Hashable {
    let id: String                 // "claude.session"
    let providerID: String
    let metricLabel: String
    /// Display template. `var` because `spendTiles` re-labels the same descriptor with a different
    /// `valueTooltipNote`; copying the descriptor and mutating this keeps that from having to
    /// reconstruct every field by hand (which silently dropped newly added ones).
    var sample: WidgetData
    /// Whether this widget can be pinned to the menu-bar strip. False for tiles the tray can't render as
    /// a value — the Usage Trend chart — so the pin affordance never offers a pin that would read "0".
    var pinnable: Bool = true
    /// True only for the `SpendTileMapper`-backed spend-history tiles (see `WidgetDescriptor.spendTiles`).
    /// The Total Spend card keys on this to decide which providers feed the ring — a title match would
    /// wrongly rope in look-alike rows like OpenRouter's API-spend "Today".
    var isSpendTile: Bool = false
    /// Stable scalar resources exported by `/v1/limits`. Empty for UI-only/history widgets.
    var limitResources: [LimitResourceDescriptor] = []
    /// Explicit aggregation semantics for this provider's normalized daily history. Exactly one
    /// descriptor carries it for every provider that exposes the shared spend tiles.
    var historyResource: UsageHistoryDescriptor? = nil
    /// True when this row only means something if the account actually has the underlying feature, so
    /// an empty row is noise rather than information — "Extra Usage" on a plan without extra usage, an
    /// on-demand row for a plan that only bundles requests, a per-key rate limit for an account with no
    /// key cap.
    ///
    /// Set only on feature/plan-dependent rows. Never on core quota meters: a session or weekly meter
    /// reading empty means "we don't know yet", and hiding that would read as "you're fine" at exactly
    /// the moment the user wants to know.
    ///
    /// The dashboard hides an empty conditional row unless the user explicitly turned it on, so
    /// opting in is a statement of intent that outranks the data. See `hidesWhenEmpty` on
    /// `WidgetData` for the live test, and `LayoutStore` for the opt-in memory.
    var hidesWhenEmpty: Bool = false

    /// The metric's single display name.
    var title: String { sample.title }

    static func == (lhs: WidgetDescriptor, rhs: WidgetDescriptor) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension WidgetDescriptor {
    /// Mark this row as feature/plan-dependent, so the dashboard hides it while it has no data unless
    /// the user explicitly enabled it. Returns a copy so a provider can opt in inline at the
    /// descriptor's construction site:
    ///
    /// ```swift
    /// .boundedDollars(id: "\(provider.id).extra", …).hidingWhenEmpty()
    /// ```
    ///
    /// Named `hidingWhenEmpty()` rather than `hidesWhenEmpty()` because Swift does not allow a
    /// zero-argument method to share a name with a stored property.
    func hidingWhenEmpty() -> WidgetDescriptor {
        var copy = self
        copy.hidesWhenEmpty = true
        return copy
    }
}
