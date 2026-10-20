import CoreFoundation
import Foundation

/// The three token-count periods the Hermes card renders. Boundaries are the user's local calendar
/// (days grouped like every other provider's spend tiles), so "This Week" is the local Monday-start
/// week and "This Month" the local calendar month.
enum HermesPeriod: String, Sendable, Equatable, CaseIterable {
    case today
    case thisWeek
    case thisMonth

    var displayName: String {
        switch self {
        case .today: return "Today"
        case .thisWeek: return "This Week"
        case .thisMonth: return "This Month"
        }
    }
}

/// Token counts by bucket, mirroring Hermes' own accounting columns. Hermes records `input_tokens` as
/// the *uncached* (miss) portion, so summing the buckets never double-counts cached tokens.
struct HermesTokenCounts: Sendable, Equatable {
    var input: Int
    var output: Int
    var cacheRead: Int
    var cacheWrite: Int
    var reasoning: Int

    var total: Int { input + output + cacheRead + cacheWrite + reasoning }
}

/// One period's Hermes usage: token buckets, the sum of Hermes' per-session estimated cost, and the
/// API-call count (both are carried raw so the mapper can decide what to surface).
struct HermesPeriodUsage: Sendable, Equatable {
    var period: HermesPeriod
    var counts: HermesTokenCounts
    var costUSD: Double?
    var apiCallCount: Int
    var isPartial: Bool = false
}

/// One model's usage inside a period, from Hermes' per-model attribution rows
/// (`session_model_usage`, joined to `sessions` for the period boundary).
struct HermesModelUsage: Sendable, Equatable {
    var model: String
    var tokens: Int
    var costUSD: Double?
    var isPartial: Bool = false
}

/// The result of a Hermes scan: the three period rows, a daily token/cost series for the trend chart,
/// and per-period model breakdowns. Periods are always present (zero-filled by SQL `COALESCE`), so the
/// mapper decides what a zero period means; `daily` is empty when no session falls inside the window.
struct HermesUsageScan: Sendable, Equatable {
    var periods: [HermesPeriodUsage]
    var daily: DailyUsageSeries
    var modelUsageByPeriod: [HermesPeriod: [HermesModelUsage]]
    var partialDays: Set<String> = []
}

/// Reads Hermes' local SQLite session database (`~/.hermes/state.db`, or `$HERMES_HOME/state.db`) and
/// builds the usage the provider renders. Read-only and network-free: Hermes writes the token columns
/// (`input_tokens`, `output_tokens`, `cache_read_tokens`, `cache_write_tokens`, `reasoning_tokens`),
/// `api_call_count`, and `estimated_cost_usd` per session as it runs, and `session_model_usage` holds
/// the per-model attribution rows.
///
/// A `Sendable` struct (like the OpenCode scanner), `async` and nonisolated, so the SQLite reads run
/// off the main actor when the `@MainActor` provider `await`s it.
struct HermesUsageScanner: Sendable {
    var sqlite: SQLiteAccessing
    var databasePaths: @Sendable () throws -> [String]
    var calendar: Calendar

    init(
        sqlite: SQLiteAccessing = SQLiteCLIAccessor(),
        databasePaths: @escaping @Sendable () throws -> [String] = HermesUsageScanner.defaultDatabasePaths,
        calendar: Calendar = .current
    ) {
        self.sqlite = sqlite
        self.databasePaths = databasePaths
        self.calendar = calendar
    }

    /// `[]` when Hermes' state database doesn't exist (the normal "Hermes not used on this machine"
    /// case) — a present-but-unreadable file still yields its path so `scan` can surface the error.
    static let defaultDatabasePaths: @Sendable () throws -> [String] = {
        let environment = ProcessEnvironmentReader()
        let home = FileManager.default.homeDirectoryForCurrentUser
        let path = HermesPaths.stateDBPath(environment: environment, homeDirectory: home)
        return FileManager.default.fileExists(atPath: path) ? [path] : []
    }

