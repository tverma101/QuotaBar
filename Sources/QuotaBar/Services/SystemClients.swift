import Darwin
import Foundation
import LocalAuthentication
import Security

protocol EnvironmentReading: Sendable {
    func value(for name: String) -> String?
}

struct ProcessEnvironmentReader: EnvironmentReading {
    var processEnvironment: [String: String] = ProcessInfo.processInfo.environment
    var shellEnvironment: LoginShellEnvironment = .shared
    var launchSnapshot: @Sendable () -> ShellEnvironmentSnapshot? = { ShellEnvironmentSnapshotStore.launchSnapshot }

    private static let identityKeys = Set(ShellEnvironmentSnapshot.capturedKeys)

    func value(for name: String) -> String? {
        // The process environment first (set by launchd, `launchctl setenv`, or a terminal launch),
        // then the captured login-shell environment — so keys a user exports in their shell profile
        // still resolve in a packaged app launched from Finder/Dock. See `LoginShellEnvironment`.
        if let value = processEnvironment[name]?.nilIfEmpty {
            return value
        }
        // Identity-relevant keys (provider home overrides, OAuth endpoint switches) resolve from the
        // persisted shell-environment snapshot when one exists: those facts — including "verifiably
        // NOT exported" — are frozen for the whole session, so every reader (the launch account pass
        // at init, the provider auth stores and log scanners whenever they run) sees the same home
        // overrides no matter when the async login-shell capture lands. Without the pin, an export
        // changed since the last launch would split them: identity read from the snapshot's home,
        // usage fetched from the freshly captured one, mis-stamping the shared snapshot cache. A
        // changed export applies from the next launch (the snapshot refresh task persists and logs
        // it). Every other key reads the live capture as before.
        if Self.identityKeys.contains(name), let snapshot = launchSnapshot() {
            return snapshot.values[name]?.nilIfEmpty
        }
        return shellEnvironment.value(for: name)
    }
}

protocol TextFileAccessing: Sendable {
    func exists(_ path: String) -> Bool
    /// Read a UTF-8 file when it exists. `nil` means the path is absent; permission, encoding, and
    /// other failures still throw so credential callers do not confuse broken storage with logout.
    func readTextIfPresent(_ path: String) throws -> String?
    func readText(_ path: String) throws -> String
    func writeText(_ path: String, _ text: String) throws
    /// Remove the file at `path`. A missing file is not an error — the caller wants the key gone, and
    /// it already is. Used by the in-app API-key editor's Remove / Clear-override actions.
    func remove(_ path: String) throws
}

extension TextFileAccessing {
    /// Compatibility path for test doubles. The production accessor classifies the read error directly
    /// so it does not have an exists-then-read race.
    func readTextIfPresent(_ path: String) throws -> String? {
        guard exists(path) else { return nil }
        return try readText(path)
    }
}

struct LocalTextFileAccessor: TextFileAccessing {
    /// Credential and token files must never be readable by another local account. Write through a
    /// private temporary file in the destination directory, flush it, then rename it over the target:
    /// the final replacement is atomic and has mode 0600 from the moment it becomes addressable.
    private static let privateFileMode = mode_t(S_IRUSR | S_IWUSR)

