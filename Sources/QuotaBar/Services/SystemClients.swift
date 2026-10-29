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

        // A symlink at the destination is followed, not replaced.
        //
        // `rename(2)` replaces the *directory entry*, so writing over a path that is a symlink silently
        // destroys the link and leaves a regular file in its place. Users keep `~/.codex/auth.json`,
        // `~/.claude/.credentials.json` and `~/.grok/auth.json` symlinked into a dotfiles repo, and a
        // *background* refresh — the five-minute tick, no user action — was rotating a token and
        // atomically clobbering the link. The dotfiles copy then stopped receiving rotations, the link was
        // gone with no undo and no log line, and the divergence only surfaced at the next `git status`.
        //
        // `O_NOFOLLOW` was already applied to the temporary file, which protects the write; this protects
        // the link. Resolving first means the rotation lands on the real target, which is exactly what
        // linking it asked for.
        let resolvedURL = URL(
            fileURLWithPath: Self.resolveSymlinkDestination(expanded, fallbackParent: parent)
        )
        let resolvedParent = resolvedURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: resolvedParent, withIntermediateDirectories: true
        )
        let destination = resolvedURL.path
        let temporary = resolvedParent.appendingPathComponent(
            ".\(resolvedURL.lastPathComponent).\(UUID().uuidString).tmp"
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

        // Rename onto the *resolved* destination. Using `expanded` here is what destroyed the link: the
        // rename replaced the symlink's directory entry with a regular file.
        let renameResult = temporary.path.withCString { source in
            destination.withCString { target in
                Darwin.rename(source, target)
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

    /// Follows a symlink chain at `path` and returns the path that should actually be written.
    ///
    /// Bounded to a handful of hops so a symlink cycle cannot hang a background refresh. A broken link
    /// whose target's parent does not exist resolves to that target, and the write then creates the
    /// parent — better than destroying the link and leaving the user with a regular file where their
    /// setup used to be.
    static func resolveSymlinkDestination(_ path: String, fallbackParent: URL) -> String {
        var current = path
        for _ in 0..<8 {
            var status = stat()
            let isLink = current.withCString { Darwin.lstat($0, &status) } == 0
                && (status.st_mode & S_IFMT) == S_IFLNK
            guard isLink else { return current }
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            let length = current.withCString { Darwin.readlink($0, &buffer, buffer.count - 1) }
            guard length > 0 else { return current }
            buffer[length] = 0
            let target = String(decoding: buffer[..<length].map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let next = target.hasPrefix("/")
                ? target
                : fallbackParent.path + "/" + target
            current = (next as NSString).expandingTildeInPath
        }
        // Cycle, or deeper than the hop budget: return where we started rather than somewhere arbitrary.
        return path
    }

}

protocol SQLiteAccessing: Sendable {
    func queryValue(path: String, sql: String) throws -> String?
    func execute(path: String, sql: String) throws
}

struct SQLiteCLIAccessor: SQLiteAccessing {
    var processRunner: ProcessRunning
    var allowsReadWriteFallback: Bool

    init(
        processRunner: ProcessRunning = SystemProcessRunner(),
        allowsReadWriteFallback: Bool = true
    ) {
        self.processRunner = processRunner
        self.allowsReadWriteFallback = allowsReadWriteFallback
    }

    func queryValue(path: String, sql: String) throws -> String? {
        // A normal sqlite3 open can create a missing database. Credential probes must be read-only and
        // side-effect free, so absence returns nil before a process is launched.
        guard try databaseExists(path) else { return nil }
        var result = try run(path: path, sql: sql, readOnly: true)
        if !result.succeeded, allowsReadWriteFallback {
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
        // SQL can contain credential values (for example Cursor's rotated access token). Keep it
        // off the process argument list, where other local processes can inspect it with `ps`.
        let result = try run(path: path, sql: sql, sendSQLOnStandardInput: true)
        guard result.succeeded else {
            throw SQLiteError.queryFailed(result.stderr)
        }
    }

    private func run(
        path: String,
        sql: String,
        readOnly: Bool = false,
        sendSQLOnStandardInput: Bool = false
    ) throws -> ProcessResult {
        var arguments = ["-batch", "-noheader"]
        if readOnly { arguments.append("-readonly") }
        arguments += [
            "-cmd", ".timeout 1000",
            expandHome(path)
        ]
        if !sendSQLOnStandardInput { arguments.append(sql) }
        return try processRunner.run(
            executable: "/usr/bin/sqlite3",
            arguments: arguments,
            environment: [:],
            standardInput: sendSQLOnStandardInput ? Data(sql.utf8) : nil,
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
    func readGenericPassword(
        service: String,
        allowInteraction: Bool,
        interactiveQueryLease: KeychainInteractiveQueryLease?
    ) throws -> String?
    func writeGenericPassword(service: String, value: String) throws
    func writeGenericPassword(service: String, account: String, value: String) throws
    func readGenericPasswordForCurrentUser(service: String) throws -> String?
    func readGenericPasswordForCurrentUser(service: String, allowInteraction: Bool) throws -> String?
    func readGenericPasswordForCurrentUser(
        service: String,
        allowInteraction: Bool,
        interactiveQueryLease: KeychainInteractiveQueryLease?
    ) throws -> String?
    func writeGenericPasswordForCurrentUser(service: String, value: String) throws
    /// Read a generic password scoped to an explicit account (`-a`). Used when another app stored the
    /// item under a known account name (e.g. Antigravity's `agy` token under service `gemini`,
    /// account `antigravity`) rather than the current user.
    func readGenericPassword(service: String, account: String) throws -> String?
    /// Account-scoped read that can suppress UI. The default (for mocks that don't model interaction)
    /// ignores the flag; the real `SecurityKeychainAccessor` overrides it with the in-process
    /// `LAContext` path, which is what keeps a scheduled refresh from opening a Keychain dialog.
    func readGenericPassword(service: String, account: String, allowInteraction: Bool) throws -> String?
    func readGenericPassword(
        service: String,
        account: String,
        allowInteraction: Bool,
        interactiveQueryLease: KeychainInteractiveQueryLease?
    ) throws -> String?
    /// Attributes-only Keychain existence probe. This must dispatch to the real Security.framework
    /// implementation rather than reading the secret through the mock fallback.
    func genericPasswordExists(service: String) -> Bool?
}

protocol SecurityKeychainItemWriting: Sendable {
    func defaultFileKeychainWriteScope() throws -> SecurityKeychainWriteScope
    func addGenericPassword(attributes: [String: Any]) -> OSStatus
    func updateGenericPassword(matching query: [String: Any], attributes: [String: Any]) -> OSStatus
}

/// An explicit context for one Security.framework query. Supplying the context even for an interactive
/// retry gives the per-load cancellation token a handle to invalidate while Keychain authentication is
/// pending; Security creates and discards an inaccessible context when this attribute is omitted.
struct KeychainAuthenticationContextLease {
    let context: LAContext
    private let cancellationToken: KeychainReadCancellationToken?
    private let interactiveQueryLease: KeychainInteractiveQueryLease?

    init(
        interactionAllowed: Bool,
        interactiveQueryLease: KeychainInteractiveQueryLease? = nil
    ) throws {
        let context = LAContext()
        context.interactionNotAllowed = !interactionAllowed
        let cancellationToken = ProviderRefreshContext.keychainReadCancellationToken
        guard !ProviderRefreshContext.credentialReadIsCancelled else {
            context.invalidate()
            throw CancellationError()
        }
        if let interactiveQueryLease,
           !KeychainPermissionGate.shared.register(context, for: interactiveQueryLease)
        {
            throw CancellationError()
        }
        if let cancellationToken, !cancellationToken.register(context) {
            if let interactiveQueryLease {
                KeychainPermissionGate.shared.unregister(context, for: interactiveQueryLease)
            }
            context.invalidate()
            throw CancellationError()
        }
        self.context = context
        self.cancellationToken = cancellationToken
        self.interactiveQueryLease = interactiveQueryLease
    }

    var mayBeginQuery: Bool {
        !ProviderRefreshContext.credentialReadIsCancelled
            && (interactiveQueryLease.map { KeychainPermissionGate.shared.isCurrent($0) } ?? true)
    }

    /// Retires the context after SecItemCopyMatching returns and reports whether cancellation happened
    /// before the query completed. Each lease is one-shot because an invalidated context is not reusable.
    func finish() -> Bool {
        let tokenAllowsResult = cancellationToken?.finish(context) ?? true
        let actionAllowsResult = interactiveQueryLease.map {
            KeychainPermissionGate.shared.finishContext(context, for: $0)
        } ?? true
        return tokenAllowsResult && actionAllowsResult && !Task<Never, Never>.isCancelled
    }
}

/// The keychain and authentication context shared by the add and duplicate-update halves of one write.
/// Keeping this scope intact ensures both operations target the same default file-based keychain and
/// neither can open authentication UI during a provider refresh.
struct SecurityKeychainWriteScope: @unchecked Sendable {
    let defaultKeychain: AnyObject
    let authenticationContext: LAContext

    var addAttributes: [String: Any] {
        [
            kSecUseKeychain as String: defaultKeychain,
            kSecUseAuthenticationContext as String: authenticationContext
        ]
    }

    var updateQueryAttributes: [String: Any] {
        [
            kSecMatchSearchList as String: [defaultKeychain] as CFArray,
            kSecUseAuthenticationContext as String: authenticationContext
        ]
    }
}

struct SecurityFrameworkKeychainWriter: SecurityKeychainItemWriting {
    func defaultFileKeychainWriteScope() throws -> SecurityKeychainWriteScope {
        // File-based SecItem writes default to this keychain. SecKeychainCopyDefault is deprecated,
        // but remains the public API for obtaining its SecKeychainRef so the duplicate-update query
        // can be constrained to exactly the same keychain. We still use SecItem for the item itself.
        var defaultKeychain: SecKeychain?
        let status = SecKeychainCopyDefault(&defaultKeychain)
        guard status == errSecSuccess else {
            throw KeychainError.writeFailed("Could not resolve default file keychain (Security.framework OSStatus \(status)).")
        }
        guard let defaultKeychain else {
            throw KeychainError.writeFailed("Security.framework returned no default file keychain.")
        }

        let authenticationContext = LAContext()
        authenticationContext.interactionNotAllowed = true
        return SecurityKeychainWriteScope(
            defaultKeychain: defaultKeychain,
            authenticationContext: authenticationContext
        )
    }

    func addGenericPassword(attributes: [String: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }

    func updateGenericPassword(matching query: [String: Any], attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }
}

extension KeychainAccessing {
    func writeGenericPassword(service: String, account: String, value: String) throws {
        _ = account
        try writeGenericPassword(service: service, value: value)
    }

    func readGenericPassword(service: String, allowInteraction: Bool) throws -> String? {
        try readGenericPassword(service: service)
    }

    func readGenericPassword(
        service: String,
        allowInteraction: Bool,
        interactiveQueryLease: KeychainInteractiveQueryLease?
    ) throws -> String? {
        if allowInteraction, let interactiveQueryLease,
           !interactiveQueryLease.markQueryStarted() {
            throw CancellationError()
        }
        return try readGenericPassword(service: service, allowInteraction: allowInteraction)
    }

    func readGenericPasswordForCurrentUser(service: String) throws -> String? {
        try readGenericPassword(service: service)
    }

    func readGenericPasswordForCurrentUser(service: String, allowInteraction: Bool) throws -> String? {
        try readGenericPasswordForCurrentUser(service: service)
    }

    func readGenericPasswordForCurrentUser(
        service: String,
        allowInteraction: Bool,
        interactiveQueryLease: KeychainInteractiveQueryLease?
    ) throws -> String? {
        if allowInteraction, let interactiveQueryLease,
           !interactiveQueryLease.markQueryStarted() {
            throw CancellationError()
        }
        return try readGenericPasswordForCurrentUser(service: service, allowInteraction: allowInteraction)
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

    func readGenericPassword(
        service: String,
        account: String,
        allowInteraction: Bool,
        interactiveQueryLease: KeychainInteractiveQueryLease?
    ) throws -> String? {
        if allowInteraction, let interactiveQueryLease,
           !interactiveQueryLease.markQueryStarted() {
            throw CancellationError()
        }
        return try readGenericPassword(service: service, account: account, allowInteraction: allowInteraction)
    }

    /// Read a generic password the way a provider refresh should: **silent first**, escalating to a
    /// Keychain dialog only when the user explicitly asked for a refresh.
    ///
    /// Every provider credential read on a refresh path should use this rather than the flagless
    /// overload, so it participates in per-item permission memory and the manual dialog budget.
    /// All production reads stay in process; `allowInteraction: false`
    /// fails fast with `KeychainError.interactionNotAllowed` instead of blocking on UI.
    ///
    /// Escalation mirrors `ClaudeAuthStore`: a silent read that proves interaction is *required* may
    /// retry with UI, but only for a manual refresh, and only once per manual action across all
    /// providers via the shared `CredentialInteractionGate` — so ⌘R opens at most one Keychain dialog
    /// no matter how many provider cards are enabled.
    /// A caller with an independent credential fallback may request a silent recheck of a previously
    /// blocked item on manual actions, so newly granted access can recover without opening a dialog.
    func readGenericPasswordForRefresh(
        service: String,
        account: String? = nil,
        allowInteraction: Bool? = nil,
        interactionGate: CredentialInteractionGate? = nil,
        bypassDeferredReadFailure: Bool = false,
        recheckBlockedSilently: Bool = false
    ) throws -> String? {
        let key = KeychainItemKey(service: service, account: account)
        let mayInteract = allowInteraction ?? ProviderRefreshContext.isManual
        let actionGate = interactionGate ?? ProviderRefreshContext.credentialInteractionGate
        return try readForRefresh(
            key,
            allowInteraction: mayInteract,
            interactionGate: actionGate,
            bypassDeferredReadFailure: bypassDeferredReadFailure,
            recheckBlockedSilently: recheckBlockedSilently && ProviderRefreshContext.isManual
        ) {
            allowInteraction, interactiveQueryLease in
            if let account {
                return try readGenericPassword(
                    service: service,
                    account: account,
                    allowInteraction: allowInteraction,
                    interactiveQueryLease: interactiveQueryLease
                )
            }
            return try readGenericPassword(
                service: service,
                allowInteraction: allowInteraction,
                interactiveQueryLease: interactiveQueryLease
            )
        }
    }

    /// Current-user-scoped variant of `readGenericPasswordForRefresh`, for items this app *writes*
    /// itself under `kSecAttrAccount` (see `writeGenericPasswordForCurrentUser`). Account scoping is
    /// part of the query, not a detail: a service-only read is a different lookup, so this must not
    /// collapse into the service-only helper.
    func readGenericPasswordForRefreshForCurrentUser(
        service: String,
        allowInteraction: Bool? = nil,
        interactionGate: CredentialInteractionGate? = nil,
        bypassDeferredReadFailure: Bool = false
    ) throws -> String? {
        let key = KeychainItemKey(service: service, account: currentUserKeychainAccount())
        let mayInteract = allowInteraction ?? ProviderRefreshContext.isManual
        let actionGate = interactionGate ?? ProviderRefreshContext.credentialInteractionGate
        return try readForRefresh(
            key,
            allowInteraction: mayInteract,
            interactionGate: actionGate,
            bypassDeferredReadFailure: bypassDeferredReadFailure
        ) {
            allowInteraction, interactiveQueryLease in
            try readGenericPasswordForCurrentUser(
                service: service,
                allowInteraction: allowInteraction,
                interactiveQueryLease: interactiveQueryLease
            )
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
    private func readForRefresh(
        _ key: KeychainItemKey,
        allowInteraction: Bool,
        interactionGate: CredentialInteractionGate?,
        bypassDeferredReadFailure: Bool = false,
        recheckBlockedSilently: Bool = false,
        _ read: (Bool, KeychainInteractiveQueryLease?) throws -> String?
    ) throws -> String? {
        guard !ProviderRefreshContext.credentialReadIsCancelled else {
            throw CancellationError()
        }
        let permissionGate = KeychainPermissionGate.shared
        let manualActionID = ProviderRefreshContext.manualActionID
        guard !permissionGate.isDeclined(key) else {
            throw KeychainError.interactionNotAllowed
        }
        if permissionGate.isBlocked(key), !allowInteraction, !recheckBlockedSilently {
            throw KeychainError.interactionNotAllowed
        }
        if !bypassDeferredReadFailure,
           permissionGate.shouldDeferFailedRead(for: key, manualActionID: manualActionID) {
            throw KeychainError.readDeferred
        }

        let observedGeneration = permissionGate.generation(for: key)
        // A prompt for this same item is already on screen. A silent probe now can only fail and
        // would spend another Security read on an item whose answer is already arriving, so wait for
        // the in-flight query instead and retry silently only if its grant cleared this item.
        if let granted = permissionGate.waitForInFlightSameItemInteractiveQuery(
            matching: key,
            manualActionID: manualActionID
        ) {
            guard !ProviderRefreshContext.credentialReadIsCancelled,
                  permissionGate.isCurrentManualAction(manualActionID)
            else { throw CancellationError() }
            guard granted else { throw KeychainError.interactionNotAllowed }
            return try retrySilently(after: permissionGate.generation(for: key))
        }
        func retrySilently(after generation: UInt64) throws -> String? {
            do {
                let value = try read(false, nil)
                guard !ProviderRefreshContext.credentialReadIsCancelled,
                      permissionGate.isCurrentManualAction(manualActionID)
                else { throw CancellationError() }
                permissionGate.reset(
                    key,
                    ifGenerationIs: generation,
                    manualActionID: manualActionID
                )
                return value
            } catch KeychainError.interactionNotAllowed {
                guard !ProviderRefreshContext.credentialReadIsCancelled,
                      permissionGate.isCurrentManualAction(manualActionID)
                else { throw CancellationError() }
                permissionGate.block(
                    key,
                    ifGenerationIs: generation,
                    manualActionID: manualActionID
                )
                throw KeychainError.interactionNotAllowed
            } catch {
                guard !ProviderRefreshContext.credentialReadIsCancelled,
                      permissionGate.isCurrentManualAction(manualActionID)
                else { throw CancellationError() }
                if let keychainError = error as? KeychainError,
                   case .invalidItemData = keychainError
                {
                    if let recoveredGeneration = permissionGate.reset(
                        key,
                        ifGenerationIs: generation,
                        manualActionID: manualActionID
                    ) {
                        permissionGate.deferFailedRead(
                            for: key,
                            ifGenerationIs: recoveredGeneration,
                            manualActionID: manualActionID
                        )
                    }
                } else if let keychainError = error as? KeychainError,
                          case .readFailed = keychainError
                {
                    permissionGate.deferFailedRead(
                        for: key,
                        ifGenerationIs: generation,
                        manualActionID: manualActionID
                    )
                }
                throw error
            }
        }
        do {
            let value = try read(false, nil)
            guard !ProviderRefreshContext.credentialReadIsCancelled else {
                throw CancellationError()
            }
            guard permissionGate.isCurrentManualAction(manualActionID) else {
                throw CancellationError()
            }
            permissionGate.reset(
                key,
                ifGenerationIs: observedGeneration,
                manualActionID: manualActionID
            )
            return value
        } catch KeychainError.interactionNotAllowed {
            // Remember it: without this every periodic refresh re-reads an item it cannot read and
            // fails again, which is the "keychain access" spam.
            permissionGate.block(
                key,
                ifGenerationIs: observedGeneration,
                manualActionID: manualActionID
            )
            guard !ProviderRefreshContext.credentialReadIsCancelled else {
                throw CancellationError()
            }
            if allowInteraction,
               permissionGate.hasSuccessfulInteractiveGrant(for: key, manualActionID: manualActionID) {
                permissionGate.reset(
                    key,
                    ifGenerationIs: observedGeneration,
                    manualActionID: manualActionID
                )
                return try retrySilently(after: permissionGate.generation(for: key))
            }
            guard allowInteraction, !permissionGate.isDeclined(key) else {
                throw KeychainError.interactionNotAllowed
            }
            let interactiveQueryClaim = permissionGate.claimInteractiveQueryResult(
                for: manualActionID,
                using: interactionGate,
                key: key
            )
            let interactiveQueryLease: KeychainInteractiveQueryLease
            switch interactiveQueryClaim {
            case .claimed(let lease):
                interactiveQueryLease = lease
            case .actionSuperseded:
                throw CancellationError()
            case .queryInFlight(let activeLease, let sameItem):
                // A sibling reading this same item can reuse the result of the one in-flight prompt.
                // Wait for its synchronous Security call to finish, then retry silently only if it
                // actually cleared this item's permission block. Different-item prompts still fail
                // closed without waiting or opening another dialog.
                guard sameItem, permissionGate.waitForSuccessfulInteractiveQuery(
                    activeLease,
                    matching: key,
                    manualActionID: manualActionID
                ) else {
                    guard !ProviderRefreshContext.credentialReadIsCancelled,
                          permissionGate.isCurrentManualAction(manualActionID)
                    else { throw CancellationError() }
                    throw KeychainError.interactionNotAllowed
                }
                guard !ProviderRefreshContext.credentialReadIsCancelled,
                      permissionGate.isCurrentManualAction(manualActionID)
                else { throw CancellationError() }
                return try retrySilently(after: permissionGate.generation(for: key))
            case .actionBudgetSpent:
                if permissionGate.hasSuccessfulInteractiveGrant(for: key, manualActionID: manualActionID)
                    || permissionGate.wasSuccessfullyUnblocked(
                        key,
                        since: observedGeneration,
                        manualActionID: manualActionID
                    ) {
                    permissionGate.reset(
                        key,
                        ifGenerationIs: observedGeneration,
                        manualActionID: manualActionID
                    )
                    return try retrySilently(after: permissionGate.generation(for: key))
                }
                // Remember that this action could not obtain the item. Without this, a second card
                // that shares the same credential would repeat the silent read after the shared
                // prompt budget had already been spent elsewhere in this action.
                permissionGate.markDeclined(key, ifGenerationIs: observedGeneration)
                throw KeychainError.interactionNotAllowed
            }
            // Keep the process-wide slot until the synchronous read closure returns. Task cancellation
            // and a newer manual action invalidate its LAContext, but neither can release this slot
            // while SecItemCopyMatching is still executing.
            defer { permissionGate.finishInteractiveQuery(interactiveQueryLease) }
            // The interactive Security.framework call can display UI. Recheck after claiming the
            // action budget so a task canceled or superseded in the meantime cannot open a stale prompt.
            guard !ProviderRefreshContext.credentialReadIsCancelled else {
                throw CancellationError()
            }
            guard permissionGate.isCurrentManualAction(manualActionID) else {
                throw CancellationError()
            }
            do {
                let value = try read(true, interactiveQueryLease)
                guard !ProviderRefreshContext.credentialReadIsCancelled else {
                    throw CancellationError()
                }
                guard permissionGate.isCurrentManualAction(manualActionID) else {
                    throw CancellationError()
                }
                permissionGate.reset(
                    key,
                    ifGenerationIs: observedGeneration,
                    manualActionID: manualActionID
                )
                guard permissionGate.markInteractiveQuerySucceeded(interactiveQueryLease) else {
                    throw CancellationError()
                }
                return value
            } catch KeychainError.interactionNotAllowed {
                guard !ProviderRefreshContext.credentialReadIsCancelled else {
                    throw CancellationError()
                }
                guard permissionGate.isCurrentManualAction(manualActionID) else {
                    throw CancellationError()
                }
                // A canceled prompt is remembered; unrelated read failures remain retryable.
                permissionGate.markDeclined(key, ifGenerationIs: observedGeneration)
                throw KeychainError.interactionNotAllowed
            } catch {
                guard !ProviderRefreshContext.credentialReadIsCancelled else {
                    throw CancellationError()
                }
                guard permissionGate.isCurrentManualAction(manualActionID) else {
                    throw CancellationError()
                }
                if let keychainError = error as? KeychainError,
                   case .invalidItemData = keychainError
                {
                    guard permissionGate.markInteractiveQuerySucceeded(interactiveQueryLease) else {
                        throw CancellationError()
                    }
                    if let recoveredGeneration = permissionGate.reset(
                        key,
                        ifGenerationIs: observedGeneration,
                        manualActionID: manualActionID
                    ) {
                        permissionGate.deferFailedRead(
                            for: key,
                            ifGenerationIs: recoveredGeneration,
                            manualActionID: manualActionID
                        )
                    }
                }
                throw error
            }
        } catch {
            guard !ProviderRefreshContext.credentialReadIsCancelled else {
                throw CancellationError()
            }
            guard permissionGate.isCurrentManualAction(manualActionID) else {
                throw CancellationError()
            }
            if let keychainError = error as? KeychainError,
               case .invalidItemData = keychainError {
                if let recoveredGeneration = permissionGate.reset(
                    key,
                    ifGenerationIs: observedGeneration,
                    manualActionID: manualActionID
                ) {
                    permissionGate.deferFailedRead(
                        for: key,
                        ifGenerationIs: recoveredGeneration,
                        manualActionID: manualActionID
                    )
                }
            } else if let keychainError = error as? KeychainError,
                      case .readFailed = keychainError
            {
                permissionGate.deferFailedRead(
                    for: key,
                    ifGenerationIs: observedGeneration,
                    manualActionID: manualActionID
                )
            }
            throw error
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
    let itemReader: SecurityKeychainItemReading
    let itemWriter: SecurityKeychainItemWriting

    init(
        itemReader: SecurityKeychainItemReading = SecurityFrameworkKeychainReader(),
        itemWriter: SecurityKeychainItemWriting = SecurityFrameworkKeychainWriter()
    ) {
        self.itemReader = itemReader
        self.itemWriter = itemWriter
    }

    func readGenericPassword(service: String) throws -> String? {
        try readGenericPassword(service: service, allowInteraction: false)
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
        let status = KeychainUserInteraction.shared.perform(allowInteraction: false) {
            itemReader.copyMatching(query, result: nil)
        }
        switch status {
        case errSecSuccess: return true
        case errSecItemNotFound: return false
        default: return nil
        }
    }

    func readGenericPasswordForCurrentUser(service: String) throws -> String? {
        try readGenericPasswordForCurrentUser(service: service, allowInteraction: false)
    }

    /// Claude uses this overload so background refreshes can read an already-authorized login while
    /// immediately returning when macOS would otherwise need to present Keychain UI.
    func readGenericPasswordForCurrentUser(service: String, allowInteraction: Bool) throws -> String? {
        try readPassword(
            service: service,
            account: currentUserKeychainAccount(),
            allowInteraction: allowInteraction,
            interactiveQueryLease: nil
        )
    }

    func readGenericPasswordForCurrentUser(
        service: String,
        allowInteraction: Bool,
        interactiveQueryLease: KeychainInteractiveQueryLease?
    ) throws -> String? {
        try readPassword(
            service: service,
            account: currentUserKeychainAccount(),
            allowInteraction: allowInteraction,
            interactiveQueryLease: interactiveQueryLease
        )
    }

    /// Service-only fallback used by older Claude Code Keychain entries.
    func readGenericPassword(service: String, allowInteraction: Bool) throws -> String? {
        try readPassword(
            service: service,
            account: nil,
            allowInteraction: allowInteraction,
            interactiveQueryLease: nil
        )
    }

    func readGenericPassword(
        service: String,
        allowInteraction: Bool,
        interactiveQueryLease: KeychainInteractiveQueryLease?
    ) throws -> String? {
        try readPassword(
            service: service,
            account: nil,
            allowInteraction: allowInteraction,
            interactiveQueryLease: interactiveQueryLease
        )
    }

    func readGenericPassword(service: String, account: String) throws -> String? {
        try readGenericPassword(service: service, account: account, allowInteraction: false)
    }

    /// Account-scoped read that can suppress UI, matching the two service-scoped overloads. Without
    /// this, the only account-scoped path was the `security` subprocess, so a provider reading another
    /// app's item (Antigravity's `agy` token) had no way to stay silent on a scheduled refresh.
    func readGenericPassword(service: String, account: String, allowInteraction: Bool) throws -> String? {
        try readPassword(
            service: service,
            account: account,
            allowInteraction: allowInteraction,
            interactiveQueryLease: nil
        )
    }

    func readGenericPassword(
        service: String,
        account: String,
        allowInteraction: Bool,
        interactiveQueryLease: KeychainInteractiveQueryLease?
    ) throws -> String? {
        try readPassword(
            service: service,
            account: account,
            allowInteraction: allowInteraction,
            interactiveQueryLease: interactiveQueryLease
        )
    }

    private func readPassword(
        service: String,
        account: String?,
        allowInteraction: Bool,
        interactiveQueryLease: KeychainInteractiveQueryLease?
    ) throws -> String? {
        let itemKey = KeychainItemKey(service: service, account: account)
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
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }
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
            // A query may have waited behind another provider's prompt; cancellation must be
            // checked again after acquiring the process-wide interaction lock.
            guard authenticationContext.mayBeginQuery else { return errSecUserCanceled }
            return itemReader.copyMatching(query, result: &result)
        }
        guard authenticationContext.finish() else { throw CancellationError() }
        let permissionGate = KeychainPermissionGate.shared
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let value = String(data: data, encoding: .utf8)
            else {
                throw KeychainError.invalidItemData("Keychain item is not UTF-8 text.")
            }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                missingItems.markMissing(for: itemKey)
                return nil
            }
            missingItems.markPresent(itemKey)
            return trimmed
        case errSecItemNotFound:
            missingItems.markMissing(for: itemKey)
            return nil
        case errSecInteractionNotAllowed, errSecInteractionRequired, errSecAuthFailed, errSecUserCanceled:
            // Previously silent. This is the single most important Keychain diagnostic: it is what a
            // provider needs to say "macOS needs permission" instead of "not logged in", and with no
            // line here a misclassified provider left no trace anywhere except the in-memory gate.
            // Not a warning: refusing to release an item the app does not own is an expected answer,
            // and the user is the one who has to act on it.
            if permissionGate.shouldLogInteractionRefusal(for: itemKey) {
                AppLog.info(
                    .keychain,
                    "silent read needs user interaction (service \(service.debugDescription), OSStatus \(status))"
                )
            }
            throw KeychainError.interactionNotAllowed
        default:
            // Provider-agnostic on purpose: this accessor is shared, so naming one provider here
            // misattributed every other provider's failure to Claude.
            if permissionGate.shouldLogReadFailure(for: itemKey, status: status) {
                AppLog.warn(.keychain, "credential read failed (Security.framework OSStatus \(status))")
            }
            throw KeychainError.readFailed("Security.framework OSStatus \(status)")
        }
    }

    func writeGenericPassword(service: String, value: String) throws {
        try writePassword(service: service, account: currentUserKeychainAccount(), value: value)
    }

    func writeGenericPassword(service: String, account: String, value: String) throws {
        try writePassword(service: service, account: account, value: value)
    }

    func writeGenericPasswordForCurrentUser(service: String, value: String) throws {
        try writePassword(service: service, account: currentUserKeychainAccount(), value: value)
    }

    private func writePassword(service: String, account: String, value: String) throws {
        let scope = try itemWriter.defaultFileKeychainWriteScope()
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let secret = Data(value.utf8)
        var attributes = identity.merging(scope.addAttributes) { _, scoped in scoped }
        attributes[kSecValueData as String] = secret

        let addStatus = KeychainUserInteraction.shared.perform(allowInteraction: false) {
            itemWriter.addGenericPassword(attributes: attributes)
        }
        guard addStatus != errSecDuplicateItem else {
            let updateQuery = identity.merging(scope.updateQueryAttributes) { _, scoped in scoped }
            let updateStatus = KeychainUserInteraction.shared.perform(allowInteraction: false) {
                itemWriter.updateGenericPassword(
                    matching: updateQuery,
                    attributes: [kSecValueData as String: secret]
                )
            }
            guard updateStatus == errSecSuccess else { throw writeError(status: updateStatus) }
            KeychainMissingItemCache.shared.markPresent(KeychainItemKey(service: service, account: account))
            return
        }
        guard addStatus == errSecSuccess else { throw writeError(status: addStatus) }
        KeychainMissingItemCache.shared.markPresent(KeychainItemKey(service: service, account: account))
    }

    private func writeError(status: OSStatus) -> KeychainError {
        if status == errSecInteractionNotAllowed || status == errSecInteractionRequired {
            return .interactionNotAllowed
        }
        return .writeFailed("Security.framework OSStatus \(status)")
    }
}

func currentUserKeychainAccount() -> String {
    ProcessInfo.processInfo.environment["USER"]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    ?? NSUserName()
}

enum KeychainError: Error, LocalizedError {
    case interactionNotAllowed
    case writeFailed(String)
    case readFailed(String)
    case invalidItemData(String)
    case readDeferred

    var errorDescription: String? {
        switch self {
        case .interactionNotAllowed:
            return "Keychain access requires user interaction."
        case .writeFailed(let message):
            return message.isEmpty ? "Keychain write failed." : message
        case .readFailed(let message):
            return message.isEmpty ? "Keychain read failed." : message
        case .invalidItemData(let message):
            return message.isEmpty ? "Keychain item data is invalid." : message
        case .readDeferred:
            return "A recent Keychain read failed; retry manually or wait before trying again."
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
/// ACL, and two different items in the same app routinely differ. `account` is part of the key
/// because it is part of the query. A service-only lookup remains distinct, while a current-user
/// lookup is normalized to its account value so it shares state with the equivalent explicit query.
struct KeychainItemKey: Hashable, Sendable {
    let service: String
    let account: String?

    init(service: String, account: String? = nil) {
        self.service = service
        self.account = account
    }
}

/// Avoid repeating Security queries for absent optional credentials on every background refresh.
/// Absence is cached briefly; explicit manual refreshes and interactive reads always recheck it.
final class KeychainMissingItemCache: @unchecked Sendable {
    static let shared = KeychainMissingItemCache()

    private let lock = NSLock()
    private let ttl: TimeInterval
    private var expirationByKey: [KeychainItemKey: TimeInterval] = [:]

    init(ttl: TimeInterval = 30) {
        self.ttl = max(ttl, 0)
    }

    func shouldSkipRead(
        for key: KeychainItemKey,
        manualActionID: UInt64? = nil,
        allowsInteraction: Bool = false,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let expiration = expirationByKey[key], expiration <= now {
            expirationByKey.removeValue(forKey: key)
            return false
        }
        // Bypassing a cached miss starts a real recheck, but does not erase the old result before
        // that query returns. If cancellation wins before a result, the next background refresh
        // should still be able to use the negative entry.
        if manualActionID != nil || allowsInteraction { return false }
        return expirationByKey[key] != nil
    }

    func markMissing(
        for key: KeychainItemKey,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        lock.lock()
        expirationByKey[key] = now + ttl
        lock.unlock()
    }

    func markPresent(_ key: KeychainItemKey) {
        lock.lock()
        expirationByKey.removeValue(forKey: key)
        lock.unlock()
    }

    func resetAll() {
        lock.lock()
        expirationByKey.removeAll()
        lock.unlock()
    }
}

/// Owns the process-wide slot for one interactive Security.framework query. It remains active until
/// the synchronous `SecItemCopyMatching` call returns, even if its LAContext is invalidated first.
struct KeychainInteractiveQueryLease: Sendable, Hashable {
    fileprivate let id: UUID
    fileprivate let manualActionID: UInt64
    fileprivate let key: KeychainItemKey?

    /// Confirms that the interactive Security query is about to start. Finishing an unstarted lease
    /// returns the still-unused prompt budget to the action's other provider reads.
    func markQueryStarted() -> Bool {
        KeychainPermissionGate.shared.markInteractiveQueryStarted(self)
    }
}

enum KeychainInteractiveQueryClaim {
    case claimed(KeychainInteractiveQueryLease)
    case actionSuperseded
    case queryInFlight(KeychainInteractiveQueryLease, sameItem: Bool)
    case actionBudgetSpent
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
/// Keyed by [`KeychainItemKey`] so block and reset both stay scoped to the item that earned them. It also
/// owns one process-wide interactive-query lease so overlapping manual actions cannot stack prompts.
final class KeychainPermissionGate: @unchecked Sendable {
    static let shared = KeychainPermissionGate()

    private struct ReadFailure: Hashable {
        let key: KeychainItemKey
        let status: OSStatus
    }

    private struct DeferredReadFailure {
        let retryAfter: Date
        let manualActionID: UInt64?
    }

    private let invalidateContext: @Sendable (LAContext) -> Void

    init(invalidateContext: @escaping @Sendable (LAContext) -> Void = { $0.invalidate() }) {
        self.invalidateContext = invalidateContext
    }
    private let lock = NSCondition()
    private var blocked: Set<KeychainItemKey> = []
    private var generations: [KeychainItemKey: UInt64] = [:]
    /// Identity of the latest explicit refresh action, including actions whose detached reads have
    /// not reached a Keychain item yet.
    private var latestManualActionID: UInt64 = 0
    private struct ActiveInteractiveQuery {
        let lease: KeychainInteractiveQueryLease
        var context: LAContext?
        let interactionGate: CredentialInteractionGate?
        var queryStarted: Bool
        var succeeded: Bool
    }
    /// Only one interactive Security call may be in flight across all manual actions and providers.
    private var activeInteractiveQuery: ActiveInteractiveQuery?
    private var interactiveQueryWaiterCount = 0
    private var registeredInteractiveWaiters: [UUID: Int] = [:]
    private var completedInteractiveQueryResults: [UUID: Bool] = [:]
    private var successfulInteractiveItems: Set<KeychainItemKey> = []
    /// Items whose interactive read was declined during one manual refresh action.
    ///
    /// This prevents duplicate provider tasks in that same action from asking again. Background passes
    /// remain blocked until a later explicit action, which clears this set once and grants one new
    /// shared prompt budget.
    private var declined: Set<KeychainItemKey> = []
    /// Keep repeated refresh attempts from filling the diagnostic log with the same persistent
    /// Security.framework answer. A successful or missing-item result clears the entry so a later
    /// regression is visible again.
    private var loggedInteractionRefusals: Set<KeychainItemKey> = []
    private var loggedReadFailures: Set<ReadFailure> = []
    /// Generic Security failures remain retryable, but are not queried on every background tick or
    /// repeated in another phase of the same manual action when a provider has another credential source.
    private var deferredReadFailures: [KeychainItemKey: DeferredReadFailure] = [:]
    private static let failedReadRetryDelay: TimeInterval = 15 * 60

    func shouldLogInteractionRefusal(for key: KeychainItemKey) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return loggedInteractionRefusals.insert(key).inserted
    }

    func shouldLogReadFailure(for key: KeychainItemKey, status: OSStatus) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return loggedReadFailures.insert(ReadFailure(key: key, status: status)).inserted
    }

    func shouldDeferFailedRead(
        for key: KeychainItemKey,
        manualActionID: UInt64?,
        now: Date = Date()
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let failure = deferredReadFailures[key] else { return false }
        guard failure.retryAfter > now else {
            deferredReadFailures.removeValue(forKey: key)
            return false
        }
        // A deliberate new action retries an older failure, but a multi-phase refresh must not
        // immediately repeat the same failed Security query in its history follow-up.
        if let manualActionID {
            return failure.manualActionID == manualActionID
        }
        return true
    }

    func deferFailedRead(
        for key: KeychainItemKey,
        ifGenerationIs expected: UInt64,
        manualActionID: UInt64?,
        now: Date = Date()
    ) {
        lock.lock()
        let actionIsCurrent = manualActionID == nil || latestManualActionID == manualActionID
        if actionIsCurrent, generations[key, default: 0] == expected {
            deferredReadFailures[key] = DeferredReadFailure(
                retryAfter: now.addingTimeInterval(Self.failedReadRetryDelay),
                manualActionID: manualActionID
            )
        }
        lock.unlock()
    }

    /// Whether this manual action has already failed to obtain the item.
    func isDeclined(_ key: KeychainItemKey) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return declined.contains(key)
    }

    /// Records that this action did not obtain the item, so sibling tasks do not retry it.
    func markDeclined(_ key: KeychainItemKey) {
        lock.lock()
        declined.insert(key)
        lock.unlock()
    }

    /// A new explicit Refresh is a deliberate retry. Clear the previous action's per-item declines;
    /// the fresh shared interaction budget still caps this action at one dialog across all providers.
    @discardableResult
    func beginManualAction() -> UInt64 {
        lock.lock()
        latestManualActionID &+= 1
        declined.removeAll()
        successfulInteractiveItems.removeAll()
        // In-flight reads from an older action may finish after the new Refresh starts. Advance every
        // item already observed by the gate so an old cancellation/failure cannot restore stale state.
        for key in Array(generations.keys) {
            generations[key, default: 0] &+= 1
        }
        let actionID = latestManualActionID
        let supersededContext = activeInteractiveQuery?.context
        lock.broadcast()
        lock.unlock()
        // Retire a stale prompt, but keep its query lease occupied until SecItemCopyMatching returns.
        // Invalidation is not a reliable signal that Security has stopped using the context.
        if let supersededContext { invalidateContext(supersededContext) }
        return actionID
    }

    func isCurrentManualAction(_ actionID: UInt64?) -> Bool {
        guard let actionID else { return true }
        lock.lock()
        defer { lock.unlock() }
        return latestManualActionID == actionID
    }

    /// Validates the action, spends its per-action budget, and reserves the process-wide interactive
    /// query slot under the same lock. A newer action cannot start a second Security call while an old
    /// synchronous call is still in flight.
    func claimInteractiveQuery(
        for actionID: UInt64?,
        using interactionGate: CredentialInteractionGate?
    ) -> KeychainInteractiveQueryLease? {
        guard case .claimed(let lease) = claimInteractiveQueryResult(
            for: actionID,
            using: interactionGate
        ) else { return nil }
        return lease
    }

    func claimInteractiveQueryResult(
        for actionID: UInt64?,
        using interactionGate: CredentialInteractionGate?,
        key: KeychainItemKey? = nil
    ) -> KeychainInteractiveQueryClaim {
        lock.lock()
        defer { lock.unlock() }
        while true {
            if let actionID, latestManualActionID != actionID {
                return .actionSuperseded
            }
            if let activeInteractiveQuery {
                // A sibling must not be denied while the current lease is still doing cancellable
                // setup. Wait until it either enters Security.framework (then no second prompt may
                // start) or finishes without starting (then its unused budget is returned).
                if activeInteractiveQuery.queryStarted {
                    let lease = activeInteractiveQuery.lease
                    let sameItem = key != nil && lease.key == key
                    if sameItem {
                        registeredInteractiveWaiters[lease.id, default: 0] += 1
                    }
                    return .queryInFlight(lease, sameItem: sameItem)
                }
                interactiveQueryWaiterCount += 1
                lock.wait()
                interactiveQueryWaiterCount -= 1
                continue
            }
            guard interactionGate?.claim() ?? true else { return .actionBudgetSpent }
            let lease = KeychainInteractiveQueryLease(
                id: UUID(),
                manualActionID: latestManualActionID,
                key: key
            )
            activeInteractiveQuery = ActiveInteractiveQuery(
                lease: lease,
                context: nil,
                interactionGate: interactionGate,
                queryStarted: false,
                succeeded: false
            )
            return .claimed(lease)
        }
    }

    func markInteractiveQueryStarted(_ lease: KeychainInteractiveQueryLease) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard activeInteractiveQuery?.lease == lease,
              latestManualActionID == lease.manualActionID
        else { return false }
        activeInteractiveQuery?.queryStarted = true
        lock.broadcast()
        return true
    }

    /// Registers the context atomically with the active lease and current action. If a newer manual
    /// action already superseded this query, reject the context before it reaches Security.framework.
    func register(_ context: LAContext, for lease: KeychainInteractiveQueryLease) -> Bool {
        lock.lock()
        guard activeInteractiveQuery?.lease == lease,
              latestManualActionID == lease.manualActionID
        else {
            lock.unlock()
            invalidateContext(context)
            return false
        }
        activeInteractiveQuery?.context = context
        lock.unlock()
        return true
    }

    func unregister(_ context: LAContext, for lease: KeychainInteractiveQueryLease) {
        lock.lock()
        if activeInteractiveQuery?.lease == lease,
           let registeredContext = activeInteractiveQuery?.context,
           registeredContext === context {
            activeInteractiveQuery?.context = nil
        }
        lock.unlock()
    }

    func isCurrent(_ lease: KeychainInteractiveQueryLease) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeInteractiveQuery?.lease == lease
            && latestManualActionID == lease.manualActionID
    }

    /// Clears a completed context but keeps the process slot held until the caller retires the query
    /// lease after the Security call has fully returned.
    func finishContext(_ context: LAContext, for lease: KeychainInteractiveQueryLease) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard activeInteractiveQuery?.lease == lease else { return false }
        if let registeredContext = activeInteractiveQuery?.context,
           registeredContext === context {
            activeInteractiveQuery?.context = nil
        }
        return latestManualActionID == lease.manualActionID
    }

    func finishInteractiveQuery(_ lease: KeychainInteractiveQueryLease) {
        lock.lock()
        if activeInteractiveQuery?.lease == lease {
            if registeredInteractiveWaiters[lease.id, default: 0] > 0 {
                completedInteractiveQueryResults[lease.id] = activeInteractiveQuery?.succeeded ?? false
            }
            if activeInteractiveQuery?.queryStarted == false {
                // Return the unused action budget before exposing the process slot as free. A
                // sibling must not observe an empty slot while the old claim still looks spent.
                activeInteractiveQuery?.interactionGate?.releaseClaim()
            }
            activeInteractiveQuery = nil
            lock.broadcast()
        }
        lock.unlock()
    }

    func markInteractiveQuerySucceeded(_ lease: KeychainInteractiveQueryLease) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard activeInteractiveQuery?.lease == lease,
              latestManualActionID == lease.manualActionID else { return false }
        activeInteractiveQuery?.succeeded = true
        if let key = lease.key {
            successfulInteractiveItems.insert(key)
        }
        return true
    }

    func hasSuccessfulInteractiveGrant(
        for key: KeychainItemKey,
        manualActionID: UInt64?
    ) -> Bool {
        // A grant belongs to the explicit action that earned it. A reader with no action identity
        // (a background pass) has no claim on it, and neither does a later action — the grant memory
        // would otherwise outlive the prompt that produced it and hand a silent retry to a reader
        // that never saw that dialog.
        guard let manualActionID else { return false }
        lock.lock()
        defer { lock.unlock() }
        return latestManualActionID == manualActionID
            && successfulInteractiveItems.contains(key)
    }

    func isBlocked(_ key: KeychainItemKey) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return blocked.contains(key)
    }

    /// Synchronization point for the regression that proves an unstarted lease wakes its sibling.
    func interactiveQueryWaiterCountForTesting() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return interactiveQueryWaiterCount
    }

    /// Waits for one already-started interactive query on the same item. Its result is retained only
    /// while registered siblings need it, so a fast completion cannot race the silent retry. Timed
    /// waits let cancellation be observed even when Security.framework keeps a prompt open.
    func waitForSuccessfulInteractiveQuery(
        _ lease: KeychainInteractiveQueryLease,
        matching key: KeychainItemKey,
        manualActionID: UInt64?
    ) -> Bool {
        lock.lock()
        guard lease.key == key,
              registeredInteractiveWaiters[lease.id, default: 0] > 0 else {
            lock.unlock()
            return false
        }
        return waitForInteractiveLease(lease, matching: key, manualActionID: manualActionID)
    }

    /// Same wait, but for a caller that has not claimed anything yet: it registers as a waiter for
    /// the query already on screen for this item. Returns `nil` when no such query is in flight, so
    /// the caller can fall back to its own silent read.
    ///
    /// Only a prompt owned by the caller's own action is reusable. A newer action must fail closed
    /// rather than wait behind the older prompt it just superseded.
    func waitForInFlightSameItemInteractiveQuery(
        matching key: KeychainItemKey,
        manualActionID: UInt64?
    ) -> Bool? {
        lock.lock()
        guard let active = activeInteractiveQuery,
              active.queryStarted,
              active.lease.key == key,
              manualActionID == nil || active.lease.manualActionID == manualActionID
        else {
            lock.unlock()
            return nil
        }
        let lease = active.lease
        registeredInteractiveWaiters[lease.id, default: 0] += 1
        return waitForInteractiveLease(lease, matching: key, manualActionID: manualActionID)
    }

    /// Caller holds the lock and has registered as a waiter for `lease`. Waits until the query
    /// leaves the process slot, then reports whether it granted this item.
    private func waitForInteractiveLease(
        _ lease: KeychainInteractiveQueryLease,
        matching key: KeychainItemKey,
        manualActionID: UInt64?
    ) -> Bool {
        interactiveQueryWaiterCount += 1
        defer {
            interactiveQueryWaiterCount -= 1
            let remaining = registeredInteractiveWaiters[lease.id, default: 1] - 1
            if remaining <= 0 {
                registeredInteractiveWaiters.removeValue(forKey: lease.id)
                completedInteractiveQueryResults.removeValue(forKey: lease.id)
            } else {
                registeredInteractiveWaiters[lease.id] = remaining
            }
            lock.unlock()
        }
        while activeInteractiveQuery?.lease == lease {
            let actionIsCurrent = manualActionID == nil || latestManualActionID == manualActionID
            guard actionIsCurrent,
                  latestManualActionID == lease.manualActionID,
                  !ProviderRefreshContext.credentialReadIsCancelled else {
                return false
            }
            _ = lock.wait(until: Date(timeIntervalSinceNow: 0.05))
        }
        let actionIsCurrent = manualActionID == nil || latestManualActionID == manualActionID
        return actionIsCurrent
            && latestManualActionID == lease.manualActionID
            && !ProviderRefreshContext.credentialReadIsCancelled
            && completedInteractiveQueryResults[lease.id] == true
            && !blocked.contains(key)
    }

    func generation(for key: KeychainItemKey) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let value = generations[key, default: 0]
        generations[key] = value
        return value
    }

    func wasSuccessfullyUnblocked(
        _ key: KeychainItemKey,
        since generation: UInt64,
        manualActionID: UInt64?
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let actionIsCurrent = manualActionID == nil || latestManualActionID == manualActionID
        return actionIsCurrent
            && generations[key, default: 0] != generation
            && !blocked.contains(key)
    }

    func block(
        _ key: KeychainItemKey,
        ifGenerationIs expected: UInt64,
        manualActionID: UInt64? = nil
    ) {
        lock.lock()
        let actionIsCurrent = manualActionID == nil || latestManualActionID == manualActionID
        if actionIsCurrent, generations[key, default: 0] == expected {
            blocked.insert(key)
        }
        lock.unlock()
    }

    /// Clears the block for one item, leaving every other item's state untouched.
    func reset(_ key: KeychainItemKey) {
        lock.lock()
        blocked.remove(key)
        declined.remove(key)
        deferredReadFailures.removeValue(forKey: key)
        loggedInteractionRefusals.remove(key)
        loggedReadFailures = Set(loggedReadFailures.filter { $0.key != key })
        generations[key, default: 0] &+= 1
        lock.unlock()
    }

    /// Reset only when this read still owns the generation and manual action it observed. A late
    /// result from an older load cannot erase a newer action's blocked/declined state.
    @discardableResult
    func reset(
        _ key: KeychainItemKey,
        ifGenerationIs expected: UInt64,
        manualActionID: UInt64?
    ) -> UInt64? {
        lock.lock()
        let actionIsCurrent = manualActionID == nil || latestManualActionID == manualActionID
        var resetGeneration: UInt64?
        if actionIsCurrent, generations[key, default: 0] == expected {
            blocked.remove(key)
            declined.remove(key)
            deferredReadFailures.removeValue(forKey: key)
            loggedInteractionRefusals.remove(key)
            loggedReadFailures = Set(loggedReadFailures.filter { $0.key != key })
            generations[key, default: 0] &+= 1
            resetGeneration = generations[key]
        }
        lock.unlock()
        return resetGeneration
    }

    func markDeclined(_ key: KeychainItemKey, ifGenerationIs expected: UInt64) {
        lock.lock()
        if generations[key, default: 0] == expected {
            blocked.insert(key)
            declined.insert(key)
        }
        lock.unlock()
    }

    /// Clears every item. Test-support only: production has no reason to forget an item's ACL.
    func resetAll() {
        lock.lock()
        blocked.removeAll()
        generations.removeAll()
        declined.removeAll()
        deferredReadFailures.removeAll()
        loggedInteractionRefusals.removeAll()
        loggedReadFailures.removeAll()
        registeredInteractiveWaiters.removeAll()
        completedInteractiveQueryResults.removeAll()
        successfulInteractiveItems.removeAll()
        let context = activeInteractiveQuery?.context
        if activeInteractiveQuery?.queryStarted == false {
            activeInteractiveQuery?.interactionGate?.releaseClaim()
        }
        activeInteractiveQuery = nil
        lock.broadcast()
        lock.unlock()
        if let context { invalidateContext(context) }
    }
}
