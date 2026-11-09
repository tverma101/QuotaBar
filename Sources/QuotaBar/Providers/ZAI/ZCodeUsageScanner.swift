import Foundation

struct ZCodeAllowance: Sendable, Equatable {
    var label: String
    var used: Double
    var limit: Double
    var remaining: Double
    var resetsAt: Date?
}

struct ZCodeUsageResult: Sendable, Equatable {
    var totalTokens: Double?
    var planName: String?
    var logScan: LogUsageScan?
    var weekendBuild: ZCodeAllowance?

    var dailySeries: DailyUsageSeries? {
        logScan?.series
    }

    init(
        totalTokens: Double? = nil,
        planName: String? = nil,
        logScan: LogUsageScan? = nil,
        dailySeries: DailyUsageSeries? = nil,
        weekendBuild: ZCodeAllowance? = nil
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
        return FileManager.default.fileExists(atPath: expanded)
    }

    func totalTokens(pricing: ModelPricing = .empty) throws -> Double? {
        try usage(pricing: pricing)?.totalTokens
    }

    func usage(pricing: ModelPricing = .empty) throws -> ZCodeUsageResult? {
        try Task.checkCancellation()
        let expanded = (path as NSString).expandingTildeInPath
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: expanded),
              let size = attrs[.size] as? UInt64,
              let mdate = attrs[.modificationDate] as? Date else {
            lock.withLock {
                cachedResult = nil
                cachedSqliteStamp = nil
                cachedLevelDBStamp = nil
                cachedPricingToken = nil
            }
            return nil
        }
        let currentSqliteStamp = (size, mdate.timeIntervalSinceReferenceDate)
        let currentLevelDBStamp = levelDBStamp()
        let currentPricingToken = pricing.aggregateCacheToken

        if let cached = lock.withLock({ () -> ZCodeUsageResult? in
            guard let sStamp = cachedSqliteStamp,
                  sStamp.size == currentSqliteStamp.0,
                  sStamp.mtime == currentSqliteStamp.1,
                  cachedLevelDBStamp?.size == currentLevelDBStamp?.size,
                  cachedLevelDBStamp?.mtime == currentLevelDBStamp?.mtime,
                  cachedPricingToken == currentPricingToken else {
                return nil
            }
            return cachedResult
        }) {
            return cached
        }

        try Task.checkCancellation()
        let sql = """
            SELECT (SELECT CASE WHEN SUM(CASE WHEN typeof(input_tokens) != 'integer'
                OR typeof(output_tokens) != 'integer' OR input_tokens < 0 OR output_tokens < 0
                THEN 1 ELSE 0 END) > 0 THEN 'invalid'
                ELSE CAST(SUM(CAST(input_tokens AS REAL) + CAST(output_tokens AS REAL)) AS TEXT) END
            FROM model_usage) || '|' || COALESCE((SELECT provider_id FROM model_usage WHERE provider_id LIKE 'account:zai%' ORDER BY started_at DESC LIMIT 1), '');
            """
        let raw = try sqlite.queryValue(path: path, sql: sql)
        try Task.checkCancellation()

        guard let raw else {
            lock.withLock {
                cachedResult = nil
                cachedSqliteStamp = currentSqliteStamp
                cachedLevelDBStamp = currentLevelDBStamp
                cachedPricingToken = currentPricingToken
            }
            return nil
        }

        let parts = raw.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard let tokenString = parts.first else { throw ZCodeUsageError.invalidUsage }
        guard tokenString != "invalid" else { throw ZCodeUsageError.invalidUsage }

        var totalTokens: Double? = nil
        if let total = Double(tokenString), total.isFinite, total >= 0 {
            totalTokens = total > 0 ? total : nil
        } else if !tokenString.isEmpty {
            throw ZCodeUsageError.invalidUsage
        }

        var planName: String? = nil
        if parts.count > 1 {
            let providerID = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if providerID.contains("start-plan") {
                planName = "Start Plan"
            } else if providerID.contains("coding-plan") {
                planName = "Coding Plan"
            }
        }

