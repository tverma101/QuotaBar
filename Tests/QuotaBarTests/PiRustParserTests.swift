import Darwin
import Foundation
import XCTest
@testable import QuotaBar

/// FFI parity tests for the quotabar-core Rust Pi session parser. The Swift reference
/// implementation (`PiUsageScanner.parseFileSwift(at:)`) is the oracle: for every file the
/// Rust whole-file path accepts, its entries must match exactly; for the shapes it declines it
/// must return `.fallback` so production re-runs Swift — never a different answer.
final class PiRustParserTests: XCTestCase {
    private typealias Entry = PiUsageScanner.Entry

    /// Builds one pi session-log line. Token counts default to a self-consistent total
    /// (`input + output + cacheRead + cacheWrite`); `total` overrides it for the mismatch cases.
    /// `cost` is a raw JSON fragment so non-literal totals (`"1e13"`) can be expressed.
    private func piLine(
        id: String? = "m1",
        timestamp: String = "2026-07-12T10:00:00.000Z",
        type: String = "message",
        role: String = "assistant",
        provider: String = "anthropic",
        model: String? = "claude-opus-4-8",
        input: Int = 100, output: Int = 50,
        cacheRead: Int = 0, cacheWrite: Int = 0, cacheWrite1h: Int = 0,
        total: Int? = nil,
        cost: String? = "0.5"
    ) -> String {
        let idJSON = id.map { "\"id\":\"\($0)\"," } ?? ""
        let modelJSON = model.map { "\"model\":\"\($0)\"," } ?? ""
        let costJSON = cost.map { ",\"cost\":{\"total\":\($0)}" } ?? ""
        let total = total ?? (input + output + cacheRead + cacheWrite)
        return """
        {"type":"\(type)",\(idJSON)"timestamp":"\(timestamp)","message":{"role":"\(role)","provider":"\(provider)",\(modelJSON)"usage":{"input":\(input),"output":\(output),"cacheRead":\(cacheRead),"cacheWrite":\(cacheWrite),"cacheWrite1h":\(cacheWrite1h),"totalTokens":\(total)\(costJSON)}}}
        """
    }

