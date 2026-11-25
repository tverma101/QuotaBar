import CryptoKit
import Foundation

/// Credentials Antigravity already has on the machine. On current builds the OAuth tokens live in the
/// macOS Keychain (service `gemini`, account `antigravity`) as a `go-keyring-base64`-wrapped JSON blob
/// holding an access token, a refresh token, and an expiry — written by the Antigravity app / `agy` CLI.
/// (The old SQLite `oauthToken` envelope no longer carries tokens, so it isn't read.)
struct AntigravityKeychainToken: Sendable, Equatable {
    var accessToken: String?
    var refreshToken: String?
    var expiry: Date?
}

/// T3 Code's private Antigravity instances keep a self-contained OAuth credential on disk
/// (`acp_token.json`: refresh token plus the instance's own client pair). Reading it needs no
/// Keychain grant, so a per-build cdhash change cannot lock QuotaBar out of quota the way the
/// Keychain ACL does. QuotaBar only ever reads the file; T3 Code owns writing it.
struct AntigravityFileCredential: Sendable, Equatable {
    var refreshToken: String
    var clientID: String
    var clientSecret: String
    var projectID: String?
    var sourcePath: String
}

struct AntigravityAuthStore: Sendable {
    static let keychainService = "gemini"
    static let keychainAccount = "antigravity"
    static let unresolvedCacheIdentityKey = "antigravity-unresolved"
    /// Our own cache of refreshed access tokens, so a Google OAuth refresh happens ~once per token
    /// lifetime instead of every refresh cycle. We never write back to Antigravity's keychain item.
    // Native-source builds keep their derived-token cache under a native name; the old T3-era file
    // stays on disk unreferenced so it can never be mistaken for this app's credential.
    static let cachePath = "~/Library/Application Support/QuotaBar/antigravity/native-auth.json"
    private static let cacheReadFailureKey = "auth.antigravity.cache.read"
    private static let cacheDecodeFailureKey = "auth.antigravity.cache.decode"
    private static let cacheWriteFailureKey = "auth.antigravity.cache.write"
    private static let cacheRemoveFailureKey = "auth.antigravity.cache.remove"
    /// Treat a token with less than this left as already expired (skip straight to refresh).
    static let refreshBuffer: TimeInterval = 60

    var keychain: KeychainAccessing
    var files: TextFileAccessing
    var now: @Sendable () -> Date
    /// Where T3 Code's private Antigravity instances keep their file-based OAuth credentials.
    /// Injected so tests can point at a fixture tree; the default discovers the real profiles.
    var fileCredentialPaths: @Sendable () -> [URL]

    init(
        keychain: KeychainAccessing = SecurityKeychainAccessor(),
        files: TextFileAccessing = LocalTextFileAccessor(),
        now: @escaping @Sendable () -> Date = Date.init,
        // Production reads no file credentials — T3's credentials belong to T3, not this app.
        // Tests that exercise the legacy loader inject their own paths explicitly.
        fileCredentialPaths: @escaping @Sendable () -> [URL] = { [] }
    ) {
        self.keychain = keychain
        self.files = files
        self.now = now
        self.fileCredentialPaths = fileCredentialPaths
    }

    /// Blocking keychain read — call off the main actor.
    /// Antigravity's credential is written by the Antigravity app / `agy` CLI, so its Keychain ACL does
    /// not trust QuotaBar until the user grants it. A *background* refresh can never grant that — it has
    /// no way to show a dialog — so the shared `KeychainPermissionGate` stops the repeated attempts and
    /// this turns the one definitive answer into copy that names the action that works.
    func loadKeychainToken() throws -> AntigravityKeychainToken? {
        let raw: String?
        do {
            raw = try keychain.readGenericPasswordForRefresh(
                service: Self.keychainService,
                account: Self.keychainAccount
            )
        } catch KeychainError.interactionNotAllowed {
            // The shared Keychain gate logs the first silent refusal. Later blocked refreshes must
            // stay quiet instead of repeating a provider-level line on every scheduler tick.
            throw AntigravityError.credentialPermissionRequired
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AntigravityError.credentialStoreUnreadable
        }
        guard let raw else { return nil }
        guard let token = Self.extractToken(fromKeychainRaw: raw) else {
            // Let the provider surface this typed failure once through WidgetDataStore's
            // persistent-failure logging. Logging here repeats on every scheduled retry.
            throw AntigravityError.invalidCredentialData
        }
        return token
    }

