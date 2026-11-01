import Foundation
import XCTest
@testable import QuotaBar

@MainActor
final class CodexAutoResetCoordinatorTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    func testDefaultCodexAccountReceivesVerifiedLaunchIdentity() {
        XCTAssertEqual(
            CodexAutoResetCoordinator.verifiedIdentity(
                providerID: "codex", expectedIdentityKey: nil, defaultCodexIdentity: "primary-account"
            ),
            "primary-account"
        )
    }

    func testRegisteredCodexAccountKeepsItsOwnIdentity() {
        XCTAssertEqual(
            CodexAutoResetCoordinator.verifiedIdentity(
                providerID: "codex-account-secondary", expectedIdentityKey: "secondary-account",
                defaultCodexIdentity: "primary-account"
            ),
            "secondary-account"
        )
    }

    func testUnattributedAccountCannotInheritDefaultIdentity() {
        XCTAssertNil(CodexAutoResetCoordinator.verifiedIdentity(
            providerID: "codex-account-unknown", expectedIdentityKey: nil,
            defaultCodexIdentity: "primary-account"
        ))
        XCTAssertNil(CodexAutoResetCoordinator.verifiedIdentity(
            providerID: "codex", expectedIdentityKey: nil, defaultCodexIdentity: nil
        ))
    }

    func testPendingRetryCannotCrossAccountAfterDefaultLoginSwitch() async {
        let defaults = defaults()
        let due = credit("pending-credit", 45)
        var requests: [String] = []
        let original = CodexAutoResetCoordinator(accounts: ["codex": .init(
            availableCredits: { [due] },
            claim: { _, id, _ in requests.append("first:\(id)"); return .failed }
        )], defaults: defaults, now: { self.base },
           verifiedAccountIdentityByProviderID: ["codex": "account-A"])
        await original.runOnce(for: "codex")
        XCTAssertEqual(requests.count, 1)

        let afterSwitch = CodexAutoResetCoordinator(accounts: ["codex": .init(
            availableCredits: { [] },
            claim: { _, id, _ in requests.append("wrong-account:\(id)"); return .success }
        )], defaults: defaults, now: { self.base.addingTimeInterval(15) },
           verifiedAccountIdentityByProviderID: ["codex": "account-B"])
        await afterSwitch.runOnce(for: "codex")
        XCTAssertEqual(requests.count, 1, "A pending claim must not post under account B")

        let restored = CodexAutoResetCoordinator(accounts: ["codex": .init(
            availableCredits: { [] },
            claim: { _, id, _ in requests.append("retry:\(id)"); return .success }
        )], defaults: defaults, now: { self.base.addingTimeInterval(15) },
           verifiedAccountIdentityByProviderID: ["codex": "account-A"])
        await restored.runOnce(for: "codex")
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].replacingOccurrences(of: "first:", with: ""),
                       requests[1].replacingOccurrences(of: "retry:", with: ""))
    }

    func testProviderSlotCreditIDCanBeReusedByAnotherVerifiedAccount() async {
        let defaults = defaults()
        let due = credit("same-credit-id", 45)
        var count = 0
        let account = CodexAutoResetCoordinator.Account(
            availableCredits: { [due] },
            claim: { _, _, _ in count += 1; return .success }
        )
        let first = CodexAutoResetCoordinator(accounts: ["codex": account],
            defaults: defaults, now: { self.base },
            verifiedAccountIdentityByProviderID: ["codex": "account-A"])
        await first.runOnce(for: "codex")
        let second = CodexAutoResetCoordinator(accounts: ["codex": account],
            defaults: defaults, now: { self.base },
            verifiedAccountIdentityByProviderID: ["codex": "account-B"])
        await second.runOnce(for: "codex")
        XCTAssertEqual(count, 2, "A's successful claim cannot suppress B's credit")
    }

    func testVisibleStatusTracksRealLookupAndNextScheduledAttempt() async {
        let defaults = defaults(enabled: false)
        let expiry = base.addingTimeInterval(600)
        let subject = CodexAutoResetCoordinator(accounts: ["codex": .init(
            availableCredits: { [.init(id: "credit", expiresAt: expiry)] },
            claim: { _, _, _ in XCTFail("must not redeem early"); return .failed }
        )], defaults: defaults, now: { self.base })
        XCTAssertEqual(subject.status(for: "codex", enabled: false), .off)
        XCTAssertEqual(subject.status(for: "unknown", enabled: true), .unverified)
        XCTAssertEqual(subject.status(for: "codex", enabled: true), .checking)
        defaults.set(true, forKey: CodexAutoResetCoordinator.enabledKey)
        await subject.runOnce(for: "codex")
        XCTAssertEqual(subject.status(for: "codex", enabled: true), .scheduled(expiry.addingTimeInterval(-60)))
        subject.resetToDefaults()
        XCTAssertFalse(defaults.bool(forKey: CodexAutoResetCoordinator.enabledKey))
        subject.stop()
    }

    func testVisibleStatusDoesNotKeepSchedulingAConsumedCredit() async {
        let defaults = defaults()
        let due = credit("credit", 45)
        let subject = CodexAutoResetCoordinator(accounts: ["codex": .init(
            availableCredits: { [due] }, claim: { _, _, _ in .success }
        )], defaults: defaults, now: { self.base })
        await subject.runOnce(for: "codex")
        XCTAssertEqual(subject.status(for: "codex", enabled: true), .monitoring)
    }

    func testVisibleLookupFailureCannotLookLikeHealthyMonitoring() async {
        let subject = CodexAutoResetCoordinator(accounts: ["codex": .init(
            availableCredits: { nil }, claim: { _, _, _ in XCTFail("no lookup"); return .failed }
        )], defaults: defaults(), now: { self.base })
        await subject.runOnce(for: "codex")
        XCTAssertEqual(subject.status(for: "codex", enabled: true), .attention("Could not check reset credits"))
    }

    private func defaults(enabled: Bool = true) -> UserDefaults {
        let defaults = UserDefaults(suiteName: "CodexAutoResetTests-\(UUID().uuidString)")!
        defaults.set(enabled, forKey: CodexAutoResetCoordinator.enabledKey)
        return defaults
    }

    private func credit(_ id: String, _ secondsFromBase: TimeInterval) -> CodexResetCredit {
        CodexResetCredit(id: id, expiresAt: base.addingTimeInterval(secondsFromBase))
    }

    func testExactlyOneMinuteAndExpirationBoundaries() {
        for (seconds, expected) in [(61.0, 1.0), (60.0, 0.0), (1.0, 0.0)] {
            XCTAssertEqual(CodexAutoResetCoordinator.secondsUntilTrigger(
                expiresAt: base.addingTimeInterval(seconds), now: base), expected)
        }
        XCTAssertNil(CodexAutoResetCoordinator.secondsUntilTrigger(expiresAt: base, now: base))
        XCTAssertNil(CodexAutoResetCoordinator.secondsUntilTrigger(expiresAt: base.addingTimeInterval(-1), now: base))
    }

    func testEarlyAndExpiredCreditsDoNotRedeem() async {
        let defaults = defaults()
        var requests: [String] = []
        let early = credit("early", 61)
        let subject = CodexAutoResetCoordinator(accounts: ["codex": .init(
            availableCredits: { [early] },
            claim: { credit, _, _ in requests.append(credit.id); return .success }
        )], defaults: defaults, now: { self.base })
        let delay = await subject.runOnce(for: "codex")
        XCTAssertEqual(delay, 1)
        let expired = credit("expired", 0)
        let past = credit("past", -100)
        let finished = CodexAutoResetCoordinator(accounts: ["codex": .init(
            availableCredits: { [expired, past] },
            claim: { credit, _, _ in requests.append(credit.id); return .success }
        )], defaults: defaults, now: { self.base })
        _ = await finished.runOnce(for: "codex")
        XCTAssertTrue(requests.isEmpty)
    }

    func testDistinctAccountsSpendOnlyOwnExpiringCredits() async {
        let defaults = defaults()
        var requests: [String] = []
        let due = credit("due", 60)
        let later = credit("later", 3600)
        let accounts: [String: CodexAutoResetCoordinator.Account] = [
            "codex": .init(availableCredits: { [due, later] }, claim: { credit, _, _ in
                requests.append("first:\(credit.id)"); return .success
            }),
            "codex@other": .init(availableCredits: { [due] }, claim: { credit, _, _ in
                requests.append("other:\(credit.id)"); return .success
            })
        ]
        let subject = CodexAutoResetCoordinator(accounts: accounts, defaults: defaults, now: { self.base })
        await subject.runOnce(for: "codex")
        await subject.runOnce(for: "codex@other")
        await subject.runOnce(for: "codex")
        await subject.runOnce(for: "codex@other")
        XCTAssertEqual(requests, ["first:due", "other:due"])
    }

    func testTwoCreditsWithIdenticalExpiryAreNotConfused() async {
        let defaults = defaults()
        var seen: [String] = []
        let sameTime = [credit("a", 50), credit("b", 50)]
        let subject = CodexAutoResetCoordinator(accounts: ["codex": .init(
            availableCredits: { sameTime },
            claim: { credit, _, _ in seen.append(credit.id); return .success }
        )], defaults: defaults, now: { self.base })
        await subject.runOnce(for: "codex")
        await subject.runOnce(for: "codex")
        await subject.runOnce(for: "codex")
        XCTAssertEqual(seen, ["a", "b"])
    }

    func testRequestIDPersistsAcrossRestartsAndBoundedRetries() async {
        let defaults = defaults()
        var ids: [String] = []
        let banked = credit("credit-X", 55)
        let accounts: [String: CodexAutoResetCoordinator.Account] = ["codex": .init(
            availableCredits: { [banked] },
            claim: { _, id, _ in ids.append(id); return .failed }
        )]
        let first = CodexAutoResetCoordinator(accounts: accounts, defaults: defaults, now: { self.base })
        await first.runOnce(for: "codex")
        var later = base.addingTimeInterval(15)
        let restarted = CodexAutoResetCoordinator(accounts: accounts, defaults: defaults, now: { later })
        await restarted.runOnce(for: "codex")
        later = base.addingTimeInterval(30)
        await restarted.runOnce(for: "codex")
        await restarted.runOnce(for: "codex")
        XCTAssertEqual(ids.count, 3)
        XCTAssertEqual(Set(ids).count, 1)
    }

    func testDisabledToggleDoesNotLookUpOrClaim() async {
        let defaults = defaults(enabled: false)
        var lookups = 0
        var claims = 0
        let subject = CodexAutoResetCoordinator(accounts: ["codex": .init(
            availableCredits: { lookups += 1; return [self.credit("one", 50)] },
            claim: { _, _, _ in claims += 1; return .success }
        )], defaults: defaults, now: { self.base })
        await subject.runOnce(for: "codex")
        XCTAssertEqual(lookups, 0)
        XCTAssertEqual(claims, 0)
    }

    func testDisablingWhileAwaitingLookupDoesNotClaim() async {
        let defaults = defaults()
        var claims = 0
        let due = credit("one", 45)
        let subject = CodexAutoResetCoordinator(accounts: ["codex": .init(
            availableCredits: {
                defaults.set(false, forKey: CodexAutoResetCoordinator.enabledKey)
                return [due]
            },
            claim: { _, _, _ in claims += 1; return .success }
        )], defaults: defaults, now: { self.base })
        await subject.runOnce(for: "codex")
        XCTAssertEqual(claims, 0)
    }

    func testReenablingAfterPreflightCancellationKeepsCreditEligible() async {
        let defaults = defaults()
        let due = credit("one", 45)
        var claims = 0
        let account = CodexAutoResetCoordinator.Account(
            availableCredits: { [due] },
            claim: { _, _, _ in
                claims += 1
                if claims == 1 {
                    // The real claim service reports cancellation when the toggle is
                    // turned off after the scheduler has started its preflight.
                    defaults.set(false, forKey: CodexAutoResetCoordinator.enabledKey)
                    return .cancelled
                }
                return .success
            }
        )
        let first = CodexAutoResetCoordinator(
            accounts: ["codex": account], defaults: defaults, now: { self.base }
        )

        await first.runOnce(for: "codex")
        defaults.set(true, forKey: CodexAutoResetCoordinator.enabledKey)
        let restarted = CodexAutoResetCoordinator(
            accounts: ["codex": account], defaults: defaults, now: { self.base }
        )
        await restarted.runOnce(for: "codex")

        XCTAssertEqual(claims, 2, "a canceled preflight must not mark a still-live credit terminal")
    }

    func testUncertainFailureRetriesSameRequestAsAnIdempotentReplay() async {
        let defaults = defaults()
        let due = credit("uncertain-credit", 45)
        var claims: [(requestID: String, isRetry: Bool)] = []
        let account = CodexAutoResetCoordinator.Account(
            availableCredits: { [due] },
            claim: { credit, requestID, _ in
                claims.append((requestID, credit.isRetry))
                return claims.count == 1 ? .failed : .success
            }
        )
        let first = CodexAutoResetCoordinator(
            accounts: ["codex": account], defaults: defaults, now: { self.base }
        )
        await first.runOnce(for: "codex")

        let retry = CodexAutoResetCoordinator(
            accounts: ["codex": account], defaults: defaults,
            now: { self.base.addingTimeInterval(15) }
        )
        await retry.runOnce(for: "codex")

        XCTAssertEqual(claims.count, 2)
        XCTAssertEqual(claims[0].requestID, claims[1].requestID)
        XCTAssertEqual(claims.map(\.isRetry), [false, true])
    }

    func testRestartAfterEnablingStartsImmediateLookup() async {
        let defaults = defaults(enabled: false)
        let lookedUp = expectation(description: "enabled worker checks credits immediately")
        var lookups = 0
        let subject = CodexAutoResetCoordinator(accounts: ["codex": .init(
            availableCredits: {
                lookups += 1
                lookedUp.fulfill()
                return []
            },
            claim: { _, _, _ in .failed }
        )], defaults: defaults, now: { self.base })
        defer { subject.stop() }

        subject.start()
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(lookups, 0, "the disabled worker must stay idle")
        defaults.set(true, forKey: CodexAutoResetCoordinator.enabledKey)
        subject.restart()

        await fulfillment(of: [lookedUp], timeout: 1)
        XCTAssertEqual(lookups, 1)
    }

    func testAuthorizationIsRecheckedImmediatelyBeforePost() async {
        let defaults = defaults()
        var calls = 0
        let banked = credit("one", 45)
        let subject = CodexAutoResetCoordinator(accounts: ["codex": .init(
            availableCredits: { [banked] },
            claim: { _, _, canRedeem in
                defaults.set(false, forKey: CodexAutoResetCoordinator.enabledKey)
                if canRedeem() { calls += 1 }
                return .noCredit
            }
        )], defaults: defaults, now: { self.base })
        await subject.runOnce(for: "codex")
        XCTAssertEqual(calls, 0)
    }

    func testUnknownExpiryNeverCausesConsumption() async {
        let defaults = defaults()
        var calls = 0
        let subject = CodexAutoResetCoordinator(accounts: ["codex": .init(
            availableCredits: { nil },
            claim: { _, _, _ in calls += 1; return .success }
        )], defaults: defaults, now: { self.base })
        await subject.runOnce(for: "codex")
        XCTAssertEqual(calls, 0)
    }

    func testNoResetNeededIsTerminalWithoutSpendingOtherCredit() async {
        let defaults = defaults()
        var seen: [String] = []
        let one = credit("one", 50)
        let subject = CodexAutoResetCoordinator(accounts: ["codex": .init(
            availableCredits: { [one] },
            claim: { credit, _, _ in seen.append(credit.id); return .nothingToReset }
        )], defaults: defaults, now: { self.base })
        await subject.runOnce(for: "codex")
        await subject.runOnce(for: "codex")
        XCTAssertEqual(seen, ["one"])
    }

    func testInFlightDuplicateIsSuppressed() async {
        let defaults = defaults()
        var calls = 0
        let one = credit("one", 50)
        let subject = CodexAutoResetCoordinator(accounts: ["codex": .init(
            availableCredits: { [one] },
            claim: { _, _, _ in
                calls += 1
                try? await Task.sleep(for: .milliseconds(50))
                return .success
            }
        )], defaults: defaults, now: { self.base })
        async let first: TimeInterval = subject.runOnce(for: "codex")
        async let second: TimeInterval = subject.runOnce(for: "codex")
        _ = await (first, second)
        XCTAssertEqual(calls, 1)
    }

    func testRetryCooldownDoesNotDelayAnotherDueCredit() async {
        let defaults = defaults()
        let a = credit("a", 50)
        let b = credit("b", 51)
        var calls: [String] = []
        let subject = CodexAutoResetCoordinator(accounts: ["codex": .init(
            availableCredits: { [a, b] },
            claim: { credit, _, _ in
                calls.append(credit.id)
                return credit.id == "a" ? .failed : .success
            }
        )], defaults: defaults, now: { self.base })
        await subject.runOnce(for: "codex")
        await subject.runOnce(for: "codex")
        XCTAssertEqual(calls, ["a", "b"], "retry cooldown must not starve a distinct due credit")
    }

    func testFailureIsVisibleAndClearedBySuccess() async {
        let defaults = defaults()
        let a = credit("a", 40)
        let b = credit("b", 40)
        let subject = CodexAutoResetCoordinator(accounts: ["codex": .init(
            availableCredits: { [a, b] },
            claim: { credit, _, _ in credit.id == "a" ? .failed : .success }
        )], defaults: defaults, now: { self.base })
        await subject.runOnce(for: "codex")
        XCTAssertNotNil(subject.lastErrorByAccount["codex"])
        await subject.runOnce(for: "codex")
        XCTAssertNil(subject.lastErrorByAccount["codex"])
    }

    func testFailedOneAccountDoesNotBlockAnother() async {
        let defaults = defaults()
        var calls: [String] = []
        let one = credit("one", 30)
        let subject = CodexAutoResetCoordinator(accounts: [
            "codex": .init(availableCredits: { nil }, claim: { _, _, _ in
                calls.append("failed"); return .failed
            }),
            "codex@valid": .init(availableCredits: { [one] }, claim: { _, _, _ in
                calls.append("success"); return .success
            })
        ], defaults: defaults, now: { self.base })
        await subject.runOnce(for: "codex")
        await subject.runOnce(for: "codex@valid")
        XCTAssertEqual(calls, ["success"])
    }


    func testPendingCreditCanConfirmAfterItVanishesFromServerList() async {
        let defaults = defaults()
        let original = credit("original", 50)
        var lookups = 0
        var calls: [(String, Bool)] = []
        let subject = CodexAutoResetCoordinator(accounts: ["codex": .init(
            availableCredits: {
                defer { lookups += 1 }
                return lookups == 0 ? [original] : []
            },
            claim: { credit, requestID, _ in
                calls.append((requestID, credit.isRetry))
                return calls.count == 1 ? .failed : .success
            }
        )], defaults: defaults, now: { self.base })
        await subject.runOnce(for: "codex")
        XCTAssertEqual(calls.count, 1)
        XCTAssertFalse(calls[0].1)
        // The second GET no longer lists the credit, simulating an accepted POST whose
        // HTTP response was lost; the original UUID/ID must still be replayable.
        var next = base.addingTimeInterval(15)
        let restarted = CodexAutoResetCoordinator(accounts: ["codex": .init(
            availableCredits: { [] },
            claim: { credit, requestID, _ in
                calls.append((requestID, credit.isRetry))
                return .success
            }
        )], defaults: defaults, now: { next })
        await restarted.runOnce(for: "codex")
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].0, calls[1].0)
        XCTAssertTrue(calls[1].1)
        next = base.addingTimeInterval(20)
        await restarted.runOnce(for: "codex")
        XCTAssertEqual(calls.count, 2)
    }

    func testDisabledWorkerSleepsRatherThanBusyPolling() async {
        let defaults = defaults(enabled: false)
        var lookups = 0
        let subject = CodexAutoResetCoordinator(accounts: ["codex": .init(
            availableCredits: { lookups += 1; return [] },
            claim: { _, _, _ in .failed }
        )], defaults: defaults, now: { self.base })
        let interval = await subject.runOnce(for: "codex")
        XCTAssertEqual(interval, 3_600)
        XCTAssertEqual(lookups, 0)
    }


    func testLookupFailureClearsWhenNextCheckSucceeds() async {
        let defaults = defaults()
        var queries = 0
        let subject = CodexAutoResetCoordinator(accounts: ["codex": .init(
            availableCredits: {
                defer { queries += 1 }
                return queries == 0 ? nil : []
            },
            claim: { _, _, _ in .success }
        )], defaults: defaults, now: { self.base })
        XCTAssertEqual(subject.monitoredAccountCount, 1)
        await subject.runOnce(for: "codex")
        XCTAssertNotNil(subject.lastErrorByAccount["codex"])
        await subject.runOnce(for: "codex")
        XCTAssertNil(subject.lastErrorByAccount["codex"])
    }
}
