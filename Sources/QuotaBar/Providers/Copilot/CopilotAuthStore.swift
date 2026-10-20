import Foundation

/// A GitHub token already on the machine, usable against the Copilot usage endpoint.
struct CopilotToken: Hashable, Sendable {
    var value: String
}

enum CopilotAuthError: Error, LocalizedError, Equatable {
    case notLoggedIn
    /// The Keychain item exists but macOS will not release it without a dialog. Distinct from
    /// `notLoggedIn`: the user *is* signed in, and re-authenticating changes nothing.
    case credentialPermissionRequired
    case credentialsUnreadable
    case invalidCredentials
    case tokenInvalid
    case accessDenied

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "Sign in to GitHub Copilot in your editor, or run gh auth login, and try again."
        case .credentialPermissionRequired:
            return "macOS needs permission to read your Copilot Keychain item. Refresh to be asked once, then choose Always Allow."
        case .credentialsUnreadable:
            return "QuotaBar couldn't read a Copilot credential source. Check file access for your editor or GitHub CLI config, or unlock your login Keychain, then refresh again."
        case .invalidCredentials:
            return "QuotaBar found malformed Copilot editor credentials. Repair or remove the invalid apps.json or hosts.json file, then sign in again with your editor or GitHub CLI."
        case .tokenInvalid:
            return "GitHub token invalid or expired. Re-authenticate (gh auth login) and try again."
        case .accessDenied:
            return "GitHub denied access to Copilot usage. Check your Copilot license and organization policy."
        }
    }
}

/// Reads a GitHub token that Copilot tooling already left on the machine — no login flow, no browser
/// cookies. Sources are tried prompt-free files first, Keychain last:
/// 1. Copilot editor config `~/.config/github-copilot/apps.json` (older `hosts.json`) — the OAuth token
///    the VS Code / JetBrains / Neovim Copilot plugins write. Universal and file-based.
/// 2. GitHub CLI `~/.config/gh/hosts.yml` `oauth_token` — present when `gh` stores the token in a file.
/// 3. GitHub CLI Keychain item (service `gh:github.com`) — go-keyring-wrapped, used when `gh` stores the
///    token in the system keyring instead of the file.
struct CopilotAuthStore: Sendable {
    static let editorAppsPath = "~/.config/github-copilot/apps.json"
    static let editorHostsPath = "~/.config/github-copilot/hosts.json"
    static let ghHostsPath = "~/.config/gh/hosts.yml"
    static let ghKeychainService = "gh:github.com"

