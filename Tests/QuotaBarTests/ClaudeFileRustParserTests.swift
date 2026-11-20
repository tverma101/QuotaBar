import Darwin
import Foundation
import XCTest
@testable import QuotaBar

/// FFI parity tests for the quotabar-core Rust whole-file Claude session parser
/// (`qb_claude_parse_file`). The Swift reference implementation
/// (`ClaudeLogUsageScanner.parseFileSwift(at:)`) is the oracle: for every file the Rust path
/// accepts, its entries must match exactly; for the shapes it declines it must answer
/// `.fallback` so production re-runs Swift — never a different answer.
final class ClaudeFileRustParserTests: XCTestCase {
    private typealias Entry = ClaudeLogUsageScanner.Entry

    /// Lines the Rust parser accepts; each must produce the same file-level answer as the
    /// Swift oracle (including nil for lines whose malformed flag fails the file).
    private let sharedCorpus: [String] = [
        // Modern line with cache split, fast speed and a cost.
        #"{"timestamp":"2026-02-20T12:00:00.000Z","sessionId":"s","requestId":"req_1","version":"1.0.24","isSidechain":true,"costUSD":0.5,"message":{"id":"msg_1","model":"claude-test-model","usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":30,"cache_creation":{"ephemeral_5m_input_tokens":20,"ephemeral_1h_input_tokens":10},"speed":"fast"}}}"#,
        // Legacy aggregate cache-creation counter.
        #"{"timestamp":"2026-02-20T12:00:00Z","message":{"id":"m","model":"x","usage":{"input_tokens":10,"output_tokens":5,"cache_creation_input_tokens":40,"cache_read_input_tokens":7}}}"#,
        // Advisor iterations — extra entries, mixed model/trimmed whitespace.
        #"{"timestamp":"2026-02-20T12:00:00.000Z","message":{"id":"msg_9","model":"opus","usage":{"input_tokens":10,"output_tokens":5,"iterations":[{"type":"message"},{"type":"advisor_message","model":" advisor-model ","input_tokens":70,"output_tokens":30,"speed":"standard"},{"type":"advisor_message","input_tokens":1,"output_tokens":2}]}}}"#,
        // Non-assistant rows are skipped silently even with the marker present.
        #"{"timestamp":"2026-02-20T12:00:00.000Z","type":"user","message":{"id":"m","usage":{"input_tokens":1,"output_tokens":2}}}"#,
        // Model placeholders and blank models normalize to nil.
        #"{"timestamp":"2026-02-20T12:00:00.000Z","message":{"id":"m","model":"<synthetic>","usage":{"input_tokens":1,"output_tokens":2}}}"#,
        // Noise lines — no `"usage"` marker, never even parsed.
        #"{"noise":true,"foo":[1,2,3]}"#,
        // Malformed candidates — the whole file answers nil in BOTH engines.
        #"{"timestamp":"2026-02-20T12:00:00.000Z","message":{"id":"m","usage":{"input_tokens":1.5,"output_tokens":2}}}"#,
        #"{"timestamp":"2026-13-20T12:00:00Z","message":{"id":"m","usage":{"input_tokens":1,"output_tokens":2}}}"#,
        #"{"usage": not-json"#,
    ]

    /// Lines the Rust fast path deliberately declines — Foundation timestamp shapes. The file
    /// parse must answer `.fallback`; the production scanner then re-parses in Swift.
    private let fallbackCorpus: [String] = [
        #"{"timestamp":"2026-02-20 12:00:00","message":{"id":"m","usage":{"input_tokens":1,"output_tokens":2}}}"#,
        #"{"timestamp":"2026-02-20T12:00:00.123456Z","message":{"id":"m","usage":{"input_tokens":1,"output_tokens":2}}}"#,
        #"{"timestamp":"2026-02-20T12:00:00+00:00","message":{"id":"m","usage":{"input_tokens":1,"output_tokens":2}}}"#,
    ]

    // MARK: - File-level parity

    func testSingleLineFilesMatchSwiftOracle() throws {
        for line in sharedCorpus {
            let url = try writeTempFile(lines: [line])
            defer { try? FileManager.default.removeItem(at: url) }
            try assertParity(at: url, description: line)
        }
    }

    func testMultiLineCleanFileParity() throws {
        // The well-formed subset — entries accumulate across the file.
        let lines = [
            #"{"noise":true}"#,
            #"{"timestamp":"2026-02-20T12:00:00.000Z","sessionId":"s","requestId":"req_1","message":{"id":"msg_1","model":"claude-test-model","usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":30}}}"#,
            #"{"timestamp":"2026-02-20T12:00:01Z","message":{"id":"msg_2","model":"x","usage":{"input_tokens":10,"output_tokens":5,"cache_creation_input_tokens":40}}}"#,
            #"{"timestamp":"2026-02-20T12:00:02.500Z","message":{"id":"msg_3","usage":{"input_tokens":7,"output_tokens":3,"iterations":[{"type":"advisor_message","model":"adv","input_tokens":2,"output_tokens":1}]}}}"#,
        ]
        let url = try writeTempFile(lines: lines)
        defer { try? FileManager.default.removeItem(at: url) }
        try assertParity(at: url, description: "multi-line file")
        // Rust must actually accept this file (otherwise the parity check was vacuous).
        guard case .success = ClaudeFileRustParser.parseFile(at: url) else {
            return XCTFail("Rust declined a clean file")
        }
    }