    /// Lines the Rust parser accepts or rejects deterministically; the whole-file result must
    /// agree with the Swift oracle (entries match, or both decline to nil).
    private var sharedCorpus: [String] { [
        // Canonical mapped line — all fields, cache split, carried cost.
        piLine(cacheRead: 30, cacheWrite: 20, cacheWrite1h: 8), // total 200
        // Every mapped provider resolves its card.
        piLine(provider: "claude-agent-sdk"),
        piLine(provider: "openai-codex", model: "gpt-5.3-codex"),
        piLine(provider: "cursor", model: "composer-2.5", cost: "0"),
        piLine(provider: "zai", model: "glm-5"),
        piLine(provider: "zhipu", model: "glm-5"),
        piLine(provider: "google-antigravity", model: "gemini-3-pro"),
        piLine(provider: "github-copilot", model: "gpt-5"),
        // Non-fractional canonical timestamp.
        piLine(timestamp: "2026-07-12T10:00:00Z"),
        // id: absent → nil; whitespace-padded → stored raw.
        piLine(id: nil),
        piLine(id: "  spaced-id  "),
        // model: absent → "", stored trimmed.
        piLine(model: nil),
        piLine(model: "  claude-sonnet-4-6  "),
        // Zero-token row still parses; cost absent/null/empty/null-total → no carried cost.
        piLine(input: 0, output: 0),
        piLine(cost: nil),
        #"{"type":"message","id":"m","timestamp":"2026-07-12T10:00:00.000Z","message":{"role":"assistant","provider":"anthropic","usage":{"input":1,"output":1,"totalTokens":2,"cost":null}}}"#,
        #"{"type":"message","id":"m","timestamp":"2026-07-12T10:00:00.000Z","message":{"role":"assistant","provider":"anthropic","usage":{"input":1,"output":1,"totalTokens":2,"cost":{}}}}"#,
        #"{"type":"message","id":"m","timestamp":"2026-07-12T10:00:00.000Z","message":{"role":"assistant","provider":"anthropic","usage":{"input":1,"output":1,"totalTokens":2,"cost":{"total":null}}}}"#,
        // Cost at the 1e12 bound.
        piLine(cost: "1e12"),
        // Irrelevant: no marker at all.
        #"{"noise":true}"#,
        #"not json at all"#,
        // Irrelevant: `"usage" : {` with a space does not trip the byte prefilter.
        #"{"type":"message","timestamp":"2026-07-12T10:00:00.000Z","message":{"role":"assistant","provider":"anthropic","usage" : {"input":1,"output":1,"totalTokens":2}}}"#,
        // Irrelevant: marker trips inside a string value, but `type` is absent.
        #"{"note":"contains \"usage\":{\" text"}"#,
        // Irrelevant: wrong/absent/non-string type, non-assistant/absent role, unmapped provider.
        piLine(type: "user"),
        #"{"type":7,"timestamp":"2026-07-12T10:00:00.000Z","message":{"role":"assistant","provider":"anthropic","usage":{"input":1,"output":1,"totalTokens":2}}}"#,
        #"{"timestamp":"2026-07-12T10:00:00.000Z","message":{"role":"assistant","provider":"anthropic","usage":{"input":1,"output":1,"totalTokens":2}}}"#,
        piLine(role: "user"),
        #"{"type":"message","timestamp":"2026-07-12T10:00:00.000Z","message":{"provider":"anthropic","usage":{"input":1,"output":1,"totalTokens":2}}}"#,
        piLine(provider: "nvidia-nim"),
        // Malformed: invalid JSON / non-object JSON carrying the marker.
        #"{"usage":{ but broken"#,
        #"[{"usage":{"a":1}}]"#,
        // Malformed: `message` absent, null, or non-object (top-level usage keeps the marker alive).
        #"{"type":"message","timestamp":"2026-07-12T10:00:00.000Z","usage":{"a":1},"id":"m"}"#,
        #"{"type":"message","timestamp":"2026-07-12T10:00:00.000Z","usage":{"a":1},"message":null}"#,
        #"{"type":"message","timestamp":"2026-07-12T10:00:00.000Z","usage":{"a":1},"message":"scalar"}"#,
        // Malformed: provider absent/null/non-string.
        #"{"type":"message","timestamp":"2026-07-12T10:00:00.000Z","message":{"role":"assistant","usage":{"input":1,"output":1,"totalTokens":2}}}"#,
        #"{"type":"message","timestamp":"2026-07-12T10:00:00.000Z","message":{"role":"assistant","provider":null,"usage":{"input":1,"output":1,"totalTokens":2}}}"#,
        #"{"type":"message","timestamp":"2026-07-12T10:00:00.000Z","message":{"role":"assistant","provider":7,"usage":{"input":1,"output":1,"totalTokens":2}}}"#,
        // Malformed: timestamp absent, non-string, or canonical-shape-but-invalid.
        #"{"type":"message","id":"m","message":{"role":"assistant","provider":"anthropic","usage":{"input":1,"output":1,"totalTokens":2}}}"#,
        #"{"type":"message","timestamp":1783850400,"message":{"role":"assistant","provider":"anthropic","usage":{"input":1,"output":1,"totalTokens":2}}}"#,
        #"{"type":"message","timestamp":null,"message":{"role":"assistant","provider":"anthropic","usage":{"input":1,"output":1,"totalTokens":2}}}"#,
        #"{"type":"message","timestamp":"2026-13-12T10:00:00.000Z","message":{"role":"assistant","provider":"anthropic","usage":{"input":1,"output":1,"totalTokens":2}}}"#,
        // Malformed: usage absent/null/non-object inside message.
        #"{"type":"message","timestamp":"2026-07-12T10:00:00.000Z","usage":{"a":1},"message":{"role":"assistant","provider":"anthropic"}}"#,
        #"{"type":"message","timestamp":"2026-07-12T10:00:00.000Z","usage":{"a":1},"message":{"role":"assistant","provider":"anthropic","usage":null}}"#,
        #"{"type":"message","timestamp":"2026-07-12T10:00:00.000Z","usage":{"a":1},"message":{"role":"assistant","provider":"anthropic","usage":7}}"#,
        // Malformed: id present but null/numeric/blank/empty.
        #"{"type":"message","id":null,"timestamp":"2026-07-12T10:00:00.000Z","message":{"role":"assistant","provider":"anthropic","usage":{"input":1,"output":1,"totalTokens":2}}}"#,
        #"{"type":"message","id":123,"timestamp":"2026-07-12T10:00:00.000Z","message":{"role":"assistant","provider":"anthropic","usage":{"input":1,"output":1,"totalTokens":2}}}"#,
        #"{"type":"message","id":"   ","timestamp":"2026-07-12T10:00:00.000Z","message":{"role":"assistant","provider":"anthropic","usage":{"input":1,"output":1,"totalTokens":2}}}"#,
        #"{"type":"message","id":"","timestamp":"2026-07-12T10:00:00.000Z","message":{"role":"assistant","provider":"anthropic","usage":{"input":1,"output":1,"totalTokens":2}}}"#,
        // Malformed: required counts missing; present-null counts (required AND optional);
        // bool/fractional/negative/over-cap/string counts.
        #"{"type":"message","timestamp":"2026-07-12T10:00:00.000Z","message":{"role":"assistant","provider":"anthropic","usage":{"output":1,"totalTokens":2}}}"#,
        #"{"type":"message","timestamp":"2026-07-12T10:00:00.000Z","message":{"role":"assistant","provider":"anthropic","usage":{"input":1,"totalTokens":2}}}"#,
        #"{"type":"message","timestamp":"2026-07-12T10:00:00.000Z","message":{"role":"assistant","provider":"anthropic","usage":{"input":1,"output":1}}}"#,
        #"{"type":"message","timestamp":"2026-07-12T10:00:00.000Z","message":{"role":"assistant","provider":"anthropic","usage":{"input":null,"output":1,"totalTokens":2}}}"#,
        #"{"type":"message","timestamp":"2026-07-12T10:00:00.000Z","message":{"role":"assistant","provider":"anthropic","usage":{"input":1,"output":1,"cacheRead":null,"totalTokens":2}}}"#,
        #"{"type":"message","timestamp":"2026-07-12T10:00:00.000Z","message":{"role":"assistant","provider":"anthropic","usage":{"input":1,"output":1,"cacheWrite1h":null,"totalTokens":2}}}"#,
        #"{"type":"message","timestamp":"2026-07-12T10:00:00.000Z","message":{"role":"assistant","provider":"anthropic","usage":{"input":true,"output":1,"totalTokens":2}}}"#,
        #"{"type":"message","timestamp":"2026-07-12T10:00:00.000Z","message":{"role":"assistant","provider":"anthropic","usage":{"input":1.5,"output":1,"totalTokens":2}}}"#,
        #"{"type":"message","timestamp":"2026-07-12T10:00:00.000Z","message":{"role":"assistant","provider":"anthropic","usage":{"input":-1,"output":1,"totalTokens":2}}}"#,
        #"{"type":"message","timestamp":"2026-07-12T10:00:00.000Z","message":{"role":"assistant","provider":"anthropic","usage":{"input":1e16,"output":1,"totalTokens":2}}}"#,
        #"{"type":"message","timestamp":"2026-07-12T10:00:00.000Z","message":{"role":"assistant","provider":"anthropic","usage":{"input":"5","output":1,"totalTokens":2}}}"#,
        // Malformed: cacheWrite1h > cacheWrite; totalTokens ≠ bucket sum.
        #"{"type":"message","timestamp":"2026-07-12T10:00:00.000Z","message":{"role":"assistant","provider":"anthropic","usage":{"input":10,"output":5,"cacheWrite":40,"cacheWrite1h":41,"totalTokens":55}}}"#,
        #"{"type":"message","timestamp":"2026-07-12T10:00:00.000Z","message":{"role":"assistant","provider":"anthropic","usage":{"input":10,"output":5,"cacheRead":3,"totalTokens":15}}}"#,
        // Malformed: cost non-object; total non-number/bool/negative/over-cap.
        #"{"type":"message","timestamp":"2026-07-12T10:00:00.000Z","message":{"role":"assistant","provider":"anthropic","usage":{"input":1,"output":1,"totalTokens":2,"cost":5}}}"#,
        #"{"type":"message","timestamp":"2026-07-12T10:00:00.000Z","message":{"role":"assistant","provider":"anthropic","usage":{"input":1,"output":1,"totalTokens":2,"cost":{"total":"x"}}}}"#,
        #"{"type":"message","timestamp":"2026-07-12T10:00:00.000Z","message":{"role":"assistant","provider":"anthropic","usage":{"input":1,"output":1,"totalTokens":2,"cost":{"total":true}}}}"#,
        #"{"type":"message","timestamp":"2026-07-12T10:00:00.000Z","message":{"role":"assistant","provider":"anthropic","usage":{"input":1,"output":1,"totalTokens":2,"cost":{"total":-1}}}}"#,
        #"{"type":"message","timestamp":"2026-07-12T10:00:00.000Z","message":{"role":"assistant","provider":"anthropic","usage":{"input":1,"output":1,"totalTokens":2,"cost":{"total":1e13}}}}"#,
        // Malformed: model present but not a string — null included.
        #"{"type":"message","timestamp":"2026-07-12T10:00:00.000Z","message":{"role":"assistant","provider":"anthropic","model":null,"usage":{"input":1,"output":1,"totalTokens":2}}}"#,
        #"{"type":"message","timestamp":"2026-07-12T10:00:00.000Z","message":{"role":"assistant","provider":"anthropic","model":123,"usage":{"input":1,"output":1,"totalTokens":2}}}"#,
        #"{"type":"message","timestamp":"2026-07-12T10:00:00.000Z","message":{"role":"assistant","provider":"anthropic","model":{},"usage":{"input":1,"output":1,"totalTokens":2}}}"#,
    ] }

