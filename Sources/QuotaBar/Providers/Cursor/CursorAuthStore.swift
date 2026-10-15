import Foundation

struct CursorAuthState: Hashable, Sendable {
    enum Source: Hashable, Sendable {
        case sqlite
        case keychain
    }

    var accessToken: String?
    var refreshToken: String?
    var source: Source
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
    func loadAuthState(requireDeterminateKeychainSelection: Bool = false) throws -> CursorAuthState? {
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
        } catch {
            try ProviderCancellation.rethrowIfCancellation(error)
            // A readable database with no auth rows returns nil. A query/open failure means the
            // configured source is indeterminate, so preserve it for detection and try Keychain.
            sqliteReadFailed = true
            AppLog.error(LogTag.auth("cursor"), "state database credential read failed")
        }

        let hasSQLiteAuth = sqliteAccessToken != nil || sqliteRefreshToken != nil
        let sqliteCanAuthenticate = sqliteRefreshToken != nil
            || (sqliteAccessToken != nil && !isExpired(sqliteAccessToken))

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
        // permission is the only actionable credential path and must remain visible.
        var keychainAccessToken: String?
        var keychainRefreshToken: String?
        do {
            keychainAccessToken = try readKeychainValue(Self.keychainAccessTokenService)
            keychainRefreshToken = try readKeychainValue(Self.keychainRefreshTokenService)
        } catch let error as CursorAuthError {
            guard hasSQLiteAuth, sqliteCanAuthenticate else { throw error }
            if requireDeterminateKeychainSelection,
               sqliteMembershipType == "free",
               Self.tokenSubject(sqliteAccessToken) != nil {
                throw error
            }
            return CursorAuthState(
                accessToken: sqliteAccessToken,
                refreshToken: sqliteRefreshToken,
                source: .sqlite
            )
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
                return CursorAuthState(
                    accessToken: keychainAccessToken,
                    refreshToken: keychainRefreshToken,
                    source: .keychain
                )
            }

            return CursorAuthState(
                accessToken: sqliteAccessToken,
                refreshToken: sqliteRefreshToken,
                source: .sqlite
            )
        }

        if hasKeychainAuth {
            return CursorAuthState(
                accessToken: keychainAccessToken,
                refreshToken: keychainRefreshToken,
                source: .keychain
            )
        }

        return nil
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
            try loadAuthState(requireDeterminateKeychainSelection: true)
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

    private func readKeychainValue(_ service: String) throws -> String? {
        let value: String?
        do {
            // QuotaBar writes rotated tokens under the current-user account. Check that exact item
            // first, then retain compatibility with Cursor's older account-agnostic service entries.
            if let currentUserValue = try keychain.readGenericPasswordForRefreshForCurrentUser(service: service) {
                value = currentUserValue
            } else {
                value = try keychain.readGenericPasswordForRefresh(service: service)
            }
        } catch let error as CancellationError {
            throw error
        } catch KeychainError.interactionNotAllowed {
            // The shared Keychain gate logs the first silent refusal; a remembered block must not
            // emit another auth line on each automatic retry.
            throw CursorAuthError.credentialPermissionRequired
        } catch {
            AppLog.error(LogTag.auth("cursor"), "keychain credential read failed")
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

    private static func sqlEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }
}
