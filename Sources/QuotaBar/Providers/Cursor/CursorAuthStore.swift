import CryptoKit
import Foundation

struct CursorAuthState: Hashable, Sendable {
    enum Source: Hashable, Sendable {
        case sqlite
        case keychain
    }

    var accessToken: String?
    var refreshToken: String?
    /// Lowercased `cursorAuth/stripeMembershipType` from the Cursor state DB when present. It is
    /// only carried on a SQLite-backed session: that row belongs to the SQLite token's account.
    var membershipType: String? = nil
    var source: Source
    /// True when a rotation-required refresh-token lookup completed successfully and found no token.
    /// This avoids repeating an absent-item lookup during the same proactive refresh.
    var refreshTokenReadForRotation = false
}

enum CursorAuthError: Error, LocalizedError, Equatable {
    case notLoggedIn
    /// The Keychain item exists but macOS will not release it without a dialog. Distinct from
    /// `notLoggedIn`: the user *is* signed in, and re-authenticating changes nothing.
    case credentialPermissionRequired
    case credentialsUnreadable
    case sessionExpired
    case tokenExpired

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "Not logged in. Sign in via Cursor app or run `agent login`."
        case .credentialPermissionRequired:
            return "macOS needs permission to read your Cursor Keychain item. Refresh to be asked once, then choose Always Allow."
        case .credentialsUnreadable:
            return "QuotaBar couldn't read Cursor's local credential data. Check access to Cursor's state database and login Keychain, then refresh again."
        case .sessionExpired:
            return "Session expired. Sign in via Cursor app or run `agent login`."
        case .tokenExpired:
            return "Token expired. Sign in via Cursor app or run `agent login`."
        }
    }
}

struct CursorAuthStore: Sendable {
    static let stateDBPath = "~/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
    static let accessTokenKey = "cursorAuth/accessToken"
    static let refreshTokenKey = "cursorAuth/refreshToken"
    static let membershipTypeKey = "cursorAuth/stripeMembershipType"
    static let keychainAccessTokenService = "cursor-access-token"
    static let keychainRefreshTokenService = "cursor-refresh-token"
    private static let stateDBReadFailureKey = "auth.cursor.stateDB.read"
    private static let optionalRefreshReadFailureKey = "auth.cursor.keychain.refresh.optional"
    static let refreshBufferSeconds: TimeInterval = 5 * 60

    var sqlite: SQLiteAccessing
    var keychain: KeychainAccessing
    var now: @Sendable () -> Date

