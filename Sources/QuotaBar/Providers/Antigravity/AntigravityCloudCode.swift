import Foundation

/// Google Cloud Code quota reads for Antigravity: the Keychain login when readable, and T3 Code's
/// file-based instance credentials when the Keychain is absent or its ACL blocks this build. Split
/// from AntigravityProvider.swift to keep both files small; the probe order and error semantics are
/// documented on the provider.
extension AntigravityProvider {
    // MARK: - Cloud Code

    private struct AccessTokenAttempt {
        let value: String
        let isDerivedCache: Bool
    }

    /// Called from `probe()` in AntigravityProvider.swift.
    /// `allowFileCredentials` gates the T3 file-credential branch: the native source reads only the
    /// app's own saved sign-in, so production never looks at another client's credential files.
    func probeCloudCode(allowFileCredentials: Bool) async throws -> StrategyResult {
        let authStore = self.authStore
        let keychainToken: AntigravityKeychainToken?
        var keychainError: Error?
        do {
            keychainToken = try await loadOffMainActor { try authStore.loadKeychainToken() }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            keychainToken = nil
            keychainError = error
        }
        try Task.checkCancellation()

        if let keychainToken {
            return try await probeCloudCode(keychainToken: keychainToken)
        }

        // Keychain absent or blocked: T3 Code's private Antigravity instances keep file-based OAuth
        // credentials that refresh without a Keychain grant, so a per-build cdhash change cannot
        // strand quota while T3 Code is signed in. Only the legacy fixture path may consult them.
        if allowFileCredentials {
            let fileCredentials = await loadOffMainActor { authStore.loadFileCredentials() }
            try Task.checkCancellation()
            if !fileCredentials.isEmpty {
                return try await probeCloudCode(fileCredentials: fileCredentials)
            }
        }

        // Proven logout invalidates the derived cache. A Keychain read failure deliberately leaves
        // the cache untouched for recovery.
        if keychainError == nil {
            await loadOffMainActor { authStore.discardCachedToken() }
        }
        if let keychainError { throw keychainError }
        throw AntigravityError.notSignedIn
    }

    private func probeCloudCode(keychainToken: AntigravityKeychainToken) async throws -> StrategyResult {
        let authStore = self.authStore
        if let identityKey = AntigravityAuthStore.cacheIdentityKey(for: keychainToken) {
            ProviderRefreshContext.cacheIdentityResult?.set(identityKey)
        }

        var tokens: [AccessTokenAttempt] = []
        var hasKnownExpiredAccessToken = false
        if let access = keychainToken.accessToken {
            if authStore.isUsable(expiry: keychainToken.expiry) {
                tokens.append(AccessTokenAttempt(value: access, isDerivedCache: false))
            } else {
                hasKnownExpiredAccessToken = true
            }
        }
        if let cached = await loadOffMainActor({ authStore.loadCachedToken(matching: keychainToken) }),
           !tokens.contains(where: { $0.value == cached }) {
            try Task.checkCancellation()
            tokens.append(AccessTokenAttempt(value: cached, isDerivedCache: true))
        }
        try Task.checkCancellation()

        // We have something to authenticate with if any token was tried or a refresh token exists. Used
        // to tell a transient outage ("temporarily unavailable") apart from a genuine "not signed in".
        let hasCredentials = !tokens.isEmpty || (keychainToken.refreshToken?.isEmpty == false)

        var sawAuthFailure = false
        var sawForbidden = false
        var sawNoQuotaEndpoint = false
        var sawTransientFailure = false
        for attempt in tokens {
            switch try await fetchCloudCode(token: attempt.value) {
            case .success(let result): return result
            case .authFailed:
                sawAuthFailure = true
                if attempt.isDerivedCache {
                    await loadOffMainActor { authStore.discardCachedToken() }
                }
            case .forbidden: sawForbidden = true
            case .notFound: sawNoQuotaEndpoint = true
            case .unavailable: sawTransientFailure = true
            }
        }

        // Only refresh on evidence of dead auth: a rejection, no usable token, or a known-expired
        // access token whose derived cache just failed. A transient Cloud Code outage on a live
        // access token must not trigger a Google OAuth refresh every cycle.
        if sawAuthFailure || tokens.isEmpty || hasKnownExpiredAccessToken,
           let refreshToken = keychainToken.refreshToken, !refreshToken.isEmpty {
            switch try await usageClient.refreshGoogleToken(refreshToken) {
            case .refreshed(let accessToken, let expiresIn):
                try Task.checkCancellation()
                do {
                    let sourceStillMatches = try await loadOffMainActor {
                        try authStore.cacheToken(
                            accessToken,
                            expiresIn: expiresIn,
                            matching: keychainToken
                        )
                    }
                    guard sourceStillMatches else { throw AntigravityError.authExpired }
                } catch AntigravityError.credentialPermissionRequired
                    where quotaSource == .nativeApp && ProviderRefreshContext.isManual {
                    // A one-time Keychain grant authorizes this refresh, but not a second silent
                    // read or durable caching. The provider-held token is still used; nothing is
                    // written to the derived cache on a silent refusal.
                    AppLog.debug(LogTag.auth("antigravity"), "using renewed Antigravity sign-in for this refresh only")
                }
                try Task.checkCancellation()
                switch try await fetchCloudCode(token: accessToken) {
                case .success(let result): return result
                case .authFailed: throw AntigravityError.authExpired
                case .forbidden: throw AntigravityError.accessDenied
                case .notFound: throw AntigravityError.quotaEndpointUnavailable
                // The refreshed token is valid, so a non-2xx here is a transient outage, not bad auth.
                case .unavailable: throw AntigravityError.unavailable
                }
            // The refresh token itself is dead (revoked / expired) — that's expired auth, not an outage.
            case .authFailed: throw AntigravityError.authExpired
            case .clientConfigurationInvalid: throw AntigravityError.oauthClientConfigurationInvalid
            // Refresh was only transiently unavailable (throttled / 5xx / network). The refresh token may
            // still be valid, so report a transient outage — even if a token 401'd, an expired access
            // token is normal and isn't evidence the sign-in is dead.
            case .unavailable: throw AntigravityError.unavailable
            }
        }

        // Reached only when no usable refresh credential exists: a rejected token with no way to
        // refresh is genuinely expired auth. A known-expired access token reports expired auth only
        // when nothing produced a competing outcome — an outage or denial is not a dead sign-in.
        if sawAuthFailure { throw AntigravityError.authExpired }
        if hasKnownExpiredAccessToken, !sawForbidden, !sawNoQuotaEndpoint, !sawTransientFailure {
            throw AntigravityError.authExpired
        }
        if sawForbidden { throw AntigravityError.accessDenied }
        if sawNoQuotaEndpoint, !sawTransientFailure {
            throw AntigravityError.quotaEndpointUnavailable
        }
        // Signed in but every endpoint was unreachable — report a transient failure, not "not signed in".
        if hasCredentials { throw AntigravityError.unavailable }
        throw AntigravityError.notSignedIn
    }

