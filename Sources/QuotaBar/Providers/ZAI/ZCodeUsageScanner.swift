import Foundation

struct ZCodeAllowance: Sendable, Equatable {
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

struct ZCodeUsageResult: Sendable, Equatable {
    var totalTokens: Double?
    var planName: String?
    var logScan: LogUsageScan?
    var weekendBuild: ZCodeAllowance?
    /// `model_usage` rows excluded from totals because they were corrupt (non-integer or negative
    /// token columns). Surfaced as a historyWarning so a partial history explains itself instead
    /// of silently reading low.
    var damagedRows: Int = 0

    var dailySeries: DailyUsageSeries? {
        logScan?.series
    }

    init(
        totalTokens: Double? = nil,
        planName: String? = nil,
        logScan: LogUsageScan? = nil,
        dailySeries: DailyUsageSeries? = nil,
        weekendBuild: ZCodeAllowance? = nil,
        damagedRows: Int = 0
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
    private var cachedResult: ZCodeUsageResult?
    private var cachedSqliteStamp: (size: UInt64, mtime: TimeInterval)?
    private var cachedLevelDBStamp: (size: UInt64, mtime: TimeInterval)?
    private var cachedPricingToken: String?

    init(
        sqlite: any SQLiteAccessing = SQLiteCLIAccessor(allowsReadWriteFallback: true),
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
        let currentSqliteStamp = Self.sqliteStamp(at: expanded)
        let currentLevelDBStamp = levelDBStamp()
        let currentPricingToken = pricing.aggregateCacheToken

        if let cached = lock.withLock({ () -> ZCodeUsageResult? in
            guard cachedSqliteStamp?.size == currentSqliteStamp?.size,
                  cachedSqliteStamp?.mtime == currentSqliteStamp?.mtime,
                  cachedLevelDBStamp?.size == currentLevelDBStamp?.size,
                  cachedLevelDBStamp?.mtime == currentLevelDBStamp?.mtime,
                  cachedPricingToken == currentPricingToken else {
                return nil
            }
            if let now, let allowance = cachedResult?.weekendBuild {
                if let exp = allowance.expiresAt, exp <= now { return nil }
                if let eff = allowance.effectiveAt, eff <= now, allowance.used == 0 { return nil }
            }
            return cachedResult
        }) {
            return cached
        }

        try Task.checkCancellation()

        // Local sqlite history is one source; the LevelDB entitlement is another. Neither is
        // required: a missing or unreadable source yields its part as nil instead of hiding the
        // other source's data (a fresh Weekend Build plan has no sqlite db yet, for example).
        var totalTokens: Double? = nil
        var planName: String? = nil
        var logScan: LogUsageScan? = nil
        var damagedRows = 0

        if currentSqliteStamp != nil {
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
                    totalTokens = total > 0 ? total : nil
                } else if !parts[0].isEmpty {
                    throw ZCodeUsageError.invalidUsage
                }
                damagedRows = Int(parts[1]) ?? 0
                if parts.count > 2 {
                    let providerID = parts[2...].joined(separator: "|")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if providerID.contains("start-plan") {
                        planName = "Start Plan"
                    } else if providerID.contains("coding-plan") {
                        planName = "Coding Plan"
                    }
                }
            }

            // Daily series for spend tiles (Today, Yesterday, Last 30 Days)
            logScan = readDailySeries(pricing: pricing)
        }

        // Read live entitlement from LevelDB (e.g. Weekend Build total token allowance)
        let entitlement = scanLevelDBEntitlement(leveldbPath: leveldbPath, now: now)
        if planName == nil, let entitlementPlan = entitlement?.planName {
            planName = entitlementPlan
        }

        if totalTokens == nil && logScan == nil && entitlement == nil {
            // Neither source yielded anything readable — no result to build (and nothing to cache).
            return nil
        }

