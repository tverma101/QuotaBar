import Foundation

/// Devin quota tiles. Credentials, the API call and the quota mapping live in the Rust engine
/// (`Rust/quotabar-engine/src/providers/devin.rs`); this type only describes the widgets.
@MainActor
final class DevinProvider: ProviderRuntime {
    let provider = Provider(
        id: "devin",
        displayName: "Devin",
        icon: .providerMark("devin"),
        links: [
            .init(label: "Dashboard", url: "https://app.devin.ai/settings/plans")
        ]
    )

    let transcriptUsageScanner: DevinTranscriptUsageScanner
    let now: @Sendable () -> Date
    let pricing: @Sendable () async -> ModelPricing

    init(
        transcriptUsageScanner: DevinTranscriptUsageScanner = DevinTranscriptUsageScanner(),
        now: @escaping @Sendable () -> Date = Date.init,
        pricing: @escaping @Sendable () async -> ModelPricing = { ModelPricingStore.shared.current() }
    ) {
        self.transcriptUsageScanner = transcriptUsageScanner
        self.now = now
        self.pricing = pricing
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(id: "devin.daily", provider: provider, title: "Daily", metricLabel: "Daily quota")
                .exportingLimit("daily", unit: "percent")
                .hidingWhenEmpty(),
            .percent(id: "devin.weekly", provider: provider, title: "Weekly", metricLabel: "Weekly quota")
                .exportingLimit("weekly", unit: "percent"),
            .dollarBalance(id: "devin.extra", provider: provider, title: "Extra Balance", metricLabel: "Extra usage balance", valueWord: "left").hidingWhenEmpty()
                .exportingLimit("extraUsageBalance", kind: .balance, unit: "usd", source: .value(kind: .dollars)),
            .usageTrend(provider: provider)
                .exportingHistory(
                    scope: .machineLocal,
                    estimatedCost: true,
                    sourceNote: "From local Devin sessions; dollar amounts are estimates"
                )
            // Local spend tiles from the CLI's local session usage.
        ] + WidgetDescriptor.spendTiles(provider: provider)
    }

    func hasLocalCredentials() async -> Bool {
        await RustEngine.hasLocalCredentials(providerID: provider.id)
    }

    func refresh() async -> ProviderSnapshot {
        // Fold-only passes (panel phase 2, local-accounting wakes) run the session/transcript
        // scans and priced fold in the scan-worker child when available; `localUsageSnapshot`
        // stays the in-process path. No live quota API either way — the store's merge recovers
        // the meters and plan from the prior snapshot.
        if ProviderRefreshContext.scope.suppressesLiveQuota {
            return await ScanWorkerClient.shared.foldOnlySnapshot(
                provider: provider,
                inProcessFallback: { await self.localUsageSnapshot() }
            )
        }
        // Credentials, the quota request and its mapping run in the Rust engine.
        var snapshot = await RustEngine.refresh(provider: provider)
        guard snapshot.errorCategory == nil, !Task.isCancelled else { return snapshot }
        // Menu-bar and panel-meter passes only need the quota meters. Skip the local usage scan;
        // the data store merges prior spend/history lines onto this snapshot.
        if !ProviderRefreshContext.scope.skipsLocalAccounting {
            snapshot.usageHistory = await appendLocalUsage(to: &snapshot.lines, now: now())
        }
        return snapshot
    }

    /// The fold-only snapshot: local spend tiles and Usage Trend without the quota meters,
    /// which the store recovers from the prior snapshot alongside their freshness stamp.
    private func localUsageSnapshot() async -> ProviderSnapshot {
        var lines: [MetricLine] = []
        let usageHistory = await appendLocalUsage(to: &lines, now: now())
        MetricLine.appendNoDataIfNeeded(&lines)
        return ProviderSnapshot.make(
            provider: provider,
            plan: nil,
            lines: lines,
            refreshedAt: now(),
            usageHistory: usageHistory
        )
    }

    /// Local spend tiles from the CLI's session database, falling back to exported transcripts
    /// when the database is missing or holds no metered calls. A nil scan means the local usage
    /// source could not be completely read — the provider keeps its last-good history rather than
    /// publishing a partial fold.
    private func appendLocalUsage(to lines: inout [MetricLine], now: Date) async -> ProviderUsageHistory? {
        guard !Task.isCancelled else { return nil }
        guard let scan = await transcriptUsageScanner.scan(
            daysBack: UsageHistoryWindow.lifetimeDays(through: now),
            now: now,
            pricing: await pricing()
        ) else { return nil }
        let note = "From local Devin sessions; dollar amounts are estimates"
        SpendTileMapper.appendTokenUsage(
            scan.series,
            to: &lines,
            now: now,
            unknownModelsByDay: scan.unknownModelsByDay,
            modelUsage: scan.modelUsage,
            modelSourceNote: note,
            apiEstimateByDay: scan.apiEstimateByDay,
            estimatedCostDays: scan.estimatedCostDays
        )
        SpendTileMapper.appendUsageTrend(scan.series, to: &lines, now: now, note: note)
        return ProviderUsageHistory(
            series: scan.series,
            modelUsage: scan.modelUsage,
            unknownModelsByDay: scan.unknownModelsByDay,
            apiEstimateByDay: scan.apiEstimateByDay,
            apiEstimateIncompleteDays: scan.apiEstimateIncompleteDays
        )
    }
}
