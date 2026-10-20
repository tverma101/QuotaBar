import CryptoKit
import Foundation

struct CodexTokens: Codable, Hashable, Sendable {
    var accessToken: String?
    var refreshToken: String?
    var idToken: String?
    var accountID: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case accountID = "account_id"
    }
}

struct CodexAuth: Codable, Hashable, Sendable {
    var tokens: CodexTokens?
    var lastRefresh: String?
    var apiKey: String?

    enum CodingKeys: String, CodingKey {
        case tokens
        case lastRefresh = "last_refresh"
        case apiKey = "OPENAI_API_KEY"
    }
}

struct CodexAuthState: Hashable, Sendable {
    enum Source: Hashable, Sendable {
        case file(path: String)
        case keychain(account: String)
    }

    var auth: CodexAuth
    var source: Source

    /// Whether this candidate carries a non-empty OAuth access token — the same bar refresh requires
    /// before fetching usage (an API-key-only auth.json can't serve the usage API). Keep the optional
    /// local credential probe aligned with this check.
    var hasUsableAccessToken: Bool {
        auth.tokens?.accessToken?.isEmpty == false
    }
}

enum CodexAuthError: Error, LocalizedError, Equatable {
    case notLoggedIn
    /// The Keychain item exists but macOS will not release it without a dialog. Distinct from
    /// `notLoggedIn`: the user *is* signed in, and re-authenticating changes nothing.
    case credentialPermissionRequired
    case credentialsUnreadable
    case sessionExpired
    case tokenConflict
    case tokenRevoked
    case tokenExpired
    case usageAPIKey
    case invalidAuthPayload

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "Not logged in. Run `codex` to authenticate."
        case .credentialPermissionRequired:
            return "macOS needs permission to read your Codex Keychain item. Refresh to be asked once, then choose Always Allow."
        case .credentialsUnreadable:
            return "QuotaBar found Codex credential data but couldn't read it. Check file permissions and that your login Keychain is unlocked, then refresh again."
        case .sessionExpired:
            return "Session expired. Run `codex` to log in again."
        case .tokenConflict:
            return "Token conflict. Run `codex` to log in again."
        case .tokenRevoked:
            return "Token revoked. Run `codex` to log in again."
        case .tokenExpired:
            return "Token expired. Run `codex` to log in again."
        case .usageAPIKey:
            return "Usage not available for API key."
        case .invalidAuthPayload:
            return "Codex auth data is invalid."
        }
    }

    var allowsAuthFallback: Bool {
        switch self {
        case .sessionExpired, .tokenConflict, .tokenRevoked, .tokenExpired:
            return true
        case .notLoggedIn, .usageAPIKey, .invalidAuthPayload, .credentialsUnreadable:
            return false
        // A Keychain ACL refusal is not an expired credential: falling back to another credential
        // source would mask the one action (Always Allow) that actually resolves it.
        case .credentialPermissionRequired:
            return false
        }
    }
}

struct CodexAuthStore: Sendable {
    static let keychainService = "Codex Auth"
    /// Refresh once the access token is within this window of its JWT `exp` — the same 5-minute slack
    /// the `codex` CLI itself uses, so QuotaBar rotates on the same schedule rather than guessing.
    static let accessTokenRefreshWindow: TimeInterval = 5 * 60
    private static let authFile = "auth.json"
    private static let defaultAuthHomes = ["~/.config/codex", "~/.codex"]

    var environment: EnvironmentReading
    var files: TextFileAccessing
    var keychain: KeychainAccessing
    var now: @Sendable () -> Date
    /// When set, this store is cryptographically/account-bound at the metadata level: auth from a
    /// different ChatGPT account, or auth whose account-id and id-token disagree, is invisible and
    /// cannot be persisted through this store. Provider-level checks remain as a second defense.
    var expectedIdentityKey: String?

    init(
        environment: EnvironmentReading = QuotaBarEnvironmentReader(),
        files: TextFileAccessing = LocalTextFileAccessor(),
        keychain: KeychainAccessing = SecurityKeychainAccessor(),
        now: @escaping @Sendable () -> Date = Date.init,
        expectedIdentityKey: String? = nil
    ) {
        self.environment = environment
        self.files = files
        self.keychain = keychain
        self.now = now
        self.expectedIdentityKey = Self.normalizedIdentityKey(expectedIdentityKey)
    }