    /// Scan the database. Returns `nil` when there is no Hermes database at all; throws
    /// `databaseUnreadable` when the database exists but a query fails — an all-failed scan has no data
    /// source and must not render as zero usage.
    func scan(now: Date) async throws -> HermesUsageScan? {
        guard !Task.isCancelled else { return nil }
        let paths: [String]
        do {
            paths = try databasePaths()
        } catch {
            throw HermesUsageError.databaseUnreadable(detail: error.localizedDescription)
        }
        guard let path = paths.first else { return nil }

        let starts = periodStarts(now: now)
        var periods: [HermesPeriodUsage] = []
        var modelUsage: [HermesPeriod: [HermesModelUsage]] = [:]

        // `session_model_usage` is Hermes' per-model/per-task attribution table (preferred source for
        // breakdowns); older installs may not have it, so the probe decides which query to run.
        guard !Task.isCancelled else { return nil }
        let hasModelTable = try? (JSONLAccountingWorkPacer.shared.perform {
            try sqlite.queryValue(path: path, sql: Self.modelTableProbeSQL) != nil
        })
        guard !Task.isCancelled else { return nil }

        for (period, start) in starts {
            guard !Task.isCancelled else { return nil }
            guard let sumJSON = try JSONLAccountingWorkPacer.shared.perform({
                try sqlite.queryValue(
                    path: path,
                    sql: Self.periodSQL(start: start, maximumTimestamp: JSONLScanning.maximumTimestamp(now: now))
                )
            }) else {
                throw HermesUsageError.databaseUnreadable(detail: "period query returned no result")
            }
            guard !Task.isCancelled else { return nil }
            guard let counts = JSONLAccountingWorkPacer.shared.perform({ Self.parsePeriod(sumJSON) }) else {
                throw HermesUsageError.databaseUnreadable(detail: "period query returned malformed accounting data")
            }
            periods.append(HermesPeriodUsage(
                period: period,
                counts: counts.counts,
                costUSD: counts.costUSD,
                apiCallCount: counts.apiCallCount,
                isPartial: counts.isPartial
            ))
            guard !Task.isCancelled else { return nil }
            guard let modelJSON = try JSONLAccountingWorkPacer.shared.perform({
                try sqlite.queryValue(
                    path: path,
                    sql: Self.modelsSQL(
                        start: start,
                        detailed: hasModelTable == true,
                        maximumTimestamp: JSONLScanning.maximumTimestamp(now: now)
                    )
                )
            }) else {
                throw HermesUsageError.databaseUnreadable(detail: "model query returned no result")
            }
            guard !Task.isCancelled else { return nil }
            guard let parsedModels = JSONLAccountingWorkPacer.shared.perform({ Self.parseModels(modelJSON) }) else {
                throw HermesUsageError.databaseUnreadable(detail: "model query returned malformed accounting data")
            }
            modelUsage[period] = parsedModels
        }

        // Keep the history screen on the same calendar-year boundary as the other local scanners.
        // A fixed number of days would drift around leap years and this helper requires its `through` date.
        let today = calendar.startOfDay(for: now)
        let dailyCutoff = calendar.date(byAdding: .year, value: -10, to: today)
            ?? calendar.date(byAdding: .day, value: -3_650, to: today)
            ?? calendar.startOfDay(for: now)
        let parsedDaily: ParsedDaily
        guard !Task.isCancelled else { return nil }
        if let dailyJSON = try JSONLAccountingWorkPacer.shared.perform({
            try sqlite.queryValue(
                path: path,
                sql: Self.dailySQL(cutoff: dailyCutoff, maximumTimestamp: JSONLScanning.maximumTimestamp(now: now))
            )
        }) {
            guard !Task.isCancelled else { return nil }
            guard let parsed = JSONLAccountingWorkPacer.shared.perform({ Self.parseDaily(dailyJSON) }) else {
                throw HermesUsageError.databaseUnreadable(detail: "daily query returned malformed accounting data")
            }
            parsedDaily = parsed
        } else {
            throw HermesUsageError.databaseUnreadable(detail: "daily query returned no result")
        }

        return HermesUsageScan(
            periods: periods,
            daily: parsedDaily.series,
            modelUsageByPeriod: modelUsage,
            partialDays: parsedDaily.partialDays
        )
    }

