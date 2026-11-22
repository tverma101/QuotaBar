import Darwin
import Foundation
import XCTest
@testable import QuotaBar

/// FFI parity tests for the quotabar-core Rust Claude usage-line parser, plus an opt-in
/// benchmark. The Swift reference implementation (`parseEntriesSwiftForTesting`) is the oracle:
/// whenever Rust accepts a line, its entries and malformed flag must match that path exactly.
/// For the shapes the Rust fast path declines, the bridge must return nil so production falls
/// back to Swift.
final class ClaudeUsageLineRustParserTests: XCTestCase {
    private typealias Entry = ClaudeLogUsageScanner.Entry

    /// Lines the Rust parser accepts; each must agree with the Swift oracle.
    private let sharedCorpus: [String] = [
        // Modern line with cache split, fast speed and a cost.
        #"{"timestamp":"2026-02-20T12:00:00.000Z","sessionId":"s","requestId":"req_1","version":"1.0.24","isSidechain":true,"costUSD":0.5,"message":{"id":"msg_1","model":"claude-test-model","usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":30,"cache_creation":{"ephemeral_5m_input_tokens":20,"ephemeral_1h_input_tokens":10},"speed":"fast"}}}"#,
        // Legacy aggregate cache-creation counter.
        #"{"timestamp":"2026-02-20T12:00:00.000Z","message":{"id":"m","model":"x","usage":{"input_tokens":10,"output_tokens":5,"cache_creation_input_tokens":40,"cache_read_input_tokens":7}}}"#,
        // Non-fractional canonical UTC timestamp.
        #"{"timestamp":"2026-02-20T12:00:00Z","message":{"id":"m","usage":{"input_tokens":1,"output_tokens":2}}}"#,
        // Fractional timestamp validated to millisecond precision.
        #"{"timestamp":"2026-02-20T12:00:00.123Z","message":{"id":"m","usage":{"input_tokens":1,"output_tokens":2}}}"#,
        // Advisor iterations with mixed validity.
        #"{"timestamp":"2026-02-20T12:00:00.000Z","message":{"id":"msg_9","model":"opus","usage":{"input_tokens":10,"output_tokens":5,"iterations":[{"type":"message"},{"type":"advisor_message","model":" advisor-model ","input_tokens":70,"output_tokens":30,"speed":"standard"},{"type":"advisor_message","input_tokens":1,"output_tokens":2}]}}}"#,
        // Advisor with a malformed nested token count — the advisor is dropped, the parent stays.
        #"{"timestamp":"2026-02-20T12:00:00.000Z","message":{"id":"m","usage":{"input_tokens":10,"output_tokens":5,"iterations":[{"type":"advisor_message","input_tokens":"bad","output_tokens":2}]}}}"#,
        // Advisor iteration whose type is a number is malformed.
        #"{"timestamp":"2026-02-20T12:00:00.000Z","message":{"id":"m","usage":{"input_tokens":10,"output_tokens":5,"iterations":[{"type":7}]}}}"#,
        // `iterations` that is not an array is malformed.
        #"{"timestamp":"2026-02-20T12:00:00.000Z","message":{"id":"m","usage":{"input_tokens":10,"output_tokens":5,"iterations":{"type":"advisor_message"}}}}"#,
        // Leap day accepted, non-leap rejection.
        #"{"timestamp":"2024-02-29T00:00:00.000Z","message":{"id":"m","usage":{"input_tokens":1,"output_tokens":2}}}"#,
        #"{"timestamp":"2026-02-29T00:00:00.000Z","message":{"id":"m","usage":{"input_tokens":1,"output_tokens":2}}}"#,
        // Canonical shape, invalid calendar month — malformed in Swift too.
        #"{"timestamp":"2026-13-20T12:00:00Z","message":{"id":"m","usage":{"input_tokens":1,"output_tokens":2}}}"#,
        // Cost edges: valid zero, invalid negatives, bools, huge values, null.
        #"{"timestamp":"2026-02-20T12:00:00.000Z","costUSD":0,"message":{"id":"m","usage":{"input_tokens":1,"output_tokens":2}}}"#,
        #"{"timestamp":"2026-02-20T12:00:00.000Z","costUSD":1234.5,"message":{"id":"m","usage":{"input_tokens":1,"output_tokens":2}}}"#,
        #"{"timestamp":"2026-02-20T12:00:00.000Z","costUSD":-1,"message":{"id":"m","usage":{"input_tokens":1,"output_tokens":2}}}"#,
        #"{"timestamp":"2026-02-20T12:00:00.000Z","costUSD":true,"message":{"id":"m","usage":{"input_tokens":1,"output_tokens":2}}}"#,
        #"{"timestamp":"2026-02-20T12:00:00.000Z","costUSD":1e13,"message":{"id":"m","usage":{"input_tokens":1,"output_tokens":2}}}"#,
        #"{"timestamp":"2026-02-20T12:00:00.000Z","costUSD":null,"message":{"id":"m","usage":{"input_tokens":1,"output_tokens":2}}}"#,
        // Validity edges on ids, version, model, sidechain.
        #"{"timestamp":"2026-02-20T12:00:00.000Z","sessionId":"","message":{"id":"m","usage":{"input_tokens":1,"output_tokens":2}}}"#,
        #"{"timestamp":"2026-02-20T12:00:00.000Z","version":"1.2.3-rc.1+build.5","message":{"id":"m","usage":{"input_tokens":1,"output_tokens":2}}}"#,
        #"{"timestamp":"2026-02-20T12:00:00.000Z","version":"1.0","message":{"id":"m","usage":{"input_tokens":1,"output_tokens":2}}}"#,
        #"{"timestamp":"2026-02-20T12:00:00.000Z","isSidechain":1,"message":{"id":"m","usage":{"input_tokens":1,"output_tokens":2}}}"#,
        #"{"timestamp":"2026-02-20T12:00:00.000Z","message":{"id":"m","model":"  ","usage":{"input_tokens":1,"output_tokens":2}}}"#,
        #"{"timestamp":"2026-02-20T12:00:00.000Z","message":{"id":"m","model":"<synthetic>","usage":{"input_tokens":1,"output_tokens":2}}}"#,
        #"{"timestamp":"2026-02-20T12:00:00.000Z","requestId":null,"message":{"id":"m","usage":{"input_tokens":1,"output_tokens":2}}}"#,
        // Token-count edges: fractional, bool, over the 1e15 cap, cap boundary.
        #"{"timestamp":"2026-02-20T12:00:00.000Z","message":{"id":"m","usage":{"input_tokens":1.5,"output_tokens":2}}}"#,
        #"{"timestamp":"2026-02-20T12:00:00.000Z","message":{"id":"m","usage":{"input_tokens":true,"output_tokens":2}}}"#,
        #"{"timestamp":"2026-02-20T12:00:00.000Z","message":{"id":"m","usage":{"input_tokens":1000000000000001,"output_tokens":2}}}"#,
        #"{"timestamp":"2026-02-20T12:00:00.000Z","message":{"id":"m","usage":{"input_tokens":1000000000000000,"output_tokens":2}}}"#,
        #"{"timestamp":"2026-02-20T12:00:00.000Z","message":{"id":"m","usage":{"input_tokens":null,"output_tokens":2}}}"#,
        #"{"timestamp":"2026-02-20T12:00:00.000Z","message":{"usage":{"output_tokens":2}}}"#,
        // Speed values.
        #"{"timestamp":"2026-02-20T12:00:00.000Z","message":{"id":"m","usage":{"input_tokens":1,"output_tokens":2,"speed":"turbo"}}}"#,
        #"{"timestamp":"2026-02-20T12:00:00.000Z","message":{"id":"m","usage":{"input_tokens":1,"output_tokens":2,"speed":"standard"}}}"#,
        #"{"timestamp":"2026-02-20T12:00:00.000Z","message":{"id":"m","usage":{"input_tokens":1,"output_tokens":2,"speed":null}}}"#,
        // Cache-creation shapes.
        #"{"timestamp":"2026-02-20T12:00:00.000Z","message":{"id":"m","usage":{"input_tokens":1,"output_tokens":2,"cache_creation":{"ephemeral_5m_input_tokens":10}}}}"#,
        #"{"timestamp":"2026-02-20T12:00:00.000Z","message":{"id":"m","usage":{"input_tokens":1,"output_tokens":2,"cache_creation":{"ephemeral_5m_input_tokens":10,"ephemeral_1h_input_tokens":20}}}}"#,
        #"{"timestamp":"2026-02-20T12:00:00.000Z","message":{"id":"m","usage":{"input_tokens":1,"output_tokens":2,"cache_creation":"10"}}}"#,
        #"{"timestamp":"2026-02-20T12:00:00.000Z","message":{"id":"m","usage":{"input_tokens":1,"output_tokens":2,"cache_creation":null}}}"#,
        // Non-assistant rows are skipped silently; assistant rows with a top-level usage are
        // observable malformed records.
        #"{"timestamp":"2026-02-20T12:00:00.000Z","type":"user","message":{"id":"m","usage":{"input_tokens":1,"output_tokens":2}}}"#,
        #"{"timestamp":"2026-02-20T12:00:00.000Z","type":7,"message":{"id":"m","usage":{"input_tokens":1,"output_tokens":2}}}"#,
        #"{"timestamp":"2026-02-20T12:00:00.000Z","type":"assistant","usage":{"input_tokens":1}}"#,
        #"{"timestamp":"2026-02-20T12:00:00.000Z","type":"assistant","message":{"id":"m"}}"#,
        // Garbage input.
        #"this is not json"#,
        #"123"#,
        #"[1,2,3]"#,
        #"{"#,
    ]