    func testMalformedRowFailsBothEngines() throws {
        let lines = [
            #"{"timestamp":"2026-02-20T12:00:00.000Z","message":{"id":"m1","usage":{"input_tokens":1,"output_tokens":2}}}"#,
            #"{"timestamp":"2026-02-20T12:00:01.000Z","message":{"id":"m2","usage":{"input_tokens":"bad","output_tokens":2}}}"#,
            #"{"timestamp":"2026-02-20T12:00:02.000Z","message":{"id":"m3","usage":{"input_tokens":3,"output_tokens":4}}}"#,
        ]
        let url = try writeTempFile(lines: lines)
        defer { try? FileManager.default.removeItem(at: url) }
        try assertParity(at: url, description: "file with a malformed row")
        guard case .failed = ClaudeFileRustParser.parseFile(at: url) else {
            return XCTFail("Rust should report failure for a malformed usage row")
        }
    }

    func testTrailingUnterminatedLineIsParsed() throws {
        // Claude's append cache hands the trailing newline-less fragment to the same per-line
        // parser (provisional rows), so the file result includes it.
        let lines = [
            #"{"timestamp":"2026-02-20T12:00:00.000Z","message":{"id":"m1","usage":{"input_tokens":1,"output_tokens":2}}}"#,
            #"{"timestamp":"2026-02-20T12:00:01.000Z","message":{"id":"m2","usage":{"input_tokens":3,"output_tokens":4}}}"#,
        ]
        let url = try writeTempFile(lines: lines, trailingNewline: false)
        defer { try? FileManager.default.removeItem(at: url) }
        try assertParity(at: url, description: "unterminated final line")
        guard case .success(let entries, _) = ClaudeFileRustParser.parseFile(at: url) else {
            return XCTFail("Rust should accept an unterminated final line")
        }
        XCTAssertEqual(entries.count, 2)
    }

    func testTrailingMalformedFragmentFailsBothEngines() throws {
        let body = #"{"timestamp":"2026-02-20T12:00:00.000Z","message":{"id":"m1","usage":{"input_tokens":1,"output_tokens":2}}}"# + "\n"
            + #"{"timestamp":"2026-02-20T12:00:01.000Z","message":{"id":"m2","usage":{"input_tokens":"bad","#
        let url = try writeTempBody(body)
        defer { try? FileManager.default.removeItem(at: url) }
        try assertParity(at: url, description: "malformed trailing fragment")
        guard case .failed = ClaudeFileRustParser.parseFile(at: url) else {
            return XCTFail("a malformed trailing fragment must fail the file")
        }
    }

    func testEmptyFileAgrees() throws {
        let url = try writeTempFile(lines: [])
        defer { try? FileManager.default.removeItem(at: url) }
        try assertParity(at: url, description: "empty file")
        guard case .success(let entries, _) = ClaudeFileRustParser.parseFile(at: url) else {
            return XCTFail("Rust should accept an empty file")
        }
        XCTAssertTrue(entries.isEmpty)
    }