    // MARK: T3 Code file credentials

    /// Try each instance's credential, most recently active first. One instance's dead grant does not
    /// prove the others are dead; a transient outage or a missing endpoint reads the same on every
    /// instance, so those stop the loop and surface immediately.
    private func probeCloudCode(fileCredentials: [AntigravityFileCredential]) async throws -> StrategyResult {
        var lastCredentialError: Error?
        for credential in fileCredentials {
            try Task.checkCancellation()
            do {
                return try await probeCloudCode(fileCredential: credential)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as AntigravityError {
                switch error {
                case .authExpired, .accessDenied, .oauthClientConfigurationInvalid, .notSignedIn:
                    lastCredentialError = error
                default:
                    throw error
                }
            }
        }
        throw lastCredentialError ?? AntigravityError.notSignedIn
    }

    /// Same probe shape as the Keychain path, with two differences: the file holds only a refresh
    /// token (the derived cache is the sole access token to try first), and the refresh uses the
    /// instance's own OAuth client pair — a refresh token only refreshes with its issuing client.
    private func probeCloudCode(fileCredential: AntigravityFileCredential) async throws -> StrategyResult {
        let authStore = self.authStore
        if let identityKey = AntigravityAuthStore.cacheIdentityKey(forRefreshToken: fileCredential.refreshToken) {
            ProviderRefreshContext.cacheIdentityResult?.set(identityKey)
        }

        var tokens: [AccessTokenAttempt] = []
        if let cached = await loadOffMainActor({ authStore.loadCachedToken(matchingRefreshToken: fileCredential.refreshToken) }) {
            try Task.checkCancellation()
            tokens.append(AccessTokenAttempt(value: cached, isDerivedCache: true))
        }
        try Task.checkCancellation()

        var sawAuthFailure = false
        var sawForbidden = false
        var sawNoQuotaEndpoint = false
        var sawTransientFailure = false
        for attempt in tokens {
            switch try await fetchCloudCode(token: attempt.value) {
            case .success(let result): return result
            case .authFailed:
                sawAuthFailure = true
                if attempt.isDerivedCache {
                    await loadOffMainActor { authStore.discardCachedToken() }
                }
            case .forbidden: sawForbidden = true
            case .notFound: sawNoQuotaEndpoint = true
            case .unavailable: sawTransientFailure = true
            }
        }

        // Only refresh on evidence of an auth failure (or no token to try) — a transient Cloud Code
        // outage must not trigger a Google OAuth refresh every cycle.
        if sawAuthFailure || tokens.isEmpty {
            switch try await usageClient.refreshGoogleToken(
                fileCredential.refreshToken,
                clientID: fileCredential.clientID,
                clientSecret: fileCredential.clientSecret
            ) {
            case .refreshed(let accessToken, let expiresIn):
                try Task.checkCancellation()
                let cached = try await loadOffMainActor {
                    try authStore.cacheToken(
                        accessToken,
                        expiresIn: expiresIn,
                        matchingRefreshToken: fileCredential.refreshToken,
                        revalidate: { authStore.loadFileCredential(atPath: fileCredential.sourcePath)?.refreshToken }
                    )
                }
                guard cached else { throw AntigravityError.authExpired }
                try Task.checkCancellation()
                switch try await fetchCloudCode(token: accessToken) {
                case .success(let result): return result
                case .authFailed: throw AntigravityError.authExpired
                case .forbidden: throw AntigravityError.accessDenied
                case .notFound: throw AntigravityError.quotaEndpointUnavailable
                // The refreshed token is valid, so a non-2xx here is a transient outage, not bad auth.
                case .unavailable: throw AntigravityError.unavailable
                }
            case .authFailed: throw AntigravityError.authExpired
            case .clientConfigurationInvalid: throw AntigravityError.oauthClientConfigurationInvalid
            case .unavailable: throw AntigravityError.unavailable
            }
        }

        if sawForbidden { throw AntigravityError.accessDenied }
        if sawNoQuotaEndpoint, !sawTransientFailure {
            throw AntigravityError.quotaEndpointUnavailable
        }
        // A refresh credential exists, so an unreachable endpoint is a transient failure.
        throw AntigravityError.unavailable
    }

    private enum CloudCodeProbe {
        case success(StrategyResult)
        case authFailed
        case forbidden
        case notFound
        case unavailable
    }

    private enum CodeAssistLookup {
        case response(plan: String?, project: String?)
        case authFailed
        case forbidden
        case notFound
        case unavailable

        var plan: String? {
            guard case .response(let plan, _) = self else { return nil }
            return plan
        }
    }

    private func fetchCloudCode(token: String) async throws -> CloudCodeProbe {
        // The native source uses only the summary endpoint: the saved sign-in's project scope is
        // resolved through loadCodeAssist, and no synthesized per-model quota is ever fabricated.
        if quotaSource == .nativeApp { return try await fetchNativeSavedQuota(token: token) }
        // Authoritative first: the quota summary (merged pools + weekly windows). A parsed summary —
        // even one with zero usable buckets — is the answer and must never fall into the legacy chain
        // below, which fabricates "fully used" from missing quota info. A 404 falls through; if every
        // quota endpoint is absent and no request has a transient failure, report that permanent state.
        let codeAssistTask = Task { try await loadCodeAssist(token: token) }
        return try await withTaskCancellationHandler {
            defer { codeAssistTask.cancel() }
            var sawNotFound = false
            var sawTransientFailure = false
            var sawUnusableSuccess = false
            switch try await usageClient.cloudCodeSummaries(token: token) {
            case .authFailed:
                return .authFailed
            case .forbidden:
                return .forbidden
            case .notFound:
                sawNotFound = true
                for index in AntigravityUsageClient.cloudCodeURLs.indices {
                    AntigravityUsageMapper.clearQuotaSummaryDiagnostics(sourceID: "cloud-code-\(index)")
                }
                break
            case .ok(let bodies, let allHostsAnswered):
                if let summary = AntigravityUsageMapper.parseQuotaSummariesResult(bodies, allHostsAnswered: allHostsAnswered) {
                    return .success(StrategyResult(
                        plan: try await codeAssistTask.value.plan,
                        lines: summary.lines,
                        replacesPriorQuotaProgress: summary.isComplete,
                        warning: summary.isComplete
                            ? nil
                            : "Some Antigravity quota limits could not be read. Missing limits may retain older values."
                    ))
                }
                // The named RPC answered, but its schema is not usable. Do not query legacy endpoints:
                // they turn missing quota into fabricated depleted meters.
                return .success(StrategyResult(
                    plan: try await codeAssistTask.value.plan,
                    lines: [],
                    replacesPriorQuotaProgress: false,
                    warning: "Antigravity quota summary could not be read. Existing limits are retained."
                ))
            case .unavailable:
                sawTransientFailure = true
                break
            }

            // Legacy: fetchAvailableModels — the full Antigravity model set (Gemini + Claude + GPT-OSS).
            switch try await usageClient.cloudCode(path: AntigravityUsageClient.fetchModelsPath, token: token, userAgent: AntigravityUsageClient.clientUserAgent, body: [:]) {
            case .authFailed:
                return .authFailed
            case .forbidden:
                return .forbidden
            case .notFound:
                sawNotFound = true
                break
            case .ok(let data):
                let lines = AntigravityUsageMapper.buildLines(AntigravityUsageMapper.parseCloudCodeModels(data))
                if !lines.isEmpty {
                    return .success(StrategyResult(plan: try await codeAssistTask.value.plan, lines: lines))
                }
                sawUnusableSuccess = true
            case .unavailable:
                sawTransientFailure = true
                break
            }

            // Fallback: the shared loadCodeAssist result supplies both the plan and project.
            // Its request already ran alongside the summary/models lookups.
            var plan: String?
            var project: String?
            switch try await codeAssistTask.value {
            case .authFailed: return .authFailed
            case .forbidden: return .forbidden
            case .response(let loadedPlan, let loadedProject):
                plan = loadedPlan
                project = loadedProject
            case .notFound:
                sawNotFound = true
            case .unavailable: sawTransientFailure = true
            }

            var quota = try await usageClient.cloudCode(
                path: AntigravityUsageClient.retrieveQuotaPath,
                token: token,
                userAgent: AntigravityUsageClient.clientUserAgent,
                body: project.map { ["project": $0] } ?? [:]
            )
            if project != nil, quota.isUnavailable {
                quota = try await usageClient.cloudCode(path: AntigravityUsageClient.retrieveQuotaPath, token: token, userAgent: AntigravityUsageClient.clientUserAgent, body: [:])
            }
            switch quota {
            case .authFailed: return .authFailed
            case .forbidden: return .forbidden
            case .notFound:
                sawNotFound = true
            case .ok(let data):
                let lines = AntigravityUsageMapper.buildLines(AntigravityUsageMapper.parseQuotaBuckets(data))
                if !lines.isEmpty { return .success(StrategyResult(plan: plan, lines: lines)) }
                sawUnusableSuccess = true
            case .unavailable:
                sawTransientFailure = true
            }
            return (sawNotFound || sawUnusableSuccess) && !sawTransientFailure ? .notFound : .unavailable
        } onCancel: {
            codeAssistTask.cancel()
        }
    }

    /// The saved-sign-in path: resolve the app's project once, then ask the summary endpoint for
    /// that project — retrying projectless only on a definitive refusal. No legacy per-model
    /// endpoint ever fills in for a missing summary.
    private func fetchNativeSavedQuota(token: String) async throws -> CloudCodeProbe {
        let account = try await loadCodeAssist(token: token)
        let project: String?
        if case .response(_, let value) = account { project = value } else { project = nil }
        var outcome = try await usageClient.cloudCodeSummaries(token: token, project: project)
        if project != nil {
            switch outcome {
            case .authFailed, .forbidden, .notFound:
                outcome = try await usageClient.cloudCodeSummaries(token: token)
            default: break
            }
        }
        switch outcome {
        case .authFailed: return .authFailed
        case .forbidden: return .forbidden
        case .notFound: return .notFound
        case .unavailable: return .unavailable
        case .ok(let bodies, let allHostsAnswered):
            guard let summary = AntigravityUsageMapper.parseQuotaSummariesResult(
                bodies,
                allHostsAnswered: allHostsAnswered
            ) else { return .unavailable }
            guard !summary.lines.isEmpty else { return .notFound }
            return .success(StrategyResult(
                plan: account.plan,
                lines: summary.lines,
                replacesPriorQuotaProgress: summary.isComplete,
                warning: summary.isComplete
                    ? nil
                    : "Some Antigravity quota limits could not be read. Missing limits may retain older values."
            ))
        }
    }

    private func loadCodeAssist(token: String) async throws -> CodeAssistLookup {
        // Plan and project lookups prefer production; daily has the active counters for quota reads.
        // The nested metadata identifies this client as the Antigravity IDE to the Cloud Code API.
        switch try await usageClient.cloudCode(
            path: AntigravityUsageClient.loadCodeAssistPath,
            token: token,
            userAgent: AntigravityUsageClient.clientUserAgent,
            body: ["metadata": ["ideType": "ANTIGRAVITY", "platform": "PLATFORM_UNSPECIFIED", "pluginType": "GEMINI"]],
            bases: AntigravityUsageClient.planProjectURLs
        ) {
        case .authFailed:
            return .authFailed
        case .forbidden:
            return .forbidden
        case .notFound:
            return .notFound
        case .ok(let data):
            return .response(
                plan: AntigravityUsageMapper.parseLoadCodeAssistPlan(data),
                project: AntigravityUsageMapper.parseProject(data)
            )
        case .unavailable:
            return .unavailable
        }
    }
}
