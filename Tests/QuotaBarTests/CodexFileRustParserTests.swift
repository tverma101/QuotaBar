import Darwin
import Foundation
import XCTest
@testable import QuotaBar

/// FFI parity tests for the quotabar-core Rust whole-file Codex rollout parser
/// (`qb_codex_parse_file`). The Swift reference implementation
/// (`CodexLogUsageScanner.swiftFileParseForTesting`) is the oracle: for every file the Rust
/// path accepts, its events, checkpoint projection, trailing-fragment carry, and read
/// statistics must match exactly; for the shapes it declines it must answer `.fallback` so
/// production re-runs Swift — never a different answer.
final class CodexFileRustParserTests: XCTestCase {
    private typealias Event = CodexLogUsageScanner.Event

    private func iso(_ offset: TimeInterval, base: TimeInterval = 1_763_172_000) -> String {
        OpenUsageISO8601.string(from: Date(timeIntervalSince1970: base + offset))
    }

    private func epoch(_ offset: TimeInterval, base: TimeInterval = 1_763_172_000) -> TimeInterval {
        base + offset
    }

    /// A diverse rollout: cumulative-total deltas, model context, service tier, session_meta,
    /// the child-session replay gate, rate-limit pings, and noise rows.
    private func rolloutCorpus() -> [String] {
        [
            #"{"type":"session_meta","timestamp":"\#(iso(0))","payload":{"id":"sess-1"}}"#,
            #"{"type":"turn_context","timestamp":"\#(iso(0))","payload":{"model":"gpt-5-codex"}}"#,
            #"{"type":"event_msg","timestamp":"\#(iso(0))","payload":{"type":"agent_message","message":"hello"}}"#,
            #"{"type":"event_msg","timestamp":"\#(iso(1))","payload":{"type":"thread_settings_applied","thread_settings":{"service_tier":"fast"}}}"#,
            #"{"type":"event_msg","timestamp":"\#(iso(2))","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":40,"reasoning_output_tokens":10,"total_tokens":150}}}}"#,
            #"{"type":"event_msg","timestamp":"\#(iso(3))","payload":{"type":"token_count","info":null}}"#,
            #"{"type":"event_msg","timestamp":"\#(iso(4))","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":50,"output_tokens":10}}}}"#,
            #"{"type":"event_msg","timestamp":"\#(iso(5))","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":250,"cached_input_tokens":80,"output_tokens":90,"reasoning_output_tokens":35,"total_tokens":375}}}}"#,
        ]
    }

    // MARK: - File-level parity

    func testRolloutFileMatchesSwiftOracle() throws {
        let url = try writeTempFile(lines: rolloutCorpus())
        defer { try? FileManager.default.removeItem(at: url) }
        try assertParity(at: url, description: "rollout corpus")
        guard case .success(let events, let checkpoint, _) = CodexRolloutRustParser.parseFile(at: url, emitSince: nil) else {
            return XCTFail("Rust declined a clean rollout")
        }
        XCTAssertEqual(events.count, 3)
        XCTAssertTrue(checkpoint.hasPreviousTotals)
        XCTAssertEqual(checkpoint.currentModel, "gpt-5-codex")
        XCTAssertTrue(checkpoint.currentTierIsFast)
        XCTAssertEqual(checkpoint.serviceTier, "fast")
    }

    func testEachLineShapeAgreesIndividually() throws {
        for line in rolloutCorpus() {
            let url = try writeTempFile(lines: [line])
            defer { try? FileManager.default.removeItem(at: url) }
            try assertParity(at: url, description: line)
        }
    }

    func testChildSessionReplayGateCheckpointParity() throws {
        let lines = [
            #"{"type":"session_meta","timestamp":"\#(iso(0))","payload":{"forked_from_id":"parent-abc"}}"#,
            #"{"type":"event_msg","timestamp":"\#(iso(1))","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":900,"output_tokens":300,"total_tokens":1200}}}}"#,
            #"{"type":"event_msg","timestamp":"\#(iso(2))","payload":{"type":"task_started","started_at":\#(epoch(2))}}"#,
            #"{"type":"event_msg","timestamp":"\#(iso(3))","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":950,"output_tokens":320,"total_tokens":1270}}}}"#,
        ]
        let url = try writeTempFile(lines: lines)
        defer { try? FileManager.default.removeItem(at: url) }
        try assertParity(at: url, description: "replay gate rollout")
        guard case .success(_, let checkpoint, _) = CodexRolloutRustParser.parseFile(at: url, emitSince: nil) else {
            return XCTFail("Rust declined the replay-gate rollout")
        }
        // The gate closed at task_started; session state is checkpointed for the next append.
        XCTAssertEqual(checkpoint.replayGateKind, .none)
        XCTAssertTrue(checkpoint.sawSessionMeta)
        XCTAssertTrue(checkpoint.hasPreviousTotals)
    }

