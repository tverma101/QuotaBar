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
        KeychainPermissionGate.shared.reset()
    }

    override func tearDown() {
        KeychainPermissionGate.shared.reset()
        super.tearDown()
    }

    /// The gate lives in the shared helper rather than in each provider, because the condition belongs
    /// to the item's ACL: once macOS says "this needs a dialog", every background refresh until the
    /// user grants it gets the same answer. This asserts the general contract.
    func testSuccessfulInteractiveReadClearsAPreviouslyBlockedItem() throws {
        let blocked = RecordingKeychain(requiresInteraction: true)
        XCTAssertThrowsError(try blocked.readGenericPasswordForRefresh(service: "svc"))
        XCTAssertTrue(KeychainPermissionGate.shared.isBlocked, "a silent-read failure must block later background attempts")

        // A *background* read cannot clear the block — it never reaches the Keychain, which is the
        // whole point. Only a manual refresh can, because only it can show the dialog that grants access.
        let stillBlocked = RecordingKeychain(requiresInteraction: false)
        XCTAssertThrowsError(try stillBlocked.readGenericPasswordForRefresh(service: "svc"))
        XCTAssertTrue(KeychainPermissionGate.shared.isBlocked)

        // The manual read reaches the Keychain, succeeds, and clears the block for everyone.
        let granted = RecordingKeychain(requiresInteraction: false)
        let value = try ProviderRefreshContext.$isManual.withValue(true) {
            try granted.readGenericPasswordForRefresh(service: "svc")
        }
        XCTAssertEqual(value, "secret")
        XCTAssertFalse(
            KeychainPermissionGate.shared.isBlocked,
            "granting access must not leave the item blocked for every other provider"
        )

        // And background reads work silently again.
        let afterwards = RecordingKeychain(requiresInteraction: false)
        _ = try afterwards.readGenericPasswordForRefresh(service: "svc")
        XCTAssertEqual(afterwards.calls, [false])
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
