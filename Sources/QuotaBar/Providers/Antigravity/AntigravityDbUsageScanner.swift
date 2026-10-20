import CryptoKit
import Darwin
import Foundation

struct AntigravityDbUsageScanResult: Sendable {
    let scan: LogUsageScan?
    let hasReadFailures: Bool
}

/// Reads token accounting from Antigravity's local conversation databases, discovered by FelixIsaac
/// in openusage#1058/#1120. Transcript JSONL files contain no usable generation token counts.
///
/// SQLite batches are bounded, and oversized protobufs are skipped before `hex(data)` runs: real
/// Antigravity sessions can contain generation blobs hundreds of megabytes in size.
actor AntigravityDbUsageScanner {
    static let maximumBlobBytes = 1_048_576
    static let batchSize = 1_024
    static let maximumBatchSourceBytes = 8_388_608
    private static let changedDuringScanMessage = "Antigravity conversation database changed during scan"

    private let sqlite: SQLiteAccessing
    private let discoverConversationDirectories: @Sendable () throws -> ConversationDirectoryDiscovery
    private let readFailureReporter: UsageLogReadFailureReporter
    private let oversizedBlobReporter: UsageLogReadFailureReporter
    private var scanCache: [String: CachedDatabase] = [:]
    private var sqliteSupportsSHA3Aggregate: Bool?

    struct ConversationDirectoryDiscovery: Sendable {
        let directories: [String]
        let failures: [String: String]
    }

    init(
        sqlite: SQLiteAccessing = SQLiteCLIAccessor(allowsReadWriteFallback: false),
        conversationsDirectory: (@Sendable () -> String)? = nil,
        conversationsDirectories: (@Sendable () throws -> [String])? = nil,
        conversationDiscovery: (@Sendable () throws -> ConversationDirectoryDiscovery)? = nil,
        readFailureWarning: UsageLogReadFailureReporter.Warning? = nil,
        oversizedBlobWarning: UsageLogReadFailureReporter.Warning? = nil
    ) {
        self.sqlite = sqlite
        if let conversationDiscovery {
            self.discoverConversationDirectories = conversationDiscovery
        } else if let conversationsDirectory {
            self.discoverConversationDirectories = {
                ConversationDirectoryDiscovery(directories: [conversationsDirectory()], failures: [:])
            }
        } else if let conversationsDirectories {
            self.discoverConversationDirectories = {
                ConversationDirectoryDiscovery(directories: try conversationsDirectories(), failures: [:])
            }
        } else {
            self.discoverConversationDirectories = Self.defaultConversationDiscovery
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
    static let defaultConversationDiscovery: @Sendable () throws -> ConversationDirectoryDiscovery = {
        let geminiRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini", isDirectory: true)
        do {
            return try discoverConversationDirectories(in: geminiRoot)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return ConversationDirectoryDiscovery(directories: [], failures: [:])
        }
    }

    static func conversationDirectories(in geminiRoot: URL) throws -> [String] {
        try discoverConversationDirectories(in: geminiRoot).directories
    }

    static func discoverConversationDirectories(
        in geminiRoot: URL,
        attributesOfItem: (String) throws -> [FileAttributeKey: Any] = {
            try FileManager.default.attributesOfItem(atPath: $0)
        }
    ) throws -> ConversationDirectoryDiscovery {
        let fileManager = FileManager.default
        let names = try fileManager.contentsOfDirectory(atPath: geminiRoot.path)
        var directories: [String] = []
        var failures: [String: String] = [:]
        for name in names.filter({ $0.hasPrefix("antigravity") }).sorted() {
            let root = geminiRoot.appendingPathComponent(name, isDirectory: true)
            let conversations = root.appendingPathComponent("conversations", isDirectory: true)
            let attributes: [FileAttributeKey: Any]
            do {
                attributes = try attributesOfItem(conversations.path)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                // A client can install its root before creating its conversation database.
                continue
            } catch {
                failures[conversations.path] = error.localizedDescription
                continue
            }
            guard attributes[.type] as? FileAttributeType == .typeDirectory else { continue }
            directories.append(conversations.path)
        }
        return ConversationDirectoryDiscovery(directories: directories.sorted(), failures: failures)
    }

    func scan(daysBack: Int = UsageHistoryWindow.previousDays, now: Date = Date(), pricing: ModelPricing) async -> LogUsageScan? {
        await scanWithStatus(daysBack: daysBack, now: now, pricing: pricing).scan
    }

    func scanWithStatus(
        daysBack: Int = UsageHistoryWindow.previousDays,
        now: Date = Date(),
        pricing: ModelPricing
    ) async -> AntigravityDbUsageScanResult {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let geminiRoot = home.appendingPathComponent(".gemini", isDirectory: true).path
        let discoveredDirectories: [String]
        var discoveryFailures: [String: String] = [:]
        do {
            let discovery = try discoverConversationDirectories()
            discoveredDirectories = discovery.directories
            discoveryFailures = discovery.failures
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
        var seenDatabaseIdentifiers: Set<DatabaseIdentity> = []
        paths = paths.filter { path in
            guard let identifier = Self.databaseIdentity(at: path) else { return true }
            return seenDatabaseIdentifiers.insert(identifier).inserted
        }
        let databasePaths = Set(paths)
        rebindMovedDatabaseCaches(to: databasePaths)
        discardDuplicateCachedDatabaseAliases(activePaths: databasePaths)
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
        for path in Array(scanCache.keys).sorted() {
            guard var cached = scanCache[path], cached.windowStart < since else { continue }
            Self.prune(&cached, before: since)
            scanCache[path] = cached
        }

        // A readable conversation directory that no longer lists a previously scanned database is a
        // retired or temporarily absent source. Keep its last-good events as a partial lower bound
        // while readable databases continue to update.
        let retainedAbsentCachedPaths = absentCachedPaths.filter { scanCache[$0] != nil }

        guard !paths.isEmpty || !retainedAbsentCachedPaths.isEmpty || !cachedPathsUnderUnreadableDirectories.isEmpty else {
            let newlyFailing = await readFailureReporter.update(
                checkedPaths: checkedPaths,
                failingPaths: Set(failingPaths.keys).subtracting(absentCachedPaths)
            )
            for path in newlyFailing.sorted() {
                AppLog.warn(LogTag.plugin("antigravity"), "conversation store could not be read at \(path): \(failingPaths[path] ?? "unknown error")")
            }
            // No listed database is not proof that ten years of usage should be erased. Keep the
            // last-good history until a readable database completes a scan.
            return AntigravityDbUsageScanResult(scan: nil, hasReadFailures: !failingPaths.isEmpty)
        }

        var databaseScans: [LogUsageScan] = []
        let pricingToken = pricing.aggregateCacheToken
        let timeZoneIdentifier = Calendar.current.timeZone.identifier
        var oversizedPaths: Set<String> = []
        var hasUnknownIncompleteSource = !discoveryFailures.isEmpty

        for path in paths {
            guard !Task.isCancelled else {
                return AntigravityDbUsageScanResult(scan: nil, hasReadFailures: false)
            }
            do {
                let cached = try cachedDatabase(path: path, since: since, observedAt: now)
                guard !Task.isCancelled else {
                    return AntigravityDbUsageScanResult(scan: nil, hasReadFailures: false)
                }
                guard let cached else { continue }
                if !cached.oversizedTimestamps.isEmpty {
                    oversizedPaths.insert(path)
                }
                guard let aggregate = aggregate(
                    cached,
                    path: path,
                    since: since,
                    pricing: pricing,
                    pricingToken: pricingToken,
                    timeZoneIdentifier: timeZoneIdentifier,
                    now: now
                ) else { return AntigravityDbUsageScanResult(scan: nil, hasReadFailures: false) }
                databaseScans.append(aggregate)
            } catch is CancellationError {
                return AntigravityDbUsageScanResult(scan: nil, hasReadFailures: false)
            } catch {
                guard !Task.isCancelled else {
                    return AntigravityDbUsageScanResult(scan: nil, hasReadFailures: false)
                }
                failingPaths[path] = error.localizedDescription
                hasUnknownIncompleteSource = true
                if let cached = scanCache[path],
                   let staleAggregate = aggregate(
                       cached,
                       path: path,
                       since: since,
                       pricing: pricing,
                       pricingToken: pricingToken,
                       timeZoneIdentifier: timeZoneIdentifier,
                       now: now
                   )
                {
                    databaseScans.append(staleAggregate.markingUnmeasuredUsage(
                        on: Set(staleAggregate.series.daily.map(\.date)).union([DailyUsageAccumulator.dayKey(from: now)])
                    ))
                }
            }
        }

        let staleCachedPaths = Set(retainedAbsentCachedPaths)
            .union(cachedPathsUnderUnreadableDirectories.subtracting(databasePaths))
        for path in staleCachedPaths.sorted() {
            guard let cached = scanCache[path] else { continue }
            hasUnknownIncompleteSource = true
            if !cached.oversizedTimestamps.isEmpty {
                oversizedPaths.insert(path)
            }
            guard let aggregate = aggregate(
                cached,
                path: path,
                since: since,
                pricing: pricing,
                pricingToken: pricingToken,
                timeZoneIdentifier: timeZoneIdentifier,
                now: now
            ) else { return AntigravityDbUsageScanResult(scan: nil, hasReadFailures: false) }
            databaseScans.append(aggregate.markingUnmeasuredUsage(
                on: Set(aggregate.series.daily.map(\.date)).union([DailyUsageAccumulator.dayKey(from: now)])
            ))
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

        guard !databaseScans.isEmpty || failingPaths.isEmpty else {
            return AntigravityDbUsageScanResult(scan: nil, hasReadFailures: true)
        }
        guard !Task.isCancelled else { return AntigravityDbUsageScanResult(scan: nil, hasReadFailures: false) }

        var merged = DailyUsageAccumulator.merged(databaseScans) ?? DailyUsageAccumulator().build()
        if hasUnknownIncompleteSource {
            let observedDays = Set(merged.series.daily.map(\.date))
            merged = merged.markingUnmeasuredUsage(
                on: observedDays.union([DailyUsageAccumulator.dayKey(from: now)])
            )
        }
        return AntigravityDbUsageScanResult(scan: merged, hasReadFailures: !failingPaths.isEmpty)
    }

    /// Reuse the priced per-database fold while its source revision, pricing snapshot, calendar
    /// window, and time zone are unchanged. Cached protobuf events remain available so a pricing or
    /// window change can rebuild the aggregate without another SQLite read.
    private func aggregate(
        _ cached: CachedDatabase,
        path: String,
        since: Date,
        pricing: ModelPricing,
        pricingToken: String,
        timeZoneIdentifier: String,
        now: Date
    ) -> LogUsageScan? {
        guard !Task.isCancelled else { return nil }
        let maximumTimestamp = JSONLScanning.maximumTimestamp(now: now)
        if let aggregate = cached.aggregate,
           aggregate.pricingToken == pricingToken,
           aggregate.windowStart <= since,
           aggregate.timeZoneIdentifier == timeZoneIdentifier,
           aggregate.recomputeAfter.map({ now >= $0 }) != true,
           aggregate.latestAcceptedTimestamp.map({
               Date(timeIntervalSince1970: TimeInterval($0)) <= maximumTimestamp
           }) != false
        {
            let scan: LogUsageScan
            if aggregate.windowStart < since {
                scan = aggregate.scan.droppingDays(before: DailyUsageAccumulator.dayKey(from: since))
                if var current = scanCache[path], current.fingerprint == cached.fingerprint {
                    current.aggregate = CachedAggregate(
                        pricingToken: aggregate.pricingToken,
                        windowStart: since,
                        timeZoneIdentifier: aggregate.timeZoneIdentifier,
                        scan: scan,
                        recomputeAfter: aggregate.recomputeAfter,
                        latestAcceptedTimestamp: aggregate.latestAcceptedTimestamp
                    )
                    scanCache[path] = current
                }
            } else {
                scan = aggregate.scan
            }
            return Self.markingCachedDataIncomplete(
                scan,
                cached: cached,
                since: since,
                maximumTimestamp: maximumTimestamp,
                now: now,
                hasFutureEvent: aggregate.recomputeAfter != nil
            )
        }

        var accumulator = DailyUsageAccumulator()
        var recomputeAfter: Date?
        var latestAcceptedTimestamp: Int64?
        let allowedClockSkew = maximumTimestamp.timeIntervalSince(now)
        JSONLAccountingWorkPacer.shared.forEach(cached.events) { event in
            let date = Date(timeIntervalSince1970: TimeInterval(event.timestampSeconds))
            guard date <= maximumTimestamp else {
                let transition = date.addingTimeInterval(-allowedClockSkew)
                recomputeAfter = min(recomputeAfter ?? transition, transition)
                return
            }
            latestAcceptedTimestamp = max(latestAcceptedTimestamp ?? event.timestampSeconds, event.timestampSeconds)
            Self.accumulate(event, since: since, pricing: pricing, into: &accumulator)
        }
        for timestamp in cached.oversizedTimestamps
            + cached.invalidTokenTimestamps
            + cached.malformedUsageTimestamps
        {
            let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
            guard date > maximumTimestamp else { continue }
            let transition = date.addingTimeInterval(-allowedClockSkew)
            recomputeAfter = min(recomputeAfter ?? transition, transition)
        }
        guard !Task.isCancelled else { return nil }
        let scan = accumulator.build()
        guard !Task.isCancelled else { return nil }
        if var current = scanCache[path], current.fingerprint == cached.fingerprint {
            current.aggregate = CachedAggregate(
                pricingToken: pricingToken,
                windowStart: since,
                timeZoneIdentifier: timeZoneIdentifier,
                scan: scan,
                recomputeAfter: recomputeAfter,
                latestAcceptedTimestamp: latestAcceptedTimestamp
            )
            scanCache[path] = current
        }
        return Self.markingCachedDataIncomplete(
            scan,
            cached: cached,
            since: since,
            maximumTimestamp: maximumTimestamp,
            now: now,
            hasFutureEvent: recomputeAfter != nil
        )
    }

    private static func markingCachedDataIncomplete(
        _ scan: LogUsageScan,
        cached: CachedDatabase,
        since: Date,
        maximumTimestamp: Date,
        now: Date,
        hasFutureEvent: Bool
    ) -> LogUsageScan {
        var incompleteDays = Set<String>()
        for timestamp in cached.undatedUsageTimestamps
            + cached.oversizedTimestamps
            + cached.invalidTokenTimestamps
            + cached.malformedUsageTimestamps
        {
            let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
            guard date >= since else { continue }
            if date > maximumTimestamp {
                incompleteDays.insert(DailyUsageAccumulator.dayKey(from: now))
            } else {
                incompleteDays.insert(DailyUsageAccumulator.dayKey(from: date))
            }
        }
        if hasFutureEvent {
            incompleteDays.insert(DailyUsageAccumulator.dayKey(from: now))
        }
        return scan.markingUnmeasuredUsage(on: incompleteDays)
    }

    /// The candidate row limit cuts subprocess count; the windowed source-byte budget bounds the
    /// combined generation and step metadata before hex encoding expands the returned text.
    static func dataSQL(after index: Int, includeStepMetadata: Bool = false) -> String {
        dataSQL(after: index, through: nil, includeStepMetadata: includeStepMetadata)
    }

    /// The correlated step lookup is only safe and bounded when idx is a unique single-column key.
    static let stepMetadataProbeSQL = """
    SELECT 1 WHERE
        EXISTS (SELECT 1 FROM pragma_table_info('steps') WHERE name = 'idx')
        AND EXISTS (SELECT 1 FROM pragma_table_info('steps') WHERE name = 'metadata')
        AND EXISTS (SELECT 1 FROM pragma_table_info('steps') WHERE name = 'idx' AND pk = 1)
        AND (SELECT COUNT(*) FROM pragma_table_info('steps') WHERE pk > 0) = 1
    """

    private static func dataSQL(
        after index: Int,
        through lastIndex: Int?,
        includeStepMetadata: Bool = false
    ) -> String {
        let upperBound = lastIndex.map { " AND idx <= \($0)" } ?? ""
        let stepMetadataColumn = includeStepMetadata
            ? ",\n            'step_hex', (SELECT CASE WHEN length(steps.metadata) <= \(maximumBlobBytes) THEN hex(steps.metadata) ELSE NULL END FROM steps WHERE steps.idx = g.idx)"
            : ""
        let stepBytesColumn = includeStepMetadata
            ? ", length((SELECT metadata FROM steps WHERE steps.idx = gen_metadata.idx)) AS step_bytes"
            : ""
        let stepSourceBytes = includeStepMetadata
            ? "CASE WHEN step_bytes <= \(maximumBlobBytes) THEN COALESCE(step_bytes, 0) ELSE 0 END"
            : "0"
        return """
        WITH candidates AS (
            SELECT idx, data\(stepBytesColumn) FROM gen_metadata
            WHERE idx > \(index)\(upperBound) AND data IS NOT NULL
            ORDER BY idx
            LIMIT \(batchSize)
        ), bounded AS (
            SELECT idx, data\(includeStepMetadata ? ", step_bytes" : ""),
                SUM((CASE WHEN length(data) <= \(maximumBlobBytes) THEN length(data) ELSE 0 END) + (\(stepSourceBytes)))
                    OVER (ORDER BY idx ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS source_bytes
            FROM candidates
        ), accepted AS (
            SELECT idx, data FROM bounded
            WHERE source_bytes <= \(maximumBatchSourceBytes)
            ORDER BY idx
        ), page_state AS (
            SELECT EXISTS (
                SELECT 1 FROM gen_metadata
                WHERE idx > (SELECT MAX(idx) FROM accepted) AND data IS NOT NULL\(upperBound)
            ) AS has_more
        )
        SELECT json_group_array(json_object('index', g.idx, 'bytes', length(g.data), 'hex',
            CASE WHEN length(g.data) <= \(maximumBlobBytes) THEN hex(g.data) ELSE NULL END\(stepMetadataColumn),
            'has_more', json(CASE WHEN page_state.has_more THEN 'true' ELSE 'false' END)))
        FROM accepted g CROSS JOIN page_state
        """
    }

    private func cachedDatabase(path: String, since: Date, observedAt: Date) throws -> CachedDatabase? {
        var didRetry = false
        while true {
            do {
                return try cachedDatabaseOnce(path: path, since: since, observedAt: observedAt)
            } catch {
                let message = error.localizedDescription
                guard !Task.isCancelled,
                      !didRetry,
                      message == Self.changedDuringScanMessage || Self.isRetryableSQLiteFailure(message)
                else { throw error }
                didRetry = true
            }
        }
    }

    private static func isRetryableSQLiteFailure(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("locked")
            || normalized.contains("busy")
            || normalized.contains("timed out")
            || normalized.contains("unable to open database file")
            || normalized.contains("cannot open database file")
    }

    private static func isUnsupportedStepMetadataProbe(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("no such table: pragma_table_info")
            || normalized.contains("no such function: pragma_table_info")
            || normalized.contains("pragma_table_info is not supported")
    }

    private func cachedDatabaseOnce(path: String, since: Date, observedAt: Date) throws -> CachedDatabase? {
        let fingerprint = try DatabaseFingerprint(path: path)
        guard fingerprint.latestModification >= since else { return nil }

        if var cached = scanCache[path], cached.fingerprint == fingerprint, cached.windowStart <= since {
            if cached.windowStart < since {
                Self.prune(&cached, before: since)
                scanCache[path] = cached
            }
            return cached
        }

        var cached = scanCache[path]
        if cached?.fingerprint.databaseIdentity != fingerprint.databaseIdentity
            || (cached?.fingerprint.databaseSize ?? 0) > fingerprint.databaseSize
            || (cached?.windowStart ?? since) > since
        {
            cached = nil
        }

        var cachedContentFingerprint: ContentFingerprint?
        var contentFingerprintUnavailable = sqliteSupportsSHA3Aggregate == false
        var prefixVerifiedBeforeRead = false

        // A changed database can rewrite an old row and append a new one in the same transaction.
        // Verify the full cached generation prefix before retaining it, then read any appended rows.
        // SQLite CLI builds with SHA3 support verify the prefix and produce the new table fingerprint
        // in one compact, ordered aggregate query. Older CLI builds use the paced batch fallback.
        if let existing = cached, existing.fingerprint != fingerprint {
            guard !Task.isCancelled else { return nil }
            if !contentFingerprintUnavailable {
                do {
                    cachedContentFingerprint = try Self.contentFingerprint(
                        path: path,
                        through: existing.lastIndex,
                        sqlite: sqlite,
                        includeStepMetadata: existing.hasStepMetadata == true
                    )
                    if cachedContentFingerprint != nil { sqliteSupportsSHA3Aggregate = true }
                } catch {
                    contentFingerprintUnavailable = Self.isSHA3Unavailable(error)
                    if contentFingerprintUnavailable { sqliteSupportsSHA3Aggregate = false }
                }
            }
            guard !Task.isCancelled else { return nil }

            if let cachedContentFingerprint, let previous = existing.contentFingerprint {
                if cachedContentFingerprint.maximumIndex < existing.lastIndex
                    || cachedContentFingerprint.prefixFingerprint != previous
                {
                    cached = nil
                } else {
                    prefixVerifiedBeforeRead = true
                }
            } else {
                // SHA3 is optional in SQLite CLI builds. The bounded row verifier detects a
                // truncated prefix, so defer to the single final maximum-index check for changes.
                let prefixMatches = try Self.cachedRowsMatch(path: path, cached: existing, sqlite: sqlite)
                guard !Task.isCancelled else { return nil }
                if !prefixMatches {
                    cached = nil
                } else {
                    prefixVerifiedBeforeRead = true
                }
            }
        }

        let retainedPrefix = cached
        var refreshed = cached ?? CachedDatabase(fingerprint: fingerprint, windowStart: since)
        refreshed.fingerprint = fingerprint
        refreshed.windowStart = since
        refreshed.aggregate = nil
        Self.prune(&refreshed, before: since)
        try readDatabase(path: path, since: since, observedAt: observedAt, into: &refreshed)
        guard !Task.isCancelled else { return nil }

        let comparablePrefix = retainedPrefix.flatMap {
            $0.hasStepMetadata == refreshed.hasStepMetadata ? $0 : nil
        }
        // The compact query on a changed cache already returns both the prior-prefix digest and
        // the whole-table digest. Reuse it after the tail read; the final file revision check below
        // ensures the database did not change between that query and the completed scan.
        var summary: ContentFingerprint?
        if let cachedContentFingerprint, comparablePrefix != nil {
            summary = cachedContentFingerprint
        } else if !contentFingerprintUnavailable {
            do {
                summary = try Self.contentFingerprint(
                    path: path,
                    through: comparablePrefix?.lastIndex ?? refreshed.lastIndex,
                    sqlite: sqlite,
                    includeStepMetadata: refreshed.hasStepMetadata == true,
                    prefixEqualsTable: comparablePrefix == nil
                )
                if summary != nil { sqliteSupportsSHA3Aggregate = true }
            } catch {
                contentFingerprintUnavailable = Self.isSHA3Unavailable(error)
                if contentFingerprintUnavailable { sqliteSupportsSHA3Aggregate = false }
            }
        }
        if let summary {
            guard summary.maximumIndex == refreshed.lastIndex else {
                throw SQLiteError.queryFailed(Self.changedDuringScanMessage)
            }
            if let comparablePrefix {
                if let expected = comparablePrefix.contentFingerprint {
                    guard summary.prefixFingerprint == expected else {
                        throw SQLiteError.queryFailed(Self.changedDuringScanMessage)
                    }
                } else if !prefixVerifiedBeforeRead {
                    guard try Self.cachedRowsMatch(path: path, cached: comparablePrefix, sqlite: sqlite) else {
                        throw SQLiteError.queryFailed(Self.changedDuringScanMessage)
                    }
                }
            }
            refreshed.contentFingerprint = summary.tableFingerprint
        } else {
            // SHA3 is optional in SQLite CLI builds. Preserve the bounded batch fallback there.
            guard try Self.maximumIndex(path: path, sqlite: sqlite) == refreshed.lastIndex else {
                throw SQLiteError.queryFailed(Self.changedDuringScanMessage)
            }
            if let comparablePrefix, !prefixVerifiedBeforeRead,
               !(try Self.cachedRowsMatch(path: path, cached: comparablePrefix, sqlite: sqlite))
            {
                throw SQLiteError.queryFailed(Self.changedDuringScanMessage)
            }
            refreshed.contentFingerprint = nil
        }

        guard !Task.isCancelled else { return nil }
        guard try DatabaseFingerprint(path: path) == fingerprint else {
            throw SQLiteError.queryFailed(Self.changedDuringScanMessage)
        }

        scanCache[path] = refreshed
        return refreshed
    }

    private static func prune(_ cached: inout CachedDatabase, before since: Date) {
        JSONLAccountingWorkPacer.shared.perform {
            cached.events.removeAll {
                Date(timeIntervalSince1970: TimeInterval($0.timestampSeconds)) < since
            }
            cached.undatedUsageTimestamps.removeAll { Date(timeIntervalSince1970: TimeInterval($0)) < since }
            cached.invalidTokenTimestamps.removeAll { Date(timeIntervalSince1970: TimeInterval($0)) < since }
            cached.malformedUsageTimestamps.removeAll { Date(timeIntervalSince1970: TimeInterval($0)) < since }
            cached.oversizedTimestamps.removeAll { Date(timeIntervalSince1970: TimeInterval($0)) < since }
        }
        cached.windowStart = since
    }

    /// A database renamed within a discovered conversation directory keeps its device/inode identity.
    /// Move the cache entry before treating the old path as missing; otherwise one database could be
    /// folded once from its new path and again from the old cached path.
    private func rebindMovedDatabaseCaches(to activePaths: Set<String>) {
        for newPath in activePaths.sorted() where scanCache[newPath] == nil {
            guard let identifier = Self.databaseIdentity(at: newPath) else { continue }
            let oldPath = scanCache.first { entry in
                !activePaths.contains(entry.key)
                    && entry.value.fingerprint.databaseIdentity == identifier
            }?.key
            guard let oldPath, let cached = scanCache.removeValue(forKey: oldPath) else { continue }
            scanCache[newPath] = cached
        }
    }

    /// If identity probing briefly failed, two aliases of one database can both acquire cached
    /// rows. Once a later scan identifies and deduplicates them, retire the inactive alias cache so
    /// it is not mistaken for a missing database and folded a second time.
    private func discardDuplicateCachedDatabaseAliases(activePaths: Set<String>) {
        let activeIdentities = Set(activePaths.compactMap { Self.databaseIdentity(at: $0) })
        guard !activeIdentities.isEmpty else { return }
        for path in Array(scanCache.keys) where !activePaths.contains(path) {
            guard let cached = scanCache[path],
                  activeIdentities.contains(cached.fingerprint.databaseIdentity)
            else { continue }
            scanCache.removeValue(forKey: path)
        }
    }

    private static func databaseIdentity(at path: String) -> DatabaseIdentity? {
        (try? fileStamp(at: path))?.identity
    }

    private func readDatabase(path: String, since: Date, observedAt: Date, into cached: inout CachedDatabase) throws {
        // Modern Antigravity stores put generation times in the matching steps.metadata row instead
        // of gen_metadata.data. Recheck legacy databases when their file changes: an app upgrade can
        // add the table while QuotaBar is running. If that happens, replay cached indices so formerly
        // undated events are recovered. Unchanged databases return from cachedDatabase before this
        // query, so idle refreshes still pay no schema-probe cost.
        let hasStepMetadata: Bool
        let stepMetadataDiagnosticKey = "provider.antigravity.step-metadata-probe.\(JSONLScanCachePaths.stableFingerprint(path))"
        do {
            hasStepMetadata = try sqlite.queryValue(path: path, sql: Self.stepMetadataProbeSQL) == "1"
            DiagnosticGate.clearFailure(stepMetadataDiagnosticKey)
        } catch {
            if Self.isRetryableSQLiteFailure(error.localizedDescription) {
                throw SQLiteError.queryFailed(error.localizedDescription)
            }
            guard Self.isUnsupportedStepMetadataProbe(error.localizedDescription) else {
                throw SQLiteError.queryFailed(error.localizedDescription)
            }
            // Older or restricted SQLite CLIs may reject table-valued PRAGMA. The generation rows
            // remain readable without the correlated timestamp; their history is surfaced as partial.
            DiagnosticGate.logOnce(for: stepMetadataDiagnosticKey) {
                AppLog.warn(
                    LogTag.plugin("antigravity"),
                    "could not inspect Antigravity step metadata in \(path); reading generation rows without it: \(error.localizedDescription)"
                )
            }
            hasStepMetadata = false
        }
        if let previousHasStepMetadata = cached.hasStepMetadata,
           previousHasStepMetadata != hasStepMetadata
        {
            cached.lastIndex = -1
            cached.rowCount = 0
            cached.tableFingerprint = Self.emptyTableFingerprint
            cached.contentFingerprint = nil
            cached.events.removeAll()
            cached.invalidTokenTimestamps.removeAll()
            cached.malformedUsageTimestamps.removeAll()
            cached.undatedUsageTimestamps.removeAll()
            cached.oversizedTimestamps.removeAll()
        }
        cached.hasStepMetadata = hasStepMetadata
        let includeStepMetadata = cached.hasStepMetadata ?? false
        let observedTimestamp = Int64(observedAt.timeIntervalSince1970)

        while !Task.isCancelled {
            guard let payload = try JSONLAccountingWorkPacer.shared.perform({
                try sqlite.queryValue(
                    path: path,
                    sql: Self.dataSQL(after: cached.lastIndex, through: nil, includeStepMetadata: includeStepMetadata)
                )
            }) else { break }
            let rows = try JSONLAccountingWorkPacer.shared.perform {
                try JSONDecoder().decode([Row].self, from: Data(payload.utf8))
            }
            guard !rows.isEmpty else { break }
            let hasMore = rows.last?.hasMore ?? (rows.count == Self.batchSize)
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
                        // The generation bytes are unavailable, so its identifiers cannot validate
                        // an index-correlated step timestamp. Mark the first-observed day instead.
                        if observedAt >= since { cached.oversizedTimestamps.append(observedTimestamp) }
                        continue
                    }
                    guard let blob = Self.bytes(fromHex: hex) else { continue }
                    switch AntigravityProtoDecoder.decodeGenerationEvent(
                        from: blob,
                        stepMetadata: row.stepHex.flatMap(Self.bytes(fromHex:)),
                        observationTimestamp: observedTimestamp
                    ) {
                    case .ignored:
                        continue
                    case .invalidTokenCount(let timestamp):
                        let recordedAt = timestamp ?? observedTimestamp
                        if Date(timeIntervalSince1970: TimeInterval(recordedAt)) >= since {
                            cached.invalidTokenTimestamps.append(recordedAt)
                        }
                    case .malformedUsage(let timestamp):
                        let recordedAt = timestamp ?? observedTimestamp
                        if Date(timeIntervalSince1970: TimeInterval(recordedAt)) >= since {
                            cached.malformedUsageTimestamps.append(recordedAt)
                        }
                    case .undatedUsage:
                        if observedAt >= since { cached.undatedUsageTimestamps.append(observedTimestamp) }
                    case .event(let event):
                        guard Date(timeIntervalSince1970: TimeInterval(event.timestampSeconds)) >= since else {
                            continue
                        }
                        cached.events.append(event)
                        if event.timestampIsInferred {
                            cached.undatedUsageTimestamps.append(event.timestampSeconds)
                        }
                    }
                }
            }
            guard hasMore else { break }
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
        sqlite: SQLiteAccessing,
        includeStepMetadata: Bool,
        prefixEqualsTable: Bool = false
    ) throws -> ContentFingerprint? {
        guard let value = try JSONLAccountingWorkPacer.shared.perform({
            try sqlite.queryValue(
                path: path,
                sql: contentFingerprintSQL(
                    through: lastCachedIndex,
                    includeStepMetadata: includeStepMetadata,
                    prefixEqualsTable: prefixEqualsTable
                )
            )
        }) else {
            return nil
        }
        let fields = value.split(separator: "|", omittingEmptySubsequences: false)
        guard fields.count == 3,
              let maximumIndex = Int(fields[0])
        else { return nil }
        let tableFingerprint = String(fields[2])
        return ContentFingerprint(
            maximumIndex: maximumIndex,
            prefixFingerprint: prefixEqualsTable ? tableFingerprint : String(fields[1]),
            tableFingerprint: tableFingerprint
        )
    }

    /// The explicit aggregate order is required because the fingerprint represents an ordered table
    /// prefix. SQLite CLI builds without `sha3` / `sha3_agg` fail this query and use `cachedRowsMatch`.
    private static func contentFingerprintSQL(
        through lastCachedIndex: Int,
        includeStepMetadata: Bool,
        prefixEqualsTable: Bool = false
    ) -> String {
        let stepDigest = includeStepMetadata
            ? "COALESCE((SELECT CASE WHEN metadata IS NULL THEN 'missing' WHEN length(metadata) <= \(maximumBlobBytes) THEN hex(sha3(metadata, 256)) ELSE 'oversized' END FROM steps WHERE idx = g.idx), 'missing')"
            : "''"
        let prefixDigest = prefixEqualsTable
            ? "''"
            : "COALESCE(hex(sha3_agg(CASE WHEN idx <= \(lastCachedIndex) THEN printf('%d:%d:%s:%s;', idx, byteCount, rowDigest, stepDigest) END ORDER BY idx)), '')"
        return """
        WITH rows AS MATERIALIZED (
            SELECT g.idx, length(g.data) AS byteCount,
                CASE WHEN length(g.data) <= \(maximumBlobBytes)
                    THEN hex(sha3(g.data, 256)) ELSE 'oversized' END AS rowDigest,
                \(stepDigest) AS stepDigest
            FROM gen_metadata g
            WHERE g.data IS NOT NULL
        )
        SELECT COALESCE(MAX(idx), -1) || '|' ||
            \(prefixDigest) || '|' ||
            COALESCE(hex(sha3_agg(
                printf('%d:%d:%s:%s;', idx, byteCount, rowDigest, stepDigest) ORDER BY idx
            )), '')
        FROM rows
        """
    }

    private static func isSHA3Unavailable(_ error: Error) -> Bool {
        error.localizedDescription.lowercased().contains("no such function: sha3")
    }

    private static func cachedRowsMatch(
        path: String,
        cached: CachedDatabase,
        sqlite: SQLiteAccessing
    ) throws -> Bool {
        if cached.rowCount == 0 { return cached.lastIndex == -1 }
        var cursor = -1
        var rowCount = 0
        var fingerprint = emptyTableFingerprint
        while cursor < cached.lastIndex {
            try Task.checkCancellation()
            let queriedPayload: String?
            do {
                queriedPayload = try JSONLAccountingWorkPacer.shared.perform { () throws -> String? in
                    try Task.checkCancellation()
                    return try sqlite.queryValue(
                        path: path,
                        sql: dataSQL(
                            after: cursor,
                            through: cached.lastIndex,
                            includeStepMetadata: cached.hasStepMetadata == true
                        )
                    )
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                if Self.isRetryableSQLiteFailure(error.localizedDescription) {
                    throw SQLiteError.queryFailed(error.localizedDescription)
                }
                return false
            }
            try Task.checkCancellation()
            guard let payload = queriedPayload else { return false }
            guard let rows = try? JSONLAccountingWorkPacer.shared.perform({
                try JSONDecoder().decode([Row].self, from: Data(payload.utf8))
            }), !rows.isEmpty else { return false }
            let validBatch = try JSONLAccountingWorkPacer.shared.perform { () throws -> Bool in
                for row in rows {
                    try Task.checkCancellation()
                    guard row.index > cursor else { return false }
                    fingerprint = advancingFingerprint(fingerprint, with: rowFingerprint(row))
                    cursor = row.index
                    rowCount += 1
                }
                return true
            }
            try Task.checkCancellation()
            guard validBatch else { return false }
        }
        return rowCount == cached.rowCount
            && cursor == cached.lastIndex
            && fingerprint == cached.tableFingerprint
    }

    private static func rowFingerprint(_ row: Row) -> DatabaseRowFingerprint {
        let digest: Data?
        if row.hex != nil || row.stepHex != nil {
            var hasher = SHA256()
            if let hex = row.hex {
                hasher.update(data: Data([1]))
                hasher.update(data: Data(hex.utf8))
            } else {
                hasher.update(data: Data([0]))
            }
            if let stepHex = row.stepHex {
                hasher.update(data: Data([1]))
                hasher.update(data: Data(stepHex.utf8))
            } else {
                hasher.update(data: Data([0]))
            }
            digest = Data(hasher.finalize())
        } else {
            digest = nil
        }
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
        let stepHex: String?
        let hasMore: Bool?

        enum CodingKeys: String, CodingKey {
            case index
            case byteCount = "bytes"
            case hex
            case stepHex = "step_hex"
            case hasMore = "has_more"
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

    private struct DatabaseIdentity: Hashable {
        let device: UInt64
        let inode: UInt64
    }

    private struct FileStamp: Equatable {
        let identity: DatabaseIdentity
        let size: Int64
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
        let changeSeconds: Int64
        let changeNanoseconds: Int64

        var modificationDate: Date {
            Date(
                timeIntervalSince1970: Double(modificationSeconds)
                    + Double(modificationNanoseconds) / 1_000_000_000
            )
        }

        var changeDate: Date {
            Date(
                timeIntervalSince1970: Double(changeSeconds)
                    + Double(changeNanoseconds) / 1_000_000_000
            )
        }
    }

    private static func fileStamp(at path: String, missingAllowed: Bool = false) throws -> FileStamp? {
        let resolvedPath = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        var value = stat()
        guard Darwin.lstat(resolvedPath, &value) == 0 else {
            if missingAllowed, errno == ENOENT { return nil }
            throw SQLiteError.queryFailed("Antigravity database revision could not be read")
        }
        guard value.st_size >= 0 else {
            throw SQLiteError.queryFailed("Antigravity database has a negative size")
        }
        return FileStamp(
            identity: DatabaseIdentity(device: UInt64(value.st_dev), inode: UInt64(value.st_ino)),
            size: Int64(value.st_size),
            modificationSeconds: Int64(value.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(value.st_mtimespec.tv_nsec),
            changeSeconds: Int64(value.st_ctimespec.tv_sec),
            changeNanoseconds: Int64(value.st_ctimespec.tv_nsec)
        )
    }

    private struct DatabaseFingerprint: Equatable {
        let database: FileStamp
        let wal: FileStamp?

        init(path: String) throws {
            guard let database = try AntigravityDbUsageScanner.fileStamp(at: path) else {
                throw SQLiteError.queryFailed("Antigravity database disappeared during revision check")
            }
            self.database = database
            wal = try AntigravityDbUsageScanner.fileStamp(at: path + "-wal", missingAllowed: true)
        }

        var databaseIdentity: DatabaseIdentity { database.identity }
        var databaseSize: Int64 { database.size }
        var latestModification: Date {
            max(
                max(database.modificationDate, database.changeDate),
                max(wal?.modificationDate ?? .distantPast, wal?.changeDate ?? .distantPast)
            )
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
        var oversizedTimestamps: [Int64] = []
        var invalidTokenTimestamps: [Int64] = []
        var malformedUsageTimestamps: [Int64] = []
        var undatedUsageTimestamps: [Int64] = []
        var hasStepMetadata: Bool?
        var aggregate: CachedAggregate?
    }

    private struct CachedAggregate {
        let pricingToken: String
        let windowStart: Date
        let timeZoneIdentifier: String
        let scan: LogUsageScan
        let recomputeAfter: Date?
        let latestAcceptedTimestamp: Int64?
    }
}
