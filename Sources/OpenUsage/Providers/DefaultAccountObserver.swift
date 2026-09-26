import Foundation

/// Reads which account is signed in at a provider home. Identity keys only ever come from the
/// provider's own account metadata, so an account that cannot name itself is `unresolved`, never
/// guessed from a path, label, timestamp, or current selection.
struct DefaultAccountObserver: Sendable {
    enum Outcome: Equatable, Sendable {
        case resolved(identityKey: String, label: String?, anchor: String)
        case unresolved(reason: String)
        case absent
    }

    var environment: EnvironmentReading
    var files: TextFileAccessing
    var keychain: KeychainAccessing
    var homeDirectory: @Sendable () -> URL

    init(
        environment: EnvironmentReading = OpenUsageEnvironmentReader(),
        files: TextFileAccessing = LocalTextFileAccessor(),
        keychain: KeychainAccessing = SecurityKeychainAccessor(),
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser }
    ) {
        self.environment = environment
        self.files = files
        self.keychain = keychain
        self.homeDirectory = homeDirectory
    }

    private func expandTilde(_ path: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        return homeDirectory().path + String(path.dropFirst(1))
    }

    // MARK: - Claude

    struct ClaudeStateFile: Codable {
        struct OAuthAccount: Codable {
            var accountUuid: String?
            var emailAddress: String?
            var organizationUuid: String?
            var organizationName: String?
        }

        var oauthAccount: OAuthAccount?
    }

    static func claudeIdentityKey(_ account: ClaudeStateFile.OAuthAccount) -> String? {
        guard let uuid = account.accountUuid?.nilIfEmpty?.lowercased() else { return nil }
        guard let org = account.organizationUuid?.nilIfEmpty?.lowercased() else { return uuid }
        return "\(uuid)|\(org)"
    }

    static func claudeIdentityLabel(_ account: ClaudeStateFile.OAuthAccount) -> String? {
        let email = account.emailAddress?.nilIfEmpty
        guard let org = account.organizationName?.nilIfEmpty else { return email }
        return email.map { "\($0) (\(org))" } ?? org
    }

    func observeClaude() -> Outcome {
        var configDir = "~/.claude"
        if let raw = environment.value(for: "CLAUDE_CONFIG_DIR")?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            guard !raw.contains(",") else {
                return .unresolved(reason: "CLAUDE_CONFIG_DIR is a comma-separated list")
            }
            configDir = raw
        }
        let anchor = expandTilde(configDir)
        let identityPath = anchor == expandTilde("~/.claude")
            ? expandTilde("~/.claude.json")
            : anchor + "/.claude.json"
        let text: String?
        do {
            text = try files.readTextIfPresent(identityPath)
        } catch {
            return .unresolved(reason: "identity file unreadable: \(error.localizedDescription)")
        }
        guard let text else {
            return files.exists(anchor + "/.credentials.json")
                ? .unresolved(reason: "credentials present but no identity file")
                : .absent
        }
        guard let parsed = try? JSONDecoder().decode(ClaudeStateFile.self, from: Data(text.utf8)),
              let account = parsed.oauthAccount,
              let key = Self.claudeIdentityKey(account)
        else {
            return .unresolved(reason: "identity file present but names no account")
        }
        return .resolved(identityKey: key, label: Self.claudeIdentityLabel(account), anchor: anchor)
    }

    // MARK: - Codex

    /// Observe the default Codex credential source. Because the singleton provider can fall back to
    /// the global `Codex Auth` Keychain item, a present or unverifiable keychain item makes a file
    /// identity unsafe here; we refuse to stamp one account onto usage that might come from another.
    func observeCodex() -> Outcome {
        let homes: [String]
        if let raw = environment.value(for: "CODEX_HOME")?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            homes = [raw]
        } else {
            homes = ["~/.config/codex", "~/.codex"]
        }

        if keychain.genericPasswordExists(service: CodexAuthStore.keychainService) != false {
            return .unresolved(reason: "keychain credential present or unverifiable — identity unresolved this launch")
        }
        return observeCodex(homes: homes)
    }

    /// Observe one explicitly configured Codex home. Account-scoped runtimes created for these homes
    /// do not use the global keychain fallback, so the home's own `auth.json` is authoritative and can
    /// be resolved without consulting Keychain at all.
    func observeCodex(home: String) -> Outcome {
        observeCodex(homes: [home])
    }

    private func observeCodex(homes: [String]) -> Outcome {
        var sawFootprint = false
        for home in homes {
            let anchor = expandTilde(home.trimmingCharacters(in: .whitespacesAndNewlines))
            guard !anchor.isEmpty else { continue }
            let text: String?
            do {
                text = try files.readTextIfPresent(anchor + "/auth.json")
            } catch {
                sawFootprint = true
                continue
            }
            guard let text else { continue }
            sawFootprint = true
            guard let auth = CodexAuthStore.parseAuth(text),
                  auth.tokens?.accessToken?.nilIfEmpty != nil
            else { continue }
            let payload = auth.tokens?.idToken.flatMap { ProviderParse.jwtPayload($0) }
            let email = (payload?["email"] as? String)?.nilIfEmpty
            if let identity = CodexAuthStore.accountIdentity(in: auth) {
                return .resolved(identityKey: identity, label: email, anchor: anchor)
            }
        }
        return sawFootprint
            ? .unresolved(reason: "credentials present but no account identity")
            : .absent
    }

    static func chatGPTAccountID(inIDTokenPayload payload: [String: Any]?) -> String? {
        guard let payload else { return nil }
        let authClaim = payload["https://api.openai.com/auth"] as? [String: Any]
        let raw = (authClaim?["chatgpt_account_id"] ?? payload["chatgpt_account_id"]) as? String
        return raw?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}
