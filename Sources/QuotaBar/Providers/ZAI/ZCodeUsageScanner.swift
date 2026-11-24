import Foundation

struct ZCodeAllowance: Sendable, Equatable, Codable {
    var label: String
    var used: Double
    var limit: Double
    var remaining: Double
    var resetsAt: Date?
    /// When the backing purchase ends (`subscription.details[].expireTime`). Promotional
    /// `one_time` buckets expire rather than reset, so `resetsAt` stays nil for them.
    var expiresAt: Date?
    /// Scheduled start time (`entitlements[].effectiveTime` or `beginTime`) for an upcoming promo.
    var effectiveAt: Date? = nil
}

struct ZCodeUsageResult: Sendable, Equatable, Codable {
    var totalTokens: Double?
    var planName: String?
    var logScan: LogUsageScan?
    var weekendBuild: ZCodeAllowance?
    /// `model_usage` rows excluded from totals because they were corrupt (non-integer or negative
    /// token columns). Surfaced as a historyWarning so a partial history explains itself instead
    /// of silently reading low.
    var damagedRows: Int = 0
    /// The sqlite half of the scan threw (corrupt db, schema mismatch); the LevelDB entitlement
    /// still surfaced. Recorded so the provider can warn rather than silently reading low.
    var sqliteReadFailure: String? = nil

    var dailySeries: DailyUsageSeries? {
        logScan?.series
    }

    init(
        totalTokens: Double? = nil,
        planName: String? = nil,
        logScan: LogUsageScan? = nil,
        dailySeries: DailyUsageSeries? = nil,
        weekendBuild: ZCodeAllowance? = nil,
        damagedRows: Int = 0,
        sqliteReadFailure: String? = nil
    ) {
        self.totalTokens = totalTokens
        self.planName = planName
        if let logScan {
            self.logScan = logScan
        } else if let dailySeries {
            self.logScan = LogUsageScan(
                series: dailySeries,
                modelUsage: nil,
                unknownModelsByDay: [:]
            )
        } else {
            self.logScan = nil
        }
        self.weekendBuild = weekendBuild
        self.damagedRows = damagedRows
        self.sqliteReadFailure = sqliteReadFailure
    }
}

/// Local ZCode App Usage. ZCode records the full prompt (including cache hits) in input_tokens,
/// so adding its cache columns again would double-count them. This is not a Coding Plan quota.
final class ZCodeUsageScanner: @unchecked Sendable {
    static let defaultSqlitePath = "~/.zcode/cli/db/db.sqlite"
    static let defaultLevelDBPath = "~/Library/Application Support/ZCode/session/Local Storage/leveldb"

    let sqlite: any SQLiteAccessing
    let path: String
    let leveldbPath: String

    private let lock = NSLock()
    /// The local sqlite history's share of a result. Cached on the database file's own stamp and
    /// the pricing token so a LevelDB-only change never re-runs the sqlite queries.
    private struct SqlitePart {
        var totalTokens: Double?
        var planName: String?
        var logScan: LogUsageScan?
        var damagedRows: Int = 0
        var sqliteError: Error? = nil
    }
    private var cachedSqlitePart: SqlitePart?
    private var cachedSqliteStamp: (size: UInt64, mtime: TimeInterval)?
    private var cachedSqlitePricingToken: String?
    /// The LevelDB entitlement's share on its own stamp. `hasCachedEntitlement` distinguishes
    /// "scanned, found nothing" from "never scanned" — a cached nil is a real answer.
    private var cachedEntitlement: (planName: String?, weekendBuild: ZCodeAllowance?)?
    private var hasCachedEntitlement = false
    private var cachedLevelDBStamp: (size: UInt64, mtime: TimeInterval)?
    private var cachedScanDate: Date?

    init(
        sqlite: any SQLiteAccessing = NativeSQLiteAccessor(allowsReadWriteFallback: true),
        path: String = defaultSqlitePath,
        leveldbPath: String = defaultLevelDBPath
    ) {
        self.sqlite = sqlite
        self.path = path
        self.leveldbPath = leveldbPath
    }

