import XCTest
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
}

/// Covers `readGenericPasswordForRefresh` — the helper every provider credential read now uses, and
/// the fix for Keychain dialogs reappearing on every scheduled refresh.
final class KeychainRefreshReadTests: XCTestCase {
    /// Records every interaction flag the helper asks for, so a test can assert *whether* UI was ever
    /// permitted, not just what came back.
    private final class RecordingKeychain: KeychainAccessing, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [Bool] = []
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
            lock.unlock()
            if requiresInteraction && !allowInteraction { throw KeychainError.interactionNotAllowed }
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
            lock.unlock()
            if requiresInteraction && !allowInteraction { throw KeychainError.interactionNotAllowed }
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
    func testGateLimitsOneEscalationPerManualRefresh() throws {
        let gate = CredentialInteractionGate()
        func attempt() throws -> Bool {
            try ProviderRefreshContext.$isManual.withValue(true) {
                try ProviderRefreshContext.$credentialInteractionGate.withValue(gate) {
                    let keychain = RecordingKeychain(requiresInteraction: true)
                    XCTAssertNoThrow(try keychain.readGenericPasswordForRefresh(service: "svc"))
                    // Whether this attempt was the one that claimed the gate.
                    return gate.claim()
                }
            }
        }
        _ = try? attempt()
        // Gate is now spent; a second provider's escalation must be refused.
        let second = RecordingKeychain(requiresInteraction: true)
        XCTAssertThrowsError(
            try ProviderRefreshContext.$isManual.withValue(true) {
                try ProviderRefreshContext.$credentialInteractionGate.withValue(gate) {
                    try second.readGenericPasswordForRefresh(service: "other")
                }
            }
        )
        XCTAssertEqual(second.calls, [false], "a refused escalation must not even attempt the UI read")
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
    private func attemptManualRead(
        _ keychain: KeychainAccessing,
        service: String
    ) throws -> String? {
        try keychain.readGenericPasswordForRefresh(service: service)
    }

    /// The complaint this answers: the app kept asking after the user had already said no.
    ///
    /// A decline used to be indistinguishable from never having been asked. The item stayed blocked for
    /// background reads — correctly silent — but the next manual refresh escalated again and raised the
    /// identical dialog for the same item, and the user had no way to make it stop except to stop
    /// pressing Refresh Now.
    func testADeclinedItemIsNotPromptedForAgain() throws {
        let service = "com.example.declined"
        let key = KeychainItemKey(service: service)

        // Asked once; the user cancels, so even the interactive read fails.
        let cancelling = CancellingKeychain()
        XCTAssertThrowsError(
            try ProviderRefreshContext.$isManual.withValue(true) { try attemptManualRead(cancelling, service: service) }
        )
        XCTAssertEqual(cancelling.interactiveReads, 1, "precondition: the dialog was raised once")
        XCTAssertTrue(
            KeychainPermissionGate.shared.isDeclined(key),
            "a cancelled prompt must be remembered, or the next refresh raises the same dialog again"
        )

        // A later manual refresh must answer from memory instead of asking again.
        let wouldPromptAgain = GrantingKeychain()
        XCTAssertThrowsError(
            try ProviderRefreshContext.$isManual.withValue(true) { try attemptManualRead(wouldPromptAgain, service: service) }
        )
        XCTAssertEqual(
            wouldPromptAgain.interactiveReads, 0,
            "the app must not raise a second dialog for an item the user already declined"
        )
    }

    /// Declining one item must not lock out another — the gate is per item, and a grant on B still works.
    func testDecliningOneItemDoesNotAffectAnother() throws {
        let cancelling = CancellingKeychain()
        XCTAssertThrowsError(
            try ProviderRefreshContext.$isManual.withValue(true) {
                try attemptManualRead(cancelling, service: "com.example.a")
            }
        )
        XCTAssertTrue(KeychainPermissionGate.shared.isDeclined(KeychainItemKey(service: "com.example.a")))
        XCTAssertFalse(
            KeychainPermissionGate.shared.isDeclined(KeychainItemKey(service: "com.example.b")),
            "one declined item must not suppress a different one"
        )

        let granting = GrantingKeychain()
        let value = try ProviderRefreshContext.$isManual.withValue(true) {
            try attemptManualRead(granting, service: "com.example.b")
        }
        XCTAssertEqual(value, "secret")
    }

    /// The escape hatch. Without it, "asked once" would mean "never again this session", with no route
    /// back for a user who decides to grant after reading the copy.
    func testClearingADeclineAllowsAskingAgain() throws {
        let service = "com.example.reset"
        let cancelling = CancellingKeychain()
        XCTAssertThrowsError(
            try ProviderRefreshContext.$isManual.withValue(true) { try attemptManualRead(cancelling, service: service) }
        )
        XCTAssertTrue(KeychainPermissionGate.shared.isDeclined(KeychainItemKey(service: service)))

        KeychainPermissionGate.shared.clearDeclined(KeychainItemKey(service: service))
        XCTAssertFalse(KeychainPermissionGate.shared.isDeclined(KeychainItemKey(service: service)))

        let granting = GrantingKeychain()
        let value = try ProviderRefreshContext.$isManual.withValue(true) {
            try attemptManualRead(granting, service: service)
        }
        XCTAssertEqual(value, "secret", "after clearing, the app asks again and the grant works")
    }
}