    init(
        sqlite: SQLiteAccessing = SQLiteCLIAccessor(),
        keychain: KeychainAccessing = SecurityKeychainAccessor(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.sqlite = sqlite
        self.keychain = keychain
        self.now = now
    }

    /// Throws `credentialPermissionRequired` when a Keychain item exists but macOS refuses to release
    /// it, so the provider stops at "macOS needs permission" instead of reporting a signed-in user as
    /// "not logged in" — a remedy that cannot possibly help. A present state database that cannot be
    /// queried is likewise distinct from a missing database or a database with no auth rows.
    func loadAuthState(
        requireDeterminateKeychainSelection: Bool = false,
        forceKeychainRefreshTokenRead: Bool = false
    ) throws -> CursorAuthState? {
        var sqliteAccessToken: String?
        var sqliteRefreshToken: String?
        var sqliteMembershipType: String?
        var sqliteReadFailed = false
        do {
            sqliteAccessToken = try readStateValue(Self.accessTokenKey)
            sqliteRefreshToken = try readStateValue(Self.refreshTokenKey)
            sqliteMembershipType = try readStateValue(Self.membershipTypeKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            DiagnosticGate.clearFailure(Self.stateDBReadFailureKey)
        } catch {
            try ProviderCancellation.rethrowIfCancellation(error)
            // A readable database with no auth rows returns nil. A query/open failure means the
            // configured source is indeterminate, so preserve it for detection and try Keychain.
            sqliteReadFailed = true
            DiagnosticGate.logOnce(for: Self.stateDBReadFailureKey) {
                AppLog.error(LogTag.auth("cursor"), "state database credential read failed")
            }
        }

        let hasSQLiteAuth = sqliteAccessToken != nil || sqliteRefreshToken != nil
        let sqliteCanAuthenticate = sqliteRefreshToken != nil
            || (sqliteAccessToken != nil && !isExpired(sqliteAccessToken))
        let needsKeychainForAccountSelection = sqliteMembershipType == "free"
            && Self.tokenSubject(sqliteAccessToken) != nil

        // The Keychain is a *fallback* here, so it must not be able to fail a card that already has a
        // working sqlite credential.
        //
        // Reading it unconditionally was a real regression of my own: a user signed in via Cursor's
        // `state.vscdb`, whose `cursor-access-token` item existed but was ACL-blocked, got
        // `credentialPermissionRequired` thrown from here — so the whole store threw and the card showed
        // *no usage at all*, with a remedy for an item that has nothing to do with the token actually in
        // use. Granting it changed nothing, and because this ran on every background tick the card stayed
        // down for the whole session.
        //
        // So: when SQLite has a credential it can still use or refresh, a Keychain refusal degrades to
        // "no Keychain auth" and SQLite wins. If SQLite is expired and has no refresh token, the Keychain
        // permission is the only actionable credential path and must remain visible. The exception is a
        // free-account JWT whose subject must be compared with Keychain to choose between two stores: if
        // that identity read fails, using SQLite could publish usage for the wrong Cursor account.
        // A usable SQLite token otherwise skips optional Keychain reads.
        var keychainAccessToken: String?
        var keychainRefreshToken: String?
        var keychainRefreshTokenReadForRotation = false
        if !sqliteCanAuthenticate || needsKeychainForAccountSelection {
            do {
                keychainAccessToken = try readKeychainValue(Self.keychainAccessTokenService)
            } catch let error as CursorAuthError {
                guard hasSQLiteAuth, sqliteCanAuthenticate else { throw error }
                if needsKeychainForAccountSelection {
                    throw error
                }
                return CursorAuthState(
                    accessToken: sqliteAccessToken,
                    refreshToken: sqliteRefreshToken,
                    membershipType: sqliteMembershipType,
                    source: .sqlite
                )
            }

            let sqliteSubject = Self.tokenSubject(sqliteAccessToken)
            let keychainSubject = Self.tokenSubject(keychainAccessToken)
            let subjectsDiffer = sqliteSubject != nil
                && keychainSubject != nil
                && sqliteSubject != keychainSubject
            // The access token alone can serve usage requests until its rotation window opens.
            // Reading the optional refresh item here can trigger a Keychain permission prompt
            // during a manual refresh even though that credential is not needed yet.
            if !sqliteCanAuthenticate || subjectsDiffer {
                let rotationNeeded = forceKeychainRefreshTokenRead || needsRefresh(keychainAccessToken)
                keychainRefreshTokenReadForRotation = rotationNeeded
                do {
                    keychainRefreshToken = try readKeychainValue(
                        Self.keychainRefreshTokenService,
                        allowInteraction: rotationNeeded ? nil : false,
                        // A 401 can trigger this on every scheduled refresh. Honor the shared
                        // generic-read cooldown in the background; only an explicit manual action
                        // may force a fresh lookup after a known failure.
                        bypassDeferredReadFailure: forceKeychainRefreshTokenRead
                            && ProviderRefreshContext.isManual
                    )
                    DiagnosticGate.clearFailure(Self.optionalRefreshReadFailureKey)
                } catch let error as CancellationError {
                    throw error
                } catch {
                    // An access token can authenticate without the optional refresh item. During an
                    // ordinary probe, keep it available and defer the read error until rotation is
                    // actually required. A 401-driven forced rotation must surface that error now.
                    if forceKeychainRefreshTokenRead {
                        throw error
                    } else if let keychainAccessToken, !isExpired(keychainAccessToken) {
                        DiagnosticGate.logOnce(for: Self.optionalRefreshReadFailureKey) {
                            AppLog.debug(LogTag.auth("cursor"), "optional Keychain refresh token unavailable")
                        }
                    } else if hasSQLiteAuth && sqliteCanAuthenticate
                                && !subjectsDiffer
                                && !(requireDeterminateKeychainSelection && needsKeychainForAccountSelection) {
                        return CursorAuthState(
                            accessToken: sqliteAccessToken,
                            refreshToken: sqliteRefreshToken,
                            membershipType: sqliteMembershipType,
                            source: .sqlite
                        )
                    } else {
                        throw error
                    }
                }
            }
        }

        let hasKeychainAuth = keychainAccessToken != nil || keychainRefreshToken != nil

        // Cursor's Keychain copy is a fallback for users whose database cannot supply a token. If both
        // sources are genuinely empty, keep a database read error visible instead of calling it logged
        // out. A usable Keychain credential still allows the card to refresh normally.
        if sqliteReadFailed, !hasSQLiteAuth, !hasKeychainAuth {
            throw CursorAuthError.credentialsUnreadable
        }

        if hasSQLiteAuth {
            let sqliteSubject = Self.tokenSubject(sqliteAccessToken)
            let keychainSubject = Self.tokenSubject(keychainAccessToken)
            let subjectsDiffer = sqliteSubject != nil && keychainSubject != nil && sqliteSubject != keychainSubject
            if hasKeychainAuth, sqliteMembershipType == "free", subjectsDiffer {
                // SQLite looks like a free account for a different subject; do not carry that
                // membership onto the keychain session.
                return CursorAuthState(
                    accessToken: keychainAccessToken,
                    refreshToken: keychainRefreshToken,
                    membershipType: nil,
                    source: .keychain,
                    refreshTokenReadForRotation: keychainRefreshTokenReadForRotation
                )
            }

            return CursorAuthState(
                accessToken: sqliteAccessToken,
                refreshToken: sqliteRefreshToken,
                membershipType: sqliteMembershipType,
                source: .sqlite
            )
        }

        if hasKeychainAuth {
            // Keychain-only auth has no proven link to the state-DB membership row; leave it unset
            // rather than attaching another account's stripeMembershipType.
            return CursorAuthState(
                accessToken: keychainAccessToken,
                refreshToken: keychainRefreshToken,
                membershipType: nil,
                source: .keychain,
                refreshTokenReadForRotation: keychainRefreshTokenReadForRotation
            )
        }

        return nil
    }

    /// Resolve a deferred Keychain refresh token only after a request proves rotation is needed.
    /// Re-select the active source and compare its access token before pairing it with the refresh
    /// credential, so an account switch during the request cannot mix credential generations.
    func authStateForRefresh(
        _ expected: CursorAuthState,
        forceKeychainReload: Bool = false
    ) throws -> CursorAuthState? {
        guard expected.source == .keychain else { return expected }
        guard forceKeychainReload
                || (expected.refreshToken == nil && !expected.refreshTokenReadForRotation)
        else { return expected }
        let live = try loadAuthState(
            requireDeterminateKeychainSelection: true,
            forceKeychainRefreshTokenRead: true
        )
        guard let live,
              live.source == expected.source,
              live.accessToken == expected.accessToken,
              expected.refreshToken == nil || live.refreshToken == expected.refreshToken
        else {
            throw CursorAuthError.sessionExpired
        }
        return live
    }

    func needsRefresh(_ accessToken: String?) -> Bool {
        guard let accessToken,
              let expiresAt = Self.tokenExpiration(accessToken)
        else {
            return true
        }
        return expiresAt.timeIntervalSince(now()) <= Self.refreshBufferSeconds
    }

    func isExpired(_ accessToken: String?) -> Bool {
        guard let accessToken, let expiresAt = Self.tokenExpiration(accessToken) else { return false }
        return expiresAt <= now()
    }

    /// Store a rotated access token only if the exact credential generation used for the refresh is
    /// still present. This makes logout/account replacement win when a refresh response arrives late.
    func saveAccessToken(_ accessToken: String, replacing expected: CursorAuthState) throws {
        let live = try ProviderRefreshContext.withCredentialSourceRevalidation {
            try loadAuthState(
                requireDeterminateKeychainSelection: true,
                forceKeychainRefreshTokenRead: expected.source == .keychain && expected.refreshToken != nil
            )
        }
        guard let live,
              live.source == expected.source,
              live.accessToken == expected.accessToken,
              live.refreshToken == expected.refreshToken else {
            throw CursorAuthError.sessionExpired
        }

        switch expected.source {
        case .sqlite:
            try writeStateValue(Self.accessTokenKey, accessToken)
        case .keychain:
            try keychain.writeGenericPasswordForCurrentUser(service: Self.keychainAccessTokenService, value: accessToken)
        }
    }

    private func readStateValue(_ key: String) throws -> String? {
        let sql = "SELECT value FROM ItemTable WHERE key = '\(Self.sqlEscaped(key))' LIMIT 1;"
        guard let value = try sqlite.queryValue(path: Self.stateDBPath, sql: sql) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func writeStateValue(_ key: String, _ value: String) throws {
        let sql = """
        INSERT OR REPLACE INTO ItemTable (key, value) VALUES ('\(Self.sqlEscaped(key))', '\(Self.sqlEscaped(value))');
        """
        try sqlite.execute(path: Self.stateDBPath, sql: sql)
    }

    private func readKeychainValue(
        _ service: String,
        allowInteraction: Bool? = nil,
        bypassDeferredReadFailure: Bool = false
    ) throws -> String? {
        let value: String?
        do {
            // QuotaBar writes rotated tokens under the current-user account. Check that exact item
            // first, then retain compatibility with Cursor's older account-agnostic service entries.
            if let currentUserValue = try keychain.readGenericPasswordForRefreshForCurrentUser(
                service: service,
                allowInteraction: allowInteraction,
                bypassDeferredReadFailure: bypassDeferredReadFailure
            ) {
                value = currentUserValue
            } else {
                value = try keychain.readGenericPasswordForRefresh(
                    service: service,
                    allowInteraction: allowInteraction,
                    bypassDeferredReadFailure: bypassDeferredReadFailure
                )
            }
        } catch let error as CancellationError {
            throw error
        } catch KeychainError.interactionNotAllowed {
            // The shared Keychain gate logs the first silent refusal; a remembered block must not
            // emit another auth line on each automatic retry.
            throw CursorAuthError.credentialPermissionRequired
        } catch {
            throw CursorAuthError.credentialsUnreadable
        }
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    private static func tokenExpiration(_ token: String) -> Date? {
        guard let exp = ProviderParse.jwtPayload(token)?["exp"].flatMap(ProviderParse.number) else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    static func tokenSubject(_ token: String?) -> String? {
        guard let token,
              let subject = ProviderParse.jwtPayload(token)?["sub"] as? String
        else {
            return nil
        }
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Non-secret cache identity for Cursor spend history. At launch this reads only the local state
    /// database; it never reads Keychain, which would add another credential query before refresh.
    /// Free accounts can select a different Keychain token than the SQLite token, so that ambiguous
    /// case deliberately gets a per-launch identity and cannot reuse history from an unverified user.
    func cacheIdentityKeyForLaunch() -> String {
        let unresolvedIdentity = "cursor-unresolved-\(UUID().uuidString)"
        do {
            let membership = try readStateValue(Self.membershipTypeKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard membership != "free" else { return unresolvedIdentity }
            let accessToken = try readStateValue(Self.accessTokenKey)
            let refreshToken = try readStateValue(Self.refreshTokenKey)
            let sqliteCanAuthenticate = refreshToken != nil
                || (accessToken != nil && !isExpired(accessToken))
            guard sqliteCanAuthenticate,
                  let identityKey = Self.cacheIdentityKey(for: CursorAuthState(
                      accessToken: accessToken,
                      refreshToken: refreshToken,
                      source: .sqlite
                  ))
            else {
                return unresolvedIdentity
            }
            return identityKey
        } catch {
            return unresolvedIdentity
        }
    }

    static func cacheIdentityKey(for state: CursorAuthState) -> String? {
        if let subject = tokenSubject(state.accessToken) {
            return cacheIdentityKey(subject: subject)
        }
        let credential = state.refreshToken ?? state.accessToken
        guard let credential, !credential.isEmpty else { return nil }
        return cacheIdentityKey(credential: credential)
    }

    private static func cacheIdentityKey(subject: String) -> String {
        let digest = SHA256.hash(data: Data(subject.utf8))
        return "cursor-\(digest.map { String(format: "%02x", $0) }.joined())"
    }

    private static func cacheIdentityKey(credential: String) -> String {
        let digest = SHA256.hash(data: Data(credential.utf8))
        return "cursor-credential-\(digest.map { String(format: "%02x", $0) }.joined())"
    }

    private static func sqlEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }
}
