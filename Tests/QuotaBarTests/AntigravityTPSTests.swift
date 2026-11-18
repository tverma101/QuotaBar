import Foundation
import XCTest
@testable import QuotaBar

/// Hermetic end-to-end coverage for the Antigravity corpus of the TPS lens: synthetic conversation
/// databases with planner-response steps, built with a minimal protobuf encoder in-process. Never
/// touches the user's real conversation stores.
final class AntigravityTPSTests: XCTestCase {
    private var home: URL!
    private var fixtureHome: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("openusage-antigravity-tps-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        fixtureHome = home.appendingPathComponent("gemini-home", isDirectory: true)
        try FileManager.default.createDirectory(
            at: fixtureHome.appendingPathComponent(".gemini/antigravity/conversations", isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    func testPlannerResponsesFoldIntoTheTPSLens() async throws {
        let now = Date()
        let end = Int64(now.timeIntervalSince1970 * 1000)
        let starts = (0..<6).map { end - Int64(6 - $0) * 10_000 }
        let conversations = fixtureHome.appendingPathComponent(".gemini/antigravity/conversations")
        let database = conversations.appendingPathComponent("11111111-2222-3333-4444-555555555555.db").path
        try createConversation(at: database)
        for (index, start) in starts.enumerated() {
            try insertResponse(
                at: database,
                idx: Int64(index + 1),
                startMs: start,
                output: 500,
                responseId: "resp-\(index)"
            )
        }
        try insertGeneration(at: database, stepIndices: [1, 2, 3, 4, 5, 6], model: "gemini-2.5-pro")

        let scan = await scanAntigravity(now: now)
        let estimate = try XCTUnwrap(scan)
        let corpus = try XCTUnwrap(estimate.corpora["antigravity"], "planner responses must fold into the lens")
        XCTAssertEqual(corpus.intervals, 6)
        XCTAssertEqual(corpus.outputTokens, 3_000, accuracy: 1e-9)
        XCTAssertEqual(corpus.tokensPerSecond ?? 0, 100, accuracy: 1e-9)

        let models = try XCTUnwrap(estimate.models["antigravity"], "the model breakdown must be populated")
        XCTAssertEqual(models.first?.model, "gemini-2.5-pro")
        XCTAssertEqual(models.first?.rate ?? 0, 100, accuracy: 1e-9)
    }

    func testDuplicateResponseIdesAcrossStoresCountOnce() async throws {
        let now = Date()
        let end = Int64(now.timeIntervalSince1970 * 1000)
        let stores = [".gemini/antigravity/conversations", ".gemini/antigravity-cli/conversations"]
        for (storeIndex, subpath) in stores.enumerated() {
            let dir = fixtureHome.appendingPathComponent(subpath, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // Same conversation id in both stores: a copied database, one response.
            let database = dir.appendingPathComponent("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.db").path
            try createConversation(at: database)
            for index in 0..<6 {
                try insertResponse(
                    at: database,
                    idx: Int64(index + 1),
                    startMs: end - Int64(6 - index) * 10_000,
                    output: 100,
                    responseId: "shared-resp-\(index)"
                )
            }
            _ = storeIndex
        }

        let scan = await scanAntigravity(now: now)
        let estimate = try XCTUnwrap(scan)
        let corpus = try XCTUnwrap(estimate.corpora["antigravity"])
        XCTAssertEqual(corpus.intervals, 6, "a fork copy must not double-count responses")
        XCTAssertEqual(corpus.outputTokens, 600, accuracy: 1e-9)
    }

    func testOpenAndAncientRowsAreExcluded() async throws {
        let now = Date()
        let end = Int64(now.timeIntervalSince1970 * 1000)
        let database = fixtureHome
            .appendingPathComponent(".gemini/antigravity/conversations/ffffffff-1111-2222-3333-444444444444.db")
            .path
        try createConversation(at: database)
        for index in 0..<6 {
            try insertResponse(
                at: database,
                idx: Int64(index + 1),
                startMs: end - Int64(6 - index) * 10_000,
                output: 100,
                responseId: "recent-\(index)"
            )
        }
        // One open (still generating) planner row: it must be ignored.
        try insertResponse(
            at: database,
            idx: 7,
            startMs: end - 5_000,
            output: 999,
            responseId: "open-one",
            status: 2
        )
        // One ancient row outside the window.
        try insertResponse(
            at: database,
            idx: 8,
            startMs: end - 40 * 86_400_000,
            output: 999,
            responseId: "ancient-one"
        )

        let scan = await scanAntigravity(now: now)
        let estimate = try XCTUnwrap(scan)
        let corpus = try XCTUnwrap(estimate.corpora["antigravity"])
        XCTAssertEqual(corpus.intervals, 6, "open and out-of-window rows must not count")
        XCTAssertEqual(corpus.outputTokens, 600, accuracy: 1e-9)
    }

    func testMissingStoreIsNoDataNotAnError() async throws {
        let scan = await scanAntigravity(now: Date(), useEmptyStore: true)
        let estimate = try XCTUnwrap(scan)
        XCTAssertNil(estimate.corpora["antigravity"])
    }

    // MARK: - Fixture plumbing

    private func scanAntigravity(now: Date, useEmptyStore: Bool = false) async -> TokensPerSecondEstimate? {
        let home = self.home!
        let fixtureHome = self.fixtureHome!
        let emptyHome = home.appendingPathComponent("empty-gemini", isDirectory: true)
        if useEmptyStore {
            try? FileManager.default.createDirectory(at: emptyHome, withIntermediateDirectories: true)
        }
        let claude = ClaudeLogUsageScanner(
            environment: FakeEnvironment([:]),
            homeDirectory: { home.appendingPathComponent("no-claude") },
            incrementalScanner: IncrementalJSONLScanner<ClaudeLogUsageScanner.Entry>()
        )
        let codex = CodexLogUsageScanner(
            environment: FakeEnvironment([:]),
            homeDirectory: { home.appendingPathComponent("no-codex") },
            incrementalScanner: IncrementalJSONLScanner<CodexLogUsageScanner.Event>()
        )
        let grok = GrokLogUsageScanner(
            environment: FakeEnvironment([:]),
            homeDirectory: { home.appendingPathComponent("no-grok") },
            incrementalScanner: IncrementalJSONLScanner<GrokLogUsageScanner.Entry>()
        )
        let muse = MuseUsageScanner(
            homeDirectory: { home.appendingPathComponent("no-muse") },
            incrementalScanner: IncrementalJSONLScanner<MuseUsageScanner.Entry>()
        )
        let pi = PiUsageScanner(
            environment: FakeEnvironment([:]),
            homeDirectory: { home.appendingPathComponent("no-pi") },
            incrementalScanner: IncrementalJSONLScanner<PiUsageScanner.Entry>()
        )
        return await TokensPerSecondScanner(
            claude: claude,
            codex: codex,
            grok: grok,
            muse: muse,
            pi: pi,
            museSessionsRoot: { emptyHome },
            zaiDatabasePath: { nil },
            antigravityHome: { useEmptyStore ? emptyHome : fixtureHome }
        ).scan(daysBack: 14, now: now)
    }

    private func insertResponse(
        at database: String,
        idx: Int64,
        startMs: Int64,
        output: Int64,
        responseId: String,
        status: Int64 = 3
    ) throws {
        let timestamp = { (ms: Int64) -> [UInt8] in
            // google.protobuf.Timestamp { 1: seconds, 2: nanos }
            ProtoFixture.varintField(1, UInt64(bitPattern: ms / 1000))
                + ProtoFixture.varintField(2, 0)
        }
        var metadata = ProtoFixture.bytesField(1, timestamp(startMs))                       // created_at
        metadata += ProtoFixture.bytesField(7, timestamp(startMs + 5_000))                  // finished_generating_at
        var usage = ProtoFixture.varintField(2, 1_000)                                      // input_tokens
        usage += ProtoFixture.varintField(3, UInt64(output))                                // output_tokens
        usage += ProtoFixture.stringField(11, responseId)                                   // response_id
        metadata += ProtoFixture.bytesField(9, usage)                                       // model_usage
        let blob = hex(metadata)
        try sqlite(database, """
        INSERT INTO steps (idx, step_type, status, metadata) VALUES (\(idx), 15, \(status), x'\(blob)');
        """)
    }

    private func insertGeneration(at database: String, stepIndices: [UInt64], model: String) throws {
        let chatModel = ProtoFixture.stringField(19, model)                                 // response_model
        var generation = ProtoFixture.bytesField(1, chatModel)                              // chat_model
        var packed: [UInt8] = []
        for step in stepIndices { packed += ProtoFixture.varint(step) }                     // packed step_indices
        generation += ProtoFixture.bytesField(2, packed)
        let size = generation.count
        try sqlite(database, """
        INSERT INTO gen_metadata (idx, data, size) VALUES (0, x'\(hex(generation))', \(size));
        """)
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
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "fixture sqlite error: \(sql)")
    }

    private func metadataForStep1() -> [UInt8] {
        let now = Date()
        let end = Int64(now.timeIntervalSince1970 * 1000)
        let start = end - 6 * 10_000
        func ts(_ ms: Int64) -> [UInt8] {
            ProtoFixture.varintField(1, UInt64(bitPattern: ms / 1000)) + ProtoFixture.varintField(2, 0)
        }
        var metadata = ProtoFixture.bytesField(1, ts(start))
        metadata += ProtoFixture.bytesField(7, ts(start + 5_000))
        var usage = ProtoFixture.varintField(2, 1_000)
        usage += ProtoFixture.varintField(3, 500)
        usage += ProtoFixture.stringField(11, "resp-0")
        metadata += ProtoFixture.bytesField(9, usage)
        return metadata
    }

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// Minimal protobuf encoder for fixture blobs (varint + length-delimited).
private enum ProtoFixture {
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

    static func key(_ number: Int, wire: UInt8) -> [UInt8] {
        varint(UInt64(number << 3) | UInt64(wire))
    }

    static func varintField(_ number: Int, _ value: UInt64) -> [UInt8] {
        key(number, wire: 0) + varint(value)
    }

    static func bytesField(_ number: Int, _ value: [UInt8]) -> [UInt8] {
        key(number, wire: 2) + varint(UInt64(value.count)) + value
    }

    static func stringField(_ number: Int, _ value: String) -> [UInt8] {
        bytesField(number, Array(value.utf8))
    }
}
