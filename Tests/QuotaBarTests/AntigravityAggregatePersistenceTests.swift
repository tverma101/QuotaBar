import XCTest
@testable import QuotaBar

/// Minimal protobuf fixture builders mirroring the synthetic shapes in AntigravityDbUsageScannerTests.
private func antigravityVarint(_ value: UInt64) -> [UInt8] {
    var remaining = value
    var encoded: [UInt8] = []
    repeat {
        var byte = UInt8(remaining & 0x7f)
        remaining >>= 7
        if remaining != 0 { byte |= 0x80 }
        encoded.append(byte)
    } while remaining != 0
    return encoded
}

private func antigravityVarintField(_ number: UInt32, _ value: UInt64) -> [UInt8] {
    antigravityVarint(UInt64(number) << 3) + antigravityVarint(value)
}

private func antigravityBytesField(_ number: UInt32, _ bytes: [UInt8]) -> [UInt8] {
    antigravityVarint(UInt64(number) << 3 | 2) + antigravityVarint(UInt64(bytes.count)) + bytes
}

private func antigravityGenerationBlob(model: String, input: UInt64, output: UInt64, timestamp: UInt64) -> [UInt8] {
    let usage = antigravityVarintField(1, 0) + antigravityVarintField(2, input) + antigravityVarintField(3, output)
    var event = antigravityBytesField(19, Array(model.utf8)) + antigravityBytesField(4, usage)
    event += antigravityBytesField(9, antigravityBytesField(4, antigravityVarintField(1, timestamp)))
    return antigravityBytesField(1, event)
}

