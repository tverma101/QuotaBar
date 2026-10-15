import XCTest
@testable import QuotaBar

/// Synthetic protobuf fixtures follow FelixIsaac's original regression coverage in openusage#1058.
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

private func antigravityGenerationBlob(
    model: String?,
    input: UInt64,
    output: UInt64,
    cacheRead: UInt64 = 0,
    systemPrompt: UInt64 = 0,
    timestamp: UInt64?
) -> [UInt8] {
    let usage = antigravityVarintField(1, systemPrompt)
        + antigravityVarintField(2, input)
        + antigravityVarintField(3, output)
        + antigravityVarintField(5, cacheRead)

    var event: [UInt8] = []
    if let model {
        event += antigravityBytesField(19, Array(model.utf8))
    }
    event += antigravityBytesField(4, usage)

    if let timestamp {
        let wallClock = antigravityVarintField(1, timestamp)
        event += antigravityBytesField(9, antigravityBytesField(4, wallClock))
    }
    return antigravityBytesField(1, event)
}

private struct AntigravityFixtureRow: Sendable {
    var index: Int
    var blob: [UInt8]?
}

private final class AntigravityFakeSQLite: SQLiteAccessing, @unchecked Sendable {
    private let lock = NSLock()
    private var rowsByPath: [String: [AntigravityFixtureRow]]
    private var cursors: [Int] = []
    private var queryCounts: [String: Int] = [:]
    private var contentFingerprintQueryCount = 0
    let failingPaths: Set<String>
    let cancellingPath: String?
    let cancellingSQLContaining: String?
    let cancellingOnContentFingerprintQuery: Int?

    init(
        rowsByPath: [String: [AntigravityFixtureRow]] = [:],
        failingPaths: Set<String> = [],
        cancellingPath: String? = nil,
        cancellingSQLContaining: String? = nil,
        cancellingOnContentFingerprintQuery: Int? = nil
    ) {
        self.rowsByPath = rowsByPath
        self.failingPaths = failingPaths
        self.cancellingPath = cancellingPath
        self.cancellingSQLContaining = cancellingSQLContaining
        self.cancellingOnContentFingerprintQuery = cancellingOnContentFingerprintQuery
    }

    func queryValue(path: String, sql: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }

        queryCounts[path, default: 0] += 1
        if failingPaths.contains(path) {
            throw SQLiteError.queryFailed("database locked")
        }
        if sql.contains("sha3_agg(") {
            contentFingerprintQueryCount += 1
            if contentFingerprintQueryCount == cancellingOnContentFingerprintQuery {
                withUnsafeCurrentTask { $0?.cancel() }
            }
            let rows = rowsByPath[path, default: []]
                .filter { $0.blob != nil }
                .sorted { $0.index < $1.index }
            let marker = "idx <= "
            guard let range = sql.range(of: marker),
                  let lastCachedIndex = Int(sql[range.upperBound...].split(whereSeparator: \.isWhitespace).first ?? "")
            else {
                throw SQLiteError.queryFailed("missing content fingerprint boundary")
            }
            let maximumIndex = rows.last?.index ?? -1
            let prefix = rows.filter { $0.index <= lastCachedIndex }
            func signature(_ rows: [AntigravityFixtureRow]) -> String {
                rows.map { row in
                    let byteCount = row.blob?.count ?? 0
                    let digest = byteCount <= AntigravityDbUsageScanner.maximumBlobBytes
                        ? row.blob?.map { String(format: "%02x", $0) }.joined() ?? ""
                        : "oversized"
                    return "\(row.index):\(byteCount):\(digest);"
                }.joined()
            }
            return "\(maximumIndex)|\(signature(prefix))|\(signature(rows))"
        }
        if path == cancellingPath || cancellingSQLContaining.map(sql.contains) == true {
            withUnsafeCurrentTask { $0?.cancel() }
        }
        if sql.contains("COALESCE(MAX(idx)") {
            return rowsByPath[path, default: []].filter { $0.blob != nil }.map(\.index).max().map { String($0) } ?? "-1"
        }
        let selectedRows: [AntigravityFixtureRow]
        if let markerRange = sql.range(of: "WHERE idx IN ("),
           let end = sql[markerRange.upperBound...].firstIndex(of: ")") {
            let indices = Set(sql[markerRange.upperBound..<end].split(separator: ",").compactMap {
                Int($0.trimmingCharacters(in: .whitespacesAndNewlines))
            })
            selectedRows = rowsByPath[path, default: []].filter { indices.contains($0.index) }
        } else {
            let marker = "WHERE idx > "
            guard let markerRange = sql.range(of: marker),
                  let cursor = Int(sql[markerRange.upperBound...].split(whereSeparator: \.isWhitespace).first ?? "")
            else {
                throw SQLiteError.queryFailed("missing batch cursor")
            }
            let upperBound = sql.range(of: "AND idx <= ").flatMap { range in
                Int(sql[range.upperBound...].split(whereSeparator: \.isWhitespace).first ?? "")
            }
            if upperBound == nil { cursors.append(cursor) }
            selectedRows = rowsByPath[path, default: []].filter { row in
                row.index > cursor && (upperBound.map { row.index <= $0 } ?? true)
            }
        }

        let rows: [[String: Any]] = selectedRows
            .sorted { $0.index < $1.index }
            .prefix(AntigravityDbUsageScanner.batchSize)
            .map { row in
                let value: Any = row.blob.map { bytes in
                    bytes.map { String(format: "%02x", $0) }.joined()
                } ?? NSNull()
                return [
                    "index": row.index,
                    "bytes": row.blob?.count ?? AntigravityDbUsageScanner.maximumBlobBytes + 1,
                    "hex": value
                ]
            }

