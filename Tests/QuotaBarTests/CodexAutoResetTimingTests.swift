import Foundation
import XCTest
import os
@testable import QuotaBar

@MainActor
final class CodexAutoResetTimingTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func defaults() -> UserDefaults {
        let store = UserDefaults(suiteName: "CodexResetTiming-\(UUID().uuidString)")!
        store.set(true, forKey: CodexAutoResetCoordinator.enabledKey)
        return store
    }

    func testFirstLookupFailureDoesNotSleepThroughTheEntireRedemptionWindow() async {
        let subject = CodexAutoResetCoordinator(accounts: ["codex": .init(
            availableCredits: { nil }, claim: { _, _, _ in XCTFail("no fresh credit"); return .failed }
        )], defaults: defaults(), now: { self.base })
        let delay = await subject.runOnce(for: "codex")
        XCTAssertLessThanOrEqual(delay, 15, "a first failed check must not idle for five minutes")
    }

    func testPreflightPostponedExpiryReschedulesInsteadOfTerminalizingCredit() async {
        let original = Date().addingTimeInterval(45)
        let postponed = original.addingTimeInterval(3_600)
        let (service, http) = service(expiry: postponed)
        let result = await service.claimAuto(credit: .init(id: "target", expiresAt: original),
            redeemRequestID: "request", canRedeem: { true })
        XCTAssertEqual(result, .cancelled, "a changed expiry is a pre-POST reschedule, not a lost credit")
        XCTAssertEqual(http.requests.map(\.url), [CodexUsageClient.resetCreditsURL])
    }

    func testClaimServiceItselfRejectsEarlyRedemption() async {
        let future = Date().addingTimeInterval(600)
        let (service, http) = service(expiry: future)
        let result = await service.claimAuto(credit: .init(id: "target", expiresAt: future),
            redeemRequestID: "request", canRedeem: { true })
        XCTAssertEqual(result, .cancelled)
        XCTAssertTrue(http.requests.isEmpty, "the write boundary must recheck timing even if a caller is stale")
    }

    func testWakeDuringLookupIsBufferedAndChecksAgainImmediately() async {
        let center = NotificationCenter()
        let checkedAgain = expectation(description: "buffered wake performs another check")
        var checks = 0
        let subject = CodexAutoResetCoordinator(accounts: ["codex": .init(
            availableCredits: {
                checks += 1
                if checks == 1 {
                    center.post(name: CodexAutoResetCoordinator.wakeNotification, object: nil)
                } else if checks == 2 { checkedAgain.fulfill() }
                return [.init(id: "future", expiresAt: self.base.addingTimeInterval(600))]
            }, claim: { _, _, _ in XCTFail("future credit"); return .failed }
        )], defaults: defaults(), now: { self.base }, wakeCenter: center)
        defer { subject.stop() }
        subject.start()
        await fulfillment(of: [checkedAgain], timeout: 1)
        XCTAssertEqual(checks, 2)
    }

    func testWakeDuringConsumeDoesNotCancelOrDuplicateTheWrite() async {
        let center = NotificationCenter()
        let began = expectation(description: "consume in flight")
        let checkedAgain = expectation(description: "wake consumed after POST")
        var release: CheckedContinuation<Void, Never>?
        var checks = 0
        var writes = 0
        let subject = CodexAutoResetCoordinator(accounts: ["codex": .init(
            availableCredits: {
                checks += 1
                if checks == 2 { checkedAgain.fulfill() }
                return [.init(id: "due", expiresAt: self.base.addingTimeInterval(45))]
            }, claim: { _, _, _ in
                writes += 1
                began.fulfill()
                await withCheckedContinuation { release = $0 }
                XCTAssertFalse(Task.isCancelled)
                return .success
            }
        )], defaults: defaults(), now: { self.base }, wakeCenter: center)
        defer { subject.stop(); release?.resume(); release = nil }
        subject.start()
        await fulfillment(of: [began], timeout: 1)
        center.post(name: CodexAutoResetCoordinator.wakeNotification, object: nil)
        release?.resume(); release = nil
        await fulfillment(of: [checkedAgain], timeout: 1)
        XCTAssertEqual(writes, 1)
    }

    func testObservedDeadlineSurvivesAnOfflineRestart() async {
        let store = defaults()
        let credit = CodexResetCredit(id: "known", expiresAt: base.addingTimeInterval(90))
        let first = CodexAutoResetCoordinator(accounts: ["codex": .init(
            availableCredits: { [credit] }, claim: { _, _, _ in XCTFail("too early"); return .failed }
        )], defaults: store, now: { self.base }, verifiedAccountIdentityByProviderID: ["codex": "owner"])
        await first.runOnce(for: "codex")
        let restarted = CodexAutoResetCoordinator(accounts: ["codex": .init(
            availableCredits: { nil }, claim: { _, _, _ in XCTFail("no live validation"); return .failed }
        )], defaults: store, now: { self.base }, verifiedAccountIdentityByProviderID: ["codex": "owner"])
        XCTAssertEqual(restarted.status(for: "codex", enabled: true), .scheduled(credit.expiresAt.addingTimeInterval(-60)))
        let delay = await restarted.runOnce(for: "codex")
        XCTAssertEqual(delay, 10)
    }

    func testPassingAnObservedWindowIsVisibleAndNeverPostsAfterExpiry() async {
        let store = defaults()
        var now = base
        var credits = [CodexResetCredit(id: "known", expiresAt: base.addingTimeInterval(90))]
        var writes = 0
        let account = CodexAutoResetCoordinator.Account(
            availableCredits: { credits }, claim: { _, _, _ in writes += 1; return .success }
        )
        let first = CodexAutoResetCoordinator(accounts: ["codex": account], defaults: store,
            now: { now }, verifiedAccountIdentityByProviderID: ["codex": "owner"])
        await first.runOnce(for: "codex")
        now = base.addingTimeInterval(100)
        credits = []
        await first.runOnce(for: "codex")
        XCTAssertEqual(first.status(for: "codex", enabled: true), .windowPassed(nextAttempt: nil))
        XCTAssertEqual(writes, 0)
        let switched = CodexAutoResetCoordinator(accounts: ["codex": account], defaults: store,
            now: { now }, verifiedAccountIdentityByProviderID: ["codex": "another-owner"])
        XCTAssertEqual(switched.status(for: "codex", enabled: true), .checking,
            "an expired credit notice must not cross verified account identity")
    }

    func testLiveDeadlineUpdatesReplaceUnsentCachedExpiry() async {
        let store = defaults()
        var expiry = base.addingTimeInterval(90)
        let account = CodexAutoResetCoordinator.Account(
            availableCredits: { [.init(id: "same", expiresAt: expiry)] },
            claim: { _, _, _ in XCTFail("too early"); return .failed }
        )
        let subject = CodexAutoResetCoordinator(accounts: ["codex": account], defaults: store, now: { self.base })
        await subject.runOnce(for: "codex")
        expiry = base.addingTimeInterval(600)
        await subject.runOnce(for: "codex")
        let restarted = CodexAutoResetCoordinator(accounts: ["codex": account], defaults: store, now: { self.base })
        XCTAssertEqual(restarted.status(for: "codex", enabled: true), .scheduled(expiry.addingTimeInterval(-60)))
    }

    func testExpiryIsRecheckedBeforeEachSameAccountCredentialFallback() async {
        let expiry = base.addingTimeInterval(45)
        let state = OSAllocatedUnfairLock(initialState: (now: base, writes: 0))
        let body = Data("""
        {"credits":[{"id":"target","status":"available","expires_at":"\(OpenUsageISO8601.string(from: expiry))"}]}
        """.utf8)
        let http = RoutingHTTPClient { request in
            if request.url == CodexUsageClient.resetCreditsURL {
                return HTTPResponse(statusCode: 200, headers: [:], body: body)
            }
            state.withLock { $0.writes += 1; $0.now = expiry.addingTimeInterval(1) }
            return HTTPResponse(statusCode: 401, headers: [:], body: Data())
        }
        let service = CodexResetClaimService(usageClient: .init(http: http),
            credentialCandidates: { [("stale", "same-account"), ("fresh", "same-account")] },
            now: { state.withLock { $0.now } })
        let outcome = await service.claimAuto(credit: .init(id: "target", expiresAt: expiry),
            redeemRequestID: "same-request", canRedeem: { true })
        XCTAssertEqual(outcome, .noCredit)
        XCTAssertEqual(state.withLock { $0.writes }, 1, "a late auth rejection must not start another consume after expiry")
    }

    private func service(expiry: Date) -> (CodexResetClaimService, RoutingHTTPClient) {
        let body = Data("""
        {"credits":[{"id":"target","status":"available","reset_type":"codex_rate_limits",
        "expires_at":"\(OpenUsageISO8601.string(from: expiry))"}]}
        """.utf8)
        let http = RoutingHTTPClient { request in
            if request.url == CodexUsageClient.resetCreditsURL {
                return HTTPResponse(statusCode: 200, headers: [:], body: body)
            }
            return HTTPResponse(statusCode: 200, headers: [:], body: Data("{\"code\":\"reset\"}".utf8))
        }
        return (CodexResetClaimService(usageClient: .init(http: http),
            credentialCandidates: { [("fixture-token", "fixture-account")] }), http)
    }
}
