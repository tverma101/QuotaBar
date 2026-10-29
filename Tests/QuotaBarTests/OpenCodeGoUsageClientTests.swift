import XCTest
@testable import QuotaBar

/// The account-wide usage endpoint: real-response parsing, auth/error mapping, and the key's use as the
/// Bearer token (never logged — asserted here at the request boundary).
final class OpenCodeGoUsageClientTests: XCTestCase {
    /// The exact shape the live endpoint returned when this client was written (Aug 11, 2026).
    static let livePayloadFixture = Data(#"{"usage":{"rolling":{"status":"ok","percent":4,"resetsAt":"2026-08-12T03:53:00.876Z"},"weekly":{"status":"ok","percent":25,"resetsAt":"2026-08-17T00:00:00.876Z"},"monthly":{"status":"ok","percent":78,"resetsAt":"2026-08-31T01:28:22.876Z"}}}"#.utf8)

    private func livePayload() -> Data {
        Self.livePayloadFixture
    }

    func testParsesLivePayload() async throws {
        let client = OpenCodeGoUsageClient(http: FakeHTTPClient(
            response: HTTPResponse(statusCode: 200, headers: [:], body: livePayload())
        ))
        let usage = try await client.fetchUsage(key: "sk-test")
        XCTAssertEqual(usage.rolling.status, "ok")
        XCTAssertEqual(usage.rolling.percent, 4)
        XCTAssertEqual(usage.weekly.percent, 25)
        XCTAssertEqual(usage.monthly.percent, 78)
        XCTAssertEqual(
            usage.rolling.resetsAt, OpenUsageISO8601.date(from: "2026-08-12T03:53:00.876Z")
        )
        XCTAssertEqual(
            usage.monthly.resetsAt, OpenUsageISO8601.date(from: "2026-08-31T01:28:22.876Z")
        )
        XCTAssertTrue(usage.isAvailable)
    }

    func testSendsKeyAsBearerToken() async throws {
        let http = FakeHTTPClient(response: HTTPResponse(statusCode: 200, headers: [:], body: livePayload()))
        let client = OpenCodeGoUsageClient(http: http)
        _ = try await client.fetchUsage(key: "sk-secret-key")
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(http.requests[0].url.absoluteString, "https://opencode.ai/zen/go/v1/usage")
        XCTAssertEqual(http.requests[0].headers["Authorization"], "Bearer sk-secret-key")
        XCTAssertNil(http.requests[0].body)
    }

    func testUnauthorizedMapsToTypedError() async {
        let client = OpenCodeGoUsageClient(http: FakeHTTPClient(
            response: HTTPResponse(
                statusCode: 401, headers: [:],
                body: Data(#"{"type":"error","error":{"type":"AuthError","message":"Unauthorized"}}"#.utf8)
            )
        ))
        do {
            _ = try await client.fetchUsage(key: "sk-bad")
            XCTFail("expected a throw")
        } catch let error as OpenCodeUsageError {
            XCTAssertEqual(error, .accountAPIUnauthorized)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testServerErrorMapsToTypedError() async {
        let client = OpenCodeGoUsageClient(http: FakeHTTPClient(
            response: HTTPResponse(statusCode: 500, headers: [:], body: Data())
        ))
        do {
            _ = try await client.fetchUsage(key: "sk-test")
            XCTFail("expected a throw")
        } catch let error as OpenCodeUsageError {
            XCTAssertEqual(error, .accountAPIRequestFailed(500))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testMalformedBodyMapsToInvalidResponse() async {
        let client = OpenCodeGoUsageClient(http: FakeHTTPClient(
            response: HTTPResponse(statusCode: 200, headers: [:], body: Data("not json".utf8))
        ))
        do {
            _ = try await client.fetchUsage(key: "sk-test")
            XCTFail("expected a throw")
        } catch let error as OpenCodeUsageError {
            XCTAssertEqual(error, .accountAPIInvalidResponse)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testSuccessStatusWithErrorEnvelopeMapsToInvalidResponse() async {
        let body = Data(#"{"type":"error","error":{"type":"AuthError","message":"Unauthorized"}}"#.utf8)
        let client = OpenCodeGoUsageClient(http: FakeHTTPClient(
            response: HTTPResponse(statusCode: 200, headers: [:], body: body)
        ))
        do {
            _ = try await client.fetchUsage(key: "sk-test")
            XCTFail("a success status with an error body must not confirm an account")
        } catch let error as OpenCodeUsageError {
            XCTAssertEqual(error, .accountAPIInvalidResponse)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testMissingWindowMapsToInvalidResponse() async {
        // A payload missing one window must not render partial meters — `isAvailable` is the gate.
        let partial = Data(#"{"usage":{"rolling":{"status":"ok","percent":4,"resetsAt":"2026-08-12T03:53:00.876Z"},"weekly":{"status":"ok","percent":25,"resetsAt":"2026-08-17T00:00:00.876Z"}}}"#.utf8)
        let client = OpenCodeGoUsageClient(http: FakeHTTPClient(
            response: HTTPResponse(statusCode: 200, headers: [:], body: partial)
        ))
        do {
            _ = try await client.fetchUsage(key: "sk-test")
            XCTFail("expected a throw")
        } catch let error as OpenCodeUsageError {
            XCTAssertEqual(error, .accountAPIInvalidResponse)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testUnknownWindowStatusMapsToInvalidResponse() async {
        let degraded = Data(#"{"usage":{"rolling":{"status":"unknown","percent":0,"resetsAt":"2026-08-12T03:53:00.876Z"},"weekly":{"status":"ok","percent":25,"resetsAt":"2026-08-17T00:00:00.876Z"},"monthly":{"status":"ok","percent":78,"resetsAt":"2026-08-31T01:28:22.876Z"}}}"#.utf8)
        let client = OpenCodeGoUsageClient(http: FakeHTTPClient(
            response: HTTPResponse(statusCode: 200, headers: [:], body: degraded)
        ))
        do {
            _ = try await client.fetchUsage(key: "sk-test")
            XCTFail("expected a throw")
        } catch let error as OpenCodeUsageError {
            XCTAssertEqual(error, .accountAPIInvalidResponse)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testRateLimitedWindowsStillConfirmAnActiveSubscription() async throws {
        let limited = Data(#"{"usage":{"rolling":{"status":"rate-limited","percent":100,"resetsAt":"2026-08-12T03:53:00Z"},"weekly":{"status":"rate-limited","percent":100,"resetsAt":"2026-08-17T00:00:00Z"},"monthly":{"status":"rate-limited","percent":100,"resetsAt":"2026-08-31T01:28:22Z"}}}"#.utf8)
        let client = OpenCodeGoUsageClient(http: FakeHTTPClient(
            response: HTTPResponse(statusCode: 200, headers: [:], body: limited)
        ))

        let usage = try await client.fetchUsage(key: "sk-test")

        XCTAssertTrue(usage.isAvailable)
    }

    func testForbiddenEndpointResponseDoesNotClaimKeyIsInvalid() async {
        let client = OpenCodeGoUsageClient(http: FakeHTTPClient(
            response: HTTPResponse(
                statusCode: 403, headers: [:],
                body: Data(#"{"type":"error","error":{"type":"EntitlementError","message":"OpenCode Go subscription required."}}"#.utf8)
            )
        ))
        do {
            _ = try await client.fetchUsage(key: "sk-test")
            XCTFail("expected an entitlement error")
        } catch let error as OpenCodeUsageError {
            XCTAssertEqual(error, .accountAPINoEntitlement)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testErrorTypeTakesPrecedenceOverHTTPStatus() async {
        let client = OpenCodeGoUsageClient(http: FakeHTTPClient(
            response: HTTPResponse(
                statusCode: 403, headers: [:],
                body: Data(#"{"type":"error","error":{"type":"AuthError","message":"Unauthorized"}}"#.utf8)
            )
        ))
        do {
            _ = try await client.fetchUsage(key: "sk-test")
            XCTFail("expected an auth error")
        } catch let error as OpenCodeUsageError {
            XCTAssertEqual(error, .accountAPIUnauthorized)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}