    // MARK: - Period boundaries (local calendar)

    private func periodStarts(now: Date) -> [(period: HermesPeriod, start: Date)] {
        let today = calendar.startOfDay(for: now)
        let weekday = calendar.component(.weekday, from: today) // 1=Sun ... 7=Sat
        let daysSinceMonday = (weekday + 5) % 7                 // Mon→0, Sun→6
        let weekStart = calendar.date(byAdding: .day, value: -daysSinceMonday, to: today) ?? today
        let monthStart = calendar.dateInterval(of: .month, for: now)?.start
            ?? calendar.date(from: calendar.dateComponents([.year, .month], from: now))
            ?? today
        return [
            (.today, today),
            (.thisWeek, weekStart),
            (.thisMonth, monthStart)
        ]
    }

    // MARK: - Parsing

    /// Period row shape: `[input, output, cacheRead, cacheWrite, reasoning, apiCallCount, costUSD, costIsComplete, invalidRows, hasActiveSession]`.
    private struct ParsedPeriod {
        var counts: HermesTokenCounts
        var costUSD: Double?
        var apiCallCount: Int
        var isPartial: Bool
    }

    private static func parsePeriod(_ json: String) -> ParsedPeriod? {
        guard let data = json.data(using: .utf8),
              let array = (try? JSONSerialization.jsonObject(with: data)) as? [Any],
              array.count == 10,
              let input = nonnegativeTokenCount(array[0]),
              let output = nonnegativeTokenCount(array[1]),
              let cacheRead = nonnegativeTokenCount(array[2]),
              let cacheWrite = nonnegativeTokenCount(array[3]),
              let reasoning = nonnegativeTokenCount(array[4]),
              let apiCallCount = nonnegativeTokenCount(array[5]),
              let costValue = nonnegativeCost(array[6]),
              let costCompleteFlag = nonnegativeTokenCount(array[7]),
              costCompleteFlag <= 1,
              let invalidRows = nonnegativeTokenCount(array[8]),
              invalidRows == 0,
              let activeSessions = nonnegativeTokenCount(array[9]),
              activeSessions <= 1 else {
            return nil
        }
        let costIsComplete = costCompleteFlag == 1
        let usableCost = costIsComplete
            ? (costValue > 0 ? costValue : nil)
            : nil
        return ParsedPeriod(
            counts: HermesTokenCounts(
                input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite, reasoning: reasoning
            ),
            costUSD: usableCost,
            apiCallCount: apiCallCount,
            isPartial: activeSessions == 1
        )
    }