    var files: TextFileAccessing
    var keychain: KeychainAccessing

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        keychain: KeychainAccessing = SecurityKeychainAccessor()
    ) {
        self.files = files
        self.keychain = keychain
    }

    /// First non-empty source wins. Blocking (Keychain) — call off the main actor.
    /// Throws `credentialPermissionRequired` rather than returning `nil` when the Keychain item exists
    /// but macOS refuses to release it, so the provider does not report a signed-in user as
    /// "not logged in" — a remedy that cannot possibly help them.
    func loadToken() throws -> CopilotToken? {
        var sawUnreadableSource = false
        var sawInvalidCredentials = false
        do {
            if let editor = try loadFromEditorConfig() { return editor }
        } catch CopilotAuthError.credentialsUnreadable {
            sawUnreadableSource = true
        } catch CopilotAuthError.invalidCredentials {
            sawInvalidCredentials = true
        }
        do {
            if let config = try loadFromGhConfig() { return config }
        } catch CopilotAuthError.credentialsUnreadable {
            sawUnreadableSource = true
        }
        do {
            if let keychain = try loadFromGhKeychain() { return keychain }
        } catch CopilotAuthError.credentialsUnreadable {
            sawUnreadableSource = true
        }
        if sawInvalidCredentials { throw CopilotAuthError.invalidCredentials }
        if sawUnreadableSource { throw CopilotAuthError.credentialsUnreadable }
        return nil
    }

    // MARK: - Sources

    func loadFromEditorConfig() throws -> CopilotToken? {
        var sawUnreadableFile = false
        var sawInvalidFile = false
        for path in [Self.editorAppsPath, Self.editorHostsPath] {
            let text: String?
            do {
                text = try readConfigText(path)
            } catch CopilotAuthError.credentialsUnreadable {
                sawUnreadableFile = true
                continue
            }
            guard let text else { continue }
            switch Self.editorJSONToken(text) {
            case .token(let token):
                return CopilotToken(value: token)
            case .noToken:
                continue
            case .malformed:
                sawInvalidFile = true
            }
        }
        if sawInvalidFile { throw CopilotAuthError.invalidCredentials }
        if sawUnreadableFile { throw CopilotAuthError.credentialsUnreadable }
        return nil
    }

    func loadFromGhConfig() throws -> CopilotToken? {
        guard let text = try readConfigText(Self.ghHostsPath),
              let token = Self.yamlValue(text, key: "oauth_token")
        else {
            return nil
        }
        return CopilotToken(value: token)
    }

    func loadFromGhKeychain() throws -> CopilotToken? {
        guard let raw = try readGhKeychainRaw(),
              let token = ProviderParse.unwrapGoKeyring(raw)
        else {
            return nil
        }
        return CopilotToken(value: token)
    }

    /// Throws `credentialPermissionRequired` when the item exists but macOS will not release it, so the
    /// caller stops at "macOS needs permission" instead of falling through to "not logged in".
    private func readGhKeychainRaw() throws -> String? {
        // `gh` stores its Keychain item under the GitHub username as the account. Read it scoped to that
        // account when we can recover it from hosts.yml; otherwise fall back to a service-only lookup.
        if let account = try ghUsername() {
            do {
                return try keychain.readGenericPasswordForRefresh(
                    service: Self.ghKeychainService,
                    account: account
                )
            } catch KeychainError.interactionNotAllowed {
                // A definitive answer, not a miss: the item is there but macOS will not release it
                // silently. Falling through would repeat the entire silent-then-escalate chain for a
                // lookup that cannot succeed, and on a manual refresh could raise a second dialog for
                // the same item.
                // The shared Keychain gate logs the first silent refusal; do not repeat it after the
                // item has been remembered as blocked.
                throw CopilotAuthError.credentialPermissionRequired
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try ProviderCancellation.rethrowIfCancellation(error)
                // A miss is returned as nil. A storage error is not evidence that this account has no
                // item, and retrying a broader query could select a different GitHub account.
                throw CopilotAuthError.credentialsUnreadable
            }
        }
        // A service-only lookup is a *different item* from the account-scoped one, so its refusal must
        // not be confused with the account-scoped miss handled above.
        do {
            return try keychain.readGenericPasswordForRefresh(service: Self.ghKeychainService)
        } catch KeychainError.interactionNotAllowed {
            // The shared Keychain gate logs the first silent refusal; do not repeat it after the
            // item has been remembered as blocked.
            throw CopilotAuthError.credentialPermissionRequired
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try ProviderCancellation.rethrowIfCancellation(error)
            throw CopilotAuthError.credentialsUnreadable
        }
    }

    private func ghUsername() throws -> String? {
        guard let text = try readConfigText(Self.ghHostsPath) else { return nil }
        return Self.yamlValue(text, key: "user")
    }

    /// Missing files are ordinary source misses. A present file that cannot be read is indeterminate,
    /// not a logout; preserve it as an actionable credential-access error for refresh and seeding.
    private func readConfigText(_ path: String) throws -> String? {
        let diagnosticKey = "auth.copilot.config.\(path)"
        do {
            let text = try files.readTextIfPresent(path)
            DiagnosticGate.clearFailure(diagnosticKey)
            return text
        } catch {
            try ProviderCancellation.rethrowIfCancellation(error)
            DiagnosticGate.logOnce(for: diagnosticKey) {
                AppLog.error(LogTag.auth("copilot"), "local credential config read failed: \(path)")
            }
            throw CopilotAuthError.credentialsUnreadable
        }
    }

    // MARK: - Parsing (pure)

    /// Pull a github.com `oauth_token` from the Copilot editor config. The file is a JSON object keyed by
    /// host — `"github.com"` (older `hosts.json`) or `"github.com:<appId>"` (newer `apps.json`) — each
    /// value an object carrying `oauth_token`. Only github.com entries are used: another host's token
    /// (e.g. GitHub Enterprise) must not be sent to api.github.com, and returning `nil` lets the chain
    /// fall through to gh config / keychain, which may hold a valid github.com token.
    static func oauthToken(fromEditorJSON text: String) -> String? {
        guard case .token(let token) = editorJSONToken(text) else { return nil }
        return token
    }

    private enum EditorJSONToken {
        case token(String)
        case noToken
        case malformed
    }

    private static func editorJSONToken(_ text: String) -> EditorJSONToken {
        guard let data = text.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data),
              let object = value as? [String: Any]
        else {
            return .malformed
        }

        var sawMalformedEntry = false
        for (key, value) in object where key == "github.com" || key.hasPrefix("github.com:") {
            guard let dict = value as? [String: Any] else {
                sawMalformedEntry = true
                continue
            }
            guard let rawToken = dict["oauth_token"] else { continue }
            guard let token = rawToken as? String else {
                sawMalformedEntry = true
                continue
            }
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return .token(trimmed) }
        }
        return sawMalformedEntry ? .malformed : .noToken
    }

    /// Read an indented `key: value` from within a specific host block of the `hosts.yml` GitHub CLI
    /// writes. `gh` keys each host block by a top-level (unindented) `<host>:` line; reading must be
    /// scoped to the `github.com` block, because a GitHub Enterprise block in the same file would
    /// otherwise let its `oauth_token` win and get sent to api.github.com (a guaranteed 401/403).
    /// `users:` (the nested map) doesn't match `user:` because the colon position differs.
    static func yamlValue(_ text: String, key: String, host: String = "github.com") -> String? {
        let prefix = key + ":"
        let hostHeader = host + ":"
        var inHost = false
        for line in text.split(whereSeparator: \.isNewline) {
            // An unindented line starts a new top-level block (a host header or other root key); only
            // the github.com block's children should be read.
            if let first = line.first, !first.isWhitespace {
                inHost = line.trimmingCharacters(in: .whitespaces).hasPrefix(hostHeader)
                continue
            }
            guard inHost else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(prefix) else { continue }
            let value = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            let unquoted = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return unquoted.isEmpty ? nil : unquoted
        }
        return nil
    }

}