    func hasHistory() -> Bool {
        let expanded = (path as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: expanded) { return true }
        // A LevelDB entitlement without local sqlite history (fresh plan, cleared db) is still
        // usage QuotaBar can render — don't report "nothing here" and skip the refresh.
        let dbPath = (leveldbPath as NSString).expandingTildeInPath
        return FileManager.default.fileExists(atPath: dbPath)
    }

    func totalTokens(pricing: ModelPricing = .empty) throws -> Double? {
        try usage(pricing: pricing)?.totalTokens
    }

    func usage(pricing: ModelPricing = .empty, now: Date? = nil) throws -> ZCodeUsageResult? {
        try Task.checkCancellation()
        let expanded = (path as NSString).expandingTildeInPath
        // Stamps are optional per source: a missing sqlite file must not blind the LevelDB
        // entitlement scan (and vice versa), so the cache compares each source independently.
        // One directory listing feeds both the LevelDB stamp and the entitlement scan — the
        // .log/.ldb files used to be stat'd twice per refresh.
        let currentSqliteStamp = Self.sqliteStamp(at: expanded)
        let levelDBFiles = loadLevelDBFiles()
        let currentLevelDBStamp = Self.levelDBStamp(levelDBFiles)
        let currentPricingToken = pricing.aggregateCacheToken

        let memoryWarmForAllSources = lock.withLock {
            cachedSqlitePart != nil
                && cachedSqliteStamp?.size == currentSqliteStamp?.size
                && cachedSqliteStamp?.mtime == currentSqliteStamp?.mtime
                && cachedSqlitePricingToken == currentPricingToken
                && hasCachedEntitlement
                && cachedLevelDBStamp?.size == currentLevelDBStamp?.size
                && cachedLevelDBStamp?.mtime == currentLevelDBStamp?.mtime
        }
        // A fresh scan-worker child has no in-memory cache; the persisted record lets it answer
        // an unchanged fold without spawning sqlite or touching LevelDB again.
        if !memoryWarmForAllSources,
           let persisted = ZCodeUsageCachePersistence.read(),
           persisted.sqlitePath == path,
           persisted.leveldbPath == leveldbPath,
           persisted.sqliteSize == currentSqliteStamp?.size,
           persisted.sqliteMtime == currentSqliteStamp?.mtime,
           persisted.leveldbSize == currentLevelDBStamp?.size,
           persisted.leveldbMtime == currentLevelDBStamp?.mtime,
           persisted.pricingToken == currentPricingToken,
           Self.promoStillValid(persisted.result.weekendBuild, scannedAt: persisted.scannedAt,
                                now: now ?? Date()) {
            lock.withLock {
                cachedSqlitePart = SqlitePart(
                    totalTokens: persisted.result.totalTokens,
                    planName: persisted.result.planName,
                    logScan: persisted.result.logScan,
                    damagedRows: persisted.result.damagedRows
                )
                cachedSqliteStamp = currentSqliteStamp
                cachedSqlitePricingToken = currentPricingToken
                cachedEntitlement = (planName: persisted.result.planName, weekendBuild: persisted.result.weekendBuild)
                hasCachedEntitlement = true
                cachedLevelDBStamp = currentLevelDBStamp
                cachedScanDate = persisted.scannedAt
            }
            return persisted.result
        }

        try Task.checkCancellation()

        // Local sqlite history is one source; the LevelDB entitlement is another. Neither is
        // required: a missing or unreadable source yields its part as nil instead of hiding the
        // other source's data (a fresh Weekend Build plan has no sqlite db yet, for example).
        let sqlitePart = try sqliteUsage(stamp: currentSqliteStamp, pricing: pricing)
        try Task.checkCancellation()
        let entitlement = levelDBEntitlement(
            stamp: currentLevelDBStamp,
            files: levelDBFiles,
            now: now
        )

        var planName = sqlitePart.planName
        if planName == nil, let entitlementPlan = entitlement?.planName {
            planName = entitlementPlan
        }

        if sqlitePart.totalTokens == nil && sqlitePart.logScan == nil && entitlement == nil {
            // Neither source yielded anything readable — no result to build (and nothing to
            // cache). A sqlite failure without an entitlement fallback still fails loudly.
            if let sqliteError = sqlitePart.sqliteError { throw sqliteError }
            return nil
        }

        let result = ZCodeUsageResult(
            totalTokens: sqlitePart.totalTokens,
            planName: planName,
            logScan: sqlitePart.logScan,
            weekendBuild: entitlement?.weekendBuild,
            damagedRows: sqlitePart.damagedRows,
            sqliteReadFailure: sqlitePart.sqliteError?.localizedDescription
        )
        let scannedAt = now ?? Date()
        lock.withLock { cachedScanDate = scannedAt }
        if sqlitePart.sqliteError == nil {
            ZCodeUsageCachePersistence.write(ZCodeUsageCachePersistence.Record(
                schema: ZCodeUsageCachePersistence.schema,
                sqlitePath: path,
                leveldbPath: leveldbPath,
                sqliteSize: currentSqliteStamp?.size,
                sqliteMtime: currentSqliteStamp?.mtime,
                leveldbSize: currentLevelDBStamp?.size,
                leveldbMtime: currentLevelDBStamp?.mtime,
                pricingToken: currentPricingToken,
                scannedAt: scannedAt,
                result: result
            ))
        }
        return result
    }