    func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: expandHome(path))
    }

    func readText(_ path: String) throws -> String {
        try String(contentsOfFile: expandHome(path), encoding: .utf8)
    }

    func readTextIfPresent(_ path: String) throws -> String? {
        do {
            return try readText(path)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    func writeText(_ path: String, _ text: String) throws {
        let expanded = expandHome(path)
        let parent = URL(fileURLWithPath: expanded).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let destination = URL(fileURLWithPath: expanded)
        let temporary = parent.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp"
        )
        let descriptor = temporary.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, Self.privateFileMode)
        }
        guard descriptor >= 0 else { throw Self.currentPOSIXError() }

        var descriptorIsOpen = true
        var temporaryExists = true
        defer {
            if descriptorIsOpen { _ = Darwin.close(descriptor) }
            if temporaryExists {
                temporary.path.withCString { _ = Darwin.unlink($0) }
            }
        }

        // A process umask may only remove permissions at creation. Reassert the exact private mode on
        // the still-unpublished inode before writing or renaming it into place.
        guard Darwin.fchmod(descriptor, Self.privateFileMode) == 0 else {
            throw Self.currentPOSIXError()
        }
        try Self.writeAll(Data(text.utf8), to: descriptor)
        guard Darwin.fsync(descriptor) == 0 else { throw Self.currentPOSIXError() }
        let closeResult = Darwin.close(descriptor)
        descriptorIsOpen = false
        guard closeResult == 0 else { throw Self.currentPOSIXError() }

        let renameResult = temporary.path.withCString { source in
            expanded.withCString { destination in
                Darwin.rename(source, destination)
            }
        }
        guard renameResult == 0 else { throw Self.currentPOSIXError() }
        temporaryExists = false
    }

    func remove(_ path: String) throws {
        let expanded = expandHome(path)
        guard FileManager.default.fileExists(atPath: expanded) else { return }
        try FileManager.default.removeItem(atPath: expanded)
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    buffer.count - offset
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    throw currentPOSIXError()
                }
                guard result > 0 else { throw POSIXError(.EIO) }
                offset += result
            }
        }
    }

    private static func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

protocol SQLiteAccessing: Sendable {
    func queryValue(path: String, sql: String) throws -> String?
    func execute(path: String, sql: String) throws
}

struct SQLiteCLIAccessor: SQLiteAccessing {
    var processRunner: ProcessRunning

    init(processRunner: ProcessRunning = SystemProcessRunner()) {
        self.processRunner = processRunner
    }

    func queryValue(path: String, sql: String) throws -> String? {
        // A normal sqlite3 open can create a missing database. Credential probes must be read-only and
        // side-effect free, so absence returns nil before a process is launched.
        guard try databaseExists(path) else { return nil }
        var result = try run(path: path, sql: sql, readOnly: true)
        if !result.succeeded {
            // A WAL-mode database under an active writer can refuse a readonly open with
            // SQLITE_CANTOPEN (14) — the shared-memory lock it needs is held. Retry read-write: the
            // query is a SELECT (no side effects), and the existence guard above already prevents
            // creating a missing database.
            result = try run(path: path, sql: sql, readOnly: false)
        }
        guard result.succeeded else {
            throw SQLiteError.queryFailed(result.stderr)
        }
        let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    func execute(path: String, sql: String) throws {
        let result = try run(path: path, sql: sql)
        guard result.succeeded else {
            throw SQLiteError.queryFailed(result.stderr)
        }
    }

    private func run(path: String, sql: String, readOnly: Bool = false) throws -> ProcessResult {
        var arguments = ["-batch", "-noheader"]
        if readOnly { arguments.append("-readonly") }
        arguments += [
            "-cmd", ".timeout 1000",
            expandHome(path),
            sql
        ]
        return try processRunner.run(
            executable: "/usr/bin/sqlite3",
            arguments: arguments,
            environment: [:],
            timeout: 5
        )
    }

    private func databaseExists(_ path: String) throws -> Bool {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: expandHome(path))
            return true
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return false
        }
    }
}

enum SQLiteError: Error, LocalizedError, Equatable {
    case queryFailed(String)

    var errorDescription: String? {
        switch self {
        case .queryFailed(let message):
            return message.isEmpty ? "SQLite query failed." : message
        }
    }
}

protocol KeychainAccessing: Sendable {
    func readGenericPassword(service: String) throws -> String?
    func readGenericPassword(service: String, allowInteraction: Bool) throws -> String?
    func writeGenericPassword(service: String, value: String) throws
    func readGenericPasswordForCurrentUser(service: String) throws -> String?
    func readGenericPasswordForCurrentUser(service: String, allowInteraction: Bool) throws -> String?
    func writeGenericPasswordForCurrentUser(service: String, value: String) throws
    /// Read a generic password scoped to an explicit account (`-a`). Used when another app stored the
    /// item under a known account name (e.g. Antigravity's `agy` token under service `gemini`,
    /// account `antigravity`) rather than the current user.
    func readGenericPassword(service: String, account: String) throws -> String?
    /// Account-scoped read that can suppress UI. The default (for mocks that don't model interaction)
    /// ignores the flag; the real `SecurityKeychainAccessor` overrides it with the in-process
    /// `LAContext` path, which is what keeps a scheduled refresh from opening a Keychain dialog.
    func readGenericPassword(service: String, account: String, allowInteraction: Bool) throws -> String?
}