    func loadAuthCandidates() throws -> [CodexAuthState] {
        var candidates: [CodexAuthState] = []
        var firstError: CodexAuthError?
        for path in authPaths() {
            do {
                if let candidate = try loadAuth(at: path) {
                    candidates.append(candidate)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as CodexAuthError {
                if firstError == nil { firstError = error }
            } catch {
                if firstError == nil { firstError = .credentialsUnreadable }
            }
        }
        // Keep using any readable, usable profile file. If none could be loaded, preserve the
        // distinction between absent credentials and an existing file that could not be read.
        if candidates.isEmpty, let firstError {
            throw firstError
        }
        return candidates
    }

    /// Reads the credential from a single on-disk auth file — the targeted counterpart to
    /// `loadKeychainAuth()`, used when reloading the exact source we already loaded from so we don't
    /// re-scan every candidate path. Returns `nil` when the file is missing or doesn't carry
    /// token-like auth; read/parse failures remain actionable instead of becoming a false miss.
    func loadAuth(at path: String) throws -> CodexAuthState? {
        let text: String?
        do {
            text = try files.readTextIfPresent(path)
        } catch let error as CancellationError {
            throw error
        } catch {
            throw CodexAuthError.credentialsUnreadable
        }
        guard let text else { return nil }
        guard let auth = Self.parseAuth(text) else { throw CodexAuthError.invalidAuthPayload }
        guard Self.hasTokenLikeAuth(auth), matchesExpectedAccount(auth) else { return nil }
        return CodexAuthState(auth: auth, source: .file(path: path))
    }

    /// Throws rather than returning `nil` for an unreadable item: "macOS will not release this without
    /// a dialog" and "there is no credential" are different problems with different fixes, and
    /// collapsing the first into the second tells a signed-in user to go re-authenticate.
    func loadKeychainAuth() throws -> CodexAuthState? {
        var permissionRequired = false
        var unreadable = false
        for account in keychainAccountCandidates() {
            do {
                if let state = try loadKeychainAuth(account: account) {
                    return state
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch CodexAuthError.credentialPermissionRequired {
                permissionRequired = true
            } catch {
                unreadable = true
            }
        }

        if permissionRequired {
            // The shared Keychain gate logs the first silent refusal; later reads use its blocked
            // state and must not repeat this line on every scheduler pass.
            throw CodexAuthError.credentialPermissionRequired
        }
        if unreadable {
            throw CodexAuthError.credentialsUnreadable
        }
        return nil
    }

    /// Reload one exact Codex CLI Keychain item. Codex scopes its `Codex Auth` item to a stable key
    /// derived from CODEX_HOME, so a service-only query can select another profile's credential.
    func loadKeychainAuth(account: String) throws -> CodexAuthState? {
        let value: String?
        do {
            value = try keychain.readGenericPasswordForRefresh(
                service: Self.keychainService,
                account: account
            )
        } catch let error as CancellationError {
            throw error
        } catch KeychainError.interactionNotAllowed {
            throw CodexAuthError.credentialPermissionRequired
        } catch {
            throw CodexAuthError.credentialsUnreadable
        }
        guard let value,
              let auth = Self.parseAuth(value),
              Self.hasTokenLikeAuth(auth),
              matchesExpectedAccount(auth)
        else {
            return nil
        }
        return CodexAuthState(auth: auth, source: .keychain(account: account))
    }

    func save(_ state: CodexAuthState) throws {
        guard matchesExpectedAccount(state.auth) else {
            throw CodexAuthError.tokenConflict
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = state.source.isFile ? [.prettyPrinted, .sortedKeys] : []
        let data = try encoder.encode(state.auth)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CodexAuthError.invalidAuthPayload
        }

        switch state.source {
        case .file(let path):
            try files.writeText(path, text)
        case .keychain(let account):
            try keychain.writeGenericPassword(service: Self.keychainService, account: account, value: text)
        }
    }

    /// Persist a refresh only while the exact credential generation that produced it is still live.
    /// Logout removes the source and a CLI/account switch replaces its token bundle; either must win
    /// over a refresh response that was already in flight. Non-token metadata is merged from the
    /// live file/Keychain value so a refresh does not roll back concurrent CLI metadata updates.
    func save(_ state: CodexAuthState, replacing original: CodexAuthState) throws {
        guard state.source == original.source else { throw CodexAuthError.tokenConflict }

        let live = try ProviderRefreshContext.withCredentialSourceRevalidation {
            switch original.source {
            case .file(let path):
                return try loadAuth(at: path)
            case .keychain(let account):
                return try loadKeychainAuth(account: account)
            }
        }

        guard let live,
              live.auth.tokens == original.auth.tokens,
              matchesExpectedAccount(live.auth) else {
            throw CodexAuthError.tokenConflict
        }

        var merged = live
        merged.auth.tokens = state.auth.tokens
        merged.auth.lastRefresh = state.auth.lastRefresh
        try save(merged)
    }

    /// Whether the access token should be proactively refreshed.
    ///
    /// Prefers the access token's own JWT `exp` — refresh only when it is at (or within
    /// `accessTokenRefreshWindow` of) expiry, mirroring the `codex` CLI. The hardcoded 8-day
    /// wall-clock age is only a fallback for tokens whose `exp` we can't read; on its own it forced a
    /// refresh while the access token was still valid, tripping `refresh_token_reused` (issue #516).
    /// A brand-new login with no `last_refresh` and no readable `exp` does NOT need a refresh.
    func needsRefresh(_ auth: CodexAuth) -> Bool {
        if let accessToken = auth.tokens?.accessToken,
           let expiresAt = accessTokenExpiresAt(accessToken) {
            return expiresAt.timeIntervalSince(now()) <= Self.accessTokenRefreshWindow
        }
        guard let lastRefresh = auth.lastRefresh,
              let date = OpenUsageISO8601.date(from: lastRefresh)
        else {
            return false
        }
        return now().timeIntervalSince(date) > 8 * 24 * 60 * 60
    }

    /// The access token's expiry from its JWT `exp` claim, or `nil` when the token isn't a decodable
    /// JWT or omits `exp`.
    func accessTokenExpiresAt(_ token: String) -> Date? {
        guard let exp = ProviderParse.jwtPayload(token)?["exp"].flatMap(ProviderParse.number) else {
            return nil
        }
        return Date(timeIntervalSince1970: exp)
    }

    func authPaths() -> [String] {
        if let codexHome = codexHome() {
            return [joinPath(codexHome, Self.authFile)]
        }
        return Self.defaultAuthHomes.map { joinPath($0, Self.authFile) }
    }

    func codexHome() -> String? {
        guard let codexHome = environment.value(for: "CODEX_HOME")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !codexHome.isEmpty
        else {
            return nil
        }
        return codexHome
    }

    /// Codex stores direct-keyring credentials at `Codex Auth` / `cli|<16 hex chars>`, where the
    /// suffix is the first 16 lowercase SHA-256 hex characters of the canonical CODEX_HOME path.
    /// The CLI falls back to the original path when canonicalization fails; mirror that for homes
    /// that have not been created yet.
    static func keychainAccount(forCodexHome home: String) -> String {
        let expandedHome = expandHome(home)
        let canonicalHome: String
        if FileManager.default.fileExists(atPath: expandedHome) {
            canonicalHome = URL(fileURLWithPath: expandedHome)
                .resolvingSymlinksInPath()
                .standardizedFileURL
                .path
        } else {
            canonicalHome = expandedHome
        }
        let digest = SHA256.hash(data: Data(canonicalHome.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "cli|\(hex.prefix(16))"
    }

    func keychainAccountCandidates() -> [String] {
        let homes = codexHome().map { [$0] } ?? Self.defaultAuthHomes
        return homes.map(Self.keychainAccount(forCodexHome:))
    }

    /// Returns a copy bound to one account identity. Provider construction uses this even when a
    /// caller supplied an unbound store, so changing `CODEX_HOME` or injecting another auth source
    /// cannot replace the selected card's credentials behind the provider's back.
    func scoped(to identityKey: String?) -> CodexAuthStore {
        var copy = self
        copy.expectedIdentityKey = Self.normalizedIdentityKey(identityKey)
        return copy
    }

    static func parseAuth(_ text: String) -> CodexAuth? {
        ProviderParse.decodeJSONWithHexFallback(text, as: CodexAuth.self)
    }

    static func hasTokenLikeAuth(_ auth: CodexAuth) -> Bool {
        if auth.tokens?.accessToken?.isEmpty == false { return true }
        if auth.apiKey?.isEmpty == false { return true }
        return false
    }

    /// Metadata-only account identity used by both launch-time attribution and scoped credential
    /// loading. If `account_id` and the JWT's ChatGPT account claim disagree, fail closed instead of
    /// trusting whichever field happens to be present first.
    static func accountIdentity(in auth: CodexAuth) -> String? {
        let (accountID, idTokenID) = identityParts(in: auth)
        guard !hasIdentityConflict(accountID: accountID, idTokenID: idTokenID) else { return nil }
        return accountID ?? idTokenID
    }

    static func hasIdentityConflict(in auth: CodexAuth) -> Bool {
        let (accountID, idTokenID) = identityParts(in: auth)
        return hasIdentityConflict(accountID: accountID, idTokenID: idTokenID)
    }

    static func normalizedIdentityKey(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty?.lowercased()
    }

    private func matchesExpectedAccount(_ auth: CodexAuth) -> Bool {
        guard !Self.hasIdentityConflict(in: auth) else { return false }
        guard let expectedIdentityKey else { return true }
        guard let actual = Self.accountIdentity(in: auth) else { return false }
        return actual.caseInsensitiveCompare(expectedIdentityKey) == .orderedSame
    }

    private static func identityParts(in auth: CodexAuth) -> (accountID: String?, idTokenID: String?) {
        let accountID = normalizedIdentityKey(auth.tokens?.accountID)
        let idTokenID = auth.tokens?.idToken
            .flatMap { ProviderParse.jwtPayload($0) }
            .flatMap(DefaultAccountObserver.chatGPTAccountID(inIDTokenPayload:))
            .flatMap(normalizedIdentityKey)
        return (accountID, idTokenID)
    }

    private static func hasIdentityConflict(accountID: String?, idTokenID: String?) -> Bool {
        guard let accountID, let idTokenID else { return false }
        return accountID.caseInsensitiveCompare(idTokenID) != .orderedSame
    }

    private func joinPath(_ base: String, _ leaf: String) -> String {
        base.trimmingTrailingSlashes + "/" + leaf
    }
}

private extension CodexAuthState.Source {
    var isFile: Bool {
        if case .file = self { return true }
        return false
    }
}
