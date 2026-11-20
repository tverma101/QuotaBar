import Darwin
import Foundation
import XCTest
@testable import QuotaBar

/// Parity coverage for `CodexRouterRustParser` — the Rust port of
/// `CodexRouterEventLineParser`. Every corpus line asserts two things: the Rust verdict and
/// event payload equal the Swift oracle's (`parseResultSwift`/`parseEventSwift`), and the
/// dispatched surfaces (`parseResult`/`parse`) agree for the lines Rust declines.
final class CodexRouterRustParserTests: XCTestCase {
    private typealias Event = CodexRouterUsageScanner.Event

    private enum Verdict { case event, malformedEvent, irrelevant, malformed }

    private enum Expectation { case answered, declines }

    private func verdictKind(_ result: CodexRouterEventLineParser.LineResult) -> Verdict {
        switch result {
        case .event: return .event
        case .malformedEvent: return .malformedEvent
        case .irrelevant: return .irrelevant
        case .malformed: return .malformed
        }
    }

    private func verdictKind(_ outcome: CodexRouterRustParser.LineOutcome) -> Verdict {
        switch outcome {
        case .event: return .event
        case .malformedEvent: return .malformedEvent
        case .irrelevant: return .irrelevant
        case .malformed: return .malformed
        }
    }

    // MARK: - Per-line corpus