extension KeychainAccessing {
    func readGenericPassword(service: String, allowInteraction: Bool) throws -> String? {
        try readGenericPassword(service: service)
    }

    func readGenericPasswordForCurrentUser(service: String) throws -> String? {
        try readGenericPassword(service: service)
    }

    func readGenericPasswordForCurrentUser(service: String, allowInteraction: Bool) throws -> String? {
        try readGenericPasswordForCurrentUser(service: service)
    }

    func writeGenericPasswordForCurrentUser(service: String, value: String) throws {
        try writeGenericPassword(service: service, value: value)
    }

    /// Default for mocks that don't model accounts: fall back to the service-only lookup. The real
    /// `SecurityKeychainAccessor` overrides this to pass `-a <account>`.
    func readGenericPassword(service: String, account: String) throws -> String? {
        try readGenericPassword(service: service)
    }

    func readGenericPassword(service: String, account: String, allowInteraction: Bool) throws -> String? {
        _ = allowInteraction
        return try readGenericPassword(service: service)
    }

    /// Read a generic password the way a provider refresh should: **silent first**, escalating to a
    /// Keychain dialog only when the user explicitly asked for a refresh.
    ///
    /// Every provider credential read on a refresh path should use this rather than the flagless
    /// overload. That overload shells out to `security find-generic-password`, which has no way to
    /// suppress UI, so a scheduled refresh re-prompts for the life of the app — one dialog every five
    /// minutes, per item, forever. The in-process path here is silent, and `allowInteraction: false`
    /// fails fast with `KeychainError.interactionNotAllowed` instead of blocking on UI.
    ///
    /// Escalation mirrors `ClaudeAuthStore`: a silent read that proves interaction is *required* may
    /// retry with UI, but only for a manual refresh, and only once per manual action across all
    /// providers via the shared `CredentialInteractionGate` — so ⌘R opens at most one Keychain dialog
    /// no matter how many provider cards are enabled.
    func readGenericPasswordForRefresh(service: String, account: String? = nil) throws -> String? {
        // A silent read already proved this item needs user interaction. Another background refresh
        // cannot grant that — it has no way to show a dialog — so answer from memory instead of
        // re-reading and re-failing every cycle. A manual refresh always retries, because it is the
        // one context that can present the dialog.
        let key = KeychainItemKey(service: service, account: account)
        if KeychainPermissionGate.shared.isBlocked(key),
           !ProviderRefreshContext.isManual {
            throw KeychainError.interactionNotAllowed
        }
        let result = try escalatingRead(key) {
            if let account {
                return try readGenericPassword(service: service, account: account, allowInteraction: $0)
            }
            return try readGenericPassword(service: service, allowInteraction: $0)
        }
        // Reached without a silent-read failure, so access is granted for *this* item now. Scoped to
        // this key on purpose: clearing the whole gate here would let an unrelated provider's success
        // un-block an item that still needs a dialog, and the re-read spam would resume.
        KeychainPermissionGate.shared.reset(key)
        return result
    }

    /// Current-user-scoped variant of `readGenericPasswordForRefresh`, for items this app *writes*
    /// itself under `kSecAttrAccount` (see `writeGenericPasswordForCurrentUser`). Account scoping is
    /// part of the query, not a detail: a service-only read is a different lookup, so this must not
    /// collapse into the service-only helper.
    func readGenericPasswordForRefreshForCurrentUser(service: String) throws -> String? {
        try escalatingRead(KeychainItemKey(service: service, scopedToCurrentUser: true)) {
            try readGenericPasswordForCurrentUser(service: service, allowInteraction: $0)
        }
    }

