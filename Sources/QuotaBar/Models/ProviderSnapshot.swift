import Foundation

/// Latest normalized output for one provider refresh.
struct ProviderSnapshot: Hashable, Sendable, Codable {
    let providerID: String
    let displayName: String
    var plan: String?
    var lines: [MetricLine]
    var refreshedAt: Date
    /// Raw normalized daily history used to build spend rows. This always belongs to this Mac; peer
    /// history is combined only in the in-memory rendered view and is never written into the cache.
    var usageHistory: ProviderUsageHistory?
    /// A soft, non-blocking notice carried on a *successful* snapshot — e.g. Claude's "Re-login for live
    /// usage" when the saved login lacks the `user:profile` scope. Distinct from `errorCategory` (which is
    /// only on error snapshots): the refresh succeeded and partial data (spend tiles) still loads, so this
    /// surfaces as the provider header's amber triangle rather than blanking the provider. Cached with the
    /// snapshot; cleared on the next refresh when the condition resolves.
    var warning: String?
    /// An explicit successful menu-bar refresh can invalidate previously shown quota state when the
    /// provider has definitive evidence that it no longer applies. Other providers preserve prior
    /// progress during incomplete menu-bar passes.
    var clearsPriorMenuBarQuotaState: Bool?
    /// True when `usageHistory` was carried over from a previous snapshot by a menu-bar merge (or a
    /// full-scope scan miss) rather than computed by this refresh. A menu-bar merge re-stamps
    /// `refreshedAt` for the meters it did compute; without this marker that stamp would also vouch
    /// for the carried history, and since menu-bar passes run every TTL, full passes could
    /// cache-hit forever and never recompute the deferred history (stale spend tiles and
    /// unknown-model warnings would then never clear). Cached with the snapshot; a snapshot whose
    /// history was computed this refresh leaves it nil.
    var carriesPriorHistory: Bool?
    /// When the live quota API last answered for the meters in this snapshot — the meters' own
    /// freshness stamp, distinct from `refreshedAt`. A fold-only pass (`.localAccounting` /
    /// `.panelAccounting`) produces a snapshot whose *history* is fresh but whose meters were
    /// recovered from the previous snapshot by the store's merge; stamping that merge with a fresh
    /// `refreshedAt` alone let closed-panel ledger wakes (one per routed turn) keep re-vouching for
    /// meters the live API had not answered in hours, so panel-open full passes cache-hit forever
    /// and the subscription usage meters never updated. The cache's freshness gate reads the OLDER
    /// of this stamp and `refreshedAt`, so a recovered-meter snapshot goes stale for every scope the
    /// moment its meter stamp ages out, while genuinely fresh work in the same snapshot still
    /// counts. `nil` on legacy payloads (treated as `refreshedAt`, today's behavior).
    var quotaRefreshedAt: Date?
    /// Set only on error snapshots: a stable, non-PII bucket for the failure, read by telemetry on the
    /// failure path. Always `nil` on success (and error snapshots aren't cached), so it never persists.
    var errorCategory: ErrorCategory?

    init(
        providerID: String,
        displayName: String,
        plan: String? = nil,
        lines: [MetricLine],
        refreshedAt: Date = Date(),
        usageHistory: ProviderUsageHistory? = nil,
        warning: String? = nil,
        clearsPriorMenuBarQuotaState: Bool? = nil,
        carriesPriorHistory: Bool? = nil,
        errorCategory: ErrorCategory? = nil
    ) {
        self.providerID = providerID
        self.displayName = displayName
        self.plan = plan
        self.lines = lines
        self.refreshedAt = refreshedAt
        self.usageHistory = usageHistory
        self.warning = warning
        self.clearsPriorMenuBarQuotaState = clearsPriorMenuBarQuotaState
        self.carriesPriorHistory = carriesPriorHistory
        self.errorCategory = errorCategory
        // A provider-produced snapshot assumes its meters are live until the data store says
        // otherwise (fold-only scopes carry the previous snapshot's stamp instead — see
        // `WidgetDataStore.refresh`). Legacy cached payloads decode this as nil and the cache
        // falls back to `refreshedAt`.
        self.quotaRefreshedAt = refreshedAt
    }

    func line(label: String) -> MetricLine? {
        lines.first { $0.label == label }
    }