    /// Lines the Rust fast path deliberately declines; production falls back to the Swift
    /// reference implementation, whose result must be the Swift parse.
    private let fallbackCorpus: [String] = [
        // Space-separated timestamp — Foundation parses it, Rust must decline.
        #"{"timestamp":"2026-02-20 12:00:00","message":{"id":"m","usage":{"input_tokens":1,"output_tokens":2}}}"#,
        #"{"timestamp":"2026-02-20T12:00:00.123456Z","message":{"id":"m","usage":{"input_tokens":1,"output_tokens":2}}}"#,
        #"{"timestamp":"2026-02-20T12:00:00.12Z","message":{"id":"m","usage":{"input_tokens":1,"output_tokens":2}}}"#,
        #"{"timestamp":"2026-02-20T12:00:00.1234Z","message":{"id":"m","usage":{"input_tokens":1,"output_tokens":2}}}"#,
        #"{"timestamp":"2026-02-20T12:00:00+00:00","message":{"id":"m","usage":{"input_tokens":1,"output_tokens":2}}}"#,
    ]

    func testRustParserMatchesSwiftOracle() throws {
        for line in sharedCorpus {
            let oracle = ClaudeLogUsageScanner.parseEntriesSwiftForTesting(Data(line.utf8))
            let rust = try XCTUnwrap(
                ClaudeUsageLineRustParser.parse(Data(line.utf8)),
                "Rust parser unexpectedly declined line: \(line)"
            )
            XCTAssertEqual(rust.malformed, oracle.malformed, "malformed flag mismatch for: \(line)")
            XCTAssertEqual(rust.entries, oracle.entries, "entries mismatch for: \(line)")
        }
    }