        let result = ZCodeUsageResult(
            totalTokens: totalTokens,
            planName: planName,
            logScan: logScan,
            weekendBuild: entitlement?.weekendBuild,
            damagedRows: damagedRows
        )
        lock.withLock {
            cachedResult = result
            cachedSqliteStamp = currentSqliteStamp
            cachedLevelDBStamp = currentLevelDBStamp
            cachedPricingToken = currentPricingToken
        }
        return result
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
            WHERE input_tokens >= 0 AND output_tokens >= 0
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
            WHERE input_tokens >= 0 AND output_tokens >= 0
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
            cachedResult = nil
            cachedSqliteStamp = nil
            cachedLevelDBStamp = nil
            cachedPricingToken = nil
        }
    }

    private static func sqliteStamp(at path: String) -> (size: UInt64, mtime: TimeInterval)? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? UInt64,
              let mdate = attrs[.modificationDate] as? Date else { return nil }
        return (size, mdate.timeIntervalSinceReferenceDate)
    }

    private func levelDBStamp() -> (size: UInt64, mtime: TimeInterval)? {
        let expanded = (leveldbPath as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: .skipsHiddenFiles
        ) else { return nil }
        var maxMtime: TimeInterval = 0
        var totalSize: UInt64 = 0
        for file in files where file.pathExtension == "log" || file.pathExtension == "ldb" {
            let vals = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let mtime = vals?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
            let sz = UInt64(vals?.fileSize ?? 0)
            if mtime > maxMtime { maxMtime = mtime }
            totalSize += sz
        }
        return totalSize > 0 ? (totalSize, maxMtime) : nil
    }

    /// Key prefix shared by every ZCode entitlement snapshot regardless of plan or account suffix
    /// (`…:subscription-v2:account:zai-start-plan:…`, future coding/pro plan keys included). The
    /// scanner must not hardcode one plan's key or a new promotional plan silently stops showing.
    static let entitlementKeyPrefix = "zcode:usage-entitlement:subscription-v2:account:"
    static let entitlementJSONMarker = "{\"cachedAt\""
    /// Cap on bytes scanned per JSON body — the entitlement snapshot is a few KB.
    static let maxEntitlementJSONBytes = 25_000

    private func scanLevelDBEntitlement(
        leveldbPath: String,
        now: Date? = nil
    ) -> (planName: String?, weekendBuild: ZCodeAllowance?)? {
        let expanded = (leveldbPath as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: .skipsHiddenFiles
        ) else { return nil }

        let levelFiles = files.filter { $0.pathExtension == "log" || $0.pathExtension == "ldb" }
        let sorted = levelFiles.sorted {
            let d1 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let d2 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return d1 > d2
        }

        let keyPrefix = Data(Self.entitlementKeyPrefix.utf8)
        let jsonMarker = Data(Self.entitlementJSONMarker.utf8)

        // LevelDB compaction copies a key into several files (and the newest copy is not always in
        // the newest file), so scan every occurrence everywhere and keep the snapshot with the
        // highest `cachedAt` instead of trusting file ordering.
        var bestSnapshot: [String: Any]?
        var bestCachedAt: Double = -1
        autoreleasepool {
            for file in sorted {
                guard let data = try? Data(contentsOf: file) else { continue }
                var searchStart = data.startIndex
                while searchStart < data.endIndex,
                      let keyRange = data.range(of: keyPrefix, in: searchStart..<data.endIndex) {
                    let scanFrom = keyRange.upperBound
                    guard let markerRange = data.range(of: jsonMarker, in: scanFrom..<data.endIndex),
                          markerRange.lowerBound - scanFrom < 512 else {
                        searchStart = keyRange.upperBound
                        continue
                    }
                    if let snapshot = Self.parseEntitlementSnapshot(data, from: markerRange.lowerBound) {
                        let cachedAt = snapshot.cachedAt
                        if cachedAt > bestCachedAt {
                            bestCachedAt = cachedAt
                            bestSnapshot = snapshot.root
                        }
                        searchStart = markerRange.upperBound
                    } else {
                        searchStart = markerRange.upperBound
                    }
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
            planName = level == "Start" ? "Start Plan" : (level == "Coding" ? "Coding Plan" : "\(level) Plan")
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
                let isBuild = productID.contains("build") || productID.contains("wk") || rawName.localizedCaseInsensitiveContains("build")
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
                guard planId.contains("wk") || planId.contains("build") || isOneTime || promos[planId] != nil else { continue }
                seenPlanIDs.insert(planId)

                let unit = limit["unit"] as? Double ?? Double(limit["unit"] as? Int ?? 0)
                guard unit > 0 else { continue }
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

        for (prodID, promo) in promos where !seenPlanIDs.contains(prodID) {
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