    /// The success-path counterpart to `error(provider:message:)`: derives `providerID`/`displayName`
    /// from the provider so every runtime builds its snapshot the same way (`refreshedAt` is required
    /// so each call passes its own `now()`).
    static func make(
        provider: Provider,
        plan: String?,
        lines: [MetricLine],
        refreshedAt: Date,
        usageHistory: ProviderUsageHistory? = nil,
        warning: String? = nil,
        clearsPriorMenuBarQuotaState: Bool? = nil
    ) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            plan: plan,
            lines: lines,
            refreshedAt: refreshedAt,
            usageHistory: usageHistory,
            warning: warning,
            clearsPriorMenuBarQuotaState: clearsPriorMenuBarQuotaState
        )
    }

    /// Build an error snapshot straight from a caught error: the badge text stays the error's
    /// user-facing `localizedDescription` (UI copy is unchanged), and the telemetry category is derived
    /// from the error's `CategorizedError` conformance (falling back to `.other` for anything that
    /// doesn't classify itself). Preferred over `error(provider:message:)` wherever an `Error` is in hand.
    static func error(provider: Provider, error: Error) -> ProviderSnapshot {
        Self.error(
            provider: provider,
            message: error.localizedDescription,
            category: (error as? CategorizedError)?.errorCategory ?? .other
        )
    }

    static func error(provider: Provider, message: String, category: ErrorCategory? = nil) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            lines: [.badge(label: MetricLine.errorBadgeLabel, text: message, colorHex: "#EF4444")],
            errorCategory: category
        )
    }

    /// After a menu-bar-scoped refresh (fresh quota / progress / badge lines only), keep the prior
    /// spend/token `.values`, `.chart`, and `usageHistory` until the next `.full` refresh so the
    /// panel does not blank those rows between opens.
    ///
    /// When the icons-only pass itself is incomplete (e.g. Codex `localOnlySnapshot` after an auth
    /// failure returns no Session/Weekly meters), also keep prior `.progress` / `.badge` / `.text`
    /// lines whose labels the fresh snapshot omitted — otherwise a transient API miss would wipe the
    /// strip meters until the next successful quota fetch. Fresh lines still win on label collision.
    /// A nil/`""` plan on the fresh snapshot does not clear a previously known plan.
    func mergingMenuBarUpdate(over previous: ProviderSnapshot?) -> ProviderSnapshot {
        guard let previous else { return self }
        var merged = self
        let clearsPriorQuota = clearsPriorMenuBarQuotaState == true
        merged.clearsPriorMenuBarQuotaState = nil
        // A menu-bar merge re-stamps the result with a fresh refreshedAt. Preserved spend tiles are
        // day-labeled ("Today" / "Yesterday") but computed at the previous scan's clock: when that
        // was a different local day, keeping them under the new timestamp presents yesterday's spend
        // as current until the next .full pass. Drop those two labels on a day boundary; the next
        // full pass (the loop schedules one right after rollover) rebuilds them.
        let sameLocalDay = Calendar.current.isDate(
            previous.refreshedAt,
            inSameDayAs: merged.refreshedAt
        )
        if merged.usageHistory == nil {
            merged.usageHistory = previous.usageHistory
            // Preserved, not computed: the full pass that re-runs the deferred history must not be
            // satisfied by this merge's fresh `refreshedAt` (see `carriesPriorHistory`).
            merged.carriesPriorHistory = previous.usageHistory != nil ? true : merged.carriesPriorHistory
        }
        // Meters' freshness: when this pass produced no live quota `.progress` lines (fold-only
        // scopes), any meters on the merged snapshot were recovered from `previous` — so the
        // meters' stamp is `previous`'s, not this merge's fresh clock. Letting the fresh
        // `refreshedAt` vouch for recovered meters let a closed-panel ledger wake (one per routed
        // turn) keep hours-old subscription meters TTL-fresh forever, and panel-open passes then
        // cache-hit instead of re-reading the live quota API. Carry only when `previous` actually
        // held meters: a provider that never produces `.progress` lines (Hermes's always-full
        // snapshot, a meterless plan) would otherwise inherit a stamp that never refreshes and
        // cache-miss on every pass for fold work that is genuinely fresh.
        if !lines.contains(where: Self.isQuotaProgress),
           previous.lines.contains(where: Self.isQuotaProgress) {
            merged.quotaRefreshedAt = previous.quotaRefreshedAt ?? previous.refreshedAt
            // The recovered meters keep their caveat too: a fold-only pass's fresh success says
            // nothing about the meters' condition (e.g. "Live Codex limits unavailable" from the
            // meters-only phase that failed while this fold succeeded). A pass that produces its
            // own meters still clears the warning by returning nil, as before — and an explicit
            // quota invalidation replaces the state wholesale, warning included.
            if merged.warning == nil, !clearsPriorQuota {
                merged.warning = previous.warning
            }
        }
        if !clearsPriorQuota && (merged.plan == nil || merged.plan?.isEmpty == true) {
            merged.plan = previous.plan
        }
        let freshLabels = Set(lines.map(\.label))
        let preserved = previous.lines.filter { line in
            if !sameLocalDay, Self.isDayLabeledSpendTile(line) { return false }
            return !freshLabels.contains(line.label)
                && !(clearsPriorQuota && Self.isQuotaProgress(line))
        }
        if !preserved.isEmpty {
            merged.lines.append(contentsOf: preserved)
        }
        // localOnly / empty menuBar passes append the shared "No usage data" placeholder. Drop it
        // once prior meters were recovered so the card does not show Status alongside live rows.
        if merged.lines.contains(where: { $0 != MetricLine.noUsageData }) {
            merged.lines.removeAll { $0 == MetricLine.noUsageData }
        }
        return merged
    }

    private static func isQuotaProgress(_ line: MetricLine) -> Bool {
        if case .progress = line { return true }
        return false
    }

    /// The shared Today / Yesterday spend tiles from `SpendTileMapper` — the only lines whose label
    /// claims a relationship to "now" instead of naming a fixed metric.
    private static func isDayLabeledSpendTile(_ line: MetricLine) -> Bool {
        guard case .values = line else { return false }
        return line.label == "Today" || line.label == "Yesterday"
    }
}
