import XCTest
@testable import QuotaBar

/// Parity between the Rust fast path (`qb_router_parse_line`) and the Swift reference parser
/// (`CodexRouterEventLineParser`). The Rust parser must never disagree with Swift: when it cannot
/// prove the Swift answer it returns NULL and the bridge re-runs the Swift parser.
final class CodexRouterLineRustParserTests: XCTestCase {
    private typealias LineResult = CodexRouterEventLineParser.LineResult

    // MARK: - Synthetic corpus

    private let edgeLines: [String] = [
        "",
        "   ",
        "not json",
        "[]",
        "[1,2,3]",
        "{}",
        "{\"unrelated\":true}",
        "{\"unrelated\":{\"nested\":[1,2,{\"x\":null}]}}",
        "{\"at\":\"2026-11-17T20:49:45.123Z\"}",
        "{\"at\":\"2026-11-17T20:49:45.123Z\",\"model\":\"deepseek-v4.1-flash\",\"provider\":\"opencode-go\","
            + "\"status\":200,\"inputTokens\":1000,\"cachedInputTokens\":400,\"outputTokens\":250,"
            + "\"reasoningTokens\":40,\"totalTokens\":1250}",
        // Explicit zero status: a valid unsuccessful record, so irrelevant rather than malformed.
        "{\"at\":\"2026-11-17T20:49:45.123Z\",\"model\":\"m\",\"provider\":\"opencode-go\",\"status\":0}",
        "{\"at\":\"2026-11-17T20:49:45.123Z\",\"model\":\"m\",\"provider\":\"opencode-go\",\"status\":500}",
        "{\"at\":\"2026-11-17T20:49:45.123Z\",\"model\":\"m\",\"status\":200}",
        "{\"at\":\"2026-11-17T20:49:45.123Z\",\"status\":200}",
        "{\"at\":\"2026-11-17T20:49:45.123Z\",\"model\":\"   \",\"provider\":\"  \",\"status\":200,"
            + "\"inputTokens\":5,\"outputTokens\":6}",
        // Duplicate recognized fields are malformed, not last-wins.
        "{\"at\":\"2026-11-17T20:49:45.123Z\",\"status\":200,\"status\":200,\"model\":\"m\"}",
        "{\"at\":\"2026-11-17T20:49:45.123Z\",\"model\":\"a\",\"model\":\"b\",\"status\":200}",
        "{\"at\":\"2026-11-17T20:49:45.123Z\",\"model\":\"m\",\"provider\":\"opencode-go\","
            + "\"provider\":\"opencode-go\",\"status\":200}",
        // Wrong types clear the field.
        "{\"at\":\"2026-11-17T20:49:45.123Z\",\"model\":1,\"status\":200}",
        "{\"at\":\"2026-11-17T20:49:45.123Z\",\"model\":\"m\",\"status\":\"200\"}",
        "{\"at\":\"2026-11-17T20:49:45.123Z\",\"model\":\"m\",\"provider\":42,\"status\":200}",
        "{\"at\":null,\"model\":\"m\",\"status\":200}",
        "{\"at\":\"2026-11-17T20:49:45.123Z\",\"model\":null,\"status\":200}",
        "{\"at\":\"2026-11-17T20:49:45.123Z\",\"model\":\"m\",\"serviceTier\":null,\"status\":200}",
        "{\"at\":\"2026-11-17T20:49:45.123Z\",\"model\":\"m\",\"accountId\":null,"
            + "\"accountFingerprint\":null,\"status\":200}",
        // Timestamps: canonical without fraction, invalid calendar, non-canonical shape, empty.
        "{\"at\":\"2026-11-17T20:49:45Z\",\"model\":\"m\",\"status\":200}",
        "{\"at\":\"2026-02-30T20:49:45.123Z\",\"model\":\"m\",\"status\":200}",
        "{\"at\":\"2026-11-17 20:49:45Z\",\"model\":\"m\",\"status\":200}",
        "{\"at\":\"2026-11-17T20:49:45.123+02:00\",\"model\":\"m\",\"status\":200}",
        "{\"at\":\"\",\"model\":\"m\",\"status\":200}",
        "{\"at\":\"  2026-11-17T20:49:45.123Z  \",\"model\":\"m\",\"status\":200}",
        // Numbers: floats, exponents, saturation around the 1e15 ceiling, negatives.
        "{\"at\":\"2026-11-17T20:49:45.123Z\",\"model\":\"m\",\"status\":200.0,\"inputTokens\":1.5}",
        "{\"at\":\"2026-11-17T20:49:45.123Z\",\"model\":\"m\",\"status\":200,\"inputTokens\":1e3}",
        "{\"at\":\"2026-11-17T20:49:45.123Z\",\"model\":\"m\",\"status\":200,\"inputTokens\":9999999999999999}",
        "{\"at\":\"2026-11-17T20:49:45.123Z\",\"model\":\"m\",\"status\":200,\"inputTokens\":-4}",
        "{\"at\":\"2026-11-17T20:49:45.123Z\",\"model\":\"m\",\"status\":200,\"totalTokens\":0,"
            + "\"inputTokens\":10,\"outputTokens\":2}",
        "{\"at\":\"2026-11-17T20:49:45.123Z\",\"model\":\"m\",\"status\":200,"
            + "\"estimatedInputTokens\":12345678901234567890}",
        // Escapes, unicode and nested metadata must agree (usually via the Swift fallback).
        "{\"at\":\"2026-11-17T20:49:45.123Z\",\"model\":\"m\",\"status\":200,\"meta\":{\"a\":[1,{\"b\":\"c,}\"}]}}",
        "{\"at\":\"2026-11-17T20:49:45.123Z\",\"model\":\"caf\\u00e9\",\"status\":200}",
        "{\"at\":\"2026-11-17T20:49:45.123Z\",\"model\":\"café\",\"status\":200}",
        "{\"at\":\"2026-11-17T20:49:45.123Z\",\"model\":\"a\\\"b\",\"status\":200}",
        "{\"at\":\"2026-11-17T20:49:45.123Z\",\"model\":\"m\",\"status\":200,\"serviceTier\":\"Priority\"}",
        "{\"at\":\"2026-11-17T20:49:45.123Z\",\"model\":\"m\",\"status\":200,\"serviceTier\":\"bogus\"}",
        // Broken structure: unbalanced, trailing comma, truncated.
        "{\"at\":\"2026-11-17T20:49:45.123Z\",\"model\":\"m\",\"status\":200",
        "{\"at\":\"2026-11-17T20:49:45.123Z\",\"model\":\"m\",\"status\":200,}",
        "{\"at\":\"2026-11-17T20:49:45.123Z\" \"model\":\"m\"}",
        "{\"at\":\"2026-11-17T20:49:45.123Z\",\"model\":\"m\",\"status\":200} trailing"
    ]