    /// Lines the Rust parser declines — non-canonical timestamp strings only.
    private var fallbackCorpus: [String] { [
        piLine(timestamp: "2026-07-12 10:00:00"),
        piLine(timestamp: "2026-07-12T10:00:00.123456Z"),
        piLine(timestamp: "2026-07-12T10:00:00+00:00"),
    ] }

    // MARK: - File-level parity

    func testWholeFileParseMatchesSwiftOracle() throws {
        for line in sharedCorpus {
            let url = try writeTempFile(lines: [line])
            defer { try? FileManager.default.removeItem(at: url) }
            try assertParity(at: url, description: line)
        }
    }

    func testMultiLineFileParity() throws {
        let url = try writeTempFile(lines: sharedCorpus)
        defer { try? FileManager.default.removeItem(at: url) }
        try assertParity(at: url, description: "whole corpus file")
    }

    /// A file of only valid + irrelevant lines produces entry equality, not just shared failure.
    func testMultiLineValidFileEntriesMatch() throws {
        let lines = [
            #"{"noise":true}"#,
            piLine(id: "a", input: 10, output: 5, cost: "0.25"),
            piLine(id: "b", provider: "openai-codex", model: "gpt-5.3-codex", input: 7, output: 3),
            piLine(id: "skipped", provider: "nvidia-nim"),
            piLine(id: "c", cacheRead: 30, cacheWrite: 20, cacheWrite1h: 8, cost: nil),
        ]
        let url = try writeTempFile(lines: lines)
        defer { try? FileManager.default.removeItem(at: url) }
        guard case .success(let rust) = PiRustParser.parseFile(at: url) else {
            return XCTFail("Rust should accept the valid-only file")
        }
        let swift = try XCTUnwrap(PiUsageScanner.parseFileSwift(at: url))
        XCTAssertEqual(rust, swift)
        XCTAssertEqual(rust.map { $0.id }, ["a", "b", "c"])
    }