    /// `ts` is a canonical timestamp; `tsAlt` a second canonical one. Lines tagged
    /// `.declines` carry a non-canonical `at` the Rust module deliberately hands back.
    private var corpus: [(name: String, line: String, expect: Expectation)] {
        let ts = "2026-10-02T12:00:00Z"
        return [
            ("full event", #"{"at":"\#(ts)","status":200,"model":"gpt-6","provider":"openai","inputTokens":10,"cachedInputTokens":3,"outputTokens":5,"reasoningTokens":2,"totalTokens":17,"accountId":"a","accountFingerprint":"f","serviceTier":"priority","estimatedInputTokens":12}"#, .answered),
            ("minimal event", #"{"at":"\#(ts)","status":200}"#, .answered),
            ("field order", #"{"status":200,"at":"\#(ts)","inputTokens":1,"model":"m"}"#, .answered),
            ("escaped key", #"{"at":"\#(ts)","status":200,"m\u006fdel":"gpt-6"}"#, .answered),
            ("escaped timestamp", #"{"at":"2026-10-02T12:00:00\u005a","status":200}"#, .answered),
            ("nested decoys", #"{"at":"\#(ts)","status":200,"pad":{"status":999,"at":"x","inputTokens":-1},"arr":[{"model":"y"}]}"#, .answered),
            ("status float exact", #"{"at":"\#(ts)","status":2e2}"#, .answered),
            ("status float frac", #"{"at":"\#(ts)","status":2.5}"#, .answered),
            ("status floor", #"{"at":"\#(ts)","status":299.9}"#, .answered),
            ("status string", #"{"at":"\#(ts)","status":"200"}"#, .answered),
            ("status null", #"{"at":"\#(ts)","status":null}"#, .answered),
            ("status bool", #"{"at":"\#(ts)","status":true}"#, .answered),
            ("status missing", #"{"at":"\#(ts)","model":"m"}"#, .answered),
            ("status 199", #"{"at":"\#(ts)","status":199}"#, .answered),
            ("status 299", #"{"at":"\#(ts)","status":299}"#, .answered),
            ("status 0", #"{"at":"\#(ts)","status":0}"#, .answered),
            ("status 404", #"{"at":"\#(ts)","status":404}"#, .answered),
            ("status 500", #"{"at":"\#(ts)","status":500}"#, .answered),
            ("status 600", #"{"at":"\#(ts)","status":600}"#, .answered),
            ("status 99", #"{"at":"\#(ts)","status":99}"#, .answered),
            ("status negative", #"{"at":"\#(ts)","status":-5}"#, .answered),
            ("status -0", #"{"at":"\#(ts)","status":-0}"#, .answered),
            ("status dup 2xx", #"{"at":"\#(ts)","status":200,"status":201}"#, .answered),
            ("status dup 404", #"{"at":"\#(ts)","status":404,"status":404}"#, .answered),
            ("status dup invalid last", #"{"at":"\#(ts)","status":200,"status":"x"}"#, .answered),
            ("model missing", #"{"at":"\#(ts)","status":200}"#, .answered),
            ("model empty", #"{"at":"\#(ts)","status":200,"model":""}"#, .answered),
            ("model blank", #"{"at":"\#(ts)","status":200,"model":"   "}"#, .answered),
            ("model null", #"{"at":"\#(ts)","status":200,"model":null}"#, .answered),
            ("model number", #"{"at":"\#(ts)","status":200,"model":5}"#, .answered),
            ("model dup", #"{"at":"\#(ts)","status":200,"model":"a","model":"b"}"#, .answered),
            ("provider missing", #"{"at":"\#(ts)","status":200}"#, .answered),
            ("provider empty", #"{"at":"\#(ts)","status":200,"provider":""}"#, .answered),
            ("provider blank", #"{"at":"\#(ts)","status":200,"provider":"  "}"#, .answered),
            ("provider null", #"{"at":"\#(ts)","status":200,"provider":null}"#, .answered),
            ("provider padded", #"{"at":"\#(ts)","status":200,"provider":"  openai  "}"#, .answered),
            ("provider number", #"{"at":"\#(ts)","status":200,"provider":7}"#, .answered),
            ("provider dup", #"{"at":"\#(ts)","status":200,"provider":"a","provider":"b"}"#, .answered),
            ("tier priority", #"{"at":"\#(ts)","status":200,"serviceTier":"PRIORITY"}"#, .answered),
            ("tier unknown", #"{"at":"\#(ts)","status":200,"serviceTier":"weird"}"#, .answered),
            ("tier blank", #"{"at":"\#(ts)","status":200,"serviceTier":" "}"#, .answered),
            ("tier null", #"{"at":"\#(ts)","status":200,"serviceTier":null}"#, .answered),
            ("accountId present", #"{"at":"\#(ts)","status":200,"accountId":"acct_1"}"#, .answered),
            ("accountId null", #"{"at":"\#(ts)","status":200,"accountId":null}"#, .answered),
            ("accountId blank", #"{"at":"\#(ts)","status":200,"accountId":"  "}"#, .answered),
            ("accountId number", #"{"at":"\#(ts)","status":200,"accountId":7}"#, .answered),
            ("accountId dup", #"{"at":"\#(ts)","status":200,"accountId":"a","accountId":"b"}"#, .answered),
            ("fingerprint null", #"{"at":"\#(ts)","status":200,"accountFingerprint":null}"#, .answered),
            ("fingerprint number", #"{"at":"\#(ts)","status":200,"accountFingerprint":7}"#, .answered),
            ("identity dup", #"{"at":"\#(ts)","status":200,"accountId":"a","accountFingerprint":"b","accountId":"c"}"#, .answered),
            ("input frac", #"{"at":"\#(ts)","status":200,"inputTokens":2.9}"#, .answered),
            ("input neg frac", #"{"at":"\#(ts)","status":200,"inputTokens":-2.9}"#, .answered),
            ("input negative", #"{"at":"\#(ts)","status":200,"inputTokens":-5}"#, .answered),
            ("input zero", #"{"at":"\#(ts)","status":200,"inputTokens":0}"#, .answered),
            ("input exp exact", #"{"at":"\#(ts)","status":200,"inputTokens":0.5e3}"#, .answered),
            ("input string", #"{"at":"\#(ts)","status":200,"inputTokens":"42"}"#, .answered),
            ("input null", #"{"at":"\#(ts)","status":200,"inputTokens":null}"#, .answered),
            ("input ceiling", #"{"at":"\#(ts)","status":200,"inputTokens":1000000000000000}"#, .answered),
            ("input saturated", #"{"at":"\#(ts)","status":200,"inputTokens":1000000000000001}"#, .answered),
            ("input sat negative", #"{"at":"\#(ts)","status":200,"inputTokens":-1000000000000001}"#, .answered),
            ("input inf", #"{"at":"\#(ts)","status":200,"inputTokens":1e309}"#, .answered),
            ("input neg inf", #"{"at":"\#(ts)","status":200,"inputTokens":-1e309}"#, .answered),
            ("input dup", #"{"at":"\#(ts)","status":200,"inputTokens":1,"inputTokens":2}"#, .answered),
            ("cached negative", #"{"at":"\#(ts)","status":200,"cachedInputTokens":-5}"#, .answered),
            ("total negative", #"{"at":"\#(ts)","status":200,"totalTokens":-5}"#, .answered),
            ("total absent vs null", #"{"at":"\#(ts)","status":200,"totalTokens":null}"#, .answered),
            ("estimated positive", #"{"at":"\#(ts)","status":200,"estimatedInputTokens":40}"#, .answered),
            ("estimated negative", #"{"at":"\#(ts)","status":200,"estimatedInputTokens":-5}"#, .answered),
            ("estimated zero", #"{"at":"\#(ts)","status":200,"estimatedInputTokens":0}"#, .answered),
            ("estimated saturated", #"{"at":"\#(ts)","status":200,"estimatedInputTokens":2000000000000000}"#, .answered),
            ("at missing", #"{"status":200,"model":"m"}"#, .answered),
            ("at null", #"{"status":200,"at":null}"#, .answered),
            ("at number", #"{"status":200,"at":123}"#, .answered),
            ("at empty", #"{"status":200,"at":""}"#, .declines),
            ("at blank", #"{"status":200,"at":"   "}"#, .declines),
            ("at bad month", #"{"status":200,"at":"2026-13-02T12:00:00Z"}"#, .answered),
            ("at bad day", #"{"status":200,"at":"2026-02-30T12:00:00Z"}"#, .answered),
            ("at leap valid", #"{"status":200,"at":"2024-02-29T12:00:00Z"}"#, .answered),
            ("at fractional 3", #"{"status":200,"at":"2026-10-02T12:00:00.789Z"}"#, .answered),
            ("at epoch", #"{"status":200,"at":"1970-01-01T00:00:00.000Z"}"#, .answered),
            ("at dup", #"{"at":"\#(ts)","at":"\#(ts)","status":200}"#, .answered),
            ("noncanonical space", #"{"status":200,"at":"2026-10-02 12:00:00"}"#, .declines),
            ("noncanonical offset", #"{"status":200,"at":"2026-10-02T12:00:00+00:00"}"#, .declines),
            ("noncanonical frac4", #"{"status":200,"at":"2026-10-02T12:00:00.1234Z"}"#, .declines),
            ("noncanonical utc", #"{"status":200,"at":"2026-10-02T12:00:00 UTC"}"#, .declines),
            ("irrelevant array", #"[1,2,3]"#, .answered),
            ("irrelevant scalar", #"123"#, .answered),
            ("irrelevant string", #""text""#, .answered),
            ("irrelevant literal", #"true"#, .answered),
            ("irrelevant null lit", #"null"#, .answered),
            ("unrelated object", #"{"foo":1,"bar":[true,null]}"#, .answered),
            ("case sensitive key", #"{"STATUS":200,"at":"\#(ts)"}"#, .answered),
            ("torn object", #"{"status":200"#, .answered),
            ("torn member", #"{"status":}"#, .answered),
            ("torn value", #"{"status":200,"pad":{"x" 1}}"#, .answered),
            ("missing comma", #"{"at":"\#(ts)","status":200 "x":1}"#, .answered),
            ("torn string", #"{"at":"\#(ts)","model":"unfinished}"#, .answered),
            ("raw control char", "{\"at\":\"\(ts)\",\"pad\":\"a\nb\"}", .answered),
            ("leading ws", "   \t\n {\"at\":\"\(ts)\",\"status\":200}", .answered),
            ("trailing ws", "{\"at\":\"\(ts)\",\"status\":200} \t\r\n", .answered),
            ("trailing garbage", #"{"at":"\#(ts)","status":200}x"#, .answered),
            ("trailing object", #"{"at":"\#(ts)","status":200} {}"#, .answered),
            ("ws only", "   \t\r\n  ", .answered),
            ("empty", "", .answered),
            ("trailing comma pad", #"{"pad":1,}"#, .answered),
            ("trailing comma status", #"{"status":200,}"#, .answered),
            ("trailing comma nested", #"{"pad":[1,]}"#, .answered),
            ("double comma", #"{"pad":1,,}"#, .answered),
            ("unpaired surrogate pad", #"{"pad":"\ud800"}"#, .answered),
            ("unpaired surrogate model", #"{"at":"\#(ts)","status":200,"model":"\ud800"}"#, .answered),
            ("surrogate pair", #"{"at":"\#(ts)","status":200,"model":"\ud83d\ude00m"}"#, .answered),
            ("nulls in unknown", #"{"at":"\#(ts)","status":200,"pad":null}"#, .answered),
            ("nested unknown", #"{"at":"\#(ts)","status":200,"pad":{"a":[1,2,{"b":"x"}]}}"#, .answered),
            ("deep nest 130", #"{"pad":\#(String(repeating: "[", count: 130) + String(repeating: "]", count: 130))}"#, .answered),
            ("deep nest 129", #"{"pad":\#(String(repeating: "[", count: 129) + String(repeating: "]", count: 129))}"#, .answered),
            ("deep nest 520", #"{"pad":\#(String(repeating: "[", count: 520) + String(repeating: "]", count: 520))}"#, .answered),
            ("decimal limit ok", #"{"pad":\#("1" + String(repeating: "0", count: 165)),}"#, .answered),
            ("decimal limit over", #"{"pad":\#(String(repeating: "9", count: 166)),}"#, .answered),
            ("float posinf", #"{"pad":1e999,}"#, .answered),
            ("float neginf", #"{"pad":-1e999,}"#, .answered),
            ("bom", "\u{feff}{\"pad\":1,}", .answered),
            ("bom status", "\u{feff}{\"status\":1,}", .answered),
            ("404 no at", #"{"status":404}"#, .answered),
        ]
    }

    func testPerLineVerdictsAndEventsMatchOracle() throws {
        for (name, line, expect) in corpus {
            let data = Data(line.utf8)
            var oracleCache = CodexRouterEventLineParser.TimestampCache()
            let oracle = CodexRouterEventLineParser.parseResultSwift(data[...], timestampCache: &oracleCache)
            let oracleParseEvent = CodexRouterEventLineParser.parseEventSwift(
                data[...], timestampCache: &oracleCache)
            // The payload the oracle produced for this line: `.event`/`.malformedEvent`
            // carry theirs; `.irrelevant` surfaces whatever `parse` would return (the
            // non-2xx event with a valid timestamp, else nil); `.malformed` has none.
            let oraclePayload: Event? = switch oracle {
            case .event(let event), .malformedEvent(let event): event
            case .irrelevant, .malformed: oracleParseEvent
            }

            let detail = CodexRouterRustParser.parseLineDetail(data[...])
            switch expect {
            case .answered:
                let detail = try XCTUnwrap(detail, "\(name): bridge should answer")
                XCTAssertEqual(
                    verdictKind(detail.outcome), verdictKind(oracle),
                    "\(name): verdict \(verdictKind(detail.outcome)) != oracle \(verdictKind(oracle))")
                XCTAssertEqual(detail.event, oraclePayload, "\(name): event payload mismatch")
            case .declines:
                XCTAssertNil(detail, "\(name): bridge should decline")
                var dispatchedCache = CodexRouterEventLineParser.TimestampCache()
                let dispatched = CodexRouterEventLineParser.parseResult(data[...], timestampCache: &dispatchedCache)
                XCTAssertEqual(
                    verdictKind(dispatched), verdictKind(oracle),
                    "\(name): dispatched verdict \(verdictKind(dispatched)) != oracle \(verdictKind(oracle))")
                XCTAssertEqual(
                    CodexRouterEventLineParser.parse(data[...]), oracleParseEvent,
                    "\(name): dispatched parse mismatch")
            }
        }
    }

    /// The `parse` surface returns the produced event for every line whose timestamp parsed —
    /// including `.malformedEvent` verdicts and non-2xx `.irrelevant` short circuits.
    func testParseSurfaceReturnsIrrelevantAndMalformedEventPayloads() throws {
        var cache = CodexRouterEventLineParser.TimestampCache()
        // Non-2xx with a valid timestamp: `.irrelevant` verdict, but `parse` returns the event.
        let non2xx = Data(#"{"at":"2026-10-02T12:00:00Z","status":404,"model":"m"}"#.utf8)
        let detail = try XCTUnwrap(CodexRouterRustParser.parseLineDetail(non2xx[...]))
        XCTAssertEqual(verdictKind(detail.outcome), .irrelevant)
        XCTAssertEqual(
            detail.event,
            CodexRouterEventLineParser.parseEventSwift(non2xx[...], timestampCache: &cache))
        XCTAssertEqual(CodexRouterEventLineParser.parse(non2xx[...]), detail.event)
        // Malformed-event verdicts keep their payload through `parseResult` but `parse` is nil
        // only when the timestamp failed — here it parsed, so `parse` still returns the event.
        let badStatus = Data(#"{"at":"2026-10-02T12:00:00Z","status":2.5}"#.utf8)
        let detail2 = try XCTUnwrap(CodexRouterRustParser.parseLineDetail(badStatus[...]))
        XCTAssertEqual(verdictKind(detail2.outcome), .malformedEvent)
        XCTAssertEqual(CodexRouterEventLineParser.parse(badStatus[...]), detail2.event)
        // Distant-past malformed events surface as nil on `parse`.
        let noAt = Data(#"{"status":200}"#.utf8)
        XCTAssertNil(CodexRouterEventLineParser.parse(noAt[...]))
        let detail3 = try XCTUnwrap(CodexRouterRustParser.parseLineDetail(noAt[...]))
        XCTAssertEqual(verdictKind(detail3.outcome), .malformedEvent)
        XCTAssertEqual(detail3.event?.hasValidTimestampField, false)
    }

    // MARK: - Whole-file parity

    /// The Swift whole-file oracle — a line-for-line mirror of `fullParseAndCheckpoint`'s
    /// `readLines(deliverFinalPartial: false)` + `looksLikeCompleteObject` tail handling.
    private func parseFileSwift(at url: URL) -> [Event]? {
        var collected: [Event] = []
        var malformedLine = false
        var timestampCache = CodexRouterEventLineParser.TimestampCache()
        let read = JSONLFileReader.readLines(
            at: url,
            chunkSize: 64 * 1024,
            deliverFinalPartial: false
        ) { line in
            switch CodexRouterEventLineParser.parseResultSwift(line, timestampCache: &timestampCache) {
            case .event(let event), .malformedEvent(let event):
                collected.append(event)
            case .irrelevant:
                break
            case .malformed:
                malformedLine = true
            }
        }
        guard read.isComplete, !malformedLine else { return nil }
        if !read.finalPartial.isEmpty,
           CodexRouterEventLineParser.looksLikeCompleteObject(read.finalPartial[...]) {
            switch CodexRouterEventLineParser.parseResultSwift(
                read.finalPartial[...], timestampCache: &timestampCache) {
            case .event(let event), .malformedEvent(let event):
                collected.append(event)
            case .irrelevant:
                break
            case .malformed:
                return nil
            }
        }
        return collected
    }

    private func writeTemp(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("router-parity-\(UUID().uuidString).jsonl")
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func assertFileParity(_ contents: String, _ label: String) throws {
        let url = try writeTemp(contents)
        defer { try? FileManager.default.removeItem(at: url) }
        let oracle = parseFileSwift(at: url)
        switch CodexRouterRustParser.parseFile(at: url) {
        case .success(let events, let read):
            XCTAssertEqual(events, oracle, "\(label): events mismatch")
            XCTAssertTrue(read.isComplete, "\(label): success must report a complete read")
        case .failed:
            XCTAssertNil(oracle, "\(label): Rust failed but oracle produced events")
        case .fallback:
            // Whole-file fallback is a contract answer, not a verdict — record it; the
            // dedicated fallback test below pins which inputs trigger it.
            XCTFail("\(label): unexpected fallback")
        }
    }

    func testWholeFileParityValidLedger() throws {
        let ts = "2026-10-02T12:00:00Z"
        try assertFileParity(
            """
            {"at":"\(ts)","status":200,"model":"gpt-6","provider":"openai","inputTokens":10,"outputTokens":5}
            {"at":"\(ts)","status":404}
            {"at":"\(ts)","status":200,"inputTokens":-5}
            {"foo":"irrelevant?","status":
            """,
            "truncated file")
        try assertFileParity(
            """
            {"at":"\(ts)","status":200,"model":"m"}
            {"at":"\(ts)","status":200,"model":"n"}
            """,
            "two events")
        try assertFileParity(
            #"{"at":"2026-10-02T12:00:00Z","status":200,"model":"tail"}"#,
            "unterminated final object is still emitted")
    }

    func testWholeFileParityFailedAndFallback() throws {
        let ts = "2026-10-02T12:00:00Z"
        // A malformed line poisons the whole file for both engines.
        let url = try writeTemp("{\"at\":\"\(ts)\",\"status\":200}\n{\"status\":200\n")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(parseFileSwift(at: url))
        guard case .failed = CodexRouterRustParser.parseFile(at: url) else {
            XCTFail("malformed line should fail the file")
            return
        }

        // A non-canonical timestamp line sends the whole file back to Swift — never a
        // partial Rust answer.
        let fallbackURL = try writeTemp(
            "{\"at\":\"\(ts)\",\"status\":200}\n{\"at\":\"2026-10-02 12:00:00\",\"status\":200}\n")
        defer { try? FileManager.default.removeItem(at: fallbackURL) }
        guard case .fallback = CodexRouterRustParser.parseFile(at: fallbackURL) else {
            XCTFail("non-canonical timestamp should trigger whole-file fallback")
            return
        }
        XCTAssertNotNil(parseFileSwift(at: fallbackURL))
    }

    func testWholeFileOversizedLineFails() throws {
        let oversized = String(repeating: "x", count: 64 * 1024 * 1024 + 1)
        let url = try writeTemp("{\"pad\":\"\(oversized)\"}\n{\"status\":200}\n")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(parseFileSwift(at: url))
        guard case .failed = CodexRouterRustParser.parseFile(at: url) else {
            XCTFail("oversized line should fail the file")
            return
        }
    }

    func testWholeFileEmptyAndTornTail() throws {
        // An unterminated tail that is NOT `}`-terminated stays buffered — neither parsed
        // nor counted as malformed.
        let ts = "2026-10-02T12:00:00Z"
        let url = try writeTemp("{\"at\":\"\(ts)\",\"status\":200}\n{\"at\":\"\(ts)\",\"status\":")
        defer { try? FileManager.default.removeItem(at: url) }
        guard case .success(let events, let read) = CodexRouterRustParser.parseFile(at: url) else {
            XCTFail("torn tail should not fail the file")
            return
        }
        XCTAssertEqual(events, parseFileSwift(at: url))
        XCTAssertEqual(events.count, 1)
        // The torn tail is retained as the append-resume carry.
        XCTAssertEqual(read.finalPartial, Data("{\"at\":\"\(ts)\",\"status\":".utf8))

        let empty = try writeTemp("")
        defer { try? FileManager.default.removeItem(at: empty) }
        guard case .success(let emptyEvents, _) = CodexRouterRustParser.parseFile(at: empty) else {
            XCTFail("empty file should succeed")
            return
        }
        XCTAssertEqual(emptyEvents, [])
    }

    // MARK: - Benchmark

    /// Opt-in benchmark comparing the Rust whole-file path against the Swift oracle over a
    /// synthetic ledger. `QUOTABAR_ROUTER_PARSE_BENCH=1 swift test --filter CodexRouterRustParserTests`.
    func testRouterParseBenchmarkRustVsSwift() throws {
        guard ProcessInfo.processInfo.environment["QUOTABAR_ROUTER_PARSE_BENCH"] == "1" else {
            throw XCTSkip("Enable the router parse benchmark explicitly")
        }
        var lines: [String] = []
        for index in 0..<20_000 {
            if index.isMultiple(of: 4) {
                lines.append(#"{"noise":{"ignored":true}}"#)
            } else {
                lines.append(
                    #"{"at":"2026-10-02T12:00:00Z","status":200,"model":"gpt-6","provider":"openai","inputTokens":100,"cachedInputTokens":30,"outputTokens":50,"reasoningTokens":10,"totalTokens":190,"accountId":"acct-\#(index)","serviceTier":"default"}"#
                )
            }
        }
        let url = try writeTemp(lines.joined(separator: "\n") + "\n")
        defer { try? FileManager.default.removeItem(at: url) }

        let rustStats = measure {
            guard case .success(let events, _) = CodexRouterRustParser.parseFile(at: url) else { return -1 }
            return events.count
        }
        let swiftStats = measure {
            parseFileSwift(at: url)?.count ?? -1
        }
        XCTAssertEqual(rustStats.result, swiftStats.result)

        print(String(
            format: "ROUTER_PARSE_BENCH rustCPU=%.6fs rustWall=%.6fs swiftCPU=%.6fs swiftWall=%.6fs cpuRatio=%.2fx",
            rustStats.cpu, rustStats.wall, swiftStats.cpu, swiftStats.wall,
            rustStats.cpu > 0 ? swiftStats.cpu / rustStats.cpu : -1
        ))
    }

    /// An irrelevant non-2xx row still contributes its event to a per-line `parse`, but the
    /// whole-file surface skips it exactly like the Swift driver.
    func testWholeFileNon2xxSkipped() throws {
        let ts = "2026-10-02T12:00:00Z"
        let url = try writeTemp(
            "{\"at\":\"\(ts)\",\"status\":404}\n{\"at\":\"\(ts)\",\"status\":200}\n")
        defer { try? FileManager.default.removeItem(at: url) }
        guard case .success(let events, _) = CodexRouterRustParser.parseFile(at: url) else {
            XCTFail("file should succeed")
            return
        }
        XCTAssertEqual(events, parseFileSwift(at: url))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.status, 200)
    }

    private func measure<T>(_ body: () throws -> T) rethrows -> (result: T, cpu: Double, wall: Double) {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let startCPU = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
        let startWall = DispatchTime.now().uptimeNanoseconds
        let result = try body()
        let wall = Double(DispatchTime.now().uptimeNanoseconds - startWall) / 1e9
        getrusage(RUSAGE_SELF, &usage)
        let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6 - startCPU
        return (result, cpu, wall)
    }
}
