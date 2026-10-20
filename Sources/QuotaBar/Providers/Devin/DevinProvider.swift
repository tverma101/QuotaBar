import Foundation

@MainActor
final class DevinProvider: ProviderRuntime {
    /// Diagnostic keys for the three ways a quota request can fail. Each kind is logged on its own
    /// line so a server outage, a schema change, and a broken network stay distinguishable in the log.
    static let httpFailureDiagnosticKeyPrefix = "devin.usage.http."
    static let invalidResponseDiagnosticKey = "devin.usage.invalid-response"
    static let transportFailureDiagnosticKey = "devin.usage.transport"

    let provider = Provider(
        id: "devin",
        displayName: "Devin",
        icon: .providerMark("devin"),
        links: [
            .init(label: "Dashboard", url: "https://app.devin.ai/settings/plans")
        ]
    )

    let authStore: DevinAuthStore
    let usageClient: DevinUsageClient
    let now: @Sendable () -> Date

    init(
        authStore: DevinAuthStore = DevinAuthStore(),
        usageClient: DevinUsageClient = DevinUsageClient(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(id: "devin.daily", provider: provider, title: "Daily", metricLabel: "Daily quota")
                .exportingLimit("daily", unit: "percent")
                .hidingWhenEmpty(),
            .percent(id: "devin.weekly", provider: provider, title: "Weekly", metricLabel: "Weekly quota")
                .exportingLimit("weekly", unit: "percent"),
            .dollarBalance(id: "devin.extra", provider: provider, title: "Extra Balance", metricLabel: "Extra usage balance", valueWord: "left").hidingWhenEmpty()
                .exportingLimit("extraUsageBalance", kind: .balance, unit: "usd", source: .value(kind: .dollars))
        ]
    }

    func hasLocalCredentials() async -> Bool {
        // Same sources as `refresh()`: the credentials file, then the Devin app's stored auth. Both are
        // blocking disk/SQLite reads, so both run off the main actor (see `loadOffMainActor`).
        do {
            if try await loadOffMainActor({ [authStore] in try authStore.loadCredentialsFile() }) != nil {
                return true
            }
            return try await loadOffMainActor { [authStore] in try authStore.loadAppAuth() } != nil
        } catch DevinAuthError.credentialsUnreadable {
            // Keep an indeterminate but present local source enabled so refresh can show its repair path.
            return true
        } catch {
            return false
        }
    }

    func refresh() async -> ProviderSnapshot {
        var sawAPIKey = false
        var sawAuthFailure = false
        var credentialSourceUnreadable = false
        var requestFailure: DevinAttemptFailure?
        let credentials: DevinAuth?
        do {
            credentials = try await loadOffMainActor { [authStore] in try authStore.loadCredentialsFile() }
        } catch DevinAuthError.credentialsUnreadable {
            credentials = nil
            credentialSourceUnreadable = true
        } catch {
            if ProviderCancellation.isCancellation(error) {
                return cancelledRefreshSnapshot(provider: provider)
            }
            return ProviderSnapshot.error(provider: provider, error: error)
        }
        guard !Task.isCancelled else { return cancelledRefreshSnapshot(provider: provider) }

        if let credentials {
            sawAPIKey = true
            switch await attempt(auth: credentials) {
            case .success(let mapped):
                return snapshot(from: mapped)
            case .authFailure:
                sawAuthFailure = true
            case .failed(let failure):
                requestFailure = requestFailure ?? failure
            case .cancelled:
                return cancelledRefreshSnapshot(provider: provider)
            }
        }

        let appAuth: DevinAuth?
        do {
            appAuth = try await loadOffMainActor { [authStore] in try authStore.loadAppAuth() }
        } catch {
            if ProviderCancellation.isCancellation(error) {
                return cancelledRefreshSnapshot(provider: provider)
            }
            return ProviderSnapshot.error(provider: provider, error: error)
        }
        guard !Task.isCancelled else { return cancelledRefreshSnapshot(provider: provider) }
        if let appAuth,
           credentials == nil || shouldAttemptAppAuth(appAuth, after: credentials) {
            sawAPIKey = true
            switch await attempt(auth: appAuth) {
            case .success(let mapped):
                return snapshot(from: mapped)
            case .authFailure:
                sawAuthFailure = true
            case .failed(let failure):
                requestFailure = requestFailure ?? failure
            case .cancelled:
                return cancelledRefreshSnapshot(provider: provider)
            }
        }

        if credentialSourceUnreadable {
            return ProviderSnapshot.error(provider: provider, error: DevinAuthError.credentialsUnreadable)
        }
        if sawAuthFailure {
            return ProviderSnapshot.error(provider: provider, error: DevinAuthError.notLoggedIn)
        }
        // A failed request keeps its own message and telemetry bucket: "the service is down", "the
        // payload changed", and "the network is broken" are different problems with different fixes.
        if let requestFailure {
            return ProviderSnapshot.error(
                provider: provider,
                message: requestFailure.message,
                category: requestFailure.category
            )
        }
        if sawAPIKey {
            return ProviderSnapshot.error(provider: provider, error: DevinUsageError.quotaUnavailable)
        }
        return ProviderSnapshot.error(provider: provider, error: DevinAuthError.notLoggedIn)
    }