    /// Model row shape: `[model, tokens, costUSD, costIsComplete, invalidRows, hasActiveSession]`;
    /// a missing or non-string model reads as "Unattributed" (mirrors the spend tiles' handling of
    /// models the source can't name).
    private static func parseModels(_ json: String) -> [HermesModelUsage]? {
        guard let data = json.data(using: .utf8),
              let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else {
            return nil
        }
        var rows: [HermesModelUsage] = []
        rows.reserveCapacity(parsed.count)
        for element in parsed {
            guard let entry = element as? [Any], entry.count == 6,
                  let tokens = nonnegativeTokenCount(entry[1]),
                  let cost = nonnegativeCost(entry[2]),
                  let costCompleteFlag = nonnegativeTokenCount(entry[3]), costCompleteFlag <= 1,
                  let invalidRows = nonnegativeTokenCount(entry[4]), invalidRows == 0,
                  let activeSessions = nonnegativeTokenCount(entry[5]), activeSessions <= 1
            else { return nil }
            let model = (entry[0] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let costIsComplete = costCompleteFlag == 1
            rows.append(HermesModelUsage(
                model: (model?.nilIfEmpty ?? ""),
                tokens: tokens,
                costUSD: costIsComplete
                    ? (cost > 0 ? cost : nil)
                    : nil,
                isPartial: activeSessions == 1
            ))
        }
        return rows.sorted { lhs, rhs in
            if lhs.tokens != rhs.tokens { return lhs.tokens > rhs.tokens }
            return lhs.model.localizedStandardCompare(rhs.model) == .orderedAscending
        }
    }

    /// Daily row shape: `[yyyy-MM-dd, tokens, costUSD, costIsComplete, invalidRows, hasActiveSession]`.
    private struct ParsedDaily {
        var series: DailyUsageSeries
        var partialDays: Set<String>
    }

    private static func parseDaily(_ json: String) -> ParsedDaily? {
        guard let data = json.data(using: .utf8),
              let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else {
            return nil
        }
        var daily: [DailyUsageEntry] = []
        var partialDays: Set<String> = []
        daily.reserveCapacity(parsed.count)
        for element in parsed {
            guard let entry = element as? [Any], entry.count == 6,
                  let day = entry[0] as? String,
                  let tokens = nonnegativeTokenCount(entry[1]),
                  let cost = nonnegativeCost(entry[2]),
                  let costCompleteFlag = nonnegativeTokenCount(entry[3]), costCompleteFlag <= 1,
                  let invalidRows = nonnegativeTokenCount(entry[4]), invalidRows == 0,
                  let activeSessions = nonnegativeTokenCount(entry[5]), activeSessions <= 1
            else { return nil }
            if activeSessions == 1 { partialDays.insert(day) }
            let costIsComplete = costCompleteFlag == 1
            // A session can carry a recorded cost even if its token buckets are empty or unavailable.
            // Keep that day in history so the lifetime report agrees with the Hermes period total.
            let totalTokens = tokens
            guard totalTokens > 0 || (costIsComplete && cost > 0) else { continue }
            daily.append(DailyUsageEntry(
                date: day,
                totalTokens: totalTokens,
                costUSD: costIsComplete
                    ? (cost > 0 ? cost : nil)
                    : nil,
                costIsComplete: costIsComplete
            ))
        }
        return ParsedDaily(series: DailyUsageSeries(daily: daily), partialDays: partialDays)
    }

    private static func nonnegativeTokenCount(_ value: Any) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        let count = number.doubleValue
        guard count.isFinite, count >= 0, count <= 1e15, count.rounded(.towardZero) == count else {
            return nil
        }
        return Int(count)
    }

