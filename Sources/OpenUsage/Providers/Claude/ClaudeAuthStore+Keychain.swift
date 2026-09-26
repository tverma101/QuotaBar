import Foundation

extension ClaudeAuthStore {
    func loadKeychainCredentials(
        allowInteraction: Bool,
        interactionGate: CredentialInteractionGate?
    ) -> ClaudeCredentialState? {
        // The service name is safe to log; NEVER log the returned credential blob / OAuth tokens.
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
                    return state
                }
            } catch KeychainError.interactionNotAllowed {
                AppLog.debug(.keychain, "Claude Code Keychain read skipped; user interaction is unavailable")
                return nil
            } catch {
                // Preserve the established fallback behavior for absent, malformed, or unreadable entries.
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
                    return state
                }
            } catch KeychainError.interactionNotAllowed {
                AppLog.debug(.keychain, "Claude Code Keychain read skipped; user interaction is unavailable")
                return nil
            } catch {
                // Preserve the established fallback behavior for absent, malformed, or unreadable entries.
            }
            AppLog.debug(.keychain, "read miss service=\(service)")
        }
        return nil
    }

    private func readClaudeKeychainPassword(
        service: String,
        currentUserOnly: Bool,
        allowInteraction: Bool,
        interactionGate: CredentialInteractionGate?
    ) throws -> String? {
        do {
            if currentUserOnly {
                return try keychain.readGenericPasswordForCurrentUser(service: service, allowInteraction: false)
            }
            return try keychain.readGenericPassword(service: service, allowInteraction: false)
        } catch KeychainError.interactionNotAllowed {
            guard allowInteraction, interactionGate?.claim() ?? true else {
                throw KeychainError.interactionNotAllowed
            }
            if currentUserOnly {
                return try keychain.readGenericPasswordForCurrentUser(service: service, allowInteraction: true)
            }
            return try keychain.readGenericPassword(service: service, allowInteraction: true)
        }
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
