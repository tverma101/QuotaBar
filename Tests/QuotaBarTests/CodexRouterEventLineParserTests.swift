import XCTest
@testable import QuotaBar

final class CodexRouterEventLineParserTests: XCTestCase {
    func testParsesFieldsInAnyOrderAndDecodesEscapedStrings() throws {
        let event = try XCTUnwrap(parse(#"{"padding":"ignore, \"keys\"","serviceTier":"PRIORITY","totalTokens":17,"outputTokens":5,"reasoningTokens":2,"cachedInputTokens":3,"inputTokens":10,"status":200,"provider":"openai","model":"gpt-6-luna","at":"2026-10-02T12:00:00Z","accountId":"acct\u005fA","accountFingerprint":"acct_deadbeef"}"#))

        XCTAssertEqual(event.model, "gpt-6-luna")
        XCTAssertEqual(event.provider, "openai")
        XCTAssertEqual(event.status, 200)
        XCTAssertEqual(event.inputTokens, 10)
        XCTAssertEqual(event.cachedInputTokens, 3)
        XCTAssertEqual(event.outputTokens, 5)
        XCTAssertEqual(event.reasoningTokens, 2)
        XCTAssertEqual(event.totalTokens, 17)
        XCTAssertEqual(event.accountId, "acct_A")
        XCTAssertEqual(event.accountFingerprint, "acct_deadbeef")
        XCTAssertEqual(event.serviceTier, "priority")
    }

    func testIgnoresNestedDecoyFieldsAndAppliesDefaults() throws {
        let event = try XCTUnwrap(parse(#"{"at":"2026-10-02T12:00:00Z","metadata":{"status":200,"inputTokens":99},"padding":"status:200 inputTokens:99"}"#))

        XCTAssertEqual(event.status, 0)
        XCTAssertEqual(event.inputTokens, 0)
        XCTAssertEqual(event.model, ModelUsageEntry.unattributedModelName)
        XCTAssertEqual(event.provider, "unknown")
    }

    func testSaturatesHugeIntegerAndTrimsCRLFWhitespace() throws {
        let event = try XCTUnwrap(parse(" {\"at\":\"2026-10-02T12:00:00Z\",\"inputTokens\":999999999999999999999}  \r\n"))

        XCTAssertEqual(event.inputTokens, 1_000_000_000_000_000)
    }

    func testDuplicateKeysUseLastTopLevelValue() throws {
        let event = try XCTUnwrap(parse(#"{"at":"2026-10-02T12:00:00Z","status":200,"status":500,"model":"first","model":"last"}"#))

        XCTAssertEqual(event.status, 500)
        XCTAssertEqual(event.model, "last")
    }

    func testJSONNumberFractionsAndExponentsAreParsedAsWholeValues() throws {
        let event = try XCTUnwrap(parse(#"{"at":"2026-10-02T12:00:00Z","status":2e2,"inputTokens":1.5e3,"outputTokens":4.9,"totalTokens":2e3}"#))

        XCTAssertEqual(event.status, 200)
        XCTAssertEqual(event.inputTokens, 1_500)
        XCTAssertEqual(event.outputTokens, 4)
        XCTAssertEqual(event.totalTokens, 2_000)
    }

    func testSaturatesExponentOverflowInsteadOfDroppingTheEvent() throws {
        let event = try XCTUnwrap(parse(#"{"at":"2026-10-02T12:00:00Z","inputTokens":1e309}"#))
        XCTAssertEqual(event.inputTokens, 1_000_000_000_000_000)
    }

    func testLastKnownFieldOccurrenceWinsWhenItsValueIsInvalid() throws {
        let event = try XCTUnwrap(parse(#"{"at":"2026-10-02T12:00:00Z","status":200,"status":"invalid","model":"first","model":null}"#))

        XCTAssertEqual(event.status, 0)
        XCTAssertEqual(event.model, ModelUsageEntry.unattributedModelName)
        XCTAssertNil(parse(#"{"at":"2026-10-02T12:00:00Z","at":null,"status":200}"#))
    }

    func testRecognizesEscapedKnownFieldNames() throws {
        let event = try XCTUnwrap(parse(#"{"at":"2026-10-02T12:00:00Z","input\u0054okens":42}"#))

        XCTAssertEqual(event.inputTokens, 42)
    }

    func testRejectsTrailingCommaAndInvalidUTF8Strings() {
        XCTAssertNil(parse(#"{"at":"2026-10-02T12:00:00Z","status":200,}"#))

        var invalidUTF8 = Data(#"{"at":"2026-10-02T12:00:00Z","model":""#.utf8)
        invalidUTF8.append(0xFF)
        invalidUTF8.append(contentsOf: Data(#""}"#.utf8))
        XCTAssertNil(parse(invalidUTF8))

        var invalidUnknownUTF8 = Data(#"{"at":"2026-10-02T12:00:00Z","padding":""#.utf8)
        invalidUnknownUTF8.append(0xFF)
        invalidUnknownUTF8.append(contentsOf: Data(#""}"#.utf8))
        XCTAssertNil(parse(invalidUnknownUTF8))
    }

    func testRejectsMalformedUnknownJSONValues() {
        XCTAssertNil(parse(#"{"at":"2026-10-02T12:00:00Z","padding":{"x" 1}}"#))
        XCTAssertNil(parse(#"{"at":"2026-10-02T12:00:00Z","padding":[1,]}"#))
        XCTAssertNil(parse(#"{"at":"2026-10-02T12:00:00Z","padding":"bad\q"}"#))
    }

    func testTimestampCacheReusesDatesAndHonorsItsBound() throws {
        var cache = CodexRouterEventLineParser.TimestampCache(capacity: 1)
        let first = Data(#"{"at":"2026-10-02T12:00:00Z"}"#.utf8)
        let second = Data(#"{"at":"2026-10-02T13:00:00Z"}"#.utf8)

        let initial = try XCTUnwrap(CodexRouterEventLineParser.parse(first[...], timestampCache: &cache))
        let repeated = try XCTUnwrap(CodexRouterEventLineParser.parse(first[...], timestampCache: &cache))
        let afterCapacity = try XCTUnwrap(CodexRouterEventLineParser.parse(second[...], timestampCache: &cache))

        XCTAssertEqual(initial.timestamp, repeated.timestamp)
        XCTAssertEqual(afterCapacity.timestamp, ISO8601DateFormatter().date(from: "2026-10-02T13:00:00Z"))
        XCTAssertEqual(cache.cachedTimestampCount, 1)
        XCTAssertEqual(cache.cacheHitCount, 1)
    }

    func testTimestampCacheDoesNotRetainOversizedTimestampKeys() throws {
        var cache = CodexRouterEventLineParser.TimestampCache(capacity: 4)
        let oversizedTimestamp = "2026-10-02T12:00:00." + String(repeating: "1", count: 128) + "Z"
        let data = Data(#"{"at":"\#(oversizedTimestamp)"}"#.utf8)

        XCTAssertNotNil(CodexRouterEventLineParser.parse(data[...], timestampCache: &cache))
        XCTAssertNotNil(CodexRouterEventLineParser.parse(data[...], timestampCache: &cache))
        XCTAssertEqual(cache.cachedTimestampCount, 0)
        XCTAssertEqual(cache.cacheHitCount, 0)
    }

    func testCanonicalRouterTimestampsMatchFoundationAcrossCalendarBoundaries() throws {
        let timestamps = [
            "1970-01-01T00:00:00.000Z",
            "2000-02-29T23:59:59.999Z",
            "2026-10-02T12:34:56.789Z",
            "9999-12-31T23:59:59.000Z",
            "2026-10-02T12:34:56Z",
        ]
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plainFormatter = ISO8601DateFormatter()
        plainFormatter.formatOptions = [.withInternetDateTime]

        for timestamp in timestamps {
            let expected = timestamp.contains(".")
                ? formatter.date(from: timestamp)
                : plainFormatter.date(from: timestamp)
            let expectedDate = try XCTUnwrap(expected, timestamp)
            let actual = OpenUsageISO8601.date(from: timestamp)
            let actualDate = try XCTUnwrap(actual, timestamp)
            XCTAssertEqual(actualDate.timeIntervalSince1970, expectedDate.timeIntervalSince1970, accuracy: 0.001, timestamp)
        }
    }

    func testCanonicalRouterTimestampRejectsImpossibleCalendarDates() {
        XCTAssertNil(OpenUsageISO8601.date(from: "2026-02-29T12:00:00.000Z"))
        XCTAssertNil(OpenUsageISO8601.date(from: "2026-13-01T12:00:00.000Z"))
        XCTAssertNil(OpenUsageISO8601.date(from: "2026-10-02T24:00:00.000Z"))
    }

    func testRejectsTornFinalObject() {
        XCTAssertNil(parse(#"{"at":"2026-10-02T12:00:00Z","model":"unfinished}"#))
    }

    private func parse(_ value: String) -> CodexRouterUsageScanner.Event? {
        let data = Data(value.utf8)
        return CodexRouterEventLineParser.parse(data[...])
    }

    private func parse(_ data: Data) -> CodexRouterUsageScanner.Event? {
        CodexRouterEventLineParser.parse(data[...])
    }
}
