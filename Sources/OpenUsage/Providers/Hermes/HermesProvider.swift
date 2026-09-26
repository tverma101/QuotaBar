import Foundation

/// Tracks Hermes Agent usage from Hermes' own local session database (`~/.hermes/state.db`, or
/// `$HERMES_HOME/state.db`): the token buckets Hermes records per session (input, output, cache reads,
/// cache writes, reasoning), its per-session estimated cost, and its per-model attribution rows.
/// Read-only, cookie-free, and network-free — see `HermesUsageScanner`.
@MainActor
final class HermesProvider: ProviderRuntime {
    let provider = Provider(
        id: "hermes",
        displayName: "Hermes",
        icon: .providerMark("hermes"),
        links: [
            .init(label: "Dashboard", url: "https://hermes-agent.nousresearch.com/docs")
        ]
    )

    let authStore: HermesAuthStore
    let usageScanner: HermesUsageScanner
    let now: @Sendable () -> Date

    init(
        authStore: HermesAuthStore = HermesAuthStore(),
        usageScanner: HermesUsageScanner = HermesUsageScanner(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageScanner = usageScanner
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        // Today / This Week / This Month above the fold — the period token rows are the card's core —
        // with the Usage Trend chart behind the caret.
        [
            .values(id: "hermes.today", provider: provider, title: "Today", isUsagePeriod: true),
            .values(id: "hermes.thisweek", provider: provider, title: "This Week", isUsagePeriod: true),
            .values(id: "hermes.thismonth", provider: provider, title: "This Month", isUsagePeriod: true),
            .usageTrend(provider: provider)
                .exportingHistory(
                    scope: .machineLocal,
                    estimatedCost: true,
                    sourceNote: HermesUsageMapper.sourceNote
                )
        ]
    }

    func hasLocalCredentials() async -> Bool {
        // Same source as `refresh()`: the Hermes state database on disk. Local-only, off the main actor.
        await loadOffMainActor { [authStore] in authStore.hasDatabase() }
    }

    func refresh() async -> ProviderSnapshot {
        // History-skip note: Hermes has no remote quota API — Today/Week/Month tiles ARE the local
        // DB scan. Leave always-full; unpinned Hermes is omitted from `.menuBar` passes by the filter.
        let refreshedAt = now()

        let scan: HermesUsageScan?
        do {
            // The scanner is a Sendable struct whose async scan hops off the main actor itself.
            scan = try await usageScanner.scan(now: refreshedAt)
        } catch {
            return ProviderSnapshot.error(provider: provider, error: error)
        }

        guard let scan else {
            return ProviderSnapshot.error(provider: provider, error: HermesUsageError.notDetected)
        }

        let lines = HermesUsageMapper.lines(scan: scan, now: refreshedAt)
        return ProviderSnapshot.make(
            provider: provider,
            plan: nil,
            lines: lines,
            refreshedAt: refreshedAt,
            usageHistory: ProviderUsageHistory(
                series: scan.daily,
                modelUsage: nil,
                unknownModelsByDay: [:]
            )
        )
    }
}