    private static func nonnegativeCost(_ value: Any) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        let cost = number.doubleValue
        guard cost.isFinite, cost >= 0, cost <= 1e12 else { return nil }
        return cost
    }

    // MARK: - SQL

    static let modelTableProbeSQL = """
        SELECT name FROM sqlite_master
        WHERE type = 'table' AND name = 'session_model_usage';
        """

    /// Literal epoch seconds, embedded as a number (never user text). Rounded to milliseconds like the
    /// OpenCode scanner so the comparison is stable against REAL timestamps.
    private static func literal(_ date: Date) -> String {
        String(format: "%.3f", date.timeIntervalSince1970)
    }

    static func periodSQL(start: Date, maximumTimestamp: Date? = nil) -> String {
        let tokenExpression = tokenSumExpression(alias: nil)
        let costCompleteness = costCompletenessExpression(
            tokenExpression: tokenExpression,
            costExpression: "estimated_cost_usd"
        )
        let invalidRows = invalidRowsExpression(alias: nil, maximumTimestamp: maximumTimestamp)
        return """
        SELECT json_array(
                 COALESCE(SUM(input_tokens),0),
                 COALESCE(SUM(output_tokens),0),
                 COALESCE(SUM(cache_read_tokens),0),
                 COALESCE(SUM(cache_write_tokens),0),
                 COALESCE(SUM(reasoning_tokens),0),
                 COALESCE(SUM(api_call_count),0),
                 COALESCE(SUM(estimated_cost_usd),0),
                 \(costCompleteness),
                 \(invalidRows),
                 CASE WHEN COALESCE(SUM(CASE WHEN ended_at IS NULL THEN 1 ELSE 0 END),0) > 0 THEN 1 ELSE 0 END)
        FROM sessions
        WHERE started_at >= \(literal(start))
          AND \(nonOpenCodeBillingPredicate(sessionAlias: nil));
        """
    }

    static func modelsSQL(start: Date, detailed: Bool, maximumTimestamp: Date? = nil) -> String {
        // `json_group_array` is itself an aggregate, so SUM() must live in an inner subquery — nesting
        // aggregates directly is a SQLite error. In the detailed case the token columns are qualified
        // with `smu.` because `sessions` carries the same column names (ambiguous without it).
        let modelExpr = detailed ? "smu.model" : "model"
        let tokensExpr = tokenSumExpression(alias: detailed ? "smu" : nil)
        let costExpr = detailed ? "smu.estimated_cost_usd" : "estimated_cost_usd"
        let costCompleteness = costCompletenessExpression(
            tokenExpression: tokensExpr,
            costExpression: costExpr
        )
        let invalidRows = invalidRowsExpression(
            alias: detailed ? "smu" : nil,
            sessionAlias: detailed ? "s" : nil,
            maximumTimestamp: maximumTimestamp
        )
        let activeSessions = detailed
            ? "CASE WHEN SUM(CASE WHEN s.ended_at IS NULL THEN 1 ELSE 0 END) > 0 THEN 1 ELSE 0 END"
            : "CASE WHEN SUM(CASE WHEN ended_at IS NULL THEN 1 ELSE 0 END) > 0 THEN 1 ELSE 0 END"
        let source: String
        if detailed {
            source = """
                FROM session_model_usage smu
                JOIN sessions s ON s.id = smu.session_id
                WHERE s.started_at >= \(literal(start))
                  AND \(nonOpenCodeBillingPredicate(sessionAlias: "s"))
                """
        } else {
            source = """
                FROM sessions
                WHERE started_at >= \(literal(start))
                  AND \(nonOpenCodeBillingPredicate(sessionAlias: nil))
                """
        }
        return """
            SELECT json_group_array(json_array(model, tokens, cost, cost_is_complete, invalid_rows, active_sessions)) FROM (
                SELECT \(modelExpr) AS model,
                       CAST(SUM(\(tokensExpr)) AS REAL) AS tokens,
                       COALESCE(SUM(\(costExpr)),0) AS cost,
                       \(costCompleteness) AS cost_is_complete,
                       \(invalidRows) AS invalid_rows,
                       \(activeSessions) AS active_sessions
                \(source)
                GROUP BY \(modelExpr)
            );
            """
    }

    static func dailySQL(cutoff: Date, maximumTimestamp: Date? = nil) -> String {
        let tokenExpression = tokenSumExpression(alias: nil)
        let costCompleteness = costCompletenessExpression(
            tokenExpression: tokenExpression,
            costExpression: "estimated_cost_usd"
        )
        let invalidRows = invalidRowsExpression(alias: nil, maximumTimestamp: maximumTimestamp)
        return """
        SELECT json_group_array(json_array(day, tokens, cost, cost_is_complete, invalid_rows, active_sessions)) FROM (
            SELECT date(CAST(started_at AS INTEGER),'unixepoch','localtime') AS day,
                   CAST(SUM(\(tokenExpression)) AS REAL) AS tokens,
                   COALESCE(SUM(estimated_cost_usd),0) AS cost,
                   \(costCompleteness) AS cost_is_complete,
                   \(invalidRows) AS invalid_rows,
                   CASE WHEN SUM(CASE WHEN ended_at IS NULL THEN 1 ELSE 0 END) > 0 THEN 1 ELSE 0 END AS active_sessions
            FROM sessions
            WHERE started_at >= \(literal(cutoff))
              AND \(nonOpenCodeBillingPredicate(sessionAlias: nil))
            GROUP BY day
        );
        """
    }

    private static func tokenSumExpression(alias: String?) -> String {
        let prefix = alias.map { $0 + "." } ?? ""
        return "(COALESCE(\(prefix)input_tokens,0) + COALESCE(\(prefix)output_tokens,0) + COALESCE(\(prefix)cache_read_tokens,0) + COALESCE(\(prefix)cache_write_tokens,0) + COALESCE(\(prefix)reasoning_tokens,0))"
    }

    private static func costCompletenessExpression(tokenExpression: String, costExpression: String) -> String {
        // Hermes declares estimated_cost_usd REAL DEFAULT 0, so a token-bearing row whose importer
        // omitted the field is indistinguishable from an explicit zero after SQLite inserts it.
        // Treat zero as missing coverage; showing another session's subtotal as complete would be false.
        "CASE WHEN SUM(CASE WHEN \(tokenExpression) > 0 AND (\(costExpression) IS NULL OR \(costExpression) <= 0) THEN 1 ELSE 0 END) = 0 THEN 1 ELSE 0 END"
    }

    /// SQLite coerces malformed text values to zero inside SUM(), which otherwise turns one corrupt
    /// Hermes row into a plausible smaller total. Carry an invalid-row flag through every aggregate
    /// and reject the whole scan if any source counter or recorded cost has the wrong shape.
    private static func invalidRowsExpression(
        alias: String?,
        sessionAlias: String? = nil,
        maximumTimestamp: Date? = nil
    ) -> String {
        let prefix = alias.map { $0 + "." } ?? ""
        var counterNames = [
            "input_tokens", "output_tokens", "cache_read_tokens", "cache_write_tokens", "reasoning_tokens"
        ]
        // `api_call_count` is on `sessions`, not the optional per-model attribution table.
        if alias == nil { counterNames.append("api_call_count") }
        let counters = counterNames.map { name -> String in
            let column = prefix + name
            return "(\(column) IS NOT NULL AND (typeof(\(column)) NOT IN ('integer','real') OR \(column) < 0 OR \(column) > 1000000000000000 OR \(column) != CAST(\(column) AS INTEGER)))"
        }
        let cost = prefix + "estimated_cost_usd"
        let invalidCost = "(\(cost) IS NOT NULL AND (typeof(\(cost)) NOT IN ('integer','real') OR \(cost) < 0 OR \(cost) > 1000000000000))"
        let timestampPrefix = sessionAlias.map { $0 + "." } ?? ""
        let timestamp = timestampPrefix + "started_at"
        let apiCallCount = sessionAlias.map { $0 + ".api_call_count" } ?? "api_call_count"
        let hasUsage = "(\(tokenSumExpression(alias: alias)) > 0 OR COALESCE(\(apiCallCount),0) > 0 OR COALESCE(\(cost),0) > 0)"
        let invalidTimestamp = maximumTimestamp.map {
            "(\(hasUsage) AND (typeof(\(timestamp)) NOT IN ('integer','real') OR \(timestamp) > \(literal($0))))"
        }
        var invalidExpressions = counters + [invalidCost]
        if let invalidTimestamp { invalidExpressions.append(invalidTimestamp) }
        let invalid = invalidExpressions.joined(separator: " OR ")
        return "CASE WHEN SUM(CASE WHEN \(invalid) THEN 1 ELSE 0 END) > 0 THEN 1 ELSE 0 END"
    }

    /// OpenCode-billed Hermes sessions are folded onto the OpenCode card, where their cost is
    /// attributed to the account that paid for them. Keeping them in the Hermes card would double
    /// count their tokens in cross-provider spend totals.
    private static func nonOpenCodeBillingPredicate(sessionAlias: String?) -> String {
        let prefix = sessionAlias.map { $0 + "." } ?? ""
        return """
        COALESCE(LOWER(\(prefix)billing_provider), '') NOT LIKE 'opencode%'
          AND COALESCE(LOWER(\(prefix)billing_base_url), '') NOT LIKE '%opencode%'
        """
    }
}
