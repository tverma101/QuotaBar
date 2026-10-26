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
    timestamp: UInt64?,
    stepUUID: String? = "turn-1",
    botID: String? = "bot-1"
) -> [UInt8] {
    var usage = antigravityVarintField(1, systemPrompt)
        + antigravityVarintField(2, input)
        + antigravityVarintField(3, output)
        + antigravityVarintField(5, cacheRead)
    if let botID { usage += antigravityBytesField(7, Array(botID.utf8)) }

    var event: [UInt8] = []
    if let model {
        event += antigravityBytesField(19, Array(model.utf8))
    }
    event += antigravityBytesField(4, usage)

    if let timestamp {
        let wallClock = antigravityVarintField(1, timestamp)
        event += antigravityBytesField(9, antigravityBytesField(4, wallClock))
    }
    var generation = antigravityBytesField(1, event)
    if let stepUUID { generation += antigravityBytesField(4, Array(stepUUID.utf8)) }
    return generation
}

private func antigravityStepMetadata(
    timestamp: UInt64,
    stepUUID: String? = "turn-1",
    botID: String? = "bot-1"
) -> [UInt8] {
    var metadata = antigravityBytesField(1, antigravityVarintField(1, timestamp))
    if let botID { metadata += antigravityBytesField(9, antigravityBytesField(7, Array(botID.utf8))) }
    if let stepUUID { metadata += antigravityBytesField(12, Array(stepUUID.utf8)) }
    return metadata
}

private struct AntigravityFixtureRow: Sendable {
    var index: Int
    var blob: [UInt8]?
    var stepMetadata: [UInt8]? = nil
}

private final class AntigravityFakeSQLite: SQLiteAccessing, @unchecked Sendable {
    private let lock = NSLock()
    private var rowsByPath: [String: [AntigravityFixtureRow]]
    private var cursors: [Int] = []
    private var stepTimestampCursors: [Int] = []
    private var queryCounts: [String: Int] = [:]
    private var contentFingerprintQueryCount = 0
    private var maximumIndexQueryCount = 0
    private(set) var contentFingerprintSQLs: [String] = []
    private var stepMetadataQueryCount = 0
    let failingPaths: Set<String>
    let failingStepMetadataProbePaths: Set<String>
    let failingStepMetadataOpenPaths: Set<String>
    let transientStepMetadataProbePaths: Set<String>
    let transientStepMetadataTimeoutPaths: Set<String>
    let transientBatchTimeoutPaths: Set<String>
    let unindexedStepMetadataPaths: Set<String>
    private var triggeredTransientStepMetadataFailures: Set<String> = []
    private var triggeredTransientBatchTimeouts: Set<String> = []
    let cancellingPath: String?
    let cancellingSQLContaining: String?
    let throwingCancellationSQLContaining: String?
    let cancellingOnContentFingerprintQuery: Int?
    let touchPathAfterContentFingerprintQuery: Int?
    let unsupportedSHA3: Bool

    init(
        rowsByPath: [String: [AntigravityFixtureRow]] = [:],
        failingPaths: Set<String> = [],
        failingStepMetadataProbePaths: Set<String> = [],
        failingStepMetadataOpenPaths: Set<String> = [],
        transientStepMetadataProbePaths: Set<String> = [],
        transientStepMetadataTimeoutPaths: Set<String> = [],
        transientBatchTimeoutPaths: Set<String> = [],
        unindexedStepMetadataPaths: Set<String> = [],
        cancellingPath: String? = nil,
        cancellingSQLContaining: String? = nil,
        throwingCancellationSQLContaining: String? = nil,
        cancellingOnContentFingerprintQuery: Int? = nil,
        touchPathAfterContentFingerprintQuery: Int? = nil,
        unsupportedSHA3: Bool = false
    ) {
        self.rowsByPath = rowsByPath
        self.failingPaths = failingPaths
        self.failingStepMetadataProbePaths = failingStepMetadataProbePaths
        self.failingStepMetadataOpenPaths = failingStepMetadataOpenPaths
        self.transientStepMetadataProbePaths = transientStepMetadataProbePaths
        self.transientStepMetadataTimeoutPaths = transientStepMetadataTimeoutPaths
        self.transientBatchTimeoutPaths = transientBatchTimeoutPaths
        self.unindexedStepMetadataPaths = unindexedStepMetadataPaths
        self.cancellingPath = cancellingPath
        self.cancellingSQLContaining = cancellingSQLContaining
        self.throwingCancellationSQLContaining = throwingCancellationSQLContaining
        self.cancellingOnContentFingerprintQuery = cancellingOnContentFingerprintQuery
        self.touchPathAfterContentFingerprintQuery = touchPathAfterContentFingerprintQuery
        self.unsupportedSHA3 = unsupportedSHA3
    }

    func queryValue(path: String, sql: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }

        queryCounts[path, default: 0] += 1
        if failingPaths.contains(path) {
            throw SQLiteError.queryFailed("database locked")
        }
        if sql.contains("pragma_table_info('steps')") {
            if transientStepMetadataProbePaths.contains(path),
               triggeredTransientStepMetadataFailures.insert(path).inserted
            {
                throw SQLiteError.queryFailed("database is locked")
            }
            if transientStepMetadataTimeoutPaths.contains(path),
               triggeredTransientStepMetadataFailures.insert(path).inserted
            {
                throw SQLiteError.queryFailed("/usr/bin/sqlite3 timed out after 5s.")
            }
            if failingStepMetadataProbePaths.contains(path) {
                throw SQLiteError.queryFailed("no such table: pragma_table_info")
            }
            if failingStepMetadataOpenPaths.contains(path) {
                throw SQLiteError.queryFailed("unable to open database file")
            }
            if unindexedStepMetadataPaths.contains(path) { return nil }
            return rowsByPath[path, default: []].contains { $0.stepMetadata != nil } ? "1" : nil
        }
        if sql.contains("step_timestamp_digest") {
            if unsupportedSHA3 { throw SQLiteError.queryFailed("no such function: sha3_agg") }
            let range = sql.range(of: "idx <= ")!
            let through = Int(sql[range.upperBound...].split(whereSeparator: \.isWhitespace).first!)!
            let steps = rowsByPath[path, default: []].filter { $0.stepMetadata != nil }.sorted { $0.index < $1.index }
            func signature(_ rows: [AntigravityFixtureRow]) -> String {
                rows.map { "\($0.index):" + $0.stepMetadata!.map { String(format: "%02x", $0) }.joined() }.joined(separator: ";")
            }
            return signature(steps.filter { $0.index <= through }) + "|" + signature(steps)
        }
        if sql.contains("sha3_agg(") {
            contentFingerprintQueryCount += 1
            contentFingerprintSQLs.append(sql)
            if unsupportedSHA3 {
                throw SQLiteError.queryFailed("no such function: sha3_agg")
            }
            if contentFingerprintQueryCount == cancellingOnContentFingerprintQuery {
                withUnsafeCurrentTask { $0?.cancel() }
            }
            let rows = rowsByPath[path, default: []]
                .sorted { $0.index < $1.index }
            let maximumIndex = rows.last?.index ?? -1
            let prefix: [AntigravityFixtureRow]
            if let range = sql.range(of: "idx <= "),
               let lastCachedIndex = Int(sql[range.upperBound...].split(whereSeparator: \.isWhitespace).first ?? "") {
                prefix = rows.filter { $0.index <= lastCachedIndex }
            } else {
                prefix = rows
            }
            func signature(_ rows: [AntigravityFixtureRow]) -> String {
                rows.map { row in
                    let byteCount = row.blob?.count ?? 0
                    let digest = byteCount <= AntigravityDbUsageScanner.maximumBlobBytes
                        ? row.blob?.map { String(format: "%02x", $0) }.joined() ?? ""
                        : "oversized"
                    return "\(row.index):\(byteCount):\(digest);"
                }.joined()
            }
            let result = "\(maximumIndex)|\(signature(prefix))|\(signature(rows))"
            if contentFingerprintQueryCount == touchPathAfterContentFingerprintQuery {
                let modifiedAt = ((try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date)
                    ?? Date()
                try? FileManager.default.setAttributes(
                    [.modificationDate: modifiedAt.addingTimeInterval(2)],
                    ofItemAtPath: path
                )
            }
            return result
        }
        if sql.contains("WITH candidates AS"),
           transientBatchTimeoutPaths.contains(path),
           triggeredTransientBatchTimeouts.insert(path).inserted
        {
            throw ProcessRunnerError.timedOut(executable: "/usr/bin/sqlite3", timeout: 5)
        }
        if path == cancellingPath || cancellingSQLContaining.map(sql.contains) == true {
            withUnsafeCurrentTask { $0?.cancel() }
        }
        if throwingCancellationSQLContaining.map(sql.contains) == true {
            withUnsafeCurrentTask { $0?.cancel() }
            throw CancellationError()
        }
        if sql.contains("COALESCE(MAX(idx)") {
            maximumIndexQueryCount += 1
            return rowsByPath[path, default: []].map(\.index).max().map { String($0) } ?? "-1"
        }
        if sql.contains("step_timestamp_candidates") {
            let marker = "WHERE idx > "
            let range = sql.range(of: marker)!
            let cursor = Int(sql[range.upperBound...].split(whereSeparator: \.isWhitespace).first!)!
            stepTimestampCursors.append(cursor)
            let rows: [[String: Any]] = rowsByPath[path, default: []]
                .filter { $0.index > cursor && $0.stepMetadata != nil }
                .sorted { $0.index < $1.index }.prefix(128)
                .map { row in ["index": row.index, "hex": row.stepMetadata!.map { String(format: "%02x", $0) }.joined()] }
            return String(decoding: try JSONSerialization.data(withJSONObject: rows), as: UTF8.self)
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
                var output: [String: Any] = [
                    "index": row.index,
                    "bytes": row.blob?.count ?? AntigravityDbUsageScanner.maximumBlobBytes + 1,
                    "hex": value
                ]
                if sql.contains("'step_hex'") {
                    stepMetadataQueryCount += 1
                    output["step_hex"] = row.stepMetadata.map { bytes in
                        bytes.map { String(format: "%02x", $0) }.joined()
                    } ?? NSNull()
                }
                return output
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

    var queriedStepTimestampCursors: [Int] { lock.withLock { stepTimestampCursors } }

    var queriedPaths: [String: Int] {
        lock.withLock { queryCounts }
    }

    var contentFingerprintQueries: Int {
        lock.withLock { contentFingerprintQueryCount }
    }

    var maximumIndexQueries: Int {
        lock.withLock { maximumIndexQueryCount }
    }

    var stepMetadataQueries: Int {
        lock.withLock { stepMetadataQueryCount }
    }

    func execute(path: String, sql: String) throws {}
}

private final class AntigravityPricingRecheckCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func record() {
        lock.withLock { count += 1 }
    }
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

    func testExtractsGenerationTimestampFromCorrelatedStepMetadata() throws {
        let blob = antigravityGenerationBlob(
            model: "gemini-3.6-flash",
            input: 1_000,
            output: 200,
            timestamp: nil
        )
        let stepMetadata = antigravityStepMetadata(timestamp: 1_800_000_000)

        let event = try XCTUnwrap(AntigravityProtoDecoder.generationEvent(from: blob, stepMetadata: stepMetadata))

        XCTAssertEqual(event.model, "gemini-3.6-flash")
        XCTAssertEqual(event.inputTokens, 1_000)
        XCTAssertEqual(event.outputTokens, 200)
        XCTAssertEqual(event.timestampSeconds, 1_800_000_000)
    }

    func testRejectsStepTimestampWhenGenerationIdentityDoesNotMatch() {
        let blob = antigravityGenerationBlob(
            model: "gemini-3.6-flash",
            input: 1_000,
            output: 200,
            timestamp: nil
        )

        let wrongStep = antigravityStepMetadata(timestamp: 1_800_000_000, stepUUID: "other-turn")
        let wrongBot = antigravityStepMetadata(timestamp: 1_800_000_000, botID: "other-bot")
        let missingIdentifiers = antigravityBytesField(1, antigravityVarintField(1, 1_800_000_000))

        XCTAssertEqual(AntigravityProtoDecoder.decodeGenerationEvent(from: blob, stepMetadata: wrongStep), .undatedUsage)
        XCTAssertEqual(AntigravityProtoDecoder.decodeGenerationEvent(from: blob, stepMetadata: wrongBot), .undatedUsage)
        XCTAssertEqual(AntigravityProtoDecoder.decodeGenerationEvent(from: blob, stepMetadata: missingIdentifiers), .undatedUsage)
    }

    func testStepTimestampFallsBackWhenBothFormatsOmitIdentifiers() throws {
        let timestamp: UInt64 = 1_800_000_000
        let blob = antigravityGenerationBlob(
            model: "gemini-3.6-flash",
            input: 1_000,
            output: 200,
            timestamp: nil,
            stepUUID: nil,
            botID: nil
        )
        let stepMetadata = antigravityStepMetadata(timestamp: timestamp, stepUUID: nil, botID: nil)

        let event = try XCTUnwrap(AntigravityProtoDecoder.generationEvent(from: blob, stepMetadata: stepMetadata))

        XCTAssertEqual(event.timestampSeconds, Int64(timestamp))
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

    func testListedDirectoryWithoutDatabasesDoesNotClearLastGoodHistory() async throws {
        let fixture = try makeDatabaseDirectory(fileNames: [])
        let scanner = AntigravityDbUsageScanner(
            sqlite: AntigravityFakeSQLite(),
            conversationsDirectory: { fixture.url.path }
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

    func testScannerReadsModernGenerationTimestampsFromStepMetadata() async throws {
        let fixture = try makeDatabaseDirectory()
        let timestamp = UInt64(now.timeIntervalSince1970) - 3_600
        let row = AntigravityFixtureRow(
            index: 0,
            blob: antigravityGenerationBlob(
                model: "gemini-3.6-flash",
                input: 10,
                output: 5,
                timestamp: nil
            ),
            stepMetadata: antigravityStepMetadata(timestamp: timestamp)
        )
        let sqlite = AntigravityFakeSQLite(rowsByPath: [fixture.paths[0]: [row]])
        let scanner = AntigravityDbUsageScanner(sqlite: sqlite, conversationsDirectory: { fixture.url.path })

        let scan = await scanner.scan(now: now, pricing: pricing)
        let result = try XCTUnwrap(scan)

        XCTAssertEqual(result.series.daily.first?.totalTokens, 15)
        XCTAssertGreaterThan(sqlite.stepMetadataQueries, 0, "The generation query must include correlated step metadata")
    }

    func testUntrustedStepTimestampDoesNotInventUsageOnFirstObservedDay() async throws {
        let fixture = try makeDatabaseDirectory()
        let observedTimestamp = Int64(now.timeIntervalSince1970)
        let blob = antigravityGenerationBlob(
            model: "gemini-3.6-flash",
            input: 1_000,
            output: 200,
            timestamp: nil
        )
        let mismatchedStep = antigravityStepMetadata(
            timestamp: UInt64(observedTimestamp - 3_600),
            stepUUID: "different-turn"
        )
        let sqlite = AntigravityFakeSQLite(rowsByPath: [fixture.paths[0]: [
            .init(index: 0, blob: blob, stepMetadata: mismatchedStep)
        ]])
        let scanner = AntigravityDbUsageScanner(sqlite: sqlite, conversationsDirectory: { fixture.url.path })

        let result = await scanner.scan(now: now, pricing: pricing)
        let scan = try XCTUnwrap(result)

        XCTAssertTrue(scan.series.daily.isEmpty)
        XCTAssertEqual(scan.unmeasuredUsageDays, [DailyUsageAccumulator.dayKey(from: now)])
    }

    func testGenerationMatchesStepIdentityAcrossDifferentRowIndicesAndRecoversEditedDates() async throws {
        let fixture = try makeDatabaseDirectory()
        let yesterday = now.addingTimeInterval(-86_400)
        let blob = antigravityGenerationBlob(model: "gemini-3.6-flash", input: 100, output: 20, timestamp: nil)
        let sqlite = AntigravityFakeSQLite(rowsByPath: [fixture.paths[0]: [
            .init(index: 0, blob: blob),
            .init(index: 10, blob: nil, stepMetadata: antigravityStepMetadata(timestamp: UInt64(yesterday.timeIntervalSince1970)))
        ]])
        let scanner = AntigravityDbUsageScanner(sqlite: sqlite, conversationsDirectory: { fixture.url.path })
        let first = await scanner.scan(now: now, pricing: pricing)
        XCTAssertEqual(first?.series.daily.first?.date, DailyUsageAccumulator.dayKey(from: yesterday))
        XCTAssertEqual(first?.series.daily.first?.totalTokens, 120)

        sqlite.replaceRows([
            .init(index: 0, blob: blob),
            .init(index: 10, blob: nil, stepMetadata: antigravityStepMetadata(timestamp: UInt64(now.timeIntervalSince1970)))
        ], at: fixture.paths[0])
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(2)], ofItemAtPath: fixture.paths[0])
        let updated = await scanner.scan(now: now, pricing: pricing)
        XCTAssertEqual(updated?.series.daily.first?.date, DailyUsageAccumulator.dayKey(from: now))
        XCTAssertEqual(updated?.series.daily.first?.totalTokens, 120)
    }

    func testRepeatedStepIdentityRetainsProvenDayAndRejectsConflictingDays() throws {
        let timestamp = UInt64(TestLocalInstant.date(2026, 10, 20, 12).timeIntervalSince1970)
        let generation = antigravityGenerationBlob(model: "gemini-3.6-flash", input: 10, output: 2, timestamp: nil)
        var index = AntigravityStepTimestampIndex()
        try index.insert(antigravityStepMetadata(timestamp: timestamp), maximumEstimatedMemoryBytes: 64 * 1024 * 1024)
        try index.insert(antigravityStepMetadata(timestamp: timestamp + 60), maximumEstimatedMemoryBytes: 64 * 1024 * 1024)
        XCTAssertEqual(index.timestamp(for: generation), Int64(timestamp))
        try index.insert(antigravityStepMetadata(timestamp: timestamp + 86_400), maximumEstimatedMemoryBytes: 64 * 1024 * 1024)
        XCTAssertNil(index.timestamp(for: generation), "conflicting calendar days must not be guessed")
    }

    func testStepTimestampIndexReadsOnlyAppendedMetadataAfterVerifyingPrefix() throws {
        let timestamp = UInt64(now.timeIntervalSince1970)
        let sqlite = AntigravityFakeSQLite(rowsByPath: ["/steps.db": [
            .init(index: 10, blob: nil, stepMetadata: antigravityStepMetadata(timestamp: timestamp))
        ]])
        let first = try AntigravityStepTimestampIndex.load(path: "/steps.db", sqlite: sqlite)
        sqlite.append(.init(index: 11, blob: nil, stepMetadata:
            antigravityStepMetadata(timestamp: timestamp, stepUUID: "other-turn", botID: "other-bot")), to: "/steps.db")
        let next = try AntigravityStepTimestampIndex.load(path: "/steps.db", sqlite: sqlite, previous: first)
        XCTAssertTrue(next.preserves(first))
        XCTAssertEqual(sqlite.queriedStepTimestampCursors, [-1, 10, 10, 11])
    }

    func testUnrelatedStepAppendDoesNotReplayUndatedGenerationsButMatchingStepDoes() async throws {
        let fixture = try makeDatabaseDirectory()
        let timestamp = UInt64(now.timeIntervalSince1970)
        let blob = antigravityGenerationBlob(model: "gemini-3.6-flash", input: 10, output: 2, timestamp: nil)
        let sqlite = AntigravityFakeSQLite(rowsByPath: [fixture.paths[0]: [
            .init(index: 0, blob: blob),
            .init(index: 10, blob: nil, stepMetadata:
                antigravityStepMetadata(timestamp: timestamp, stepUUID: "other", botID: "other"))
        ]])
        let scanner = AntigravityDbUsageScanner(sqlite: sqlite, conversationsDirectory: { fixture.url.path })
        _ = await scanner.scan(now: now, pricing: pricing)
        sqlite.append(.init(index: 11, blob: nil, stepMetadata:
            antigravityStepMetadata(timestamp: timestamp, stepUUID: "unrelated", botID: "unrelated")), to: fixture.paths[0])
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(2)], ofItemAtPath: fixture.paths[0])
        _ = await scanner.scan(now: now, pricing: pricing)
        XCTAssertEqual(sqlite.queriedCursors, [-1, 10], "an unrelated step must not replay the old generations")
        sqlite.append(.init(index: 12, blob: nil, stepMetadata: antigravityStepMetadata(timestamp: timestamp)), to: fixture.paths[0])
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(4)], ofItemAtPath: fixture.paths[0])
        let recovered = await scanner.scan(now: now, pricing: pricing)
        XCTAssertEqual(recovered?.series.daily.first?.totalTokens, 12)
        XCTAssertEqual(sqlite.queriedCursors.last, -1, "a newly available matching date must recover the old generation")
    }

    func testStepTimestampIndexPagesRealSQLiteWithoutRelyingOnGenerationIndices() throws {
        let fixture = try makeDatabaseDirectory()
        let timestamp = UInt64(now.timeIntervalSince1970)
        let metadata = antigravityStepMetadata(timestamp: timestamp).map { String(format: "%02x", $0) }.joined()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [fixture.paths[0], "CREATE TABLE steps(idx INTEGER PRIMARY KEY, metadata BLOB); " +
            "WITH RECURSIVE rows(n) AS (SELECT 0 UNION ALL SELECT n+1 FROM rows WHERE n<129) " +
            "INSERT INTO steps SELECT n, X'\(metadata)' FROM rows;"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: data, as: UTF8.self))
        let index = try AntigravityStepTimestampIndex.load(path: fixture.paths[0], sqlite: SQLiteCLIAccessor())
        let generation = antigravityGenerationBlob(model: "gemini-3.6-flash", input: 10, output: 2, timestamp: nil)
        XCTAssertEqual(index.timestamp(for: generation), Int64(timestamp))
    }

    func testOversizedBlobWithStepTimestampPublishesLowerBoundHistory() async throws {
        let fixture = try makeDatabaseDirectory()
        let timestamp = UInt64(now.timeIntervalSince1970) - 2 * 86_400
        let valid = antigravityGenerationBlob(
            model: "gemini-3.6-flash", input: 10, output: 5, timestamp: timestamp
        )
        let sqlite = AntigravityFakeSQLite(rowsByPath: [fixture.paths[0]: [
            .init(index: 0, blob: nil, stepMetadata: antigravityStepMetadata(timestamp: timestamp)),
            .init(index: 1, blob: valid)
        ]])
        let scanner = AntigravityDbUsageScanner(sqlite: sqlite, conversationsDirectory: { fixture.url.path })

        let result = await scanner.scan(now: now, pricing: pricing)
        let scan = try XCTUnwrap(result)

        XCTAssertEqual(scan.series.daily.first?.totalTokens, 15)
        XCTAssertEqual(scan.unmeasuredUsageDays, [DailyUsageAccumulator.dayKey(from: now)])
    }

    func testCompletedEmptyDatabaseScanReturnsAuthoritativeEmptyHistory() async throws {
        let fixture = try makeDatabaseDirectory()
        let scanner = AntigravityDbUsageScanner(
            sqlite: AntigravityFakeSQLite(),
            conversationsDirectory: { fixture.url.path }
        )

        let result = await scanner.scan(now: now, pricing: pricing)
        let scan = try XCTUnwrap(result)

        XCTAssertTrue(scan.series.daily.isEmpty)
        XCTAssertTrue(scan.unknownModelsByDay.isEmpty)
    }

    func testCachedDatabaseAggregateSkipsRepricingButInvalidatesWhenRatesChange() async throws {
        let fixture = try makeDatabaseDirectory()
        let timestamp = UInt64(now.timeIntervalSince1970) - 3_600
        let model = "gemini-cache-invalidation-test"
        let blob = antigravityGenerationBlob(model: model, input: 1_000, output: 1_000, timestamp: timestamp)
        let sqlite = AntigravityFakeSQLite(rowsByPath: [fixture.paths[0]: [.init(index: 0, blob: blob)]])
        let scanner = AntigravityDbUsageScanner(sqlite: sqlite, conversationsDirectory: { fixture.url.path })
        let emptySupplement = PricingSupplement()
        let emptyCatalog = PricingCatalog()
        let unknownPricing = ModelPricing(
            supplement: emptySupplement,
            primary: emptyCatalog,
            secondary: PricingCatalog()
        )
        let recheckCounter = AntigravityPricingRecheckCounter()
        let equivalentPricing = ModelPricing(
            supplement: emptySupplement,
            primary: emptyCatalog,
            secondary: PricingCatalog(),
            onOpenRouterRecheckModel: { _ in recheckCounter.record() }
        )

        let firstResult = await scanner.scan(now: now, pricing: unknownPricing)
        let first = try XCTUnwrap(firstResult)
        let reusedResult = await scanner.scan(now: now, pricing: equivalentPricing)
        let reused = try XCTUnwrap(reusedResult)

        XCTAssertEqual(first.unknownModelsByDay, reused.unknownModelsByDay)
        XCTAssertEqual(recheckCounter.value, 0, "An unchanged database and pricing token should reuse the priced aggregate")

        let priced = ModelPricing(
            supplement: emptySupplement,
            primary: PricingCatalog(entries: [model: ModelRates(
                inputPerMillion: 1,
                outputPerMillion: 2,
                cacheWritePerMillion: 0,
                cacheReadPerMillion: 0
            )]),
            secondary: PricingCatalog()
        )
        let repricedResult = await scanner.scan(now: now, pricing: priced)
        let repriced = try XCTUnwrap(repricedResult)

        XCTAssertTrue(repriced.unknownModelsByDay.isEmpty)
        XCTAssertGreaterThan(repriced.series.daily.first?.costUSD ?? 0, 0)
    }

    func testCachedDatabaseAggregateTrimsAtMidnightWithoutRepricing() async throws {
        let fixture = try makeDatabaseDirectory()
        let timestamp = UInt64(now.timeIntervalSince1970) - 3_600
        let model = "gemini-midnight-cache-test"
        let blob = antigravityGenerationBlob(model: model, input: 1_000, output: 1_000, timestamp: timestamp)
        let sqlite = AntigravityFakeSQLite(rowsByPath: [fixture.paths[0]: [.init(index: 0, blob: blob)]])
        let scanner = AntigravityDbUsageScanner(sqlite: sqlite, conversationsDirectory: { fixture.url.path })
        let emptySupplement = PricingSupplement()
        let emptyCatalog = PricingCatalog()
        let firstPricing = ModelPricing(
            supplement: emptySupplement,
            primary: emptyCatalog,
            secondary: PricingCatalog()
        )
        let recheckCounter = AntigravityPricingRecheckCounter()
        let equivalentPricing = ModelPricing(
            supplement: emptySupplement,
            primary: emptyCatalog,
            secondary: PricingCatalog(),
            onOpenRouterRecheckModel: { _ in recheckCounter.record() }
        )

        let initialResult = await scanner.scan(now: now, pricing: firstPricing)
        let initial = try XCTUnwrap(initialResult)
        let nextDay = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 1, to: now))
        let rolledResult = await scanner.scan(now: nextDay, pricing: equivalentPricing)
        let rolled = try XCTUnwrap(rolledResult)

        XCTAssertEqual(rolled.series.daily.map(\.totalTokens), initial.series.daily.map(\.totalTokens))
        XCTAssertEqual(recheckCounter.value, 0, "rolling the lifetime window drops expired days without repricing")
        XCTAssertEqual(sqlite.queriedPaths[fixture.paths[0]], 3,
                       "an unchanged database is not queried again at the day boundary")
    }

    func testStepMetadataProbeFailureFallsBackToGenerationTimestamp() async throws {
        let fixture = try makeDatabaseDirectory()
        let timestamp = UInt64(now.timeIntervalSince1970) - 3_600
        let blob = antigravityGenerationBlob(
            model: "gemini-3.6-flash", input: 10, output: 5, timestamp: timestamp
        )
        let sqlite = AntigravityFakeSQLite(
            rowsByPath: [fixture.paths[0]: [.init(index: 0, blob: blob)]],
            failingStepMetadataProbePaths: [fixture.paths[0]]
        )
        let scanner = AntigravityDbUsageScanner(sqlite: sqlite, conversationsDirectory: { fixture.url.path })

        let resultValue = await scanner.scan(now: now, pricing: pricing)
        let result = try XCTUnwrap(resultValue)
        XCTAssertEqual(result.series.daily.first?.totalTokens, 15)
    }

    func testStepMetadataProbeRetriesTransientLockBeforeFallingBack() async throws {
        let fixture = try makeDatabaseDirectory()
        let timestamp = UInt64(now.timeIntervalSince1970) - 3_600
        let stepOnlyBlob = antigravityGenerationBlob(
            model: "gemini-3.6-flash", input: 10, output: 5, timestamp: nil
        )
        let sqlite = AntigravityFakeSQLite(
            rowsByPath: [fixture.paths[0]: [
                .init(index: 0, blob: stepOnlyBlob, stepMetadata: antigravityStepMetadata(timestamp: timestamp))
            ]],
            transientStepMetadataProbePaths: [fixture.paths[0]]
        )
        let scanner = AntigravityDbUsageScanner(sqlite: sqlite, conversationsDirectory: { fixture.url.path })

        let scan = await scanner.scan(now: now, pricing: pricing)
        let result = try XCTUnwrap(scan)

        XCTAssertEqual(result.series.daily.first?.totalTokens, 15)
        XCTAssertNil(result.unmeasuredUsageDays)
        XCTAssertGreaterThanOrEqual(sqlite.queriedPaths[fixture.paths[0]] ?? 0, 4)
    }

    func testStepMetadataProbeRetriesSubprocessTimeout() async throws {
        let fixture = try makeDatabaseDirectory()
        let timestamp = UInt64(now.timeIntervalSince1970) - 3_600
        let blob = antigravityGenerationBlob(
            model: "gemini-3.6-flash", input: 10, output: 5, timestamp: timestamp
        )
        let sqlite = AntigravityFakeSQLite(
            rowsByPath: [fixture.paths[0]: [.init(index: 0, blob: blob)]],
            transientStepMetadataTimeoutPaths: [fixture.paths[0]]
        )
        let scanner = AntigravityDbUsageScanner(sqlite: sqlite, conversationsDirectory: { fixture.url.path })

        let result = await scanner.scanWithStatus(now: now, pricing: pricing)

        XCTAssertFalse(result.hasReadFailures)
        XCTAssertEqual(result.scan?.series.daily.first?.totalTokens, 15)
    }

    func testGenerationBatchRetriesRawSubprocessTimeout() async throws {
        let fixture = try makeDatabaseDirectory()
        let blob = antigravityGenerationBlob(
            model: "gemini-3.6-flash", input: 10, output: 5,
            timestamp: UInt64(now.timeIntervalSince1970) - 3_600
        )
        let sqlite = AntigravityFakeSQLite(
            rowsByPath: [fixture.paths[0]: [.init(index: 0, blob: blob)]],
            transientBatchTimeoutPaths: [fixture.paths[0]]
        )
        let scanner = AntigravityDbUsageScanner(sqlite: sqlite, conversationsDirectory: { fixture.url.path })

        let result = await scanner.scanWithStatus(now: now, pricing: pricing)

        XCTAssertFalse(result.hasReadFailures)
        XCTAssertEqual(result.scan?.series.daily.first?.totalTokens, 15)
    }

    func testStepMetadataProbeOpenFailureIsNotTreatedAsAnOldSchema() async throws {
        let fixture = try makeDatabaseDirectory()
        let blob = antigravityGenerationBlob(
            model: "gemini-3.6-flash", input: 10, output: 5, timestamp: nil
        )
        let sqlite = AntigravityFakeSQLite(
            rowsByPath: [fixture.paths[0]: [.init(index: 0, blob: blob)]],
            failingStepMetadataOpenPaths: [fixture.paths[0]]
        )
        let scanner = AntigravityDbUsageScanner(sqlite: sqlite, conversationsDirectory: { fixture.url.path })

        let result = await scanner.scanWithStatus(now: now, pricing: pricing)

        XCTAssertTrue(result.hasReadFailures)
        XCTAssertNil(result.scan, "An open failure must preserve last-good history instead of silently dropping step timestamps")
    }

    func testUnindexedStepMetadataIsSkippedToAvoidRepeatedTableScans() async throws {
        let fixture = try makeDatabaseDirectory()
        let sqlite = AntigravityFakeSQLite(
            rowsByPath: [fixture.paths[0]: [
                .init(
                    index: 0,
                    blob: antigravityGenerationBlob(
                        model: "gemini-3.6-flash", input: 10, output: 5, timestamp: nil
                    ),
                    stepMetadata: antigravityStepMetadata(timestamp: UInt64(now.timeIntervalSince1970) - 3_600)
                )
            ]],
            unindexedStepMetadataPaths: [fixture.paths[0]]
        )
        let scanner = AntigravityDbUsageScanner(sqlite: sqlite, conversationsDirectory: { fixture.url.path })

        let result = await scanner.scanWithStatus(now: now, pricing: pricing)

        XCTAssertFalse(result.hasReadFailures)
        XCTAssertTrue(result.scan?.series.daily.isEmpty == true,
                      "a missing trusted date must not invent today's usage")
        XCTAssertEqual(result.scan?.unmeasuredUsageDays, [DailyUsageAccumulator.dayKey(from: now)])
        XCTAssertEqual(sqlite.stepMetadataQueries, 0)
    }

    func testAllUnreadableDatabasesReturnReadFailureStatusWithoutCachedHistory() async throws {
        let fixture = try makeDatabaseDirectory()
        let scanner = AntigravityDbUsageScanner(
            sqlite: AntigravityFakeSQLite(failingPaths: [fixture.paths[0]]),
            conversationsDirectory: { fixture.url.path }
        )

        let result = await scanner.scanWithStatus(now: now, pricing: pricing)

        XCTAssertNil(result.scan)
        XCTAssertTrue(result.hasReadFailures)
    }

    func testDiscoveryContinuesAfterOneConversationRootStatFails() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let geminiRoot = home.appendingPathComponent(".gemini", isDirectory: true)
        let failedConversations = geminiRoot
            .appendingPathComponent("antigravity-broken", isDirectory: true)
            .appendingPathComponent("conversations", isDirectory: true)
        let readableConversations = geminiRoot
            .appendingPathComponent("antigravity-working", isDirectory: true)
            .appendingPathComponent("conversations", isDirectory: true)
        try FileManager.default.createDirectory(at: failedConversations, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: readableConversations, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }

        let discovery = try AntigravityDbUsageScanner.discoverConversationDirectories(in: geminiRoot) { path in
            if path == failedConversations.path {
                throw NSError(domain: "AntigravityDiscoveryTests", code: 1)
            }
            return try FileManager.default.attributesOfItem(atPath: path)
        }

        XCTAssertEqual(discovery.directories, [readableConversations.path])
        XCTAssertEqual(Set(discovery.failures.keys), [failedConversations.path])
    }

    func testSmallGenerationRowsUseBoundedHighCapacityBatches() async throws {
        let fixture = try makeDatabaseDirectory()
        let timestamp = UInt64(now.timeIntervalSince1970) - 3_600
        let blob = antigravityGenerationBlob(
            model: "gemini-3.6-flash", input: 10, output: 5, timestamp: timestamp
        )
        let rows = (0..<300).map { AntigravityFixtureRow(index: $0, blob: blob) }
        let sqlite = AntigravityFakeSQLite(rowsByPath: [fixture.paths[0]: rows])
        let scanner = AntigravityDbUsageScanner(sqlite: sqlite, conversationsDirectory: { fixture.url.path })

        let scan = await scanner.scan(now: now, pricing: pricing)
        let result = try XCTUnwrap(scan)

        XCTAssertEqual(result.series.daily.first?.totalTokens, 4_500)
        XCTAssertLessThan(sqlite.queriedPaths[fixture.paths[0]] ?? .max, 10,
                          "ordinary small rows should be read in far fewer SQLite subprocesses")
    }

    func testColdScanComputesOnlyTheWholeTableDigest() async throws {
        let fixture = try makeDatabaseDirectory()
        let timestamp = UInt64(now.timeIntervalSince1970) - 3_600
        let blob = antigravityGenerationBlob(model: "gemini-3.6-flash", input: 10, output: 5, timestamp: timestamp)
        let sqlite = AntigravityFakeSQLite(rowsByPath: [fixture.paths[0]: [.init(index: 0, blob: blob)]])
        let scanner = AntigravityDbUsageScanner(sqlite: sqlite, conversationsDirectory: { fixture.url.path })

        let scan = await scanner.scan(now: now, pricing: pricing)

        XCTAssertNotNil(scan)
        let query = try XCTUnwrap(sqlite.contentFingerprintSQLs.first)
        XCTAssertEqual(query.components(separatedBy: "sha3_agg(").count - 1, 1,
                       "a cold scan has no cached prefix to hash separately")
        XCTAssertFalse(query.contains("CASE WHEN idx <="))
    }

    func testSQLiteWithoutSHA3RemembersCapabilityAndUsesOneMaximumIndexCheckPerAppend() async throws {
        let fixture = try makeDatabaseDirectory()
        let databaseURL = URL(fileURLWithPath: fixture.paths[0])
        try Data(repeating: 0x11, count: 2_048).write(to: databaseURL)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: fixture.paths[0])

        let timestamp = UInt64(now.timeIntervalSince1970) - 3_600
        let first = antigravityGenerationBlob(model: "gemini-3.6-flash", input: 10, output: 5, timestamp: timestamp)
        let second = antigravityGenerationBlob(model: "gemini-3.6-flash", input: 20, output: 10, timestamp: timestamp)
        let sqlite = AntigravityFakeSQLite(
            rowsByPath: [fixture.paths[0]: [.init(index: 0, blob: first)]],
            unsupportedSHA3: true
        )
        let scanner = AntigravityDbUsageScanner(sqlite: sqlite, conversationsDirectory: { fixture.url.path })

        let initial = await scanner.scan(now: now, pricing: pricing)
        XCTAssertEqual(try XCTUnwrap(initial).series.daily.first?.totalTokens, 15)
        XCTAssertEqual(sqlite.contentFingerprintQueries, 1, "the missing extension is detected once")
        let initialMaximumQueries = sqlite.maximumIndexQueries
        XCTAssertEqual(initialMaximumQueries, 1)

        sqlite.append(.init(index: 1, blob: second), to: fixture.paths[0])
        let handle = try FileHandle(forWritingTo: databaseURL)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Data(repeating: 0x22, count: 2_048))
        try handle.truncate(atOffset: 2_048)
        try handle.close()
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(2)],
            ofItemAtPath: fixture.paths[0]
        )

        let updated = await scanner.scan(now: now, pricing: pricing)
        XCTAssertEqual(try XCTUnwrap(updated).series.daily.first?.totalTokens, 45)
        XCTAssertEqual(sqlite.contentFingerprintQueries, 1, "later changes skip the unsupported aggregate probe")
        XCTAssertEqual(sqlite.maximumIndexQueries - initialMaximumQueries, 1,
                       "the changed scan needs one final maximum-index consistency check")
    }

    func testUndatedUsageWarningAgesOutOfTheHistoryWindowWithoutCallingItUnreadable() async throws {
        let fixture = try makeDatabaseDirectory()
        let blob = antigravityGenerationBlob(model: "gemini-3.6-flash", input: 10, output: 5, timestamp: nil)
        let sqlite = AntigravityFakeSQLite(rowsByPath: [fixture.paths[0]: [.init(index: 0, blob: blob)]])
        let scanner = AntigravityDbUsageScanner(sqlite: sqlite, conversationsDirectory: { fixture.url.path })
        let firstNow = Date()

        let first = await scanner.scanWithStatus(daysBack: 29, now: firstNow, pricing: pricing)
        XCTAssertNotNil(first.scan)
        XCTAssertFalse(first.hasReadFailures, "an undated row is a data-quality warning, not a database read failure")
        XCTAssertTrue(first.scan?.unmeasuredUsageDays?.contains(DailyUsageAccumulator.dayKey(from: firstNow)) == true)

        let later = await scanner.scanWithStatus(
            daysBack: 29,
            now: firstNow.addingTimeInterval(31 * 86_400),
            pricing: pricing
        )
        XCTAssertFalse(later.hasReadFailures)
        XCTAssertTrue(later.scan?.unmeasuredUsageDays?.isEmpty ?? true,
                      "the conservative first-seen marker must expire with the requested history window")
    }

    func testFutureDatedRootDoesNotFreezeReadableSibling() async throws {
        let fixture = try makeDatabaseDirectory(fileNames: ["a.db", "b.db"])
        let past = UInt64(now.timeIntervalSince1970) - 3_600
        let future = UInt64(now.timeIntervalSince1970) + 24 * 60 * 60
        let valid = antigravityGenerationBlob(model: "gemini-3.6-flash", input: 10, output: 5, timestamp: past)
        let futureBlob = antigravityGenerationBlob(model: "gemini-3.6-flash", input: 100, output: 50, timestamp: future)
        let sqlite = AntigravityFakeSQLite(rowsByPath: [
            fixture.paths[0]: [.init(index: 0, blob: futureBlob)],
            fixture.paths[1]: [.init(index: 0, blob: valid)]
        ])
        let scanner = AntigravityDbUsageScanner(sqlite: sqlite, conversationsDirectory: { fixture.url.path })

        let firstResult = await scanner.scan(now: now, pricing: pricing)
        let first = try XCTUnwrap(firstResult)
        let queryCounts = sqlite.queriedPaths
        let secondResult = await scanner.scan(now: now, pricing: pricing)
        let second = try XCTUnwrap(secondResult)

        XCTAssertEqual(first.series.daily.first?.totalTokens, 15)
        XCTAssertTrue(first.unmeasuredUsageDays?.contains(DailyUsageAccumulator.dayKey(from: now)) == true)
        XCTAssertEqual(second.series.daily.first?.totalTokens, 15)
        XCTAssertEqual(sqlite.queriedPaths, queryCounts, "future rows remain cached without repeating database work")
    }

    func testScannerRetriesOnceWhenDatabaseChangesDuringRead() async throws {
        let fixture = try makeDatabaseDirectory()
        let timestamp = UInt64(now.timeIntervalSince1970) - 3_600
        let blob = antigravityGenerationBlob(
            model: "gemini-3.6-flash", input: 10, output: 5, timestamp: timestamp
        )
        let sqlite = AntigravityFakeSQLite(
            rowsByPath: [fixture.paths[0]: [.init(index: 0, blob: blob)]],
            touchPathAfterContentFingerprintQuery: 1
        )
        let scanner = AntigravityDbUsageScanner(sqlite: sqlite, conversationsDirectory: { fixture.url.path })

        let result = await scanner.scan(now: now, pricing: pricing)
        let scan = try XCTUnwrap(result)

        XCTAssertEqual(scan.series.daily.first?.totalTokens, 15)
        XCTAssertEqual(sqlite.contentFingerprintQueries, 2, "A single changed-during-scan retry should complete the fold")
    }

    func testLegacyDatabaseSchemaUpgradeReplaysPreviouslyUndatedRows() async throws {
        let fixture = try makeDatabaseDirectory()
        let timestamp = UInt64(now.timeIntervalSince1970) - 3_600
        let blob = antigravityGenerationBlob(
            model: "gemini-3.6-flash", input: 10, output: 5, timestamp: nil
        )
        let sqlite = AntigravityFakeSQLite(
            rowsByPath: [fixture.paths[0]: [.init(index: 0, blob: blob)]]
        )
        let scanner = AntigravityDbUsageScanner(sqlite: sqlite, conversationsDirectory: { fixture.url.path })

        let legacy = await scanner.scan(now: now, pricing: pricing)
        let incompleteLegacy = try XCTUnwrap(legacy)
        XCTAssertTrue(incompleteLegacy.series.daily.isEmpty,
                      "a missing trusted date must not invent today's usage")
        XCTAssertTrue(incompleteLegacy.unmeasuredUsageDays?.contains(DailyUsageAccumulator.dayKey(from: now)) == true,
                      "undated usage should be surfaced as incomplete instead of freezing all history")

        sqlite.replaceRows(
            [.init(index: 0, blob: blob, stepMetadata: antigravityStepMetadata(timestamp: timestamp))],
            at: fixture.paths[0]
        )
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(2)],
            ofItemAtPath: fixture.paths[0]
        )

        let upgradedResult = await scanner.scan(now: now, pricing: pricing)
        let upgraded = try XCTUnwrap(upgradedResult)
        XCTAssertEqual(upgraded.series.daily.first?.totalTokens, 15)
        XCTAssertGreaterThan(sqlite.stepMetadataQueries, 0)
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
        XCTAssertFalse(incomplete.unmeasuredUsageDays?.isEmpty ?? true,
                       "cached data from an unavailable root is a visible lower bound")
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
        XCTAssertGreaterThan(
            sqlite.queriedPaths[unavailableDatabase.path] ?? 0,
            missingDatabaseQueryCount ?? 0,
            "restoring a file changes its source revision, so cached rows are reverified before reuse"
        )
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
        let retained = try XCTUnwrap(incomplete)
        XCTAssertEqual(retained.series.daily.first?.totalTokens, 15)
        XCTAssertFalse(retained.unmeasuredUsageDays?.isEmpty ?? true,
                       "last-good rows remain visible while the discovery root is unreadable")

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
        let initialFingerprintQueries = sqlite.contentFingerprintQueries

        try FileManager.default.moveItem(atPath: oldPath, toPath: newPath)
        sqlite.moveRows(from: oldPath, to: newPath)
        let renamedResult = await scanner.scan(now: now, pricing: pricing)

        XCTAssertEqual(try XCTUnwrap(renamedResult).series.daily.first?.totalTokens, 15)
        XCTAssertEqual(sqlite.queriedPaths[oldPath], oldPathQueries)
        XCTAssertGreaterThan(
            sqlite.queriedPaths[newPath] ?? 0,
            0,
            "rename changes the file revision, so cached rows are verified before reuse"
        )
        XCTAssertEqual(
            sqlite.contentFingerprintQueries - initialFingerprintQueries,
            1,
            "the verification digest also seeds the refreshed cache"
        )
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
            3,
            "an append should launch one schema probe, one compact prefix verifier, and one query for new rows"
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
        XCTAssertEqual(sqlite.queriedPaths[fixture.paths[0]], 4, "cancellation must stop before a full reread")
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
        XCTAssertTrue(try XCTUnwrap(expired).series.daily.isEmpty)

        let recent = antigravityGenerationBlob(
            model: "gemini-3.6-flash", input: 10, output: 5,
            timestamp: UInt64(future.timeIntervalSince1970) - 3_600
        )
        sqlite.append(.init(index: 1, blob: recent), to: fixture.paths[0])
        try FileManager.default.setAttributes([.modificationDate: future], ofItemAtPath: fixture.paths[0])
        let refreshed = await scanner.scan(now: future, pricing: pricing)

        XCTAssertEqual(try XCTUnwrap(refreshed).series.daily.first?.totalTokens, 15)
        XCTAssertEqual(sqlite.queriedCursors, [-1, 0], "the aged cache reads only appended rows after pruning old events")
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

    func testOversizedBlobsPublishLowerBoundHistoryAndWarnOnlyOnce() async throws {
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
        XCTAssertEqual(first.series.daily.first?.totalTokens, 15,
                       "measured rows stay visible while the oversized row is explicitly marked incomplete")
        XCTAssertEqual(second.series.daily.first?.totalTokens, 15)
        XCTAssertFalse(first.unmeasuredUsageDays?.isEmpty ?? true)
        XCTAssertFalse(second.unmeasuredUsageDays?.isEmpty ?? true)
        XCTAssertEqual(recorder.next(), 1)
    }

    func testUnreadableDatabasePublishesReadableSiblingAsPartialAndCancellationStillStops() async throws {
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
        let first = try XCTUnwrap(firstResult)
        let second = try XCTUnwrap(secondResult)
        let failingPathQueryCount = sqlite.queriedPaths[fixture.paths[0]] ?? 0
        XCTAssertEqual(first.series.daily.first?.totalTokens, 15)
        XCTAssertEqual(second.series.daily.first?.totalTokens, 15)
        XCTAssertFalse(first.unmeasuredUsageDays?.isEmpty ?? true)
        XCTAssertGreaterThanOrEqual(failingPathQueryCount, 2)
        XCTAssertLessThanOrEqual(failingPathQueryCount, 8,
                                 "a locked database gets one bounded retry on each of two scans")
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

    func testSQLiteCancellationDoesNotEmitAReadFailureWarning() async throws {
        let fixture = try makeDatabaseDirectory()
        let warnings = Counter()
        let timestamp = UInt64(now.timeIntervalSince1970) - 3_600
        let blob = antigravityGenerationBlob(model: "gemini-3.6-flash", input: 10, output: 5, timestamp: timestamp)
        let sqlite = AntigravityFakeSQLite(
            rowsByPath: [fixture.paths[0]: [.init(index: 0, blob: blob)]],
            throwingCancellationSQLContaining: "FROM gen_metadata"
        )
        let scanner = AntigravityDbUsageScanner(
            sqlite: sqlite,
            conversationsDirectory: { fixture.url.path },
            readFailureWarning: { _ in _ = warnings.next() }
        )

        let result = await scanner.scanWithStatus(now: now, pricing: pricing)

        XCTAssertNil(result.scan)
        XCTAssertFalse(result.hasReadFailures)
        XCTAssertEqual(warnings.next(), 0, "cancelling a scan must not look like a broken conversation database")
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
            onOpenRouterRecheckModel: { _ in withUnsafeCurrentTask { $0?.cancel() } }
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
        XCTAssertTrue(sql.contains("length(g.data) <= \(AntigravityDbUsageScanner.maximumBlobBytes)"))
        XCTAssertTrue(sql.contains("THEN hex(g.data) ELSE NULL"))
        XCTAssertTrue(sql.contains("\(AntigravityDbUsageScanner.maximumBatchSourceBytes)"))
        XCTAssertTrue(sql.contains("'has_more'"))
    }

    func testProductionBatchSQLRunsAgainstRealSQLiteAndMarksTheLastPage() throws {
        let fixture = try makeDatabaseDirectory()
        let sqlitePath = "/usr/bin/sqlite3"
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: sqlitePath))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sqlitePath)
        process.arguments = [
            fixture.paths[0],
            "CREATE TABLE gen_metadata(idx INTEGER PRIMARY KEY, data BLOB NOT NULL); " +
                "WITH RECURSIVE rows(n) AS (SELECT 0 UNION ALL SELECT n + 1 FROM rows WHERE n < 1099) " +
                "INSERT INTO gen_metadata(idx, data) SELECT n, X'01' FROM rows;"
        ]
        let processOutput = Pipe()
        process.standardOutput = processOutput
        process.standardError = processOutput
        try process.run()
        let processData = processOutput.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: processData, as: UTF8.self))

        let accessor = SQLiteCLIAccessor()
        let firstPayload = try XCTUnwrap(accessor.queryValue(
            path: fixture.paths[0],
            sql: AntigravityDbUsageScanner.dataSQL(after: -1)
        ))
        let firstRows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(firstPayload.utf8)) as? [[String: Any]])
        XCTAssertEqual(firstRows.count, AntigravityDbUsageScanner.batchSize)
        XCTAssertEqual(firstRows.last?["has_more"] as? Bool, true)

        let lastIndex = try XCTUnwrap(firstRows.last?["index"] as? Int)
        let finalPayload = try XCTUnwrap(accessor.queryValue(
            path: fixture.paths[0],
            sql: AntigravityDbUsageScanner.dataSQL(after: lastIndex)
        ))
        let finalRows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(finalPayload.utf8)) as? [[String: Any]])
        XCTAssertEqual(finalRows.count, 1099 - lastIndex)
        XCTAssertEqual(finalRows.last?["has_more"] as? Bool, false)
    }

    func testProductionBatchSQLBudgetsGenerationAndStepMetadataTogether() throws {
        let fixture = try makeDatabaseDirectory()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [
            fixture.paths[0],
            "CREATE TABLE gen_metadata(idx INTEGER PRIMARY KEY, data BLOB NOT NULL); " +
                "CREATE TABLE steps(idx INTEGER PRIMARY KEY, metadata BLOB); " +
                "WITH RECURSIVE rows(n) AS (SELECT 0 UNION ALL SELECT n + 1 FROM rows WHERE n < 1023) " +
                "INSERT INTO gen_metadata(idx, data) SELECT n, zeroblob(8192) FROM rows; " +
                "WITH RECURSIVE rows(n) AS (SELECT 0 UNION ALL SELECT n + 1 FROM rows WHERE n < 1023) " +
                "INSERT INTO steps(idx, metadata) SELECT n, zeroblob(8192) FROM rows;"
        ]
        let processOutput = Pipe()
        process.standardOutput = processOutput
        process.standardError = processOutput
        try process.run()
        let processData = processOutput.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: processData, as: UTF8.self))

        let accessor = SQLiteCLIAccessor()
        let firstPayload = try XCTUnwrap(accessor.queryValue(
            path: fixture.paths[0],
            sql: AntigravityDbUsageScanner.dataSQL(after: -1, includeStepMetadata: true)
        ))
        let firstRows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(firstPayload.utf8)) as? [[String: Any]])
        XCTAssertEqual(firstRows.count, AntigravityDbUsageScanner.maximumBatchSourceBytes / (8_192 * 2))
        XCTAssertEqual(firstRows.last?["has_more"] as? Bool, true)
        let firstBatchBytes = firstRows.reduce(into: 0) { total, row in
            total += row["bytes"] as? Int ?? 0
            total += ((row["step_hex"] as? String)?.utf8.count ?? 0) / 2
        }
        XCTAssertEqual(firstBatchBytes, AntigravityDbUsageScanner.maximumBatchSourceBytes)

        let lastIndex = try XCTUnwrap(firstRows.last?["index"] as? Int)
        let finalPayload = try XCTUnwrap(accessor.queryValue(
            path: fixture.paths[0],
            sql: AntigravityDbUsageScanner.dataSQL(after: lastIndex, includeStepMetadata: true)
        ))
        let finalRows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(finalPayload.utf8)) as? [[String: Any]])
        XCTAssertEqual(finalRows.count, 1024 - firstRows.count)
        XCTAssertEqual(finalRows.last?["has_more"] as? Bool, false)
    }

    func testStepMetadataProbeRequiresASingleColumnIndexedKey() throws {
        let fixture = try makeDatabaseDirectory(fileNames: ["indexed.db", "unindexed.db", "composite.db"])
        let accessor = SQLiteCLIAccessor()
        try accessor.execute(path: fixture.paths[0], sql: "CREATE TABLE steps(idx INTEGER PRIMARY KEY, metadata BLOB)")
        try accessor.execute(path: fixture.paths[1], sql: "CREATE TABLE steps(idx INTEGER, metadata BLOB)")
        try accessor.execute(
            path: fixture.paths[2],
            sql: "CREATE TABLE steps(idx INTEGER, other INTEGER, metadata BLOB, PRIMARY KEY(idx, other))"
        )

        XCTAssertEqual(
            try accessor.queryValue(path: fixture.paths[0], sql: AntigravityDbUsageScanner.stepMetadataProbeSQL),
            "1"
        )
        XCTAssertNil(try accessor.queryValue(path: fixture.paths[1], sql: AntigravityDbUsageScanner.stepMetadataProbeSQL))
        XCTAssertNil(try accessor.queryValue(path: fixture.paths[2], sql: AntigravityDbUsageScanner.stepMetadataProbeSQL))
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
    func testProviderKeepsPriorHistoryPathWhenOnlyUnmeasuredRowsWereScanned() async throws {
        let fixture = try makeDatabaseDirectory()
        let fixedNow = now
        let fixedPricing = pricing
        let timestamp = UInt64(fixedNow.timeIntervalSince1970) - 3_600
        let sqlite = AntigravityFakeSQLite(rowsByPath: [fixture.paths[0]: [
            .init(index: 0, blob: nil, stepMetadata: antigravityStepMetadata(timestamp: timestamp))
        ]])
        let scanner = AntigravityDbUsageScanner(sqlite: sqlite, conversationsDirectory: { fixture.url.path })
        let partialScan = await scanner.scan(now: fixedNow, pricing: fixedPricing)
        let scan = try XCTUnwrap(partialScan)
        XCTAssertFalse(scan.unmeasuredUsageDays?.isEmpty ?? true,
                       "An oversized-only scan must remain marked as incomplete on a cache hit")
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

        XCTAssertEqual(snapshot.line(label: "Session")?.label, "Session")
        XCTAssertNil(snapshot.usageHistory, "An oversized-only scan must not replace last-good history with empty rows")
        XCTAssertTrue(snapshot.historyWarning?.contains("lower bounds") == true)
        XCTAssertFalse(snapshot.lines.contains { ["Today", "Yesterday", "Last 30 Days", "Usage Trend"].contains($0.label) })
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

    @MainActor
    func testMenuBarRefreshClearsQuotaPoolOmittedBySuccessfulSummary() async {
        let fixedNow = now
        let fixedPricing = pricing
        let routing = RoutingHTTPClient { request in
            guard request.url.path.hasSuffix("retrieveUserQuotaSummary") else {
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
            let response = #"{"groups":[{"buckets":[{"bucketId":"gemini-5h","remainingFraction":0.8}]}]}"#
            return HTTPResponse(statusCode: 200, headers: [:], body: Data(response.utf8))
        }
        let credentials = #"{"token":{"access_token":"ya29.test","refresh_token":"1//test","expiry":"2099-01-01T00:00:00Z"}}"#
        let wrappedCredentials = "go-keyring-base64:" + Data(credentials.utf8).base64EncodedString()
        let provider = AntigravityProvider(
            authStore: AntigravityAuthStore(keychain: FakeKeychain(wrappedCredentials), files: FakeFiles()),
            usageClient: AntigravityUsageClient(lsHTTP: routing, http: routing),
            discovery: LanguageServerDiscovery(processRunner: EmptyProcessRunner()),
            now: { fixedNow },
            pricing: { fixedPricing }
        )
        let previous = ProviderSnapshot(
            providerID: "antigravity",
            displayName: "Antigravity",
            plan: "Pro",
            lines: [
                .progress(label: "Session", used: 30, limit: 100, format: .percent),
                .progress(label: "Weekly", used: 70, limit: 100, format: .percent),
            ]
        )

        let fresh = await ProviderRefreshContext.$scope.withValue(.menuBar) {
            await provider.refresh()
        }
        let merged = fresh.mergingMenuBarUpdate(over: previous)
        let quotaLabels: (ProviderSnapshot) -> [String] = { snapshot in
            snapshot.lines.compactMap { line in
                guard case .progress = line else { return nil }
                return line.label
            }
        }

        XCTAssertNil(fresh.errorCategory)
        XCTAssertEqual(quotaLabels(fresh), ["Session"])
        XCTAssertEqual(fresh.replacesPriorQuotaProgress, true)
        XCTAssertNil(fresh.clearsPriorMenuBarQuotaState)
        XCTAssertEqual(quotaLabels(merged), ["Session"], "An omitted pool must not retain its previous quota value")
        XCTAssertEqual(merged.plan, "Pro", "Quota replacement must preserve independently fetched plan state")
        XCTAssertNil(merged.clearsPriorMenuBarQuotaState)
    }
}
