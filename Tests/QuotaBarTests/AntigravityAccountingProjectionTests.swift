import XCTest
import SQLite3
import os
@testable import QuotaBar

final class AntigravityAccountingProjectionTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // Scans persist derivation records; keep each test's writes in a scratch directory so no
        // fixture leaks into (or warms from) the user's real scan cache.
        AntigravityAggregatePersistence.directoryOverride = FileManager.default.temporaryDirectory
            .appendingPathComponent("antigravity-projection-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        if let override = AntigravityAggregatePersistence.directoryOverride {
            try? FileManager.default.removeItem(at: override)
        }
        AntigravityAggregatePersistence.directoryOverride = nil
        super.tearDown()
    }

    private func varint(_ value: UInt64) -> [UInt8] {
        var n = value
        var result: [UInt8] = []
        repeat {
            var byte = UInt8(n & 127)
            n >>= 7
            if n > 0 { byte |= 128 }
            result.append(byte)
        } while n > 0
        return result
    }

    private func bytes(_ field: UInt64, _ value: [UInt8]) -> [UInt8] {
        varint(field << 3 | 2) + varint(UInt64(value.count)) + value
    }

    private func blob(padding: Int = 3_000_000, duplicateUsage: Bool = false, input: UInt64 = 100) -> [UInt8] {
        let usage = varint(2 << 3) + varint(input) + varint(3 << 3) + varint(50)
        let timestamp = bytes(4, varint(1 << 3) + varint(1_793_470_000))
        var wrapped = bytes(2, [UInt8](repeating: 65, count: padding))
        wrapped += bytes(4, usage) + bytes(19, Array("gemini-3.6-flash".utf8)) + bytes(9, timestamp)
        if duplicateUsage { wrapped += bytes(4, usage) }
        return bytes(1, wrapped) + bytes(4, Array("step-id".utf8))
    }

    func testProjectionSkipsMegabytesOfConversationAndPreservesExactAccounting() throws {
        let source = blob()
        var bytesRead = 0
        let projected = try XCTUnwrap(AntigravityAccountingProjection.project(byteCount: source.count) { range in
            bytesRead += range.count
            return Array(source[range])
        })
        XCTAssertLessThan(bytesRead, 20_000)
        XCTAssertLessThan(projected.count, 200)
        let event = try XCTUnwrap(AntigravityProtoDecoder.generationEvent(from: projected))
        XCTAssertEqual(event.model, "gemini-3.6-flash")
        XCTAssertEqual(event.inputTokens, 100)
        XCTAssertEqual(event.outputTokens, 50)
        XCTAssertEqual(event.timestampSeconds, 1_793_470_000)
    }

    func testDuplicateUsageAndTruncationCannotPublishPlausibleTotals() throws {
        let source = blob(duplicateUsage: true)
        let projected = try XCTUnwrap(AntigravityAccountingProjection.project(byteCount: source.count) { Array(source[$0]) })
        guard case .malformedUsage = AntigravityProtoDecoder.decodeGenerationEvent(from: projected) else {
            return XCTFail("duplicate cumulative accounting must remain invalid")
        }
        let truncated = Array(source.dropLast())
        XCTAssertNil(try AntigravityAccountingProjection.project(byteCount: truncated.count) { Array(truncated[$0]) })
    }

    func testReaderBudgetAndCancellationStayBounded() async throws {
        let source = bytes(1, bytes(4, [UInt8](repeating: 0, count: 70_000)))
        XCTAssertNil(try AntigravityAccountingProjection.project(byteCount: source.count) { Array(source[$0]) })
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try AntigravityAccountingProjection.project(byteCount: source.count) { Array(source[$0]) }
        }
        do { _ = try await task.value; XCTFail("cancelled projection must stop") }
        catch is CancellationError {} catch { XCTFail("unexpected error: \(error)") }
    }

    func testRealSQLiteOversizedRowIsCountedOnceAndReusedOnWarmScan() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Same destination (the Trash) without spawning a trash subprocess per test run.
        defer { try? FileManager.default.trashItem(at: directory, resultingItemURL: nil) }
        let path = directory.appendingPathComponent("history.db").path
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, "CREATE TABLE gen_metadata(idx INTEGER PRIMARY KEY, data BLOB)", nil, nil, nil), SQLITE_OK)
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(database, "INSERT INTO gen_metadata VALUES(0, ?)", -1, &statement, nil), SQLITE_OK)
        let source = blob()
        source.withUnsafeBytes { buffer in
            XCTAssertEqual(sqlite3_bind_blob(statement, 1, buffer.baseAddress, Int32(buffer.count), nil), SQLITE_OK)
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        }
        sqlite3_finalize(statement)
        let before = try Data(contentsOf: URL(fileURLWithPath: path))
        let projected = try XCTUnwrap(AntigravityAccountingProjection.read(path: path, index: 0, expectedBytes: source.count))
        XCTAssertEqual(AntigravityProtoDecoder.generationEvent(from: projected)?.inputTokens, 100)
        let projectionReads = OSAllocatedUnfairLock(initialState: 0)
        let scanner = AntigravityDbUsageScanner(conversationsDirectory: { directory.path }, projectOversized: { path, index, size in
            projectionReads.withLock { $0 += 1 }
            return try AntigravityAccountingProjection.read(path: path, index: index, expectedBytes: size)
        })
        let now = Date(timeIntervalSince1970: 1_793_470_100)
        let first = await scanner.scan(now: now, pricing: .empty)
        let second = await scanner.scan(now: now, pricing: .empty)
        XCTAssertEqual(first?.series.daily.first?.totalTokens, 150)
        XCTAssertEqual(second?.series, first?.series)
        XCTAssertTrue(first?.unmeasuredUsageDays?.isEmpty ?? true)
        XCTAssertEqual(projectionReads.withLock { $0 }, 1, "warm scans must not project the unchanged large source again")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), before, "source stays read-only")
        XCTAssertThrowsError(try AntigravityAccountingProjection.read(path: path, index: 0, expectedBytes: source.count + 1))

        let edited = blob(input: 101)
        XCTAssertEqual(edited.count, source.count)
        var update: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(database, "UPDATE gen_metadata SET data = ? WHERE idx = 0", -1, &update, nil), SQLITE_OK)
        edited.withUnsafeBytes { buffer in
            XCTAssertEqual(sqlite3_bind_blob(update, 1, buffer.baseAddress, Int32(buffer.count), nil), SQLITE_OK)
            XCTAssertEqual(sqlite3_step(update), SQLITE_DONE)
        }
        sqlite3_finalize(update)
        let changed = await scanner.scan(now: now, pricing: .empty)
        XCTAssertEqual(changed?.series.daily.first?.totalTokens, 151, "same-size edits must not retain stale projected usage")
        XCTAssertEqual(projectionReads.withLock { $0 }, 2)
    }

    func testOptInReadOnlyLiveAccountingProjection() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["QUOTABAR_ANTIGRAVITY_LIVE_DB"],
              let index = environment["QUOTABAR_ANTIGRAVITY_LIVE_INDEX"].flatMap(Int.init) else {
            throw XCTSkip("explicit local-source validation only")
        }
        let sqlite = SQLiteCLIAccessor(allowsReadWriteFallback: false)
        let size = try XCTUnwrap(try sqlite.queryValue(path: path,
            sql: "SELECT length(data) FROM gen_metadata WHERE idx = \(index)").flatMap(Int.init))
        let projection = try XCTUnwrap(AntigravityAccountingProjection.read(path: path, index: index, expectedBytes: size))
        let steps = try AntigravityStepTimestampIndex.load(path: path, sqlite: sqlite)
        let decoded = AntigravityProtoDecoder.decodeGenerationEvent(from: projection,
            matchedStepTimestamp: steps.timestamp(for: projection))
        guard case .event(let event) = decoded else { return XCTFail("Live accounting could not be recovered: \(decoded)") }
        print("Live accounting projection: sourceBytes=\(size) projectedBytes=\(projection.count) model=\(event.model) input=\(event.inputTokens) output=\(event.outputTokens) cacheRead=\(event.cacheReadTokens) timestamp=\(event.timestampSeconds)")
        XCTAssertGreaterThan(event.inputTokens + event.outputTokens + event.cacheReadTokens, 0)
    }
}
