import Foundation
import XCTest
@testable import QuotaBar

/// Regression coverage for the actual credit-ID-based auto-claim HTTP path. This never calls
/// the real backend; RoutingHTTPClient records requests and returns fixture JSON.
@MainActor
final class CodexAutoResetClaimTests: XCTestCase {
    private func fixture(_ credits: [String], expiry: Date) -> Data {
        let available: [[String: Any]] = credits.map { id in
            ["id": id, "status": "available", "reset_type": "codex_rate_limits",
             "expires_at": OpenUsageISO8601.string(from: expiry)]
        }
        return try! JSONSerialization.data(withJSONObject: [
            "credits": available, "available_count": credits.count
        ])
    }

    private func service(
        body: Data,
        consumeCode: String = "reset"
    ) -> (CodexResetClaimService, RoutingHTTPClient) {
        let http = RoutingHTTPClient { request in
            switch request.url {
            case CodexUsageClient.resetCreditsURL:
                return HTTPResponse(statusCode: 200, headers: [:], body: body)
            case CodexUsageClient.consumeResetCreditURL:
                return HTTPResponse(statusCode: 200, headers: [:], body: Data("{\"code\":\"\(consumeCode)\"}".utf8))
            default:
                XCTFail("unexpected endpoint: \(request.url)")
                return HTTPResponse(statusCode: 500, headers: [:], body: Data())
            }
        }
        return (
            CodexResetClaimService(
                usageClient: CodexUsageClient(http: http),
                credentialCandidates: { [("token", "account-X")] }
            ), http
        )
    }

