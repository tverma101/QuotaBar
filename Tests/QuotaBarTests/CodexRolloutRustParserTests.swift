import Darwin
import Foundation
import XCTest
@testable import QuotaBar

/// FFI parity tests for the quotabar-core Rust Codex rollout line parser (stage 2). The Swift
/// reference parser (`CodexLogUsageScanner.FileParser`) is the oracle: whenever Rust consumes a
/// line it must produce the identical event stream and malformed flag. The test corpus exercises
/// cumulative-total deltas, last-token-usage baselines, the child-session replay gate, tier flags,
/// and the auto-review pricing slug.
final class CodexRolloutRustParserTests: XCTestCase {
    private typealias Event = CodexLogUsageScanner.Event

    private func iso(_ offset: TimeInterval, base: TimeInterval = 1_763_172_000) -> String {
        OpenUsageISO8601.string(from: Date(timeIntervalSince1970: base + offset))
    }

    private func epoch(_ offset: TimeInterval, base: TimeInterval = 1_763_172_000) -> TimeInterval {
        base + offset
    }

    private func feedRust(_ data: Data, emitSince: Date?) -> (events: [Event], malformed: Bool, declined: Bool) {
        guard let parser = CodexRolloutRustParser.Handle(emitSince: emitSince) else {
            return ([], false, true)
        }
        var declined = false
        for line in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            let bytes = line.withUnsafeBytes { buffer in
                Array(buffer)
            }
            if !parser.consume(Data(bytes)[...]) { declined = true }
        }
        guard !declined, let events = parser.finish() else {
            return ([], parser.hasMalformedUsage, true)
        }
        return (events, parser.hasMalformedUsage, false)
    }

    private func assertParity(
        _ lines: [String],
        emitSince: Date? = nil,
        fileID: StaticString = #fileID,
        lineID: UInt = #line
    ) {
        let raw = lines.joined(separator: "\n")
        let data = Data(raw.utf8)
        let oracle = CodexLogUsageScanner.parseFileForTesting(data, emitSince: emitSince)
        let rust = feedRust(data, emitSince: emitSince)
        XCTAssertFalse(rust.declined, "Rust parser declined input it should handle", file: fileID, line: lineID)
        XCTAssertEqual(rust.malformed, oracle.malformed, "malformed flag mismatch for:\n\(raw)", file: fileID, line: lineID)
        XCTAssertEqual(rust.events, oracle.events, "events mismatch for:\n\(raw)", file: fileID, line: lineID)
    }

    // MARK: - Event stream parity

    func testBasicTokenCountDeltaComputation() {
        assertParity([
            #"{"type":"event_msg","timestamp":"\#(iso(0))","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":40,"reasoning_output_tokens":10,"total_tokens":150}}}}"#,
            #"{"type":"event_msg","timestamp":"\#(iso(1))","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":250,"cached_input_tokens":80,"output_tokens":90,"reasoning_output_tokens":35,"total_tokens":375}}}}"#,
        ])
    }

    func testLastTokenUsageBaselineWithoutTotals() {
        assertParity([
            #"{"type":"event_msg","timestamp":"\#(iso(0))","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"output_tokens":20}}}}"#,
            #"{"type":"event_msg","timestamp":"\#(iso(1))","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":50,"output_tokens":10}}}}"#,
        ])
    }

    func testChildSessionReplayGateSwallowsPreGateTokens() {
        assertParity([
            #"{"type":"session_meta","timestamp":"\#(iso(0))","payload":{"forked_from_id":"parent-abc"}}"#,
            #"{"type":"event_msg","timestamp":"\#(iso(1))","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":900,"output_tokens":300,"total_tokens":1200}}}}"#,
            #"{"type":"event_msg","timestamp":"\#(iso(2))","payload":{"type":"task_started","started_at":\#(epoch(2))}}"#,
            #"{"type":"event_msg","timestamp":"\#(iso(3))","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":950,"output_tokens":320,"total_tokens":1270}}}}"#,
        ])
    }

    func testChildSessionGateWithSelfTimedStart() {
        // No machine-parseable session_meta timestamp (missing), so the gate is self-timed:
        // it clears when started_at is >= the timestamp of that same task_started line.
        assertParity([
            #"{"type":"session_meta","payload":{"parent_thread_id":"parent-abc"}}"#,
            #"{"type":"event_msg","timestamp":"\#(iso(1))","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":900,"output_tokens":300,"total_tokens":1200}}}}"#,
            #"{"type":"event_msg","timestamp":"\#(iso(2))","payload":{"type":"task_started","started_at":\#(epoch(2))}}"#,
            #"{"type":"event_msg","timestamp":"\#(iso(3))","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":950,"output_tokens":320,"total_tokens":1270}}}}"#,
        ])
    }

    func testTurnContextCarriesModelAcrossTokenCounts() {
        assertParity([
            #"{"type":"turn_context","timestamp":"\#(iso(0))","payload":{"model":"gpt-5-codex"}}"#,
            #"{"type":"event_msg","timestamp":"\#(iso(1))","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"output_tokens":5,"total_tokens":15}}}}"#,
        ])
    }

    func testTurnContextInvalidModelMarksMalformedAndResets() {
        assertParity([
            #"{"type":"turn_context","timestamp":"\#(iso(0))","payload":{"model":42}}"#,
            #"{"type":"event_msg","timestamp":"\#(iso(1))","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"output_tokens":5,"total_tokens":15}}}}"#,
        ])
    }

    func testThreadSettingsAppliedFastTier() {
        assertParity([
            #"{"type":"event_msg","timestamp":"\#(iso(0))","payload":{"type":"thread_settings_applied","thread_settings":{"service_tier":"fast"}}}"#,
            #"{"type":"event_msg","timestamp":"\#(iso(1))","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"output_tokens":5,"total_tokens":15}}}}"#,
        ])
    }

    func testThreadSettingsAppliedUnknownTierDropsCostCompleteness() {
        assertParity([
            #"{"type":"event_msg","timestamp":"\#(iso(0))","payload":{"type":"thread_settings_applied","thread_settings":{"service_tier":"turbo"}}}"#,
            #"{"type":"event_msg","timestamp":"\#(iso(1))","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"output_tokens":5,"total_tokens":15}}}}"#,
        ])
    }

    func testAutoReviewModelPricesViaDatedFallback() {
        let line = #"{"type":"turn_context","timestamp":"\#(iso(0))","payload":{"model":"codex-auto-review"}}"#
        let usage = #"{"type":"event_msg","timestamp":"\#(iso(1))","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"output_tokens":5,"total_tokens":15}}}}"#
        assertParity([line, usage])

        // The fallback must match what Swift itself computes, not a hardcoded slug.
        let swift = CodexLogUsageScanner.parseFileForTesting(Data([line, usage].joined(separator: "\n").utf8), emitSince: nil)
        XCTAssertEqual(swift.events.first?.pricingModel, CodexLogUsageScanner.autoReviewFallback(at: iso(1)))
    }

    func testMalformedTokenCountVariants() {
        assertParity([// Missing info.
            #"{"type":"event_msg","timestamp":"\#(iso(0))","payload":{"type":"token_count"}}"#])
        assertParity([// Garbage JSON carrying the token_count marker.
            #"{"type":"event_msg", "broken": true, "payload":{"type":"token_count"}"#])
        assertParity([// Non-numeric token bucket.
            #"{"type":"event_msg","timestamp":"\#(iso(0))","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":"10","output_tokens":5}}}}"#])
        assertParity([// Absent timestamp.
            #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"output_tokens":5}}}}"#])
    }

    func testInterleavedNoiseLinesAreIgnored() {
        assertParity([
            #"{"type":"event_msg","timestamp":"\#(iso(0))","payload":{"type":"agent_message","message":"hello"}}"#,
            #"{"type":"event_msg","timestamp":"\#(iso(1))","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"output_tokens":20,"total_tokens":120}}}}"#,
            #"{"type":"event_msg","timestamp":"\#(iso(2))","payload":{"type":"quotas","primary_tokens_left":1000}}"#,
        ])
    }

    func testEmitSinceDropsOldEvents() {
        let since = Date(timeIntervalSince1970: epoch(2))
        assertParity([
            #"{"type":"event_msg","timestamp":"\#(iso(0))","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"output_tokens":20,"total_tokens":120}}}}"#,
            #"{"type":"event_msg","timestamp":"\#(iso(3))","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":150,"output_tokens":40,"total_tokens":190}}}}"#,
        ], emitSince: since)
    }

    // MARK: - Fallback contract

    func testNonCanonicalTimestampDeclinesFile() {
        // Space-separated timestamp: Foundation parses it, the Rust fast path cannot; it must
        // decline the whole file (the scanner then re-parses with Swift).
        let line = #"{"type":"event_msg","timestamp":"2026-11-15 10:00:02","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"output_tokens":5,"total_tokens":15}}}}"#
        guard let parser = CodexRolloutRustParser.Handle(emitSince: nil) else {
            return XCTFail("could not create Rust parser")
        }
        let accepted = parser.consume(Data(line.utf8)[...])
        XCTAssertFalse(accepted)
    }

    func testSessionMetaNonCanonicalTimestampDeclinesFile() {
        let line = #"{"type":"session_meta","timestamp":"2026-11-15 10:00:00","payload":{"forked_from_id":"parent-abc"}}"#
        guard let parser = CodexRolloutRustParser.Handle(emitSince: nil) else {
            return XCTFail("could not create Rust parser")
        }
        XCTAssertFalse(parser.consume(Data(line.utf8)[...]))
    }

    // MARK: - Benchmark

    /// Opt-in benchmark comparing the Rust FFI path against the Swift reference parser over a
    /// synthetic rollout. Enable with `QUOTABAR_CODEX_PARSE_BENCH=1 swift test --filter CodexRolloutRustParserTests`.
    func testCodexParseBenchmarkRustVsSwift() throws {
        guard ProcessInfo.processInfo.environment["QUOTABAR_CODEX_PARSE_BENCH"] == "1" else {
            throw XCTSkip("Enable the Codex parse benchmark explicitly")
        }
        let lineCount = 20_000
        var corpus = Data()
        corpus.append(Data(#"{"type":"turn_context","timestamp":"\#(iso(0))","payload":{"model":"gpt-5-codex"}}"#
            .appending("\n").utf8))
        for index in 1...lineCount {
            // Roughly cumulative counters with jittered component splits.
            let input = index * 137
            let output = index * 41
            let cached = min(input / 3, input)
            let line = #"{"type":"event_msg","timestamp":"\#(iso(Double(index)))","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"output_tokens":\#(output),"reasoning_output_tokens":\#(output / 2),"total_tokens":\#(input + output)}}}}"# + "\n"
            corpus.append(Data(line.utf8))
        }

        let rustStats = measure {
            let handle = CodexRolloutRustParser.Handle(emitSince: nil)!
            for line in corpus.split(separator: 0x0A, omittingEmptySubsequences: true) {
                let bytes = line.withUnsafeBytes { Array($0) }
                _ = handle.consume(Data(bytes)[...])
            }
            return handle.finish()?.count ?? -1
        }
        let swiftStats = measure {
            CodexLogUsageScanner.parseFileForTesting(corpus, emitSince: nil).events.count
        }
        XCTAssertEqual(rustStats.result, swiftStats.result)

        print(String(
            format: "CODEX_PARSE_BENCH lines=%d rustCPU=%.6fs rustWall=%.6fs swiftCPU=%.6fs swiftWall=%.6fs cpuRatio=%.2fx",
            lineCount + 1, rustStats.cpu, rustStats.wall, swiftStats.cpu, swiftStats.wall,
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
