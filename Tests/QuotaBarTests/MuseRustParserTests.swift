import Darwin
import Foundation
import XCTest
@testable import QuotaBar

/// FFI parity tests for the quotabar-core Rust Muse session parser. The Swift reference
/// implementation (`MuseUsageScanner.parseFileSwift(at:)`) is the oracle: for every file the
/// Rust whole-file path accepts, its entries must match exactly; for the shapes it declines it
/// must return `.fallback` so production re-runs Swift — never a different answer.
final class MuseRustParserTests: XCTestCase {
    private typealias Entry = MuseUsageScanner.Entry

    /// Lines the Rust parser accepts; the whole-file result must agree with the Swift oracle.
    private let sharedCorpus: [String] = [
        // Canonical reported token attribution — record.model wins over quantity.model.
        MuseLogFixture.attribution(
            input: 100, cached: 30, output: 50, reasoning: 10,
            recordModel: "muse-spark-1.2-contributor", quantityModel: "ignored-model"
        ),
        // quantity.model is used when record.model is absent…
        MuseLogFixture.attribution(input: 10, output: 5, quantityModel: "muse-spark-1.1"),
        // …or blank — record.model trims away first.
        MuseLogFixture.attribution(
            input: 10, output: 5, recordModel: "   ", quantityModel: "muse-spark-9"
        ),
        // Neither model present → the bridged default.
        MuseLogFixture.attribution(input: 10, output: 5),
        // recorded_at is MICROseconds — this one lands on 2026-02-20T12:00:00.123456Z.
        MuseLogFixture.attribution(recordedAt: 1_771_588_800_123_456, input: 7, output: 3),
        // Cache invariant at the boundary (cached == input).
        MuseLogFixture.attribution(input: 10, cached: 10, output: 5),

        // Irrelevant verdicts — marker absent entirely.
        #"{"noise":true}"#,
        #"not json at all"#,
        #"{"payload":{"event":{"kind":"other"}}}"#,
        // Marker bytes present (via an unrelated field) but the decoded kind differs.
        #"{"recorded_at":1771588800123456,"payload":{"event":{"kind":"goal_progress","note":"goal_usage_attribution"}}}"#,
        // Every failure in the payload→event→kind trio is irrelevant, not malformed.
        #"{"payload":"goal_usage_attribution"}"#,
        #"{"payload":{"event":"goal_usage_attribution"}}"#,
        #"{"payload":{"event":{"kind_x":"goal_usage_attribution"}}}"#,
        #"{"payload":{"event":{"kind":7,"note":"goal_usage_attribution"}}}"#,
        // reported:false and unit!=tokens are skipped rows, not errors.
        MuseLogFixture.attribution(reported: false, input: 100, output: 50),
        MuseLogFixture.attribution(unit: "requests", input: 100, output: 50),
        // Zero-token attributions are bookkeeping placeholders.
        MuseLogFixture.attribution(input: 0, output: 0),

        // Malformed verdicts — the marker is there but the record cannot stand.
        #"{"goal_usage_attribution" broken"#,
        #"["goal_usage_attribution"]"#,
        // Missing/non-dict record or quantity.
        #"{"recorded_at":1771588800123456,"payload":{"event":{"kind":"goal_usage_attribution"}}}"#,
        #"{"recorded_at":1771588800123456,"payload":{"event":{"kind":"goal_usage_attribution","record":[]}}}"#,
        #"{"recorded_at":1771588800123456,"payload":{"event":{"kind":"goal_usage_attribution","record":{}}}}"#,
        #"{"recorded_at":1771588800123456,"payload":{"event":{"kind":"goal_usage_attribution","record":{"quantity":7}}}}"#,
        // `reported` must be a real JSON bool — `1` and `"true"` fail like Swift's CFBoolean check.
        #"{"recorded_at":1771588800123456,"payload":{"event":{"kind":"goal_usage_attribution","record":{"quantity":{"reported":1,"unit":"tokens","input_tokens":1,"output_tokens":1}}}}}"#,
        #"{"recorded_at":1771588800123456,"payload":{"event":{"kind":"goal_usage_attribution","record":{"quantity":{"reported":"true","unit":"tokens","input_tokens":1,"output_tokens":1}}}}}"#,
        #"{"recorded_at":1771588800123456,"payload":{"event":{"kind":"goal_usage_attribution","record":{"quantity":{"reported":null,"unit":"tokens","input_tokens":1,"output_tokens":1}}}}}"#,
        // Missing unit.
        #"{"recorded_at":1771588800123456,"payload":{"event":{"kind":"goal_usage_attribution","record":{"quantity":{"reported":true,"input_tokens":1,"output_tokens":1}}}}}"#,
        // recorded_at: missing, zero, negative, fractional, string, bool, null, over the 9e15 cap.
        #"{"payload":{"event":{"kind":"goal_usage_attribution","record":{"quantity":{"reported":true,"unit":"tokens","input_tokens":1,"output_tokens":1}}}}}"#,
        MuseLogFixture.attribution(recordedAt: 0, input: 1, output: 1),
        MuseLogFixture.attribution(recordedAt: -5, input: 1, output: 1),
        #"{"recorded_at":1771588800.5,"payload":{"event":{"kind":"goal_usage_attribution","record":{"quantity":{"reported":true,"unit":"tokens","input_tokens":1,"output_tokens":1}}}}}"#,
        #"{"recorded_at":"1771588800123456","payload":{"event":{"kind":"goal_usage_attribution","record":{"quantity":{"reported":true,"unit":"tokens","input_tokens":1,"output_tokens":1}}}}}"#,
        #"{"recorded_at":true,"payload":{"event":{"kind":"goal_usage_attribution","record":{"quantity":{"reported":true,"unit":"tokens","input_tokens":1,"output_tokens":1}}}}}"#,
        #"{"recorded_at":null,"payload":{"event":{"kind":"goal_usage_attribution","record":{"quantity":{"reported":true,"unit":"tokens","input_tokens":1,"output_tokens":1}}}}}"#,
        #"{"recorded_at":9000000000000001,"payload":{"event":{"kind":"goal_usage_attribution","record":{"quantity":{"reported":true,"unit":"tokens","input_tokens":1,"output_tokens":1}}}}}"#,
        // cached > input is malformed.
        MuseLogFixture.attribution(input: 10, cached: 11, output: 5),
        // A present JSON null is malformed even for the optional counts (NSNull fails `as? NSNumber`).
        #"{"recorded_at":1771588800123456,"payload":{"event":{"kind":"goal_usage_attribution","record":{"quantity":{"reported":true,"unit":"tokens","input_tokens":1,"output_tokens":1,"cached_tokens":null}}}}}"#,
        #"{"recorded_at":1771588800123456,"payload":{"event":{"kind":"goal_usage_attribution","record":{"quantity":{"reported":true,"unit":"tokens","input_tokens":1,"output_tokens":1,"reasoning_tokens":null}}}}}"#,
        // Missing required counts, and the usual non-number shapes.
        #"{"recorded_at":1771588800123456,"payload":{"event":{"kind":"goal_usage_attribution","record":{"quantity":{"reported":true,"unit":"tokens","output_tokens":1}}}}}"#,
        #"{"recorded_at":1771588800123456,"payload":{"event":{"kind":"goal_usage_attribution","record":{"quantity":{"reported":true,"unit":"tokens","input_tokens":1}}}}}"#,
        #"{"recorded_at":1771588800123456,"payload":{"event":{"kind":"goal_usage_attribution","record":{"quantity":{"reported":true,"unit":"tokens","input_tokens":true,"output_tokens":1}}}}}"#,
        #"{"recorded_at":1771588800123456,"payload":{"event":{"kind":"goal_usage_attribution","record":{"quantity":{"reported":true,"unit":"tokens","input_tokens":1.5,"output_tokens":1}}}}}"#,
        #"{"recorded_at":1771588800123456,"payload":{"event":{"kind":"goal_usage_attribution","record":{"quantity":{"reported":true,"unit":"tokens","input_tokens":-1,"output_tokens":1}}}}}"#,
        #"{"recorded_at":1771588800123456,"payload":{"event":{"kind":"goal_usage_attribution","record":{"quantity":{"reported":true,"unit":"tokens","input_tokens":1000000000000001,"output_tokens":1}}}}}"#,
        #"{"recorded_at":1771588800123456,"payload":{"event":{"kind":"goal_usage_attribution","record":{"quantity":{"reported":true,"unit":"tokens","input_tokens":"5","output_tokens":1}}}}}"#,
        // Present non-string models (NSNull included) are malformed at either site.
        #"{"recorded_at":1771588800123456,"payload":{"event":{"kind":"goal_usage_attribution","record":{"model":5,"quantity":{"reported":true,"unit":"tokens","input_tokens":1,"output_tokens":1}}}}}"#,
        #"{"recorded_at":1771588800123456,"payload":{"event":{"kind":"goal_usage_attribution","record":{"model":null,"quantity":{"reported":true,"unit":"tokens","input_tokens":1,"output_tokens":1}}}}}"#,
        #"{"recorded_at":1771588800123456,"payload":{"event":{"kind":"goal_usage_attribution","record":{"quantity":{"reported":true,"unit":"tokens","input_tokens":1,"output_tokens":1,"model":{}}}}}}"#,
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
            MuseLogFixture.attribution(input: 5, output: 2),
            MuseLogFixture.attribution(input: 10, cached: 11, output: 1),
        ]
        let url = try writeTempFile(lines: lines)
        defer { try? FileManager.default.removeItem(at: url) }
        // The malformed last line fails the whole file in BOTH engines.
        try assertParity(at: url, description: "mixed file")
    }

    func testTrailingPartialLineIsDelivered() throws {
        let line = MuseLogFixture.attribution(input: 5, output: 2)
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
            .appendingPathComponent("quotabar-muse-parity-missing-\(UUID().uuidString).jsonl")
        XCTAssertNil(MuseUsageScanner.parseFileSwift(at: url))
        guard case .failed = MuseRustParser.parseFile(at: url) else {
            XCTFail("Rust parser should report failure for a missing file")
            return
        }
    }

    // MARK: - Per-line surface

    func testPerLineSurfaceMatchesFileSurface() throws {
        for line in sharedCorpus {
            let url = try writeTempFile(lines: [line])
            defer { try? FileManager.default.removeItem(at: url) }
            let fileOutcome = MuseRustParser.parseFile(at: url)
            guard case .success(let fileEntries) = fileOutcome else {
                continue // failed/fallback files are covered by their own tests
            }
            guard let rust = MuseRustParser.parseLine(Data(line.utf8)) else {
                XCTFail("per-line declined where file accepted: \(line)")
                continue
            }
            switch rust {
            case .entry(let entry):
                XCTAssertEqual([entry], fileEntries, "line/file mismatch: \(line)")
            case .irrelevant:
                XCTAssertTrue(fileEntries.isEmpty, "irrelevant line produced entries: \(line)")
            case .malformed:
                XCTFail("malformed line cannot produce a successful file: \(line)")
            }
        }
    }

    /// `recorded_at` is microseconds — sanity-check the decoded timestamp on one line.
    func testMicrosecondTimestampDecodes() throws {
        let line = MuseLogFixture.attribution(recordedAt: 1_771_588_800_123_456, input: 7, output: 3)
        let url = try writeTempFile(lines: [line])
        defer { try? FileManager.default.removeItem(at: url) }
        guard case .success(let entries) = MuseRustParser.parseFile(at: url) else {
            XCTFail("Rust parser declined a canonical attribution line")
            return
        }
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].timestamp.timeIntervalSince1970, 1_771_588_800.123_456, accuracy: 1e-9)
        XCTAssertEqual(entries[0].tokens.input, 7)
        XCTAssertEqual(entries[0].tokens.output, 3)
        XCTAssertEqual(entries[0].model, "muse-spark-1.2-contributor")
    }

    // MARK: - Benchmark

    /// Opt-in benchmark comparing the Rust whole-file path against the Swift reference over a
    /// synthetic corpus. `QUOTABAR_MUSE_PARSE_BENCH=1 swift test --filter MuseRustParserTests`.
    func testMuseParseBenchmarkRustVsSwift() throws {
        guard ProcessInfo.processInfo.environment["QUOTABAR_MUSE_PARSE_BENCH"] == "1" else {
            throw XCTSkip("Enable the Muse parse benchmark explicitly")
        }
        var lines: [String] = []
        for index in 0..<20_000 {
            if index.isMultiple(of: 4) {
                lines.append(#"{"noise":{"kind":"notification"}}"#)
            } else {
                lines.append(MuseLogFixture.attribution(
                    recordedAt: 1_771_588_800_000_000 + index,
                    input: 100, cached: 30, output: 50, reasoning: 10,
                    recordModel: "muse-spark-1.2-contributor"
                ))
            }
        }
        let url = try writeTempFile(lines: lines)
        defer { try? FileManager.default.removeItem(at: url) }

        let rustStats = measure {
            guard case .success(let entries) = MuseRustParser.parseFile(at: url) else { return -1 }
            return entries.count
        }
        let swiftStats = measure {
            MuseUsageScanner.parseFileSwift(at: url)?.count ?? -1
        }
        XCTAssertEqual(rustStats.result, swiftStats.result)

        print(String(
            format: "MUSE_PARSE_BENCH rustCPU=%.6fs rustWall=%.6fs swiftCPU=%.6fs swiftWall=%.6fs cpuRatio=%.2fx",
            rustStats.cpu, rustStats.wall, swiftStats.cpu, swiftStats.wall,
            rustStats.cpu > 0 ? swiftStats.cpu / rustStats.cpu : -1
        ))
    }

    // MARK: - Helpers

    private func assertParity(at url: URL, description: String) throws {
        let swift = MuseUsageScanner.parseFileSwift(at: url)
        switch MuseRustParser.parseFile(at: url) {
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
            .appendingPathComponent("quotabar-muse-parity-\(UUID().uuidString).jsonl")
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

/// One `goal_usage_attribution` line in Muse's `session.jsonl` envelope shape.
private enum MuseLogFixture {
    static func attribution(
        recordedAt: Int = 1_771_588_800_123_456,
        reported: Bool = true,
        unit: String = "tokens",
        input: Int,
        cached: Int? = nil,
        output: Int,
        reasoning: Int? = nil,
        recordModel: String? = nil,
        quantityModel: String? = nil
    ) -> String {
        var quantity: [String: Any] = [
            "reported": reported,
            "unit": unit,
            "input_tokens": input,
            "output_tokens": output,
        ]
        if let cached { quantity["cached_tokens"] = cached }
        if let reasoning { quantity["reasoning_tokens"] = reasoning }
        if let quantityModel { quantity["model"] = quantityModel }
        var record: [String: Any] = ["quantity": quantity]
        if let recordModel { record["model"] = recordModel }
        let object: [String: Any] = [
            "recorded_at": recordedAt,
            "payload": ["event": ["kind": "goal_usage_attribution", "record": record]],
        ]
        return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
}
