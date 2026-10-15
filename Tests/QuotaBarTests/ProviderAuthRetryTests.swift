import XCTest
@testable import QuotaBar

/// Covers `ProviderAuthRetry.requireSuccess`, the shared non-2xx triage the Claude/Codex/Grok mappers
/// and `CursorProvider` route through: 401/403 → the provider's auth-expired error, any other non-2xx →
/// the provider's request-failed error (carrying the status), and a 2xx returns without throwing.
final class ProviderAuthRetryTests: XCTestCase {
    private enum SampleError: Error, Equatable {
        case authExpired
        case requestFailed(Int)
    }

    private func requireSuccess(status: Int) throws {
        let response = HTTPResponse(statusCode: status, headers: [:], body: Data())
        try ProviderAuthRetry.requireSuccess(
            response,
            authExpired: SampleError.authExpired,
            requestFailed: { SampleError.requestFailed($0) }
        )
    }

    func testSuccessStatusesDoNotThrow() throws {
        for status in [200, 201, 204, 299] {
            try requireSuccess(status: status)
        }
    }

    func testUnauthorizedAndForbiddenThrowAuthExpired() {
        for status in [401, 403] {
            XCTAssertThrowsError(try requireSuccess(status: status)) { error in
                XCTAssertEqual(error as? SampleError, .authExpired)
            }
        }
    }

    func testOtherNon2xxThrowRequestFailedWithStatus() {
        for status in [400, 404, 429, 500, 503] {
            XCTAssertThrowsError(try requireSuccess(status: status)) { error in
                XCTAssertEqual(error as? SampleError, .requestFailed(status))
            }
        }
    }

    @MainActor
    func testInitialAttemptCancellationPropagatesWithoutRefreshing() async {
        var refreshCount = 0
        do {
            _ = try await ProviderAuthRetry.fetch(
                token: "old-token",
                attempt: { _ in throw CancellationError() },
                refreshAccessToken: {
                    refreshCount += 1
                    return "new-token"
                },
                connectionFailed: SampleError.requestFailed(0),
                authExpired: SampleError.authExpired
            )
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // Cancellation is not a connection failure and must stop the retry chain.
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        XCTAssertEqual(refreshCount, 0)
    }

    @MainActor
    func testRetryAttemptCancellationPropagatesWithoutBecomingConnectionFailure() async {
        var attemptCount = 0
        var refreshCount = 0
        do {
            _ = try await ProviderAuthRetry.fetch(
                token: "old-token",
                attempt: { _ in
                    attemptCount += 1
                    if attemptCount == 1 {
                        return HTTPResponse(statusCode: 401, headers: [:], body: Data())
                    }
                    throw URLError(.cancelled)
                },
                refreshAccessToken: {
                    refreshCount += 1
                    return "new-token"
                },
                connectionFailed: SampleError.requestFailed(0),
                authExpired: SampleError.authExpired
            )
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // URLSession cancellation uses URLError.cancelled; providers normalize it here.
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        XCTAssertEqual(attemptCount, 2)
        XCTAssertEqual(refreshCount, 1)
    }

    @MainActor
    func testRefreshClosureURLCancellationPropagatesWithoutRetryingRequest() async {
        var attemptCount = 0
        do {
            _ = try await ProviderAuthRetry.fetch(
                token: "old-token",
                attempt: { _ in
                    attemptCount += 1
                    return HTTPResponse(statusCode: 401, headers: [:], body: Data())
                },
                refreshAccessToken: { throw URLError(.cancelled) },
                connectionFailed: SampleError.requestFailed(0),
                authExpired: SampleError.authExpired
            )
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // The refresh closure's URLSession cancellation must stop the retry chain.
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        XCTAssertEqual(attemptCount, 1, "no request with a refreshed token can follow cancellation")
    }

    @MainActor
    func testCancellationAfterSuccessful401ResponseStopsBeforeTokenRefresh() async {
        let gate = AsyncTestGate()
        var attempts = 0
        var refreshCount = 0
        let task = Task {
            try await ProviderAuthRetry.fetch(
                token: "old-token",
                attempt: { _ in
                    attempts += 1
                    await gate.pause()
                    return HTTPResponse(statusCode: 401, headers: [:], body: Data())
                },
                refreshAccessToken: {
                    refreshCount += 1
                    return "new-token"
                },
                connectionFailed: SampleError.requestFailed(0),
                authExpired: SampleError.authExpired
            )
        }
        await gate.waitUntilPaused()
        task.cancel()
        await gate.open()

        do {
            _ = try await task.value
            XCTFail("expected cancellation after the successful-but-late 401")
        } catch is CancellationError {
            // The response arrived after cancellation; do not rotate credentials on its behalf.
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(refreshCount, 0)
    }

    @MainActor
    func testCancellationAfterSuccessfulRefreshStopsBeforeRetry() async {
        let gate = AsyncTestGate()
        var attempts = 0
        let task = Task {
            try await ProviderAuthRetry.fetch(
                token: "old-token",
                attempt: { _ in
                    attempts += 1
                    return HTTPResponse(statusCode: 401, headers: [:], body: Data())
                },
                refreshAccessToken: {
                    await gate.pause()
                    return "new-token"
                },
                connectionFailed: SampleError.requestFailed(0),
                authExpired: SampleError.authExpired
            )
        }
        await gate.waitUntilPaused()
        task.cancel()
        await gate.open()

        do {
            _ = try await task.value
            XCTFail("expected cancellation after token refresh")
        } catch is CancellationError {
            // The refresh completed late; no authenticated retry should follow it.
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        XCTAssertEqual(attempts, 1)
    }
}

private actor AsyncTestGate {
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var entered = false
    private var released = false

    func pause() async {
        guard !released else { return }
        entered = true
        enteredContinuation?.resume()
        enteredContinuation = nil
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilPaused() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            enteredContinuation = continuation
        }
    }

    func open() {
        released = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
