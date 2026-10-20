import XCTest
@testable import QuotaBar

/// The reset-credit claim: request shape, outcome decoding, expiry→id matching, and the service's full
/// list→consume flow — all through a stub HTTP client (the real endpoint is never touched; the protocol
/// itself was verified live once, see docs/research/codex-reset-credit-claim.md).
@MainActor
final class CodexResetClaimTests: XCTestCase {
    private nonisolated static let expiry = Date(timeIntervalSince1970: 1_800_000_000)

    /// Counts refreshAfterClaim invocations from the service's async context.
    private final class RefreshCounter: @unchecked Sendable {
        var count = 0
    }

    private nonisolated static func listBody(expiry: Date = expiry, status: String = "available") -> Data {
        Data("""
        {"credits": [
            {"id": "RateLimitResetCredit_other", "status": "available",
             "expires_at": "\(OpenUsageISO8601.string(from: expiry.addingTimeInterval(999_999)))"},
            {"id": "RateLimitResetCredit_target", "status": "\(status)",
             "expires_at": "\(OpenUsageISO8601.string(from: expiry))"}
        ], "available_count": 2}
        """.utf8)
    }

    private nonisolated static func consumeBody(code: String) -> Data {
        Data(#"{"code": "\#(code)", "windows_reset": 2}"#.utf8)
    }

    /// Routes the list GET and consume POST; anything else fails the test.
    private func makeService(
        listStatus: Int = 200,
        listBody: Data = listBody(),
        consumeStatus: Int = 200,
        consumeBody: Data = consumeBody(code: "reset"),
        refreshes: RefreshCounter = RefreshCounter()
    ) -> (CodexResetClaimService, RoutingHTTPClient) {
        let http = RoutingHTTPClient { request in
            switch request.url {
            case CodexUsageClient.resetCreditsURL:
                return HTTPResponse(statusCode: listStatus, headers: [:], body: listBody)
            case CodexUsageClient.consumeResetCreditURL:
                return HTTPResponse(statusCode: consumeStatus, headers: [:], body: consumeBody)
            default:
                XCTFail("unexpected request: \(request.url)")
                return HTTPResponse(statusCode: 500, headers: [:], body: Data())
            }
        }
        let service = CodexResetClaimService(
            usageClient: CodexUsageClient(http: http),
            credentialCandidates: { [("token-123", "acct-456")] },
            refreshAfterClaim: { refreshes.count += 1 }
        )
        return (service, http)
    }

    private func makeProductionService(
        authStore: CodexAuthStore,
        expectedAccessToken: String?
    ) -> (CodexResetClaimService, RoutingHTTPClient) {
        let http = RoutingHTTPClient { request in
            if let expectedAccessToken {
                XCTAssertEqual(request.headers["Authorization"], "Bearer \(expectedAccessToken)")
            }
            switch request.url {
            case CodexUsageClient.resetCreditsURL:
                return HTTPResponse(statusCode: 200, headers: [:], body: Self.listBody())
            case CodexUsageClient.consumeResetCreditURL:
                return HTTPResponse(statusCode: 200, headers: [:], body: Self.consumeBody(code: "reset"))
            default:
                XCTFail("unexpected request: \(request.url)")
                return HTTPResponse(statusCode: 500, headers: [:], body: Data())
            }
        }
        let service = CodexResetClaimService(
            authStore: authStore,
            usageClient: CodexUsageClient(http: http),
            refreshAfterClaim: {}
        )
        return (service, http)
    }

    // MARK: - Consume request shape

    func testConsumeRequestShape() async throws {
        let http = RoutingHTTPClient { _ in
            HTTPResponse(statusCode: 200, headers: [:], body: Self.consumeBody(code: "reset"))
        }
        let client = CodexUsageClient(http: http)
        _ = try await client.consumeResetCredit(
            accessToken: "token-123", accountID: "acct-456",
            creditID: "RateLimitResetCredit_target", redeemRequestID: "11111111-2222-3333-4444-555555555555"
        )

        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url, CodexUsageClient.consumeResetCreditURL)
        XCTAssertEqual(request.headers["Authorization"], "Bearer token-123")
        XCTAssertEqual(request.headers["ChatGPT-Account-Id"], "acct-456")
        XCTAssertEqual(request.headers["Content-Type"], "application/json")

        let body = try XCTUnwrap(request.body)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(payload, [
            "redeem_request_id": "11111111-2222-3333-4444-555555555555",
            "credit_id": "RateLimitResetCredit_target"
        ])
    }

