import Foundation
import XCTest
@testable import QuotaBar

/// Counts parsed from provider payloads are untrusted input, and `Int(someDouble)` on an
/// out-of-range value is a *fatal error*, not a nil. One malformed token count in a session log
/// therefore killed the whole menu-bar process (SIGTRAP) mid-refresh — the worst possible failure for a
/// background app, and one that only ever reproduces on real-world data.
///
/// Each case below is a value an agent reproduced as a hard crash. A regression reintroducing the
/// unguarded conversion will not fail an assertion here; it will take the test binary down, which is the
/// point: the suite cannot report green while the app is crashable.
final class HostileNumericInputTests: XCTestCase {
    /// `Double(Int.max)` rounds *up* to 2^63, so a naive `number <= Double(Int.max)` guard admits exactly
    /// 2^63 and the conversion then traps. That off-by-one is why this compares in the clamped domain.
    func testTheIntMaxBoundaryDoesNotTrap() {
        // `Double(Int.max)` is 2^63 exactly, and 2^63 - 1 is *not* representable as a Double — so the
        // largest safely-inside value has to be probed well below the boundary, not at it.
        let justPastMax = 9_223_372_036_854_775_808.0   // == Double(Int.max), i.e. 2^63
        XCTAssertEqual(ProviderParse.intFromClampedDouble(justPastMax), .max)
        let comfortablyInside = 1_000_000_000_000_000_000.0   // 1e18, exact
        XCTAssertEqual(ProviderParse.intFromClampedDouble(comfortablyInside), 1_000_000_000_000_000_000)
    }

    func testExtremeValuesClampInsteadOfTrapping() {
        for value in [1e30, 1e300, Double.greatestFiniteMagnitude] {
            XCTAssertEqual(ProviderParse.intFromClampedDouble(value), .max, "\(value) must saturate")
        }
        XCTAssertEqual(ProviderParse.intFromClampedDouble(-1e30), 0, "a count is never negative")
        XCTAssertEqual(ProviderParse.intFromClampedDouble(.nan), 0, "NaN is not a count")
        XCTAssertEqual(ProviderParse.intFromClampedDouble(3.9), 3, "a count reads as floor")
    }

    /// The documented crash: `input_tokens` at Int.max plus any output overflowed `+`, which traps.
    func testSaturatingAddSurvivesIntMaxPlusOne() {
        XCTAssertEqual(ProviderParse.addingSaturating(.max, 1), .max)
        XCTAssertEqual(ProviderParse.addingSaturating(.max, .max), .max)
        XCTAssertEqual(ProviderParse.addingSaturating(2, 3), 5)
        XCTAssertEqual(ProviderParse.addingSaturating(0, 0), 0)
    }

    /// `ProviderParse.number` is deliberately permissive and only rejects non-finite values, so it will
    /// hand back `1e30`. The bounded reader is what stands between that and a conversion.
    func testPermissiveNumberStillReturnsTheHostileValue() {
        let hostile = 1e30
        XCTAssertEqual(ProviderParse.number(hostile), hostile, "number() is intentionally permissive")
        XCTAssertEqual(ProviderParse.int(hostile), .max, "int() is the bounded boundary")
    }

    // MARK: - End-to-end through the parsers that crashed

    /// Grok's `modelUsage` counts. The only guard was `>= 0`, which bounds the wrong end of the range.
    func testGrokLogLineWithAbsurdCountsDoesNotTrap() throws {
        let line = #"{"type":"event_msg","payload":{"type":"token_count","modelUsage":{"m":{"inputTokens":1e30,"outputTokens":5,"cachedReadTokens":-1e30}}},"timestamp":"2026-09-20T10:00:00.000Z"}"#
        // Surviving the payload is the entire assertion: a trap fails the run rather than an assertion,
        // which is the regression being guarded. Whether the line also happens to yield a row is a
        // separate question and deliberately not claimed here.
        let entries = GrokLogUsageScanner.parseFile(Data(line.utf8))
        for entry in entries {
            XCTAssertGreaterThanOrEqual(entry.tokens.input, 0, "a count must never be negative")
        }
    }

    /// Pi session usage block, six unclamped conversion sites.
    func testPiUsageBlockWithAbsurdCountDoesNotTrap() throws {
        let line = #"{"id":"m1","timestamp":"2026-09-20T10:00:00.000Z","message":{"role":"assistant","provider":"cursor","model":"composer-2.5","usage":{"input":1e30,"output":1e30,"cacheRead":1e30,"cacheWrite":1e30,"cacheWrite1h":1e30,"totalTokens":1e30}}}"#
        if let entry = PiUsageScanner.parseLine(Data(line.utf8)) {
            XCTAssertGreaterThanOrEqual(entry.tokens.input, 0, "a count must never be negative")
        }
    }

    /// Codex session log: `input_tokens` at the boundary plus a non-zero output is the verified SIGTRAP.
    func testCodexLineWithIntMaxInputPlusOutputDoesNotTrap() throws {
        let line = #"{"timestamp":"2026-09-20T10:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":9223372036854775807,"output_tokens":1}}}}"#
        // Parsed for real: `RawUsage.init(json:)` is private, so the only way to exercise the
        // `input + output` recompute is through the file parser. A total is omitted so the recompute is
        // the path taken — that is the arithmetic that overflowed.
        let events = CodexLogUsageScanner.parseFile(Data(line.utf8))
        for event in events {
            XCTAssertGreaterThanOrEqual(event.total, 0, "a count must never go negative")
        }
        _ = CodexLogUsageScanner.Event(
            timestamp: Date(), model: "gpt-5.6-luna", pricingModel: nil,
            input: .max, cached: 0, output: 1, reasoning: 0, total: 0, isFast: false
        )
    }
}