    func testRustParserDeclinesShapesItCannotHandle() throws {
        for line in fallbackCorpus {
            XCTAssertNil(
                ClaudeUsageLineRustParser.parse(Data(line.utf8)),
                "Rust parser should fall back for: \(line)"
            )
        }
    }

    func testFallbackCorpusAgreesWithSwiftOracle() throws {
        // Whatever happens on the Rust side, the production fallback is the Swift reference path;
        // these timestamps must still produce entries in Swift (Foundation handles the shapes), or
        // the line would be silently dropped instead of double-accounted.
        for line in fallbackCorpus {
            let oracle = ClaudeLogUsageScanner.parseEntriesSwiftForTesting(Data(line.utf8))
            XCTAssertEqual(oracle.entries.count, 1, "Swift oracle should parse: \(line)")
            XCTAssertFalse(oracle.malformed, "Swift oracle should not flag malformed: \(line)")
        }
    }

    func testLineWithMoreThanSixtyFourEntriesFallsBack() throws {
        let advisors = (0..<100).map { _ in
            #"{"type":"advisor_message","input_tokens":1,"output_tokens":1}"#
        }.joined(separator: ",")
        let line = #"{"timestamp":"2026-02-20T12:00:00.000Z","message":{"id":"m","usage":{"input_tokens":1,"output_tokens":2,"iterations":["# + advisors + "]}}}"
        XCTAssertNil(ClaudeUsageLineRustParser.parse(Data(line.utf8)))
        let swiftEntries = ClaudeLogUsageScanner.parseEntriesSwiftForTesting(Data(line.utf8)).entries
        XCTAssertEqual(swiftEntries.count, 101)
    }

    /// Opt-in benchmark comparing the Rust FFI path against the Swift reference path over a
    /// synthetic corpus. Enable with `QUOTABAR_CLAUDE_PARSE_BENCH=1 swift test --filter ClaudeUsageLineRustParserTests`.
    func testClaudeParseBenchmarkRustVsSwift() throws {
        guard ProcessInfo.processInfo.environment["QUOTABAR_CLAUDE_PARSE_BENCH"] == "1" else {
            throw XCTSkip("Enable the Claude parse benchmark explicitly")
        }
        let lineCount = 20_000
        var corpus = Data()
        for _ in 0..<lineCount {
            corpus.append(contentsOf: Data(#"{"timestamp":"2026-02-20T12:00:00.000Z","sessionId":"s","requestId":"req_1","version":"1.0.24","message":{"id":"msg_1","model":"claude-test-model","usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":30,"cache_creation":{"ephemeral_5m_input_tokens":20,"ephemeral_1h_input_tokens":10},"speed":"fast"}}}"#.utf8))
            corpus.append(0x0A)
        }
        let lines = corpus.split(separator: 0x0A, omittingEmptySubsequences: true).map { Data($0) }
        XCTAssertEqual(lines.count, lineCount)

        let rustStats = measure {
            var entries = 0
            for line in lines {
                entries += ClaudeUsageLineRustParser.parse(line)?.entries.count ?? 0
            }
            return entries
        }
        let swiftStats = measure {
            var entries = 0
            for line in lines {
                entries += ClaudeLogUsageScanner.parseEntriesSwiftForTesting(line).entries.count
            }
            return entries
        }
        XCTAssertEqual(rustStats.result, swiftStats.result)

        print(String(
            format: "CLAUDE_PARSE_BENCH lines=%d rustCPU=%.6fs rustWall=%.6fs swiftCPU=%.6fs swiftWall=%.6fs cpuRatio=%.2fx",
            lineCount, rustStats.cpu, rustStats.wall, swiftStats.cpu, swiftStats.wall,
            rustStats.cpu > 0 ? swiftStats.cpu / rustStats.cpu : -1
        ))
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