        // Daily series for spend tiles (Today, Yesterday, Last 30 Days)
        var logScan: LogUsageScan? = nil
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
                logScan = built
            }
        } else {
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
                    logScan = LogUsageScan(series: DailyUsageSeries(daily: entries), modelUsage: nil, unknownModelsByDay: [:])
                }
            }
        }

        // Read live entitlement from LevelDB (e.g. Weekend Build total token allowance)
        let entitlement = scanLevelDBEntitlement(leveldbPath: leveldbPath)
        if planName == nil, let entitlementPlan = entitlement?.planName {
            planName = entitlementPlan
        }

        let result = ZCodeUsageResult(
            totalTokens: totalTokens,
            planName: planName,
            logScan: logScan,
            weekendBuild: entitlement?.weekendBuild
        )
        lock.withLock {
            cachedResult = result
            cachedSqliteStamp = currentSqliteStamp
            cachedLevelDBStamp = currentLevelDBStamp
            cachedPricingToken = currentPricingToken
        }
        return result
    }

    func unloadCachesForMemoryPressure() {
        lock.withLock {
            cachedResult = nil
            cachedSqliteStamp = nil
            cachedLevelDBStamp = nil
            cachedPricingToken = nil
        }
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

    private func scanLevelDBEntitlement(leveldbPath: String) -> (planName: String?, weekendBuild: ZCodeAllowance?)? {
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

        let key = Data("zcode:usage-entitlement:subscription-v2:account:zai-start-plan".utf8)
        let jsonMarker = Data("{\"cachedAt\"".utf8)

        for file in sorted {
            guard let data = try? Data(contentsOf: file) else { continue }
            guard let keyRange = data.range(of: key, options: .backwards) else { continue }
            let searchStart = keyRange.upperBound
            guard let markerRange = data.range(of: jsonMarker, options: [], in: searchStart..<data.count) else { continue }
            let braceStart = markerRange.lowerBound

            var depth = 0
            var jsonEnd = braceStart
            for i in braceStart..<min(braceStart + 25000, data.count) {
                if data[i] == 0x7B { depth += 1 }
                else if data[i] == 0x7D {
                    depth -= 1
                    if depth == 0 {
                        jsonEnd = i + 1
                        break
                    }
                }
            }
            guard depth == 0 else { continue }
            let jsonBytes = data[braceStart..<jsonEnd]
            guard let root = try? JSONSerialization.jsonObject(with: jsonBytes) as? [String: Any],
                  let snapshot = root["snapshot"] as? [String: Any] else { continue }

            var planName: String? = nil
            if let quota = snapshot["quota"] as? [String: Any],
               let level = quota["level"] as? String {
                if level == "Start" { planName = "Start Plan" }
                else if level == "Coding" { planName = "Coding Plan" }
                else { planName = "\(level) Plan" }
            }

            var weekendBuild: ZCodeAllowance? = nil
            if let quota = snapshot["quota"] as? [String: Any],
               let limits = quota["limits"] as? [[String: Any]] {
                for limit in limits {
                    let planId = limit["planId"] as? String ?? ""
                    let period = limit["period"] as? String ?? ""
                    let isWeekendBuild = planId.contains("wk") || period == "one_time"
                    if isWeekendBuild {
                        let unit = limit["unit"] as? Double ?? Double(limit["unit"] as? Int ?? 0)
                        let usage = limit["usage"] as? Double ?? Double(limit["usage"] as? Int ?? 0)
                        let remaining = limit["remaining"] as? Double ?? Double(limit["remaining"] as? Int ?? 0)
                        var resetsAt: Date? = nil
                        if let resetMs = limit["nextResetTime"] as? Double ?? (limit["nextResetTime"] as? Int).map(Double.init) {
                            resetsAt = Date(timeIntervalSince1970: resetMs / 1000)
                        }
                        if unit > 0 {
                            weekendBuild = ZCodeAllowance(
                                label: "Weekend Build",
                                used: usage,
                                limit: unit,
                                remaining: remaining,
                                resetsAt: resetsAt
                            )
                            break
                        }
                    }
                }
            }
            return (planName, weekendBuild)
        }
        return nil
    }
}

enum ZCodeUsageError: Error, LocalizedError {
    case invalidUsage
    var errorDescription: String? { "Couldn't read ZCode token usage." }
}
