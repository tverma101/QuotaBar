import Darwin
import Foundation
import XCTest
@testable import QuotaBar

/// FFI parity tests for the quotabar-core Rust Grok session parser. The Swift reference
/// implementation (`GrokLogUsageScanner.parseFileSwift(at:)`) is the oracle: for every file the
/// Rust whole-file path accepts, its entries must match exactly; for the shapes it declines it
/// must return `.fallback` so production re-runs Swift — never a different answer.
final class GrokRustParserTests: XCTestCase {
    private typealias Entry = GrokLogUsageScanner.Entry

    /// Lines the Rust parser accepts; the whole-file result must agree with the Swift oracle.
    private let sharedCorpus: [String] = [
        // Canonical completed turn — nested params.update shape.
        GrokLogFixture.completedTurn(
            timestamp: "2026-02-20T12:00:00.000Z", model: "grok-4", input: 100, cached: 30,
            cacheWrite: 20, output: 50, costUsdTicks: 25_000_000_000, eventID: "evt-1"
        ),
        // Non-nested top-level update shape.
        GrokLogFixture.completedTurn(
            timestamp: "2026-02-20T12:00:00.000Z", model: "grok-4", input: 10, output: 5,
            nested: false
        ),
        // Numeric seconds timestamp.
        GrokLogFixture.completedTurn(
            timestamp: "2026-02-20T12:00:00Z", model: "grok-code-fast-1", input: 10, output: 5,
            numericTimestamp: true
        ),
        // agentTimestampMs overrides the object timestamp.
        GrokLogFixture.completedTurn(
            timestamp: "2026-02-20T12:00:00.000Z", model: "grok-4", input: 1, output: 1,
            agentTimestampMs: 1_771_588_800_123
        ),
        // Multi-model turn — sorted model order matters.
        GrokLogFixture.completedTurn(
            timestamp: "2026-02-20T12:00:00.000Z", model: "z-model", input: 5, output: 2,
            additionalModels: ["a-model": ["inputTokens": 7, "outputTokens": 3]]
        ),
        // Reasoning is carried inside outputTokens only.
        GrokLogFixture.completedTurn(
            timestamp: "2026-02-20T12:00:00.000Z", model: "grok-4", input: 10, output: 5,
            reasoning: 3
        ),
        // Zero ticks → carried cost of exactly 0.
        GrokLogFixture.completedTurn(
            timestamp: "2026-02-20T12:00:00.000Z", model: "grok-4", input: 10, output: 5,
            costUsdTicks: 0
        ),
        // Cache invariants at the boundary.
        GrokLogFixture.completedTurn(
            timestamp: "2026-02-20T12:00:00.000Z", model: "grok-4", input: 10, cached: 6,
            cacheWrite: 4, output: 5
        ),
        // Cache invariant violations → file-level failure (malformed).
        GrokLogFixture.completedTurn(
            timestamp: "2026-02-20T12:00:00.000Z", model: "grok-4", input: 10, cached: 11,
            output: 5
        ),
        GrokLogFixture.completedTurn(
            timestamp: "2026-02-20T12:00:00.000Z", model: "grok-4", input: 10, cached: 6,
            cacheWrite: 5, output: 5
        ),
        // Marker present but a different sessionUpdate → irrelevant.
        GrokLogFixture.completedTurn(
            timestamp: "2026-02-20T12:00:00.000Z", model: "grok-4", input: 1, output: 1,
            sessionUpdate: "turn_completed_but_other"
        ),
        GrokLogFixture.completedTurn(
            timestamp: "2026-02-20T12:00:00.000Z", model: "grok-4", input: 1, output: 1,
            sessionUpdate: "turn_started"
        ),
        // Missing usage / missing modelUsage → malformed.
        #"{"timestamp":"2026-02-20T12:00:00.000Z","params":{"update":{"sessionUpdate":"turn_completed"}}}"#,
        #"{"timestamp":"2026-02-20T12:00:00.000Z","params":{"update":{"sessionUpdate":"turn_completed","usage":{}}}}"#,
        // Invalid JSON with the marker → malformed; without → irrelevant.
        #"{"turn_completed" but broken"#,
        // Non-object JSON with the marker → malformed.
        #"[{"turn_completed":true}]"#,
        // No marker at all → irrelevant (not even parsed).
        #"{"params":{"update":{"sessionUpdate":"user_message"}}}"#,
        #"not json at all"#,
        // Scalar _meta / bad eventId / blank eventId → malformed.
        #"{"timestamp":1771588800,"params":{"_meta":7,"update":{"sessionUpdate":"turn_completed","usage":{"modelUsage":{"m":{"inputTokens":1,"outputTokens":1}}}}}}"#,
        #"{"timestamp":1771588800,"params":{"_meta":{"eventId":5},"update":{"sessionUpdate":"turn_completed","usage":{"modelUsage":{"m":{"inputTokens":1,"outputTokens":1}}}}}}"#,
        #"{"timestamp":1771588800,"params":{"_meta":{"eventId":"   "},"update":{"sessionUpdate":"turn_completed","usage":{"modelUsage":{"m":{"inputTokens":1,"outputTokens":1}}}}}}"#,
        // Token-count edges: null (present-but-NSNull is malformed even for optional fields),
        // bool, fractional, over the 1e15 cap.
        #"{"timestamp":1771588800,"params":{"update":{"sessionUpdate":"turn_completed","usage":{"modelUsage":{"m":{"inputTokens":null,"outputTokens":1}}}}}}"#,
        #"{"timestamp":1771588800,"params":{"update":{"sessionUpdate":"turn_completed","usage":{"modelUsage":{"m":{"inputTokens":1,"outputTokens":1,"cachedReadTokens":null}}}}}}"#,
        #"{"timestamp":1771588800,"params":{"update":{"sessionUpdate":"turn_completed","usage":{"modelUsage":{"m":{"inputTokens":true,"outputTokens":1}}}}}}"#,
        #"{"timestamp":1771588800,"params":{"update":{"sessionUpdate":"turn_completed","usage":{"modelUsage":{"m":{"inputTokens":1.5,"outputTokens":1}}}}}}"#,
        #"{"timestamp":1771588800,"params":{"update":{"sessionUpdate":"turn_completed","usage":{"modelUsage":{"m":{"inputTokens":1000000000000001,"outputTokens":1}}}}}}"#,
        // Ticks edges: invalid ticks fail the line; missing per-model ticks inherit top-level
        // only for single-model turns.
        #"{"timestamp":1771588800,"params":{"update":{"sessionUpdate":"turn_completed","usage":{"costUsdTicks":"x","modelUsage":{"m":{"inputTokens":1,"outputTokens":1}}}}}}"#,
        #"{"timestamp":1771588800,"params":{"update":{"sessionUpdate":"turn_completed","usage":{"costUsdTicks":40000000000,"modelUsage":{"m":{"inputTokens":1,"outputTokens":1}}}}}}"#,
        // Timestamp edges: missing → malformed; bool → malformed; out-of-range seconds → malformed.
        #"{"params":{"update":{"sessionUpdate":"turn_completed","usage":{"modelUsage":{"m":{"inputTokens":1,"outputTokens":1}}}}}}"#,
        #"{"timestamp":true,"params":{"update":{"sessionUpdate":"turn_completed","usage":{"modelUsage":{"m":{"inputTokens":1,"outputTokens":1}}}}}}"#,
        #"{"timestamp":1e13,"params":{"update":{"sessionUpdate":"turn_completed","usage":{"modelUsage":{"m":{"inputTokens":1,"outputTokens":1}}}}}}"#,
    ]

