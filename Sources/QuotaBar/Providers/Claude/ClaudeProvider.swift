import CryptoKit
import Foundation

@MainActor
final class ClaudeProvider: ProviderRuntime {
    static func makeProvider(id: String = "claude", displayName: String = "Claude") -> Provider {
        Provider(
            id: id,
            displayName: displayName,
            icon: .providerMark("claude"),
            links: [
                .init(label: "Status", url: "https://status.anthropic.com/"),
                .init(label: "Dashboard", url: "https://claude.ai/settings/usage")
            ]
        )
    }

    let provider: Provider
    let authStore: ClaudeAuthStore
    let usageClient: ClaudeUsageClient
    let logUsageScanner: ClaudeLogUsageScanner
    let piUsageScanner: PiUsageScanner
    let allowsUnattributedPiUsage: Bool
    let now: @Sendable () -> Date
    let pricing: @Sendable () async -> ModelPricing

    /// Last successful live-usage result and a rate-limit cooldown, carried across refreshes (the provider
    /// is a long-lived singleton). `/api/oauth/usage` rate-limits aggressively, so on a 429 we serve the
    /// last-good bars with a staleness note instead of blanking the dashboard, and skip the live call
    /// entirely until the cooldown expires so we don't keep hammering an endpoint that's already limiting
    /// us. Mirrors the legacy plugin's `cachedUsageData` + `rateLimitedUntilMs`.
    private var cachedCredentialFingerprint: Data?
    private var verifiedCredentialFingerprint: Data?
    private var lastGoodUsage: ClaudeMappedUsage?
    private var rateLimitedUntil: Date?
    private static let rateLimitCooldown: TimeInterval = 5 * 60