    func testNoiseThenValidThenMalformedFile() throws {
        let lines = [
            #"{"noise":true}"#,
            piLine(id: "ok", input: 5, output: 2, cost: "0.25"),
            // The malformed middle line fails the whole file in BOTH engines.
            #"{"type":"message","timestamp":"2026-07-12T10:00:00.000Z","message":{"role":"assistant","provider":"anthropic","usage":{"input":1,"output":1,"totalTokens":99}}}"#,
        ]
        let url = try writeTempFile(lines: lines)
        defer { try? FileManager.default.removeItem(at: url) }
        try assertParity(at: url, description: "mixed file")
    }

    func testTrailingPartialLineIsDelivered() throws {
        let url = try writeTempFile(lines: [piLine(id: "tail")], trailingNewline: false)
        defer { try? FileManager.default.removeItem(at: url) }
        try assertParity(at: url, description: "unterminated final line")
        guard case .success(let rust) = PiRustParser.parseFile(at: url) else {
            return XCTFail("Rust should deliver the trailing partial line")
        }
        XCTAssertEqual(rust.map { $0.id }, ["tail"])
    }

    func testEmptyFileAgrees() throws {
        let url = try writeTempFile(lines: [])
        defer { try? FileManager.default.removeItem(at: url) }
        try assertParity(at: url, description: "empty file")
    }

