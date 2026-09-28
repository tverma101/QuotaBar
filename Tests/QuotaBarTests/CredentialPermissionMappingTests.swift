import Foundation
import XCTest
@testable import QuotaBar

/// Regression coverage for a real, user-visible misdiagnosis.
///
/// A Keychain item that macOS refuses to release without a dialog was swallowed into `nil`, so the
/// provider reported `notLoggedIn`. The user is signed in; the only thing that helps is one Refresh plus
/// "Always Allow". Worse than the bad wording, the resulting snapshot had no error line, so
/// `WidgetDataStore` treated the refresh as a *success*: meters looked live, `refreshedAt` was stamped,
/// the negative-cache backoff never engaged, and the app re-probed the item every five minutes forever.
///
/// Antigravity and Claude Desktop already modelled this correctly
/// (`credentialPermissionRequired` / `desktopPermissionRequired`). These tests pin the same contract
/// for Codex, Copilot, and Cursor, and cover the accessor's missing diagnostic.
final class CredentialPermissionMappingTests: XCTestCase {
    /// Every provider that reads its credential from the Keychain must be able to distinguish "no
    /// credential" from "macOS won't release the credential".
    private static let keychainBackedProviders: [String] = ["Codex", "Copilot", "Cursor"]

    override func setUp() {
        super.setUp()
        KeychainPermissionGate.shared.resetAll()
    }

    override func tearDown() {
        KeychainPermissionGate.shared.resetAll()
        super.tearDown()
    }

    // MARK: - Classification

    /// A refusal must land in `credentialAccess`, not `notLoggedIn`. `notLoggedIn` is the one bucket
    /// `ErrorCategory` documents as expected noise, so misfiling it there also blinded telemetry to a
    /// genuine configuration problem.
    func testRefusalIsCategorisedAsCredentialAccessNotNotLoggedIn() throws {
        XCTAssertEqual(Self.keychainBackedProviders.count, 3, "keep in sync with the list under test")

        XCTAssertEqual(CodexAuthError.credentialPermissionRequired.errorCategory, .credentialAccess)
        XCTAssertEqual(CopilotAuthError.credentialPermissionRequired.errorCategory, .credentialAccess)
        XCTAssertEqual(CursorAuthError.credentialPermissionRequired.errorCategory, .credentialAccess)

        // And the distinction is real, not cosmetic.
        XCTAssertNotEqual(CodexAuthError.credentialPermissionRequired, .notLoggedIn)
        XCTAssertNotEqual(CodexAuthError.credentialPermissionRequired.errorCategory, .notLoggedIn)
    }

    /// The remedy must name the action that works. "Run `codex` to authenticate" cannot fix a Keychain
    /// ACL, and sending a signed-in user to re-authenticate is what made this bug confusing.
    func testRefusalCopyNamesTheActionThatActuallyWorks() throws {
        for description in [
            CodexAuthError.credentialPermissionRequired.errorDescription,
            CopilotAuthError.credentialPermissionRequired.errorDescription,
            CursorAuthError.credentialPermissionRequired.errorDescription,
        ] {
            let text = try XCTUnwrap(description, "every case needs copy")
            XCTAssertTrue(
                text.lowercased().contains("permission"),
                "copy must say permission is needed, got: \(text)"
            )
            XCTAssertTrue(
                text.lowercased().contains("always allow"),
                "copy must name the dialog action, got: \(text)"
            )
        }
    }

    /// Every enum is `Equatable` and `LocalizedError`; the new case must not be the "unknown" default
    /// anywhere, which would silently reintroduce a wrong message.
    func testEveryCaseHasUserFacingCopy() throws {
        let all: [LocalizedError] = [
            CodexAuthError.credentialPermissionRequired,
            CopilotAuthError.credentialPermissionRequired,
            CursorAuthError.credentialPermissionRequired,
        ]
        for error in all {
            let description = try XCTUnwrap(error.errorDescription)
            XCTAssertFalse(description.isEmpty, "every case needs copy")
        }
    }

    // MARK: - Store behaviour

    // MARK: - Store behaviour

    /// The core regression: a refusing Keychain must throw the permission error, not return `nil`.
    func testCodexKeychainRefusalThrowsInsteadOfReturningNil() throws {
        let store = CodexAuthStore(files: FakeFiles(), keychain: RefusingKeychain())
        XCTAssertThrowsError(try store.loadKeychainAuth()) { error in
            XCTAssertEqual(error as? CodexAuthError, .credentialPermissionRequired)
        }
    }

    func testCopilotKeychainRefusalThrowsInsteadOfReturningNil() throws {
        let store = CopilotAuthStore(files: FakeFiles(), keychain: RefusingKeychain())
        XCTAssertThrowsError(try store.loadToken()) { error in
            XCTAssertEqual(error as? CopilotAuthError, .credentialPermissionRequired)
        }
    }

