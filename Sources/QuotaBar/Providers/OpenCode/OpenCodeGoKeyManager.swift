import CryptoKit
import Foundation

enum OpenCodeGoKeyDiagnostics {
    static let authFileInventoryRead = "opencode.account-inventory.auth-file-read"
    static let savedKeysInventoryRead = "opencode.account-inventory.saved-keys-read"
}

enum OpenCodeGoKeyIdentity {
    static func credentialID(for key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Platform workflow behind OpenCode's Go Keys settings surface. It owns no refresh behavior: the
/// production provider refreshes in the Rust engine, while this small bridge lists auth-file keys,
/// edits QuotaBar's app-owned key file, and records which account the card should show.
@MainActor
final class OpenCodeGoKeyManager {
    private let authStore: OpenCodeAuthStore
    private let goKeyStore: OpenCodeGoKeyStore
    private let activeKeyID: @Sendable () -> String?
    private let onGoKeysChanged: @MainActor () -> Void

    init(
        authStore: OpenCodeAuthStore = OpenCodeAuthStore(),
        goKeyStore: OpenCodeGoKeyStore = OpenCodeGoKeyStore(),
        activeKeyID: @escaping @Sendable () -> String? = {
            UserDefaults.standard.string(forKey: OpenCodeGoKeyStore.selectionKey)
        },
        onGoKeysChanged: @escaping @MainActor () -> Void = {}
    ) {
        self.authStore = authStore
        self.goKeyStore = goKeyStore
        self.activeKeyID = activeKeyID
        self.onGoKeysChanged = onGoKeysChanged
    }

    func goKeyEntries() async -> [OpenCodeGoKeyEntry] {
        async let fileRead: ([(name: String, key: String)], String?) = loadOffMainActor { [authStore] in
            do { return (try authStore.apiKeys(), nil) }
            catch { return ([], error.localizedDescription) }
        }
        async let savedRead: ([OpenCodeGoKey], String?) = loadOffMainActor { [goKeyStore] in
            do { return (try goKeyStore.loadKeys(), nil) }
            catch { return ([], error.localizedDescription) }
        }
        let (fileResult, savedResult) = await (fileRead, savedRead)
        if let error = fileResult.1 {
            DiagnosticGate.logOnce(for: OpenCodeGoKeyDiagnostics.authFileInventoryRead) {
                AppLog.warn(LogTag.plugin("opencode"), "Go keys unreadable from auth.json: \(error)")
            }
        } else {
            DiagnosticGate.clearFailure(OpenCodeGoKeyDiagnostics.authFileInventoryRead)
        }
        if let error = savedResult.1 {
            DiagnosticGate.logOnce(for: OpenCodeGoKeyDiagnostics.savedKeysInventoryRead) {
                AppLog.warn(LogTag.plugin("opencode"), "Go saved keys unreadable: \(error)")
            }
        } else {
            DiagnosticGate.clearFailure(OpenCodeGoKeyDiagnostics.savedKeysInventoryRead)
        }
        guard fileResult.1 == nil, savedResult.1 == nil else {
            return []
        }
        let keys = fileResult.0.map {
            (name: $0.name, key: $0.key, id: $0.name, source: OpenCodeGoKeySource.authFile)
        } + savedResult.0.map {
            (name: $0.label, key: $0.key, id: $0.id.uuidString, source: OpenCodeGoKeySource.appSaved)
        }
        let selection = activeKeyID()
        return keys.map { entry in
            OpenCodeGoKeyEntry(
                id: entry.id,
                label: entry.name,
                maskedKey: Self.mask(entry.key),
                accountID: OpenCodeGoKeyIdentity.credentialID(for: entry.key),
                source: entry.source,
                isActive: entry.id == selection
            )
        }
    }

    @discardableResult
    func saveGoKey(label: String, key: String) async throws -> OpenCodeGoKey {
        let saved = try await loadOffMainActor { [goKeyStore, label, key] in
            try goKeyStore.addKey(label: label, key: key)
        }
        onGoKeysChanged()
        return saved
    }

    func removeGoKey(id: UUID) async throws {
        try await loadOffMainActor { [goKeyStore, id] in
            try goKeyStore.removeKey(id: id)
        }
        // Dropping the pinned key must not leave a stale selection behind — refresh would fall
        // back to "all accounts", but the settings list should reflect reality immediately.
        if OpenCodeGoKeyStore.activeSelection() == id.uuidString {
            OpenCodeGoKeyStore.setActiveSelection(nil)
        }
        onGoKeysChanged()
    }

    func selectGoKey(id: String) {
        OpenCodeGoKeyStore.setActiveSelection(id)
    }

    func activeGoKeyID() -> String? {
        activeKeyID()
    }

    private static func mask(_ key: String) -> String {
        guard key.count > 8 else { return "••••••••" }
        return String(key.prefix(4)) + "…" + String(key.suffix(4))
    }
}
