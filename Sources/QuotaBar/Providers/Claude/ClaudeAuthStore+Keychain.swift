import Foundation

extension ClaudeAuthStore {
    func loadKeychainCredentials(
        allowInteraction: Bool,
        interactionGate: CredentialInteractionGate?
    ) -> (candidate: ClaudeCredentialState?, permissionRequired: Bool, readFailed: Bool, cancelled: Bool) {
        // The service name is safe to log; NEVER log the returned credential blob / OAuth tokens.
        var permissionRequired = false
        var readFailed = false
        for service in keychainServiceCandidates() {
            do {
                if let value = try readClaudeKeychainPassword(
                    service: service,
                    currentUserOnly: true,
                    allowInteraction: allowInteraction,
                    interactionGate: interactionGate
                ), let state = credentialState(
                    from: value,
                    service: service,
                    source: .keychainCurrentUser(service: service)
                ) {
                    return (state, permissionRequired, readFailed, false)
                }
            } catch KeychainError.interactionNotAllowed {
                permissionRequired = true
                continue
            } catch is CancellationError {
                return (nil, permissionRequired, readFailed, true)
            } catch {
                readFailed = true
            }

            do {
                if let value = try readClaudeKeychainPassword(
                    service: service,
                    currentUserOnly: false,
                    allowInteraction: allowInteraction,
                    interactionGate: interactionGate
                ), let state = credentialState(
                    from: value,
                    service: service,
                    source: .keychainLegacy(service: service)
                ) {
                    return (state, permissionRequired, readFailed, false)
                }
            } catch KeychainError.interactionNotAllowed {
                permissionRequired = true
                continue
            } catch is CancellationError {
                return (nil, permissionRequired, readFailed, true)
            } catch {
                readFailed = true
            }
            AppLog.debug(.keychain, "read miss service=\(service)")
        }
        return (nil, permissionRequired, readFailed, false)
    }

    private func readClaudeKeychainPassword(
        service: String,
        currentUserOnly: Bool,
        allowInteraction: Bool,
        interactionGate: CredentialInteractionGate?
    ) throws -> String? {
        if currentUserOnly {
            return try keychain.readGenericPasswordForRefreshForCurrentUser(
                service: service,
                allowInteraction: allowInteraction,
                interactionGate: interactionGate
            )
        }
        return try keychain.readGenericPasswordForRefresh(
            service: service,
            allowInteraction: allowInteraction,
            interactionGate: interactionGate
        )
    }

    /// Parse one Keychain hit without logging its credential blob or OAuth tokens.
    private func credentialState(
        from value: String?,
        service: String,
        source: ClaudeCredentialState.Source
    ) -> ClaudeCredentialState? {
        guard let value,
              let parsed = Self.parseCredentials(value),
              let oauth = parsed.claudeAiOauth,
              oauth.accessToken?.isEmpty == false
        else {
            return nil
        }
        AppLog.debug(.keychain, "read hit service=\(service)")
        return ClaudeCredentialState(oauth: oauth, source: source, fullData: parsed, inferenceOnly: false)
    }
}