    /// Shared silent-first-then-escalate body for the refresh helpers. `read` receives the
    /// interaction flag and performs the read; a silent attempt that throws
    /// `KeychainError.interactionNotAllowed` is retried once, and only for a manual refresh that has
    /// not already spent the shared per-action dialog budget.
    ///
    /// `key` identifies the item being read, so a failure marks only that item as needing
    /// interaction. That is the whole point: a provider that cannot be read silently must not stop
    /// every other provider from being refreshed.
    private func escalatingRead(_ key: KeychainItemKey, _ read: (Bool) throws -> String?) throws -> String? {
        do {
            return try read(false)
        } catch KeychainError.interactionNotAllowed {
            // Remember it: without this every five-minute cycle re-reads an item it cannot read and
            // fails again, which is the "keychain access" spam.
            KeychainPermissionGate.shared.block(key)
            // Already asked and refused. Escalating again would raise the identical dialog for the same
            // item, which is the complaint this exists to answer: the app kept asking after the user had
            // already said no. Report the same definitive answer instead.
            guard !KeychainPermissionGate.shared.isDeclined(key) else {
                throw KeychainError.interactionNotAllowed
            }
            guard ProviderRefreshContext.isManual,
                  ProviderRefreshContext.credentialInteractionGate?.claim() ?? true
            else {
                throw KeychainError.interactionNotAllowed
            }
            do {
                return try read(true)
            } catch {
                // Cancelled, or the grant did not take. Either way the user has been asked once for this
                // item and did not grant it, so stop asking for the rest of the session.
                KeychainPermissionGate.shared.markDeclined(key)
                throw error
            }
        }
    }

    /// Whether an item exists for `service`, without reading its secret. `nil` means the probe
    /// itself failed (locked keychain, denied) — the caller picks its own safe side, which is not
    /// the same for every caller. The default (for mocks) falls back to a read; the real
    /// `SecurityKeychainAccessor` overrides this with an in-process attributes-only probe, safe for
    /// the launch path — it can't trigger an unlock prompt and returns in microseconds.
    func genericPasswordExists(service: String) -> Bool? {
        do {
            return try readGenericPassword(service: service) != nil
        } catch {
            return nil
        }
    }
}

struct SecurityKeychainAccessor: KeychainAccessing {
    let processRunner: ProcessRunning

    init(processRunner: ProcessRunning = SystemProcessRunner()) {
        self.processRunner = processRunner
    }

    // `security find-generic-password` exits 44 (errSecItemNotFound) when no item matches — the
    // legitimate "no credential stored" case. Any OTHER non-zero exit means a real failure (keychain
    // locked or access denied, a cancelled unlock prompt) that must not be silently rendered as
    // "not signed in".
    private static let itemNotFoundExitCode: Int32 = 44

    func readGenericPassword(service: String) throws -> String? {
        try readPassword(["find-generic-password", "-s", service, "-w"], service: service)
    }

