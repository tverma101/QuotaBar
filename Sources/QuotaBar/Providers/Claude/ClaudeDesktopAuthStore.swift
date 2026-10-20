import CommonCrypto
import CryptoKit
import Foundation
import LocalAuthentication
import Security

enum ClaudeDesktopCredentialStatus: Sendable, Equatable {
    case notChecked
    case notFound
    case permissionRequired
    case unreadable
    case stale
    case invalid
    case available
}

enum ClaudeDesktopCredentialMaterialStatus: Sendable, Equatable {
    case absent
    case available
    case unreadable
}

struct ClaudeDesktopCredentialResult: Sendable {
    var oauth: ClaudeOAuth?
    var status: ClaudeDesktopCredentialStatus
    var organization: String? = nil
}

struct ClaudeDesktopOrganizationLoad: Sendable {
    var activeOrganization: String?
    var credentialsByOrganization: [String: ClaudeDesktopCredentialResult]
}

protocol ClaudeDesktopSafeStorageKeyReading: Sendable {
    func readPassword(allowInteraction: Bool) throws -> String?
    func readPassword(
        allowInteraction: Bool,
        interactiveQueryLease: KeychainInteractiveQueryLease?
    ) throws -> String?
}

extension ClaudeDesktopSafeStorageKeyReading {
    func readPassword(
        allowInteraction: Bool,
        interactiveQueryLease: KeychainInteractiveQueryLease?
    ) throws -> String? {
        if allowInteraction, let interactiveQueryLease,
           !interactiveQueryLease.markQueryStarted() {
            throw CancellationError()
        }
        return try readPassword(allowInteraction: allowInteraction)
    }
}

struct ClaudeDesktopSafeStorageKeyReader: ClaudeDesktopSafeStorageKeyReading {
    static let service = "Claude Safe Storage"
    static let account = "Claude Key"

    func readPassword(allowInteraction: Bool) throws -> String? {
        try readPassword(allowInteraction: allowInteraction, interactiveQueryLease: nil)
    }

    func readPassword(
        allowInteraction: Bool,
        interactiveQueryLease: KeychainInteractiveQueryLease?
    ) throws -> String? {
        let itemKey = KeychainItemKey(service: Self.service, account: Self.account)
        let missingItems = KeychainMissingItemCache.shared
        if missingItems.shouldSkipRead(
            for: itemKey,
            manualActionID: ProviderRefreshContext.manualActionID,
            allowsInteraction: allowInteraction
        ) {
            return nil
        }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]
        let authenticationContext = try KeychainAuthenticationContextLease(
            interactionAllowed: allowInteraction,
            interactiveQueryLease: interactiveQueryLease
        )
        query[kSecUseAuthenticationContext as String] = authenticationContext.context

        guard authenticationContext.mayBeginQuery else {
            _ = authenticationContext.finish()
            throw CancellationError()
        }
        if allowInteraction, let interactiveQueryLease,
           !interactiveQueryLease.markQueryStarted() {
            _ = authenticationContext.finish()
            throw CancellationError()
        }
        var result: CFTypeRef?
        let status = KeychainUserInteraction.shared.perform(allowInteraction: allowInteraction) {
            guard authenticationContext.mayBeginQuery else { return errSecUserCanceled }
            return SecItemCopyMatching(query as CFDictionary, &result)
        }
        guard authenticationContext.finish() else { throw CancellationError() }
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let password = String(data: data, encoding: .utf8),
                  !password.isEmpty
            else {
                throw ClaudeDesktopCredentialError.invalidSafeStorageKey
            }
            missingItems.markPresent(itemKey)
            return password
        case errSecItemNotFound:
            missingItems.markMissing(for: itemKey)
            return nil
        case errSecInteractionNotAllowed, errSecInteractionRequired, errSecAuthFailed, errSecUserCanceled:
            throw ClaudeDesktopCredentialError.permissionRequired
        default:
            if KeychainPermissionGate.shared.shouldLogReadFailure(
                for: itemKey,
                status: OSStatus(status)
            ) {
                AppLog.warn(.keychain, "Claude Desktop Safe Storage read failed (Security.framework OSStatus \(status))")
            }
            throw ClaudeDesktopCredentialError.keychainFailure(Int(status))
        }
    }
}

enum ClaudeDesktopCredentialError: Error, Sendable {
    case permissionRequired
    case invalidSafeStorageKey
    case keychainFailure(Int)
    case keychainReadDeferred
    case invalidCiphertext
    case decryptionFailed(Int32)
}

struct ClaudeDesktopCredentialsUnreadableError: Error, LocalizedError, CategorizedError {
    var errorDescription: String? {
        "QuotaBar found Claude Desktop login data but couldn't read its config or Cookies database. Check file access, then refresh again."
    }

    var errorCategory: ErrorCategory { .credentialAccess }
}

/// Reads Claude Desktop's Electron OAuth cache as an externally owned, read-only credential source.
///
/// The refresh token is deliberately never decoded into `ClaudeOAuth`: Anthropic rotates refresh
/// tokens, so using one here would invalidate Claude Desktop's copy. QuotaBar only borrows a currently
/// valid access token and waits for Desktop to renew it.
struct ClaudeDesktopAuthStore: Sendable {
    private static let readFailurePrefix = "auth.claude.desktop.read."
    private static let configRelativePath = "Library/Application Support/Claude/config.json"
    private static let cookieRelativePaths = [
        "Library/Application Support/Claude/Cookies",
        "Library/Application Support/Claude/Network/Cookies"
    ]
    private static let cacheV1Key = "oauth:tokenCache"
    private static let cacheV2Key = "oauth:tokenCacheV2"
    private static let cookieHosts = [".claude.ai", "claude.ai"]