    /// Lines the Rust parser declines — non-canonical timestamp strings only.
    private let fallbackCorpus: [String] = [
        GrokLogFixture.completedTurn(
            timestamp: "2026-02-20 12:00:00", model: "grok-4", input: 1, output: 1
        ),
        GrokLogFixture.completedTurn(
            timestamp: "2026-02-20T12:00:00.123456Z", model: "grok-4", input: 1, output: 1
        ),
        GrokLogFixture.completedTurn(
            timestamp: "2026-02-20T12:00:00+00:00", model: "grok-4", input: 1, output: 1
        ),
    ]

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

    func testNoiseThenValidThenMalformedFile() throws {
        let lines = [
            #"{"noise":true}"#,
            GrokLogFixture.completedTurn(
                timestamp: "2026-02-20T12:00:00.000Z", model: "grok-4", input: 5, output: 2,
                costUsdTicks: 10_000_000_000
            ),
            GrokLogFixture.completedTurn(
                timestamp: "2026-02-20T12:00:00.000Z", model: "grok-4", input: 10, cached: 11,
                output: 1
            ),
        ]
        let url = try writeTempFile(lines: lines)
        defer { try? FileManager.default.removeItem(at: url) }
        // The malformed middle line fails the whole file in BOTH engines.
        try assertParity(at: url, description: "mixed file")
    }