    func testCursorKeychainRefusalThrowsInsteadOfReturningNil() throws {
        let store = CursorAuthStore(sqlite: MissingSQLite(), keychain: RefusingKeychain())
        XCTAssertThrowsError(try store.loadAuthState()) { error in
            XCTAssertEqual(error as? CursorAuthError, .credentialPermissionRequired)
        }
    }

    /// The mirror case, and the reason the fix is scoped rather than blanket: a genuine miss must still
    /// be `nil`, never a permission error. Otherwise every unconfigured provider would claim macOS is
    /// withholding a credential that does not exist.
    func testGenuineMissStillReturnsNil() throws {
        XCTAssertNil(try CopilotAuthStore(files: FakeFiles(), keychain: FakeKeychain()).loadToken())
        XCTAssertNil(try CodexAuthStore(files: FakeFiles(), keychain: FakeKeychain()).loadKeychainAuth())
    }

    /// Copilot reads the gh item twice — account-scoped, then service-only. Those are different items
    /// with different ACLs, so a refusal on one must not be retried as the other, which is how a second
    /// dialog for the same item used to be raised on a manual refresh.
    func testCopilotDoesNotRetryTheOtherLookupAfterARefusal() throws {
        let keychain = RefusingKeychain()
        let store = CopilotAuthStore(files: FakeFiles(), keychain: keychain)

        XCTAssertThrowsError(try store.loadToken()) { error in
            XCTAssertEqual(error as? CopilotAuthError, .credentialPermissionRequired)
        }
        XCTAssertEqual(keychain.reads, 1, "must not re-raise the same refusal through the fallback lookup")
    }

    /// A refusal on the account-scoped item must not mask a readable service-only item: they are
    /// different Keychain items with independent ACLs.
    func testCopilotServiceOnlyItemStaysReadableWhenTheAccountScopedOneRefuses() throws {
        let store = CopilotAuthStore(
            files: FakeFiles(),
            keychain: RefusingKeychain(refusesAccountScoped: true, refusesServiceOnly: false)
        )
        XCTAssertEqual(try store.loadToken()?.value, CopilotAuthStore.ghKeychainService)
    }

    // MARK: - Fakes

    /// Models the real ACL: a silent read reports that interaction is required, and only an interactive
    /// read succeeds. `refusesAccountScoped` / `refusesServiceOnly` let a test refuse one lookup while
    /// the other still resolves.
    private final class RefusingKeychain: KeychainAccessing, @unchecked Sendable {
        private let lock = NSLock()
        private var readCount = 0
        private let refusesAccountScoped: Bool
        private let refusesServiceOnly: Bool

        init(refusesAccountScoped: Bool = true, refusesServiceOnly: Bool = true) {
            self.refusesAccountScoped = refusesAccountScoped
            self.refusesServiceOnly = refusesServiceOnly
        }

        var reads: Int {
            lock.lock(); defer { lock.unlock() }; return readCount
        }

        private func read(_ value: String?, allowInteraction: Bool) throws -> String? {
            lock.lock()
            readCount += 1
            lock.unlock()
            if allowInteraction { return value }
            throw KeychainError.interactionNotAllowed
        }

        /// The value the service-only lookup resolves with, so a passing assertion is meaningful.
        private var serviceOnlyValue: String { CopilotAuthStore.ghKeychainService }

        func readGenericPassword(service: String, account: String, allowInteraction: Bool) throws -> String? {
            // A service-only lookup is the one made without an account.
            if account == CopilotAuthStore.ghKeychainService { return serviceOnlyValue }
            return try read(nil, allowInteraction: refusesAccountScoped ? false : true)
        }

        func readGenericPassword(service: String, account: String) throws -> String? {
            try readGenericPassword(service: service, account: account, allowInteraction: false)
        }

        func readGenericPassword(service: String) throws -> String? {
            try read(serviceOnlyValue, allowInteraction: refusesServiceOnly ? false : true)
        }

        func readGenericPassword(service: String, allowInteraction: Bool) throws -> String? {
            try read(serviceOnlyValue, allowInteraction: allowInteraction || !refusesServiceOnly)
        }

        func writeGenericPassword(service: String, value: String) throws {}
        func readGenericPasswordForCurrentUser(service: String) throws -> String? { nil }
        func readGenericPasswordForCurrentUser(service: String, allowInteraction: Bool) throws -> String? { nil }
        func writeGenericPasswordForCurrentUser(service: String, value: String) throws {}
    }

    /// SQLite with no rows, so the Keychain is the only credential source in play.
    private final class MissingSQLite: SQLiteAccessing, @unchecked Sendable {
        func queryValue(path: String, sql: String) throws -> String? { nil }
        func execute(path: String, sql: String) throws {}
    }
}