    func testSelfTimedReplayGateCheckpointParity() throws {
        // No parseable session_meta timestamp → the gate is self-timed and still open at EOF,
        // so the checkpoint must carry the gate the Swift parser would keep.
        let lines = [
            #"{"type":"session_meta","payload":{"parent_thread_id":"parent-abc"}}"#,
            #"{"type":"event_msg","timestamp":"\#(iso(1))","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":900,"output_tokens":300,"total_tokens":1200}}}}"#,
        ]
        let url = try writeTempFile(lines: lines)
        defer { try? FileManager.default.removeItem(at: url) }
        try assertParity(at: url, description: "self-timed replay gate")
        guard case .success(_, let checkpoint, _) = CodexRolloutRustParser.parseFile(at: url, emitSince: nil) else {
            return XCTFail("Rust declined the self-timed gate rollout")
        }
        XCTAssertEqual(checkpoint.replayGateKind, .untilSelfTimed)
    }

    func testEmitSinceParity() throws {
        let url = try writeTempFile(lines: rolloutCorpus())
        defer { try? FileManager.default.removeItem(at: url) }
        let since = Date(timeIntervalSince1970: epoch(3))
        try assertParity(at: url, emitSince: since, description: "emitSince rollout")
    }

    // MARK: - Trailing fragment

    func testTrailingCompleteJSONIsConsumed() throws {
        // A complete final record without a newline is parsed immediately (the same
        // `consumeCompleteFinalJSONIfPossible` rule the Swift path applies).
        let url = try writeTempFile(lines: rolloutCorpus(), trailingNewline: false)
        defer { try? FileManager.default.removeItem(at: url) }
        try assertParity(at: url, description: "unterminated final record")
        guard case .success(let events, _, let read) = CodexRolloutRustParser.parseFile(at: url, emitSince: nil) else {
            return XCTFail("Rust declined a file whose last record lacks a newline")
        }
        XCTAssertEqual(events.count, 3)
        XCTAssertTrue(read.finalPartial.isEmpty)
    }

