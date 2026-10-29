import XCTest
@testable import QuotaBar

final class AntigravityQuotaSummaryMergeTests: XCTestCase {
    private static let gemini = #"{"groups":[{"buckets":[{"bucketId":"gemini-5h","remainingFraction":0.8},{"bucketId":"gemini-weekly","remainingFraction":0.7}]}]}"#
    private static let claude = #"{"groups":[{"buckets":[{"bucketId":"3p-5h","remainingFraction":0.6},{"bucketId":"3p-weekly","remainingFraction":0.5}]}]}"#
    private static let complete = #"{"groups":[{"buckets":[{"bucketId":"gemini-5h","remainingFraction":0.8},{"bucketId":"gemini-weekly","remainingFraction":0.7},{"bucketId":"3p-5h","remainingFraction":0.6},{"bucketId":"3p-weekly","remainingFraction":0.5}]}]}"#

    private static func response(_ json: String) -> HTTPResponse {
        HTTPResponse(statusCode: 200, headers: [:], body: Data(json.utf8))
    }

    func testComplementarySummariesFillOmittedPoolsInMetricOrder() throws {
        let result = try XCTUnwrap(AntigravityUsageMapper.parseQuotaSummariesResult(
            [Data(Self.claude.utf8), Data(Self.gemini.utf8)], allHostsAnswered: true
        ))
        XCTAssertEqual(result.lines.map(\.label), ["Session", "Weekly", "Claude", "Claude Weekly"])
        XCTAssertEqual(result.lines, AntigravityUsageMapper.parseQuotaSummary(Data(Self.complete.utf8)))
        XCTAssertTrue(result.isComplete)
    }

    func testFirstUsableValueWinsAcrossHostsWithoutCreatingDuplicateWarnings() throws {
        let second = Self.complete.replacingOccurrences(of: "0.8", with: "0.1")
        let result = try XCTUnwrap(AntigravityUsageMapper.parseQuotaSummariesResult(
            [Data(Self.gemini.utf8), Data(second.utf8)], allHostsAnswered: true
        ))
        XCTAssertEqual(result.lines, AntigravityUsageMapper.parseQuotaSummary(Data(Self.complete.utf8)))
        XCTAssertTrue(result.isComplete)
    }

    func testArgonIsNotRequiredForCompletenessAndIsNotMergedAsAmbiguous() throws {
        XCTAssertTrue(AntigravityUsageMapper.hasAllSharedQuotaMeters(Data(Self.complete.utf8), sourceID: "merge-test"))
        let argon = Data(#"{"groups":[{"displayName":"Gemini 4 Argon","buckets":[{"bucketId":"argon","window":"weekly","remainingFraction":0.2}]}]}"#.utf8)
        let result = try XCTUnwrap(AntigravityUsageMapper.parseQuotaSummariesResult([argon, argon], allHostsAnswered: true))
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.lines.map(\.label), ["Argon Weekly"])
        XCTAssertFalse(AntigravityUsageMapper.hasAllSharedQuotaMeters(argon, sourceID: "merge-test"))
    }

