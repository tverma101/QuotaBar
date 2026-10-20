import Foundation
import Security
import XCTest
@testable import QuotaBar

final class KeychainUserInteractionTests: XCTestCase {
    private final class Policy: @unchecked Sendable {
        private let lock = NSLock()
        private var allowed = true
        private var changes: [Bool] = []
        var getStatus: OSStatus = errSecSuccess
        var failedSetNumber: Int?

        func get() -> (OSStatus, Bool) {
            lock.lock()
            defer { lock.unlock() }
            return (getStatus, allowed)
        }

        func set(_ value: Bool) -> OSStatus {
            lock.lock()
            defer { lock.unlock() }
            changes.append(value)
            if changes.count == failedSetNumber { return errSecIO }
            allowed = value
            return errSecSuccess
        }

        var history: [Bool] {
            lock.lock()
            defer { lock.unlock() }
            return changes
        }
    }

    func testSilentQueryRestoresPolicyAfterSecurityFailure() {
        let policy = Policy()
        let interaction = KeychainUserInteraction(getAllowed: policy.get, setAllowed: policy.set)
        let status = interaction.perform(allowInteraction: false) {
            XCTAssertFalse(policy.get().1)
            return errSecInteractionNotAllowed
        }
        XCTAssertEqual(status, errSecInteractionNotAllowed)
        XCTAssertTrue(policy.get().1)
        XCTAssertEqual(policy.history, [false, true])
    }

    func testCannotReadOrSetPolicyFailsBeforeCallingSecurity() {
        let policy = Policy()
        let interaction = KeychainUserInteraction(getAllowed: policy.get, setAllowed: policy.set)
        policy.getStatus = errSecIO
        XCTAssertEqual(interaction.perform(allowInteraction: false) {
            XCTFail("must not query with an unknown interaction policy")
            return errSecSuccess
        }, errSecIO)
        XCTAssertEqual(policy.history, [])

        policy.getStatus = errSecSuccess
        policy.failedSetNumber = 1
        XCTAssertEqual(interaction.perform(allowInteraction: false) {
            XCTFail("must not query when UI could not be disabled")
            return errSecSuccess
        }, errSecIO)
        XCTAssertEqual(policy.history, [false])
    }

    func testRestoreFailureIsReportedAndLeavesUIDisabled() {
        let policy = Policy()
        policy.failedSetNumber = 2
        let interaction = KeychainUserInteraction(getAllowed: policy.get, setAllowed: policy.set)
        XCTAssertEqual(interaction.perform(allowInteraction: false) { errSecSuccess }, errSecIO)
        XCTAssertFalse(policy.get().1)
        XCTAssertEqual(policy.history, [false, true, false])
    }

    func testNestedSilentProbeRestoresOuterInteractivePolicy() {
        let policy = Policy()
        let interaction = KeychainUserInteraction(getAllowed: policy.get, setAllowed: policy.set)
        XCTAssertEqual(interaction.perform(allowInteraction: true) {
            XCTAssertTrue(policy.get().1)
            XCTAssertEqual(interaction.perform(allowInteraction: false) {
                XCTAssertFalse(policy.get().1)
                return errSecSuccess
            }, errSecSuccess)
            XCTAssertTrue(policy.get().1)
            return errSecSuccess
        }, errSecSuccess)
        XCTAssertTrue(policy.get().1)
        XCTAssertEqual(policy.history, [true, false, true, true])
    }

    func testConcurrentInteractiveQueryCannotEnableUIDuringSilentRead() {
        let policy = Policy()
        let interaction = KeychainUserInteraction(getAllowed: policy.get, setAllowed: policy.set)
        let silentStarted = DispatchSemaphore(value: 0)
        let releaseSilent = DispatchSemaphore(value: 0)
        let interactiveAttempted = DispatchSemaphore(value: 0)
        let interactiveStarted = DispatchSemaphore(value: 0)
        let finished = DispatchGroup()
        finished.enter()
        DispatchQueue.global().async {
            defer { finished.leave() }
            XCTAssertEqual(interaction.perform(allowInteraction: false) {
                silentStarted.signal()
                XCTAssertEqual(releaseSilent.wait(timeout: .now() + 3), .success)
                XCTAssertFalse(policy.get().1)
                return errSecSuccess
            }, errSecSuccess)
        }
        XCTAssertEqual(silentStarted.wait(timeout: .now() + 2), .success)
        finished.enter()
        DispatchQueue.global().async {
            defer { finished.leave() }
            interactiveAttempted.signal()
            XCTAssertEqual(interaction.perform(allowInteraction: true) {
                interactiveStarted.signal()
                XCTAssertTrue(policy.get().1)
                return errSecSuccess
            }, errSecSuccess)
        }
        XCTAssertEqual(interactiveAttempted.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(interactiveStarted.wait(timeout: .now() + 0.05), .timedOut)
        XCTAssertEqual(policy.history, [false])
        releaseSilent.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(interactiveStarted.wait(timeout: .now() + 1), .success)
        XCTAssertTrue(policy.get().1)
        XCTAssertEqual(policy.history, [false, true, true, true])
    }
}
