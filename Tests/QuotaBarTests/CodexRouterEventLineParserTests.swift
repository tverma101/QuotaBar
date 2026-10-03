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

    func testRejectsTornFinalObject() {
        XCTAssertNil(parse(#"{"at":"2026-10-02T12:00:00Z","model":"unfinished}"#))
    }

    private func parse(_ value: String) -> CodexRouterUsageScanner.Event? {
        let data = Data(value.utf8)
        return CodexRouterEventLineParser.parse(data[...])
    }
}
