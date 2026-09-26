import Foundation

/// One app-saved OpenCode Go API key. Stored keys supplement the keys OpenCode's own
/// `auth.json` already provides — a second account's key from another machine, or a key the
/// user wants QuotaBar to manage. The key value lives in the same style of app-owned config
/// file as `UserAPIKeyStore` (OpenRouter/Z.ai keys) — the app has no Keychain-write path, and
/// ad-hoc re-signing per build would invalidate Keychain ACLs; `auth.json` itself is also a
/// plaintext key file, so this is no weaker than the credential's native home.
struct OpenCodeGoKey: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var label: String
    var key: String
}

/// The app-owned store of extra OpenCode Go keys plus the active-key selection. One small JSON
/// file in Application Support (mirroring `UserAPIKeyStore`'s config-file approach); the
/// selection — which account's meters the card shows — is a plain UserDefaults string: a saved
/// key's UUID, or the `opencode-go` auth.json entry name.
struct OpenCodeGoKeyStore: Sendable {
    /// UserDefaults key for the active selection.
    static let selectionKey = "opencode.activeGoKeyID"

    var files: TextFileAccessing
    var filePath: @Sendable () -> String

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        filePath: @escaping @Sendable () -> String = { OpenCodeGoKeyStore.defaultFilePath }
    ) {
        self.files = files
        self.filePath = filePath
    }

    static var defaultFilePath: String {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QuotaBar", isDirectory: true)
        return dir.appendingPathComponent("opencode-go-keys.json").path
    }

    /// All saved keys, in save order. An absent file is the empty list; an unreadable or
    /// malformed file throws so the provider can fail loudly (a silently dropped key list would
    /// look like a plain "not logged in").
    func loadKeys() throws -> [OpenCodeGoKey] {
        guard let text = try files.readTextIfPresent(filePath()) else { return [] }
        guard let data = text.data(using: .utf8) else {
            throw OpenCodeUsageError.credentialsUnreadable(detail: "go-keys file is not UTF-8")
        }
        do {
            return try JSONDecoder().decode([OpenCodeGoKey].self, from: data)
        } catch {
            throw OpenCodeUsageError.credentialsUnreadable(detail: "go-keys file is not valid JSON: \(error.localizedDescription)")
        }
    }

    /// Append a key and persist the list. The label defaults to "Account N" when empty; the key
    /// is trimmed and must be non-empty. Returns the stored entry (its UUID is the selection id).
    @discardableResult
    func addKey(label: String, key: String) throws -> OpenCodeGoKey {
        var keys = try loadKeys()
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw OpenCodeUsageError.credentialsUnreadable(detail: "refusing to save an empty key")
        }
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = OpenCodeGoKey(
            id: UUID(),
            label: trimmedLabel.isEmpty ? "Account \(keys.count + 1)" : trimmedLabel,
            key: trimmedKey
        )
        keys.append(entry)
        try save(keys)
        return entry
    }

    /// Remove a saved key and persist the list. A missing key is a no-op.
    func removeKey(id: UUID) throws {
        var keys = try loadKeys()
        keys.removeAll { $0.id == id }
        try save(keys)
    }

    private func save(_ keys: [OpenCodeGoKey]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(keys)
        guard let text = String(data: data, encoding: .utf8) else {
            throw OpenCodeUsageError.credentialsUnreadable(detail: "go-keys encode failed")
        }
        do {
            try files.writeText(filePath(), text)
        } catch {
            AppLog.error(.auth, "save OpenCode Go keys to \(filePath()) failed: \(error.localizedDescription)")
            throw OpenCodeUsageError.credentialsUnreadable(detail: "write failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Active selection

    static func activeSelection(defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: selectionKey)
    }

    static func setActiveSelection(_ id: String?, defaults: UserDefaults = .standard) {
        if let id {
            defaults.set(id, forKey: selectionKey)
        } else {
            defaults.removeObject(forKey: selectionKey)
        }
    }
}
