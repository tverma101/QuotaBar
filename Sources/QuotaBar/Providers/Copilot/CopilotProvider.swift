import Foundation

@MainActor
final class CopilotProvider: ProviderRuntime {
    /// `UserDefaults` key caching the slug of the org whose billing carried Copilot credit usage, so
    /// steady-state refreshes make one billing call instead of re-probing every org.
    static let billingOrgDefaultsKey = "copilot.billingOrg"
    static let billingOrgProbeRetryAfterKey = "copilot.billingOrgProbeRetryAfter"
    static let billingOrgRateLimitRetryAfterKey = "copilot.billingOrgRateLimitRetryAfter"
    static let billingOrgProbeBackoff: TimeInterval = 5 * 60

    private struct OrgBillingRateLimit: Error {
        let retryAfter: String?
        let rateLimitReset: String?
    }

    let provider = Provider(
        id: "copilot",
        displayName: "Copilot",
        icon: .providerMark("copilot"),
        links: [
            .init(label: "Status", url: "https://www.githubstatus.com/"),
            .init(label: "Dashboard", url: "https://github.com/settings/billing")
        ]
    )

    let authStore: CopilotAuthStore
    let usageClient: CopilotUsageClient
    let orgBillingClient: CopilotOrgBillingClient
    let defaults: UserDefaults
    let now: @Sendable () -> Date

