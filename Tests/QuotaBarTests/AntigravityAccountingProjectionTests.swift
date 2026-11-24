import XCTest
import SQLite3
import os
@testable import QuotaBar

/// Refuses to open one path with the SQLITE_CANTOPEN shape seen on real closed WAL stores while
/// delegating everything else — including the private clone path — to the real read-only accessor,
/// and records every path it is asked to query.
private final class CantOpenFailingSQLite: SQLiteAccessing, @unchecked Sendable {
    private let failingPath: String
    private let delegate = SQLiteCLIAccessor(allowsReadWriteFallback: false)
    let queriedPaths = OSAllocatedUnfairLock<[String]>(initialState: [])

    init(failingPath: String) {
        self.failingPath = failingPath
    }

    func queryValue(path: String, sql: String) throws -> String? {
        queriedPaths.withLock { $0.append(path) }
        if path == failingPath {
            throw SQLiteError.queryFailed("unable to open database file")
        }
        return try delegate.queryValue(path: path, sql: sql)
    }

    func execute(path: String, sql: String) throws {
        try delegate.execute(path: path, sql: sql)
    }
}

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

    /// 160 ignored 4 KiB fields push a 4 KiB-chunk reader past the 512 KiB budget even though almost
    /// no bytes are wanted; 512-byte chunks only pay for pages the wire format actually visits.
    func testSparseIgnoredFieldsStayUnderTheReadBudget() throws {
        var wrapped: [UInt8] = []
        for _ in 0..<160 { wrapped += bytes(2, [UInt8](repeating: 65, count: 4_096)) }
        let usage = varint(2 << 3) + varint(100) + varint(3 << 3) + varint(50)
        let timestamp = bytes(4, varint(1 << 3) + varint(1_793_470_000))
        wrapped += bytes(4, usage) + bytes(19, Array("gemini-3.6-flash".utf8)) + bytes(9, timestamp)
        let source = bytes(1, wrapped)
        var bytesRead = 0
        let projected = try XCTUnwrap(AntigravityAccountingProjection.project(byteCount: source.count) { range in
            bytesRead += range.count
            return Array(source[range])
        })
        XCTAssertGreaterThan(source.count, 512 * 1_024, "fixture must exceed the old 4 KiB-chunk read budget")
        XCTAssertLessThan(bytesRead, 128 * 1_024)
        XCTAssertLessThan(projected.count, 128 * 1_024)
        let event = try XCTUnwrap(AntigravityProtoDecoder.generationEvent(from: projected))
        XCTAssertEqual(event.inputTokens, 100)
        XCTAssertEqual(event.outputTokens, 50)
    }

    /// Schema-1 records predate the 512-byte projection chunks, so any that recorded refused
    /// oversized rows are stale: they rescan instead of replaying a truncated history. Clean
    /// schema-1 records still load.
    func testLegacySchemaOneRecordLoadsOnlyWithoutOversizedRows() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-guard-\(UUID().uuidString).db").path
        FileManager.default.createFile(atPath: path, contents: Data())
        defer { try? FileManager.default.removeItem(atPath: path) }
        let fingerprint = try AntigravityDbUsageScanner.DatabaseFingerprint(path: path)
        func record(schema: Int, oversized: [Int64]) -> AntigravityAggregatePersistence.Record {
            var cache = AntigravityDbUsageScanner.CachedDatabase(
                fingerprint: fingerprint, windowStart: .distantPast)
            cache.oversizedTimestamps = oversized
            return AntigravityAggregatePersistence.Record(schema: schema, cache: cache)
        }
        AntigravityAggregatePersistence.write(record(schema: 1, oversized: []), path: path)
        XCTAssertNotNil(AntigravityAggregatePersistence.read(path: path), "clean schema-1 records still load")
        AntigravityAggregatePersistence.write(record(schema: 1, oversized: [1]), path: path)
        XCTAssertNil(AntigravityAggregatePersistence.read(path: path), "schema-1 oversized history must rescan")
        AntigravityAggregatePersistence.write(record(schema: 2, oversized: [1]), path: path)
        XCTAssertNotNil(AntigravityAggregatePersistence.read(path: path))
    }

    /// A clean, fully checkpointed WAL database that refuses every open (the SQLITE_CANTOPEN shape
    /// seen on real T3 stores) is read through a private APFS clone: history counts exactly, the
    /// original stays byte-identical, and no journal sidecars are created on the real file.
    func testSidecarlessWALDatabaseIsRecoveredThroughPrivateClone() async throws {
        let (directory, path) = try makeClosedSidecarlessWALDatabase()
        defer { try? FileManager.default.trashItem(at: directory, resultingItemURL: nil) }
        let before = try Data(contentsOf: URL(fileURLWithPath: path))
        let sqlite = CantOpenFailingSQLite(failingPath: path)
        let projectedPaths = OSAllocatedUnfairLock<[String]>(initialState: [])
        let scanner = AntigravityDbUsageScanner(
            sqlite: sqlite,
            conversationsDirectory: { directory.path },
            projectOversized: { readPath, index, size in
                projectedPaths.withLock { $0.append(readPath) }
                return try AntigravityAccountingProjection.read(path: readPath, index: index, expectedBytes: size)
            }
        )
        let result = await scanner.scan(now: Date(timeIntervalSince1970: 1_793_470_100), pricing: .empty)
        let scan = try XCTUnwrap(result)
        XCTAssertEqual(scan.series.daily.first?.totalTokens, 150)
        XCTAssertTrue(scan.unmeasuredUsageDays?.isEmpty ?? true)
        XCTAssertTrue(
            sqlite.queriedPaths.withLock { $0 }.contains { $0 != path && $0.contains("antigravity-db-") },
            "recovery must run its queries against the private clone"
        )
        let projections = projectedPaths.withLock { $0 }
        XCTAssertEqual(projections.count, 1, "the oversized row is projected exactly once")
        XCTAssertTrue(
            projections.first?.contains("antigravity-db-") == true && projections.first != path,
            "oversized rows must be projected from the clone, never the refused original"
        )
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), before)
        for suffix in ["-wal", "-shm", "-journal"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: path + suffix),
                           "recovery must not create \(suffix) on the original")
        }
    }

    /// A live -wal sidecar means a writer can still own the database: the clone fallback must
    /// refuse, and the scan must not fabricate history from a stale copy.
    func testLiveWALSidecarRefusesTheCloneFallback() async throws {
        let (directory, path) = try makeClosedSidecarlessWALDatabase()
        defer { try? FileManager.default.trashItem(at: directory, resultingItemURL: nil) }
        FileManager.default.createFile(atPath: path + "-wal", contents: Data([0]))
        let sqlite = CantOpenFailingSQLite(failingPath: path)
        let scanner = AntigravityDbUsageScanner(
            sqlite: sqlite,
            conversationsDirectory: { directory.path },
            projectOversized: { readPath, index, size in
                try AntigravityAccountingProjection.read(path: readPath, index: index, expectedBytes: size)
            }
        )
        let scan = await scanner.scan(now: Date(timeIntervalSince1970: 1_793_470_100), pricing: .empty)
        XCTAssertTrue((scan?.series.daily ?? []).isEmpty, "a refused recovery must not count rows")
        XCTAssertFalse(
            sqlite.queriedPaths.withLock { $0 }.contains { $0 != path },
            "no clone path may be queried after the sidecar guard refuses"
        )
    }

    /// A closed WAL-mode fixture with one oversized generation and no journal sidecars.
    private func makeClosedSidecarlessWALDatabase() throws -> (URL, String) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("history.db").path
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &database), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(database, "PRAGMA journal_mode=WAL", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(database, "CREATE TABLE gen_metadata(idx INTEGER PRIMARY KEY, data BLOB)", nil, nil, nil), SQLITE_OK)
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(database, "INSERT INTO gen_metadata VALUES(0, ?)", -1, &statement, nil), SQLITE_OK)
        let source = blob()
        source.withUnsafeBytes { buffer in
            XCTAssertEqual(sqlite3_bind_blob(statement, 1, buffer.baseAddress, Int32(buffer.count), nil), SQLITE_OK)
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        }
        sqlite3_finalize(statement)
        XCTAssertEqual(sqlite3_exec(database, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(database), SQLITE_OK)
        // A WAL-mode database can keep empty sidecars after a clean close on this platform;
        // removing them reproduces the fully checkpointed, writerless shape the recovery covers.
        for suffix in ["-wal", "-shm", "-journal"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
            XCTAssertFalse(FileManager.default.fileExists(atPath: path + suffix),
                           "fixture must leave \(suffix) absent")
        }
        return (directory, path)
    }

    func testOptInReadOnlyLiveAccountingProjection() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["QUOTABAR_ANTIGRAVITY_LIVE_DB"],
              let index = environment["QUOTABAR_ANTIGRAVITY_LIVE_INDEX"].flatMap(Int.init) else {
            throw XCTSkip("explicit local-source validation only")
        }
        let sqlite = NativeSQLiteAccessor(allowsReadWriteFallback: false)
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