        let json = try JSONSerialization.data(withJSONObject: rows)
        return String(decoding: json, as: UTF8.self)
    }

    func append(_ row: AntigravityFixtureRow, to path: String) {
        lock.withLock { rowsByPath[path, default: []].append(row) }
    }

    func replaceRows(_ rows: [AntigravityFixtureRow], at path: String) {
        lock.withLock { rowsByPath[path] = rows }
    }

    func moveRows(from oldPath: String, to newPath: String) {
        lock.withLock {
            rowsByPath[newPath] = rowsByPath.removeValue(forKey: oldPath)
        }
    }

    var queriedCursors: [Int] {
        lock.withLock { cursors }
    }

    var queriedPaths: [String: Int] {
        lock.withLock { queryCounts }
    }

    var contentFingerprintQueries: Int {
        lock.withLock { contentFingerprintQueryCount }
    }

    func execute(path: String, sql: String) throws {}
}

final class AntigravityProtoDecoderTests: XCTestCase {
    func testDecodeVarintsAndRejectMalformedValues() {
        XCTAssertEqual(AntigravityProtoDecoder.decodeVarint([0x05])?.value, 5)
        XCTAssertEqual(AntigravityProtoDecoder.decodeVarint([0xac, 0x02])?.value, 300)
        XCTAssertNil(AntigravityProtoDecoder.decodeVarint([0x80]))
        XCTAssertNil(AntigravityProtoDecoder.decodeVarint(Array(repeating: 0xff, count: 11)))
        XCTAssertNil(AntigravityProtoDecoder.decodeVarint(Array(repeating: 0xff, count: 9) + [0x02]))
    }

    func testMalformedLengthCannotOverflowOrTrap() {
        let validField = antigravityVarintField(1, 42)
        let oversizedLength = antigravityVarint(UInt64(2) << 3 | 2) + antigravityVarint(UInt64.max)
        let fields = validField + oversizedLength

        XCTAssertEqual(AntigravityProtoDecoder.varintField(1, in: fields), 42)
        XCTAssertNil(AntigravityProtoDecoder.bytesField(2, in: fields))
    }

    func testExtractsCompleteGenerationRecord() throws {
        let blob = antigravityGenerationBlob(
            model: "gemini-3.1-pro-low",
            input: 1_000,
            output: 200,
            cacheRead: 50,
            systemPrompt: 1_132,
            timestamp: 1_800_000_000
        )
        let event = try XCTUnwrap(AntigravityProtoDecoder.generationEvent(from: blob))

        XCTAssertEqual(event.model, "gemini-3.1-pro-low")
        XCTAssertEqual(event.inputTokens, 2_132)
        XCTAssertEqual(event.outputTokens, 200)
        XCTAssertEqual(event.cacheReadTokens, 50)
        XCTAssertEqual(event.timestampSeconds, 1_800_000_000)
    }

    func testRejectsMissingTimestampZeroUsageAndUnrepresentableCounts() {
        let missingTimestamp = antigravityGenerationBlob(model: "gemini-3.6-flash", input: 1, output: 0, timestamp: nil)
        let zeroUsage = antigravityGenerationBlob(model: "gemini-3.6-flash", input: 0, output: 0, timestamp: 1_800_000_000)
        let overflowingTokens = antigravityGenerationBlob(model: "gemini-3.6-flash", input: UInt64.max, output: 0, timestamp: 1_800_000_000)
        let overflowingSystemPrompt = antigravityGenerationBlob(
            model: "gemini-3.6-flash", input: UInt64(Int.max), output: 0,
            systemPrompt: 1, timestamp: 1_800_000_000
        )

        XCTAssertNil(AntigravityProtoDecoder.generationEvent(from: missingTimestamp))
        XCTAssertNil(AntigravityProtoDecoder.generationEvent(from: zeroUsage))
        XCTAssertNil(AntigravityProtoDecoder.generationEvent(from: overflowingTokens))
        XCTAssertNil(AntigravityProtoDecoder.generationEvent(from: overflowingSystemPrompt))
        XCTAssertNil(AntigravityProtoDecoder.generationEvent(from: [0xff, 0xff, 0xff]))
    }
}

final class AntigravityDbUsageScannerTests: XCTestCase {
    // Local-anchored: conversation rows are written one hour before this clock and asserted into a *local*
    // calendar day. A UTC-pinned pair only agrees when the suite runs on UTC — at Chatham (+12:45) the
    // 11:00Z row is 23:45 on the following local day, so the provider's spend lands in Yesterday.
    private let now = TestLocalInstant.date(2026, 7, 27, 12)
    private let pricing = ModelPricing(
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

    private func makeDatabaseDirectory(fileNames: [String] = ["conversation.db"]) throws -> (url: URL, paths: [String]) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let paths = try fileNames.map { name in
            let url = directory.appendingPathComponent(name)
            try Data().write(to: url)
            return url.path
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return (directory, paths)
    }

    func testMissingDatabaseDirectoryReturnsNil() async {
        let scanner = AntigravityDbUsageScanner(
            sqlite: AntigravityFakeSQLite(),
            conversationsDirectory: { "/nonexistent-\(UUID().uuidString)" }
        )

        let result = await scanner.scan(now: now, pricing: pricing)
        XCTAssertNil(result)
    }

    func testDiscoversAndAggregatesEveryAntigravityConversationStore() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let geminiRoot = home.appendingPathComponent(".gemini", isDirectory: true)
        try FileManager.default.createDirectory(at: geminiRoot, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }

        let supportedRoots = ["antigravity", "antigravity-acp", "antigravity-cli", "antigravity-ide"]
        let ignoredRoot = "gemini-cli"
        let allRoots = supportedRoots + [ignoredRoot]
        var databaseByRoot: [String: String] = [:]
        for rootName in allRoots {
            let conversations = geminiRoot
                .appendingPathComponent(rootName, isDirectory: true)
                .appendingPathComponent("conversations", isDirectory: true)
            try FileManager.default.createDirectory(at: conversations, withIntermediateDirectories: true)
            let database = conversations.appendingPathComponent("conversation.db")
            try Data().write(to: database)
            databaseByRoot[rootName] = database.path
        }

        let discovered = try AntigravityDbUsageScanner.conversationDirectories(in: geminiRoot)
        let expected = supportedRoots.map {
            geminiRoot.appendingPathComponent($0, isDirectory: true)
                .appendingPathComponent("conversations", isDirectory: true).path
        }.sorted()
        XCTAssertEqual(discovered, expected)

        let timestamp = UInt64(now.timeIntervalSince1970) - 3_600
        let blob = antigravityGenerationBlob(
            model: "gemini-3.6-flash", input: 10, output: 5, timestamp: timestamp
        )
        var rowsByPath = Dictionary(uniqueKeysWithValues: supportedRoots.compactMap { root -> (String, [AntigravityFixtureRow])? in
            databaseByRoot[root].map { ($0, [.init(index: 0, blob: blob)]) }
        })
        rowsByPath[databaseByRoot[ignoredRoot]!] = [.init(
            index: 0,
            blob: antigravityGenerationBlob(model: "gemini-3.6-flash", input: 10_000, output: 0, timestamp: timestamp)
        )]

        let scanner = AntigravityDbUsageScanner(
            sqlite: AntigravityFakeSQLite(rowsByPath: rowsByPath),
            conversationsDirectories: { discovered }
        )
        let scan = await scanner.scan(now: now, pricing: pricing)
        let result = try XCTUnwrap(scan)
        XCTAssertEqual(result.series.daily.first?.totalTokens, supportedRoots.count * 15)
    }