    init(
        provider: Provider = ClaudeProvider.makeProvider(),
        authStore: ClaudeAuthStore = ClaudeAuthStore(),
        usageClient: ClaudeUsageClient = ClaudeUsageClient(),
        logUsageScanner: ClaudeLogUsageScanner = ClaudeLogUsageScanner(),
        piUsageScanner: PiUsageScanner = .shared,
        allowsUnattributedPiUsage: Bool = true,
        now: @escaping @Sendable () -> Date = Date.init,
        pricing: @escaping @Sendable () async -> ModelPricing = { ModelPricingStore.shared.current() }
    ) {
        self.provider = provider
        self.authStore = authStore
        self.usageClient = usageClient
        self.logUsageScanner = logUsageScanner
        self.piUsageScanner = piUsageScanner
        self.allowsUnattributedPiUsage = allowsUnattributedPiUsage
        self.now = now
        self.pricing = pricing
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(id: "\(provider.id).session", provider: provider, title: "Session", sessionStartSignal: .missingResetDate)
                .exportingLimit("session", unit: "percent"),
            .percent(id: "\(provider.id).weekly", provider: provider, title: "Weekly")
                .exportingLimit("weekly", unit: "percent"),
            .percent(id: "\(provider.id).fable", provider: provider, title: "Fable")
                .exportingLimit("fable", unit: "percent")
                .hidingWhenEmpty(),
            .percent(id: "\(provider.id).sonnet", provider: provider, title: "Sonnet")
                .exportingLimit("sonnet", unit: "percent")
                .hidingWhenEmpty(),
            .boundedDollars(id: "\(provider.id).extra", provider: provider, title: "Extra Usage", metricLabel: "Extra usage spent", limit: 100, valueWord: "spent")
                .exportingLimit("extraUsage", unit: "usd", source: .progressOrValue(kind: .dollars))
                .hidingWhenEmpty(),
            .usageTrend(provider: provider)
                .exportingHistory(
                    scope: .machineLocal,
                    estimatedCost: true,
                    sourceNote: "From your Claude usage history (estimated)"
                )
        ] + WidgetDescriptor.spendTiles(provider: provider)
    }

    func hasLocalCredentials() async -> Bool {
        // Never trigger another app's Keychain prompt during a local credential probe. Encrypted Desktop
        // material still counts as a local login; only the explicit Refresh Now action may request access.
        let probe: (load: ClaudeCredentialLoad, hasKeychainMaterial: Bool?) = await loadOffMainActor { [authStore] in
            let load = authStore.loadCredentialSet()
            guard !load.keychainReadCancelled else { return (load, nil as Bool?) }
            return (load, authStore.hasKeychainCredentialMaterial())
        }
        let load = probe.load
        if load.keychainReadCancelled { return true }
        if load.candidates.contains(where: \.hasUsableAccessToken) { return true }
        if load.keychainPermissionRequired || load.keychainReadFailed { return true }
        if load.credentialsFileUnreadable { return true }
        if load.credentialsFileInvalid { return true }
        // `nil` means the silent attributes probe could not determine whether an item exists.
        // Keep the provider detectable rather than turning an unavailable Keychain into “not logged in.”
        if probe.hasKeychainMaterial != false { return true }
        return load.desktopStatus == .permissionRequired
            || load.desktopStatus == .unreadable
            || load.desktopStatus == .stale
    }

    func refresh() async -> ProviderSnapshot {
        await refresh(
            credentialReloadsRemaining: 1,
            forceDesktopFallback: false,
            previousFallbackError: nil,
            previousKeychainAccessError: nil
        )
    }

    /// Claude Code can replace a login while a request is in flight. Reload once when that happens so
    /// the older account cannot reach the dashboard or cache; bound the retry for a changing source.
    private func refresh(
        credentialReloadsRemaining: Int,
        forceDesktopFallback: Bool,
        previousFallbackError: ClaudeAuthError?,
        previousKeychainAccessError: ClaudeAuthError?
    ) async -> ProviderSnapshot {
        guard !Task.isCancelled else { return cancelledRefreshSnapshot(provider: provider) }
        if ProviderRefreshContext.scope.suppressesLiveQuota {
            // Fold-only passes need only this card's account-scoped local logs. Reloading OAuth
            // credentials here can repeat a failed Keychain read during the visible retry's
            // history follow-up, even though this pass never uses the token or calls Anthropic.
            // The scanner is already bound to the card identity when account cards are created.
            return await snapshotWithLocalUsage(
                mapped: ClaudeMappedUsage(plan: nil, lines: []),
                warning: nil
            )
        }
        let manualActionID = ProviderRefreshContext.manualActionID
        let allowCredentialInteraction = ProviderRefreshContext.isManual
        let interactionGate = ProviderRefreshContext.credentialInteractionGate
        let credentialLoad = await loadOffMainActor { [authStore] in
            authStore.loadCredentialSet(
                allowDesktopInteraction: allowCredentialInteraction,
                allowKeychainInteraction: allowCredentialInteraction,
                interactionGate: interactionGate,
                forceDesktopFallback: forceDesktopFallback
            )
        }
        guard !Task.isCancelled else { return cancelledRefreshSnapshot(provider: provider) }
        guard KeychainPermissionGate.shared.isCurrentManualAction(manualActionID),
              !credentialLoad.keychainReadCancelled
        else { return cancelledRefreshSnapshot(provider: provider) }
        let keychainAccessError: ClaudeAuthError? = if credentialLoad.keychainPermissionRequired {
            .credentialPermissionRequired
        } else if credentialLoad.keychainReadFailed {
            .credentialKeychainReadFailed
        } else {
            previousKeychainAccessError
        }
        let storedCandidates = credentialLoad.candidates
        let candidates = storedCandidates.filter {
            $0.hasUsableAccessToken && (!forceDesktopFallback || $0.source == .desktop)
        }
        let noCredentialDiagnosticKey = "auth.claude.no-credential.\(provider.id)"
        if !candidates.isEmpty {
            DiagnosticGate.clearFailure(noCredentialDiagnosticKey)
        }
        if credentialLoad.keychainPermissionRequired, candidates.isEmpty {
            return ProviderSnapshot.error(provider: provider, error: ClaudeAuthError.credentialPermissionRequired)
        }
        if forceDesktopFallback {
            switch credentialLoad.desktopStatus {
            case .permissionRequired:
                return ProviderSnapshot.error(provider: provider, error: ClaudeAuthError.desktopPermissionRequired)
            case .unreadable:
                return ProviderSnapshot.error(provider: provider, error: ClaudeDesktopCredentialsUnreadableError())
            case .stale, .invalid, .notFound:
                if credentialLoad.credentialsFileUnreadable {
                    return ProviderSnapshot.error(provider: provider, error: ClaudeCredentialsUnreadableError())
                }
                if credentialLoad.credentialsFileInvalid {
                    return ProviderSnapshot.error(provider: provider, error: ClaudeCredentialsInvalidError())
                }
                if let keychainAccessError {
                    return ProviderSnapshot.error(provider: provider, error: keychainAccessError)
                }
                if let previousFallbackError {
                    return ProviderSnapshot.error(provider: provider, error: previousFallbackError)
                }
            case .notChecked, .available:
                break
            }
        }
        if credentialLoad.desktopStatus == .unreadable {
            return ProviderSnapshot.error(provider: provider, error: ClaudeDesktopCredentialsUnreadableError())
        }
        let hasReadableStoredCredential = candidates.contains {
            if case .environment = $0.source { return false }
            return $0.hasUsableAccessToken
        }
        if credentialLoad.credentialsFileUnreadable, !hasReadableStoredCredential {
            if credentialLoad.desktopStatus == .permissionRequired {
                return ProviderSnapshot.error(provider: provider, error: ClaudeAuthError.desktopPermissionRequired)
            }
            return ProviderSnapshot.error(provider: provider, error: ClaudeCredentialsUnreadableError())
        }
        if credentialLoad.credentialsFileInvalid,
           candidates.isEmpty,
           credentialLoad.desktopStatus != .permissionRequired
        {
            return ProviderSnapshot.error(provider: provider, error: ClaudeCredentialsInvalidError())
        }
        let hasLiveUsageCandidate = candidates.contains {
            authStore.liveUsageAvailability($0) == .available
        }
        let desktopFallbackWarning: String? = if !hasLiveUsageCandidate {
            switch credentialLoad.desktopStatus {
            case .permissionRequired:
                ClaudeAuthError.desktopPermissionRequired.localizedDescription
            case .unreadable:
                ClaudeDesktopCredentialsUnreadableError().localizedDescription
            case .stale:
                ClaudeAuthError.desktopTokenExpired.localizedDescription
            case .invalid:
                ClaudeAuthError.desktopCredentialsUnavailable.localizedDescription
            case .notChecked, .notFound, .available:
                nil
            }
        } else {
            nil
        }
        guard !candidates.isEmpty else {
            switch credentialLoad.desktopStatus {
            case .permissionRequired:
                return ProviderSnapshot.error(provider: provider, error: ClaudeAuthError.desktopPermissionRequired)
            case .unreadable:
                return ProviderSnapshot.error(provider: provider, error: ClaudeDesktopCredentialsUnreadableError())
            case .stale:
                return ProviderSnapshot.error(provider: provider, error: ClaudeAuthError.desktopTokenExpired)
            case .invalid:
                return ProviderSnapshot.error(provider: provider, error: ClaudeAuthError.desktopCredentialsUnavailable)
            case .notChecked, .notFound, .available:
                break
            }
            if credentialLoad.keychainReadFailed {
                return ProviderSnapshot.error(provider: provider, error: ClaudeAuthError.credentialKeychainReadFailed)
            }
            DiagnosticGate.logOnce(for: noCredentialDiagnosticKey) {
                AppLog.info(LogTag.auth("claude"), "no access token, not logged in")
            }
            let error = ClaudeAuthError.notLoggedIn
            let snapshot = await snapshotWithLocalUsage(
                mapped: ClaudeMappedUsage(plan: nil, lines: []),
                warning: error.localizedDescription
            )
            guard let history = snapshot.usageHistory,
                  history.series.daily.contains(where: {
                      $0.totalTokens > 0 || ($0.costUSD ?? 0) > 0
                  })
            else {
                return ProviderSnapshot.error(provider: provider, error: error)
            }
            return snapshot
        }

        // Per-source diagnostics at info level (token-free: source kind + refresh-token-present + expired
        // booleans) so a "token expired" report is diagnosable from a default log without a debug build —
        // e.g. all sources showing `refresh=no` explains why an expiry can never self-heal (issue #738).
        let sources = candidates.map { $0.diagnosticsLabel(now: now()) }.joined(separator: ", ")
        AppLog.info(LogTag.plugin("claude"), "refresh start (\(candidates.count) source\(candidates.count == 1 ? "" : "s"): \(sources))")
        let start = Date()
        // Probe each credential source in keychain-before-file order. An auth-expiry failure on one source (a
        // stale/locked-out token that an external `claude` re-login replaced in another source) falls
        // through to the next rather than failing the whole refresh; any non-auth error (rate limit,
        // request/transport failure) surfaces immediately so a real outage is never masked as a retry.
        var lastFallbackError: ClaudeAuthError?
        var credentialGeneration = ClaudeCredentialGeneration(storedCandidates)
        for state in candidates {
            guard !Task.isCancelled,
                  KeychainPermissionGate.shared.isCurrentManualAction(manualActionID)
            else { return cancelledRefreshSnapshot(provider: provider) }
            // The environment token cannot read subscription usage. If a CLI login was rejected, try
            // Desktop before this spend-only fallback can turn the refresh into a false success.
            if !forceDesktopFallback,
               lastFallbackError != nil,
               credentialLoad.desktopStatus == .notChecked,
               authStore.liveUsageAvailability(state) == .inferenceOnlyToken
            {
                return await refresh(
                    credentialReloadsRemaining: credentialReloadsRemaining,
                    forceDesktopFallback: true,
                    previousFallbackError: lastFallbackError,
                    previousKeychainAccessError: keychainAccessError
                )
            }
            do {
                let snapshot = try await probe(
                    state: state,
                    credentialGeneration: &credentialGeneration,
                    fallbackWarning: desktopFallbackWarning
                )
                guard !Task.isCancelled,
                      KeychainPermissionGate.shared.isCurrentManualAction(manualActionID)
                else { return cancelledRefreshSnapshot(provider: provider) }
                DiagnosticGate.clearFailures(prefix: Self.sourceFallbackDiagnosticPrefix(
                    providerID: provider.id,
                    source: state.source
                ))
                if case .desktop = state.source {
                    // Desktop succeeding does not mean the stored Claude login recovered; keep the
                    // fallback transition latched until a non-Desktop credential source works.
                } else {
                    DiagnosticGate.clearFailure(Self.desktopFallbackDiagnosticKey(providerID: provider.id))
                }
                AppLog.info(LogTag.plugin("claude"), "refresh end (\(Int(Date().timeIntervalSince(start) * 1000))ms)")
                return snapshot
            } catch ClaudeAuthError.credentialsChanged where credentialReloadsRemaining > 0 {
                AppLog.info(LogTag.auth("claude"), "credential source changed during refresh; reloading current login")
                return await refresh(
                    credentialReloadsRemaining: credentialReloadsRemaining - 1,
                    forceDesktopFallback: forceDesktopFallback,
                    previousFallbackError: previousFallbackError,
                    previousKeychainAccessError: keychainAccessError
                )
            } catch let error as ClaudeAuthError where error.allowsAuthFallback {
                guard !Task.isCancelled else { return cancelledRefreshSnapshot(provider: provider) }
                let diagnosticPrefix = Self.sourceFallbackDiagnosticPrefix(
                    providerID: provider.id,
                    source: state.source
                )
                DiagnosticGate.logOnce(
                    for: diagnosticPrefix + error.errorCategory.rawValue
                ) {
                    AppLog.warn(LogTag.auth("claude"), "\(state.source.label) failed (\(error)); falling back to next source if any")
                }
                lastFallbackError = error
                continue
            } catch {
                if ProviderCancellation.isCancellation(error) {
                    return cancelledRefreshSnapshot(provider: provider)
                }
                return ProviderSnapshot.error(provider: provider, error: error)
            }
        }
        if !forceDesktopFallback,
           lastFallbackError != nil,
           credentialLoad.desktopStatus == .notChecked
        {
            guard !Task.isCancelled else { return cancelledRefreshSnapshot(provider: provider) }
            DiagnosticGate.logOnce(for: Self.desktopFallbackDiagnosticKey(providerID: provider.id)) {
                AppLog.info(LogTag.auth("claude"), "stored Claude login failed; trying Claude Desktop")
            }
            return await refresh(
                credentialReloadsRemaining: credentialReloadsRemaining,
                forceDesktopFallback: true,
                previousFallbackError: lastFallbackError,
                previousKeychainAccessError: keychainAccessError
            )
        }
        if credentialLoad.credentialsFileUnreadable {
            return ProviderSnapshot.error(provider: provider, error: ClaudeCredentialsUnreadableError())
        }
        if credentialLoad.keychainPermissionRequired {
            return ProviderSnapshot.error(provider: provider, error: ClaudeAuthError.credentialPermissionRequired)
        }
        if credentialLoad.credentialsFileInvalid {
            return ProviderSnapshot.error(provider: provider, error: ClaudeCredentialsInvalidError())
        }
        if credentialLoad.keychainReadFailed {
            return ProviderSnapshot.error(provider: provider, error: ClaudeAuthError.credentialKeychainReadFailed)
        }
        return ProviderSnapshot.error(
            provider: provider,
            error: lastFallbackError ?? ClaudeAuthError.notLoggedIn
        )
    }

    private static func diagnosticIdentity(for source: ClaudeCredentialState.Source) -> String {
        switch source {
        case .file: "file"
        case .keychainCurrentUser(let service): "keychainCurrentUser.\(service)"
        case .keychainLegacy(let service): "keychainLegacy.\(service)"
        case .desktop: "desktop"
        case .environment: "environment"
        }
    }

    private static func sourceFallbackDiagnosticPrefix(
        providerID: String,
        source: ClaudeCredentialState.Source
    ) -> String {
        let identity = JSONLScanCachePaths.stableFingerprint(diagnosticIdentity(for: source))
        return "auth.claude.sourceFallback.\(providerID).\(identity)."
    }

    private static func credentialPersistenceDiagnosticKey(
        providerID: String,
        source: ClaudeCredentialState.Source
    ) -> String {
        let identity = JSONLScanCachePaths.stableFingerprint(diagnosticIdentity(for: source))
        return "auth.claude.token-persist.\(providerID).\(identity)"
    }

    private static func liveUsageDiagnosticPrefix(kind: String, providerID: String) -> String {
        "auth.claude.live-usage.\(kind).\(providerID)."
    }

    private static func liveUsageDiagnosticKey(
        kind: String,
        providerID: String,
        state: ClaudeCredentialState
    ) -> String {
        // A token rotation does not make a persistent warning new; the credential source is the
        // recovery unit. A different fallback source has an independent gate and cannot clear it.
        let identity = diagnosticIdentity(for: state.source)
        return liveUsageDiagnosticPrefix(kind: kind, providerID: providerID)
            + JSONLScanCachePaths.stableFingerprint(identity)
    }

    private static func desktopFallbackDiagnosticKey(providerID: String) -> String {
        "auth.claude.desktopFallback.\(providerID)"
    }

    private func probe(
        state initialState: ClaudeCredentialState,
        credentialGeneration: inout ClaudeCredentialGeneration,
        fallbackWarning: String?
    ) async throws -> ProviderSnapshot {
        try Task.checkCancellation()
        var state = initialState
        var mapped = ClaudeMappedUsage(
            plan: ClaudeUsageMapper.formatPlan(
                subscriptionType: state.oauth.subscriptionType,
                rateLimitTier: state.oauth.rateLimitTier
            ),
            lines: []
        )

        var warning: String?
        switch authStore.liveUsageAvailability(state) {
        case .available:
            if ProviderRefreshContext.scope.suppressesLiveQuota {
                // Fold-only pass (panel phase 2): the meters-only phase answered the usage
                // endpoint moments ago; re-fetching per fold would double every panel-open API
                // call and pull Anthropic's aggressive rate limits onto a routine open. The
                // store's merge recovers the meters and carries their freshness stamp.
                break
            }
            mapped = try await fetchLiveUsage(
                state: &state,
                credentialGeneration: &credentialGeneration
            )
            try Task.checkCancellation()
            // A rate-limited fetch rides its "Updates blocked by Anthropic" notice on the mapped usage so
            // it reaches the header triangle even when the badge/note lines aren't in the user's layout.
            warning = mapped.warning
        case .missingProfileScope:
            // The login authenticates for inference but lacks the `user:profile` scope the usage endpoint
            // needs (typically a `claude setup-token` token). Don't leave the session/weekly bars silently
            // blank — log it for diagnosis and surface a provider header warning (the amber triangle, like
            // Z.ai's "no coding plan" notice) telling the user a re-login restores them. The local-log
            // spend tiles below are unaffected and still load.
            DiagnosticGate.logOnce(for: Self.liveUsageDiagnosticKey(
                kind: "missingProfileScope",
                providerID: provider.id,
                state: state
            )) {
                AppLog.warn(LogTag.plugin("claude"), "live usage unavailable: credential lacks the user:profile scope (inference-only token); re-login with `claude` to restore session/weekly limits")
            }
            DiagnosticGate.clearFailure(Self.liveUsageDiagnosticKey(
                kind: "retryUnauthorized",
                providerID: provider.id,
                state: state
            ))
            warning = ClaudeUsageMapper.missingProfileScopeWarning
        case .inferenceOnlyToken:
            // An explicit CLAUDE_CODE_OAUTH_TOKEN is inference-only by design; nothing to fetch and nothing
            // to nag about — the spend tiles still load below.
            DiagnosticGate.clearFailure(Self.liveUsageDiagnosticKey(
                kind: "retryUnauthorized",
                providerID: provider.id,
                state: state
            ))
            break
        }
        if let fallbackWarning {
            warning = fallbackWarning
        }

        return await snapshotWithLocalUsage(mapped: mapped, warning: warning)
    }

    private func snapshotWithLocalUsage(
        mapped initialUsage: ClaudeMappedUsage,
        warning: String?
    ) async -> ProviderSnapshot {
        guard !Task.isCancelled else { return cancelledRefreshSnapshot(provider: provider) }
        var mapped = initialUsage
        // Meters-only passes (menu-bar ticks, panel phase 1) only need Session/Weekly (and sibling)
        // quota meters from the live usage API. Skip the expensive local JSONL / pi history scan;
        // the data store merges prior token/history lines onto this snapshot.
        if ProviderRefreshContext.scope.skipsLocalAccounting {
            MetricLine.appendNoDataIfNeeded(&mapped.lines)
            return ProviderSnapshot.make(
                provider: provider,
                plan: mapped.plan,
                lines: mapped.lines,
                refreshedAt: now(),
                usageHistory: nil,
                warning: warning
            )
        }
        // Local spend tiles, scanned natively from Claude Code's session logs and priced through the
        // shared pricing store, merged with Claude usage that happened inside pi (attributed back here).
        // Both scans run on their scanner actors, off the main actor, and do not require an OAuth login.
        let pricing = await pricing()
        guard !Task.isCancelled else { return cancelledRefreshSnapshot(provider: provider) }
        let scanNow = now()
        let nativeResult = await logUsageScanner.scanResult(
            daysBack: UsageHistoryWindow.lifetimeDays(through: scanNow), now: scanNow, pricing: pricing
        )
        guard !Task.isCancelled else { return cancelledRefreshSnapshot(provider: provider) }
        guard case .complete(let nativeScan) = nativeResult else {
            return localHistoryIncompleteSnapshot(mapped: mapped, warning: warning)
        }
        let piResult: PiUsageScanResult = allowsUnattributedPiUsage
            ? await piUsageScanner.scanResult(
                cardID: provider.id,
                daysBack: UsageHistoryWindow.lifetimeDays(through: scanNow),
                now: scanNow,
                pricing: pricing
            )
            : .complete(nil)
        guard !Task.isCancelled else { return cancelledRefreshSnapshot(provider: provider) }
        guard case .complete(let piScan) = piResult else {
            return localHistoryIncompleteSnapshot(mapped: mapped, warning: warning)
        }
        var usageHistory: ProviderUsageHistory?
        // Cancellation can land between the native and pi scans. Treat the pair as one unit so a
        // partial result cannot replace the last-good combined history in WidgetDataStore.
        if !Task.isCancelled, let scan = DailyUsageAccumulator.merged([nativeScan, piScan]) {
            let note = piScan == nil
                ? "From your Claude usage history (estimated)"
                : "From your Claude usage history and pi (estimated)"
            usageHistory = ProviderUsageHistory(
                series: scan.series,
                modelUsage: scan.modelUsage,
                unknownModelsByDay: scan.unknownModelsByDay,
                apiEstimateByDay: scan.apiEstimateByDay,
                apiEstimateIncompleteDays: scan.apiEstimateIncompleteDays
            )
            SpendTileMapper.appendTokenUsage(
                scan.series, to: &mapped.lines, now: now(),
                unknownModelsByDay: scan.unknownModelsByDay,
                modelUsage: scan.modelUsage,
                modelSourceNote: note,
                apiEstimateByDay: scan.apiEstimateByDay
            )
            SpendTileMapper.appendUsageTrend(scan.series, to: &mapped.lines, now: now(), note: note)
        }

        MetricLine.appendNoDataIfNeeded(&mapped.lines)
        return ProviderSnapshot.make(
            provider: provider,
            plan: mapped.plan,
            lines: mapped.lines,
            refreshedAt: now(),
            usageHistory: usageHistory,
            warning: warning
        )
    }

    /// A failed local source must not publish a partial native+Pi replacement. The store keeps the
    /// prior normalized history when this successful live snapshot carries `usageHistory == nil`.
    private func localHistoryIncompleteSnapshot(
        mapped initialUsage: ClaudeMappedUsage,
        warning: String?
    ) -> ProviderSnapshot {
        var mapped = initialUsage
        MetricLine.appendNoDataIfNeeded(&mapped.lines)
        return ProviderSnapshot.make(
            provider: provider,
            plan: mapped.plan,
            lines: mapped.lines,
            refreshedAt: now(),
            usageHistory: nil,
            warning: warning
        )
    }

    private func fetchLiveUsage(
        state: inout ClaudeCredentialState,
        credentialGeneration: inout ClaudeCredentialGeneration
    ) async throws -> ClaudeMappedUsage {
        var expectedGeneration = credentialGeneration
        defer { credentialGeneration = expectedGeneration }
        activateLiveUsageCache(for: state.oauth)

        // Inside an active rate-limit cooldown, skip the live call and serve the last-good usage so a
        // constantly-limited endpoint doesn't blank the dashboard (and we don't pile on more 429s).
        if let until = rateLimitedUntil, now() < until {
            DiagnosticGate.logOnce(for: Self.liveUsageDiagnosticKey(
                kind: "rateLimit",
                providerID: provider.id,
                state: state
            )) {
                AppLog.info(LogTag.plugin("claude"), "rate-limited (cooldown active, serving \(lastGoodUsage == nil ? "badge" : "last-good usage"))")
            }
            return rateLimitedSnapshot(credentials: state.oauth, retryAfterSeconds: Int(until.timeIntervalSince(now()).rounded(.up)))
        }

        if authStore.needsRefresh(state.oauth),
           let refreshToken = state.oauth.refreshToken,
           !refreshToken.isEmpty {
            try Task.checkCancellation()
            let refreshed = try await refreshAccessToken(
                state: &state,
                refreshToken: refreshToken,
                expectedGeneration: expectedGeneration
            )
            state.oauth.accessToken = refreshed.accessToken
            if refreshed.persisted { expectedGeneration = expectedGeneration.replacing(state) }
        }

        var working = state
        defer { state = working }
        try Task.checkCancellation()
        var verificationResponse = try await verifyAccountIfNeeded(
            accessToken: working.oauth.accessToken ?? ""
        )
        let attempt: (String) async throws -> HTTPResponse = { accessToken in
            try Task.checkCancellation()
            if let response = verificationResponse {
                verificationResponse = nil
                return response
            }
            return try await self.usageClient.fetchUsage(
                accessToken: accessToken, config: self.authStore.oauthConfig()
            )
        }
        let firstResponse: HTTPResponse
        do {
            firstResponse = try await attempt(working.oauth.accessToken ?? "")
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try ProviderCancellation.rethrowIfCancellation(error)
            throw ClaudeUsageError.connectionFailed
        }

        let response: HTTPResponse
        if ClaudeUsageClient.isMissingProfileScopeFailure(firstResponse) {
            // An explicit scope denial is definitive. Refreshing an unknown-scope token cannot grant
            // the missing permission and, without a refresh token, used to mislabel this as expired.
            response = firstResponse
        } else if ProviderAuthRetry.isAuthFailure(firstResponse) {
            AppLog.debug(.auth, "\(firstResponse.statusCode) -> refreshing token, retrying once")
            if working.source == .desktop {
                throw ClaudeAuthError.desktopTokenExpired
            }
            guard let refreshToken = working.oauth.refreshToken, !refreshToken.isEmpty else {
                throw ClaudeAuthError.tokenExpired
            }
            let refreshed = try await refreshAccessToken(
                state: &working,
                refreshToken: refreshToken,
                expectedGeneration: expectedGeneration
            )
            if refreshed.persisted {
                expectedGeneration = expectedGeneration.replacing(working)
            }
            verificationResponse = try await verifyAccountIfNeeded(accessToken: refreshed.accessToken)
            try Task.checkCancellation()

            let retried: HTTPResponse
            do {
                retried = try await attempt(refreshed.accessToken)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try ProviderCancellation.rethrowIfCancellation(error)
                throw ClaudeUsageError.connectionFailed
            }
            if ClaudeUsageClient.isMissingProfileScopeFailure(retried) {
                response = retried
            } else if ProviderAuthRetry.isAuthFailure(retried) {
                DiagnosticGate.logOnce(for: Self.liveUsageDiagnosticKey(
                    kind: "retryUnauthorized",
                    providerID: provider.id,
                    state: working
                )) {
                    AppLog.warn(.auth, "retry still unauthorized -> auth expired")
                }
                throw ClaudeAuthError.tokenExpired
            } else {
                response = retried
            }
        } else {
            response = firstResponse
        }

        let forceDesktopGeneration = working.source == .desktop
        try Task.checkCancellation()
        let currentGeneration = await loadOffMainActor { [authStore] in
            authStore.credentialGeneration(forceDesktopFallback: forceDesktopGeneration)
        }
        try Task.checkCancellation()
        guard currentGeneration == expectedGeneration else { throw ClaudeAuthError.credentialsChanged }
        if response.statusCode != 429 {
            DiagnosticGate.clearFailure(Self.liveUsageDiagnosticKey(
                kind: "rateLimit",
                providerID: provider.id,
                state: working
            ))
        }

        // A non-auth response proves this source recovered from the earlier unauthorized retry,
        // even when it has since lost the profile scope or is currently rate limited.
        DiagnosticGate.clearFailure(Self.liveUsageDiagnosticKey(
            kind: "retryUnauthorized",
            providerID: provider.id,
            state: working
        ))

        if ClaudeUsageClient.isMissingProfileScopeFailure(response) {
            DiagnosticGate.logOnce(for: Self.liveUsageDiagnosticKey(
                kind: "missingProfileScope",
                providerID: provider.id,
                state: working
            )) {
                AppLog.warn(LogTag.plugin("claude"), "live usage unavailable: OAuth response says the credential lacks the user:profile scope; re-login with `claude` to restore session/weekly limits")
            }
            return ClaudeMappedUsage(
                plan: ClaudeUsageMapper.formatPlan(
                    subscriptionType: working.oauth.subscriptionType,
                    rateLimitTier: working.oauth.rateLimitTier
                ),
                lines: [],
                warning: ClaudeUsageMapper.missingProfileScopeWarning
            )
        }

        // 429 can come back from either attempt; the helper hands both through unchanged. Start a cooldown
        // (respecting Retry-After) and serve the last-good usage rather than a bare badge.
        if response.statusCode == 429 {
            let retryAfterSeconds = ClaudeUsageMapper.parseRetryAfterSeconds(response, now: now())
            rateLimitedUntil = now().addingTimeInterval(TimeInterval(retryAfterSeconds ?? Int(Self.rateLimitCooldown)))
            DiagnosticGate.logOnce(for: Self.liveUsageDiagnosticKey(
                kind: "rateLimit",
                providerID: provider.id,
                state: working
            )) {
                AppLog.info(LogTag.plugin("claude"), "rate-limited (serving \(lastGoodUsage == nil ? "badge" : "last-good usage"))")
            }
            return rateLimitedSnapshot(credentials: working.oauth, retryAfterSeconds: retryAfterSeconds)
        }

        let mapped = try ClaudeUsageMapper.mapUsageResponse(response, credentials: working.oauth, now: now())
        DiagnosticGate.clearFailure(Self.liveUsageDiagnosticKey(
            kind: "missingProfileScope",
            providerID: provider.id,
            state: working
        ))
        lastGoodUsage = mapped
        rateLimitedUntil = nil
        return mapped
    }

    private func verifyAccountIfNeeded(accessToken: String) async throws -> HTTPResponse? {
        try Task.checkCancellation()
        guard let identity = authStore.expectedIdentityKey,
              identity.split(separator: "|").count == 2
        else { return nil }
        let fingerprint = Data(SHA256.hash(data: Data("\(identity)\u{0}\(accessToken)".utf8)))
        guard verifiedCredentialFingerprint != fingerprint else { return nil }
        if let response = try await usageClient.verifyAccount(
            accessToken: accessToken, expectedIdentityKey: identity, config: authStore.oauthConfig()
        ) {
            return response
        }
        verifiedCredentialFingerprint = fingerprint
        return nil
    }

    /// Last-good usage with an appended staleness note when we have it; otherwise the plain rate-limited
    /// badge (no successful fetch yet this run). `lastGoodUsage` only ever holds a clean `mapUsageResponse`
    /// result (never a rate-limited snapshot), so the note is never duplicated and no stale spend tiles
    /// ride along — `probe` appends those fresh after this returns.
    private func rateLimitedSnapshot(credentials: ClaudeOAuth, retryAfterSeconds: Int?) -> ClaudeMappedUsage {
        guard var mapped = lastGoodUsage else {
            return ClaudeUsageMapper.rateLimitedUsage(credentials: credentials, retryAfterSeconds: retryAfterSeconds)
        }
        mapped.lines.append(ClaudeUsageMapper.rateLimitedNote(retryAfterSeconds: retryAfterSeconds))
        mapped.warning = ClaudeUsageMapper.rateLimitedWarning(retryAfterSeconds: retryAfterSeconds)
        return mapped
    }

    /// Cache state belongs to the complete access + refresh credential pair. A login change therefore
    /// clears both last-good usage and cooldown, even when the two accounts share an access token.
    private func activateLiveUsageCache(for credentials: ClaudeOAuth) {
        let fingerprint = Self.credentialFingerprint(credentials)
        guard cachedCredentialFingerprint != fingerprint else { return }
        cachedCredentialFingerprint = fingerprint
        lastGoodUsage = nil
        rateLimitedUntil = nil
        DiagnosticGate.clearFailures(prefix: Self.liveUsageDiagnosticPrefix(
            kind: "rateLimit",
            providerID: provider.id
        ))
    }

    private static func credentialFingerprint(_ credentials: ClaudeOAuth) -> Data {
        let access = Data((credentials.accessToken ?? "").utf8)
        let refresh = Data((credentials.refreshToken ?? "").utf8)
        var pair = Data(SHA256.hash(data: access))
        pair.append(contentsOf: SHA256.hash(data: refresh))
        return Data(SHA256.hash(data: pair))
    }

    private struct RefreshedAccess {
        var accessToken: String
        var persisted: Bool
    }

    private func refreshAccessToken(
        state: inout ClaudeCredentialState,
        refreshToken: String,
        expectedGeneration: ClaudeCredentialGeneration
    ) async throws -> RefreshedAccess {
        let refreshAttemptDiagnosticKey = Self.sourceFallbackDiagnosticPrefix(
            providerID: provider.id,
            source: state.source
        ) + "refresh.attempt"
        DiagnosticGate.logOnce(for: refreshAttemptDiagnosticKey) {
            AppLog.info(LogTag.auth("claude"), "token refresh attempt")
        }
        let response: HTTPResponse
        do {
            response = try await usageClient.refreshToken(refreshToken, config: authStore.oauthConfig())
        } catch {
            try ProviderCancellation.rethrowIfCancellation(error)
            throw error
        }
        if response.statusCode == 400 || response.statusCode == 401 {
            let body = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any]
            let errorCode = body?["error"] as? String ?? body?["error_description"] as? String
            if errorCode == "invalid_grant" {
                let key = Self.sourceFallbackDiagnosticPrefix(
                    providerID: provider.id,
                    source: state.source
                ) + "refresh.invalidGrant"
                DiagnosticGate.logOnce(for: key) {
                    AppLog.warn(LogTag.auth("claude"), "session expired (invalid_grant)")
                }
                throw ClaudeAuthError.sessionExpired
            }
            // A 400/401 without a recognized OAuth error code isn't necessarily an expired token — it
            // can be an HTML proxy/WAF page or a gateway error. Surface the HTTP status rather than
            // telling the user to re-login (which can't fix a transport/infra failure).
            throw ClaudeUsageError.requestFailed(response.statusCode)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw ClaudeUsageError.requestFailed(response.statusCode)
        }
        // NEVER log decoded.accessToken / refreshToken — only the fact that a rotation happened.
        let decoded = try JSONDecoder().decode(ClaudeRefreshResponse.self, from: response.body)
        DiagnosticGate.clearFailures(prefix: Self.sourceFallbackDiagnosticPrefix(
            providerID: provider.id,
            source: state.source
        ))
        let previousOAuth = state.oauth
        state.oauth.accessToken = decoded.accessToken
        if let refreshToken = decoded.refreshToken {
            state.oauth.refreshToken = refreshToken
        }
        if let expiresIn = decoded.expiresIn {
            state.oauth.expiresAt = now().timeIntervalSince1970 * 1000 + expiresIn * 1000
        }
        // Fail loudly: a swallowed save leaves the OLD refresh token on disk after a rotation, so the
        // next launch refreshes with a server-invalidated token and the user sees a misleading
        // "session expired". The refreshed token still works for this session, so we log and continue
        // rather than fail the live fetch.
        let persisted: Bool
        let persistenceDiagnosticKey = Self.credentialPersistenceDiagnosticKey(
            providerID: provider.id,
            source: state.source
        )
        do {
            guard try await loadOffMainActor({ [authStore, state] in
                try authStore.save(state, ifUnchanged: expectedGeneration)
            }) else {
                throw ClaudeAuthError.credentialsChanged
            }
            DiagnosticGate.clearFailure(persistenceDiagnosticKey)
            persisted = true
        } catch let error as ClaudeAuthError where error == .credentialsChanged {
            throw error
        } catch {
            DiagnosticGate.logOnce(for: persistenceDiagnosticKey) {
                AppLog.error(LogTag.auth("claude"), "failed to persist rotated credentials; using the refreshed token for this session only: \(error.localizedDescription)")
            }
            persisted = false
        }
        if cachedCredentialFingerprint == Self.credentialFingerprint(previousOAuth) {
            cachedCredentialFingerprint = Self.credentialFingerprint(state.oauth)
        }
        AppLog.info(LogTag.auth("claude"), "token refresh ok (rotated)")
        // A successful response may already have invalidated the previous refresh token. Persist its
        // rotation even if cancellation arrived while the request was in flight, then honor cancel.
        try Task.checkCancellation()
        return RefreshedAccess(accessToken: decoded.accessToken, persisted: persisted)
    }

}