    private struct DesktopCacheContext {
        var activeOrganization: String
        var v2: [String: Any]?
        var v1: [String: Any]?
    }

    private enum DesktopCacheContextResult {
        case noKey
        case invalid
        case loaded(DesktopCacheContext)
    }

    var files: TextFileAccessing
    var sqlite: SQLiteAccessing
    var keyReader: ClaudeDesktopSafeStorageKeyReading
    var homeDirectory: @Sendable () -> URL
    var now: @Sendable () -> Date
    let keyCache: SafeStorageKeyCache

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        sqlite: SQLiteAccessing = SQLiteCLIAccessor(),
        keyReader: ClaudeDesktopSafeStorageKeyReading = ClaudeDesktopSafeStorageKeyReader(),
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser },
        now: @escaping @Sendable () -> Date = Date.init,
        keyCache: SafeStorageKeyCache = SafeStorageKeyCache()
    ) {
        self.files = files
        self.sqlite = sqlite
        self.keyReader = keyReader
        self.homeDirectory = homeDirectory
        self.now = now
        self.keyCache = keyCache
    }

    /// Cheap, prompt-free evidence that local Claude Desktop credential material exists. The real
    /// refresh still decrypts and validates it.
    func hasCredentialMaterial() -> Bool {
        credentialMaterialStatus() != .absent
    }

    /// Distinguish a missing Desktop login from configured material QuotaBar couldn't inspect. This
    /// probes only the config file and cookie SQLite metadata; it never touches the Keychain.
    func credentialMaterialStatus() -> ClaudeDesktopCredentialMaterialStatus {
        let configPath = path(Self.configRelativePath)
        let text: String?
        do {
            text = try files.readTextIfPresent(configPath)
        } catch {
            return .unreadable
        }
        guard let text,
              let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root[Self.cacheV2Key] is String || root[Self.cacheV1Key] is String
        else { return .absent }

        let sql = "SELECT 1 FROM cookies WHERE name = 'lastActiveOrg' AND host_key IN ('.claude.ai', 'claude.ai') LIMIT 1"
        var sawUnreadableDatabase = false
        for relativePath in Self.cookieRelativePaths {
            let databasePath = path(relativePath)
            guard files.exists(databasePath) else { continue }
            do {
                if try sqlite.queryValue(path: databasePath, sql: sql) != nil { return .available }
            } catch {
                sawUnreadableDatabase = true
            }
        }
        return sawUnreadableDatabase ? .unreadable : .absent
    }

    func lastKnownAccountUUID() -> String? {
        guard let text = try? files.readTextIfPresent(path(Self.configRelativePath)),
              let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let user = root["lastKnownAccountUuid"] as? String,
              UUID(uuidString: user) != nil
        else { return nil }
        return user.lowercased()
    }

    func load(
        allowInteraction: Bool,
        interactionGate: CredentialInteractionGate? = nil,
        organization: String? = nil,
        expectedAccountUUID: String? = nil
    ) -> ClaudeDesktopCredentialResult {
        let materialStatus = credentialMaterialStatus()
        if materialStatus == .unreadable {
            return ClaudeDesktopCredentialResult(oauth: nil, status: .unreadable)
        }
        let capturedAccountUUID = lastKnownAccountUUID()
        if let expectedAccountUUID,
           capturedAccountUUID?.caseInsensitiveCompare(expectedAccountUUID) != .orderedSame
        {
            return ClaudeDesktopCredentialResult(oauth: nil, status: .notFound)
        }
        guard materialStatus == .available else {
            return ClaudeDesktopCredentialResult(oauth: nil, status: .notFound)
        }

        do {
            let context: DesktopCacheContext
            switch try loadDesktopCacheContext(
                allowInteraction: allowInteraction,
                interactionGate: interactionGate
            ) {
            case .noKey:
                return ClaudeDesktopCredentialResult(oauth: nil, status: .notFound)
            case .invalid:
                return ClaudeDesktopCredentialResult(oauth: nil, status: .invalid)
            case .loaded(let loaded):
                context = loaded
            }
            let currentAccountUUID = lastKnownAccountUUID()
            guard Self.accountUUIDsMatch(capturedAccountUUID, currentAccountUUID),
                  expectedAccountUUID.map({ currentAccountUUID?.caseInsensitiveCompare($0) == .orderedSame }) ?? true
            else {
                return ClaudeDesktopCredentialResult(oauth: nil, status: .notFound)
            }
            Self.clearReadFailureDiagnostics(expectedAccountUUID: expectedAccountUUID ?? currentAccountUUID)

            let targetOrganization = organization?.lowercased() ?? context.activeOrganization
            let selection = Self.selectCredential(
                activeOrganization: targetOrganization,
                activeAccountUUID: currentAccountUUID,
                v2: context.v2,
                v1: context.v1,
                now: now()
            )
            switch selection {
            case .available(let oauth):
                return ClaudeDesktopCredentialResult(
                    oauth: oauth, status: .available, organization: targetOrganization
                )
            case .stale:
                return ClaudeDesktopCredentialResult(oauth: nil, status: .stale)
            case .notFound:
                return ClaudeDesktopCredentialResult(oauth: nil, status: .notFound)
            case .invalid:
                return ClaudeDesktopCredentialResult(oauth: nil, status: .invalid)
            }
        } catch ClaudeDesktopCredentialError.permissionRequired {
            return ClaudeDesktopCredentialResult(oauth: nil, status: .permissionRequired)
        } catch ClaudeDesktopCredentialError.keychainFailure {
            // The Safe Storage reader emitted a per-item/status diagnostic. Keep returning the same
            // typed failure without another provider-level line on every refresh.
            return ClaudeDesktopCredentialResult(oauth: nil, status: .invalid)
        } catch ClaudeDesktopCredentialError.keychainReadDeferred {
            return ClaudeDesktopCredentialResult(oauth: nil, status: .invalid)
        } catch is CancellationError {
            // Provider refresh checks cancellation after the off-actor load returns. Avoid turning a
            // canceled Keychain read into a Desktop error or a credential-read log entry.
            return ClaudeDesktopCredentialResult(oauth: nil, status: .notChecked)
        } catch {
            Self.logReadFailureOnce(error, expectedAccountUUID: expectedAccountUUID ?? capturedAccountUUID)
            return ClaudeDesktopCredentialResult(oauth: nil, status: .invalid)
        }
    }

    /// Resolve several organizations from one read of the shared Desktop credential context. Launch
    /// discovery used to call `load()` once per org, repeating config parsing, cookie SQLite queries,
    /// Safe Storage work, and cache decryption for every candidate. These organizations all live in
    /// the same Desktop cache, so prepare it once and select each org from the in-memory result.
    func loadOrganizations(
        _ organizations: Set<String>,
        allowInteraction: Bool,
        expectedAccountUUID: String? = nil
    ) -> ClaudeDesktopOrganizationLoad {
        let requested = Set(organizations.map { $0.lowercased() })
        func failures(
            _ status: ClaudeDesktopCredentialStatus,
            activeOrganization: String? = nil
        ) -> ClaudeDesktopOrganizationLoad {
            var results = Dictionary(uniqueKeysWithValues: requested.map {
                ($0, ClaudeDesktopCredentialResult(oauth: nil, status: status, organization: $0))
            })
            if let activeOrganization, results[activeOrganization] == nil {
                results[activeOrganization] = ClaudeDesktopCredentialResult(
                    oauth: nil, status: status, organization: activeOrganization
                )
            }
            return ClaudeDesktopOrganizationLoad(
                activeOrganization: activeOrganization,
                credentialsByOrganization: results
            )
        }

        let materialStatus = credentialMaterialStatus()
        if materialStatus == .unreadable { return failures(.unreadable) }
        let accountUUID = lastKnownAccountUUID()
        if let expectedAccountUUID,
           accountUUID?.caseInsensitiveCompare(expectedAccountUUID) != .orderedSame
        {
            return failures(.notFound)
        }
        guard materialStatus == .available else { return failures(.notFound) }

        do {
            let context: DesktopCacheContext
            switch try loadDesktopCacheContext(
                allowInteraction: allowInteraction,
                interactionGate: nil
            ) {
            case .noKey:
                return failures(.notFound)
            case .invalid:
                return failures(.invalid)
            case .loaded(let loaded):
                context = loaded
            }
            let activeOrganization = context.activeOrganization

            // Loading the shared Keychain/cache context may outlive a switch to another Claude Desktop
            // account. Never publish credentials selected with an identity that stopped being current
            // while the batch was in progress.
            let currentAccountUUID = lastKnownAccountUUID()
            let accountChanged: Bool
            switch (accountUUID, currentAccountUUID) {
            case (nil, nil):
                accountChanged = false
            case let (captured?, current?):
                accountChanged = captured.caseInsensitiveCompare(current) != .orderedSame
            default:
                accountChanged = true
            }
            let expectedAccountChanged = expectedAccountUUID.map {
                currentAccountUUID?.caseInsensitiveCompare($0) != .orderedSame
            } ?? false
            if accountChanged || expectedAccountChanged {
                return failures(.notFound, activeOrganization: activeOrganization)
            }
            Self.clearReadFailureDiagnostics(expectedAccountUUID: expectedAccountUUID ?? currentAccountUUID)

            let targets = requested.union([activeOrganization])
            var results: [String: ClaudeDesktopCredentialResult] = [:]
            for organization in targets {
                let selection = Self.selectCredential(
                    activeOrganization: organization,
                    activeAccountUUID: currentAccountUUID,
                    v2: context.v2,
                    v1: context.v1,
                    now: now()
                )
                switch selection {
                case .available(let oauth):
                    results[organization] = ClaudeDesktopCredentialResult(
                        oauth: oauth, status: .available, organization: organization
                    )
                case .stale:
                    results[organization] = ClaudeDesktopCredentialResult(
                        oauth: nil, status: .stale, organization: organization
                    )
                case .notFound:
                    results[organization] = ClaudeDesktopCredentialResult(
                        oauth: nil, status: .notFound, organization: organization
                    )
                case .invalid:
                    results[organization] = ClaudeDesktopCredentialResult(
                        oauth: nil, status: .invalid, organization: organization
                    )
                }
            }
            return ClaudeDesktopOrganizationLoad(
                activeOrganization: activeOrganization,
                credentialsByOrganization: results
            )
        } catch ClaudeDesktopCredentialError.permissionRequired {
            return failures(.permissionRequired)
        } catch ClaudeDesktopCredentialError.keychainFailure {
            return failures(.invalid)
        } catch ClaudeDesktopCredentialError.keychainReadDeferred {
            return failures(.invalid)
        } catch is CancellationError {
            return failures(.notChecked)
        } catch {
            Self.logReadFailureOnce(error, expectedAccountUUID: expectedAccountUUID ?? accountUUID)
            return failures(.invalid)
        }
    }

    private static func readFailureDiagnosticScope(expectedAccountUUID: String?) -> String {
        let identity = expectedAccountUUID?.lowercased() ?? "unscoped"
        return readFailurePrefix + JSONLScanCachePaths.stableFingerprint(identity) + "."
    }

    private static func accountUUIDsMatch(_ lhs: String?, _ rhs: String?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (left?, right?): return left.caseInsensitiveCompare(right) == .orderedSame
        default: return false
        }
    }

    private static func clearReadFailureDiagnostics(expectedAccountUUID: String?) {
        DiagnosticGate.clearFailures(prefix: readFailureDiagnosticScope(expectedAccountUUID: expectedAccountUUID))
    }

    private static func logReadFailureOnce(_ error: Error, expectedAccountUUID: String?) {
        let key = readFailureDiagnosticScope(expectedAccountUUID: expectedAccountUUID)
            + String(reflecting: type(of: error))
        DiagnosticGate.logOnce(for: key) {
            AppLog.error(LogTag.auth("claude"), "Claude Desktop credential read failed: \(error.localizedDescription)")
        }
    }

    private func loadDesktopCacheContext(
        allowInteraction: Bool,
        interactionGate: CredentialInteractionGate?
    ) throws -> DesktopCacheContextResult {
        guard let key = try safeStorageKey(
            allowInteraction: allowInteraction,
            interactionGate: interactionGate
        ) else { return .noKey }

        func read(using keyData: Data) throws -> DesktopCacheContext? {
            guard let activeOrganization = try loadActiveOrganization(key: keyData),
                  let caches = try loadCaches(key: keyData)
            else { return nil }
            return DesktopCacheContext(
                activeOrganization: activeOrganization,
                v2: caches.v2,
                v1: caches.v1
            )
        }

        do {
            guard let context = try read(using: key.data) else {
                return .invalid
            }
            return .loaded(context)
        } catch {
            guard Self.isSafeStorageDecryptionMismatch(error) else { throw error }
            keyCache.invalidateAfterDecryptionFailure(key)
            guard let replacement = try safeStorageKey(
                allowInteraction: allowInteraction,
                interactionGate: interactionGate
            ), replacement.generation != key.generation else {
                throw error
            }
            guard let context = try read(using: replacement.data) else { return .invalid }
            return .loaded(context)
        }
    }

    private static func isSafeStorageDecryptionMismatch(_ error: Error) -> Bool {
        guard let error = error as? ClaudeDesktopCredentialError else { return false }
        switch error {
        case .invalidCiphertext, .decryptionFailed:
            return true
        case .permissionRequired, .invalidSafeStorageKey, .keychainFailure,
             .keychainReadDeferred:
            return false
        }
    }

    private func safeStorageKey(
        allowInteraction: Bool,
        interactionGate: CredentialInteractionGate?
    ) throws -> SafeStorageKeyCache.CachedValue? {
        try Task.checkCancellation()
        keyCache.permitReloadAfterFailedDecrypt(
            manualActionID: ProviderRefreshContext.manualActionID,
            allowsInteraction: allowInteraction
        )
        let itemKey = KeychainItemKey(
            service: ClaudeDesktopSafeStorageKeyReader.service,
            account: ClaudeDesktopSafeStorageKeyReader.account
        )
        let permissionGate = KeychainPermissionGate.shared
        let manualActionID = ProviderRefreshContext.manualActionID
        let key = try keyCache.getOrLoadVersioned({
            let observedGeneration = permissionGate.generation(for: itemKey)
            do {
                try Task.checkCancellation()
                guard !ProviderRefreshContext.credentialReadIsCancelled else {
                    throw CancellationError()
                }
                guard !permissionGate.isDeclined(itemKey) else {
                    throw ClaudeDesktopCredentialError.permissionRequired
                }
                if permissionGate.shouldDeferFailedRead(
                    for: itemKey,
                    manualActionID: manualActionID
                )
                {
                    throw ClaudeDesktopCredentialError.keychainReadDeferred
                }
                if permissionGate.isBlocked(itemKey), !allowInteraction {
                    throw ClaudeDesktopCredentialError.permissionRequired
                }
                func retrySilently(after generation: UInt64) throws -> String? {
                    do {
                        let value = try keyReader.readPassword(allowInteraction: false)
                        guard !ProviderRefreshContext.credentialReadIsCancelled,
                              permissionGate.isCurrentManualAction(manualActionID)
                        else { throw CancellationError() }
                        permissionGate.reset(
                            itemKey,
                            ifGenerationIs: generation,
                            manualActionID: manualActionID
                        )
                        return value
                    } catch ClaudeDesktopCredentialError.permissionRequired {
                        guard !ProviderRefreshContext.credentialReadIsCancelled,
                              permissionGate.isCurrentManualAction(manualActionID)
                        else { throw CancellationError() }
                        permissionGate.block(
                            itemKey,
                            ifGenerationIs: generation,
                            manualActionID: manualActionID
                        )
                        throw ClaudeDesktopCredentialError.permissionRequired
                    } catch ClaudeDesktopCredentialError.invalidSafeStorageKey {
                        guard !ProviderRefreshContext.credentialReadIsCancelled,
                              permissionGate.isCurrentManualAction(manualActionID)
                        else { throw CancellationError() }
                        if let recoveredGeneration = permissionGate.reset(
                            itemKey,
                            ifGenerationIs: generation,
                            manualActionID: manualActionID
                        ) {
                            permissionGate.deferFailedRead(
                                for: itemKey,
                                ifGenerationIs: recoveredGeneration,
                                manualActionID: manualActionID
                            )
                        }
                        throw ClaudeDesktopCredentialError.invalidSafeStorageKey
                    }
                }
                // A Safe Storage prompt for this same item is already on screen. A silent probe now
                // can only fail and would spend another Security read on a result that is already
                // arriving, so wait for that prompt and derive the key from its grant instead.
                if let granted = permissionGate.waitForInFlightSameItemInteractiveQuery(
                    matching: itemKey,
                    manualActionID: manualActionID
                ) {
                    try Task.checkCancellation()
                    guard !ProviderRefreshContext.credentialReadIsCancelled,
                          permissionGate.isCurrentManualAction(manualActionID)
                    else { throw CancellationError() }
                    guard granted else { throw ClaudeDesktopCredentialError.permissionRequired }
                    let retried = try retrySilently(after: permissionGate.generation(for: itemKey))
                    guard let password = retried else { return nil }
                    return try Self.deriveKey(password: password)
                }
                var password: String?
                do {
                    password = try keyReader.readPassword(allowInteraction: false)
                    guard !ProviderRefreshContext.credentialReadIsCancelled else {
                        throw CancellationError()
                    }
                    guard permissionGate.isCurrentManualAction(manualActionID) else {
                        throw CancellationError()
                    }
                    permissionGate.reset(
                        itemKey,
                        ifGenerationIs: observedGeneration,
                        manualActionID: manualActionID
                    )
                } catch ClaudeDesktopCredentialError.permissionRequired {
                    permissionGate.block(
                        itemKey,
                        ifGenerationIs: observedGeneration,
                        manualActionID: manualActionID
                    )
                    guard !ProviderRefreshContext.credentialReadIsCancelled else {
                        throw CancellationError()
                    }
                    if allowInteraction,
                       permissionGate.hasSuccessfulInteractiveGrant(for: itemKey, manualActionID: manualActionID) {
                        permissionGate.deferFailedRead(
                            for: itemKey,
                            ifGenerationIs: observedGeneration,
                            manualActionID: manualActionID
                        )
                        password = try retrySilently(after: permissionGate.generation(for: itemKey))
                        guard let password else { return nil }
                        return try Self.deriveKey(password: password)
                    }
                    try Task.checkCancellation()
                    guard allowInteraction, !permissionGate.isDeclined(itemKey) else {
                        throw ClaudeDesktopCredentialError.permissionRequired
                    }
                    let interactiveQueryClaim = permissionGate.claimInteractiveQueryResult(
                        for: manualActionID,
                        using: interactionGate,
                        key: itemKey
                    )
                    let interactiveQueryLease: KeychainInteractiveQueryLease
                    switch interactiveQueryClaim {
                    case .claimed(let lease):
                        interactiveQueryLease = lease
                    case .actionSuperseded:
                        throw CancellationError()
                    case .queryInFlight(let activeLease, let sameItem):
                        // Another card may already be granting this same Safe Storage item. Wait for
                        // that one prompt to finish, then retry this read silently if it cleared the
                        // item's block; never open a second prompt for the sibling.
                        guard sameItem, permissionGate.waitForSuccessfulInteractiveQuery(
                            activeLease,
                            matching: itemKey,
                            manualActionID: manualActionID
                        ) else {
                            guard !ProviderRefreshContext.credentialReadIsCancelled,
                                  permissionGate.isCurrentManualAction(manualActionID)
                            else { throw CancellationError() }
                            throw ClaudeDesktopCredentialError.permissionRequired
                        }
                        guard !ProviderRefreshContext.credentialReadIsCancelled,
                              permissionGate.isCurrentManualAction(manualActionID)
                        else { throw CancellationError() }
                        try Task.checkCancellation()
                        password = try retrySilently(after: permissionGate.generation(for: itemKey))
                        guard let password else { return nil }
                        return try Self.deriveKey(password: password)
                    case .actionBudgetSpent:
                        if permissionGate.hasSuccessfulInteractiveGrant(for: itemKey, manualActionID: manualActionID)
                            || permissionGate.wasSuccessfullyUnblocked(
                                itemKey,
                                since: observedGeneration,
                                manualActionID: manualActionID
                            ) {
                            permissionGate.reset(
                                itemKey,
                                ifGenerationIs: observedGeneration,
                                manualActionID: manualActionID
                            )
                            password = try retrySilently(after: permissionGate.generation(for: itemKey))
                            guard let password else { return nil }
                            return try Self.deriveKey(password: password)
                        }
                        // The action's one-prompt budget was used elsewhere (or another Security query
                        // already declined this item). Do not let sibling cards repeat the same silent
                        // Safe Storage read after this action has failed to obtain the item.
                        permissionGate.markDeclined(itemKey, ifGenerationIs: observedGeneration)
                        throw ClaudeDesktopCredentialError.permissionRequired
                    }
                    // Keep the shared slot until this synchronous Keychain read returns. A newer action
                    // invalidates the context, but cannot safely assume Security has stopped using it.
                    defer { permissionGate.finishInteractiveQuery(interactiveQueryLease) }
                    guard !ProviderRefreshContext.credentialReadIsCancelled else {
                        throw CancellationError()
                    }
                    guard permissionGate.isCurrentManualAction(manualActionID) else {
                        throw CancellationError()
                    }
                    do {
                        password = try keyReader.readPassword(
                            allowInteraction: true,
                            interactiveQueryLease: interactiveQueryLease
                        )
                        guard !ProviderRefreshContext.credentialReadIsCancelled else {
                            throw CancellationError()
                        }
                        guard permissionGate.isCurrentManualAction(manualActionID) else {
                            throw CancellationError()
                        }
                        guard permissionGate.markInteractiveQuerySucceeded(interactiveQueryLease) else {
                            throw CancellationError()
                        }
                        permissionGate.reset(
                            itemKey,
                            ifGenerationIs: observedGeneration,
                            manualActionID: manualActionID
                        )
                    } catch ClaudeDesktopCredentialError.invalidSafeStorageKey {
                        guard !ProviderRefreshContext.credentialReadIsCancelled,
                              permissionGate.isCurrentManualAction(manualActionID)
                        else { throw CancellationError() }
                        // Security released the item, but its payload was not a usable key. Complete
                        // the interaction and clear the old ACL block before surfacing this error.
                        guard permissionGate.markInteractiveQuerySucceeded(interactiveQueryLease) else {
                            throw CancellationError()
                        }
                        if let recoveredGeneration = permissionGate.reset(
                            itemKey,
                            ifGenerationIs: observedGeneration,
                            manualActionID: manualActionID
                        ) {
                            permissionGate.deferFailedRead(
                                for: itemKey,
                                ifGenerationIs: recoveredGeneration,
                                manualActionID: manualActionID
                            )
                        }
                        throw ClaudeDesktopCredentialError.invalidSafeStorageKey
                    } catch ClaudeDesktopCredentialError.permissionRequired {
                        guard !ProviderRefreshContext.credentialReadIsCancelled else {
                            throw CancellationError()
                        }
                        guard permissionGate.isCurrentManualAction(manualActionID) else {
                            throw CancellationError()
                        }
                        permissionGate.markDeclined(itemKey, ifGenerationIs: observedGeneration)
                        throw ClaudeDesktopCredentialError.permissionRequired
                    }
                }
                guard let password else {
                    return nil
                }
                return try Self.deriveKey(password: password)
            } catch {
                // A stale leader's non-permission Security or derivation failure belongs only to
                // that action. Publish cancellation so a newer cache waiter can perform its own read.
                guard !Task.isCancelled,
                      !ProviderRefreshContext.credentialReadIsCancelled,
                      permissionGate.isCurrentManualAction(manualActionID)
                else { throw CancellationError() }
                if let credentialError = error as? ClaudeDesktopCredentialError,
                   case .invalidSafeStorageKey = credentialError {
                    if let recoveredGeneration = permissionGate.reset(
                        itemKey,
                        ifGenerationIs: observedGeneration,
                        manualActionID: manualActionID
                    ) {
                        permissionGate.deferFailedRead(
                            for: itemKey,
                            ifGenerationIs: recoveredGeneration,
                            manualActionID: manualActionID
                        )
                    }
                } else if let credentialError = error as? ClaudeDesktopCredentialError,
                          case .keychainFailure = credentialError {
                    permissionGate.deferFailedRead(
                        for: itemKey,
                        ifGenerationIs: observedGeneration,
                        manualActionID: manualActionID
                    )
                }
                throw error
            }
        }, isCurrent: {
            !ProviderRefreshContext.credentialReadIsCancelled
                && permissionGate.isCurrentManualAction(manualActionID)
        }, allowsInteraction: allowInteraction, manualActionID: manualActionID)
        guard !ProviderRefreshContext.credentialReadIsCancelled else {
            throw CancellationError()
        }
        guard permissionGate.isCurrentManualAction(manualActionID) else {
            throw CancellationError()
        }
        return key
    }

    private func loadActiveOrganization(key: Data) throws -> String? {
        for relativePath in Self.cookieRelativePaths {
            let databasePath = path(relativePath)
            guard files.exists(databasePath) else { continue }
            for host in Self.cookieHosts {
                let hostSQL = host.replacingOccurrences(of: "'", with: "''")
                let sql = """
                SELECT CASE
                    WHEN length(value) > 0 THEN 'plain:' || hex(CAST(value AS BLOB))
                    ELSE 'encrypted:' || hex(encrypted_value)
                END
                FROM cookies
                WHERE name = 'lastActiveOrg' AND host_key = '\(hostSQL)'
                ORDER BY last_update_utc DESC
                LIMIT 1;
                """
                guard let encoded = try sqlite.queryValue(path: databasePath, sql: sql),
                      let separator = encoded.firstIndex(of: ":")
                else {
                    continue
                }
                let mode = String(encoded[..<separator])
                let hex = String(encoded[encoded.index(after: separator)...])
                guard let stored = Data(hexString: hex) else { continue }

                let value: Data
                if mode == "plain" {
                    value = stored
                } else if mode == "encrypted" {
                    let decrypted = try Self.decrypt(stored, key: key)
                    let hostHash = Data(SHA256.hash(data: Data(host.utf8)))
                    guard decrypted.starts(with: hostHash) else { continue }
                    value = decrypted.dropFirst(hostHash.count)
                } else {
                    continue
                }
                guard let organization = String(data: value, encoding: .utf8),
                      UUID(uuidString: organization) != nil
                else {
                    continue
                }
                return organization.lowercased()
            }
        }
        return nil
    }

    private func loadCaches(key: Data) throws -> (v2: [String: Any]?, v1: [String: Any]?)? {
        guard let text = try files.readTextIfPresent(path(Self.configRelativePath)),
              let data = text.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return (
            v2: try Self.decodeCache(root[Self.cacheV2Key], key: key),
            v1: try Self.decodeCache(root[Self.cacheV1Key], key: key)
        )
    }

    private static func decodeCache(_ stored: Any?, key: Data) throws -> [String: Any]? {
        guard let base64 = stored as? String else { return nil }
        guard let encrypted = Data(base64Encoded: base64) else {
            throw ClaudeDesktopCredentialError.invalidCiphertext
        }
        let plaintext = try decrypt(encrypted, key: key)
        guard let object = try JSONSerialization.jsonObject(with: plaintext) as? [String: Any] else {
            throw ClaudeDesktopCredentialError.invalidCiphertext
        }
        return object
    }

    static func deriveKey(password: String) throws -> Data {
        let passwordData = Data(password.utf8)
        let salt = Data("saltysalt".utf8)
        var key = Data(count: kCCKeySizeAES128)
        let keyCount = key.count
        let result = key.withUnsafeMutableBytes { keyBytes in
            passwordData.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.bindMemory(to: Int8.self).baseAddress,
                        passwordData.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        1003,
                        keyBytes.bindMemory(to: UInt8.self).baseAddress,
                        keyCount
                    )
                }
            }
        }
        guard result == kCCSuccess else {
            throw ClaudeDesktopCredentialError.invalidSafeStorageKey
        }
        return key
    }

    static func decrypt(_ encrypted: Data, key: Data) throws -> Data {
        guard encrypted.count > 3,
              encrypted.prefix(3) == Data("v10".utf8),
              key.count == kCCKeySizeAES128
        else {
            throw ClaudeDesktopCredentialError.invalidCiphertext
        }

        let payload = encrypted.dropFirst(3)
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var output = Data(count: payload.count + kCCBlockSizeAES128)
        var outputLength = 0
        let outputCapacity = output.count
        let status = output.withUnsafeMutableBytes { outputBytes in
            payload.withUnsafeBytes { payloadBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            payloadBytes.baseAddress,
                            payload.count,
                            outputBytes.baseAddress,
                            outputCapacity,
                            &outputLength
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            throw ClaudeDesktopCredentialError.decryptionFailed(status)
        }
        output.count = outputLength
        return output
    }

    private func path(_ relativePath: String) -> String {
        homeDirectory().appendingPathComponent(relativePath).path
    }
}