    func testIncompleteConversationStoreScanPreservesLastGoodAggregateAndCache() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let geminiRoot = home.appendingPathComponent(".gemini", isDirectory: true)
        let conversations = ["antigravity", "antigravity-cli"].map {
            geminiRoot.appendingPathComponent($0, isDirectory: true)
                .appendingPathComponent("conversations", isDirectory: true)
        }
        for directory in conversations {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data().write(to: directory.appendingPathComponent("conversation.db"))
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }

        let timestamp = UInt64(now.timeIntervalSince1970) - 3_600
        let blob = antigravityGenerationBlob(
            model: "gemini-3.6-flash", input: 10, output: 5, timestamp: timestamp
        )
        let paths = conversations.map { $0.appendingPathComponent("conversation.db").path }
        let sqlite = AntigravityFakeSQLite(rowsByPath: Dictionary(uniqueKeysWithValues: paths.map {
            ($0, [.init(index: 0, blob: blob)])
        }))
        let scanner = AntigravityDbUsageScanner(
            sqlite: sqlite,
            conversationsDirectories: {
                try AntigravityDbUsageScanner.conversationDirectories(in: geminiRoot)
            }
        )

        let initialResult = await scanner.scan(now: now, pricing: pricing)
        let initial = try XCTUnwrap(initialResult)
        XCTAssertEqual(initial.series.daily.first?.totalTokens, 30)
        let queriesAfterInitial = sqlite.queriedPaths

        let unavailable = conversations[0].deletingLastPathComponent()
        let unavailableDatabase = conversations[1].appendingPathComponent("conversation.db")
        let backup = home.appendingPathComponent("temporarily-unavailable", isDirectory: true)
        try FileManager.default.moveItem(at: unavailable, to: backup)
        let incompleteScan = await scanner.scan(now: now, pricing: pricing)
        let incomplete = try XCTUnwrap(incompleteScan)
        XCTAssertEqual(incomplete.series.daily.first?.totalTokens, 30,
                       "a retired client root should contribute its cached rows while readable roots continue")
        XCTAssertEqual(sqlite.queriedPaths, queriesAfterInitial,
                       "a cached database below a retired root must not be queried at its stale path")

        try FileManager.default.moveItem(at: backup, to: unavailable)
        let recoveredResult = await scanner.scan(now: now, pricing: pricing)
        let recovered = try XCTUnwrap(recoveredResult)
        XCTAssertEqual(recovered.series.daily.first?.totalTokens, 30)
        XCTAssertEqual(sqlite.queriedPaths, queriesAfterInitial, "Recovered scans should reuse both cached databases")

