import Foundation
import Security
import Synchronization

/// Supplies platform services to Rust on its worker threads.
enum RustEngineHost {
    private static let environment = ProcessEnvironmentReader()
    private static let keychain = SecurityKeychainAccessor()
    private static let refreshes = Mutex<[UInt64: Refresh]>([:])
    private static let claudeDesktopKeyCache = Mutex<SafeStorageKeyCache?>(nil)

    static func useClaudeDesktopKeyCache(_ cache: SafeStorageKeyCache) {
        claudeDesktopKeyCache.withLock { $0 = cache }
    }

    struct Refresh: Sendable {
        let context = ProviderRefreshContext.detachedValues
        private let cancellation = KeychainReadCancellationToken()

        func withValue<T>(_ operation: () throws -> T) rethrows -> T {
            try context.withValue {
                try ProviderRefreshContext.$keychainReadCancellationToken.withValue(
                    cancellation,
                    operation: operation
                )
            }
        }

        func cancel() {
            cancellation.cancel()
        }
    }

    static func register(_ refresh: Refresh, for id: UInt64) {
        refreshes.withLock { $0[id] = refresh }
    }

    static func unregister(_ id: UInt64) {
        _ = refreshes.withLock { $0.removeValue(forKey: id) }
    }

    static func handle(
        _ request: Data,
        keychain: any KeychainAccessing = keychain,
        claudeKeyCache: SafeStorageKeyCache? = claudeDesktopKeyCache.withLock { $0 }
    ) -> String? {
        do {
            let envelope = try JSONDecoder().decode(Request.self, from: request)
            switch envelope.method {
            case "env":
                return try encode(envelope.params.name.flatMap { environment.value(for: $0) })
            case "secureRead":
                return try encode(read(envelope.params, keychain: keychain, claudeKeyCache: claudeKeyCache))
            case "secureWrite":
                return try encode(write(envelope.params, keychain: keychain))
            case "secureDelete":
                return try encode(delete(envelope.params))
            case "secureExists":
                guard let service = envelope.params.service else { return nil }
                return try encode(keychain.genericPasswordExists(service: service))
            default:
                AppLog.error(LogTag.refresh, "engine requested an unknown host service")
                return nil
            }
        } catch {
            // Decoding errors may contain part of the request, including a secret on writes.
            AppLog.error(LogTag.refresh, "engine host request could not be processed")
            return nil
        }
    }

    private static func read(
        _ params: Parameters, keychain: any KeychainAccessing, claudeKeyCache: SafeStorageKeyCache?
    ) -> Response {
        guard let service = params.service else {
            return Response(status: "failed", message: "Keychain service is missing.")
        }
        let account = params.account?.resolved
        if let id = params.requestId {
            guard let refresh = refreshes.withLock({ $0[id] }) else {
                return Response(status: "cancelled")
            }
            return refresh.withValue {
                read(params, service: service, account: account, keychain: keychain, claudeKeyCache: claudeKeyCache)
            }
        }
        return ProviderRefreshContext.$isManual.withValue(false) {
            read(params, service: service, account: account, keychain: keychain, claudeKeyCache: claudeKeyCache)
        }
    }

    private static func read(
        _ params: Parameters, service: String, account: String?, keychain: any KeychainAccessing,
        claudeKeyCache: SafeStorageKeyCache?
    ) -> Response {
        guard !ProviderRefreshContext.credentialReadIsCancelled else { return Response(status: "cancelled") }
        // Account discovery may already hold a one-time Safe Storage grant. Reuse it through
        // the host callback so the refresh does not require another prompt or put it in config.
        if service == ClaudeDesktopSafeStorageKeyReader.service,
           account == ClaudeDesktopSafeStorageKeyReader.account,
           let data = claudeKeyCache?.value,
           let password = String(data: data, encoding: .utf8), !password.isEmpty {
            return Response(status: "found", value: password)
        }
        do {
            let mayInteract = params.allowInteraction == true && ProviderRefreshContext.isManual
                && ProviderRefreshContext.credentialInteractionGate != nil
            let value = try keychain.readGenericPasswordForRefresh(
                service: service,
                account: account,
                allowInteraction: mayInteract,
                bypassDeferredReadFailure: params.bypassDeferredReadFailure == true,
                recheckBlockedSilently: params.recheckBlockedSilently == true
            )
            return value.map { Response(status: "found", value: $0) } ?? Response(status: "notFound")
        } catch is CancellationError {
            return Response(status: "cancelled")
        } catch KeychainError.interactionNotAllowed {
            let key = KeychainItemKey(service: service, account: account)
            return Response(status: KeychainPermissionGate.shared.isDeclined(key) ? "denied" : "interactionRequired")
        } catch KeychainError.readDeferred {
            return Response(status: "deferred")
        } catch {
            return Response(status: "failed", message: "Keychain read failed.")
        }
    }

    private static func write(_ params: Parameters, keychain: any KeychainAccessing) -> Response {
        guard let service = params.service, let value = params.value else {
            return Response(status: "failed", message: "Keychain write is missing its service or value.")
        }
        do {
            if let account = params.account?.resolved {
                try keychain.writeGenericPassword(service: service, account: account, value: value)
            } else {
                try keychain.writeGenericPasswordForCurrentUser(service: service, value: value)
            }
            return Response(status: "written")
        } catch {
            return Response(status: "failed", message: "Keychain write failed.")
        }
    }

    private static func delete(_ params: Parameters) -> Response {
        guard let service = params.service else {
            return Response(status: "failed", message: "Keychain service is missing.")
        }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let account = params.account?.resolved {
            query[kSecAttrAccount as String] = account
        }
        let status = SecItemDelete(query as CFDictionary)
        switch status {
        case errSecSuccess: return Response(status: "deleted")
        case errSecItemNotFound: return Response(status: "notFound")
        default: return Response(status: "failed", message: "Keychain delete failed.")
        }
    }

    private static func encode<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    private struct Request: Decodable {
        let method: String
        let params: Parameters
    }

    private struct Parameters: Decodable {
        let service: String?
        let name: String?
        let account: Account?
        let value: String?
        let allowInteraction: Bool?
        let bypassDeferredReadFailure: Bool?
        let recheckBlockedSilently: Bool?
        let requestId: UInt64?
    }

    private struct Account: Decodable {
        enum Kind: String, Decodable { case any, currentUser, named }

        let kind: Kind
        let name: String?

        var resolved: String? {
            switch kind {
            case .any: nil
            case .currentUser: currentUserKeychainAccount()
            case .named: name
            }
        }
    }

    private struct Response: Encodable {
        let status: String
        var value: String?
        var message: String?
    }
}