    /// Attributes-only existence probe used on the launch path: an in-process Security-framework
    /// query (no subprocess, returns in microseconds) that never requests the secret and forbids
    /// any UI, so it can neither trigger an unlock prompt nor stall launch. A failed probe (locked
    /// keychain, denied) reports `nil` ("unknown"), never a definite answer, so callers can pick
    /// their safe side.
    func genericPasswordExists(service: String) -> Bool? {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]
        switch SecItemCopyMatching(query as CFDictionary, nil) {
        case errSecSuccess: return true
        case errSecItemNotFound: return false
        default: return nil
        }
    }

    func readGenericPasswordForCurrentUser(service: String) throws -> String? {
        try readPassword(["find-generic-password", "-a", currentUserAccount(), "-s", service, "-w"], service: service)
    }

    /// Claude uses this overload so background refreshes can read an already-authorized login while
    /// immediately returning when macOS would otherwise need to present Keychain UI.
    func readGenericPasswordForCurrentUser(service: String, allowInteraction: Bool) throws -> String? {
        try readPassword(service: service, account: currentUserAccount(), allowInteraction: allowInteraction)
    }

    /// Service-only fallback used by older Claude Code Keychain entries.
    func readGenericPassword(service: String, allowInteraction: Bool) throws -> String? {
        try readPassword(service: service, account: nil, allowInteraction: allowInteraction)
    }

    func readGenericPassword(service: String, account: String) throws -> String? {
        try readPassword(["find-generic-password", "-a", account, "-s", service, "-w"], service: service)
    }

    /// Account-scoped read that can suppress UI, matching the two service-scoped overloads. Without
    /// this, the only account-scoped path was the `security` subprocess, so a provider reading another
    /// app's item (Antigravity's `agy` token) had no way to stay silent on a scheduled refresh.
    func readGenericPassword(service: String, account: String, allowInteraction: Bool) throws -> String? {
        try readPassword(service: service, account: account, allowInteraction: allowInteraction)
    }

    private func readPassword(_ arguments: [String], service: String) throws -> String? {
        let result = try processRunner.run(
            executable: "/usr/bin/security",
            arguments: arguments,
            environment: [:],
            timeout: 5
        )
        guard result.succeeded else {
            if result.exitCode == Self.itemNotFoundExitCode { return nil }
            // Log loudly here so a locked/denied keychain is diagnosable even though current callers
            // `try?` this back to nil ("not signed in"). Surfacing a distinct user-facing "keychain
            // locked" message needs the auth-load chains to propagate the throw (folded into H1).
            AppLog.warn(.keychain, "read failed for service '\(service)' (exit \(result.exitCode))")
            throw KeychainError.readFailed(result.stderr)
        }
        let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func readPassword(service: String, account: String?, allowInteraction: Bool) throws -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }
        if !allowInteraction {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let value = String(data: data, encoding: .utf8)
            else {
                throw KeychainError.readFailed("Keychain item is not UTF-8 text.")
            }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case errSecItemNotFound:
            return nil
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
            // Previously silent. This is the single most important Keychain diagnostic: it is what a
            // provider needs to say "macOS needs permission" instead of "not logged in", and with no
            // line here a misclassified provider left no trace anywhere except the in-memory gate.
            // Not a warning: refusing to release an item the app does not own is an expected answer,
            // and the user is the one who has to act on it.
            AppLog.info(
                .keychain,
                "silent read needs user interaction; Refresh will ask (service \(service.debugDescription), OSStatus \(status))"
            )
            throw KeychainError.interactionNotAllowed
        default:
            // Provider-agnostic on purpose: this accessor is shared, so naming one provider here
            // misattributed every other provider's failure to Claude.
            AppLog.warn(.keychain, "credential read failed (Security.framework OSStatus \(status))")
            throw KeychainError.readFailed("Security.framework OSStatus \(status)")
        }
    }

    func writeGenericPassword(service: String, value: String) throws {
        try writePassword(["add-generic-password", "-U", "-s", service, "-w", value])
    }

    func writeGenericPasswordForCurrentUser(service: String, value: String) throws {
        try writePassword(["add-generic-password", "-U", "-a", currentUserAccount(), "-s", service, "-w", value])
    }

    private func writePassword(_ arguments: [String]) throws {
        let result = try processRunner.run(
            executable: "/usr/bin/security",
            arguments: arguments,
            environment: [:],
            timeout: 5
        )
        if !result.succeeded {
            throw KeychainError.writeFailed(result.stderr)
        }
    }

    private func currentUserAccount() -> String {
        ProcessInfo.processInfo.environment["USER"]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        ?? NSUserName()
    }
}

enum KeychainError: Error, LocalizedError {
    case interactionNotAllowed
    case writeFailed(String)
    case readFailed(String)

    var errorDescription: String? {
        switch self {
        case .interactionNotAllowed:
            return "Keychain access requires user interaction."
        case .writeFailed(let message):
            return message.isEmpty ? "Keychain write failed." : message
        case .readFailed(let message):
            return message.isEmpty ? "Keychain read failed." : message
        }
    }
}

