import Foundation
import Security

/// `LAContext.interactionNotAllowed` controls data-protection Keychain authentication, but provider
/// credentials also live in the legacy file-based Keychain. Its UI switch is process-wide, so every
/// native read, probe, and write must share this lock for the entire synchronous Security call.
final class KeychainUserInteraction: @unchecked Sendable {
    static let shared = KeychainUserInteraction()

    private let lock = NSRecursiveLock()
    private let getAllowed: @Sendable () -> (OSStatus, Bool)
    private let setAllowed: @Sendable (Bool) -> OSStatus

    init(
        getAllowed: @escaping @Sendable () -> (OSStatus, Bool) = {
            var allowed = DarwinBoolean(false)
            let status = SecKeychainGetUserInteractionAllowed(&allowed)
            return (status, allowed.boolValue)
        },
        setAllowed: @escaping @Sendable (Bool) -> OSStatus = { SecKeychainSetUserInteractionAllowed($0) }
    ) {
        self.getAllowed = getAllowed
        self.setAllowed = setAllowed
    }

    func perform(allowInteraction: Bool, _ operation: () -> OSStatus) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }

        let (readStatus, previous) = getAllowed()
        guard readStatus == errSecSuccess else {
            AppLog.error(.keychain, "Could not read Keychain interaction policy (OSStatus \(readStatus))")
            return readStatus
        }
        let setStatus = setAllowed(allowInteraction)
        guard setStatus == errSecSuccess else {
            AppLog.error(.keychain, "Could not set Keychain interaction policy (OSStatus \(setStatus))")
            return setStatus
        }

        let status = operation()
        let restoreStatus = setAllowed(previous)
        guard restoreStatus == errSecSuccess else {
            AppLog.error(.keychain, "Could not restore Keychain interaction policy (OSStatus \(restoreStatus))")
            // Leave legacy UI disabled if restoring the prior state failed.
            let disableStatus = setAllowed(false)
            if disableStatus != errSecSuccess {
                AppLog.error(.keychain, "Could not disable Keychain interaction after restore failure (OSStatus \(disableStatus))")
            }
            return status == errSecSuccess ? restoreStatus : status
        }
        return status
    }
}

protocol SecurityKeychainItemReading: Sendable {
    func copyMatching(_ query: [String: Any], result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
}

struct SecurityFrameworkKeychainReader: SecurityKeychainItemReading {
    func copyMatching(_ query: [String: Any], result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        SecItemCopyMatching(query as CFDictionary, result)
    }
}