final class SafeStorageKeyCache: @unchecked Sendable {
    struct CachedValue: Equatable, Sendable {
        var data: Data
        var generation: UInt64
    }

    private struct LoadFailure {
        let error: any Error
        let allowsInteraction: Bool
        let manualActionID: UInt64?
    }

    private enum LoadOutcome {
        case value(CachedValue?)
        case failure(LoadFailure)
    }

    private let condition = NSCondition()
    private var stored: Data?
    private var storedGeneration: UInt64 = 0
    private var pendingReloadAfterGeneration: UInt64?
    private var reloadAttemptedForGeneration: UInt64?
    private var reloadAttemptManualActionID: UInt64?
    private var loadGeneration: UInt64 = 0
    private var loadingGeneration: UInt64?
    private var waiterCounts: [UInt64: Int] = [:]
    private var completedLoads: [UInt64: LoadOutcome] = [:]

    var value: Data? {
        get {
            condition.lock()
            defer { condition.unlock() }
            return stored
        }
    }

    /// Drop a cached password only when the decrypting caller still holds the current generation.
    /// Concurrent readers of the same stale key then share one bounded Keychain reload.
    @discardableResult
    func invalidateAfterDecryptionFailure(_ failed: CachedValue) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard stored == failed.data,
              storedGeneration == failed.generation,
              reloadAttemptedForGeneration != failed.generation
        else { return false }
        pendingReloadAfterGeneration = failed.generation
        stored = nil
        condition.broadcast()
        return true
    }

    /// A failed replacement key stays cached after its one automatic retry so scheduled refreshes
    /// do not repeatedly query Keychain. A later explicit manual action may make one new bounded
    /// attempt. The action that loaded the failed replacement owns that attempt across all sibling
    /// cards, even if another card successfully decrypts with the same key.
    func permitReloadAfterFailedDecrypt(
        manualActionID: UInt64?,
        allowsInteraction: Bool
    ) {
        guard allowsInteraction, let manualActionID else { return }
        condition.lock()
        defer { condition.unlock() }
        guard stored != nil,
              reloadAttemptedForGeneration == storedGeneration,
              reloadAttemptManualActionID != manualActionID
        else { return }
        reloadAttemptedForGeneration = nil
        reloadAttemptManualActionID = manualActionID
    }

    /// Number of sibling reads currently waiting for the in-flight key load. Kept visible so the
    /// concurrency regression can coordinate around the prompt deterministically.
    var waitingReaderCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return waiterCounts.values.reduce(0, +)
    }

    /// Reuse a key loaded by a concurrent account card. The loader itself is synchronous (Security
    /// Keychain read + PBKDF2), so one condition protects the whole in-flight read and wakes every
    /// sibling. Waiters share success and absence. A current interactive caller can retry a failed
    /// read when the in-flight loader had less permission or belonged to another manual action.
    func getOrLoad(
        _ loadKey: () throws -> Data?,
        isCurrent: () -> Bool = { !Task.isCancelled },
        allowsInteraction: Bool = false,
        manualActionID: UInt64? = nil
    ) throws -> Data? {
        try getOrLoadVersioned(
            loadKey,
            isCurrent: isCurrent,
            allowsInteraction: allowsInteraction,
            manualActionID: manualActionID
        )?.data
    }

    func getOrLoadVersioned(
        _ loadKey: () throws -> Data?,
        isCurrent: () -> Bool = { !Task.isCancelled },
        allowsInteraction: Bool = false,
        manualActionID: UInt64? = nil
    ) throws -> CachedValue? {
        condition.lock()
        if Task.isCancelled {
            condition.unlock()
            throw CancellationError()
        }

        if let stored {
            let value = CachedValue(data: stored, generation: storedGeneration)
            condition.unlock()
            return value
        }

        if let generation = loadingGeneration {
            waiterCounts[generation, default: 0] += 1
            // NSCondition has no direct task-cancellation hook. Bound the wait so a canceled sibling
            // card releases its detached worker promptly even while the leader is blocked in Security.
            while loadingGeneration == generation, !Task.isCancelled {
                _ = condition.wait(until: Date(timeIntervalSinceNow: 0.05))
            }
            if Task.isCancelled {
                finishWaiting(for: generation)
                condition.unlock()
                throw CancellationError()
            }

            if let stored {
                let value = CachedValue(data: stored, generation: storedGeneration)
                finishWaiting(for: generation)
                condition.unlock()
                return value
            }

            let outcome = completedLoads[generation]
            finishWaiting(for: generation)
            condition.unlock()
            switch outcome {
            case .value(let value): return value
            case .failure(let failure):
                // A stale leader's manual-action cancellation belongs to that action only. A current
                // sibling waiting behind it must get its own safe-storage read and prompt decision.
                if ProviderCancellation.isCancellation(failure.error), isCurrent() {
                    return try getOrLoadVersioned(
                        loadKey,
                        isCurrent: isCurrent,
                        allowsInteraction: allowsInteraction,
                        manualActionID: manualActionID
                    )
                }
                let canRetryInteractively: Bool
                if let error = failure.error as? ClaudeDesktopCredentialError {
                    switch error {
                    case .permissionRequired, .keychainFailure, .keychainReadDeferred:
                        canRetryInteractively = true
                    case .invalidSafeStorageKey, .invalidCiphertext, .decryptionFailed:
                        canRetryInteractively = false
                    }
                } else {
                    canRetryInteractively = false
                }
                let callerHasNewPermission = allowsInteraction
                    && (!failure.allowsInteraction || failure.manualActionID != manualActionID)
                if canRetryInteractively, callerHasNewPermission, isCurrent() {
                    return try getOrLoadVersioned(
                        loadKey,
                        isCurrent: isCurrent,
                        allowsInteraction: allowsInteraction,
                        manualActionID: manualActionID
                    )
                }
                throw failure.error
            case nil:
                // A newer independent load replaced the outcome before this waiter resumed.
                return try getOrLoadVersioned(
                    loadKey,
                    isCurrent: isCurrent,
                    allowsInteraction: allowsInteraction,
                    manualActionID: manualActionID
                )
            }
        }

        loadGeneration &+= 1
        let generation = loadGeneration
        loadingGeneration = generation
        condition.unlock()

        do {
            let loaded = try loadKey()
            condition.lock()
            let cachedValue: CachedValue?
            if let loaded {
                stored = loaded
                storedGeneration &+= 1
                if pendingReloadAfterGeneration != nil {
                    reloadAttemptedForGeneration = storedGeneration
                    reloadAttemptManualActionID = manualActionID
                    pendingReloadAfterGeneration = nil
                }
                cachedValue = CachedValue(data: loaded, generation: storedGeneration)
            } else {
                cachedValue = nil
            }
            if loaded == nil, waiterCounts[generation, default: 0] > 0 {
                completedLoads[generation] = .value(cachedValue)
            } else if let cachedValue, waiterCounts[generation, default: 0] > 0 {
                completedLoads[generation] = .value(cachedValue)
            }
            loadingGeneration = nil
            removeCompletedLoadIfUnobserved(generation)
            condition.broadcast()
            condition.unlock()
            return cachedValue
        } catch {
            condition.lock()
            if waiterCounts[generation, default: 0] > 0 {
                completedLoads[generation] = .failure(
                    LoadFailure(
                        error: error,
                        allowsInteraction: allowsInteraction,
                        manualActionID: manualActionID
                    )
                )
            }
            loadingGeneration = nil
            removeCompletedLoadIfUnobserved(generation)
            condition.broadcast()
            condition.unlock()
            throw error
        }
    }

    /// The condition lock must be held by the caller.
    private func finishWaiting(for generation: UInt64) {
        guard let count = waiterCounts[generation] else { return }
        if count <= 1 {
            waiterCounts.removeValue(forKey: generation)
            completedLoads.removeValue(forKey: generation)
        } else {
            waiterCounts[generation] = count - 1
        }
    }

    /// The condition lock must be held by the caller.
    private func removeCompletedLoadIfUnobserved(_ generation: UInt64) {
        if waiterCounts[generation, default: 0] == 0 {
            completedLoads.removeValue(forKey: generation)
        }
    }
}

private extension Data {
    init?(hexString: String) {
        guard hexString.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
