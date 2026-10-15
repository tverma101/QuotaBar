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
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard authenticationContext.finish() else { throw CancellationError() }
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let password = String(data: data, encoding: .utf8),
                  !password.isEmpty
            else {
                throw ClaudeDesktopCredentialError.invalidSafeStorageKey
            }
            return password
        case errSecItemNotFound:
            return nil
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
            throw ClaudeDesktopCredentialError.permissionRequired
        default:
            throw ClaudeDesktopCredentialError.keychainFailure(Int(status))
        }
    }
}

enum ClaudeDesktopCredentialError: Error, Sendable {
    case permissionRequired
    case invalidSafeStorageKey
    case keychainFailure(Int)
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
    private static let configRelativePath = "Library/Application Support/Claude/config.json"
    private static let cookieRelativePaths = [
        "Library/Application Support/Claude/Cookies",
        "Library/Application Support/Claude/Network/Cookies"
    ]
    private static let cacheV1Key = "oauth:tokenCache"
    private static let cacheV2Key = "oauth:tokenCacheV2"
    private static let cookieHosts = [".claude.ai", "claude.ai"]

    var files: TextFileAccessing
    var sqlite: SQLiteAccessing
    var keyReader: ClaudeDesktopSafeStorageKeyReading
    var homeDirectory: @Sendable () -> URL
    var now: @Sendable () -> Date
    private let keyCache: SafeStorageKeyCache

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

    /// Cheap, prompt-free evidence for first-run detection. The real refresh still decrypts and validates.
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
        if let expectedAccountUUID,
           lastKnownAccountUUID()?.caseInsensitiveCompare(expectedAccountUUID) != .orderedSame
        {
            return ClaudeDesktopCredentialResult(oauth: nil, status: .notFound)
        }
        guard materialStatus == .available else {
            return ClaudeDesktopCredentialResult(oauth: nil, status: .notFound)
        }

        do {
            guard let key = try safeStorageKey(
                allowInteraction: allowInteraction,
                interactionGate: interactionGate
            ) else {
                return ClaudeDesktopCredentialResult(oauth: nil, status: .notFound)
            }
            guard let activeOrg = try loadActiveOrganization(key: key),
                  let caches = try loadCaches(key: key)
            else {
                return ClaudeDesktopCredentialResult(oauth: nil, status: .invalid)
            }

            let targetOrganization = organization?.lowercased() ?? activeOrg
            let currentAccountUUID = lastKnownAccountUUID()
            let selection = Self.selectCredential(
                activeOrganization: targetOrganization,
                activeAccountUUID: currentAccountUUID,
                v2: caches.v2,
                v1: caches.v1,
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
        } catch is CancellationError {
            // Provider refresh checks cancellation after the off-actor load returns. Avoid turning a
            // canceled Keychain read into a Desktop error or a credential-read log entry.
            return ClaudeDesktopCredentialResult(oauth: nil, status: .notChecked)
        } catch {
            AppLog.error(LogTag.auth("claude"), "Claude Desktop credential read failed: \(error.localizedDescription)")
            return ClaudeDesktopCredentialResult(oauth: nil, status: .invalid)
        }
    }

    private func safeStorageKey(
        allowInteraction: Bool,
        interactionGate: CredentialInteractionGate?
    ) throws -> Data? {
        try Task.checkCancellation()
        let itemKey = KeychainItemKey(
            service: ClaudeDesktopSafeStorageKeyReader.service,
            account: ClaudeDesktopSafeStorageKeyReader.account
        )
        let permissionGate = KeychainPermissionGate.shared
        let manualActionID = ProviderRefreshContext.manualActionID
        let key = try keyCache.getOrLoad({
            do {
                try Task.checkCancellation()
                guard !ProviderRefreshContext.credentialReadIsCancelled else {
                    throw CancellationError()
                }
                guard !permissionGate.isDeclined(itemKey) else {
                    throw ClaudeDesktopCredentialError.permissionRequired
                }
                if permissionGate.isBlocked(itemKey), !allowInteraction {
                    throw ClaudeDesktopCredentialError.permissionRequired
                }
                let observedGeneration = permissionGate.generation(for: itemKey)
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
                        permissionGate.reset(
                            itemKey,
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
                throw error
            }
        }, isCurrent: {
            !ProviderRefreshContext.credentialReadIsCancelled
                && permissionGate.isCurrentManualAction(manualActionID)
        })
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
    private enum LoadOutcome {
        case value(Data?)
        case failure(any Error)
    }

    private let condition = NSCondition()
    private var stored: Data?
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

    /// Number of sibling reads currently waiting for the in-flight key load. Kept visible so the
    /// concurrency regression can coordinate around the prompt deterministically.
    var waitingReaderCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return waiterCounts.values.reduce(0, +)
    }

    /// Reuse a key loaded by a concurrent account card. The loader itself is synchronous (Security
    /// Keychain read + PBKDF2), so one condition protects the whole in-flight read and wakes every
    /// sibling. Waiters share the same success, absence, or failure; a later independent refresh may
    /// retry a failed read.
    func getOrLoad(
        _ loadKey: () throws -> Data?,
        isCurrent: () -> Bool = { !Task.isCancelled }
    ) throws -> Data? {
        condition.lock()
        if Task.isCancelled {
            condition.unlock()
            throw CancellationError()
        }

        if let stored {
            condition.unlock()
            return stored
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
                finishWaiting(for: generation)
                condition.unlock()
                return stored
            }

            let outcome = completedLoads[generation]
            finishWaiting(for: generation)
            condition.unlock()
            switch outcome {
            case .value(let value): return value
            case .failure(let error):
                // A stale leader's manual-action cancellation belongs to that action only. A current
                // sibling waiting behind it must get its own safe-storage read and prompt decision.
                if ProviderCancellation.isCancellation(error), isCurrent() {
                    return try getOrLoad(loadKey, isCurrent: isCurrent)
                }
                throw error
            case nil:
                // A newer independent load replaced the outcome before this waiter resumed.
                return try getOrLoad(loadKey, isCurrent: isCurrent)
            }
        }

        loadGeneration &+= 1
        let generation = loadGeneration
        loadingGeneration = generation
        condition.unlock()

        do {
            let loaded = try loadKey()
            condition.lock()
            if let loaded { stored = loaded }
            if loaded == nil, waiterCounts[generation, default: 0] > 0 {
                completedLoads[generation] = .value(nil)
            }
            loadingGeneration = nil
            removeCompletedLoadIfUnobserved(generation)
            condition.broadcast()
            condition.unlock()
            return loaded
        } catch {
            condition.lock()
            if waiterCounts[generation, default: 0] > 0 {
                completedLoads[generation] = .failure(error)
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