@MainActor
final class AntigravityAggregatePersistenceTests: XCTestCase {
    private var scratch: URL!
    private let now = TestLocalInstant.date(2026, 7, 27, 12)
    private lazy var pricing = ModelPricing(
        supplement: PricingSupplement(),
        primary: PricingCatalog(entries: [
            "gemini-3.6-flash": ModelRates(
                inputPerMillion: 1,
                outputPerMillion: 4,
                cacheWritePerMillion: 1,
                cacheReadPerMillion: 0.25
            )
        ]),
        secondary: PricingCatalog()
    )

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("antigravity-persistence-\(UUID().uuidString)", isDirectory: true)
        AntigravityAggregatePersistence.directoryOverride = scratch
    }

    override func tearDown() {
        AntigravityAggregatePersistence.directoryOverride = nil
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
        super.tearDown()
    }

    private func makeDatabaseDirectory() throws -> (url: URL, path: String) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = directory.appendingPathComponent("conversation.db")
        try Data().write(to: database)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return (directory, database.path)
    }

    private func makeScanner(
        sqlite: AntigravityFakeSQLite,
        fixture: (url: URL, path: String)
    ) -> AntigravityDbUsageScanner {
        AntigravityDbUsageScanner(sqlite: sqlite, conversationsDirectory: { fixture.url.path })
    }

    /// The disk record round-trips the full derived state: stamps, events, aggregate, and the
    /// incomplete-day bookkeeping arrays survive encode/decode, and the step timestamp index is
    /// deliberately absent from the record.
    func testRoundTripsDerivedCacheRecord() throws {
        let fixture = try makeDatabaseDirectory()
        let cache = AntigravityDbUsageScanner.CachedDatabase(
            fingerprint: try AntigravityDbUsageScanner.DatabaseFingerprint(path: fixture.path),
            windowStart: TestLocalInstant.date(2026, 6, 27, 12),
            lastIndex: 3,
            rowCount: 4,
            contentFingerprint: "digest",
            events: [.init(model: "gemini-3.6-flash", inputTokens: 10, outputTokens: 5, cacheReadTokens: 1, timestampSeconds: 1000)],
            invalidTokenTimestamps: [2000],
            undatedIdentities: [.init(uuid: "turn-1", botID: "bot-1")],
            hasStepMetadata: false,
            aggregate: .init(
                pricingToken: "token",
                windowStart: TestLocalInstant.date(2026, 6, 27, 12),
                timeZoneIdentifier: "UTC",
                scan: LogUsageScan(
                    series: .init(daily: []),
                    modelUsage: nil,
                    unknownModelsByDay: [:],
                    apiEstimateByDay: nil
                ),
                recomputeAfter: nil,
                latestAcceptedTimestamp: 1000
            )
        )
        AntigravityAggregatePersistence.write(
            .init(schema: AntigravityAggregatePersistence.schema, cache: cache),
            path: fixture.path
        )

        let loaded = AntigravityAggregatePersistence.read(path: fixture.path)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.cache.fingerprint, cache.fingerprint)
        XCTAssertEqual(loaded?.cache.events, cache.events)
        XCTAssertEqual(loaded?.cache.undatedIdentities, cache.undatedIdentities)
        XCTAssertEqual(loaded?.cache.aggregate?.latestAcceptedTimestamp, 1000)
        XCTAssertEqual(loaded?.cache.aggregate?.scan.series.daily, [])
        XCTAssertNil(loaded?.cache.stepTimestampIndex)
    }

    func testRejectsRecordWithUnknownSchema() throws {
        let fixture = try makeDatabaseDirectory()
        let cache = AntigravityDbUsageScanner.CachedDatabase(
            fingerprint: try AntigravityDbUsageScanner.DatabaseFingerprint(path: fixture.path),
            windowStart: TestLocalInstant.date(2026, 6, 27, 12)
        )
        let url = AntigravityAggregatePersistence.fileURL(path: fixture.path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        var stale = AntigravityAggregatePersistence.Record(
            schema: AntigravityAggregatePersistence.schema, cache: cache
        )
        stale.schema = AntigravityAggregatePersistence.schema + 99
        try encoder.encode(stale).write(to: url, options: .atomic)

        XCTAssertNil(AntigravityAggregatePersistence.read(path: fixture.path))
    }

    /// A fresh scanner — the scan-worker child, or this app after a memory-pressure unload —
    /// must rebuild its view from the disk record without re-reading the conversation database.
    func testFreshScannerServesDiskRecordWithoutSQLiteQueries() async throws {
        let fixture = try makeDatabaseDirectory()
        let timestamp = UInt64(now.timeIntervalSince1970) - 3_600
        let row = AntigravityFixtureRow(
            index: 0,
            blob: antigravityGenerationBlob(model: "gemini-3.6-flash", input: 10, output: 5, timestamp: timestamp)
        )
        let sqlite = AntigravityFakeSQLite(rowsByPath: [fixture.path: [row]])

        let first = makeScanner(sqlite: sqlite, fixture: fixture)
        let firstScanResult = await first.scan(now: now, pricing: pricing)
        let firstScan = try XCTUnwrap(firstScanResult)
        XCTAssertEqual(firstScan.series.daily.first?.totalTokens, 15)

        let second = makeScanner(sqlite: sqlite, fixture: fixture)
        let secondScanResult = await second.scan(now: now, pricing: pricing)
        let secondScan = try XCTUnwrap(secondScanResult)
        XCTAssertEqual(secondScan.series.daily.first?.totalTokens, 15)
        // Warm path: no batch reads, no content-fingerprint verification queries. The counters are
        // shared with the first scan, so assert scan 2 added nothing.
        XCTAssertEqual(sqlite.queriedCursors, [-1])
        XCTAssertEqual(sqlite.contentFingerprintQueryCount, 1)
    }

    /// An appended row must be folded on top of the persisted record — the SHA3 prefix of the
    /// cached rows is verified and only the appended tail is read from SQLite.
    func testFreshScannerFoldsAppendedRowsOntoPersistedRecord() async throws {
        let fixture = try makeDatabaseDirectory()
        let timestamp = UInt64(now.timeIntervalSince1970) - 3_600
        let sqlite = AntigravityFakeSQLite(rowsByPath: [fixture.path: [
            .init(index: 0, blob: antigravityGenerationBlob(model: "gemini-3.6-flash", input: 10, output: 5, timestamp: timestamp))
        ]])
        let first = makeScanner(sqlite: sqlite, fixture: fixture)
        _ = await first.scan(now: now, pricing: pricing)

        sqlite.append(
            .init(index: 1, blob: antigravityGenerationBlob(model: "gemini-3.6-flash", input: 20, output: 5, timestamp: timestamp)),
            to: fixture.path
        )
        let fileHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: fixture.path))
        try fileHandle.seekToEnd()
        try fileHandle.write(contentsOf: Data(repeating: 0, count: 64))
        try fileHandle.close()

        let second = makeScanner(sqlite: sqlite, fixture: fixture)
        let scanResult = await second.scan(now: now, pricing: pricing)
        let scan = try XCTUnwrap(scanResult)
        XCTAssertEqual(scan.series.daily.first?.totalTokens, 40)
        // Scan 1 read from the start (cursor -1) plus its whole-table digest; scan 2 only verified
        // the cached prefix and read the appended tail past the cached lastIndex.
        XCTAssertEqual(sqlite.queriedCursors, [-1, 0])
        XCTAssertEqual(sqlite.contentFingerprintQueryCount, 2)
    }

    /// A pricing change invalidates the persisted aggregate but not the events: the re-fold runs
    /// from the record's raw events without re-reading the database, and the record is refreshed.
    func testPricingChangeRefoldsFromPersistedEventsWithoutSQLite() async throws {
        let fixture = try makeDatabaseDirectory()
        let timestamp = UInt64(now.timeIntervalSince1970) - 3_600
        let row = AntigravityFixtureRow(
            index: 0,
            blob: antigravityGenerationBlob(model: "gemini-3.6-flash", input: 10, output: 5, timestamp: timestamp)
        )
        let sqlite = AntigravityFakeSQLite(rowsByPath: [fixture.path: [row]])
        let first = makeScanner(sqlite: sqlite, fixture: fixture)
        _ = await first.scan(now: now, pricing: pricing)
        XCTAssertEqual(sqlite.queriedCursors.count, 1)

        let repriced = ModelPricing(
            supplement: PricingSupplement(),
            primary: PricingCatalog(entries: [
                "gemini-3.6-flash": ModelRates(
                    inputPerMillion: 9,
                    outputPerMillion: 9,
                    cacheWritePerMillion: 9,
                    cacheReadPerMillion: 9
                )
            ]),
            secondary: PricingCatalog()
        )
        let second = makeScanner(sqlite: sqlite, fixture: fixture)
        let scanResult = await second.scan(now: now, pricing: repriced)
        let scan = try XCTUnwrap(scanResult)
        XCTAssertEqual(scan.series.daily.first?.totalTokens, 15)
        XCTAssertEqual(sqlite.queriedCursors, [-1], "the re-fold must come from persisted events, not a database re-read")
        XCTAssertEqual(sqlite.contentFingerprintQueryCount, 1)

        let record = AntigravityAggregatePersistence.read(path: fixture.path)
        XCTAssertEqual(record?.cache.aggregate?.pricingToken, repriced.aggregateCacheToken)
    }
}