    func testMissingFileFailsInBothEngines() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("quotabar-claude-parity-missing-\(UUID().uuidString).jsonl")
        XCTAssertNil(ClaudeLogUsageScanner.parseFileSwift(at: url))
        guard case .failed = ClaudeFileRustParser.parseFile(at: url) else {
            return XCTFail("Rust parser should report failure for a missing file")
        }
    }

    // MARK: - Fallback contract

    func testFallbackCorpusDeclinesWholeFile() throws {
        for line in fallbackCorpus {
            let url = try writeTempFile(lines: [line])
            defer { try? FileManager.default.removeItem(at: url) }
            guard case .fallback = ClaudeFileRustParser.parseFile(at: url) else {
                XCTFail("Rust parser should decline non-canonical timestamp: \(line)")
                continue
            }
            // The Swift oracle still parses the line — fallback preserves those entries.
            XCTAssertNotNil(
                ClaudeLogUsageScanner.parseFileSwift(at: url),
                "Swift oracle should parse: \(line)"
            )
        }
    }

    func testFallbackMidFileDeclinesEverything() throws {
        // A declined line anywhere in the file must discard the whole Rust result — entries
        // must never come from a mix of engines.
        let lines = [
            #"{"timestamp":"2026-02-20T12:00:00.000Z","message":{"id":"m1","usage":{"input_tokens":1,"output_tokens":2}}}"#,
            #"{"timestamp":"2026-02-20 12:00:01","message":{"id":"m2","usage":{"input_tokens":3,"output_tokens":4}}}"#,
        ]
        let url = try writeTempFile(lines: lines)
        defer { try? FileManager.default.removeItem(at: url) }
        guard case .fallback = ClaudeFileRustParser.parseFile(at: url) else {
            return XCTFail("Rust must decline the whole file on a single declined line")
        }
        // …but the production dispatch still answers, via the Swift re-parse.
        let oracle = try XCTUnwrap(ClaudeLogUsageScanner.parseFileSwift(at: url))
        XCTAssertEqual(ClaudeLogUsageScanner.parseFile(at: url), oracle)
        XCTAssertEqual(oracle.count, 2)
    }

    func testProductionDispatchMatchesSwiftOracle() throws {
        // The contract the production scanner relies on: `parseFile(at:)` — Rust first,
        // Swift on fallback — equals the Swift-only reference for every shape.
        for line in sharedCorpus + fallbackCorpus {
            let url = try writeTempFile(lines: [line])
            defer { try? FileManager.default.removeItem(at: url) }
            let oracle = ClaudeLogUsageScanner.parseFileSwift(at: url)
            XCTAssertEqual(
                ClaudeLogUsageScanner.parseFile(at: url), oracle,
                "dispatch mismatch for: \(line)"
            )
        }
    }

    // MARK: - Benchmark

    /// Opt-in benchmark comparing the Rust whole-file path against the Swift reference over a
    /// synthetic session file. `QUOTABAR_CLAUDE_FILE_BENCH=1 swift test --filter ClaudeFileRustParserTests`.
    /// The Swift side reads the file and runs the Swift-only per-line reference over each line
    /// (the marker-gate + JSONSerialization path the Rust engine replaces).
    func testClaudeFileBenchmarkRustVsSwift() throws {
        guard ProcessInfo.processInfo.environment["QUOTABAR_CLAUDE_FILE_BENCH"] == "1" else {
            throw XCTSkip("Enable the Claude file parse benchmark explicitly")
        }
        var lines: [String] = []
        for index in 0..<20_000 {
            if index.isMultiple(of: 5) {
                lines.append(#"{"noise":true}"#)
            } else {
                lines.append(#"{"timestamp":"2026-02-20T12:00:00.000Z","sessionId":"s","requestId":"req_\#(index)","version":"1.0.24","message":{"id":"msg_\#(index)","model":"claude-test-model","usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":30,"cache_creation":{"ephemeral_5m_input_tokens":20,"ephemeral_1h_input_tokens":10},"speed":"fast"}}}"#)
            }
        }
        let url = try writeTempFile(lines: lines)
        defer { try? FileManager.default.removeItem(at: url) }
        let marker = Data(#""usage""#.utf8)

        let rustStats = measure {
            guard case .success(let entries, _) = ClaudeFileRustParser.parseFile(at: url) else { return -1 }
            return entries.count
        }
        let swiftStats = measure {
            guard let data = try? Data(contentsOf: url) else { return -1 }
            var count = 0
            for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
                guard line.range(of: marker) != nil else { continue }
                autoreleasepool {
                    count += ClaudeLogUsageScanner.parseEntriesSwiftForTesting(Data(line)).entries.count
                }
            }
            return count
        }
        XCTAssertEqual(rustStats.result, swiftStats.result)

        print(String(
            format: "CLAUDE_FILE_BENCH rustCPU=%.6fs rustWall=%.6fs swiftCPU=%.6fs swiftWall=%.6fs cpuRatio=%.2fx",
            rustStats.cpu, rustStats.wall, swiftStats.cpu, swiftStats.wall,
            rustStats.cpu > 0 ? swiftStats.cpu / rustStats.cpu : -1
        ))
    }

    // MARK: - Helpers

    private func assertParity(at url: URL, description: String) throws {
        let swift = ClaudeLogUsageScanner.parseFileSwift(at: url)
        switch ClaudeFileRustParser.parseFile(at: url) {
        case .success(let entries, let malformed):
            XCTAssertFalse(malformed, "malformed flag on a successful file: \(description)")
            let oracle = try XCTUnwrap(swift, "Swift declined a file Rust accepted: \(description)")
            XCTAssertEqual(entries, oracle, "entry mismatch: \(description)")
        case .failed:
            XCTAssertNil(swift, "Rust failed a file Swift accepted: \(description)")
        case .fallback:
            break // Swift owns the answer for declined shapes
        }
    }

    private func writeTempFile(lines: [String], trailingNewline: Bool = true) throws -> URL {
        var body = lines.joined(separator: "\n")
        if trailingNewline, !body.isEmpty { body.append("\n") }
        return try writeTempBody(body)
    }

    private func writeTempBody(_ body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("quotabar-claude-parity-\(UUID().uuidString).jsonl")
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