    func testRustMatchesSwiftOnEdgeLines() {
        for line in edgeLines {
            assertSame(line)
        }
    }

    func testRustHandlesOrdinaryRouterRows() throws {
        let line = "{\"at\":\"2026-11-17T20:49:45.123Z\",\"model\":\"deepseek-v4.1-flash\","
            + "\"provider\":\"opencode-go\",\"status\":200,\"inputTokens\":1000,"
            + "\"cachedInputTokens\":400,\"outputTokens\":250,\"reasoningTokens\":40,"
            + "\"totalTokens\":1250,\"accountId\":\"acct-1\"}"
        let rust = try XCTUnwrap(CodexRouterLineRustParser.parseWithRust(Data(line.utf8)[...]))
        guard case .event(let event) = rust else {
            return XCTFail("expected the fast path to classify an ordinary row as an event")
        }
        XCTAssertEqual(event.model, "deepseek-v4.1-flash")
        XCTAssertEqual(event.provider, "opencode-go")
        XCTAssertEqual(event.inputTokens, 1000)
        XCTAssertEqual(event.cachedInputTokens, 400)
        XCTAssertEqual(event.outputTokens, 250)
        XCTAssertEqual(event.reasoningTokens, 40)
        XCTAssertEqual(event.totalTokens, 1250)
        XCTAssertEqual(event.accountId, "acct-1")
        XCTAssertTrue(event.hasValidStatusField)
        XCTAssertTrue(event.hasValidTimestampField)
    }

    func testRustMatchesSwiftOnRealLedger() throws {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".codex/codex-router/usage-events.jsonl")
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            throw XCTSkip("no CodexRouter ledger on this machine")
        }
        var total = 0
        var fastPath = 0
        for line in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false) {
            total += 1
            if CodexRouterLineRustParser.parseWithRust(line) != nil { fastPath += 1 }
            assertSameLine(line)
        }
        XCTAssertGreaterThan(total, 0)
        // The router writes canonical UTC ASCII rows; if a format change drove most lines to the
        // Swift fallback, the fast path would silently stop earning its keep.
        let share = Double(fastPath) / Double(total)
        XCTAssertGreaterThan(share, 0.99, "fast path covered only \(fastPath)/\(total) ledger lines")
    }

    // MARK: - Helpers

    private func assertSame(_ line: String, file: StaticString = #filePath, lineNumber: UInt = #line) {
        assertSameLine(Data(line.utf8)[...], file: file, lineNumber: lineNumber)
    }

    private func assertSameLine(
        _ bytes: Data.SubSequence,
        file: StaticString = #filePath,
        lineNumber: UInt = #line
    ) {
        var swiftCache = CodexRouterEventLineParser.TimestampCache()
        let swift = CodexRouterEventLineParser.parseResult(bytes, timestampCache: &swiftCache)
        guard let rust = CodexRouterLineRustParser.parseWithRust(bytes) else {
            // Delegated to Swift: the bridge's own result must still equal the reference.
            var bridgedCache = CodexRouterEventLineParser.TimestampCache()
            let bridged = CodexRouterLineRustParser.parseResult(bytes, timestampCache: &bridgedCache)
            XCTAssertTrue(
                sameResult(bridged, swift),
                "bridge disagreed with the reference parser for \(String(decoding: bytes, as: UTF8.self))",
                file: file,
                line: lineNumber
            )
            return
        }
        XCTAssertTrue(
            sameResult(rust, swift),
            "Rust and Swift disagreed for line: \(String(decoding: bytes, as: UTF8.self))",
            file: file,
            line: lineNumber
        )
    }

    private func sameResult(_ lhs: LineResult, _ rhs: LineResult) -> Bool {
        switch (lhs, rhs) {
        case (.irrelevant, .irrelevant), (.malformed, .malformed):
            return true
        case (.event(let a), .event(let b)), (.malformedEvent(let a), .malformedEvent(let b)):
            return a == b
        default:
            return false
        }
    }
}
