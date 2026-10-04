import Foundation

enum ProviderRefreshContext {
    /// How much work a refresh pass should do.
    /// - `menuBar`: auth + quota/rate-limit meters the status-item strip needs; skip expensive
    ///   local JSONL / CSV / history scans where cleanly separable (Codex, Claude, Cursor,
    ///   Antigravity, Grok). `WidgetDataStore.refreshAll` also limits the pass to pinned
    ///   providers (plus notification-relevant ones when quota alerts are on). Default for
    ///   background ticks while the popover is closed.
    /// - `full`: complete snapshot including token/spend/history (panel open, manual refresh, CLI).
    enum Scope: Sendable {
        case menuBar
        case full

        var isFull: Bool {
            if case .full = self { return true }
            return false
        }
    }

    /// True only for the user's explicit Refresh Now action. Snapshot-only panel presentation
    /// never opens another app's Keychain dialog.
    @TaskLocal static var isManual = false
    /// Shared by all provider refresh tasks from one explicit Refresh Now action. Claude can claim it
    /// only when a silent credential read proves that access needs user interaction, limiting that
    /// action to one Keychain dialog even when several Claude account cards are enabled.
    @TaskLocal static var credentialInteractionGate: CredentialInteractionGate? = nil
    /// Defaults to `.full` so tests, CLI, and any unscoped call site keep today's behavior.
    @TaskLocal static var scope: Scope = .full
    /// Provider refresh entry points opt into the process-wide CPU allowance, including startup,
    /// menu-bar, full-panel, and local-API reads whose providers can perform local accounting.
    /// Focused unit tests stay unthrottled unless they explicitly measure the budget.
    @TaskLocal static var accountingCPUThrottleEnabled = false
    /// Lightweight background menu-bar scope keeps existing catalogues on disk; missing catalogues
    /// may still download. Full accounting refreshes perform due catalogue discovery.
    @TaskLocal static var skipModelCatalogRefresh = false
}

/// Run an explicit full-history refresh under the shared CPU allowance. Keep force-refresh entry
/// points in views/settings on the same path as panel-open and manual-refresh passes.
func withThrottledFullAccounting<T: Sendable>(
    _ operation: @Sendable () async throws -> T
) async rethrows -> T {
    try await ProviderRefreshContext.$scope.withValue(.full) {
        try await ProviderRefreshContext.$accountingCPUThrottleEnabled.withValue(true) {
            try await operation()
        }
    }
}

final class CredentialInteractionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}

/// One AI provider QuotaBar can track. A conformer reads credentials already on the machine, calls the
/// provider's API, and normalizes the result into a `ProviderSnapshot` of `MetricLine` values that the UI
/// renders. See `docs/adding-a-provider.md` for the full walkthrough.
///
/// `refresh()` returns the latest snapshot. Build its `lines` from the app's small metric vocabulary,
/// choosing the case by the shape of the value:
/// - `.progress` — a bounded meter with a `used`/`limit` and a `format` (percent, dollars, or count). Use
///   for anything with a ceiling: session/weekly quotas, credits with a cap. Add `resetsAt` when the
///   window resets at a known time.
/// - `.values` — one or more typed, unbounded numbers. Use for spend, balances, token counts, and other
///   limitless numeric rows; formatting stays at the display edge.
/// - `.badge` — a short status pill (e.g. "Disabled", or a pay-as-you-go cap). Use for state, not a number
///   to fill a bar with.
/// - `.chart` — dated numeric points rendered as a compact usage trend.
/// - `.text` — a string-valued provider notice preserved for the local API. Dashboard widgets do not
///   parse display text; use a typed line above for every widget descriptor.
///
/// On failure, return `ProviderSnapshot.error(provider:error:)` with a typed provider error so the error
/// surfaces loudly in the UI and telemetry can report a stable, non-PII category. Use the message-only
/// factory only when no typed error exists.
@MainActor
protocol ProviderRuntime: AnyObject {
    var provider: Provider { get }
    var widgetDescriptors: [WidgetDescriptor] { get }

    func refresh() async -> ProviderSnapshot

    /// Whether credentials for this provider already exist on this machine — a cheap, local-only probe
    /// (files, keychain, SQLite; never the network). Used once, on a fresh install's first launch, by
    /// `FirstRunSeeder` to enable exactly the providers the user actually has. Mirror the credential
    /// sources `refresh()` reads, and run blocking loads via `loadOffMainActor`.
    func hasLocalCredentials() async -> Bool
}

/// Run a blocking, `Sendable` credential load off the MainActor.
///
/// Auth stores read credentials via the `security` (keychain) and `sqlite3` CLIs, whose `ProcessRunner`
/// waits block the calling thread for up to ~5s each. Those loads run at the top of a provider's
/// `@MainActor refresh()`, so calling them inline freezes the popover and the periodic-refresh loop for
/// the whole subprocess window (Cursor issues several reads per refresh — up to ~25s). Offloading to a
/// detached task moves the wait onto a background executor; the `Sendable` result crosses back cleanly.
/// It is awaited immediately, so it reads like a normal call while no longer blocking the actor.
func loadOffMainActor<T: Sendable>(_ load: @escaping @Sendable () -> T) async -> T {
    await Task.detached(priority: .utility, operation: load).value
}

/// Throwing counterpart for blocking credential reads that distinguish absence from access failure.
func loadOffMainActor<T: Sendable>(_ load: @escaping @Sendable () throws -> T) async throws -> T {
    try await Task.detached(priority: .utility, operation: load).value
}