        let databaseBackup = home.appendingPathComponent("temporarily-unavailable.db")
        try FileManager.default.moveItem(at: unavailableDatabase, to: databaseBackup)
        let missingDatabaseQueryCount = sqlite.queriedPaths[unavailableDatabase.path]
        let availableDatabase = conversations[0].appendingPathComponent("conversation.db").path
        sqlite.append(.init(index: 1, blob: antigravityGenerationBlob(
            model: "gemini-3.6-flash", input: 30, output: 0, timestamp: timestamp
        )), to: availableDatabase)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(2)],
            ofItemAtPath: availableDatabase
        )
        let missingDatabaseResult = await scanner.scan(now: now, pricing: pricing)
        let missingDatabase = try XCTUnwrap(missingDatabaseResult)
        XCTAssertEqual(missingDatabase.series.daily.first?.totalTokens, 60,
                       "Keep the absent database's last-good rows while publishing updates from readable stores")
        XCTAssertEqual(sqlite.queriedPaths[unavailableDatabase.path], missingDatabaseQueryCount,
                       "An absent database must not be queried")

        sqlite.append(.init(index: 2, blob: antigravityGenerationBlob(
            model: "gemini-3.6-flash", input: 40, output: 0, timestamp: timestamp
        )), to: availableDatabase)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(3)],
            ofItemAtPath: availableDatabase
        )
        let stillMissingResult = await scanner.scan(now: now, pricing: pricing)
        XCTAssertEqual(try XCTUnwrap(stillMissingResult).series.daily.first?.totalTokens, 100,
                       "A permanently retired database must not freeze history from remaining stores")

        try FileManager.default.moveItem(at: databaseBackup, to: unavailableDatabase)
        let databaseRecoveredResult = await scanner.scan(now: now, pricing: pricing)
        let databaseRecovered = try XCTUnwrap(databaseRecoveredResult)
        XCTAssertEqual(databaseRecovered.series.daily.first?.totalTokens, 100)
        XCTAssertEqual(sqlite.queriedPaths[unavailableDatabase.path], missingDatabaseQueryCount,
                       "A restored database with the same fingerprint should reuse retained history")
    }

    func testConversationRootDiscoveryFailureCannotPublishPartialHistoryOrEvictCache() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let geminiRoot = home.appendingPathComponent(".gemini", isDirectory: true)
        let conversations = geminiRoot
            .appendingPathComponent("antigravity", isDirectory: true)
            .appendingPathComponent("conversations", isDirectory: true)
        try FileManager.default.createDirectory(at: conversations, withIntermediateDirectories: true)
        let database = conversations.appendingPathComponent("conversation.db")
        try Data().write(to: database)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }

        let timestamp = UInt64(now.timeIntervalSince1970) - 3_600
        let blob = antigravityGenerationBlob(
            model: "gemini-3.6-flash", input: 10, output: 5, timestamp: timestamp
        )
        let sqlite = AntigravityFakeSQLite(rowsByPath: [database.path: [.init(index: 0, blob: blob)]])
        let scanner = AntigravityDbUsageScanner(
            sqlite: sqlite,
            conversationsDirectories: {
                try AntigravityDbUsageScanner.conversationDirectories(in: geminiRoot)
            }
        )

        let firstResult = await scanner.scan(now: now, pricing: pricing)
        let first = try XCTUnwrap(firstResult)
        XCTAssertEqual(first.series.daily.first?.totalTokens, 15)
        let queriesAfterInitial = sqlite.queriedPaths[database.path]

        let backup = home.appendingPathComponent("temporarily-unavailable-gemini-root")
        try FileManager.default.moveItem(at: geminiRoot, to: backup)
        try Data().write(to: geminiRoot)
        let incomplete = await scanner.scan(now: now, pricing: pricing)
        XCTAssertNil(incomplete, "A failed root discovery must not publish a partial history result")

        try FileManager.default.removeItem(at: geminiRoot)
        try FileManager.default.moveItem(at: backup, to: geminiRoot)
        let recoveredResult = await scanner.scan(now: now, pricing: pricing)
        let recovered = try XCTUnwrap(recoveredResult)
        XCTAssertEqual(recovered.series.daily.first?.totalTokens, 15)
        XCTAssertEqual(sqlite.queriedPaths[database.path], queriesAfterInitial,
                       "A failed root listing must retain cached rows for recovery")
    }

    func testAccumulatesGenerationTokensCacheReadsAndEstimatedCost() async throws {
        let fixture = try makeDatabaseDirectory()
        let timestamp = UInt64(now.timeIntervalSince1970) - 3_600
        let blob = antigravityGenerationBlob(
            model: "gemini-3.6-flash",
            input: 1_000_000,
            output: 500_000,
            cacheRead: 200_000,
            systemPrompt: 100_000,
            timestamp: timestamp
        )
        let sqlite = AntigravityFakeSQLite(rowsByPath: [fixture.paths[0]: [.init(index: 0, blob: blob)]])
        let scanner = AntigravityDbUsageScanner(sqlite: sqlite, conversationsDirectory: { fixture.url.path })

        let result = await scanner.scan(now: now, pricing: pricing)
        let scan = try XCTUnwrap(result)
        XCTAssertEqual(scan.series.daily.first?.totalTokens, 1_800_000)
        XCTAssertEqual(try XCTUnwrap(scan.series.daily.first?.costUSD), 3.15, accuracy: 0.000_001)
        XCTAssertEqual(scan.modelUsage?.daily.first?.models.first?.model, "gemini-3.6-flash")
    }

    func testScansMultipleBoundedBatches() async throws {
        let fixture = try makeDatabaseDirectory()
        let timestamp = UInt64(now.timeIntervalSince1970) - 3_600
        let blob = antigravityGenerationBlob(model: "gemini-3.6-flash", input: 10, output: 5, timestamp: timestamp)
        let rowCount = AntigravityDbUsageScanner.batchSize * 2 + 1
        let rows = (0..<rowCount).map { AntigravityFixtureRow(index: $0 * 2, blob: blob) }
        let sqlite = AntigravityFakeSQLite(rowsByPath: [fixture.paths[0]: rows])
        let scanner = AntigravityDbUsageScanner(sqlite: sqlite, conversationsDirectory: { fixture.url.path })

        let result = await scanner.scan(now: now, pricing: pricing)
        let scan = try XCTUnwrap(result)
        XCTAssertEqual(scan.series.daily.first?.totalTokens, rowCount * 15)
    }

    func testReusesHistoryAndReadsOnlyRowsAddedToDatabaseOrWAL() async throws {
        let fixture = try makeDatabaseDirectory()
        let timestamp = UInt64(now.timeIntervalSince1970) - 3_600
        let first = antigravityGenerationBlob(model: "gemini-3.6-flash", input: 10, output: 5, timestamp: timestamp)
        let second = antigravityGenerationBlob(model: "gemini-3.6-flash", input: 20, output: 10, timestamp: timestamp)
        let sqlite = AntigravityFakeSQLite(rowsByPath: [fixture.paths[0]: [.init(index: 0, blob: first)]])
        let scanner = AntigravityDbUsageScanner(sqlite: sqlite, conversationsDirectory: { fixture.url.path })

        _ = await scanner.scan(now: now, pricing: pricing)
        _ = await scanner.scan(now: now, pricing: pricing)
        XCTAssertEqual(sqlite.queriedCursors, [-1])

        sqlite.append(.init(index: 1, blob: second), to: fixture.paths[0])
        try Data([1]).write(to: URL(fileURLWithPath: fixture.paths[0]))
        let updated = await scanner.scan(now: now, pricing: pricing)

        XCTAssertEqual(try XCTUnwrap(updated).series.daily.first?.totalTokens, 45)
        XCTAssertEqual(sqlite.queriedCursors, [-1, 0])

        sqlite.append(.init(index: 2, blob: first), to: fixture.paths[0])
        try Data([1]).write(to: URL(fileURLWithPath: fixture.paths[0] + "-wal"))
        let walUpdated = await scanner.scan(now: now, pricing: pricing)

        XCTAssertEqual(try XCTUnwrap(walUpdated).series.daily.first?.totalTokens, 60)
        XCTAssertEqual(sqlite.queriedCursors, [-1, 0, 1])
    }

    func testRenamedDatabaseMovesItsCacheInsteadOfDoubleCounting() async throws {
        let fixture = try makeDatabaseDirectory()
        let oldPath = fixture.paths[0]
        let newPath = fixture.url.appendingPathComponent("renamed.db").path
        let timestamp = UInt64(now.timeIntervalSince1970) - 3_600
        let blob = antigravityGenerationBlob(
            model: "gemini-3.6-flash", input: 10, output: 5, timestamp: timestamp
        )
        let sqlite = AntigravityFakeSQLite(rowsByPath: [oldPath: [.init(index: 0, blob: blob)]])
        let scanner = AntigravityDbUsageScanner(sqlite: sqlite, conversationsDirectory: { fixture.url.path })

        let initialResult = await scanner.scan(now: now, pricing: pricing)
        XCTAssertEqual(try XCTUnwrap(initialResult).series.daily.first?.totalTokens, 15)
        let oldPathQueries = sqlite.queriedPaths[oldPath]

        try FileManager.default.moveItem(atPath: oldPath, toPath: newPath)
        sqlite.moveRows(from: oldPath, to: newPath)
        let renamedResult = await scanner.scan(now: now, pricing: pricing)

        XCTAssertEqual(try XCTUnwrap(renamedResult).series.daily.first?.totalTokens, 15)
        XCTAssertEqual(sqlite.queriedPaths[oldPath], oldPathQueries)
        XCTAssertNil(sqlite.queriedPaths[newPath], "the unchanged database inode should reuse its cache")
    }

    func testSameInodeDatabaseRewriteInvalidatesIncrementalCache() async throws {
        let fixture = try makeDatabaseDirectory()
        let databaseURL = URL(fileURLWithPath: fixture.paths[0])
        let originalRows = [
            AntigravityFixtureRow(
                index: 0,
                blob: antigravityGenerationBlob(
                    model: "gemini-3.6-flash", input: 10, output: 5,
                    timestamp: UInt64(now.timeIntervalSince1970) - 3_600
                )
            ),
            AntigravityFixtureRow(
                index: 1,
                blob: antigravityGenerationBlob(
                    model: "gemini-3.6-flash", input: 20, output: 10,
                    timestamp: UInt64(now.timeIntervalSince1970) - 1_800
                )
            )
        ]
        let replacementRows = [
            AntigravityFixtureRow(
                index: 0,
                blob: antigravityGenerationBlob(
                    model: "gemini-3.6-flash", input: 100, output: 20,
                    timestamp: UInt64(now.timeIntervalSince1970) - 3_600
                )
            ),
            AntigravityFixtureRow(
                index: 1,
                blob: antigravityGenerationBlob(
                    model: "gemini-3.6-flash", input: 200, output: 30,
                    timestamp: UInt64(now.timeIntervalSince1970) - 1_800
                )
            )
        ]
        let sqlite = AntigravityFakeSQLite(rowsByPath: [fixture.paths[0]: originalRows])
        let scanner = AntigravityDbUsageScanner(sqlite: sqlite, conversationsDirectory: { fixture.url.path })
        try Data(repeating: 0x11, count: 512).write(to: databaseURL)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: fixture.paths[0])

        let initialResult = await scanner.scan(now: now, pricing: pricing)
        let initial = try XCTUnwrap(initialResult)
        XCTAssertEqual(initial.series.daily.first?.totalTokens, 45)
        let originalAttributes = try FileManager.default.attributesOfItem(atPath: fixture.paths[0])
        let originalFileNumber = (originalAttributes[.systemFileNumber] as? NSNumber)?.uint64Value
        let originalSize = (originalAttributes[.size] as? NSNumber)?.uint64Value

        sqlite.replaceRows(replacementRows, at: fixture.paths[0])
        let handle = try FileHandle(forWritingTo: databaseURL)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Data(repeating: 0x22, count: 512))
        try handle.truncate(atOffset: 512)
        try handle.close()
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(2)],
            ofItemAtPath: fixture.paths[0]
        )
        let replacementAttributes = try FileManager.default.attributesOfItem(atPath: fixture.paths[0])
        XCTAssertEqual(
            (replacementAttributes[.systemFileNumber] as? NSNumber)?.uint64Value,
            originalFileNumber,
            "the rewrite must preserve the inode"
        )
        XCTAssertGreaterThanOrEqual(
            (replacementAttributes[.size] as? NSNumber)?.uint64Value ?? 0,
            originalSize ?? 0,
            "the rewrite must not look like a database shrink"
        )

        let rewrittenResult = await scanner.scan(now: now, pricing: pricing)
        let rewritten = try XCTUnwrap(rewrittenResult)
        XCTAssertEqual(rewritten.series.daily.first?.totalTokens, 350)
        XCTAssertEqual(sqlite.queriedCursors, [-1, -1], "a generation reset must reread from the beginning")
    }

    func testAppendAndSameInodeMiddleRowRewriteInvalidatesIncrementalCache() async throws {
        let fixture = try makeDatabaseDirectory()
        let databaseURL = URL(fileURLWithPath: fixture.paths[0])
        let originalRows = [
            AntigravityFixtureRow(
                index: 0,
                blob: antigravityGenerationBlob(
                    model: "gemini-3.6-flash", input: 10, output: 5,
                    timestamp: UInt64(now.timeIntervalSince1970) - 5_400
                )
            ),
            AntigravityFixtureRow(
                index: 1,
                blob: antigravityGenerationBlob(
                    model: "gemini-3.6-flash", input: 20, output: 10,
                    timestamp: UInt64(now.timeIntervalSince1970) - 3_600
                )
            ),
            AntigravityFixtureRow(
                index: 2,
                blob: antigravityGenerationBlob(
                    model: "gemini-3.6-flash", input: 30, output: 15,
                    timestamp: UInt64(now.timeIntervalSince1970) - 1_800
                )
            )
        ]
        let appended = antigravityGenerationBlob(
            model: "gemini-3.6-flash", input: 40, output: 20,
            timestamp: UInt64(now.timeIntervalSince1970) - 900
        )
        let replacementRows = [
            originalRows[0],
            AntigravityFixtureRow(
                index: 1,
                blob: antigravityGenerationBlob(
                    model: "gemini-3.6-flash", input: 200, output: 10,
                    timestamp: UInt64(now.timeIntervalSince1970) - 3_600
                )
            ),
            originalRows[2],
            AntigravityFixtureRow(index: 3, blob: appended)
        ]
        let sqlite = AntigravityFakeSQLite(rowsByPath: [fixture.paths[0]: originalRows])
        let scanner = AntigravityDbUsageScanner(sqlite: sqlite, conversationsDirectory: { fixture.url.path })
        try Data(repeating: 0x11, count: 512).write(to: databaseURL)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: fixture.paths[0])

        let initialResult = await scanner.scan(now: now, pricing: pricing)
        let initial = try XCTUnwrap(initialResult)
        XCTAssertEqual(initial.series.daily.first?.totalTokens, 90)

        sqlite.replaceRows(replacementRows, at: fixture.paths[0])
        let handle = try FileHandle(forWritingTo: databaseURL)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Data(repeating: 0x22, count: 512))
        try handle.truncate(atOffset: 512)
        try handle.close()
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(2)],
            ofItemAtPath: fixture.paths[0]
        )

        let rewrittenResult = await scanner.scan(now: now, pricing: pricing)
        let rewritten = try XCTUnwrap(rewrittenResult)
        XCTAssertEqual(rewritten.series.daily.first?.totalTokens, 330)
        XCTAssertEqual(sqlite.queriedCursors, [-1, -1], "a changed cached prefix must be folded again with its appended row")
    }

    func testLargeHistoryAppendUsesOneCompactPrefixFingerprintQuery() async throws {
        let fixture = try makeDatabaseDirectory()
        let databaseURL = URL(fileURLWithPath: fixture.paths[0])
        let rowCount = 512
        let timestamp = UInt64(now.timeIntervalSince1970) - 3_600
        let blob = antigravityGenerationBlob(
            model: "gemini-3.6-flash", input: 10, output: 5, timestamp: timestamp
        )
        let rows = (0..<rowCount).map { AntigravityFixtureRow(index: $0, blob: blob) }
        let sqlite = AntigravityFakeSQLite(rowsByPath: [fixture.paths[0]: rows])
        let scanner = AntigravityDbUsageScanner(sqlite: sqlite, conversationsDirectory: { fixture.url.path })
        try Data(repeating: 0x11, count: 2_048).write(to: databaseURL)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: fixture.paths[0])

        let initialResult = await scanner.scan(now: now, pricing: pricing)
        XCTAssertEqual(try XCTUnwrap(initialResult).series.daily.first?.totalTokens, rowCount * 15)
        let previousQueryCount = sqlite.queriedPaths[fixture.paths[0]] ?? 0
        let previousFingerprintCount = sqlite.contentFingerprintQueries

        sqlite.append(.init(index: rowCount, blob: blob), to: fixture.paths[0])
        let handle = try FileHandle(forWritingTo: databaseURL)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Data(repeating: 0x22, count: 2_048))
        try handle.truncate(atOffset: 2_048)
        try handle.close()
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(2)],
            ofItemAtPath: fixture.paths[0]
        )

        let appendedResult = await scanner.scan(now: now, pricing: pricing)
        XCTAssertEqual(try XCTUnwrap(appendedResult).series.daily.first?.totalTokens, (rowCount + 1) * 15)
        XCTAssertEqual(
            (sqlite.queriedPaths[fixture.paths[0]] ?? 0) - previousQueryCount,
            2,
            "an append should launch one compact prefix verifier and one query for new rows"
        )
        XCTAssertEqual(sqlite.contentFingerprintQueries - previousFingerprintCount, 1)
    }

    func testCancellationDuringCachedPrefixVerificationStopsBeforeReread() async throws {
        let fixture = try makeDatabaseDirectory()
        let timestamp = UInt64(now.timeIntervalSince1970) - 3_600
        let blob = antigravityGenerationBlob(model: "gemini-3.6-flash", input: 10, output: 5, timestamp: timestamp)
        let sqlite = AntigravityFakeSQLite(
            rowsByPath: [fixture.paths[0]: [.init(index: 0, blob: blob)]],
            cancellingOnContentFingerprintQuery: 2
        )
        let scanner = AntigravityDbUsageScanner(sqlite: sqlite, conversationsDirectory: { fixture.url.path })
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: fixture.paths[0])

        let initial = await scanner.scan(now: now, pricing: pricing)
        XCTAssertEqual(try XCTUnwrap(initial).series.daily.first?.totalTokens, 15)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(2)],
            ofItemAtPath: fixture.paths[0]
        )

        let (fixedNow, fixedPricing) = (now, pricing)
        let cancelled = await Task {
            await scanner.scan(now: fixedNow, pricing: fixedPricing)
        }.value

        XCTAssertNil(cancelled)
        XCTAssertEqual(sqlite.queriedPaths[fixture.paths[0]], 3, "cancellation must stop before a full reread")
    }

    func testEvictsConversationHistoryAfterDatabaseAgesOutOfScanWindow() async throws {
        let fixture = try makeDatabaseDirectory()
        let timestamp = UInt64(now.timeIntervalSince1970) - 3_600
        let original = antigravityGenerationBlob(model: "gemini-3.6-flash", input: 10, output: 5, timestamp: timestamp)
        let sqlite = AntigravityFakeSQLite(rowsByPath: [fixture.paths[0]: [.init(index: 0, blob: original)]])
        let scanner = AntigravityDbUsageScanner(sqlite: sqlite, conversationsDirectory: { fixture.url.path })
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: fixture.paths[0])

        _ = await scanner.scan(now: now, pricing: pricing)
        let future = now.addingTimeInterval(31 * 86_400)
        let expired = await scanner.scan(now: future, pricing: pricing)
        XCTAssertNil(expired)

        let recent = antigravityGenerationBlob(
            model: "gemini-3.6-flash", input: 10, output: 5,
            timestamp: UInt64(future.timeIntervalSince1970) - 3_600
        )
        sqlite.append(.init(index: 1, blob: recent), to: fixture.paths[0])
        try FileManager.default.setAttributes([.modificationDate: future], ofItemAtPath: fixture.paths[0])
        let refreshed = await scanner.scan(now: future, pricing: pricing)

        XCTAssertEqual(try XCTUnwrap(refreshed).series.daily.first?.totalTokens, 15)
        XCTAssertEqual(sqlite.queriedCursors, [-1, -1])
    }

    func testUnpricedAndMissingModelsRemainVisibleAsUnknown() async throws {
        let fixture = try makeDatabaseDirectory()
        let timestamp = UInt64(now.timeIntervalSince1970) - 3_600
        let unknown = antigravityGenerationBlob(model: "gemini-9-mystery", input: 100, output: 50, timestamp: timestamp)
        let missing = antigravityGenerationBlob(model: nil, input: 100, output: 50, timestamp: timestamp)
        let expired = antigravityGenerationBlob(
            model: "gemini-3.6-flash", input: 100, output: 50,
            timestamp: UInt64(now.addingTimeInterval(-60 * 86_400).timeIntervalSince1970)
        )
        let sqlite = AntigravityFakeSQLite(rowsByPath: [fixture.paths[0]: [
            .init(index: 0, blob: unknown),
            .init(index: 1, blob: missing),
            .init(index: 2, blob: expired)
        ]])
        let scanner = AntigravityDbUsageScanner(sqlite: sqlite, conversationsDirectory: { fixture.url.path })

        let result = await scanner.scan(now: now, pricing: pricing)
        let scan = try XCTUnwrap(result)
        // Unpriced and missing-name usage keeps counting tokens but claims no cost; the expired
        // generation is outside the window and contributes nothing.
        XCTAssertEqual(scan.series.daily.map(\.totalTokens), [300])
        XCTAssertNil(scan.series.daily.first?.costUSD)
        XCTAssertEqual(
            Set(scan.unknownModelsByDay.values.flatMap { $0 }),
            ["gemini-9-mystery", AntigravityProtoDecoder.GenerationEvent.unknownModel]
        )
    }

    func testOversizedBlobsAreSkippedAndWarnOnlyOnce() async throws {
        let fixture = try makeDatabaseDirectory()
        let recorder = Counter()
        let timestamp = UInt64(now.timeIntervalSince1970) - 3_600
        let valid = antigravityGenerationBlob(model: "gemini-3.6-flash", input: 10, output: 5, timestamp: timestamp)
        let sqlite = AntigravityFakeSQLite(rowsByPath: [fixture.paths[0]: [
            .init(index: 0, blob: nil),
            .init(index: 1, blob: valid)
        ]])
        let scanner = AntigravityDbUsageScanner(
            sqlite: sqlite,
            conversationsDirectory: { fixture.url.path },
            oversizedBlobWarning: { _ in _ = recorder.next() }
        )

        let firstResult = await scanner.scan(now: now, pricing: pricing)
        let secondResult = await scanner.scan(now: now, pricing: pricing)

        let first = try XCTUnwrap(firstResult)
        let second = try XCTUnwrap(secondResult)
        XCTAssertEqual(first.series.daily.first?.totalTokens, 15)
        XCTAssertEqual(second.series.daily.first?.totalTokens, 15)
        XCTAssertEqual(recorder.next(), 1)
    }

    func testUnreadableOrCancelledDatabaseCannotPublishPartialHistory() async throws {
        let fixture = try makeDatabaseDirectory(fileNames: ["a.db", "b.db"])
        let recorder = Counter()
        let timestamp = UInt64(now.timeIntervalSince1970) - 3_600
        let blob = antigravityGenerationBlob(model: "gemini-3.6-flash", input: 10, output: 5, timestamp: timestamp)
        let sqlite = AntigravityFakeSQLite(
            rowsByPath: [fixture.paths[1]: [.init(index: 0, blob: blob)]],
            failingPaths: [fixture.paths[0]]
        )
        let scanner = AntigravityDbUsageScanner(
            sqlite: sqlite,
            conversationsDirectory: { fixture.url.path },
            readFailureWarning: { _ in _ = recorder.next() }
        )

        let firstResult = await scanner.scan(now: now, pricing: pricing)
        let secondResult = await scanner.scan(now: now, pricing: pricing)
        XCTAssertNil(firstResult, "A readable sibling database must not make a failed multi-database scan look complete")
        XCTAssertNil(secondResult, "Repeated read failures must keep returning an incomplete result")
        XCTAssertEqual(recorder.next(), 1)

        let cancellableSQLite = AntigravityFakeSQLite(
            rowsByPath: fixture.paths.reduce(into: [:]) { $0[$1] = [.init(index: 0, blob: blob)] },
            cancellingPath: fixture.paths[1]
        )
        let cancellableScanner = AntigravityDbUsageScanner(
            sqlite: cancellableSQLite, conversationsDirectory: { fixture.url.path }
        )
        let (fixedNow, fixedPricing) = (now, pricing)
        let cancelled = await Task { await cancellableScanner.scan(now: fixedNow, pricing: fixedPricing) }.value
        XCTAssertNil(cancelled)
    }

    func testCancellationDuringCachedEventAggregationCannotPublishPartialHistory() async throws {
        let fixture = try makeDatabaseDirectory()
        let timestamp = UInt64(now.timeIntervalSince1970) - 3_600
        let blob = antigravityGenerationBlob(
            model: "gemini-unknown-cancel-probe", input: 10, output: 5, timestamp: timestamp
        )
        let rows = (0..<16).map { AntigravityFixtureRow(index: $0, blob: blob) }
        let sqlite = AntigravityFakeSQLite(rowsByPath: [fixture.paths[0]: rows])
        let scanner = AntigravityDbUsageScanner(
            sqlite: sqlite,
            conversationsDirectory: { fixture.url.path }
        )
        let cancellingPricing = ModelPricing(
            supplement: pricing.supplement,
            primary: pricing.primary,
            secondary: pricing.secondary,
            openRouter: pricing.openRouter,
            onUnresolvedModel: { _ in withUnsafeCurrentTask { $0?.cancel() } }
        )

        let (fixedNow, fixedPricing) = (now, cancellingPricing)
        let scanTask = Task {
            await scanner.scan(now: fixedNow, pricing: fixedPricing)
        }
        let cancelled = await scanTask.value
        XCTAssertNil(cancelled, "Cancellation during the token fold must preserve the last-good result")
    }

    func testBatchSQLBoundsRowsAndSkipsOversizedBlobsBeforeHexExpansion() {
        let sql = AntigravityDbUsageScanner.dataSQL(after: 42)

        XCTAssertTrue(sql.contains("WHERE idx > 42 AND data IS NOT NULL"))
        XCTAssertTrue(sql.contains("LIMIT \(AntigravityDbUsageScanner.batchSize)"))
        XCTAssertTrue(sql.contains("length(data) <= \(AntigravityDbUsageScanner.maximumBlobBytes)"))
        XCTAssertTrue(sql.contains("THEN hex(data) ELSE NULL"))
    }

    @MainActor
    func testProviderAddsConversationSpendToHistoryAndTotalSpend() async throws {
        let fixture = try makeDatabaseDirectory()
        let fixedNow = now
        let fixedPricing = pricing
        let timestamp = UInt64(fixedNow.timeIntervalSince1970) - 3_600
        let olderDate = try XCTUnwrap(Calendar.current.date(byAdding: .year, value: -1, to: fixedNow))
        let blob = antigravityGenerationBlob(
            model: "gemini-3.6-flash",
            input: 1_000_000,
            output: 500_000,
            timestamp: timestamp
        )
        let olderBlob = antigravityGenerationBlob(
            model: "gemini-3.6-flash",
            input: 400_000,
            output: 100_000,
            timestamp: UInt64(olderDate.timeIntervalSince1970)
        )
        let sqlite = AntigravityFakeSQLite(rowsByPath: [fixture.paths[0]: [
            .init(index: 0, blob: blob),
            .init(index: 1, blob: olderBlob)
        ]])
        let scanner = AntigravityDbUsageScanner(sqlite: sqlite, conversationsDirectory: { fixture.url.path })

        let routing = RoutingHTTPClient { request in
            if request.url.path.contains("retrieveUserQuotaSummary") {
                let response = #"{"groups":[{"buckets":[{"bucketId":"gemini-5h","remainingFraction":0.8}]}]}"#
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(response.utf8))
            }
            return HTTPResponse(statusCode: 404, headers: [:], body: Data())
        }

        let credentials = #"{"token":{"access_token":"ya29.test","refresh_token":"1//test","expiry":"2099-01-01T00:00:00Z"}}"#
        let wrappedCredentials = "go-keyring-base64:" + Data(credentials.utf8).base64EncodedString()
        let provider = AntigravityProvider(
            authStore: AntigravityAuthStore(keychain: FakeKeychain(wrappedCredentials), files: FakeFiles()),
            usageClient: AntigravityUsageClient(lsHTTP: routing, http: routing),
            discovery: LanguageServerDiscovery(processRunner: EmptyProcessRunner()),
            dbUsageScanner: scanner,
            now: { fixedNow },
            pricing: { fixedPricing }
        )

        let snapshot = await provider.refresh()
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.lines.map(\.label), ["Session", "Today", "Last 30 Days", "Usage Trend"])
        let todayKey = DailyUsageAccumulator.dayKey(from: fixedNow)
        let olderDayKey = DailyUsageAccumulator.dayKey(from: olderDate)
        XCTAssertEqual(snapshot.usageHistory?.series.daily.first { $0.date == todayKey }?.totalTokens, 1_500_000)
        XCTAssertEqual(snapshot.usageHistory?.series.daily.first { $0.date == olderDayKey }?.totalTokens, 500_000)
        let last30 = try XCTUnwrap(snapshot.lines.first { $0.label == "Last 30 Days" })
        guard case .values(_, let last30Values, _, _, _, _) = last30 else {
            return XCTFail("Last 30 Days must remain a numeric values row")
        }
        XCTAssertEqual(last30Values.last, MetricValue(number: 1_500_000, kind: .count, label: "tokens"))

        let total = TotalSpendAggregator.total(
            for: .today,
            providers: [provider.provider],
            snapshots: [provider.provider.id: snapshot]
        )
        XCTAssertEqual(total.slices.map(\.provider.id), ["antigravity"])
        XCTAssertEqual(total.totalUSD, 3, accuracy: 0.000_001)
        XCTAssertEqual(total.totalTokens, 1_500_000)
        XCTAssertTrue(total.isEstimated)
    }

    @MainActor
    func testProviderKeepsLocalHistoryWhenCloudQuotaFails() async throws {
        let fixture = try makeDatabaseDirectory()
        let fixedNow = now
        let fixedPricing = pricing
        let timestamp = UInt64(fixedNow.timeIntervalSince1970) - 3_600
        let blob = antigravityGenerationBlob(
            model: "gemini-3.6-flash",
            input: 1_000,
            output: 500,
            timestamp: timestamp
        )
        let sqlite = AntigravityFakeSQLite(rowsByPath: [fixture.paths[0]: [
            .init(index: 0, blob: blob)
        ]])
        let scanner = AntigravityDbUsageScanner(sqlite: sqlite, conversationsDirectory: { fixture.url.path })
        let routing = RoutingHTTPClient { _ in HTTPResponse(statusCode: 503, headers: [:], body: Data()) }
        let credentials = #"{"token":{"access_token":"ya29.test","refresh_token":"1//test","expiry":"2099-01-01T00:00:00Z"}}"#
        let wrappedCredentials = "go-keyring-base64:" + Data(credentials.utf8).base64EncodedString()
        let provider = AntigravityProvider(
            authStore: AntigravityAuthStore(keychain: FakeKeychain(wrappedCredentials), files: FakeFiles()),
            usageClient: AntigravityUsageClient(lsHTTP: routing, http: routing),
            discovery: LanguageServerDiscovery(processRunner: EmptyProcessRunner()),
            dbUsageScanner: scanner,
            now: { fixedNow },
            pricing: { fixedPricing }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .network)
        XCTAssertEqual(snapshot.lines.filter(\.isError).count, snapshot.lines.count)
        XCTAssertEqual(snapshot.usageHistory?.series.daily.first?.totalTokens, 1_500)
    }
}