    // MARK: - Outcome decoding

    func testConsumeOutcomeDecodesAllProtocolCodes() {
        func outcome(_ code: String, status: Int = 200) -> ResetClaimOutcome {
            CodexResetClaimService.outcome(fromConsume:
                HTTPResponse(statusCode: status, headers: [:], body: Self.consumeBody(code: code)))
        }
        XCTAssertEqual(outcome("reset"), .success)
        // The idempotency key already spent this credit on a lost-response retry — still a success.
        XCTAssertEqual(outcome("already_redeemed"), .success)
        XCTAssertEqual(outcome("nothing_to_reset"), .nothingToReset)
        XCTAssertEqual(outcome("no_credit"), .noCredit)
        XCTAssertEqual(outcome("something_new"), .failed)      // unknown code
        XCTAssertEqual(outcome("reset", status: 500), .failed) // non-2xx wins over a parseable body
        XCTAssertEqual(
            CodexResetClaimService.outcome(fromConsume:
                HTTPResponse(statusCode: 200, headers: [:], body: Data("not json".utf8))),
            .failed
        )
    }

    // MARK: - Expiry → credit-id matching

    func testCreditMatchingByExpiry() throws {
        let body = try XCTUnwrap(ProviderParse.jsonObject(Self.listBody()))
        XCTAssertEqual(
            CodexResetClaimService.creditID(in: body, expiringAt: Self.expiry),
            "RateLimitResetCredit_target"
        )
        // Sub-second truncation is tolerated; a different credit's expiry is not.
        XCTAssertEqual(
            CodexResetClaimService.creditID(in: body, expiringAt: Self.expiry.addingTimeInterval(0.5)),
            "RateLimitResetCredit_target"
        )
        XCTAssertNil(CodexResetClaimService.creditID(in: body, expiringAt: Self.expiry.addingTimeInterval(3600)))
    }

    func testCreditMatchingSkipsNonAvailableStatusButKeepsMissingStatus() throws {
        let redeemed = try XCTUnwrap(ProviderParse.jsonObject(Self.listBody(status: "redeemed")))
        XCTAssertNil(CodexResetClaimService.creditID(in: redeemed, expiringAt: Self.expiry))

        // No `status` field at all counts as available — mirrors the mapper's filter.
        let noStatus = try XCTUnwrap(ProviderParse.jsonObject(Data(
            #"{"credits": [{"id": "RateLimitResetCredit_bare", "expires_at": \#(Self.expiry.timeIntervalSince1970)}]}"#.utf8
        )))
        XCTAssertEqual(
            CodexResetClaimService.creditID(in: noStatus, expiringAt: Self.expiry),
            "RateLimitResetCredit_bare"
        )
    }

    // MARK: - Full claim flow

    func testClaimMatchesCreditConsumesItAndRefreshes() async throws {
        let refreshes = RefreshCounter()
        let (service, http) = makeService(refreshes: refreshes)

        let outcome = await service.claim(creditExpiringAt: Self.expiry, redeemRequestID: "redeem-1")

        XCTAssertEqual(outcome, .success)
        XCTAssertEqual(refreshes.count, 1, "a successful claim forces a Codex refresh before returning")
        XCTAssertEqual(http.requests.map(\.url),
                       [CodexUsageClient.resetCreditsURL, CodexUsageClient.consumeResetCreditURL])
        let consumeRequest = try XCTUnwrap(http.requests.last)
        let body = try XCTUnwrap(consumeRequest.body)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(payload["credit_id"], "RateLimitResetCredit_target", "the freshly matched id, by expiry")
        XCTAssertEqual(payload["redeem_request_id"], "redeem-1", "the caller's idempotency key, verbatim")
    }