    func testMissingFileFailsInBothEngines() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("quotabar-pi-parity-missing-\(UUID().uuidString).jsonl")
        XCTAssertNil(PiUsageScanner.parseFileSwift(at: url))
        guard case .failed = PiRustParser.parseFile(at: url) else {
            XCTFail("Rust parser should report failure for a missing file")
            return
        }
    }

    // MARK: - Fallback contract

    func testFallbackCorpusDeclines() throws {
        for line in fallbackCorpus {
            let url = try writeTempFile(lines: [line])
            defer { try? FileManager.default.removeItem(at: url) }
            guard case .fallback = PiRustParser.parseFile(at: url) else {
                XCTFail("Rust parser should decline non-canonical timestamp: \(line)")
                continue
            }
            // The Swift oracle still parses the line — fallback preserves those entries.
            XCTAssertNotNil(
                PiUsageScanner.parseFileSwift(at: url),
                "Swift oracle should parse: \(line)"
            )
        }
    }

    /// A timestamp string the canonical parser doesn't recognize always declines to Swift —
    /// even one Swift itself then rejects as malformed (the file fails via the Swift path).
    func testUnparseableTimestampFallsBackToSwiftMalformed() throws {
        let line = piLine(timestamp: "not-a-timestamp")
        let url = try writeTempFile(lines: [line])
        defer { try? FileManager.default.removeItem(at: url) }
        guard case .fallback = PiRustParser.parseFile(at: url) else {
            return XCTFail("Rust parser should decline an unrecognized timestamp string")
        }
        XCTAssertNil(PiUsageScanner.parseFileSwift(at: url))
    }

    func testPerLineSurfaceMatchesFileSurface() throws {
        for line in sharedCorpus {
            let url = try writeTempFile(lines: [line])
            defer { try? FileManager.default.removeItem(at: url) }
            let fileOutcome = PiRustParser.parseFile(at: url)
            guard case .success(let fileEntries) = fileOutcome else {
                continue // failed/fallback files are covered by their own tests
            }
            guard let rust = PiRustParser.parseLine(Data(line.utf8)) else {
                XCTFail("per-line declined where file accepted: \(line)")
                continue
            }
            switch rust {
            case .entries(let lineEntries):
                XCTAssertEqual(lineEntries, fileEntries, "line/file mismatch: \(line)")
            case .irrelevant:
                XCTAssertTrue(fileEntries.isEmpty, "irrelevant line produced entries: \(line)")
            case .malformed:
                XCTFail("malformed line cannot produce a successful file: \(line)")
            }
        }
    }

    // MARK: - Entry field spot checks through the Rust path

    /// `PiUsageScanner.parseLine` is Rust-first — these run through `PiRustParser` whenever the
    /// Rust parser accepts the shape, and the assertions pin the decoded contract.
    func testDecodedEntryFields() {
        let entry = PiUsageScanner.parseLine(Data(
            piLine(id: "  raw-id  ", cacheRead: 30, cacheWrite: 20, cacheWrite1h: 8).utf8
        ))
        XCTAssertEqual(entry?.id, "  raw-id  ")
        XCTAssertEqual(entry?.cardID, "claude")
        XCTAssertEqual(entry?.model, "claude-opus-4-8")
        XCTAssertEqual(entry?.carriedCost, 0.5)
        XCTAssertEqual(entry?.reportedTotalTokens, 200)
        XCTAssertEqual(entry?.tokens.cacheWrite5m, 12)
        XCTAssertEqual(entry?.tokens.cacheWrite1h, 8)
        XCTAssertEqual(entry?.tokens.cacheRead, 30)
        XCTAssertEqual(entry?.tokens.input, 100)
        XCTAssertEqual(entry?.tokens.output, 50)
    }

    // MARK: - Benchmark

    /// Opt-in benchmark comparing the Rust whole-file path against the Swift reference over a
    /// synthetic corpus. `QUOTABAR_PI_PARSE_BENCH=1 swift test --filter PiRustParserTests`.
    func testPiParseBenchmarkRustVsSwift() throws {
        guard ProcessInfo.processInfo.environment["QUOTABAR_PI_PARSE_BENCH"] == "1" else {
            throw XCTSkip("Enable the Pi parse benchmark explicitly")
        }
        var lines: [String] = []
        for index in 0..<20_000 {
            if index.isMultiple(of: 4) {
                lines.append(#"{"noise":{"note":"unrelated"}}"#)
            } else {
                lines.append(piLine(
                    id: "m\(index)", cacheRead: 30, cacheWrite: 20, cacheWrite1h: 8
                ))
            }
        }
        let url = try writeTempFile(lines: lines)
        defer { try? FileManager.default.removeItem(at: url) }

        let rustStats = measure {
            guard case .success(let entries) = PiRustParser.parseFile(at: url) else { return -1 }
            return entries.count
        }
        let swiftStats = measure {
            PiUsageScanner.parseFileSwift(at: url)?.count ?? -1
        }
        XCTAssertEqual(rustStats.result, swiftStats.result)

        print(String(
            format: "PI_PARSE_BENCH rustCPU=%.6fs rustWall=%.6fs swiftCPU=%.6fs swiftWall=%.6fs cpuRatio=%.2fx",
            rustStats.cpu, rustStats.wall, swiftStats.cpu, swiftStats.wall,
            rustStats.cpu > 0 ? swiftStats.cpu / rustStats.cpu : -1
        ))
    }

    // MARK: - Helpers

    private func assertParity(at url: URL, description: String) throws {
        let swift = PiUsageScanner.parseFileSwift(at: url)
        switch PiRustParser.parseFile(at: url) {
        case .success(let entries):
            let oracle = try XCTUnwrap(swift, "Swift declined a file Rust accepted: \(description)")
            XCTAssertEqual(entries, oracle, "entry mismatch: \(description)")
        case .failed:
            XCTAssertNil(swift, "Rust failed a file Swift accepted: \(description)")
        case .fallback:
            break // Swift owns the answer for declined shapes
        }
    }

    private func writeTempFile(lines: [String], trailingNewline: Bool = true) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("quotabar-pi-parity-\(UUID().uuidString).jsonl")
        var body = lines.joined(separator: "\n")
        if trailingNewline, !body.isEmpty { body.append("\n") }
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func measure<T>(_ body: () throws -> T) rethrows -> (result: T, cpu: Double, wall: Double) {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let startCPU = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
        let startWall = DispatchTime.now().uptimeNanoseconds
        let result = try body()
        getrusage(RUSAGE_SELF, &usage)
        let endCPU = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
        return (result, endCPU - startCPU, Double(DispatchTime.now().uptimeNanoseconds - startWall) / 1e9)
    }
}