    /// The sqlite-history share of the result, cached against the database file's own stamp and
    /// the pricing token. The queries are skipped entirely while the database file is absent (a
    /// nil stamp), the same source-gating the prior all-or-nothing cache applied.
    private func sqliteUsage(
        stamp: (size: UInt64, mtime: TimeInterval)?,
        pricing: ModelPricing
    ) throws -> SqlitePart {
        let pricingToken = pricing.aggregateCacheToken
        if let cached = lock.withLock({ () -> SqlitePart? in
            guard let cachedSqlitePart,
                  cachedSqliteStamp?.size == stamp?.size,
                  cachedSqliteStamp?.mtime == stamp?.mtime,
                  cachedSqlitePricingToken == pricingToken else {
                return nil
            }
            return cachedSqlitePart
        }) {
            return cached
        }

        var part = SqlitePart()
        if stamp != nil {
            do {
                // Valid-row total + damaged-row count instead of a blanket 'invalid' sentinel: one
                // corrupt row in model_usage must not throw away the whole card's history. Damaged
                // rows are excluded from the total and reported (damagedRows > 0 → historyWarning).
                let sql = """
                    SELECT (SELECT CAST(COALESCE(SUM(CASE WHEN typeof(input_tokens) != 'integer'
                            OR typeof(output_tokens) != 'integer' OR input_tokens < 0 OR output_tokens < 0
                            THEN 0 ELSE CAST(input_tokens AS REAL) + CAST(output_tokens AS REAL) END), 0) AS TEXT)
                        FROM model_usage) || '|' ||
                        CAST((SELECT COUNT(*) FROM model_usage WHERE typeof(input_tokens) != 'integer'
                            OR typeof(output_tokens) != 'integer' OR input_tokens < 0 OR output_tokens < 0) AS TEXT)
                        || '|' || COALESCE((SELECT provider_id FROM model_usage WHERE provider_id LIKE 'account:zai%' ORDER BY started_at DESC LIMIT 1), '');
                    """
                let raw = try sqlite.queryValue(path: path, sql: sql)
                try Task.checkCancellation()

                if let raw {
                    // parts[0] is the valid-row total, parts[1] the damaged-row count, and the
                    // provider_id tail is joined back in case it ever contains the '|' delimiter.
                    let parts = raw.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                    guard parts.count >= 2 else { throw ZCodeUsageError.invalidUsage }
                    if let total = Double(parts[0]), total.isFinite, total >= 0 {
                        part.totalTokens = total > 0 ? total : nil
                    } else if !parts[0].isEmpty {
                        throw ZCodeUsageError.invalidUsage
                    }
                    part.damagedRows = Int(parts[1]) ?? 0
                    if parts.count > 2 {
                        let providerID = parts[2...].joined(separator: "|")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if providerID.contains("start-plan") {
                            part.planName = "Start Plan"
                        } else if providerID.contains("coding-plan") {
                            part.planName = "Coding Plan"
                        }
                    }
                }

                // Daily series for spend tiles (Today, Yesterday, Last 30 Days)
                part.logScan = readDailySeries(pricing: pricing)
            } catch {
                // A dead sqlite source must not hide a valid LevelDB entitlement: record the
                // failure for the provider to surface and keep scanning the other source.
                if ProviderCancellation.isCancellation(error) { throw error }
                part.sqliteError = error
            }
        }

        if part.sqliteError == nil {
            lock.withLock {
                cachedSqlitePart = part
                cachedSqliteStamp = stamp
                cachedSqlitePricingToken = pricingToken
            }
        }
        return part
    }