    /// Stable, non-secret account stamp for quota snapshots. Refresh credentials remain stable across
    /// access-token rotation; access-token-only records still get a conservative account fence.
    static func cacheIdentityKey(for token: AntigravityKeychainToken) -> String? {
        cacheIdentityKey(forRefreshToken: token.refreshToken)
            ?? cacheIdentityKey(forRefreshToken: token.accessToken)
    }

    /// Same account stamp for a file-based refresh credential (T3 Code's private instances).
    static func cacheIdentityKey(forRefreshToken refreshToken: String?) -> String? {
        guard let fingerprint = credentialFingerprint(for: refreshToken) else { return nil }
        let digest = fingerprint.map { String(format: "%02x", $0) }.joined()
        return "antigravity-\(digest)"
    }

    // MARK: - T3 Code file credentials

    /// Every usable T3 Code Antigravity credential, most recently active instance first. Silent and
    /// local-only: a missing or malformed file is that instance's absence, never an error here — the
    /// provider reports the outcome when no source can authenticate.
    func loadFileCredentials() -> [AntigravityFileCredential] {
        fileCredentialPaths().compactMap { loadFileCredential(atPath: $0.path) }
    }

    /// One `acp_token.json`. The refresh token is only ever sent to Google's OAuth endpoint: a file
    /// naming any other `token_uri` is refused at this boundary rather than trusted.
    func loadFileCredential(atPath path: String) -> AntigravityFileCredential? {
        guard let text = try? files.readTextIfPresent(path) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            DiagnosticGate.logOnce(for: "auth.antigravity.file.\(JSONLScanCachePaths.stableFingerprint(path))") {
                AppLog.warn(LogTag.auth("antigravity"), "T3 Code Antigravity credential is not readable JSON; skipping it")
            }
            return nil
        }
        guard let refresh = Self.firstString(object, ["refresh_token", "refreshToken"]),
              let clientID = Self.firstString(object, ["client_id", "clientId"]),
              let clientSecret = Self.firstString(object, ["client_secret", "clientSecret"]),
              (object["token_uri"] as? String) == AntigravityUsageClient.googleOAuthURL
        else { return nil }
        return AntigravityFileCredential(
            refreshToken: refresh,
            clientID: clientID,
            clientSecret: clientSecret,
            projectID: Self.firstString(object, ["project_id", "projectId"]),
            sourcePath: path
        )
    }

    /// Resolve the launch identity without ever presenting a Keychain prompt. If Antigravity's ACL
    /// blocks this background read, the stable unresolved marker fences previously attributed quota;
    /// the next live Cloud Code refresh can replace it with the credential fingerprint.
    func cacheIdentityKeyForLaunch() -> String {
        do {
            guard let raw = try keychain.readGenericPasswordForRefresh(
                service: Self.keychainService,
                account: Self.keychainAccount,
                allowInteraction: false
            ),
                  let token = Self.extractToken(fromKeychainRaw: raw),
                  let identity = Self.cacheIdentityKey(for: token)
            else { return Self.unresolvedCacheIdentityKey }
            return identity
        } catch {
            return Self.unresolvedCacheIdentityKey
        }
    }

    /// Whether a keychain access token is worth attempting: expiry unknown, or it hasn't passed yet.
    func isUsable(expiry: Date?) -> Bool {
        guard let expiry else { return true }
        return expiry.timeIntervalSince(now()) > Self.refreshBuffer
    }

    // MARK: - Refreshed-token cache

    private struct CachedToken: Codable {
        var accessToken: String
        var expiresAtMs: Double
        /// SHA-256 of the Keychain refresh credential that produced this derived access token. This is
        /// optional only so older unbound cache files decode as a safe miss during migration.
        var credentialFingerprint: Data?
    }

    func loadCachedToken(matching source: AntigravityKeychainToken) -> String? {
        guard let refreshToken = source.refreshToken else {
            discardCachedToken()
            return nil
        }
        return loadCachedToken(matchingRefreshToken: refreshToken)
    }

    /// The derived cache is bound to the refresh credential that produced it, whether that
    /// credential came from the Keychain or from a T3 Code instance's file.
    func loadCachedToken(matchingRefreshToken refreshToken: String) -> String? {
        guard let expectedFingerprint = Self.credentialFingerprint(for: refreshToken) else {
            discardCachedToken()
            return nil
        }
        // Require at least `refreshBuffer` of life left, matching `isUsable(expiry:)` for the keychain
        // token — a near-expiry cached token would otherwise yield a near-certain 401 and a wasteful
        // extra refresh.
        let text: String
        do {
            guard let stored = try files.readTextIfPresent(Self.cachePath) else {
                DiagnosticGate.clearFailure(Self.cacheReadFailureKey)
                DiagnosticGate.clearFailure(Self.cacheDecodeFailureKey)
                return nil
            }
            DiagnosticGate.clearFailure(Self.cacheReadFailureKey)
            text = stored
        } catch {
            DiagnosticGate.logOnce(for: Self.cacheReadFailureKey) {
                AppLog.warn(LogTag.auth("antigravity"), "refreshed-token cache read failed; ignoring it")
            }
            return nil
        }
        guard let cached = try? JSONDecoder().decode(CachedToken.self, from: Data(text.utf8)) else {
            DiagnosticGate.logOnce(for: Self.cacheDecodeFailureKey) {
                AppLog.warn(LogTag.auth("antigravity"), "refreshed-token cache is malformed; discarding it")
            }
            discardCachedToken()
            return nil
        }
        DiagnosticGate.clearFailure(Self.cacheDecodeFailureKey)
        guard cached.credentialFingerprint == expectedFingerprint,
              cached.expiresAtMs > (now().timeIntervalSince1970 + Self.refreshBuffer) * 1000,
              let token = cached.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        else {
            discardCachedToken()
            return nil
        }
        return token
    }

    @discardableResult
    func cacheToken(
        _ accessToken: String,
        expiresIn: Double,
        matching source: AntigravityKeychainToken
    ) throws -> Bool {
        try cacheToken(accessToken, expiresIn: expiresIn, matchingRefreshToken: source.refreshToken) {
            // OAuth runs off-thread and can outlive a logout/account switch. Re-read the Keychain
            // source in the same synchronous operation immediately before writing the derived cache.
            try ProviderRefreshContext.withCredentialSourceRevalidation {
                try self.loadKeychainToken()
            }?.refreshToken
        }
    }

    /// Cache a refreshed access token bound to a refresh credential, revalidating that the credential
    /// is still the live one before writing. `revalidate` returns the current refresh token for the
    /// source (Keychain or a T3 Code file); a mismatch discards the derived token instead of caching
    /// it against a login that changed mid-OAuth.
    @discardableResult
    func cacheToken(
        _ accessToken: String,
        expiresIn: Double,
        matchingRefreshToken refreshToken: String?,
        revalidate: () throws -> String?
    ) throws -> Bool {
        guard let credentialFingerprint = Self.credentialFingerprint(for: refreshToken),
              accessToken.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty != nil else {
            return false
        }

        let liveRefreshToken = try revalidate()
        guard Self.credentialFingerprint(for: liveRefreshToken) == credentialFingerprint else {
            AppLog.warn(LogTag.auth("antigravity"), "discarding refreshed token because the Antigravity login changed during OAuth")
            return false
        }
        let expiresAtMs = (now().timeIntervalSince1970 + expiresIn) * 1000
        let cached = CachedToken(
            accessToken: accessToken,
            expiresAtMs: expiresAtMs,
            credentialFingerprint: credentialFingerprint
        )
        do {
            let data = try JSONEncoder().encode(cached)
            try files.writeText(Self.cachePath, String(decoding: data, as: UTF8.self))
            DiagnosticGate.clearFailure(Self.cacheWriteFailureKey)
        } catch {
            // The refreshed token still works for this session; a failed cache only means we refresh
            // again next cycle. Log loudly rather than fail the live fetch.
            DiagnosticGate.logOnce(for: Self.cacheWriteFailureKey) {
                AppLog.warn(LogTag.auth("antigravity"), "failed to cache refreshed token: \(error.localizedDescription)")
            }
        }
        return true
    }

    /// Remove only QuotaBar's derived token; Antigravity's Keychain entry is never modified.
    func discardCachedToken() {
        do {
            try files.remove(Self.cachePath)
            DiagnosticGate.clearFailure(Self.cacheRemoveFailureKey)
        } catch {
            DiagnosticGate.logOnce(for: Self.cacheRemoveFailureKey) {
                AppLog.warn(LogTag.auth("antigravity"), "failed to remove stale refreshed-token cache")
            }
        }
    }

    private static func credentialFingerprint(for refreshToken: String?) -> Data? {
        guard let refreshToken = refreshToken?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty else {
            return nil
        }
        return Data(SHA256.hash(data: Data(refreshToken.utf8)))
    }

    // MARK: - Token extraction (pure)

    /// Decode the keychain value into tokens. Mirrors the `agy` format: an optional
    /// `go-keyring-base64:` wrapper around JSON `{ token: { access_token, refresh_token, expiry }, … }`,
    /// with fallbacks for a bare JSON string, a `Bearer …` value, or a raw token.
    static func extractToken(fromKeychainRaw raw: String) -> AntigravityKeychainToken? {
        let boundaryCharacters = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "\u{FEFF}"))
        let normalizedRaw = raw.trimmingCharacters(in: boundaryCharacters)
        guard let unwrapped = ProviderParse.unwrapGoKeyring(normalizedRaw),
              let text = unwrapped.trimmingCharacters(in: boundaryCharacters).nilIfEmpty
        else {
            return nil
        }

        if let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) {
            if let dict = json as? [String: Any] {
                return tokenFromObject(dict)
            }
            if let string = (json as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
                return AntigravityKeychainToken(accessToken: string, refreshToken: nil, expiry: nil)
            }
            return nil
        }

        // Broken structured material is never sent as a raw bearer token.
        if text.hasPrefix("{") || text.hasPrefix("[") {
            return nil
        }

        if text.hasPrefix("Bearer ") {
            let token = String(text.dropFirst("Bearer ".count)).trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            return token.map { AntigravityKeychainToken(accessToken: $0, refreshToken: nil, expiry: nil) }
        }
        return AntigravityKeychainToken(accessToken: text, refreshToken: nil, expiry: nil)
    }

    static func tokenFromObject(_ object: [String: Any]) -> AntigravityKeychainToken? {
        // Prefer a nested `token` object (the agy shape); otherwise read fields off the root.
        let source = (object["token"] as? [String: Any]) ?? object
        let access = firstString(source, ["access_token", "accessToken", "token", "id_token", "idToken", "bearerToken", "auth_token", "authToken"])
        let refresh = firstString(source, ["refresh_token", "refreshToken"])
        let expiry = firstString(source, ["expiry", "expires_at", "expiresAt"]).flatMap { OpenUsageISO8601.date(from: $0) }

        if access == nil, refresh == nil {
            for key in ["tokens", "oauth", "oauth2", "credentials", "auth"] {
                if let nested = object[key] as? [String: Any], let token = tokenFromObject(nested) {
                    return token
                }
            }
            return nil
        }
        return AntigravityKeychainToken(accessToken: access, refreshToken: refresh, expiry: expiry)
    }

    private static func firstString(_ object: [String: Any], _ keys: [String]) -> String? {
        for key in keys {
            if let value = (object[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
                return value
            }
        }
        return nil
    }
}