    func testUnusableBodyOrSupplementalFailureCannotClearPriorLimits() throws {
        for (bodies, answered) in [
            ([Data(Self.claude.utf8)], false),
            ([Data(Self.claude.utf8), Data("{}".utf8)], true),
            ([Data(Self.claude.utf8), Data(#"{"groups":[{"buckets":[{"bucketId":"gemini-5h"}]}]}"#.utf8)], true)
        ] {
            let result = try XCTUnwrap(AntigravityUsageMapper.parseQuotaSummariesResult(bodies, allHostsAnswered: answered))
            XCTAssertFalse(result.isComplete)
            XCTAssertEqual(result.lines.map(\.label), ["Claude", "Claude Weekly"])
        }
    }

    func testCompleteFirstHostStopsWithoutExtraNetworkRequest() async throws {
        let http = RoutingHTTPClient { _ in Self.response(Self.complete) }
        let result = try await AntigravityUsageClient(http: http).cloudCodeSummaries(token: "test")
        guard case .ok(let bodies, let answered) = result else { return XCTFail("Expected summary") }
        XCTAssertEqual(bodies.count, 1)
        XCTAssertTrue(answered)
        XCTAssertEqual(http.requests.count, 1)
    }

    func testAllSharedMetersStopEvenWhenAnUnrelatedBucketHasSchemaDrift() async throws {
        let body = Self.complete.replacingOccurrences(of: "\"buckets\":[", with: "\"buckets\":[{\"bucketId\":\"future-pool\",\"remainingFraction\":0.1},")
        let http = RoutingHTTPClient { _ in Self.response(body) }
        let response = try await AntigravityUsageClient(http: http).cloudCodeSummaries(token: "test")
        guard case .ok(let bodies, let answered) = response else { return XCTFail("Expected usable summary") }
        XCTAssertEqual(http.requests.count, 1, "another host cannot add any missing shared meter")
        XCTAssertEqual(AntigravityUsageMapper.parseQuotaSummariesResult(bodies, allHostsAnswered: answered)?.isComplete, false,
                       "schema drift must still retain omitted prior meters")
    }

    func testPartialFirstHostQueriesOtherHost() async throws {
        let http = RoutingHTTPClient { request in
            Self.response(request.url.host?.hasPrefix("daily-") == true ? Self.claude : Self.gemini)
        }
        let result = try await AntigravityUsageClient(http: http).cloudCodeSummaries(token: "test")
        guard case .ok(let bodies, let answered) = result else { return XCTFail("Expected summaries") }
        XCTAssertEqual(http.requests.count, 2)
        XCTAssertTrue(answered)
        XCTAssertEqual(AntigravityUsageMapper.parseQuotaSummariesResult(bodies, allHostsAnswered: answered)?.lines.count, 4)
    }

    func testSupplementalAuthFailureKeepsMeasuredLimitsButInitialFailureStops() async throws {
        for status in [401, 403] {
            let http = RoutingHTTPClient { request in
                if request.url.host?.hasPrefix("daily-") == true { return Self.response(Self.claude) }
                return HTTPResponse(statusCode: status, headers: [:], body: Data())
            }
            let result = try await AntigravityUsageClient(http: http).cloudCodeSummaries(token: "test")
            guard case .ok(let bodies, let answered) = result else { return XCTFail("Measured quota discarded") }
            XCTAssertFalse(answered)
            XCTAssertEqual(bodies.count, 1)
            let denied = RoutingHTTPClient { _ in HTTPResponse(statusCode: status, headers: [:], body: Data()) }
            let failure = try await AntigravityUsageClient(http: denied).cloudCodeSummaries(token: "test")
            switch failure {
            case .authFailed: XCTAssertEqual(status, 401)
            case .forbidden: XCTAssertEqual(status, 403)
            default: XCTFail("Authentication classification changed")
            }
            XCTAssertEqual(denied.requests.count, 1)
        }
    }

    func testCancellationDuringSupplementDoesNotPublishPartialSuccess() async {
        let http = RoutingHTTPClient { request in
            if request.url.host?.hasPrefix("daily-") == true { return Self.response(Self.claude) }
            throw CancellationError()
        }
        do {
            _ = try await AntigravityUsageClient(http: http).cloudCodeSummaries(token: "test")
            XCTFail("Cancellation was swallowed")
        } catch is CancellationError {
            XCTAssertEqual(http.requests.count, 2)
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    @MainActor
    func testProviderUsesBothHostsAndDoesNotConsultLegacyEndpoints() async {
        let http = RoutingHTTPClient { request in
            if request.url.path == AntigravityUsageClient.quotaSummaryPath {
                return Self.response(request.url.host?.hasPrefix("daily-") == true ? Self.claude : Self.gemini)
            }
            if request.url.path == AntigravityUsageClient.loadCodeAssistPath {
                return Self.response(#"{"paidTier":{"id":"g1-ultra-lite-tier"}}"#)
            }
            return HTTPResponse(statusCode: 404, headers: [:], body: Data())
        }
        let token = #"{"token":{"access_token":"test","expiry":"2099-01-01T00:00:00Z"}}"#
        let provider = AntigravityProvider(
            authStore: AntigravityAuthStore(keychain: FakeKeychain("go-keyring-base64:" + Data(token.utf8).base64EncodedString()), files: FakeFiles()),
            usageClient: AntigravityUsageClient(lsHTTP: http, http: http),
            discovery: LanguageServerDiscovery(processRunner: MergeNoProcessRunner()),
            dbUsageScanner: AntigravityDbUsageScanner(conversationsDirectory: { "/nonexistent-antigravity-merge-test" })
        )
        let snapshot = await ProviderRefreshContext.$scope.withValue(.menuBar) { await provider.refresh() }
        XCTAssertEqual(snapshot.lines.map(\.label), ["Session", "Weekly", "Claude", "Claude Weekly"])
        XCTAssertEqual(snapshot.replacesPriorQuotaProgress, true)
        XCTAssertNil(snapshot.warning)
        XCTAssertEqual(snapshot.plan, "Ultra Lite")
        XCTAssertFalse(http.requests.contains { $0.url.path == AntigravityUsageClient.fetchModelsPath })
    }
}

private struct MergeNoProcessRunner: ProcessRunning {
    func run(executable: String, arguments: [String], environment: [String: String], timeout: TimeInterval) throws -> ProcessResult {
        ProcessResult(exitCode: 0, stdout: "", stderr: "")
    }
}