func expandHome(_ path: String) -> String {
    guard path == "~" || path.hasPrefix("~/") else { return path }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if path == "~" { return home }
    return home + String(path.dropFirst())
}

/// Identity of the Keychain item a read targets, for [`KeychainPermissionGate`] bookkeeping.
///
/// The gate has to be per item, not per process: the "needs a dialog" condition belongs to one item's
/// ACL, and two different items in the same app routinely differ. `account` and `scopedToCurrentUser`
/// are part of the key because they are part of the *query* — a service-only lookup, an
/// account-scoped lookup, and a current-user-scoped lookup are three different items, and collapsing
/// them would let one item's block suppress the others.
struct KeychainItemKey: Hashable {
    let service: String
    let account: String?
    let scopedToCurrentUser: Bool

    init(service: String, account: String? = nil, scopedToCurrentUser: Bool = false) {
        self.service = service
        self.account = account
        self.scopedToCurrentUser = scopedToCurrentUser
    }
}

/// Process-wide memory that a silent Keychain read needs user interaction.
///
/// Lives here rather than per provider because the condition is a property of the *item's* ACL, not
/// of one provider: once macOS says "this needs a dialog", every background refresh of *that item*
/// until the user grants it will get the same answer. Mirrors `CredentialInteractionGate`'s lock
/// discipline.
///
/// A single process-wide boolean was wrong in both directions, and the bug was user-visible:
///
/// - **Block leaked across items.** One provider whose item needs a dialog set the flag for
///   *everyone*, so every other provider's background read was refused without ever reaching the
///   Keychain — an item that was perfectly readable started reporting "not logged in" because an
///   unrelated provider needed attention.
/// - **Reset leaked across items.** Any successful read cleared the flag, including reads of
///   unrelated items. So the item that genuinely needed a dialog had its block cleared every cycle by
///   some other provider's success, and the five-minute re-read-and-fail spam came right back — the
///   exact thing the gate exists to prevent.
///
/// Keyed by [`KeychainItemKey`] so block and reset both stay scoped to the item that earned them.
final class KeychainPermissionGate: @unchecked Sendable {
    static let shared = KeychainPermissionGate()

    private init() {}
    private let lock = NSLock()
    private var blocked: Set<KeychainItemKey> = []
    /// Items the user has already been prompted for and did not grant — cancelled the dialog, or the
    /// interactive read came back refused.
    ///
    /// Without this, declining is indistinguishable from never having been asked: the item stays blocked
    /// for background reads, but the *next* manual refresh escalates again and raises the same dialog.
    /// That is the "it keeps asking" loop — the user's only escape was to stop pressing Refresh Now, and
    /// the app had no way to say it would stop asking.
    private var declined: Set<KeychainItemKey> = []

    /// Whether the user has already declined this item, so a further manual refresh must not re-prompt.
    func isDeclined(_ key: KeychainItemKey) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return declined.contains(key)
    }

    /// Records that the user declined, so the dialog is shown at most once per item per session.
    func markDeclined(_ key: KeychainItemKey) {
        lock.lock()
        declined.insert(key)
        lock.unlock()
    }

    /// Forgets a decline. Called when the user explicitly asks to try again, so the offer to grant is
    /// reachable without restarting the app.
    func clearDeclined(_ key: KeychainItemKey) {
        lock.lock()
        declined.remove(key)
        lock.unlock()
    }

    func isBlocked(_ key: KeychainItemKey) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return blocked.contains(key)
    }

    func block(_ key: KeychainItemKey) {
        lock.lock()
        blocked.insert(key)
        lock.unlock()
    }

    /// Clears the block for one item, leaving every other item's state untouched.
    func reset(_ key: KeychainItemKey) {
        lock.lock()
        blocked.remove(key)
        lock.unlock()
    }

    /// Clears every item. Test-support only: production has no reason to forget an item's ACL.
    func resetAll() {
        lock.lock()
        blocked.removeAll()
        declined.removeAll()
        lock.unlock()
    }
}