    private func attempt(auth: DevinAuth) async -> DevinAuthAttempt {
        guard !Task.isCancelled else { return .cancelled }
        let apiServerURL = authStore.effectiveAPIServerURL(auth)
        do {
            let response = try await usageClient.fetchUserStatus(auth: auth, apiServerURL: apiServerURL)
            try Task.checkCancellation()
            if response.statusCode == 401 || response.statusCode == 403 {
                return .authFailure
            }
            guard (200..<300).contains(response.statusCode) else {
                DiagnosticGate.logOnce(for: Self.httpFailureDiagnosticKeyPrefix + String(response.statusCode)) {
                    AppLog.warn(LogTag.plugin("devin"), "quota request failed (HTTP \(response.statusCode))")
                }
                return .failed(.requestFailed(response.statusCode))
            }
            do {
                let mapped = try DevinUsageMapper.mapUserStatusResponse(response, now: now())
                DiagnosticGate.clearFailures(prefix: "devin.usage.")
                return .success(mapped)
            } catch let error as DevinUsageError {
                switch error {
                case .quotaUnavailable:
                    // The response was readable; the account simply has no quota meters to show.
                    return .failed(.quotaUnavailable)
                case .invalidResponse:
                    DiagnosticGate.logOnce(for: Self.invalidResponseDiagnosticKey) {
                        AppLog.warn(LogTag.plugin("devin"), "quota response could not be read")
                    }
                    return .failed(.invalidResponse)
                }
            } catch {
                DiagnosticGate.logOnce(for: Self.invalidResponseDiagnosticKey) {
                    AppLog.warn(
                        LogTag.plugin("devin"),
                        "quota response could not be read: \(error.localizedDescription)"
                    )
                }
                return .failed(.invalidResponse)
            }
        } catch {
            if ProviderCancellation.isCancellation(error) { return .cancelled }
            DiagnosticGate.logOnce(for: Self.transportFailureDiagnosticKey) {
                AppLog.warn(
                    LogTag.plugin("devin"),
                    "quota request failed (transport): \(error.localizedDescription)"
                )
            }
            return .failed(.connectionFailed)
        }
    }

    private func shouldAttemptAppAuth(_ appAuth: DevinAuth, after credentials: DevinAuth?) -> Bool {
        guard let credentials else { return true }
        return appAuth.apiKey != credentials.apiKey ||
            authStore.effectiveAPIServerURL(appAuth) != authStore.effectiveAPIServerURL(credentials)
    }

    private func snapshot(from mapped: DevinMappedUsage) -> ProviderSnapshot {
        ProviderSnapshot.make(provider: provider, plan: mapped.plan, lines: mapped.lines, refreshedAt: now())
    }
}

private enum DevinAuthAttempt {
    case success(DevinMappedUsage)
    case authFailure
    case failed(DevinAttemptFailure)
    case cancelled
}

/// Why a Devin quota request produced no meters. Each kind keeps its own user-facing advice and its
/// own telemetry bucket instead of collapsing into one "unavailable" message.
private enum DevinAttemptFailure {
    case requestFailed(Int)
    case invalidResponse
    case connectionFailed
    case quotaUnavailable

    var message: String {
        switch self {
        case .requestFailed(let status):
            return "Devin's service returned an error (HTTP \(status)). Try again later."
        case .invalidResponse:
            return "Devin returned quota data QuotaBar couldn't read. Try again later."
        case .connectionFailed:
            return "QuotaBar couldn't reach Devin. Check your connection and try again."
        case .quotaUnavailable:
            return DevinUsageError.quotaUnavailable.localizedDescription
        }
    }

    var category: ErrorCategory {
        switch self {
        case .requestFailed(let status): ErrorCategory.http(status)
        case .invalidResponse: .decoding
        case .connectionFailed: .network
        case .quotaUnavailable: .notAvailable
        }
    }
}