    func testSameExpirySelectsExactCreditID() async throws {
        let expiry = Date().addingTimeInterval(45)
        let (service, http) = service(body: fixture(["other", "target"], expiry: expiry))
        let outcome = await service.claimAuto(
            credit: CodexResetCredit(id: "target", expiresAt: expiry),
            redeemRequestID: "request-id", canRedeem: { true }
        )
        XCTAssertEqual(outcome, .success)
        XCTAssertEqual(http.requests.map(\.url), [CodexUsageClient.resetCreditsURL, CodexUsageClient.consumeResetCreditURL])
        let post = try XCTUnwrap(http.requests.last)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(post.body)) as? [String: String])
        XCTAssertEqual(payload["credit_id"], "target")
        XCTAssertEqual(payload["redeem_request_id"], "request-id")
        XCTAssertEqual(post.headers["ChatGPT-Account-Id"], "account-X")
    }

    func testNoPostForCreditMissingFromFreshList() async {
        let expiry = Date().addingTimeInterval(30)
        let (service, http) = service(body: fixture(["another"], expiry: expiry))
        let outcome = await service.claimAuto(
            credit: .init(id: "target", expiresAt: expiry),
            redeemRequestID: UUID().uuidString, canRedeem: { true }
        )
        XCTAssertEqual(outcome, .noCredit)
        XCTAssertEqual(http.requests.map(\.url), [CodexUsageClient.resetCreditsURL])
    }

    func testNoPostAfterCreditExpires() async {
        let expiry = Date().addingTimeInterval(-1)
        let (service, http) = service(body: fixture(["target"], expiry: expiry))
        let outcome = await service.claimAuto(
            credit: .init(id: "target", expiresAt: expiry),
            redeemRequestID: UUID().uuidString, canRedeem: { true }
        )
        XCTAssertEqual(outcome, .noCredit)
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testOptOutPreventsEvenTheRead() async {
        let expiry = Date().addingTimeInterval(40)
        let (service, http) = service(body: fixture(["target"], expiry: expiry))
        let outcome = await service.claimAuto(
            credit: .init(id: "target", expiresAt: expiry),
            redeemRequestID: UUID().uuidString, canRedeem: { false }
        )
        XCTAssertEqual(outcome, .noCredit)
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testRejectedAndUnsupportedCreditsAreNotOffered() async throws {
        let expiry = Date().addingTimeInterval(40)
        let instant = OpenUsageISO8601.string(from: expiry)
        let body = Data("""
        {"credits": [
           {"id":"usable","status":"available","expires_at":"\(instant)"},
           {"id":"used","status":"redeemed","expires_at":"\(instant)"},
           {"id":"wrong-type","status":"available","reset_type":"another","expires_at":"\(instant)"},
           {"id":"no-expiry","status":"available","expires_at":null},
           {"status":"available","expires_at":"\(instant)"}
        ],"available_count":5}
        """.utf8)
        let (service, http) = service(body: body)
        let result = await service.availableCredits()
        let credits = try XCTUnwrap(result)
        XCTAssertEqual(credits.map(\.id), ["usable"])
        XCTAssertEqual(http.requests.map(\.url), [CodexUsageClient.resetCreditsURL])
    }

    func testFailedPostNeverFallsBackToAnotherAccount() async {
        let expiry = Date().addingTimeInterval(40)
        let body = fixture(["target"], expiry: expiry)
        let http = RoutingHTTPClient { request in
            if request.url == CodexUsageClient.resetCreditsURL {
                return HTTPResponse(statusCode: 200, headers: [:], body: body)
            }
            return HTTPResponse(statusCode: 403, headers: [:], body: Data())
        }
        let service = CodexResetClaimService(
            usageClient: CodexUsageClient(http: http),
            credentialCandidates: { [("token-A", "acct-A"), ("token-B", "acct-B")] }
        )
        let result = await service.claimAuto(
            credit: .init(id: "target", expiresAt: expiry),
            redeemRequestID: "request-1", canRedeem: { true }
        )
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(http.requests.filter { $0.url == CodexUsageClient.consumeResetCreditURL }.count, 1)
        XCTAssertFalse(http.requests.contains { $0.headers["ChatGPT-Account-Id"] == "acct-B" })
    }

    func testNothingToResetDoesNotReportSuccessfulRedemption() async {
        let expiry = Date().addingTimeInterval(40)
        let (service, http) = service(body: fixture(["target"], expiry: expiry), consumeCode: "nothing_to_reset")
        let outcome = await service.claimAuto(
            credit: .init(id: "target", expiresAt: expiry),
            redeemRequestID: UUID().uuidString, canRedeem: { true }
        )
        XCTAssertEqual(outcome, .nothingToReset)
        XCTAssertEqual(http.requests.count, 2)
    }


    func testRetryReplaysOriginalCreditWhenServerAlreadyRemovedIt() async throws {
        let expiry = Date().addingTimeInterval(30)
        let (service, http) = service(
            body: fixture([], expiry: expiry), consumeCode: "already_redeemed"
        )
        let outcome = await service.claimAuto(
            credit: CodexResetCredit(id: "original-credit", expiresAt: expiry, isRetry: true),
            redeemRequestID: "original-request", canRedeem: { true }
        )
        XCTAssertEqual(outcome, .success)
        XCTAssertEqual(http.requests.map(\.url), [CodexUsageClient.consumeResetCreditURL])
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(
            with: XCTUnwrap(http.requests.last?.body)
        ) as? [String: String])
        XCTAssertEqual(payload["credit_id"], "original-credit")
        XCTAssertEqual(payload["redeem_request_id"], "original-request")
    }

    func testRetryDoesNotSwitchAccountsIfFirstCredentialRejected() async {
        let expiry = Date().addingTimeInterval(30)
        let http = RoutingHTTPClient { request in
            if request.url == CodexUsageClient.consumeResetCreditURL {
                return HTTPResponse(statusCode: 403, headers: [:], body: Data())
            }
            XCTFail("a retry does not require a fresh credit list")
            return HTTPResponse(statusCode: 500, headers: [:], body: Data())
        }
        let service = CodexResetClaimService(
            usageClient: CodexUsageClient(http: http),
            credentialCandidates: { [("token-A", "acct-A"), ("token-B", "acct-B")] }
        )
        let outcome = await service.claimAuto(
            credit: CodexResetCredit(id: "target", expiresAt: expiry, isRetry: true),
            redeemRequestID: "same-key", canRedeem: { true }
        )
        XCTAssertEqual(outcome, .failed)
        XCTAssertTrue(http.requests.allSatisfy { $0.headers["ChatGPT-Account-Id"] == "acct-A" })
    }

    func testDisabledRetryNeverPosts() async {
        let expiry = Date().addingTimeInterval(30)
        let (service, http) = service(body: fixture([], expiry: expiry))
        let outcome = await service.claimAuto(
            credit: CodexResetCredit(id: "old", expiresAt: expiry, isRetry: true),
            redeemRequestID: "old-request", canRedeem: { false }
        )
        XCTAssertEqual(outcome, .noCredit)
        XCTAssertTrue(http.requests.isEmpty)
    }
}
