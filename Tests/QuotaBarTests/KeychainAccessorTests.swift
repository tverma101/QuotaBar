import XCTest
import LocalAuthentication
import Security
@testable import QuotaBar

final class KeychainAccessorTests: XCTestCase {
    /// Returns a fixed `ProcessResult` for any invocation — lets us drive the accessor's exit-code
    /// handling without a real `security` subprocess.
    private struct StubRunner: ProcessRunning {
        let result: ProcessResult
        func run(executable: String, arguments: [String], environment: [String: String], timeout: TimeInterval) throws -> ProcessResult {
            result
        }
    }

    private final class ContextInvalidationRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var invalidatedContextIDs: Set<ObjectIdentifier> = []

        func record(_ context: LAContext) {
            lock.lock()
            invalidatedContextIDs.insert(ObjectIdentifier(context))
            lock.unlock()
        }

        func contains(_ context: LAContext) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return invalidatedContextIDs.contains(ObjectIdentifier(context))
        }
    }

    private final class RecordingWriter: SecurityKeychainItemWriting, @unchecked Sendable {
        let addStatus: OSStatus
        let updateStatus: OSStatus
        let defaultKeychain = NSObject()
        let authenticationContext: LAContext
        let defaultScopeStatus: OSStatus?
        private(set) var addedAttributes: [String: Any]?
        private(set) var updateQuery: [String: Any]?
        private(set) var updatedAttributes: [String: Any]?
        private(set) var scopeCalls = 0

        init(
            addStatus: OSStatus,
            updateStatus: OSStatus = errSecSuccess,
            defaultScopeStatus: OSStatus? = nil
        ) {
            self.addStatus = addStatus
            self.updateStatus = updateStatus
            self.defaultScopeStatus = defaultScopeStatus
            let context = LAContext()
            context.interactionNotAllowed = true
            authenticationContext = context
        }

        func defaultFileKeychainWriteScope() throws -> SecurityKeychainWriteScope {
            scopeCalls += 1
            if let defaultScopeStatus {
                throw KeychainError.writeFailed("Could not resolve default file keychain (OSStatus \(defaultScopeStatus)).")
            }
            return SecurityKeychainWriteScope(
                defaultKeychain: defaultKeychain,
                authenticationContext: authenticationContext
            )
        }

        func addGenericPassword(attributes: [String: Any]) -> OSStatus {
            addedAttributes = attributes
            return addStatus
        }

        func updateGenericPassword(matching query: [String: Any], attributes: [String: Any]) -> OSStatus {
            updateQuery = query
            updatedAttributes = attributes
            return updateStatus
        }
    }

    private final class RecordingRunner: ProcessRunning, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls = 0
        var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }

        func run(executable: String, arguments: [String], environment: [String: String], timeout: TimeInterval) throws -> ProcessResult {
            lock.lock(); _calls += 1; lock.unlock()
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        }
    }

    func testCancellationInvalidatesARegisteredKeychainContext() {
        let invalidations = ContextInvalidationRecorder()
        let token = KeychainReadCancellationToken(invalidateContext: invalidations.record)
        let context = LAContext()

        XCTAssertTrue(token.register(context))
        token.cancel()

        XCTAssertTrue(token.isCancelled)
        XCTAssertTrue(invalidations.contains(context))
        XCTAssertFalse(token.finish(context), "cancellation must win over a later query completion")
    }

    func testContextRegisteredAfterCancellationIsInvalidatedBeforeUse() {
        let invalidations = ContextInvalidationRecorder()
        let token = KeychainReadCancellationToken(invalidateContext: invalidations.record)
        let context = LAContext()

        token.cancel()

        XCTAssertFalse(token.register(context), "a late context must never be passed to Security.framework")
        XCTAssertTrue(invalidations.contains(context))
    }

    func testNewManualActionInvalidatesButDoesNotReleaseInFlightInteractiveLease() throws {
        let invalidations = ContextInvalidationRecorder()
        let gate = KeychainPermissionGate(invalidateContext: invalidations.record)
        let firstActionID = gate.beginManualAction()
        let firstLease = try XCTUnwrap(
            gate.claimInteractiveQuery(for: firstActionID, using: CredentialInteractionGate())
        )
        let activeContext = LAContext()
        XCTAssertTrue(gate.register(activeContext, for: firstLease))
        XCTAssertTrue(gate.markInteractiveQueryStarted(firstLease), "the fixture must model an in-flight Security query")

        let secondActionID = gate.beginManualAction()
        XCTAssertTrue(invalidations.contains(activeContext), "a newer action should invalidate the older prompt context")
        XCTAssertFalse(gate.isCurrent(firstLease))

        let lateContext = LAContext()
        XCTAssertFalse(gate.register(lateContext, for: firstLease), "a superseded action must not attach a context")
        XCTAssertTrue(invalidations.contains(lateContext))
        XCTAssertNil(
            gate.claimInteractiveQuery(for: secondActionID, using: CredentialInteractionGate()),
            "invalidating a context must not release the slot while its synchronous query is in flight"
        )

        gate.finishInteractiveQuery(firstLease)
        let secondLease = try XCTUnwrap(
            gate.claimInteractiveQuery(for: secondActionID, using: CredentialInteractionGate())
        )
        gate.finishInteractiveQuery(secondLease)
    }

    func testKeychainQueryLeaseUsesExplicitSilentAndInteractiveContexts() throws {
        let token = KeychainReadCancellationToken(invalidateContext: { _ in })
        try ProviderRefreshContext.$keychainReadCancellationToken.withValue(token) {
            let silent = try KeychainAuthenticationContextLease(interactionAllowed: false)
            XCTAssertTrue(silent.context.interactionNotAllowed)
            XCTAssertTrue(silent.finish())

            let interactive = try KeychainAuthenticationContextLease(interactionAllowed: true)
            XCTAssertFalse(interactive.context.interactionNotAllowed)
            XCTAssertTrue(interactive.finish())
        }
    }

    func testItemNotFoundExitReturnsNil() throws {
        // Exit 44 (errSecItemNotFound) is the legitimate "no credential stored" case → nil.
        let accessor = SecurityKeychainAccessor(processRunner: StubRunner(
            result: ProcessResult(exitCode: 44, stdout: "", stderr: "The specified item could not be found in the keychain.")
        ))
        XCTAssertNil(try accessor.readGenericPassword(service: "Test"))
    }

    func testNonItemNotFoundFailureThrowsReadFailed() {
        // A non-44 non-zero exit (locked keychain / access denied / cancelled unlock) must throw, not
        // collapse into the same nil as "no credential" — otherwise it gets mislabeled "not signed in".
        let accessor = SecurityKeychainAccessor(processRunner: StubRunner(
            result: ProcessResult(exitCode: 51, stdout: "", stderr: "User interaction is not allowed.")
        ))
        XCTAssertThrowsError(try accessor.readGenericPassword(service: "Test")) { error in
            guard case KeychainError.readFailed = error else {
                return XCTFail("expected KeychainError.readFailed, got \(error)")
            }
        }
    }

    func testFoundValueIsReturnedTrimmed() throws {
        let accessor = SecurityKeychainAccessor(processRunner: StubRunner(
            result: ProcessResult(exitCode: 0, stdout: "secret-token\n", stderr: "")
        ))
        XCTAssertEqual(try accessor.readGenericPassword(service: "Test"), "secret-token")
    }

    func testWritesCredentialInProcessWithExplicitAccount() throws {
        let writer = RecordingWriter(addStatus: errSecSuccess)
        let runner = RecordingRunner()
        let accessor = SecurityKeychainAccessor(processRunner: runner, itemWriter: writer)

        try accessor.writeGenericPassword(service: "Codex Auth", account: "cli|profile", value: "secret-token")

        let attributes = try XCTUnwrap(writer.addedAttributes)
        XCTAssertEqual(attributes[kSecClass as String] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(attributes[kSecAttrService as String] as? String, "Codex Auth")
        XCTAssertEqual(attributes[kSecAttrAccount as String] as? String, "cli|profile")
        XCTAssertTrue((attributes[kSecUseKeychain as String] as AnyObject?) === writer.defaultKeychain)
        XCTAssertTrue((attributes[kSecUseAuthenticationContext as String] as? LAContext) === writer.authenticationContext)
        XCTAssertTrue(writer.authenticationContext.interactionNotAllowed)
        XCTAssertEqual(
            String(data: try XCTUnwrap(attributes[kSecValueData as String] as? Data), encoding: .utf8),
            "secret-token"
        )
        XCTAssertEqual(runner.calls, 0, "credential material must not pass through process arguments")
        XCTAssertEqual(writer.scopeCalls, 1)
        XCTAssertNil(writer.updateQuery)
    }

    func testDuplicateCredentialWriteUpdatesTheSameItem() throws {
        let writer = RecordingWriter(addStatus: errSecDuplicateItem)
        let accessor = SecurityKeychainAccessor(itemWriter: writer)

        try accessor.writeGenericPassword(service: "Cursor Token", value: "rotated-secret")

        let query = try XCTUnwrap(writer.updateQuery)
        XCTAssertEqual(query[kSecClass as String] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(query[kSecAttrService as String] as? String, "Cursor Token")
        XCTAssertEqual(query[kSecAttrAccount as String] as? String, currentUserKeychainAccount())
        let searchList = try XCTUnwrap(query[kSecMatchSearchList as String] as? NSArray)
        XCTAssertEqual(searchList.count, 1, "updates must search only the default file keychain")
        XCTAssertTrue((searchList.firstObject as AnyObject?) === writer.defaultKeychain)
        XCTAssertTrue((query[kSecUseAuthenticationContext as String] as? LAContext) === writer.authenticationContext)
        XCTAssertTrue(writer.authenticationContext.interactionNotAllowed, "credential writes must never open authentication UI")
        XCTAssertTrue((writer.addedAttributes?[kSecUseKeychain as String] as AnyObject?) === writer.defaultKeychain)
        XCTAssertEqual(
            String(data: try XCTUnwrap(writer.updatedAttributes?[kSecValueData as String] as? Data), encoding: .utf8),
            "rotated-secret"
        )
        XCTAssertEqual(writer.updatedAttributes?.count, 1, "the update changes only the secret data")
    }

    func testWriteThatRequiresInteractionReturnsTypedErrorWithoutRetryingInteractively() {
        let writer = RecordingWriter(addStatus: errSecInteractionNotAllowed)
        let accessor = SecurityKeychainAccessor(itemWriter: writer)

        XCTAssertThrowsError(try accessor.writeGenericPassword(service: "Codex Auth", value: "rotated-secret")) { error in
            guard case KeychainError.interactionNotAllowed = error else {
                return XCTFail("expected typed interaction error, got \(error)")
            }
        }
        XCTAssertTrue(writer.authenticationContext.interactionNotAllowed)
        XCTAssertNil(writer.updateQuery)
    }

    func testDuplicateWriteThatRequiresInteractionReturnsTypedError() {
        let writer = RecordingWriter(addStatus: errSecDuplicateItem, updateStatus: errSecInteractionNotAllowed)
        let accessor = SecurityKeychainAccessor(itemWriter: writer)

        XCTAssertThrowsError(try accessor.writeGenericPassword(service: "Codex Auth", value: "rotated-secret")) { error in
            guard case KeychainError.interactionNotAllowed = error else {
                return XCTFail("expected typed interaction error, got \(error)")
            }
        }
        XCTAssertNotNil(writer.updateQuery)
        XCTAssertTrue(writer.authenticationContext.interactionNotAllowed)
    }

    func testWriteStatusErrorsPreserveAddAndUpdateFailures() {
        let addFailure = RecordingWriter(addStatus: errSecIO)
        XCTAssertThrowsError(
            try SecurityKeychainAccessor(itemWriter: addFailure)
                .writeGenericPassword(service: "Codex Auth", value: "rotated-secret")
        ) { error in
            guard case KeychainError.writeFailed(let message) = error else {
                return XCTFail("expected add failure, got \(error)")
            }
            XCTAssertEqual(message, "Security.framework OSStatus \(errSecIO)")
        }
        XCTAssertNil(addFailure.updateQuery, "a failed add status must not trigger update")

        let updateFailure = RecordingWriter(addStatus: errSecDuplicateItem, updateStatus: errSecIO)
        XCTAssertThrowsError(
            try SecurityKeychainAccessor(itemWriter: updateFailure)
                .writeGenericPassword(service: "Codex Auth", value: "rotated-secret")
        ) { error in
            guard case KeychainError.writeFailed(let message) = error else {
                return XCTFail("expected update failure, got \(error)")
            }
            XCTAssertEqual(message, "Security.framework OSStatus \(errSecIO)")
        }
        XCTAssertNotNil(updateFailure.updateQuery)
    }

    func testInteractionRequiredStatusIsTyped() {
        let writer = RecordingWriter(addStatus: errSecInteractionRequired)

        XCTAssertThrowsError(
            try SecurityKeychainAccessor(itemWriter: writer)
                .writeGenericPassword(service: "Codex Auth", value: "rotated-secret")
        ) { error in
            guard case KeychainError.interactionNotAllowed = error else {
                return XCTFail("expected typed interaction error, got \(error)")
            }
        }
    }

    func testFailureToResolveDefaultKeychainStopsBeforeAdd() {
        let writer = RecordingWriter(addStatus: errSecSuccess, defaultScopeStatus: errSecNoDefaultKeychain)
        let accessor = SecurityKeychainAccessor(itemWriter: writer)

        XCTAssertThrowsError(try accessor.writeGenericPassword(service: "Codex Auth", value: "rotated-secret")) { error in
            guard case KeychainError.writeFailed = error else {
                return XCTFail("expected write failure, got \(error)")
            }
        }
        XCTAssertEqual(writer.scopeCalls, 1)
        XCTAssertNil(writer.addedAttributes)
    }
}

/// Covers `readGenericPasswordForRefresh` — the helper every provider credential read now uses, and
/// the fix for Keychain dialogs reappearing on every scheduled refresh.
final class KeychainRefreshReadTests: XCTestCase {
    /// Records every interaction flag the helper asks for, so a test can assert *whether* UI was ever
    /// permitted, not just what came back.
    private final class RecordingKeychain: KeychainAccessing, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [Bool] = []
        private var authorizationGranted = false
        /// Simulates an item whose ACL requires the user: a silent read throws
        /// `interactionNotAllowed`, an interactive one succeeds.
        let requiresInteraction: Bool

        /// The interaction flags the helper asked for, in order.
        var calls: [Bool] {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }

        private func record(_ allowInteraction: Bool) throws -> String? {
            lock.lock()
            recorded.append(allowInteraction)
            if allowInteraction { authorizationGranted = true }
            let shouldRefuse = requiresInteraction && !allowInteraction && !authorizationGranted
            lock.unlock()
            if shouldRefuse { throw KeychainError.interactionNotAllowed }
            return "secret"
        }

        // `KeychainAccessing` is `Sendable`; the lock-guarded recorder is the only mutable state.
        // `currentUserChannel` stands in for the account attribute: a service-only read and a
        // current-user read are different queries, so they are recorded separately.
        let usesCurrentUserChannel: Bool
        private var recordedCurrentUser: [Bool] = []

        var currentUserCalls: [Bool] {
            lock.lock()
            defer { lock.unlock() }
            return recordedCurrentUser
        }

        init(requiresInteraction: Bool, usesCurrentUserChannel: Bool = false) {
            self.requiresInteraction = requiresInteraction
            self.usesCurrentUserChannel = usesCurrentUserChannel
        }

        private func recordCurrentUser(_ allowInteraction: Bool) throws -> String? {
            lock.lock()
            recordedCurrentUser.append(allowInteraction)
            if allowInteraction { authorizationGranted = true }
            let shouldRefuse = requiresInteraction && !allowInteraction && !authorizationGranted
            lock.unlock()
            if shouldRefuse { throw KeychainError.interactionNotAllowed }
            return "current-user-secret"
        }

        func readGenericPassword(service: String) throws -> String? { try record(true) }
        func readGenericPassword(service: String, allowInteraction: Bool) throws -> String? { try record(allowInteraction) }
        func readGenericPassword(service: String, account: String) throws -> String? { try record(true) }
        func readGenericPassword(service: String, account: String, allowInteraction: Bool) throws -> String? { try record(allowInteraction) }
        func readGenericPasswordForCurrentUser(service: String) throws -> String? { try recordCurrentUser(true) }
        func readGenericPasswordForCurrentUser(service: String, allowInteraction: Bool) throws -> String? { try recordCurrentUser(allowInteraction) }
        func writeGenericPassword(service: String, value: String) throws {}
    }

    private final class CancellationTokenBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: KeychainReadCancellationToken?

        func set(_ token: KeychainReadCancellationToken) {
            lock.lock()
            stored = token
            lock.unlock()
        }

        var value: KeychainReadCancellationToken? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }

    private final class TokenCancellingKeychain: KeychainAccessing, @unchecked Sendable {
        let token: KeychainReadCancellationToken
        let cancelsDuringInteractiveRead: Bool
        private let lock = NSLock()
        private var recordedCalls: [Bool] = []

        var calls: [Bool] {
            lock.lock()
            defer { lock.unlock() }
            return recordedCalls
        }

        init(token: KeychainReadCancellationToken, cancelsDuringInteractiveRead: Bool) {
            self.token = token
            self.cancelsDuringInteractiveRead = cancelsDuringInteractiveRead
        }

        func readGenericPassword(service: String) throws -> String? {
            throw KeychainError.interactionNotAllowed
        }

        func readGenericPassword(service: String, allowInteraction: Bool) throws -> String? {
            lock.lock()
            recordedCalls.append(allowInteraction)
            lock.unlock()
            if allowInteraction == cancelsDuringInteractiveRead {
                token.cancel()
                throw CancellationError()
            }
            throw KeychainError.interactionNotAllowed
        }

        func writeGenericPassword(service: String, value: String) throws {}
    }

    /// Simulates a cancellation during Keychain context preflight, before Security.framework is
    /// entered. The shared prompt budget must be returned to the next read in this manual action.
    private final class PreflightCancellationKeychain: KeychainAccessing, @unchecked Sendable {
        func readGenericPassword(service: String) throws -> String? {
            throw KeychainError.interactionNotAllowed
        }

        func readGenericPassword(service: String, allowInteraction: Bool) throws -> String? {
            guard allowInteraction else { throw KeychainError.interactionNotAllowed }
            ProviderRefreshContext.keychainReadCancellationToken?.cancel()
            throw CancellationError()
        }

        func readGenericPassword(
            service: String,
            allowInteraction: Bool,
            interactiveQueryLease: KeychainInteractiveQueryLease?
        ) throws -> String? {
            _ = interactiveQueryLease
            return try readGenericPassword(service: service, allowInteraction: allowInteraction)
        }

        func writeGenericPassword(service: String, value: String) throws {}
    }

    /// Holds a claimed interactive lease in cancellable preflight so a sibling can arrive before the
    /// first read either enters Security.framework or releases its unused prompt budget.
    private final class PausedPreflightCancellationKeychain: KeychainAccessing, @unchecked Sendable {
        let preflightStarted = DispatchSemaphore(value: 0)
        let releasePreflight = DispatchSemaphore(value: 0)

        func readGenericPassword(service: String) throws -> String? {
            throw KeychainError.interactionNotAllowed
        }

        func readGenericPassword(service: String, allowInteraction: Bool) throws -> String? {
            guard allowInteraction else { throw KeychainError.interactionNotAllowed }
            preflightStarted.signal()
            _ = releasePreflight.wait(timeout: .now() + 5)
            guard ProviderRefreshContext.keychainReadCancellationToken?.isCancelled == true else {
                throw KeychainError.readFailed("The preflight fixture was released without cancellation.")
            }
            throw CancellationError()
        }

        func readGenericPassword(
            service: String,
            allowInteraction: Bool,
            interactiveQueryLease: KeychainInteractiveQueryLease?
        ) throws -> String? {
            _ = interactiveQueryLease
            return try readGenericPassword(service: service, allowInteraction: allowInteraction)
        }

        func writeGenericPassword(service: String, value: String) throws {}
    }

    /// A background refresh must ask for exactly one silent read. This is the regression that matters
    /// most: the old flagless call shelled out to `security find-generic-password`, which cannot
    /// suppress UI, so this path produced a dialog every five minutes.
    /// The shared gate is process-wide state; every test in this type must start from a clean slate
    /// or ordering decides the outcome.
    override func setUp() {
        super.setUp()
        KeychainPermissionGate.shared.resetAll()
    }

    override func tearDown() {
        KeychainPermissionGate.shared.resetAll()
        super.tearDown()
    }

    /// The gate lives in the shared helper rather than in each provider, because the condition belongs
    /// to the item's ACL: once macOS says "this needs a dialog", every background refresh *of that
    /// item* until the user grants it gets the same answer. This asserts the general contract.
    func testSuccessfulInteractiveReadClearsAPreviouslyBlockedItem() throws {
        let key = KeychainItemKey(service: "svc")
        let blocked = RecordingKeychain(requiresInteraction: true)
        XCTAssertThrowsError(try blocked.readGenericPasswordForRefresh(service: "svc"))
        XCTAssertTrue(
            KeychainPermissionGate.shared.isBlocked(key),
            "a silent-read failure must block later background attempts"
        )

        // A *background* read cannot clear the block — it never reaches the Keychain, which is the
        // whole point. Only a manual refresh can, because only it can show the dialog that grants access.
        let stillBlocked = RecordingKeychain(requiresInteraction: false)
        XCTAssertThrowsError(try stillBlocked.readGenericPasswordForRefresh(service: "svc"))
        XCTAssertTrue(KeychainPermissionGate.shared.isBlocked(key))

        // The manual read reaches the Keychain, succeeds, and clears the block for this item.
        let granted = RecordingKeychain(requiresInteraction: false)
        let value = try ProviderRefreshContext.$isManual.withValue(true) {
            try granted.readGenericPasswordForRefresh(service: "svc")
        }
        XCTAssertEqual(value, "secret")
        XCTAssertFalse(
            KeychainPermissionGate.shared.isBlocked(key),
            "granting access must clear the item that was granted"
        )

        // And background reads work silently again.
        let afterwards = RecordingKeychain(requiresInteraction: false)
        _ = try afterwards.readGenericPasswordForRefresh(service: "svc")
        XCTAssertEqual(afterwards.calls, [false])
    }

    // MARK: - Per-item isolation
    //
    // These guard a real regression. The gate used to be one process-wide boolean, which broke
    // provider independence in both directions and was user-visible as healthy providers reporting
    // "not logged in" because an unrelated provider needed a Keychain dialog.

    /// The central bug: a provider that needs a dialog must not stop a different, readable provider
    /// from being refreshed in the background.
    func testBlockedItemDoesNotSuppressAnUnrelatedService() throws {
        let blockedKey = KeychainItemKey(service: "com.example.blocked")
        let otherKey = KeychainItemKey(service: "com.example.healthy")

        let blocked = RecordingKeychain(requiresInteraction: true)
        XCTAssertThrowsError(try blocked.readGenericPasswordForRefresh(service: "com.example.blocked"))
        XCTAssertTrue(KeychainPermissionGate.shared.isBlocked(blockedKey))

        // A different service is a different item with a different ACL, so it must still be read.
        let healthy = RecordingKeychain(requiresInteraction: false)
        let value = try healthy.readGenericPasswordForRefresh(service: "com.example.healthy")

        XCTAssertEqual(value, "secret")
        XCTAssertEqual(healthy.calls, [false], "the healthy item must actually be read")
        XCTAssertFalse(
            KeychainPermissionGate.shared.isBlocked(otherKey),
            "an unrelated item must not be marked as needing interaction"
        )
    }

    /// The mirror bug: an unrelated provider's *success* must not un-block an item that still needs a
    /// dialog, or the five-minute re-read-and-fail spam returns for that item.
    func testUnrelatedSuccessDoesNotClearAnotherItemsBlock() throws {
        let blockedKey = KeychainItemKey(service: "com.example.blocked")

        let blocked = RecordingKeychain(requiresInteraction: true)
        XCTAssertThrowsError(try blocked.readGenericPasswordForRefresh(service: "com.example.blocked"))

        // A different provider refreshes successfully, every cycle.
        for _ in 0..<3 {
            let healthy = RecordingKeychain(requiresInteraction: false)
            XCTAssertEqual(try healthy.readGenericPasswordForRefresh(service: "com.example.healthy"), "secret")
        }

        XCTAssertTrue(
            KeychainPermissionGate.shared.isBlocked(blockedKey),
            "another item's success must not clear this item's block"
        )

        // And the blocked item is still not re-read on every background cycle.
        let probe = RecordingKeychain(requiresInteraction: true)
        XCTAssertThrowsError(try probe.readGenericPasswordForRefresh(service: "com.example.blocked"))
        XCTAssertEqual(
            probe.calls, [],
            "a still-blocked item must be answered from memory, not re-read"
        )
    }

    /// Account is part of the query, so account-scoped and service-only reads are different items and
    /// must not share a block.
    func testAccountScopedAndServiceOnlyReadsAreIndependentItems() throws {
        let serviceOnly = KeychainItemKey(service: "svc")
        let accountScoped = KeychainItemKey(service: "svc", account: "user@example.com")

        let blocked = RecordingKeychain(requiresInteraction: true)
        XCTAssertThrowsError(try blocked.readGenericPasswordForRefresh(service: "svc"))
        XCTAssertTrue(KeychainPermissionGate.shared.isBlocked(serviceOnly))

        let otherAccount = RecordingKeychain(requiresInteraction: false)
        let value = try otherAccount.readGenericPasswordForRefresh(service: "svc", account: "user@example.com")
        XCTAssertEqual(value, "secret")
        XCTAssertEqual(otherAccount.calls, [false])
        XCTAssertFalse(KeychainPermissionGate.shared.isBlocked(accountScoped))
    }

    func testBackgroundRefreshAnswersFromMemoryOnceBlocked() throws {
        let keychain = RecordingKeychain(requiresInteraction: true)
        XCTAssertThrowsError(try keychain.readGenericPasswordForRefresh(service: "svc"))
        XCTAssertEqual(keychain.calls, [false], "the silent probe is the only read that should happen")

        // Every later background refresh must not touch the Keychain at all.
        for _ in 0..<3 {
            XCTAssertThrowsError(try keychain.readGenericPasswordForRefresh(service: "svc"))
        }
        XCTAssertEqual(
            keychain.calls, [false],
            "a blocked item must not be re-read on every background refresh"
        )
    }

    func testBackgroundRefreshNeverPermitsInteraction() throws {
        let keychain = RecordingKeychain(requiresInteraction: true)
        XCTAssertThrowsError(try keychain.readGenericPasswordForRefresh(service: "svc")) { error in
            // `KeychainError` isn't Equatable, so match the case instead of comparing values.
            guard case .interactionNotAllowed = error as? KeychainError else {
                return XCTFail("expected interactionNotAllowed, got \(error)")
            }
        }
        XCTAssertEqual(keychain.calls, [false], "background refresh must not permit Keychain UI")
    }

    /// A background refresh against an item that does NOT need interaction still reads silently.
    func testBackgroundRefreshStaysSilentWhenNoInteractionIsNeeded() throws {
        let keychain = RecordingKeychain(requiresInteraction: false)
        XCTAssertEqual(try keychain.readGenericPasswordForRefresh(service: "svc"), "secret")
        XCTAssertEqual(keychain.calls, [false])
    }

    /// A manual refresh may escalate, but only after a silent read proved interaction is required.
    func testManualRefreshEscalatesOnlyAfterSilentReadProvesItIsNeeded() throws {
        let keychain = RecordingKeychain(requiresInteraction: true)
        let value = try ProviderRefreshContext.$isManual.withValue(true) {
            try keychain.readGenericPasswordForRefresh(service: "svc")
        }
        XCTAssertEqual(value, "secret")
        XCTAssertEqual(keychain.calls, [false, true])
    }

    /// An item that reads fine silently must not open a dialog even on a manual refresh — escalation is
    /// reactive, never speculative.
    func testManualRefreshDoesNotEscalateWhenSilentReadSucceeds() throws {
        let keychain = RecordingKeychain(requiresInteraction: false)
        let value = try ProviderRefreshContext.$isManual.withValue(true) {
            try keychain.readGenericPasswordForRefresh(service: "svc")
        }
        XCTAssertEqual(value, "secret")
        XCTAssertEqual(keychain.calls, [false])
    }

    /// One manual refresh opens at most one dialog across every provider, so the shared gate caps
    /// escalation rather than each provider claiming its own.
    func testGateLimitsOneEscalationAndSuppressesRepeatedReadForDeclinedItem() async throws {
        let first = RecordingKeychain(requiresInteraction: true)
        let second = RecordingKeychain(requiresInteraction: true)
        try await withManualRefresh {
            _ = try first.readGenericPasswordForRefresh(service: "svc")
            for _ in 0..<2 {
                do {
                    _ = try second.readGenericPasswordForRefresh(service: "other")
                    XCTFail("the spent action budget must refuse another Keychain prompt")
                } catch KeychainError.interactionNotAllowed {
                    // The first provider used the action's one interactive query.
                }
            }
        }
        XCTAssertEqual(first.calls, [false, true])
        XCTAssertEqual(second.calls, [false], "a refused escalation must not even attempt the UI read")
    }

    func testSameItemSiblingRetriesSilentlyAfterSharedInteractiveReadSucceeds() async throws {
        let service = "concurrent.same-item"
        let key = KeychainItemKey(service: service)
        let keychain = PausedGrantingKeychain()
        KeychainPermissionGate.shared.reset(key)
        defer { KeychainPermissionGate.shared.reset(key) }

        let values = try await withManualRefresh {
            let first = Task {
                try await loadOffMainActor {
                    try keychain.readGenericPasswordForRefresh(service: service)
                }
            }
            XCTAssertEqual(
                keychain.interactiveReadStarted.wait(timeout: .now() + 2), .success,
                "the first same-item reader must own the one interactive query"
            )

            let sibling = Task {
                try await loadOffMainActor {
                    try keychain.readGenericPasswordForRefresh(service: service)
                }
            }
            let deadline = Date().addingTimeInterval(2)
            while KeychainPermissionGate.shared.interactiveQueryWaiterCountForTesting() == 0,
                  Date() < deadline
            {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            XCTAssertGreaterThan(
                KeychainPermissionGate.shared.interactiveQueryWaiterCountForTesting(), 0,
                "the sibling must wait for the same item's in-flight prompt result"
            )
            keychain.releaseInteractiveRead.signal()
            return (try await first.value, try await sibling.value)
        }

        XCTAssertEqual(values.0, "secret")
        XCTAssertEqual(values.1, "secret", "the sibling must recover from the grant with one silent retry")
        XCTAssertEqual(keychain.calls, [false, true, false], "the sibling must never open a second dialog")
        XCTAssertFalse(KeychainPermissionGate.shared.isBlocked(key))
    }

    /// Account-scoped reads (Antigravity's `agy` token) get the same discipline as service-scoped ones.
    func testAccountScopedReadIsSilentOnBackgroundRefresh() throws {
        let keychain = RecordingKeychain(requiresInteraction: true)
        XCTAssertThrowsError(
            try keychain.readGenericPasswordForRefresh(service: "gemini", account: "antigravity")
        )
        XCTAssertEqual(keychain.calls, [false])
    }

    /// An item this app writes itself under `kSecAttrAccount` must be read back through the
    /// account-scoped query. Collapsing it to a service-only read is a different lookup and returns
    /// nil, which is how the iCloud device-id store lost its value once already.
    func testCurrentUserReadUsesTheAccountScopedQuery() throws {
        let keychain = RecordingKeychain(requiresInteraction: false, usesCurrentUserChannel: true)
        XCTAssertEqual(
            try keychain.readGenericPasswordForRefreshForCurrentUser(service: "own.item"),
            "current-user-secret"
        )
        XCTAssertEqual(keychain.currentUserCalls, [false])
        XCTAssertEqual(keychain.calls, [], "must not fall through to the service-only channel")
    }

    func testCurrentUserReadIsSilentOnBackgroundRefresh() throws {
        let keychain = RecordingKeychain(requiresInteraction: true, usesCurrentUserChannel: true)
        XCTAssertThrowsError(try keychain.readGenericPasswordForRefreshForCurrentUser(service: "own.item"))
        XCTAssertEqual(keychain.currentUserCalls, [false])
    }

    func testCurrentUserBlockedReadIsSuppressedUntilManualRefresh() async throws {
        let keychain = RecordingKeychain(requiresInteraction: true, usesCurrentUserChannel: true)
        let key = KeychainItemKey(service: "own.item", account: currentUserKeychainAccount())

        XCTAssertThrowsError(try keychain.readGenericPasswordForRefreshForCurrentUser(service: "own.item"))
        for _ in 0..<3 {
            XCTAssertThrowsError(try keychain.readGenericPasswordForRefreshForCurrentUser(service: "own.item"))
        }
        XCTAssertEqual(keychain.currentUserCalls, [false], "background retries must be answered from the gate")
        XCTAssertTrue(KeychainPermissionGate.shared.isBlocked(key))

        let value = try await withManualRefresh {
            try keychain.readGenericPasswordForRefreshForCurrentUser(service: "own.item")
        }
        XCTAssertEqual(value, "current-user-secret")
        XCTAssertEqual(keychain.currentUserCalls, [false, false, true])
        XCTAssertFalse(KeychainPermissionGate.shared.isBlocked(key))

        _ = try keychain.readGenericPasswordForRefreshForCurrentUser(service: "own.item")
        XCTAssertEqual(keychain.currentUserCalls, [false, false, true, false])
    }

    func testCurrentUserAndEquivalentExplicitAccountSharePermissionState() throws {
        let service = "same.keychain.item"
        let account = currentUserKeychainAccount()
        let keychain = RecordingKeychain(requiresInteraction: true, usesCurrentUserChannel: true)

        XCTAssertThrowsError(try keychain.readGenericPasswordForRefreshForCurrentUser(service: service))
        XCTAssertThrowsError(
            try keychain.readGenericPasswordForRefresh(service: service, account: account),
            "the equivalent explicit query must share the blocked-item cache"
        )
        XCTAssertEqual(keychain.currentUserCalls, [false])
        XCTAssertEqual(keychain.calls, [])
    }

    func testManualRefreshContextSurvivesDetachedCredentialLoad() async throws {
        let keychain = RecordingKeychain(requiresInteraction: true)
        let interactionGate = CredentialInteractionGate()

        let value = try await ProviderRefreshContext.$isManual.withValue(true) {
            try await ProviderRefreshContext.$credentialInteractionGate.withValue(interactionGate) {
                try await loadOffMainActor {
                    try keychain.readGenericPasswordForRefresh(service: "detached")
                }
            }
        }

        XCTAssertEqual(value, "secret")
        XCTAssertEqual(keychain.calls, [false, true])
        XCTAssertFalse(interactionGate.claim(), "detached read must use the caller's shared one-dialog budget")
    }

    func testTransientInteractiveFailureDoesNotCountAsDecline() async throws {
        let keychain = RecoversAfterTransientInteractiveFailure()
        let key = KeychainItemKey(service: "transient")

        do {
            _ = try await withManualRefresh {
                try keychain.readGenericPasswordForRefresh(service: "transient")
            }
            XCTFail("first interactive read should fail transiently")
        } catch let error as KeychainError {
            guard case .readFailed = error else { return XCTFail("unexpected keychain error: \(error)") }
        }
        XCTAssertFalse(KeychainPermissionGate.shared.isDeclined(key))
        XCTAssertTrue(KeychainPermissionGate.shared.isBlocked(key))

        let value = try await withManualRefresh {
            try keychain.readGenericPasswordForRefresh(service: "transient")
        }
        XCTAssertEqual(value, "secret")
        XCTAssertEqual(keychain.interactiveReads, 2)
        XCTAssertFalse(KeychainPermissionGate.shared.isBlocked(key))
    }

    func testLateBackgroundFailureCannotReblockAfterManualGrant() async throws {
        let keychain = BlockingFirstReadKeychain()
        let key = KeychainItemKey(service: "racing.item")
        let background = Task.detached {
            try? keychain.readGenericPasswordForRefresh(service: "racing.item")
        }
        XCTAssertEqual(keychain.firstReadStarted.wait(timeout: .now() + 2), .success)

        let value = try await withManualRefresh {
            try keychain.readGenericPasswordForRefresh(service: "racing.item")
        }
        keychain.releaseFirstRead.signal()
        _ = await background.value

        XCTAssertEqual(value, "secret")
        XCTAssertFalse(KeychainPermissionGate.shared.isBlocked(key))
    }

    func testNewManualActionCannotStartInteractiveReadUntilOlderQueryReturns() async throws {
        let service = "racing.manual-cancel"
        let key = KeychainItemKey(service: service)
        let olderKeychain = PausedInteractiveCancellationKeychain()
        let olderAction = Task.detached {
            try await withManualRefresh {
                try olderKeychain.readGenericPasswordForRefresh(service: service)
            }
        }
        defer { olderKeychain.releaseInteractive.signal() }

        XCTAssertEqual(
            olderKeychain.interactiveStarted.wait(timeout: .now() + 2), .success,
            "the older action must be paused inside its interactive read"
        )

        // A later action invalidates the old context, but the old synchronous read still owns the
        // process-wide slot until its call returns. It must fail fast without starting a second read.
        let newerKeychain = GrantingKeychain()
        do {
            _ = try await withManualRefresh {
                try newerKeychain.readGenericPasswordForRefresh(service: service)
            }
            XCTFail("a newer action must not start a second interactive Security query while the first is in flight")
        } catch let error as KeychainError {
            guard case .interactionNotAllowed = error else {
                return XCTFail("unexpected keychain error: \(error)")
            }
        }
        XCTAssertEqual(newerKeychain.interactiveReads, 0)

        olderKeychain.releaseInteractive.signal()
        do {
            _ = try await olderAction.value
            XCTFail("a superseded interactive read must not publish its result")
        } catch is CancellationError {
            // Expected: the next action invalidated the old query's context.
        }

        XCTAssertFalse(KeychainPermissionGate.shared.isDeclined(key))
        XCTAssertTrue(KeychainPermissionGate.shared.isBlocked(key), "the newer silent refusal remains blocked")

        // Once the older synchronous read has returned and released the slot, a later explicit
        // action can make a fresh interactive attempt.
        let retry = try await withManualRefresh {
            try newerKeychain.readGenericPasswordForRefresh(service: service)
        }
        XCTAssertEqual(retry, "secret")
        XCTAssertEqual(newerKeychain.interactiveReads, 1)
    }

    func testPromptBudgetCanBeReturnedWhenNoInteractiveReadStarts() {
        let interactionGate = CredentialInteractionGate()

        XCTAssertTrue(interactionGate.claim())
        interactionGate.releaseClaim()
        XCTAssertTrue(interactionGate.claim(), "a canceled preflight must not spend the action's prompt budget")
    }

    func testPreflightCancellationReturnsPromptBudgetToSiblingRead() async throws {
        let service = "racing.preflight-cancel"
        let preflightCancellation = PreflightCancellationKeychain()
        let siblingKeychain = GrantingKeychain()

        let (value, canceled) = try await withManualRefresh {
            var canceled = false
            do {
                _ = try await loadOffMainActor {
                    try preflightCancellation.readGenericPasswordForRefresh(service: service)
                }
            } catch is CancellationError {
                canceled = true
            }
            let value = try await loadOffMainActor {
                try siblingKeychain.readGenericPasswordForRefresh(service: service)
            }
            return (value, canceled)
        }

        XCTAssertTrue(canceled)
        XCTAssertEqual(value, "secret")
        XCTAssertEqual(siblingKeychain.interactiveReads, 1,
                       "the sibling consumes the prompt budget because the first Security query never began")
    }

    func testConcurrentSiblingWaitsForCanceledPreflightAndUsesPromptBudget() async throws {
        let ownerKeychain = PausedPreflightCancellationKeychain()
        let siblingKeychain = GrantingKeychain()
        let siblingEntered = DispatchSemaphore(value: 0)

        let (ownerCanceled, siblingValue) = try await withManualRefresh {
            let owner = Task {
                do {
                    _ = try await loadOffMainActor {
                        try ownerKeychain.readGenericPasswordForRefresh(service: "preflight-owner")
                    }
                    return false
                } catch is CancellationError {
                    return true
                } catch {
                    return false
                }
            }
            defer { ownerKeychain.releasePreflight.signal() }

            XCTAssertEqual(
                ownerKeychain.preflightStarted.wait(timeout: .now() + 2), .success,
                "the first read must hold its lease before the sibling starts"
            )
            let sibling = Task {
                do {
                    return try await loadOffMainActor {
                        siblingEntered.signal()
                        return try siblingKeychain.readGenericPasswordForRefresh(service: "preflight-sibling")
                    }
                } catch {
                    return nil
                }
            }
            XCTAssertEqual(siblingEntered.wait(timeout: .now() + 2), .success)
            let deadline = Date().addingTimeInterval(2)
            while KeychainPermissionGate.shared.interactiveQueryWaiterCountForTesting() == 0,
                  Date() < deadline
            {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            XCTAssertGreaterThan(
                KeychainPermissionGate.shared.interactiveQueryWaiterCountForTesting(), 0,
                "the sibling must be blocked on the owner's unstarted lease before it is released"
            )
            owner.cancel()
            ownerKeychain.releasePreflight.signal()
            return (await owner.value, await sibling.value)
        }

        XCTAssertTrue(ownerCanceled)
        XCTAssertEqual(siblingValue, "secret", "the sibling must wait and use the budget freed by preflight cancellation")
        XCTAssertEqual(siblingKeychain.interactiveReads, 1)
    }

    func testQueuedOlderManualActionCannotPromptAfterNewerManualActionSucceeds() async throws {
        let service = "racing.queued-manual"
        let key = KeychainItemKey(service: service)
        let olderKeychain = RecordingKeychain(requiresInteraction: true)
        let olderLoadStarted = DispatchSemaphore(value: 0)
        let releaseOlderLoad = DispatchSemaphore(value: 0)

        // Capture the older action identity, then hold its detached load before it even observes
        // the item. The newer action therefore cannot rely on a per-item generation bump alone.
        let olderAction = Task.detached {
            try await withManualRefresh {
                try await loadOffMainActor {
                    olderLoadStarted.signal()
                    _ = releaseOlderLoad.wait(timeout: .now() + 5)
                    return try olderKeychain.readGenericPasswordForRefresh(service: service)
                }
            }
        }
        defer { releaseOlderLoad.signal() }

        XCTAssertEqual(
            olderLoadStarted.wait(timeout: .now() + 2), .success,
            "the older manual action must be queued before its first Keychain read"
        )

        // A later explicit Refresh starts and succeeds while the older detached load is still queued.
        let newerKeychain = GrantingKeychain()
        let newerValue = try await withManualRefresh {
            try newerKeychain.readGenericPasswordForRefresh(service: service)
        }
        XCTAssertEqual(newerValue, "secret")

        releaseOlderLoad.signal()
        do {
            _ = try await olderAction.value
            XCTFail("the superseded older action must not retry with UI")
        } catch is CancellationError {
            // Supersession stops the stale credential search, not just its interactive retry.
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }

        XCTAssertEqual(olderKeychain.calls, [false], "the stale action may make only its silent read")
        XCTAssertEqual(newerKeychain.interactiveReads, 1)
        XCTAssertFalse(KeychainPermissionGate.shared.isDeclined(key))
        XCTAssertFalse(KeychainPermissionGate.shared.isBlocked(key), "stale refusal must not undo the newer grant")
    }

    func testCanceledManualReadDoesNotRetrySilentRefusalWithUI() async {
        let service = "canceled.manual-refresh"
        let key = KeychainItemKey(service: service)
        let keychain = PausedSilentRefusalKeychain()
        let action = Task.detached {
            try await withManualRefresh {
                try keychain.readGenericPasswordForRefresh(service: service)
            }
        }
        defer { keychain.releaseSilentRead.signal() }

        XCTAssertEqual(
            keychain.silentReadStarted.wait(timeout: .now() + 2), .success,
            "the task must reach its silent Keychain read before cancellation"
        )
        action.cancel()
        keychain.releaseSilentRead.signal()

        do {
            _ = try await action.value
            XCTFail("a canceled refresh must stop after the silent refusal")
        } catch is CancellationError {
            // Expected: no interactive retry was attempted.
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }

        XCTAssertEqual(keychain.interactiveReads, 0)
        XCTAssertFalse(KeychainPermissionGate.shared.isDeclined(key))
        XCTAssertFalse(KeychainPermissionGate.shared.isBlocked(key), "an in-flight canceled read did not complete a Keychain refusal")
    }

    func testCanceledKeychainLoadHasItsOwnToken() async {
        let firstStarted = DispatchSemaphore(value: 0)
        let secondStarted = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let releaseSecond = DispatchSemaphore(value: 0)
        let firstTokenBox = CancellationTokenBox()
        let secondTokenBox = CancellationTokenBox()
        defer {
            releaseFirst.signal()
            releaseSecond.signal()
        }

        let first = Task.detached {
            await loadOffMainActor {
                let token = ProviderRefreshContext.keychainReadCancellationToken!
                firstTokenBox.set(token)
                firstStarted.signal()
                _ = releaseFirst.wait(timeout: .now() + 5)
                return token
            }
        }
        let second = Task.detached {
            await loadOffMainActor {
                let token = ProviderRefreshContext.keychainReadCancellationToken!
                secondTokenBox.set(token)
                secondStarted.signal()
                _ = releaseSecond.wait(timeout: .now() + 5)
                return token
            }
        }

        XCTAssertEqual(firstStarted.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(secondStarted.wait(timeout: .now() + 5), .success)
        second.cancel()

        let firstToken = try! XCTUnwrap(firstTokenBox.value)
        let secondToken = try! XCTUnwrap(secondTokenBox.value)
        XCTAssertFalse(firstToken === secondToken)
        XCTAssertFalse(firstToken.isCancelled, "canceling a sibling load must not invalidate this load's context")
        XCTAssertTrue(secondToken.isCancelled)

        releaseFirst.signal()
        releaseSecond.signal()
        _ = await first.value
        _ = await second.value
    }

    func testCancellationDuringKeychainReadDoesNotRecordAnAuthDecline() throws {
        let service = "canceled.interactive-read"
        let key = KeychainItemKey(service: service)
        let token = KeychainReadCancellationToken(invalidateContext: { _ in })
        let keychain = TokenCancellingKeychain(token: token, cancelsDuringInteractiveRead: true)
        let interactionGate = CredentialInteractionGate()

        do {
            try ProviderRefreshContext.$isManual.withValue(true) {
                try ProviderRefreshContext.$credentialInteractionGate.withValue(interactionGate) {
                    try ProviderRefreshContext.$keychainReadCancellationToken.withValue(token) {
                        try keychain.readGenericPasswordForRefresh(service: service)
                    }
                }
            }
            XCTFail("a canceled interactive Keychain read must throw CancellationError")
        } catch is CancellationError {
            // Expected: invalidating the read is not a user-declined authorization.
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }

        XCTAssertEqual(keychain.calls, [false, true])
        XCTAssertTrue(KeychainPermissionGate.shared.isBlocked(key), "the silent refusal remains cached")
        XCTAssertFalse(KeychainPermissionGate.shared.isDeclined(key), "task cancellation is not a user decline")
    }

    func testCancellationDuringSilentKeychainReadDoesNotBlockOrRetry() throws {
        let service = "canceled.silent-read"
        let key = KeychainItemKey(service: service)
        let token = KeychainReadCancellationToken(invalidateContext: { _ in })
        let keychain = TokenCancellingKeychain(token: token, cancelsDuringInteractiveRead: false)

        do {
            try ProviderRefreshContext.$isManual.withValue(true) {
                try ProviderRefreshContext.$keychainReadCancellationToken.withValue(token) {
                    try keychain.readGenericPasswordForRefresh(service: service)
                }
            }
            XCTFail("cancellation during the silent attempt must stop escalation")
        } catch is CancellationError {
            // Expected: a canceled read is not evidence that this item requires a prompt.
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }

        XCTAssertEqual(keychain.calls, [false])
        XCTAssertFalse(KeychainPermissionGate.shared.isBlocked(key))
        XCTAssertFalse(KeychainPermissionGate.shared.isDeclined(key))
    }
}

private extension KeychainRefreshReadTests {
    final class RecoversAfterTransientInteractiveFailure: KeychainAccessing, @unchecked Sendable {
        private let lock = NSLock()
        private var _interactiveReads = 0

        var interactiveReads: Int {
            lock.lock()
            defer { lock.unlock() }
            return _interactiveReads
        }

        func readGenericPassword(service: String) throws -> String? {
            try readGenericPassword(service: service, allowInteraction: true)
        }

        func readGenericPassword(service: String, allowInteraction: Bool) throws -> String? {
            guard allowInteraction else { throw KeychainError.interactionNotAllowed }
            lock.lock()
            _interactiveReads += 1
            let attempt = _interactiveReads
            lock.unlock()
            if attempt == 1 { throw KeychainError.readFailed("temporary Security.framework failure") }
            return "secret"
        }

        func writeGenericPassword(service: String, value: String) throws {}
    }

    final class BlockingFirstReadKeychain: KeychainAccessing, @unchecked Sendable {
        private let lock = NSLock()
        private var silentReads = 0
        let firstReadStarted = DispatchSemaphore(value: 0)
        let releaseFirstRead = DispatchSemaphore(value: 0)

        func readGenericPassword(service: String) throws -> String? {
            try readGenericPassword(service: service, allowInteraction: true)
        }

        func readGenericPassword(service: String, allowInteraction: Bool) throws -> String? {
            if allowInteraction { return "secret" }
            lock.lock()
            silentReads += 1
            let readNumber = silentReads
            lock.unlock()
            if readNumber == 1 {
                firstReadStarted.signal()
                _ = releaseFirstRead.wait(timeout: .now() + 3)
            }
            throw KeychainError.interactionNotAllowed
        }

        func writeGenericPassword(service: String, value: String) throws {}
    }

    final class PausedGrantingKeychain: KeychainAccessing, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [Bool] = []
        private var authorizationGranted = false
        let interactiveReadStarted = DispatchSemaphore(value: 0)
        let releaseInteractiveRead = DispatchSemaphore(value: 0)

        var calls: [Bool] {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }

        func readGenericPassword(service: String) throws -> String? {
            try readGenericPassword(service: service, allowInteraction: true)
        }

        func readGenericPassword(service: String, allowInteraction: Bool) throws -> String? {
            lock.lock()
            recorded.append(allowInteraction)
            if allowInteraction {
                lock.unlock()
                interactiveReadStarted.signal()
                _ = releaseInteractiveRead.wait(timeout: .now() + 5)
                lock.lock()
                authorizationGranted = true
                lock.unlock()
                return "secret"
            }
            let isAuthorized = authorizationGranted
            lock.unlock()
            guard isAuthorized else { throw KeychainError.interactionNotAllowed }
            return "secret"
        }

        func writeGenericPassword(service: String, value: String) throws {}
    }

    final class PausedInteractiveCancellationKeychain: KeychainAccessing, @unchecked Sendable {
        let interactiveStarted = DispatchSemaphore(value: 0)
        let releaseInteractive = DispatchSemaphore(value: 0)

        func readGenericPassword(service: String) throws -> String? {
            throw KeychainError.interactionNotAllowed
        }

        func readGenericPassword(service: String, allowInteraction: Bool) throws -> String? {
            guard allowInteraction else { throw KeychainError.interactionNotAllowed }
            interactiveStarted.signal()
            _ = releaseInteractive.wait(timeout: .now() + 5)
            throw KeychainError.interactionNotAllowed
        }

        func writeGenericPassword(service: String, value: String) throws {}
    }

    final class PausedSilentRefusalKeychain: KeychainAccessing, @unchecked Sendable {
        private let lock = NSLock()
        private var _interactiveReads = 0
        let silentReadStarted = DispatchSemaphore(value: 0)
        let releaseSilentRead = DispatchSemaphore(value: 0)

        var interactiveReads: Int {
            lock.lock()
            defer { lock.unlock() }
            return _interactiveReads
        }

        func readGenericPassword(service: String) throws -> String? {
            try readGenericPassword(service: service, allowInteraction: true)
        }

        func readGenericPassword(service: String, allowInteraction: Bool) throws -> String? {
            if allowInteraction {
                lock.lock()
                _interactiveReads += 1
                lock.unlock()
                return "should-not-be-read"
            }
            silentReadStarted.signal()
            _ = releaseSilentRead.wait(timeout: .now() + 5)
            if Task.isCancelled { throw CancellationError() }
            throw KeychainError.interactionNotAllowed
        }

        func writeGenericPassword(service: String, value: String) throws {}
    }
}

extension KeychainRefreshReadTests {
    /// A Keychain whose ACL needs the user *and* whose dialog the user cancels: the silent read and the
    /// interactive read both throw. Models a user who dismisses the prompt.
    private final class CancellingKeychain: KeychainAccessing, @unchecked Sendable {
        private let lock = NSLock()
        private var _interactiveReads = 0
        var interactiveReads: Int {
            lock.lock(); defer { lock.unlock() }
            return _interactiveReads
        }

        private func read(_ allowInteraction: Bool) throws -> String? {
            if allowInteraction {
                lock.lock(); _interactiveReads += 1; lock.unlock()
            }
            throw KeychainError.interactionNotAllowed
        }

        func readGenericPassword(service: String) throws -> String? { try read(true) }
        func readGenericPassword(service: String, allowInteraction: Bool) throws -> String? { try read(allowInteraction) }
        func readGenericPassword(service: String, account: String) throws -> String? { try read(true) }
        func readGenericPassword(service: String, account: String, allowInteraction: Bool) throws -> String? { try read(allowInteraction) }
        func readGenericPasswordForCurrentUser(service: String) throws -> String? { try read(true) }
        func readGenericPasswordForCurrentUser(service: String, allowInteraction: Bool) throws -> String? { try read(allowInteraction) }
        func writeGenericPassword(service: String, value: String) throws {}
        func writeGenericPasswordForCurrentUser(service: String, value: String) throws {}
    }

    /// Refuses silently but *would* release the secret interactively — the shape that proves no second
    /// dialog was raised.
    private final class GrantingKeychain: KeychainAccessing, @unchecked Sendable {
        private let lock = NSLock()
        private var _interactiveReads = 0
        var interactiveReads: Int {
            lock.lock(); defer { lock.unlock() }
            return _interactiveReads
        }

        private func read(_ allowInteraction: Bool) throws -> String? {
            guard allowInteraction else { throw KeychainError.interactionNotAllowed }
            lock.lock(); _interactiveReads += 1; lock.unlock()
            return "secret"
        }

        func readGenericPassword(service: String) throws -> String? { try read(true) }
        func readGenericPassword(service: String, allowInteraction: Bool) throws -> String? { try read(allowInteraction) }
        func readGenericPassword(service: String, account: String) throws -> String? { try read(true) }
        func readGenericPassword(service: String, account: String, allowInteraction: Bool) throws -> String? { try read(allowInteraction) }
        func readGenericPasswordForCurrentUser(service: String) throws -> String? { try read(true) }
        func readGenericPasswordForCurrentUser(service: String, allowInteraction: Bool) throws -> String? { try read(allowInteraction) }
        func writeGenericPassword(service: String, value: String) throws {}
        func writeGenericPasswordForCurrentUser(service: String, value: String) throws {}
    }

    /// A manual refresh against an item whose prompt the user cancelled.
    private static func attemptManualRead(
        _ keychain: KeychainAccessing,
        service: String
    ) throws -> String? {
        try keychain.readGenericPasswordForRefresh(service: service)
    }

    /// A canceled prompt is suppressed through the remainder of that action, while a later explicit
    /// Refresh deliberately clears the decline and permits one new prompt.
    func testDeclinedItemCanOnlyBeRetriedByANewManualAction() async throws {
        let service = "com.example.declined"
        let key = KeychainItemKey(service: service)

        // Asked once; the user cancels, so even the interactive read fails.
        let cancelling = CancellingKeychain()
        try await withManualRefresh {
            XCTAssertThrowsError(try Self.attemptManualRead(cancelling, service: service))
        }
        XCTAssertEqual(cancelling.interactiveReads, 1, "precondition: the dialog was raised once")
        XCTAssertTrue(
            KeychainPermissionGate.shared.isDeclined(key),
            "a cancelled prompt must be remembered during this refresh action"
        )

        // Duplicate provider tasks in the same action answer from memory.
        let siblingTask = GrantingKeychain()
        XCTAssertThrowsError(try Self.attemptManualRead(siblingTask, service: service))
        XCTAssertEqual(
            siblingTask.interactiveReads, 0,
            "the app must not raise a second dialog for the same item in one action"
        )

        // A new explicit action is the user's retry: it gets one new shared prompt budget.
        let granting = GrantingKeychain()
        let value = try await withManualRefresh {
            try Self.attemptManualRead(granting, service: service)
        }
        XCTAssertEqual(value, "secret")
    }
}
