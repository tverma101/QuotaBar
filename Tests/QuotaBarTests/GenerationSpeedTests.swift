import Foundation
import XCTest
@testable import QuotaBar

final class GenerationSpeedTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()
    private let now = Date(timeIntervalSince1970: 1_795_262_400) // 2026-11-21T12:00:00Z

    private func report() -> GenerationSpeedReport {
        var report = GenerationSpeedReport(now: now, calendar: calendar)
        func sample(_ age: TimeInterval, seconds: Double, tokens: Int64, model: String? = "model-a") -> GenerationSpeedSample {
            GenerationSpeedSample(finishedAt: now.addingTimeInterval(-age), seconds: seconds,
                                  outputTokens: tokens, model: model)
        }
        for sample in [
            sample(60, seconds: 10, tokens: 200),
            sample(120, seconds: 1, tokens: 50),
            sample(180, seconds: 9, tokens: 250),
            sample(2 * 86_400, seconds: 2, tokens: 100, model: "model-b"),
            sample(10 * 86_400, seconds: 12, tokens: 120, model: "model-b"),
            sample(14 * 86_400 + 60, seconds: 5, tokens: 60),            // outside the window
            sample(-1, seconds: 5, tokens: 60),                          // future
            sample(30, seconds: .nan, tokens: 60),
            sample(30, seconds: 0.1, tokens: 60),                        // too short to be a response
            sample(30, seconds: 5, tokens: 0)                            // nothing generated
        ] { report.add(sample, source: .zcode) }
        report.add(sample(90, seconds: 4, tokens: 80, model: "gemini"), source: .antigravity)
        return report
    }

    func testWindowsAndRatesUseRecordedIntervalsPerSource() throws {
        let report = report()
        let today = try XCTUnwrap(report.rows(window: .today).first { $0.id == .zcode })
        XCTAssertEqual(today.totals.samples, 3)
        XCTAssertEqual(today.totals.tokens, 500, accuracy: 1e-9)
        XCTAssertEqual(today.totals.seconds, 20, accuracy: 1e-9)
        XCTAssertEqual(today.totals.rate(minimumSamples: 3) ?? 0, 25, accuracy: 1e-9)
        XCTAssertNil(today.totals.rate(minimumSamples: 5), "a provider rate needs five samples")
        XCTAssertEqual(try XCTUnwrap(today.models.first).id, "model-a")

        let week = try XCTUnwrap(report.rows(window: .week).first { $0.id == .zcode })
        XCTAssertEqual(week.totals.samples, 4)
        let fortnight = try XCTUnwrap(report.rows(window: .fortnight).first { $0.id == .zcode })
        XCTAssertEqual(fortnight.totals.samples, 5)
        XCTAssertEqual(fortnight.totals.tokens, 720, accuracy: 1e-9)
        XCTAssertEqual(fortnight.totals.seconds, 34, accuracy: 1e-9)

        // Sources keep their own denominators and identities — never summed across providers.
        let other = try XCTUnwrap(report.rows(window: .fortnight).first { $0.id == .antigravity })
        XCTAssertEqual(other.totals.samples, 1)
        XCTAssertEqual(other.models.map(\.id), ["gemini"])
    }

    func testYesterdayUsesCalendarMidnightsAcrossAutumnClockChange() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let iso = ISO8601DateFormatter()
        let now = try XCTUnwrap(iso.date(from: "2026-11-02T16:00:00Z"))
        var report = GenerationSpeedReport(now: now, calendar: calendar)
        for (timestamp, model) in [
            ("2026-11-01T06:59:59Z", "previous-day"),
            ("2026-11-01T07:00:00Z", "yesterday"),
            ("2026-11-02T07:59:59Z", "yesterday"),
            ("2026-11-02T08:00:00Z", "today")
        ] {
            report.add(GenerationSpeedSample(finishedAt: try XCTUnwrap(iso.date(from: timestamp)),
                                             seconds: 2, outputTokens: 100, model: model), source: .zcode)
        }
        let yesterday = try XCTUnwrap(report.rows(window: .yesterday).first)
        XCTAssertEqual(yesterday.models.map(\.id), ["yesterday"])
        XCTAssertEqual(yesterday.totals.samples, 2)
        XCTAssertEqual(report.rows(window: .today).first?.models.map(\.id), ["today"])
    }

    func testUnavailableSourceDisclosesWithoutHidingReadRows() throws {
        var report = report()
        report.markUnavailable(.antigravity)
        let rows = report.rows(window: .fortnight)
        XCTAssertEqual(Set(rows.map(\.id)), [.zcode, .antigravity])
        XCTAssertEqual(report.unavailable, [.antigravity])
    }

    func testZCodeSamplesRequireCompletedTimingAndIntegerCounts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("db.sqlite").path
        let sqlite = SQLiteCLIAccessor()
        try sqlite.execute(path: path, sql: """
        CREATE TABLE model_usage(status TEXT, completed_at, first_token_at, model_id, output_tokens);
        """)
        func row(_ completed: Int64, _ first: Any, _ model: Any, _ output: Any, _ status: String = "completed") -> String {
            let firstSQL = first is Int64 ? "\(first)" : "NULL"
            let modelSQL = model is String ? "'\(model)'" : "NULL"
            let outputSQL = output is String ? "'\(output)'" : "\(output)"
            return "INSERT INTO model_usage VALUES('\(status)', \(completed), \(firstSQL), \(modelSQL), \(outputSQL));"
        }
        try sqlite.execute(path: path, sql: [
            row(1_795_262_400_000, Int64(1_795_262_398_000), "m|name", Int64(100)),
            row(1_795_262_400_000, Int64(1_795_262_398_000), "m|name", Int64(100), "error"),
            row(1_795_262_400_000, "nil", "m|name", Int64(100)),
            row(1_795_262_400_000, Int64(1_795_262_401_000), "m|name", Int64(100)),
            row(1_700_000_000_000, Int64(1_700_000_998_000), "m|name", Int64(100)),
            row(1_795_262_400_000, Int64(1_795_262_398_000), "m|name", "100")
        ].joined(separator: "\n"))
        let since = Date(timeIntervalSince1970: 1_795_262_400).addingTimeInterval(-3_600)
        let samples = try GenerationSpeedScanner(zcodePath: path).zcodeSamples(
            since: since, now: Date(timeIntervalSince1970: 1_795_262_400))
        let sample = try XCTUnwrap(samples.first)
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(sample.model, "m|name")
        XCTAssertEqual(sample.outputTokens, 100)
        XCTAssertEqual(sample.seconds, 2, accuracy: 1e-9)
        XCTAssertEqual(sample.finishedAt, Date(timeIntervalSince1970: 1_795_262_400))
    }

    func testAntigravityRequiresExplicitTimingAndDeduplicatesCopies() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("genspeed-ag-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let endMs = Int64(now.timeIntervalSince1970 * 1000)
        let roots = [".gemini/antigravity/conversations", ".config/antigravity/conversations"]
        for (rootIndex, root) in roots.enumerated() {
            let dir = home.appendingPathComponent(root, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let db = dir.appendingPathComponent("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.db").path
            try createConversation(at: db)
            // Same response recorded in both roots: counts once.
            try insertResponse(at: db, idx: 1, startMs: endMs - 60_000, endOffset: 10_000,
                               output: 200, responseId: "shared-1", status: 3)
            // Missing field 7 (finished_generating_at): no explicit end, must not qualify.
            try insertResponse(at: db, idx: 2, startMs: endMs - 60_000, endOffset: nil,
                               output: 200, responseId: "no-end-\(rootIndex)", status: 3)
        }
        let since = now.addingTimeInterval(-14 * 86_400)
        let scan = AntigravityConversationReader.responseScan(home: home, since: since, now: now)
        XCTAssertFalse(scan.hasReadFailures)
        XCTAssertEqual(scan.responses.count, 1)
        XCTAssertEqual(scan.responses.first?.endMs, endMs - 50_000)
        XCTAssertEqual(scan.responses.first?.startMs, endMs - 60_000)
        XCTAssertEqual(scan.responses.first?.outputTokens, 200)
    }

    // MARK: - Fixtures (same shapes as the Antigravity corpus tests)

    private func insertResponse(
        at database: String, idx: Int64, startMs: Int64, endOffset: Int64?,
        output: Int64, responseId: String, status: Int64
    ) throws {
        func ts(_ ms: Int64) -> [UInt8] {
            SpeedProto.varintField(1, UInt64(bitPattern: ms / 1000)) + SpeedProto.varintField(2, 0)
        }
        var metadata = SpeedProto.bytesField(1, ts(startMs))                 // created_at
        if let endOffset { metadata += SpeedProto.bytesField(7, ts(startMs + endOffset)) } // finished_generating_at
        var usage = SpeedProto.varintField(2, 1_000)
        usage += SpeedProto.varintField(3, UInt64(output))
        usage += SpeedProto.stringField(11, responseId)
        metadata += SpeedProto.bytesField(9, usage)
        try sqlite(database, "INSERT INTO steps (idx, step_type, status, metadata) VALUES (\(idx), 15, \(status), x'\(SpeedProto.hex(metadata))');")
    }

    private func createConversation(at path: String) throws {
        try? FileManager.default.removeItem(atPath: path)
        try sqlite(path, """
        CREATE TABLE steps (idx integer primary key, step_type integer not null default 0, status integer not null default 0, metadata blob);
        CREATE TABLE gen_metadata (idx integer primary key, data blob, size integer not null default 0);
        CREATE TABLE executor_metadata (idx integer primary key, data blob, size integer not null default 0);
        """)
    }

    private func sqlite(_ path: String, _ sql: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [path, sql]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "fixture sqlite error: \(sql)")
    }
}

/// Minimal protobuf encoder for fixture blobs (varint + length-delimited).
private enum SpeedProto {
    static func varint(_ value: UInt64) -> [UInt8] {
        var bytes: [UInt8] = []
        var value = value
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            bytes.append(byte)
        } while value != 0
        return bytes
    }
    static func key(_ number: Int, wire: UInt8) -> [UInt8] { varint(UInt64(number << 3) | UInt64(wire)) }
    static func varintField(_ number: Int, _ value: UInt64) -> [UInt8] { key(number, wire: 0) + varint(value) }
    static func bytesField(_ number: Int, _ value: [UInt8]) -> [UInt8] {
        key(number, wire: 2) + varint(UInt64(value.count)) + value
    }
    static func stringField(_ number: Int, _ value: String) -> [UInt8] { bytesField(number, Array(value.utf8)) }
    static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
}
