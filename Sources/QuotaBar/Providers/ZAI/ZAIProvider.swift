import Foundation

@MainActor
final class ZAIProvider: ProviderRuntime {
    let provider = Provider(
        id: "zai",
        displayName: "Z.ai",
        icon: .providerMark("zai"),
        links: [
            ProviderLink(label: "Dashboard", url: "https://z.ai/manage-apikey/coding-plan/personal/my-plan"),
            ProviderLink(label: "API Keys", url: "https://z.ai/manage-apikey/apikey-list")
        ]
    )

    let authStore: ZAIAuthStore
    let usageClient: ZAIUsageClient
    let zcodeScanner: ZCodeUsageScanner
    let pricing: @Sendable () async -> ModelPricing
    let now: @Sendable () -> Date

    /// The plan name changes about once a month, so re-reading it on every refresh doubled the
    /// provider's request count for a near-constant value.
    static let planCacheInterval: TimeInterval = 3600
    private var cachedSubscription: Data?
    private var cachedSubscriptionApiKey: String?
    private var cachedSubscriptionAt: Date?

    init(
        zcodeScanner: ZCodeUsageScanner = ZCodeUsageScanner(),
        authStore: ZAIAuthStore = ZAIAuthStore(),
        usageClient: ZAIUsageClient = ZAIUsageClient(),
        pricing: @escaping @Sendable () async -> ModelPricing = { ModelPricingStore.shared.current() },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.zcodeScanner = zcodeScanner
        self.pricing = pricing
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(id: "zai.session", provider: provider, title: "Session",
                     metricLabel: "Session")
                .exportingLimit("session", unit: "percent"),
            .percent(id: "zai.weekly", provider: provider, title: "Weekly",
                     metricLabel: "Weekly")
                .exportingLimit("weekly", unit: "percent"),
            .boundedCount(id: "zai.weekendBuild", provider: provider, title: "Weekend Build",
                          metricLabel: "Weekend Build", limit: 500_000_000, suffix: "tokens")
                .hidingWhenEmpty(),
            .boundedCount(id: "zai.webSearches", provider: provider, title: "Web Searches",
                          metricLabel: "Web Searches", limit: 1000, suffix: "searches",
                          periodDurationMs: ZAIUsageMapper.monthlyPeriodMs)
                .exportingLimit("webSearches", unit: "searches")
                .hidingWhenEmpty()
        ] + WidgetDescriptor.spendTiles(provider: provider).map { descriptor in
            // Declare the local history resource on an existing tile so the Usage History screen
            // counts ZCode's recorded days — no new metric, just the stats wiring.
            descriptor.id == "zai.last30"
                ? descriptor.exportingHistory(
                    scope: .machineLocal,
                    estimatedCost: true,
                    sourceNote: "From your ZCode usage history (estimated)"
                )
                : descriptor
        }
    }

    func hasLocalCredentials() async -> Bool {
        // Same source as `refresh()`: a stored or environment-exported API key. A present but
        // unreadable config still counts so refresh can surface its repair message.
        await loadOffMainActor { [authStore, zcodeScanner] in
            authStore.hasKeyOrUnreadableConfig() || zcodeScanner.hasHistory()
        }
    }

    func refresh() async -> ProviderSnapshot {
        let quota = await refreshQuota()
        guard quota.errorCategory != .cancelled, !Task.isCancelled else { return quota }
        do {
            let currentNow = now()
            let modelPricing = await pricing()
            let usage = try await loadOffMainActor { [zcodeScanner] in try zcodeScanner.usage(pricing: modelPricing, now: currentNow) }
            guard let usage, (usage.totalTokens ?? 0) > 0 || usage.weekendBuild != nil || usage.dailySeries != nil else { return quota }
            var result = quota
            if case .badge(_, let message, _, _) = result.lines.first(where: \.isError) {
                // Keep local usage usable even when the separate Coding Plan request fails.
                // When no API key is configured at all, do not surface an amber error warning
                // over legitimate local ZCode usage.
                let isPureLocalUser = authStore.keyStatus() == .notSet && quota.errorCategory == .notLoggedIn
                let warning = isPureLocalUser ? nil : message
                if warning != nil {
                    DiagnosticGate.logOnce(for: "auth.zai.quota-with-zcode.failure") {
                        AppLog.warn(LogTag.auth("zai"), "quota refresh failed: \(message)")
                    }
                }
                result = .make(
                    provider: provider,
                    plan: quota.plan ?? usage.planName,
                    lines: [],
                    refreshedAt: now(),
                    warning: warning
                )
                result.quotaRefreshedAt = .distantPast
                result.clearsPriorMenuBarQuotaState = quota.clearsPriorMenuBarQuotaState
            } else if result.plan == nil, let localPlan = usage.planName {
                result.plan = localPlan
            }
            if quota.lines.allSatisfy({ !$0.isError }) {
                DiagnosticGate.clearFailure("auth.zai.quota-with-zcode.failure")
            }

            if let weekend = usage.weekendBuild {
                // If it has expired relative to currentNow, do not display it (auto-remove).
                if let expiresAt = weekend.expiresAt, expiresAt <= currentNow {
                    // Expired: auto-remove, do not append to result.lines
                } else {
                    var detail: String? = nil
                    let resetsAt: Date?
                    if let effectiveAt = weekend.effectiveAt, effectiveAt > currentNow {
                        detail = Formatters.deadlineLabel("Starts", at: effectiveAt, mode: .relative, now: currentNow)
                        resetsAt = effectiveAt
                    } else if let expiresAt = weekend.expiresAt {
                        detail = Formatters.deadlineLabel("Expires", at: expiresAt, mode: .relative, now: currentNow)
                        resetsAt = weekend.resetsAt
                    } else {
                        resetsAt = weekend.resetsAt
                    }
                    result.lines.append(.progress(
                        label: weekend.label,
                        used: weekend.used,
                        limit: weekend.limit,
                        format: .count(suffix: "tokens"),
                        resetsAt: resetsAt,
                        detail: detail
                    ))
                    result.quotaRefreshedAt = currentNow
                }
            }

            if let scan = usage.logScan {
                SpendTileMapper.appendTokenUsage(
                    scan.series,
                    to: &result.lines,
                    now: currentNow,
                    unknownModelsByDay: scan.unknownModelsByDay,
                    modelUsage: scan.modelUsage,
                    modelSourceNote: "From your ZCode usage history (estimated)",
                    apiEstimateByDay: scan.apiEstimateByDay,
                    estimatedCostDays: scan.estimatedCostDays
                )
                // Feed the Usage History screen (cross-provider stats) with the same scan the tiles
                // render, so ZCode's recorded days are accounted everywhere, not just on the card.
                result.usageHistory = ProviderUsageHistory(
                    series: scan.series,
                    modelUsage: scan.modelUsage,
                    unknownModelsByDay: scan.unknownModelsByDay,
                    apiEstimateByDay: scan.apiEstimateByDay,
                    apiEstimateIncompleteDays: scan.apiEstimateIncompleteDays,
                    estimatedCostDays: scan.estimatedCostDays
                )
            } else if let dailySeries = usage.dailySeries {
                SpendTileMapper.appendTokenUsage(dailySeries, to: &result.lines, now: currentNow)
            }
            return result
        } catch {
            if ProviderCancellation.isCancellation(error) { return cancelledRefreshSnapshot(provider: provider) }
            AppLog.warn(LogTag.auth("zai"), "ZCode token history read failed: \(error.localizedDescription)")
            var result = quota
            result.historyWarning = "Couldn't read ZCode token usage."
            return result
        }
    }

    func unloadLocalAccountingCachesForMemoryPressure() async {
        zcodeScanner.unloadCachesForMemoryPressure()
    }

    private func refreshQuota() async -> ProviderSnapshot {
        let auth: ZAIAuth?
        do {
            auth = try await loadOffMainActor { [authStore] in try authStore.loadAPIKeyForRefresh() }
        } catch {
            return ProviderSnapshot.error(provider: provider, error: error)
        }
        guard let auth else {
            return ProviderSnapshot.error(provider: provider, error: ZAIAuthError.missingKey)
        }

        // The quota endpoint is required; the subscription endpoint is best-effort (plan name only),
        // so a failure there must not blank out the meters. Both are fetched, and whatever the quota
        // returns is mapped alongside the plan name if the subscription succeeded.
        let quota: QuotaResult
        let subscription: Data?
        do {
            quota = try await load { try await usageClient.fetchQuota(apiKey: auth.apiKey) }
            subscription = try await subscriptionBody(apiKey: auth.apiKey)
        } catch {
            return ProviderSnapshot.error(provider: provider, error: error)
        }

        switch quota {
        case .success(let body):
            // A valid key whose account has no GLM Coding Plan gets a 2xx with `success:false`. Surface
            // that as a clear provider warning (the header's amber notice) rather than three blank "No
            // data" meters that don't explain why nothing's there.
            if ZAIUsageMapper.isNoCodingPlan(body) {
                return ProviderSnapshot.error(
                    provider: provider,
                    error: ZAIUsageError.noCodingPlan,
                    clearsPriorMenuBarQuotaState: true
                )
            }
            do {
                let mapped = try ZAIUsageMapper.map(quotaBody: body, subscriptionBody: subscription, now: now())
                return ProviderSnapshot.make(provider: provider, plan: mapped.plan, lines: mapped.lines, refreshedAt: now())
            } catch {
                return ProviderSnapshot.error(provider: provider, error: error)
            }
        case .authFailure:
            return ProviderSnapshot.error(provider: provider, error: ZAIAuthError.invalidKey)
        case .failed(let error):
            return ProviderSnapshot.error(provider: provider, error: error)
        }
    }

    /// Run the required quota call and classify the outcome: the body on 2xx, an auth failure on
    /// 401/403, or a typed failure for any other non-2xx, transport error, or empty body.
    private func load(_ call: () async throws -> HTTPResponse) async throws -> QuotaResult {
        try Task.checkCancellation()
        do {
            let response = try await call()
            try Task.checkCancellation()
            if response.statusCode == 401 || response.statusCode == 403 { return .authFailure }
            guard (200..<300).contains(response.statusCode) else {
                return .failed(.requestFailed(response.statusCode))
            }
            return .success(response.body)
        } catch {
            try ProviderCancellation.rethrowIfCancellation(error)
            return .failed(.connectionFailed)
        }
    }

    /// The subscription body, which carries the plan name.
    ///
    /// It is kept for an hour (a manual refresh re-reads it right away), and the last good value
    /// survives a failed request, so a transient blip no longer drops the plan from the card.
    private func subscriptionBody(apiKey: String) async throws -> Data? {
        if !ProviderRefreshContext.isManual,
           let cachedSubscriptionAt,
           cachedSubscriptionApiKey == apiKey,
           now().timeIntervalSince(cachedSubscriptionAt) < Self.planCacheInterval {
            return cachedSubscription
        }
        let body = try await loadOptional { try await usageClient.fetchSubscription(apiKey: apiKey) }
        guard let body else { return cachedSubscription }
        cachedSubscription = body
        cachedSubscriptionApiKey = apiKey
        cachedSubscriptionAt = now()
        return body
    }

    /// Run the optional subscription call — never throws into the snapshot: a transport error, a
    /// non-2xx, or an auth failure all just mean "no plan name this refresh". Returns just the body
    /// (the only thing the mapper consumes); the outcome is otherwise discarded.
    private func loadOptional(_ call: () async throws -> HTTPResponse) async throws -> Data? {
        try Task.checkCancellation()
        do {
            let response = try await call()
            try Task.checkCancellation()
            guard (200..<300).contains(response.statusCode) else { return nil }
            return response.body
        } catch {
            try ProviderCancellation.rethrowIfCancellation(error)
            return nil
        }
    }
}

extension ZAIProvider: APIKeyManaging {
    var apiKeyStatus: APIKeyStatus { authStore.keyStatus() }
    func currentAPIKey() -> String? { authStore.currentAPIKey() }
    func saveAPIKey(_ key: String) throws { try authStore.saveAPIKey(key) }
    func deleteAPIKey() throws { try authStore.deleteAPIKey() }
}

private enum QuotaResult {
    case success(Data)
    case authFailure
    case failed(ZAIUsageError)
}