    func testClaimWithNoMatchingCreditIsNoCreditWithoutConsuming() async {
        let refreshes = RefreshCounter()
        let (service, http) = makeService(
            listBody: Data(#"{"credits": [], "available_count": 0}"#.utf8),
            refreshes: refreshes
        )

        let outcome = await service.claim(creditExpiringAt: Self.expiry, redeemRequestID: "redeem-1")

        XCTAssertEqual(outcome, .noCredit)
        XCTAssertEqual(http.requests.map(\.url), [CodexUsageClient.resetCreditsURL], "no consume POST is ever sent")
        XCTAssertEqual(refreshes.count, 1, "the raced-away credit triggers a refresh to reconcile the timeline")
    }

    func testCancellationDuringLateSuccessfulCreditListPreventsConsumePost() async {
        let gate = ClaimListResponseGate()
        let refreshes = RefreshCounter()
        let http = RoutingHTTPClient { request in
            switch request.url {
            case CodexUsageClient.resetCreditsURL:
                await gate.pause()
                return HTTPResponse(statusCode: 200, headers: [:], body: Self.listBody())
            case CodexUsageClient.consumeResetCreditURL:
                XCTFail("a canceled list response must not start the consume POST")
                return HTTPResponse(statusCode: 200, headers: [:], body: Self.consumeBody(code: "reset"))
            default:
                XCTFail("unexpected request: \(request.url)")
                return HTTPResponse(statusCode: 500, headers: [:], body: Data())
            }
        }
        let service = CodexResetClaimService(
            usageClient: CodexUsageClient(http: http),
            credentialCandidates: { [("token", "account")] },
            refreshAfterClaim: { refreshes.count += 1 }
        )
        let claim = Task {
            await service.claim(creditExpiringAt: Self.expiry, redeemRequestID: "cancel-during-list")
        }

        await gate.waitUntilPaused()
        claim.cancel()
        await gate.open()

        let outcome = await claim.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(http.requests.map(\.url), [CodexUsageClient.resetCreditsURL])
        XCTAssertEqual(refreshes.count, 0)
    }

    func testClaimFailuresNeverRefreshAndNeverThrow() async {
        let refreshes = RefreshCounter()

        // List fetch fails.
        let (listFails, _) = makeService(listStatus: 503, refreshes: refreshes)
        let listOutcome = await listFails.claim(creditExpiringAt: Self.expiry, redeemRequestID: "redeem-1")
        XCTAssertEqual(listOutcome, .failed)

        // Consume returns a non-2xx.
        let (consumeFails, _) = makeService(
            consumeStatus: 500, consumeBody: Data("gateway error".utf8), refreshes: refreshes
        )
        let consumeOutcome = await consumeFails.claim(creditExpiringAt: Self.expiry, redeemRequestID: "redeem-1")
        XCTAssertEqual(consumeOutcome, .failed)

        // No credentials at all.
        let noCredentials = CodexResetClaimService(
            usageClient: CodexUsageClient(http: RoutingHTTPClient { _ in
                XCTFail("no request should be sent without credentials")
                return HTTPResponse(statusCode: 500, headers: [:], body: Data())
            }),
            credentialCandidates: { [] },
            refreshAfterClaim: { refreshes.count += 1 }
        )
        let credentialOutcome = await noCredentials.claim(creditExpiringAt: Self.expiry, redeemRequestID: "redeem-1")
        XCTAssertEqual(credentialOutcome, .failed)

        XCTAssertEqual(refreshes.count, 0, "failures leave the snapshot alone")
    }

    func testProductionClaimUsesManualKeychainPromptForCredentialLoad() async {
        let home = "/tmp/reset-claim-\(UUID().uuidString)"
        let keychain = ResetClaimTestKeychain(
            value: #"{"tokens":{"access_token":"keychain-token"}}"#
        )
        let authStore = CodexAuthStore(
            environment: FakeEnvironment(["CODEX_HOME": home]),
            files: FakeFiles(),
            keychain: keychain
        )
        let (service, http) = makeProductionService(authStore: authStore, expectedAccessToken: "keychain-token")

        let outcome = await withManualRefresh {
            await service.claim(creditExpiringAt: Self.expiry, redeemRequestID: "manual-keychain")
        }

        XCTAssertEqual(outcome, .success)
        XCTAssertEqual(keychain.interactionFlags, [false, true], "one manual claim may raise one Keychain prompt")
        XCTAssertEqual(http.requests.map(\.url), [CodexUsageClient.resetCreditsURL, CodexUsageClient.consumeResetCreditURL])
    }

    func testKeychainAccessFailureWithoutUsableFileHasCredentialAccessOutcome() async {
        let home = "/tmp/reset-claim-\(UUID().uuidString)"
        let keychain = ResetClaimTestKeychain(value: nil, refusesInteractiveRead: true)
        let authStore = CodexAuthStore(
            environment: FakeEnvironment(["CODEX_HOME": home]),
            files: FakeFiles(),
            keychain: keychain
        )
        let (service, http) = makeProductionService(authStore: authStore, expectedAccessToken: nil)

        let outcome = await withManualRefresh {
            await service.claim(creditExpiringAt: Self.expiry, redeemRequestID: "denied-keychain")
        }

        XCTAssertEqual(outcome, .credentialAccess)
        XCTAssertEqual(keychain.interactionFlags, [false, true], "the explicit action attempts Keychain once")
        XCTAssertTrue(http.requests.isEmpty, "credential access failure must stop before any claim request")
    }

    func testCancelledKeychainReadDoesNotBecomeCredentialAccessFailure() async {
        let home = "/tmp/reset-claim-\(UUID().uuidString)"
        let keychain = ResetClaimTestKeychain(value: nil, cancelsRead: true)
        let authStore = CodexAuthStore(
            environment: FakeEnvironment(["CODEX_HOME": home]),
            files: FakeFiles(),
            keychain: keychain
        )
        let (service, http) = makeProductionService(authStore: authStore, expectedAccessToken: nil)

        let outcome = await withManualRefresh {
            await service.claim(creditExpiringAt: Self.expiry, redeemRequestID: "cancelled-keychain")
        }

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(keychain.interactionFlags, [false], "cancellation must not trigger an interactive retry")
        XCTAssertTrue(http.requests.isEmpty, "a cancelled credential load must stop before claim requests")
    }

    func testReadableFileCredentialStillClaimsWhenKeychainAccessFails() async {
        let home = "/tmp/reset-claim-\(UUID().uuidString)"
        let keychain = ResetClaimTestKeychain(value: nil, refusesInteractiveRead: true)
        let authStore = CodexAuthStore(
            environment: FakeEnvironment(["CODEX_HOME": home]),
            files: FakeFiles([
                "\(home)/auth.json": #"{"tokens":{"access_token":"file-token"}}"#
            ]),
            keychain: keychain
        )
        let (service, http) = makeProductionService(authStore: authStore, expectedAccessToken: "file-token")

        let outcome = await withManualRefresh {
            await service.claim(creditExpiringAt: Self.expiry, redeemRequestID: "file-fallback")
        }

        XCTAssertEqual(outcome, .success, "a readable file candidate remains available if Keychain fails")
        XCTAssertEqual(keychain.interactionFlags, [])
        XCTAssertEqual(http.requests.count, 2)
    }

    func testClaimNothingToResetKeepsCreditAndRefreshes() async {
        let refreshes = RefreshCounter()
        let (service, _) = makeService(
            consumeBody: Self.consumeBody(code: "nothing_to_reset"),
            refreshes: refreshes
        )

        let outcome = await service.claim(creditExpiringAt: Self.expiry, redeemRequestID: "redeem-1")

        XCTAssertEqual(outcome, .nothingToReset)
        XCTAssertEqual(refreshes.count, 1)
    }

    // MARK: - Idempotent replay

    func testRetryWithSameKeyReplaysTheConsumeInsteadOfNoCredit() async throws {
        // First claim succeeds; the retry (same idempotency key) arrives after the credit has left the
        // list — the lost-response scenario. The service must replay the consume with the cached credit
        // id (the server answers `already_redeemed` → success), NOT re-match and misreport `.noCredit`.
        let listBodies = [Self.listBody(), Data(#"{"credits": [], "available_count": 0}"#.utf8)]
        let listCalls = RefreshCounter()
        let consumeCodes = ["reset", "already_redeemed"]
        let consumeCalls = RefreshCounter()
        let http = RoutingHTTPClient { request in
            switch request.url {
            case CodexUsageClient.resetCreditsURL:
                defer { listCalls.count += 1 }
                return HTTPResponse(statusCode: 200, headers: [:], body: listBodies[min(listCalls.count, 1)])
            case CodexUsageClient.consumeResetCreditURL:
                defer { consumeCalls.count += 1 }
                return HTTPResponse(statusCode: 200, headers: [:],
                                    body: Self.consumeBody(code: consumeCodes[min(consumeCalls.count, 1)]))
            default:
                XCTFail("unexpected request: \(request.url)")
                return HTTPResponse(statusCode: 500, headers: [:], body: Data())
            }
        }
        let service = CodexResetClaimService(
            usageClient: CodexUsageClient(http: http),
            credentialCandidates: { [("token-123", "acct-456")] }
        )

        let first = await service.claim(creditExpiringAt: Self.expiry, redeemRequestID: "redeem-1")
        let retry = await service.claim(creditExpiringAt: Self.expiry, redeemRequestID: "redeem-1")

        XCTAssertEqual(first, .success)
        XCTAssertEqual(retry, .success, "already_redeemed proves the original claim landed")
        XCTAssertEqual(listCalls.count, 1, "the replay skips re-matching entirely")
        XCTAssertEqual(consumeCalls.count, 2)
        let replay = try XCTUnwrap(http.requests.last)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(replay.body)) as? [String: String])
        XCTAssertEqual(payload["credit_id"], "RateLimitResetCredit_target", "the originally matched credit id")
    }

    // MARK: - Credential fallback

    func testClaimFallsBackAcrossCredentialCandidatesOnAuthRejection() async throws {
        // The first candidate is stale (401 on the list fetch); the provider's probe would fall back to
        // the second, and so must the claim.
        let http = RoutingHTTPClient { request in
            let stale = request.headers["Authorization"] == "Bearer stale-token"
            switch request.url {
            case CodexUsageClient.resetCreditsURL:
                return stale
                    ? HTTPResponse(statusCode: 401, headers: [:], body: Data())
                    : HTTPResponse(statusCode: 200, headers: [:], body: Self.listBody())
            case CodexUsageClient.consumeResetCreditURL:
                XCTAssertFalse(stale, "consume must use the candidate that authenticated the list fetch")
                return HTTPResponse(statusCode: 200, headers: [:], body: Self.consumeBody(code: "reset"))
            default:
                XCTFail("unexpected request: \(request.url)")
                return HTTPResponse(statusCode: 500, headers: [:], body: Data())
            }
        }
        let service = CodexResetClaimService(
            usageClient: CodexUsageClient(http: http),
            credentialCandidates: { [("stale-token", "acct-old"), ("live-token", "acct-456")] }
        )

        let outcome = await service.claim(creditExpiringAt: Self.expiry, redeemRequestID: "redeem-1")

        XCTAssertEqual(outcome, .success)
        let consume = try XCTUnwrap(http.requests.last)
        XCTAssertEqual(consume.headers["Authorization"], "Bearer live-token")
    }

    func testConsumeFallsBackToSameTokenDifferentAccountCandidate() async throws {
        // ChatGPT-Account-Id changes what a token is authorized for: a same-token candidate with a
        // different account is a distinct fallback and must not be deduplicated away. The list fetch
        // authenticates with account A, the consume is rejected for A and must retry with account B —
        // safe, because both attempts carry the same idempotency key.
        let http = RoutingHTTPClient { request in
            switch request.url {
            case CodexUsageClient.resetCreditsURL:
                return HTTPResponse(statusCode: 200, headers: [:], body: Self.listBody())
            case CodexUsageClient.consumeResetCreditURL:
                return request.headers["ChatGPT-Account-Id"] == "acct-A"
                    ? HTTPResponse(statusCode: 403, headers: [:], body: Data())
                    : HTTPResponse(statusCode: 200, headers: [:], body: Self.consumeBody(code: "reset"))
            default:
                XCTFail("unexpected request: \(request.url)")
                return HTTPResponse(statusCode: 500, headers: [:], body: Data())
            }
        }
        let service = CodexResetClaimService(
            usageClient: CodexUsageClient(http: http),
            credentialCandidates: { [("shared-token", "acct-A"), ("shared-token", "acct-B")] }
        )

        let outcome = await service.claim(creditExpiringAt: Self.expiry, redeemRequestID: "redeem-1")

        XCTAssertEqual(outcome, .success)
        let consume = try XCTUnwrap(http.requests.last)
        XCTAssertEqual(consume.headers["ChatGPT-Account-Id"], "acct-B")
    }

    func testClaimFailsWhenEveryCandidateIsRejected() async {
        let http = RoutingHTTPClient { _ in HTTPResponse(statusCode: 401, headers: [:], body: Data()) }
        let service = CodexResetClaimService(
            usageClient: CodexUsageClient(http: http),
            credentialCandidates: { [("stale-1", nil), ("stale-2", nil)] }
        )

        let outcome = await service.claim(creditExpiringAt: Self.expiry, redeemRequestID: "redeem-1")

        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(http.requests.count, 2, "every candidate is tried once, then the claim fails loudly")
    }
}

private final class ResetClaimTestKeychain: KeychainAccessing, @unchecked Sendable {
    private let lock = NSLock()
    private let value: String?
    private let requiresInteraction: Bool
    private let refusesInteractiveRead: Bool
    private let cancelsRead: Bool
    private var recordedInteractionFlags: [Bool] = []