    /// The LevelDB entitlement share, cached against the leveldb stamp. The expiry recheck mirrors
    /// the previous all-or-nothing cache: an allowance that expired (or became active) since the
    /// stamp was taken forces a fresh derivation even though the files did not move.
    private func levelDBEntitlement(
        stamp: (size: UInt64, mtime: TimeInterval)?,
        files: [LevelDBFile]?,
        now: Date?
    ) -> (planName: String?, weekendBuild: ZCodeAllowance?)? {
        let cached: (hit: Bool, value: (planName: String?, weekendBuild: ZCodeAllowance?)?) = lock.withLock {
            guard hasCachedEntitlement,
                  cachedLevelDBStamp?.size == stamp?.size,
                  cachedLevelDBStamp?.mtime == stamp?.mtime else {
                return (false, nil)
            }
            if let now, let allowance = cachedEntitlement?.weekendBuild {
                if !Self.promoStillValid(allowance, scannedAt: cachedScanDate, now: now) {
                    return (false, nil)
                }
            }
            return (true, cachedEntitlement)
        }
        if cached.hit { return cached.value }

        let entitlement = scanLevelDBEntitlement(files: files, now: now)
        lock.withLock {
            cachedEntitlement = entitlement
            hasCachedEntitlement = true
            cachedLevelDBStamp = stamp
            if let now { cachedScanDate = now }
        }
        return entitlement
    }

    /// The promo rules the cache must re-apply on every hit: an expired bucket invalidates, and a
    /// promo that went live *after* the scan invalidates exactly once (an already-active unused
    /// promo would otherwise rescan on every call forever).
    private static func promoStillValid(_ allowance: ZCodeAllowance?, scannedAt: Date?, now: Date) -> Bool {
        guard let allowance else { return true }
        if let exp = allowance.expiresAt, exp <= now { return false }
        if let eff = allowance.effectiveAt, eff <= now, allowance.used == 0,
           let scannedAt, eff > scannedAt {
            return false
        }
        return true
    }