    func testTrailingIncompleteFragmentStaysBuffered() throws {
        var body = rolloutCorpus().joined(separator: "\n") + "\n"
        body += #"{"type":"event_msg","timestamp":"2027-01-01T00:00:0"# // half-written tail
        let url = try writeTempBody(body)
        defer { try? FileManager.default.removeItem(at: url) }
        try assertParity(at: url, description: "incomplete tail carry")
        guard case .success(_, _, let read) = CodexRolloutRustParser.parseFile(at: url, emitSince: nil) else {
            return XCTFail("Rust declined a file with a buffered tail")
        }
        XCTAssertEqual(read.finalPartial, Data(#"{"type":"event_msg","timestamp":"2027-01-01T00:00:0"#.utf8))
    }

    func testEmptyFileAgrees() throws {
        let url = try writeTempFile(lines: [])
        defer { try? FileManager.default.removeItem(at: url) }
        try assertParity(at: url, description: "empty file")
        guard case .success(let events, let checkpoint, let read) = CodexRolloutRustParser.parseFile(at: url, emitSince: nil) else {
            return XCTFail("Rust declined an empty file")
        }
        XCTAssertTrue(events.isEmpty)
        XCTAssertFalse(checkpoint.hasPreviousTotals)
        XCTAssertNil(checkpoint.currentModel)
        XCTAssertTrue(read.finalPartial.isEmpty)
    }

    func testMissingFileFailsInBothEngines() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("quotabar-codex-parity-missing-\(UUID().uuidString).jsonl")
        XCTAssertNil(CodexLogUsageScanner.swiftFileParseForTesting(at: url))
        guard case .failed = CodexRolloutRustParser.parseFile(at: url, emitSince: nil) else {
            return XCTFail("Rust parser should report failure for a missing file")
        }
    }

    func testMalformedTokenCountFailsBothEngines() throws {
        let lines = rolloutCorpus() + [
            #"{"type":"event_msg","timestamp":"\#(iso(6))","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":"bad","output_tokens":5}}}}"#,
        ]
        let url = try writeTempFile(lines: lines)
        defer { try? FileManager.default.removeItem(at: url) }
        try assertParity(at: url, description: "malformed token bucket")
        guard case .failed(let malformed) = CodexRolloutRustParser.parseFile(at: url, emitSince: nil) else {
            return XCTFail("Rust should fail a file with a malformed token bucket")
        }
        XCTAssertTrue(malformed)
    }

    // MARK: - Fallback contract

    func testNonCanonicalTimestampDeclinesWholeFile() throws {
        let lines = rolloutCorpus() + [
            #"{"type":"event_msg","timestamp":"2026-11-15 10:00:02","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"output_tokens":5,"total_tokens":15}}}}"#,
        ]
        let url = try writeTempFile(lines: lines)
        defer { try? FileManager.default.removeItem(at: url) }
        guard case .fallback = CodexRolloutRustParser.parseFile(at: url, emitSince: nil) else {
            return XCTFail("Rust must decline the whole file on one declined line")
        }
        // The Swift oracle still parses the file — fallback preserves those events.
        let oracle = try XCTUnwrap(CodexLogUsageScanner.swiftFileParseForTesting(at: url))
        XCTAssertEqual(oracle.events.count, 4)
    }

    func testCompressedArchiveNeverReachesRust() throws {
        // A `.jsonl.zst` archive's raw bytes are compressed — never JSONL — so the bridge must
        // decline without reading, routing the file to Swift's decompressor path.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("quotabar-codex-parity-\(UUID().uuidString).jsonl.zst")
        try Data("not a zstd frame".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        guard case .fallback = CodexRolloutRustParser.parseFile(at: url, emitSince: nil) else {
            return XCTFail("compressed archives must decline to the Swift decompressor path")
        }
    }

    // MARK: - Benchmark

    /// Opt-in benchmark comparing the Rust whole-file path against the Swift reference over a
    /// synthetic rollout. `QUOTABAR_CODEX_FILE_BENCH=1 swift test --filter CodexFileRustParserTests`.
    func testCodexFileBenchmarkRustVsSwift() throws {
        guard ProcessInfo.processInfo.environment["QUOTABAR_CODEX_FILE_BENCH"] == "1" else {
            throw XCTSkip("Enable the Codex file parse benchmark explicitly")
        }
        var lines = [
            #"{"type":"turn_context","timestamp":"\#(iso(0))","payload":{"model":"gpt-5-codex"}}"#,
        ]
        for index in 1...20_000 {
            let input = index * 137
            let output = index * 41
            lines.append(#"{"type":"event_msg","timestamp":"\#(iso(Double(index)))","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(input),"cached_input_tokens":\#(min(input / 3, input)),"output_tokens":\#(output),"reasoning_output_tokens":\#(output / 2),"total_tokens":\#(input + output)}}}}"#)
        }
        let url = try writeTempFile(lines: lines)
        defer { try? FileManager.default.removeItem(at: url) }

        let rustStats = measure {
            guard case .success(let events, _, _) = CodexRolloutRustParser.parseFile(at: url, emitSince: nil) else { return -1 }
            return events.count
        }
        let swiftStats = measure {
            CodexLogUsageScanner.swiftFileParseForTesting(at: url)?.events.count ?? -1
        }
        XCTAssertEqual(rustStats.result, swiftStats.result)

        print(String(
            format: "CODEX_FILE_BENCH rustCPU=%.6fs rustWall=%.6fs swiftCPU=%.6fs swiftWall=%.6fs cpuRatio=%.2fx",
            rustStats.cpu, rustStats.wall, swiftStats.cpu, swiftStats.wall,
            rustStats.cpu > 0 ? swiftStats.cpu / rustStats.cpu : -1
        ))
    }

    // MARK: - Helpers

    private func assertParity(
        at url: URL,
        emitSince: Date? = nil,
        description: String
    ) throws {
        let oracle = CodexLogUsageScanner.swiftFileParseForTesting(at: url, emitSince: emitSince)
        switch CodexRolloutRustParser.parseFile(at: url, emitSince: emitSince) {
        case .success(let events, let checkpoint, let read):
            let oracle = try XCTUnwrap(oracle, "Swift declined a file Rust accepted: \(description)")
            XCTAssertEqual(events, oracle.events, "events mismatch: \(description)")
            XCTAssertEqual(checkpoint, oracle.checkpoint, "checkpoint mismatch: \(description)")
            XCTAssertEqual(read.finalPartial, oracle.partialLine, "partial-line mismatch: \(description)")
            XCTAssertEqual(read.statistics.bytesRead, oracle.bytesRead, "bytesRead mismatch: \(description)")
        case .failed:
            XCTAssertNil(oracle, "Rust failed a file Swift accepted: \(description)")
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
            .appendingPathComponent("quotabar-codex-parity-\(UUID().uuidString).jsonl")
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