    var interactionFlags: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return recordedInteractionFlags
    }

    init(
        value: String?,
        requiresInteraction: Bool = true,
        refusesInteractiveRead: Bool = false,
        cancelsRead: Bool = false
    ) {
        self.value = value
        self.requiresInteraction = requiresInteraction
        self.refusesInteractiveRead = refusesInteractiveRead
        self.cancelsRead = cancelsRead
    }

    private func read(allowInteraction: Bool) throws -> String? {
        lock.lock()
        recordedInteractionFlags.append(allowInteraction)
        lock.unlock()
        if cancelsRead {
            throw CancellationError()
        }
        guard allowInteraction || !requiresInteraction else {
            throw KeychainError.interactionNotAllowed
        }
        if allowInteraction && refusesInteractiveRead {
            throw KeychainError.interactionNotAllowed
        }
        return value
    }

    func readGenericPassword(service: String) throws -> String? {
        try read(allowInteraction: true)
    }

    func readGenericPassword(service: String, allowInteraction: Bool) throws -> String? {
        try read(allowInteraction: allowInteraction)
    }

    func readGenericPassword(service: String, account: String) throws -> String? {
        try read(allowInteraction: true)
    }

    func readGenericPassword(service: String, account: String, allowInteraction: Bool) throws -> String? {
        try read(allowInteraction: allowInteraction)
    }

    func writeGenericPassword(service: String, value: String) throws {}
    func writeGenericPassword(service: String, account: String, value: String) throws {}
}

private actor ClaimListResponseGate {
    private var paused = false
    private var released = false
    private var pauseContinuation: CheckedContinuation<Void, Never>?
    private var enteredContinuation: CheckedContinuation<Void, Never>?

    func pause() async {
        paused = true
        enteredContinuation?.resume()
        enteredContinuation = nil
        guard !released else { return }
        await withCheckedContinuation { pauseContinuation = $0 }
    }

    func waitUntilPaused() async {
        guard !paused else { return }
        await withCheckedContinuation { enteredContinuation = $0 }
    }

    func open() {
        released = true
        pauseContinuation?.resume()
        pauseContinuation = nil
    }
}