    /// The per-day model usage series read from the local sqlite history, for spend tiles and the
    /// Usage History screen. Corrupt rows are excluded by the query itself and skipped during
    /// parsing; a schema without model/cache columns falls back to a bare day-total query.
    private func readDailySeries(pricing: ModelPricing) -> LogUsageScan? {
        let dailySql = """
            SELECT date(started_at / 1000, 'unixepoch', 'localtime') || '|' ||
                   model_id || '|' ||
                   CAST(SUM(input_tokens) AS TEXT) || '|' ||
                   CAST(SUM(output_tokens) AS TEXT) || '|' ||
                   CAST(SUM(cache_read_input_tokens) AS TEXT) || '|' ||
                   CAST(SUM(cache_creation_input_tokens) AS TEXT)
            FROM model_usage
            WHERE typeof(input_tokens) = 'integer' AND typeof(output_tokens) = 'integer'
                AND input_tokens >= 0 AND output_tokens >= 0
            GROUP BY date(started_at / 1000, 'unixepoch', 'localtime'), model_id
            ORDER BY date(started_at / 1000, 'unixepoch', 'localtime') DESC;
            """
        if let dailyRaw = try? sqlite.queryValue(path: path, sql: dailySql) {
            var accumulator = DailyUsageAccumulator()
            let lines = dailyRaw.split(whereSeparator: \.isNewline)
            autoreleasepool {
                for line in lines {
                    let segments = line.split(separator: "|", omittingEmptySubsequences: false)
                    guard segments.count >= 6 else { continue }
                    let day = String(segments[0])
                    let model = String(segments[1])
                    guard let input = Int(segments[2]), input >= 0,
                          let output = Int(segments[3]), output >= 0,
                          let cacheRead = Int(segments[4]), cacheRead >= 0,
                          let cacheCreation = Int(segments[5]), cacheCreation >= 0 else { continue }
                    let rowTokens = input + output
                    guard rowTokens > 0 else { continue }
                    let uncachedInput = max(0, input - cacheRead - cacheCreation)
                    let tokens = TokenBreakdown(
                        input: uncachedInput,
                        cacheWrite5m: cacheCreation,
                        cacheRead: cacheRead,
                        output: output
                    )
                    let cost = pricing.estimatedCostDollars(model: model, tokens: tokens)
                    let canonical = pricing.canonicalName(for: model) ?? model
                    accumulator.add(
                        day: day,
                        tokens: rowTokens,
                        cost: cost,
                        model: model,
                        canonical: canonical
                    )
                    if cost != nil {
                        accumulator.markEstimatedCost(day: day)
                    }
                    accumulator.recordApiEstimate(day: day, cost: cost, tokens: rowTokens)
                }
            }
            let built = accumulator.build()
            if !built.series.daily.isEmpty {
                return built
            }
            return nil
        }
        // Fallback for minimal schemas (e.g. test fixtures without model_id/cache columns)
        let fallbackSql = """
            SELECT date(started_at / 1000, 'unixepoch', 'localtime') || ':' || CAST(SUM(input_tokens + output_tokens) AS TEXT)
            FROM model_usage
            WHERE typeof(input_tokens) = 'integer' AND typeof(output_tokens) = 'integer'
                AND input_tokens >= 0 AND output_tokens >= 0
            GROUP BY date(started_at / 1000, 'unixepoch', 'localtime')
            ORDER BY date(started_at / 1000, 'unixepoch', 'localtime') DESC;
            """
        if let fallbackRaw = try? sqlite.queryValue(path: path, sql: fallbackSql) {
            let lines = fallbackRaw.split(whereSeparator: \.isNewline)
            var entries: [DailyUsageEntry] = []
            for line in lines {
                let segments = line.split(separator: ":", maxSplits: 1)
                guard segments.count == 2, let tokens = Int(segments[1]), tokens > 0 else { continue }
                entries.append(DailyUsageEntry(date: String(segments[0]), totalTokens: tokens, costUSD: nil, costIsComplete: false))
            }
            if !entries.isEmpty {
                return LogUsageScan(series: DailyUsageSeries(daily: entries), modelUsage: nil, unknownModelsByDay: [:])
            }
        }
        return nil
    }

    func unloadCachesForMemoryPressure() {
        lock.withLock {
            cachedSqlitePart = nil
            cachedSqliteStamp = nil
            cachedSqlitePricingToken = nil
            cachedEntitlement = nil
            hasCachedEntitlement = false
            cachedLevelDBStamp = nil
            cachedScanDate = nil
        }
    }

