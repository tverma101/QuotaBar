import XCTest
@testable import QuotaBar

final class ZAIQuotaValidationMapperTests: XCTestCase {
    func testMissingRequiredValuesNeverBecomeZeroUsage() {
        let malformedLimits = [
            #"{"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3,"number":5}]}}"#,
            #"{"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":true}]}}"#,
            #"{"data":{"limits":[{"type":"TIME_LIMIT","usage":1000}]}}"#,
            #"{"data":{"limits":[{"type":"TIME_LIMIT","currentValue":10}]}}"#,
            #"{"data":{"limits":[{"type":"TIME_LIMIT","currentValue":-1,"usage":1000}]}}"#
        ]

        for body in malformedLimits {
            XCTAssertThrowsError(try ZAIUsageMapper.mapQuota(Data(body.utf8)), body) { error in
                XCTAssertEqual(error as? ZAIUsageError, .invalidResponse, body)
            }
        }
    }

    func testMalformedEnvelopeIsRejectedButExplicitEmptyLimitsRemainValid() throws {
        for body in ["not-json", #"{"data":[]}"#, #"{"data":{}}"#, #"{"data":{"limits":{}}}"#] {
            XCTAssertThrowsError(try ZAIUsageMapper.mapQuota(Data(body.utf8)), body) { error in
                XCTAssertEqual(error as? ZAIUsageError, .invalidResponse, body)
            }
        }

        let lines = try ZAIUsageMapper.mapQuota(Data(#"{"data":{"limits":[]}}"#.utf8))
        XCTAssertNotNil(lines.first { $0.label == "Status" })
    }

    func testUnknownEntriesDoNotHideKnownMeters() throws {
        let body = Data(
            #"{"data":{"limits":[{"type":"FUTURE_LIMIT"},{"type":"TOKENS_LIMIT","unit":99,"number":1,"percentage":70},{"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":25}]}}"#.utf8
        )

        let lines = try ZAIUsageMapper.mapQuota(body)

        XCTAssertNotNil(lines.first { $0.label == "Session" })
        XCTAssertNil(lines.first { $0.label == "Weekly" })
    }

    func testOnlyUnknownLimitsRemainForwardCompatibleNoData() throws {
        let body = Data(
            #"{"data":{"limits":[{"type":"FUTURE_LIMIT"},{"type":"TOKENS_LIMIT","unit":99,"number":1,"percentage":70}]}}"#.utf8
        )

        let lines = try ZAIUsageMapper.mapQuota(body)

        XCTAssertNotNil(lines.first { $0.label == "Status" })
    }

    /// One unreadable entry must not blank the whole card: it is skipped (with a warning) while
    /// its siblings' meters still render. A payload where a recognized entry existed but no meter
    /// could be built at all remains an invalid response.
    func testDamagedEntryIsSkippedWhileValidMetersRender() throws {
        // A session window missing its percentage alongside a fully valid one.
        let body = Data(
            #"{"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3,"number":5},{"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":25}]}}"#.utf8
        )
        let lines = try ZAIUsageMapper.mapQuota(body)
        let session = try XCTUnwrap(lines.first { $0.label == "Session" })
        guard case .progress(_, let used, _, _, _, _, _, _) = session else {
            return XCTFail("Session line is not progress")
        }
        XCTAssertEqual(used, 25)

        // A TIME_LIMIT entry missing its current value alongside a valid session window.
        let bodyWithDamagedTimeLimit = Data(
            #"{"data":{"limits":[{"type":"TIME_LIMIT","usage":1000},{"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":40}]}}"#.utf8
        )
        let linesWithDamagedTimeLimit = try ZAIUsageMapper.mapQuota(bodyWithDamagedTimeLimit)
        XCTAssertNotNil(linesWithDamagedTimeLimit.first { $0.label == "Session" })
        XCTAssertNil(linesWithDamagedTimeLimit.first { $0.label == "Web Searches" })
    }
}

@MainActor
final class ZAIQuotaValidationProviderTests: XCTestCase {
    func testMissingUsageReportsInvalidResponseInsteadOfZeroMeter() async {
        let provider = ZAIProvider(
            zcodeScanner: ZCodeUsageScanner(path: "/nonexistent-quotabar-zcode-test/db.sqlite", leveldbPath: "/nonexistent-quotabar-zcode-test/leveldb"),
            authStore: ZAIAuthStore(
                files: FakeFiles(),
                environment: FakeEnvironment(["ZAI_API_KEY": "zai-test"])
            ),
            usageClient: ZAIUsageClient(http: RoutingHTTPClient { request in
                if request.url == ZAIUsageClient.quotaURL {
                    return HTTPResponse(
                        statusCode: 200,
                        headers: [:],
                        body: Data(#"{"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3,"number":5}]}}"#.utf8)
                    )
                }
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"data":[]}"#.utf8))
            })
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .decoding)
        XCTAssertNil(snapshot.line(label: "Session"))
    }
}