    func testTrailingPartialLineIsDelivered() throws {
        let line = GrokLogFixture.completedTurn(
            timestamp: "2026-02-20T12:00:00.000Z", model: "grok-4", input: 5, output: 2
        )
        let url = try writeTempFile(lines: [line], trailingNewline: false)
        defer { try? FileManager.default.removeItem(at: url) }
        try assertParity(at: url, description: "unterminated final line")
    }

    func testEmptyFileAgrees() throws {
        let url = try writeTempFile(lines: [])
        defer { try? FileManager.default.removeItem(at: url) }
        try assertParity(at: url, description: "empty file")
    }

    func testMissingFileFailsInBothEngines() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("quotabar-grok-parity-missing-\(UUID().uuidString).jsonl")
        XCTAssertNil(GrokLogUsageScanner.parseFileSwift(at: url))
        guard case .failed = GrokRustParser.parseFile(at: url) else {
            XCTFail("Rust parser should report failure for a missing file")
            return
        }
    }

    // MARK: - Fallback contract

    func testFallbackCorpusDeclines() throws {
        for line in fallbackCorpus {
            let url = try writeTempFile(lines: [line])
            defer { try? FileManager.default.removeItem(at: url) }
            guard case .fallback = GrokRustParser.parseFile(at: url) else {
                XCTFail("Rust parser should decline non-canonical timestamp: \(line)")
                continue
            }
            // The Swift oracle still parses the line — fallback preserves those entries.
            XCTAssertNotNil(
                GrokLogUsageScanner.parseFileSwift(at: url),
                "Swift oracle should parse: \(line)"
            )
        }
    }

    func testPerLineSurfaceMatchesFileSurface() throws {
        for line in sharedCorpus {
            let url = try writeTempFile(lines: [line])
            defer { try? FileManager.default.removeItem(at: url) }
            let fileOutcome = GrokRustParser.parseFile(at: url)
            guard case .success(let fileEntries) = fileOutcome else {
                continue // failed/fallback files are covered by their own tests
            }
            guard let rust = GrokRustParser.parseLine(Data(line.utf8)) else {
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

    // MARK: - Benchmark

    /// Opt-in benchmark comparing the Rust whole-file path against the Swift reference over a
    /// synthetic corpus. `QUOTABAR_GROK_PARSE_BENCH=1 swift test --filter GrokRustParserTests`.
    func testGrokParseBenchmarkRustVsSwift() throws {
        guard ProcessInfo.processInfo.environment["QUOTABAR_GROK_PARSE_BENCH"] == "1" else {
            throw XCTSkip("Enable the Grok parse benchmark explicitly")
        }
        var lines: [String] = []
        for index in 0..<20_000 {
            if index.isMultiple(of: 4) {
                lines.append(#"{"noise":{"sessionUpdate":"notification"}}"#)
            } else {
                lines.append(GrokLogFixture.completedTurn(
                    timestamp: "2026-02-20T12:00:00.000Z",
                    model: "grok-4", input: 100, cached: 30, cacheWrite: 20, output: 50,
                    costUsdTicks: 25_000_000_000, eventID: "evt-\(index)"
                ))
            }
        }
        let url = try writeTempFile(lines: lines)
        defer { try? FileManager.default.removeItem(at: url) }

        let rustStats = measure {
            guard case .success(let entries) = GrokRustParser.parseFile(at: url) else { return -1 }
            return entries.count
        }
        let swiftStats = measure {
            GrokLogUsageScanner.parseFileSwift(at: url)?.count ?? -1
        }
        XCTAssertEqual(rustStats.result, swiftStats.result)

        print(String(
            format: "GROK_PARSE_BENCH rustCPU=%.6fs rustWall=%.6fs swiftCPU=%.6fs swiftWall=%.6fs cpuRatio=%.2fx",
            rustStats.cpu, rustStats.wall, swiftStats.cpu, swiftStats.wall,
            rustStats.cpu > 0 ? swiftStats.cpu / rustStats.cpu : -1
        ))
    }

    // MARK: - Helpers

    private func assertParity(at url: URL, description: String) throws {
        let swift = GrokLogUsageScanner.parseFileSwift(at: url)
        switch GrokRustParser.parseFile(at: url) {
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
            .appendingPathComponent("quotabar-grok-parity-\(UUID().uuidString).jsonl")
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