    private static func sqliteStamp(at path: String) -> (size: UInt64, mtime: TimeInterval)? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? UInt64,
              let mdate = attrs[.modificationDate] as? Date else { return nil }
        var stamp = (size: size, mtime: mdate.timeIntervalSinceReferenceDate)
        // WAL-mode writes land in the -wal sidecar and only merge at checkpoint time; include it
        // so writes between checkpoints still invalidate the cache.
        if let wal = try? FileManager.default.attributesOfItem(atPath: path + "-wal") {
            stamp.size += wal[.size] as? UInt64 ?? 0
            if let walDate = wal[.modificationDate] as? Date {
                stamp.mtime = max(stamp.mtime, walDate.timeIntervalSinceReferenceDate)
            }
        }
        return stamp
    }

    /// One LevelDB `.log`/`.ldb` file with the attributes the stamp and the scan ordering need —
    /// fetched once per `usage()` call so the directory is never stat'd twice.
    private struct LevelDBFile {
        var url: URL
        var modified: TimeInterval
        var size: UInt64
    }

    private func loadLevelDBFiles() -> [LevelDBFile]? {
        let expanded = (leveldbPath as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: .skipsHiddenFiles
        ) else { return nil }
        var levelFiles: [LevelDBFile] = []
        for file in files where file.pathExtension == "log" || file.pathExtension == "ldb" {
            let vals = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            levelFiles.append(LevelDBFile(
                url: file,
                modified: vals?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0,
                size: UInt64(vals?.fileSize ?? 0)
            ))
        }
        return levelFiles
    }

    private static func levelDBStamp(_ files: [LevelDBFile]?) -> (size: UInt64, mtime: TimeInterval)? {
        guard let files else { return nil }
        var maxMtime: TimeInterval = 0
        var totalSize: UInt64 = 0
        for file in files {
            if file.modified > maxMtime { maxMtime = file.modified }
            totalSize += file.size
        }
        return totalSize > 0 ? (totalSize, maxMtime) : nil
    }

    /// Key prefix shared by every ZCode entitlement snapshot regardless of plan or account suffix
    /// (`…:subscription-v2:account:zai-start-plan:…`, future coding/pro plan keys included). The
    /// scanner must not hardcode one plan's key or a new promotional plan silently stops showing.
    static let entitlementKeyPrefix = "zcode:usage-entitlement:subscription-v2:account:"
    /// Marker inside the JSON body; `cachedAt` is not guaranteed to be the first key, so the scan
    /// locates it and walks `{` candidates back to the snapshot's opening brace.
    static let entitlementJSONMarker = "\"cachedAt\""
    /// The record's JSON body lands within this many bytes of the entitlement key.
    static let entitlementValueSearchWindow = 512
    /// Cap on bytes scanned per JSON body — the entitlement snapshot is a few KB.
    static let maxEntitlementJSONBytes = 25_000

    private func scanLevelDBEntitlement(
        files: [LevelDBFile]?,
        now: Date? = nil
    ) -> (planName: String?, weekendBuild: ZCodeAllowance?)? {
        guard let files else { return nil }
        let sorted = files.sorted { $0.modified > $1.modified }

        let keyPrefix = Data(Self.entitlementKeyPrefix.utf8)
        let jsonMarker = Data(Self.entitlementJSONMarker.utf8)

        // LevelDB compaction copies a key into several files (and the newest copy is not always in
        // the newest file), so scan every occurrence everywhere and keep the snapshot with the
        // highest `cachedAt` instead of trusting file ordering.
        var bestSnapshot: [String: Any]?
        var bestCachedAt: Double = -1
        autoreleasepool {
            for file in sorted {
                guard let data = try? Data(contentsOf: file.url) else { continue }
                var searchStart = data.startIndex
                while searchStart < data.endIndex,
                      let keyRange = data.range(of: keyPrefix, in: searchStart..<data.endIndex) {
                    let scanFrom = keyRange.upperBound
                    let windowEnd = min(scanFrom + Self.entitlementValueSearchWindow, data.endIndex)
                    guard let markerRange = data.range(of: jsonMarker, in: scanFrom..<windowEnd) else {
                        searchStart = keyRange.upperBound
                        continue
                    }
                    // Walk '{' candidates back from the marker toward the key; the first one that
                    // parses into a JSON body carrying `cachedAt` is the snapshot root.
                    var pos = markerRange.lowerBound
                    while pos > scanFrom {
                        pos -= 1
                        guard data[pos] == 0x7B else { continue }
                        if let snapshot = Self.parseEntitlementSnapshot(data, from: pos),
                           snapshot.root["cachedAt"] != nil {
                            if snapshot.cachedAt > bestCachedAt {
                                bestCachedAt = snapshot.cachedAt
                                bestSnapshot = snapshot.root
                            }
                            break
                        }
                    }
                    searchStart = markerRange.upperBound
                }
            }
        }

        guard let snapshot = bestSnapshot else { return nil }
        return Self.entitlement(from: snapshot, now: now)
    }

    /// Brace-matches the JSON body starting at `braceStart` and decodes it. Returns the parsed root
    /// plus its `cachedAt` stamp so the caller can keep the freshest copy across LevelDB files.
    private static func parseEntitlementSnapshot(
        _ data: Data, from braceStart: Data.Index
    ) -> (root: [String: Any], cachedAt: Double)? {
        var depth = 0
        var jsonEnd = braceStart
        for i in braceStart..<min(braceStart + maxEntitlementJSONBytes, data.endIndex) {
            if data[i] == 0x7B { depth += 1 }
            else if data[i] == 0x7D {
                depth -= 1
                if depth == 0 {
                    jsonEnd = i + 1
                    break
                }
            }
        }
        guard depth == 0 else { return nil }
        guard let root = try? JSONSerialization.jsonObject(with: data[braceStart..<jsonEnd]) as? [String: Any] else {
            return nil
        }
        let cachedAt = root["cachedAt"] as? Double ?? (root["cachedAt"] as? Int).map(Double.init) ?? -1
        return (root, cachedAt)
    }

    /// A promo reset instant, but only when it is ahead of `now` and inside a believable horizon —
    /// the same guard as `ZAIUsageMapper.resetDate`. A zero, a stale value, or seconds reported
    /// where milliseconds were expected would otherwise render as "Resets soon" or as a countdown
    /// in the year 55000 on every refresh. An implausible instant is dropped (the allowance shows
    /// without a date) rather than turned into a date we don't believe.
    private static func plausibleResetDate(ms milliseconds: Double, now: Date?) -> Date? {
        guard milliseconds > 0 else { return nil }
        let date = Date(timeIntervalSince1970: milliseconds / 1000)
        guard let now else { return date }
        guard date > now, date.timeIntervalSince(now) <= ZAIUsageMapper.maximumResetHorizon else { return nil }
        return date
    }

    /// Reads plan name, promotional allowance (Weekend Build / Global Build), and expiry.
    /// Expired allowances auto-remove when `now` is provided; upcoming scheduled promos are detected.
    private static func entitlement(
        from root: [String: Any],
        now: Date? = nil
    ) -> (planName: String?, weekendBuild: ZCodeAllowance?)? {
        guard let snapshot = root["snapshot"] as? [String: Any] else { return nil }

        var planName: String? = nil
        if let quota = snapshot["quota"] as? [String: Any], let level = quota["level"] as? String {
            planName = level == "Start" ? "Start Plan" : (level == "Coding" ? "Coding Plan" : "\(level.capitalized) Plan")
        }

        struct PromoInfo {
            var productID: String; var label: String; var effectiveAt: Date?; var expiresAt: Date?
        }
        var promos: [String: PromoInfo] = [:]
        var expiryByProductID: [String: Date] = [:]

        if let subscription = snapshot["subscription"] as? [String: Any],
           let details = subscription["details"] as? [[String: Any]] {
            for detail in details {
                guard let productID = detail["productId"] as? String else { continue }
                let expire = (detail["expireTime"] as? String).flatMap(OpenUsageISO8601.date)
                if let expire { expiryByProductID[productID] = expire }

                let billingCycle = detail["billingCycle"] as? String ?? ""
                let rawName = detail["productName"] as? String ?? ""
                let isOneTime = billingCycle == "one_time"
                let isBuild = productID.contains("build") || productID.hasSuffix("wk") || productID.contains("-wk")
                    || rawName.localizedCaseInsensitiveContains("build")
                guard isOneTime || isBuild else { continue }

                var effDate = (detail["beginTime"] as? String).flatMap(OpenUsageISO8601.date)
                if let entitlements = detail["entitlements"] as? [[String: Any]] {
                    for ent in entitlements {
                        if let effText = ent["effectiveTime"] as? String, let d = OpenUsageISO8601.date(from: effText) {
                            effDate = d; break
                        }
                    }
                }

                let label: String
                if rawName.localizedCaseInsensitiveContains("Global Build") { label = "Global Build" }
                else if rawName.localizedCaseInsensitiveContains("Weekend Build") { label = "Weekend Build" }
                else if !rawName.isEmpty {
                    var c = rawName; if c.uppercased().hasPrefix("ZCODE ") { c = String(c.dropFirst(6)) }
                    label = c.capitalized.isEmpty ? "Weekend Build" : c.capitalized
                } else { label = "Weekend Build" }

                promos[productID] = PromoInfo(productID: productID, label: label, effectiveAt: effDate, expiresAt: expire)
            }
        }

        var allowances: [ZCodeAllowance] = []
        var seenPlanIDs = Set<String>()

        if let quota = snapshot["quota"] as? [String: Any], let limits = quota["limits"] as? [[String: Any]] {
            for limit in limits {
                let planId = limit["planId"] as? String ?? ""
                let isOneTime = (limit["period"] as? String ?? "") == "one_time"
                let isWeeklyPlan = planId.hasSuffix("wk") || planId.contains("-wk")
                guard isWeeklyPlan || planId.contains("build") || isOneTime || promos[planId] != nil else { continue }

                let unit = limit["unit"] as? Double ?? Double(limit["unit"] as? Int ?? 0)
                // A dropped limit row (no positive cap) must not suppress the promo fallback below.
                guard unit > 0 else { continue }
                seenPlanIDs.insert(planId)
                let usage = limit["usage"] as? Double ?? Double(limit["usage"] as? Int ?? 0)
                let remaining = limit["remaining"] as? Double ?? Double(limit["remaining"] as? Int ?? 0)
                var resetMs = limit["nextResetTime"] as? Double ?? (limit["nextResetTime"] as? Int).map(Double.init)
                var expiresAt = promos[planId]?.expiresAt ?? expiryByProductID[planId]
                if isOneTime {
                    // `one_time` buckets expire rather than reset; when the purchase record carried
                    // no expireTime, the reset instant stands in for the expiry.
                    if expiresAt == nil, let resetMs { expiresAt = plausibleResetDate(ms: resetMs, now: now) }
                    resetMs = nil
                }
                allowances.append(ZCodeAllowance(
                    label: promos[planId]?.label ?? "Weekend Build",
                    used: usage, limit: unit, remaining: remaining,
                    resetsAt: resetMs.flatMap { plausibleResetDate(ms: $0, now: now) },
                    expiresAt: expiresAt, effectiveAt: promos[planId]?.effectiveAt
                ))
            }
        }

        // Dictionary order is unstable; sort so candidate selection picks the same promo every time.
        let sortedPromos = promos.values.sorted { a, b in
            let aEff = a.effectiveAt ?? .distantFuture
            let bEff = b.effectiveAt ?? .distantFuture
            return aEff == bEff ? a.productID < b.productID : aEff < bEff
        }
        for promo in sortedPromos where !seenPlanIDs.contains(promo.productID) {
            allowances.append(ZCodeAllowance(
                label: promo.label, used: 0, limit: 500_000_000, remaining: 500_000_000,
                resetsAt: nil, expiresAt: promo.expiresAt, effectiveAt: promo.effectiveAt
            ))
        }

        let candidates = allowances.filter { allow in
            guard let now, let exp = allow.expiresAt else { return true }
            return exp > now
        }
        let refNow = now ?? .distantPast
        let activeWithRemaining = candidates.first { ($0.effectiveAt == nil || $0.effectiveAt! <= refNow) && $0.remaining > 0 }
        let activeDrained = candidates.first { ($0.effectiveAt == nil || $0.effectiveAt! <= refNow) && $0.remaining == 0 }
        let scheduled = candidates.first { $0.effectiveAt != nil && $0.effectiveAt! > refNow }
        let selected = activeWithRemaining ?? activeDrained ?? scheduled ?? (now == nil ? allowances.first : nil)

        return (planName, selected)
    }
}

enum ZCodeUsageError: Error, LocalizedError {
    case invalidUsage
    var errorDescription: String? { "Couldn't read ZCode token usage." }
}
