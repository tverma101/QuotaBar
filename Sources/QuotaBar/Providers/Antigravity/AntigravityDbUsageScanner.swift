import CryptoKit
import Foundation

/// Reads token accounting from Antigravity's local conversation databases, discovered by FelixIsaac
/// in openusage#1058/#1120. Transcript JSONL files contain no usable generation token counts.
///
/// SQLite batches are bounded, and oversized protobufs are skipped before `hex(data)` runs: real
/// Antigravity sessions can contain generation blobs hundreds of megabytes in size.
actor AntigravityDbUsageScanner {
    static let maximumBlobBytes = 1_048_576
    static let batchSize = 8

    private let sqlite: SQLiteAccessing
    private let conversationsDirectories: @Sendable () throws -> [String]
    private let readFailureReporter: UsageLogReadFailureReporter
    private let oversizedBlobReporter: UsageLogReadFailureReporter
    private var scanCache: [String: CachedDatabase] = [:]

    init(
        sqlite: SQLiteAccessing = SQLiteCLIAccessor(),
        conversationsDirectory: (@Sendable () -> String)? = nil,
        conversationsDirectories: @escaping @Sendable () throws -> [String] = AntigravityDbUsageScanner.defaultConversationsDirectories,
        readFailureWarning: UsageLogReadFailureReporter.Warning? = nil,
        oversizedBlobWarning: UsageLogReadFailureReporter.Warning? = nil
    ) {
        self.sqlite = sqlite
        if let conversationsDirectory {
            self.conversationsDirectories = { [conversationsDirectory()] }
        } else {
            self.conversationsDirectories = conversationsDirectories
        }
        self.readFailureReporter = UsageLogReadFailureReporter(
            logTag: LogTag.plugin("antigravity"),
            warning: readFailureWarning
        )
        self.oversizedBlobReporter = UsageLogReadFailureReporter(
            logTag: LogTag.plugin("antigravity"),
            warning: oversizedBlobWarning ?? { count in
                let noun = count == 1 ? "database" : "databases"
                AppLog.warn(LogTag.plugin("antigravity"), "Skipped oversized generation records in \(count) Antigravity \(noun)")
            }
        )
    }

    /// Antigravity keeps separate local conversation stores for the app, IDE, CLI, and compatible
    /// clients. Discover every sibling root so installing a different Antigravity client does not
    /// leave its local spend and trend rows empty.
    static let defaultConversationsDirectories: @Sendable () throws -> [String] = {
        let geminiRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini", isDirectory: true)
        do {
            return try conversationDirectories(in: geminiRoot)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        }
    }

    static func conversationDirectories(in geminiRoot: URL) throws -> [String] {
        let fileManager = FileManager.default
        let names = try fileManager.contentsOfDirectory(atPath: geminiRoot.path)
        var directories: [String] = []
        for name in names.filter({ $0.hasPrefix("antigravity") }).sorted() {
            let root = geminiRoot.appendingPathComponent(name, isDirectory: true)
            let conversations = root.appendingPathComponent("conversations", isDirectory: true)
            let attributes: [FileAttributeKey: Any]
            do {
                attributes = try fileManager.attributesOfItem(atPath: conversations.path)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                // A client can install its root before creating its conversation database.
                continue
            }
            guard attributes[.type] as? FileAttributeType == .typeDirectory else { continue }
            directories.append(conversations.path)
        }
        return directories.sorted()
    }

    func scan(daysBack: Int = UsageHistoryWindow.previousDays, now: Date = Date(), pricing: ModelPricing) async -> LogUsageScan? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let geminiRoot = home.appendingPathComponent(".gemini", isDirectory: true).path
        let discoveredDirectories: [String]
        var discoveryFailures: [String: String] = [:]
        do {
            discoveredDirectories = try conversationsDirectories()
        } catch {
            discoveredDirectories = []
            discoveryFailures[geminiRoot] = error.localizedDescription
        }
        let cachedDirectories = Set(scanCache.keys.map {
            URL(fileURLWithPath: $0).deletingLastPathComponent().path
        })
        let discoveredSet = Set(discoveredDirectories.map(expandHome))
        // When discovery succeeds, a cached client root that is no longer under ~/.gemini is retired;
        // don't keep probing its stale path forever. If discovery itself fails, keep cached roots in
        // the attempt so their last-good rows survive until the root can be listed again.
        let directories = Array(
            discoveryFailures.isEmpty ? discoveredSet : discoveredSet.union(cachedDirectories)
        ).sorted()
        let since = JSONLScanning.sinceDate(daysBack: daysBack, now: now)
        var paths: [String] = []
        var failingPaths = discoveryFailures
        var checkedPaths = Set(directories).union(discoveryFailures.keys)
        var successfullyListedDirectories: Set<String> = []

        for directory in directories {
            do {
                paths.append(contentsOf: try Self.databaseFiles(in: directory))
                successfullyListedDirectories.insert(directory)
            } catch {
                failingPaths[directory] = error.localizedDescription
            }
        }
        paths = Array(Set(paths)).sorted()
        var seenDatabaseIdentifiers: Set<UInt64> = []
        paths = paths.filter { path in
            guard let identifier = Self.databaseIdentifier(at: path) else { return true }
            return seenDatabaseIdentifiers.insert(identifier).inserted
        }
        let databasePaths = Set(paths)
        rebindMovedDatabaseCaches(to: databasePaths)
        let missingCachedPaths = Set(scanCache.keys).subtracting(databasePaths)
        for path in missingCachedPaths {
            failingPaths[path] = "previously scanned database is missing from the conversation directory listing"
        }
        let retiredCachedDirectories = discoveryFailures.isEmpty
            ? cachedDirectories.subtracting(discoveredSet)
            : []
        let retiredCachedPaths = Set(scanCache.keys.filter { path in
            retiredCachedDirectories.contains(URL(fileURLWithPath: path).deletingLastPathComponent().path)
        })
        let absentCachedPaths = Set(missingCachedPaths.filter { path in
            successfullyListedDirectories.contains(URL(fileURLWithPath: path).deletingLastPathComponent().path)
        }).union(retiredCachedPaths)
        checkedPaths.formUnion(databasePaths)
        checkedPaths.formUnion(missingCachedPaths)
        let unreadableDirectories = Set(directories.filter { failingPaths[$0] != nil })
            .union(discoveryFailures.keys)
        let cachedPathsUnderUnreadableDirectories = Set(scanCache.keys.filter { path in
            unreadableDirectories.contains { directory in
                let prefix = directory.hasSuffix("/") ? directory : directory + "/"
                return path.hasPrefix(prefix)
            }
        })
        let retainedPaths = discoveryFailures.isEmpty
            ? databasePaths.union(cachedPathsUnderUnreadableDirectories).union(absentCachedPaths)
            : Set(scanCache.keys)

        scanCache = scanCache.filter {
            retainedPaths.contains($0.key) && $0.value.fingerprint.latestModification >= since
        }

        // A readable conversation directory that no longer lists a previously scanned database is a
        // retired or temporarily absent source, not an unreadable source. Keep its last-good events in
        // the aggregate while the remaining databases continue to update. If the path returns, the
        // retained fingerprint lets the scanner verify or rebuild it. A directory that cannot be
        // listed, or a database that is present but cannot be queried, still fails the full scan.
        let retainedAbsentCachedPaths = absentCachedPaths.filter { scanCache[$0] != nil }

        guard !paths.isEmpty || !retainedAbsentCachedPaths.isEmpty else {
            let newlyFailing = await readFailureReporter.update(
                checkedPaths: checkedPaths,
                failingPaths: Set(failingPaths.keys).subtracting(absentCachedPaths)
            )
            for path in newlyFailing.sorted() {
                AppLog.warn(LogTag.plugin("antigravity"), "conversation store could not be read at \(path): \(failingPaths[path] ?? "unknown error")")
            }
            return nil
        }

        var accumulator = DailyUsageAccumulator()
        var oversizedPaths: Set<String> = []

        for path in paths {
            guard !Task.isCancelled else { return nil }
            do {
                let cached = try cachedDatabase(path: path, since: since)
                guard !Task.isCancelled else { return nil }
                guard let cached else { continue }
                JSONLAccountingWorkPacer.shared.forEach(cached.events) { event in
                    Self.accumulate(event, since: since, pricing: pricing, into: &accumulator)
                }
                guard !Task.isCancelled else { return nil }
                if cached.sawOversizedBlob {
                    oversizedPaths.insert(path)
                }
            } catch {
                failingPaths[path] = error.localizedDescription
            }
        }

        for path in retainedAbsentCachedPaths.sorted() {
            guard let cached = scanCache[path] else { continue }
            JSONLAccountingWorkPacer.shared.forEach(cached.events) { event in
                Self.accumulate(event, since: since, pricing: pricing, into: &accumulator)
            }
            if cached.sawOversizedBlob {
                oversizedPaths.insert(path)
            }
        }

        let newlyFailing = await readFailureReporter.update(
            checkedPaths: checkedPaths,
            failingPaths: Set(failingPaths.keys).subtracting(absentCachedPaths)
        )
        for path in newlyFailing.sorted() {
            AppLog.warn(LogTag.plugin("antigravity"), "conversation store could not be read at \(path): \(failingPaths[path] ?? "unknown error")")
        }

        let newlyOversized = await oversizedBlobReporter.update(
            checkedPaths: databasePaths,
            failingPaths: oversizedPaths
        )
        for path in newlyOversized.sorted() {
            AppLog.warn(LogTag.plugin("antigravity"), "generation records larger than \(Self.maximumBlobBytes) bytes skipped in \(path)")
        }

        // Do not publish a smaller multi-root result after discovery or SQLite failures. A missing
        // file in a successfully listed directory is excluded here because its last-good rows were
        // retained above; other roots can still publish current updates without dropping that data.
        guard Set(failingPaths.keys).subtracting(absentCachedPaths).isEmpty else { return nil }
        guard !Task.isCancelled else { return nil }

        let result = accumulator.build()
        return result.series.daily.isEmpty && result.unknownModelsByDay.isEmpty ? nil : result
    }

    /// `CASE` prevents SQLite from expanding oversized blobs, while the inner `LIMIT` bounds the
    /// maximum hex payload returned by any subprocess to roughly `batchSize * maximumBlobBytes * 2`.
    static func dataSQL(after index: Int) -> String {
        dataSQL(after: index, through: nil)
    }

    private static func dataSQL(after index: Int, through lastIndex: Int?) -> String {
        let upperBound = lastIndex.map { " AND idx <= \($0)" } ?? ""
        return """
        SELECT json_group_array(json_object('index', idx, 'bytes', length(data), 'hex',
            CASE WHEN length(data) <= \(maximumBlobBytes) THEN hex(data) ELSE NULL END))
        FROM (
            SELECT idx, data FROM gen_metadata
            WHERE idx > \(index)\(upperBound) AND data IS NOT NULL
            ORDER BY idx
            LIMIT \(batchSize)
        )
        """
    }

    private func cachedDatabase(path: String, since: Date) throws -> CachedDatabase? {
        let fingerprint = try DatabaseFingerprint(path: path)
        guard fingerprint.latestModification >= since else { return nil }

        if let cached = scanCache[path], cached.fingerprint == fingerprint, cached.windowStart <= since {
            return cached
        }

        var cached = scanCache[path]
        if cached?.fingerprint.databaseIdentifier != fingerprint.databaseIdentifier
            || (cached?.fingerprint.databaseSize ?? 0) > fingerprint.databaseSize
            || (cached?.windowStart ?? since) > since
        {
            cached = nil
        }

        var contentFingerprint: ContentFingerprint?

        // A changed database can rewrite an old row and append a new one in the same transaction.
        // Verify the full cached generation prefix before retaining it, then read any appended rows.
        // SQLite CLI builds with SHA3 support verify the prefix and produce the new table fingerprint
        // in one compact, ordered aggregate query. Older CLI builds use the paced batch fallback.
        if let existing = cached, existing.fingerprint != fingerprint {
            guard !Task.isCancelled else { return nil }
            contentFingerprint = try? Self.contentFingerprint(
                path: path,
                through: existing.lastIndex,
                sqlite: sqlite
            )
            guard !Task.isCancelled else { return nil }

            if let contentFingerprint, let previous = existing.contentFingerprint {
                if contentFingerprint.maximumIndex < existing.lastIndex
                    || contentFingerprint.prefixFingerprint != previous
                {
                    cached = nil
                }
            } else {
                // SHA3 is an optional SQLite CLI extension. Retain the exact batched verifier for
                // older macOS builds and any CLI that cannot run the aggregate query.
                let maximumIndex = try Self.maximumIndex(path: path, sqlite: sqlite)
                guard !Task.isCancelled else { return nil }
                if maximumIndex < existing.lastIndex {
                    cached = nil
                } else {
                    let prefixMatches = Self.cachedRowsMatch(path: path, cached: existing, sqlite: sqlite)
                    guard !Task.isCancelled else { return nil }
                    if !prefixMatches { cached = nil }
                }
            }
        }

        var refreshed = cached ?? CachedDatabase(fingerprint: fingerprint, windowStart: since)
        refreshed.fingerprint = fingerprint
        refreshed.windowStart = since
        JSONLAccountingWorkPacer.shared.perform {
            refreshed.events.removeAll {
                Date(timeIntervalSince1970: TimeInterval($0.timestampSeconds)) < since
            }
        }
        try readDatabase(path: path, since: since, into: &refreshed)
        guard !Task.isCancelled else { return nil }

        if let contentFingerprint, contentFingerprint.maximumIndex == refreshed.lastIndex {
            refreshed.contentFingerprint = contentFingerprint.tableFingerprint
        } else {
            // Initial scans and scans that raced a concurrent append need a digest for exactly the
            // rows represented in this cache. If SHA3 is unavailable, nil selects the batch fallback.
            let summary = try? Self.contentFingerprint(
                path: path,
                through: refreshed.lastIndex,
                sqlite: sqlite
            )
            refreshed.contentFingerprint = summary?.prefixFingerprint
            guard !Task.isCancelled else { return nil }
        }

        scanCache[path] = refreshed
        return refreshed
    }

    /// A database renamed within a discovered conversation directory keeps its file number. Move the
    /// cache entry to its new path before treating the old path as a missing retained source; otherwise
    /// one database would be folded once from its new path and again from the old cached path.
    private func rebindMovedDatabaseCaches(to activePaths: Set<String>) {
        for newPath in activePaths.sorted() where scanCache[newPath] == nil {
            guard let identifier = Self.databaseIdentifier(at: newPath) else { continue }
            let oldPath = scanCache.first { entry in
                !activePaths.contains(entry.key)
                    && entry.value.fingerprint.databaseIdentifier == identifier
            }?.key
            guard let oldPath, let cached = scanCache.removeValue(forKey: oldPath) else { continue }
            scanCache[newPath] = cached
        }
    }

    private static func databaseIdentifier(at path: String) -> UInt64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let number = attributes[.systemFileNumber] as? NSNumber,
              number.uint64Value > 0 else { return nil }
        return number.uint64Value
    }

    private func readDatabase(path: String, since: Date, into cached: inout CachedDatabase) throws {
        while !Task.isCancelled {
            guard let payload = try JSONLAccountingWorkPacer.shared.perform({
                try sqlite.queryValue(path: path, sql: Self.dataSQL(after: cached.lastIndex))
            }) else { break }
            let rows = try JSONLAccountingWorkPacer.shared.perform {
                try JSONDecoder().decode([Row].self, from: Data(payload.utf8))
            }
            guard !rows.isEmpty else { break }
            try JSONLAccountingWorkPacer.shared.perform {
                for row in rows {
                    guard row.index > cached.lastIndex else {
                        throw SQLiteError.queryFailed("Antigravity generation indices are not strictly increasing")
                    }
                    let fingerprint = Self.rowFingerprint(row)
                    cached.tableFingerprint = Self.advancingFingerprint(cached.tableFingerprint, with: fingerprint)
                    cached.lastIndex = row.index
                    cached.rowCount += 1
                    guard let hex = row.hex else {
                        cached.sawOversizedBlob = true
                        continue
                    }
                    guard let blob = Self.bytes(fromHex: hex),
                          let event = AntigravityProtoDecoder.generationEvent(from: blob),
                          Date(timeIntervalSince1970: TimeInterval(event.timestampSeconds)) >= since
                    else { continue }
                    cached.events.append(event)
                }
            }
            if rows.count < Self.batchSize { break }
        }
    }

    private static func maximumIndex(path: String, sqlite: SQLiteAccessing) throws -> Int {
        let sql = "SELECT COALESCE(MAX(idx), -1) FROM gen_metadata WHERE data IS NOT NULL"
        guard let value = try sqlite.queryValue(path: path, sql: sql), let index = Int(value) else {
            throw SQLiteError.queryFailed("Antigravity generation index query returned no value")
        }
        return index
    }

    /// Returns the current maximum index, a digest of the prior cached prefix, and a digest of all
    /// rows in one SQLite CLI invocation. Each blob is hashed in SQLite, so the subprocess returns
    /// only three small values regardless of history size. Oversized blobs remain excluded from
    /// usage decoding; their index and byte count still participate in cache validation.
    private static func contentFingerprint(
        path: String,
        through lastCachedIndex: Int,
        sqlite: SQLiteAccessing
    ) throws -> ContentFingerprint? {
        guard let value = try JSONLAccountingWorkPacer.shared.perform({
            try sqlite.queryValue(path: path, sql: contentFingerprintSQL(through: lastCachedIndex))
        }) else {
            return nil
        }
        let fields = value.split(separator: "|", omittingEmptySubsequences: false)
        guard fields.count == 3,
              let maximumIndex = Int(fields[0])
        else { return nil }
        return ContentFingerprint(
            maximumIndex: maximumIndex,
            prefixFingerprint: String(fields[1]),
            tableFingerprint: String(fields[2])
        )
    }

    /// The explicit aggregate order is required because the fingerprint represents an ordered table
    /// prefix. SQLite CLI builds without `sha3` / `sha3_agg` fail this query and use `cachedRowsMatch`.
    private static func contentFingerprintSQL(through lastCachedIndex: Int) -> String {
        """
        WITH rows AS MATERIALIZED (
            SELECT idx, length(data) AS byteCount,
                CASE WHEN length(data) <= \(maximumBlobBytes)
                    THEN hex(sha3(data, 256)) ELSE 'oversized' END AS rowDigest
            FROM gen_metadata
            WHERE data IS NOT NULL
        )
        SELECT COALESCE(MAX(idx), -1) || '|' ||
            COALESCE(hex(sha3_agg(
                CASE WHEN idx <= \(lastCachedIndex)
                    THEN printf('%d:%d:%s;', idx, byteCount, rowDigest) END ORDER BY idx
            )), '') || '|' ||
            COALESCE(hex(sha3_agg(
                printf('%d:%d:%s;', idx, byteCount, rowDigest) ORDER BY idx
            )), '')
        FROM rows
        """
    }

    private static func cachedRowsMatch(
        path: String,
        cached: CachedDatabase,
        sqlite: SQLiteAccessing
    ) -> Bool {
        if cached.rowCount == 0 { return cached.lastIndex == -1 }
        var cursor = -1
        var rowCount = 0
        var fingerprint = emptyTableFingerprint
        while cursor < cached.lastIndex {
            guard !Task.isCancelled else { return false }
            let queriedPayload: String?
            do {
                queriedPayload = try JSONLAccountingWorkPacer.shared.perform { () -> String? in
                    guard !Task.isCancelled else { return nil }
                    return try sqlite.queryValue(
                        path: path,
                        sql: dataSQL(after: cursor, through: cached.lastIndex)
                    )
                }
            } catch {
                return false
            }
            guard !Task.isCancelled, let payload = queriedPayload else { return false }
            guard let rows = try? JSONLAccountingWorkPacer.shared.perform({
                try JSONDecoder().decode([Row].self, from: Data(payload.utf8))
            }), !rows.isEmpty else { return false }
            let validBatch = JSONLAccountingWorkPacer.shared.perform { () -> Bool in
                for row in rows {
                    guard !Task.isCancelled, row.index > cursor else { return false }
                    fingerprint = advancingFingerprint(fingerprint, with: rowFingerprint(row))
                    cursor = row.index
                    rowCount += 1
                }
                return true
            }
            guard validBatch, !Task.isCancelled else { return false }
        }
        return rowCount == cached.rowCount
            && cursor == cached.lastIndex
            && fingerprint == cached.tableFingerprint
    }

    private static func rowFingerprint(_ row: Row) -> DatabaseRowFingerprint {
        let digest = row.hex.map { Data(SHA256.hash(data: Data($0.utf8))) }
        return DatabaseRowFingerprint(index: row.index, byteCount: row.byteCount, digest: digest)
    }

    private static let emptyTableFingerprint = Data(SHA256.hash(data: Data("antigravity-gen-metadata-v1".utf8)))

    private static func advancingFingerprint(
        _ previous: Data,
        with row: DatabaseRowFingerprint
    ) -> Data {
        var hasher = SHA256()
        hasher.update(data: previous)
        hasher.update(data: Data("\(row.index):\(row.byteCount):".utf8))
        if let digest = row.digest {
            hasher.update(data: Data([1]))
            hasher.update(data: digest)
        } else {
            hasher.update(data: Data([0]))
        }
        return Data(hasher.finalize())
    }

    private struct Row: Decodable {
        let index: Int
        let byteCount: Int
        let hex: String?

        enum CodingKeys: String, CodingKey {
            case index
            case byteCount = "bytes"
            case hex
        }
    }

    private struct DatabaseRowFingerprint: Equatable {
        let index: Int
        let byteCount: Int
        let digest: Data?
    }

    private struct ContentFingerprint {
        let maximumIndex: Int
        let prefixFingerprint: String
        let tableFingerprint: String
    }

    private static func accumulate(
        _ event: AntigravityProtoDecoder.GenerationEvent,
        since: Date,
        pricing: ModelPricing,
        into accumulator: inout DailyUsageAccumulator
    ) {
        let date = Date(timeIntervalSince1970: TimeInterval(event.timestampSeconds))
        guard date >= since else { return }

        let inputAndCached = event.inputTokens.addingReportingOverflow(event.cacheReadTokens)
        let total = inputAndCached.partialValue.addingReportingOverflow(event.outputTokens)
        guard !inputAndCached.overflow, !total.overflow, total.partialValue > 0 else { return }

        let day = DailyUsageAccumulator.dayKey(from: date)
        let tokens = TokenBreakdown(
            input: event.inputTokens,
            cacheRead: event.cacheReadTokens,
            output: event.outputTokens
        )

        // Public-API-rate comparison: the same tokens at the catalog rates.
        accumulator.recordApiEstimate(
            day: day,
            cost: pricing.estimatedCostDollars(model: event.model, tokens: tokens),
            tokens: total.partialValue
        )
        guard let cost = pricing.estimatedCostDollars(model: event.model, tokens: tokens) else {
            accumulator.addUnknownModel(day: day, model: event.model)
            // Unpriced rows count their tokens with a dashed cost (owner policy).
            accumulator.add(day: day, tokens: total.partialValue, cost: nil, model: event.model)
            return
        }
        accumulator.add(day: day, tokens: total.partialValue, cost: cost, model: event.model)
    }

    static func bytes(fromHex hex: String) -> [UInt8]? {
        guard hex.utf8.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.utf8.count / 2)

        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    private static func databaseFiles(in directory: String) throws -> [String] {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory)

        return names
            .filter { $0.hasSuffix(".db") }
            .sorted()
            .map { directory.trimmingTrailingSlashes + "/" + $0 }
    }

    private struct DatabaseFingerprint: Equatable {
        let databaseIdentifier: UInt64
        let databaseSize: Int64
        let databaseModification: Date
        let walSize: Int64?
        let walModification: Date?

        init(path: String) throws {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            databaseIdentifier = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            databaseSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            databaseModification = attributes[.modificationDate] as? Date ?? .distantPast

            do {
                let walAttributes = try FileManager.default.attributesOfItem(atPath: path + "-wal")
                walSize = (walAttributes[.size] as? NSNumber)?.int64Value ?? 0
                walModification = walAttributes[.modificationDate] as? Date ?? .distantPast
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                walSize = nil
                walModification = nil
            }
        }

        var latestModification: Date {
            max(databaseModification, walModification ?? .distantPast)
        }
    }

    private struct CachedDatabase {
        var fingerprint: DatabaseFingerprint
        var windowStart: Date
        var lastIndex = -1
        var rowCount = 0
        var tableFingerprint = AntigravityDbUsageScanner.emptyTableFingerprint
        var contentFingerprint: String?
        var events: [AntigravityProtoDecoder.GenerationEvent] = []
        var sawOversizedBlob = false
    }
}