    init(
        authStore: CopilotAuthStore = CopilotAuthStore(),
        usageClient: CopilotUsageClient = CopilotUsageClient(),
        orgBillingClient: CopilotOrgBillingClient = CopilotOrgBillingClient(),
        defaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.orgBillingClient = orgBillingClient
        self.defaults = defaults
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(id: "copilot.premium", provider: provider, title: "Credits")
                .exportingLimit("premiumCredits", unit: "credits", source: .progressOrValue(kind: .count)),
            .values(id: "copilot.extra", provider: provider, title: "Extra Usage", selection: .kind(.count)).hidingWhenEmpty()
                .exportingLimit("extraUsage", unit: "count", source: .value(kind: .count)),
            .values(id: "copilot.orgCredits", provider: provider, title: "Org Credits", selection: .kind(.count))
                .exportingLimit("orgCredits", unit: "credits", source: .value(kind: .count, label: "credits")),
            .values(id: "copilot.orgSpend", provider: provider, title: "Org Spend", selection: .kind(.dollars), valueWord: "spent")
                .exportingLimit("orgSpend", unit: "usd", source: .value(kind: .dollars)),
            .percent(id: "copilot.chat", provider: provider, title: "Chat")
                .exportingLimit("chat", unit: "percent"),
            .percent(id: "copilot.completions", provider: provider, title: "Completions")
                .exportingLimit("completions", unit: "percent")
        ]
    }

    func hasLocalCredentials() async -> Bool {
        // Same source as `refresh()`: editor config, gh config, or the gh keychain entry.
        do {
            return try await loadOffMainActor { [authStore] in try authStore.loadToken() } != nil
        } catch CopilotAuthError.credentialPermissionRequired {
            // The local probe proved a Keychain credential exists; keep the provider enabled so its
            // permission error is visible and the user can grant access from Refresh.
            return true
        } catch CopilotAuthError.credentialsUnreadable {
            // Keep an indeterminate Keychain-only login visible so the card can show its repair error.
            return true
        } catch CopilotAuthError.invalidCredentials {
            // A malformed editor config is present and needs repair; don't hide the provider in seeding.
            return true
        } catch {
            return false
        }
    }

    func refresh() async -> ProviderSnapshot {
        // Distinguish "no credential" from "macOS won't release the credential": the second needs one
        // Refresh and an "Always Allow", not a re-login.
        let token: CopilotToken?
        do {
            token = try await loadOffMainActor { [authStore] in try authStore.loadToken() }
        } catch is CancellationError {
            return cancelledRefreshSnapshot(provider: provider)
        } catch {
            if ProviderCancellation.isCancellation(error) {
                return cancelledRefreshSnapshot(provider: provider)
            }
            return ProviderSnapshot.error(provider: provider, error: error)
        }
        guard !Task.isCancelled else { return cancelledRefreshSnapshot(provider: provider) }
        guard let token else {
            return ProviderSnapshot.error(provider: provider, error: CopilotAuthError.notLoggedIn)
        }

        do {
            let response = try await usageClient.fetchUsage(token: token.value)
            try Task.checkCancellation()

            if response.statusCode == 401 {
                return ProviderSnapshot.error(provider: provider, error: CopilotAuthError.tokenInvalid)
            }
            if response.statusCode == 403 {
                return ProviderSnapshot.error(provider: provider, error: CopilotAuthError.accessDenied)
            }
            guard (200..<300).contains(response.statusCode) else {
                return ProviderSnapshot.error(provider: provider, error: CopilotUsageError.requestFailed(response.statusCode))
            }

            let mapped = try CopilotUsageMapper.map(response)

            // An org-managed (token-based-billing) seat has no per-seat percent meter, so the real
            // usage lives in the org's billing. Look it up there — best-effort: an org admin sees
            // Org Credits / Org Spend, everyone else keeps the plan-only card as before. Gated on
            // the mapper's explicit flag, never on `lines` being empty (issue #839). Appended rather
            // than replacing: `mapped.lines` can already carry the user's own personal Credits count
            // (issue #1094), which must survive alongside whatever the org lookup adds.
            var lines = mapped.lines
            if mapped.isOrgManagedSeat {
                lines += try await orgBillingLines(token: token.value)
            }

            return ProviderSnapshot.make(provider: provider, plan: mapped.plan, lines: lines, refreshedAt: now())
        } catch let error as CopilotUsageError {
            return ProviderSnapshot.error(provider: provider, error: error)
        } catch {
            if ProviderCancellation.isCancellation(error) {
                return cancelledRefreshSnapshot(provider: provider)
            }
            return ProviderSnapshot.error(provider: provider, error: CopilotUsageError.connectionFailed)
        }
    }

    // MARK: - Org billing lookup

    /// Org-level Copilot billing lines for an org-managed seat. Tries the cached org first, then probes
    /// every org the user belongs to, remembering the first whose billing summary carries Copilot credit
    /// usage. Returns `[]` when nothing is readable — a 403 is the *expected* outcome for a plain org
    /// member (only owners and billing managers can read org billing), so it degrades to today's
    /// plan-only card instead of erroring the provider.
    private func orgBillingLines(token: String) async throws -> [MetricLine] {
        try Task.checkCancellation()
        if let retryAfter = defaults.object(forKey: Self.billingOrgRateLimitRetryAfterKey) as? Date {
            if retryAfter > now() { return [] }
            defaults.removeObject(forKey: Self.billingOrgRateLimitRetryAfterKey)
        }
        if ProviderRefreshContext.isManual {
            defaults.removeObject(forKey: Self.billingOrgProbeRetryAfterKey)
        } else if let retryAfter = defaults.object(forKey: Self.billingOrgProbeRetryAfterKey) as? Date,
                  retryAfter > now()
        {
            return []
        }

        var attemptedOrgs = Set<String>()
        if let cached = defaults.string(forKey: Self.billingOrgDefaultsKey) {
            attemptedOrgs.insert(cached.lowercased())
            do {
                if let lines = try await usageLines(org: cached, token: token) {
                    defaults.removeObject(forKey: Self.billingOrgProbeRetryAfterKey)
                    return lines
                }
                // The cached org answered but no longer shows Copilot usage (left the org, lost the
                // billing role, org stopped using Copilot) — forget it and re-probe from scratch.
                defaults.removeObject(forKey: Self.billingOrgDefaultsKey)
            } catch {
                try ProviderCancellation.rethrowIfCancellation(error)
                if let rateLimit = error as? OrgBillingRateLimit {
                    recordOrgRateLimitCooldown(retryAfter: rateLimit.retryAfter, rateLimitReset: rateLimit.rateLimitReset)
                    AppLog.info(LogTag.plugin("copilot"), "org billing rate limited; pausing org discovery")
                    return []
                }
                // Transient failure: log it and keep the cached org for the next refresh.
                AppLog.warn(LogTag.plugin("copilot"), "org billing lookup failed for the remembered org: \(error.localizedDescription)")
                return []
            }
        }

        let orgs: [String]
        do {
            let response = try await orgBillingClient.fetchUserOrgs(token: token)
            try Task.checkCancellation()
            if let partialStatus = response.header("x-quotabar-partial-status") {
                if let statusCode = Int(partialStatus) {
                    let rateLimited = response.header("x-quotabar-partial-rate-limit") == "true"
                        || CopilotOrgBillingClient.isRateLimitResponse(
                            statusCode: statusCode,
                            retryAfter: response.header("retry-after"),
                            rateLimitRemaining: response.header("x-ratelimit-remaining")
                        )
                    if rateLimited {
                        recordOrgRateLimitCooldown(
                            retryAfter: response.header("retry-after"),
                            rateLimitReset: response.header("x-ratelimit-reset")
                        )
                        AppLog.info(LogTag.plugin("copilot"), "org list rate limited; pausing org discovery")
                        return []
                    } else if statusCode == 403 {
                        recordOrgProbeCooldown()
                    }
                    AppLog.warn(LogTag.plugin("copilot"), "org list pagination stopped at HTTP \(statusCode); using completed pages")
                } else {
                    AppLog.warn(LogTag.plugin("copilot"), "org list pagination stopped after \(partialStatus); using completed pages")
                }
            }
            if CopilotOrgBillingClient.isRateLimitResponse(response) {
                recordOrgRateLimitCooldown(
                    retryAfter: response.header("retry-after"),
                    rateLimitReset: response.header("x-ratelimit-reset")
                )
                AppLog.info(LogTag.plugin("copilot"), "org list rate limited; pausing org discovery")
                return []
            }
            guard response.statusCode == 200 else {
                // 403 here means the token lacks `read:org` (editor-plugin tokens can) — expected, not
                // an error. Anything else is still worth a diagnostic, never a failed card.
                if response.statusCode == 403 {
                    recordOrgProbeCooldown()
                }
                AppLog.info(LogTag.plugin("copilot"), "org list HTTP \(response.statusCode); skipping org billing lookup")
                return []
            }
            orgs = CopilotOrgBillingMapper.orgLogins(response)
        } catch {
            try ProviderCancellation.rethrowIfCancellation(error)
            AppLog.warn(LogTag.plugin("copilot"), "org list fetch failed: \(error.localizedDescription)")
            return []
        }

        var sawTransientFailure = false
        for org in orgs where !attemptedOrgs.contains(org.lowercased()) {
            try Task.checkCancellation()
            do {
                if let lines = try await usageLines(org: org, token: token) {
                    defaults.set(org, forKey: Self.billingOrgDefaultsKey)
                    defaults.removeObject(forKey: Self.billingOrgProbeRetryAfterKey)
                    return lines
                }
            } catch {
                try ProviderCancellation.rethrowIfCancellation(error)
                if let rateLimit = error as? OrgBillingRateLimit {
                    recordOrgRateLimitCooldown(retryAfter: rateLimit.retryAfter, rateLimitReset: rateLimit.rateLimitReset)
                    AppLog.info(LogTag.plugin("copilot"), "org billing rate limited; pausing org discovery")
                    return []
                }
                sawTransientFailure = true
                // One org's billing having an outage must not hide another org's usage — keep probing.
                AppLog.warn(LogTag.plugin("copilot"), "org billing summary failed for one org; trying the next: \(error.localizedDescription)")
            }
        }
        if !sawTransientFailure {
            defaults.set(now().addingTimeInterval(Self.billingOrgProbeBackoff), forKey: Self.billingOrgProbeRetryAfterKey)
        }
        return []
    }

    /// One org's billing summary → metric lines, or `nil` when this org definitively has nothing to show
    /// (no access — the expected 403 for plain members — or no Copilot credit usage in the summary).
    /// Throws for transient failures (transport errors, 429, 5xx) so callers keep the cached org instead
    /// of treating a brief outage as a stale org.
    private func usageLines(org: String, token: String) async throws -> [MetricLine]? {
        try Task.checkCancellation()
        let response = try await orgBillingClient.fetchUsageSummary(org: org, token: token)
        try Task.checkCancellation()
        if CopilotOrgBillingClient.isRateLimitResponse(response) {
            let retryAfter = response.header("retry-after")
            let rateLimitReset = response.header("x-ratelimit-reset")
            recordOrgRateLimitCooldown(retryAfter: retryAfter, rateLimitReset: rateLimitReset)
            if response.statusCode == 200,
               let lines = CopilotOrgBillingMapper.usageLines(response) {
                // This response is usable, but its rate headers still govern every later request.
                return lines
            }
            throw OrgBillingRateLimit(retryAfter: retryAfter, rateLimitReset: rateLimitReset)
        }
        guard response.statusCode == 200 else {
            AppLog.debug(LogTag.plugin("copilot"), "org billing summary for one org: HTTP \(response.statusCode)")
            if response.statusCode >= 500 {
                throw CopilotUsageError.requestFailed(response.statusCode)
            }
            return nil
        }
        return CopilotOrgBillingMapper.usageLines(response)
    }

    private func recordOrgProbeCooldown() {
        defaults.set(now().addingTimeInterval(Self.billingOrgProbeBackoff), forKey: Self.billingOrgProbeRetryAfterKey)
    }

    private func recordOrgRateLimitCooldown(retryAfter: String?, rateLimitReset: String?) {
        let currentTime = now()
        var retryDate: Date?
        if let retryAfter {
            if let seconds = TimeInterval(retryAfter), seconds >= 0 {
                retryDate = currentTime.addingTimeInterval(seconds)
            } else if let date = Self.httpDateFormatter.date(from: retryAfter) {
                retryDate = date
            }
        }
        if let rateLimitReset, let epoch = TimeInterval(rateLimitReset) {
            let resetDate = Date(timeIntervalSince1970: epoch)
            retryDate = retryDate.map { max($0, resetDate) } ?? resetDate
        }
        defaults.set(
            retryDate ?? currentTime.addingTimeInterval(Self.billingOrgProbeBackoff),
            forKey: Self.billingOrgRateLimitRetryAfterKey
        )
    }

    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return formatter
    }()
}
