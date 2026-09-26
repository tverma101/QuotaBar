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
}

/// One model's usage inside a period, from Hermes' per-model attribution rows
/// (`session_model_usage`, joined to `sessions` for the period boundary).
struct HermesModelUsage: Sendable, Equatable {
    var model: String
    var tokens: Int
    var costUSD: Double?
}

/// The result of a Hermes scan: the three period rows, a daily token/cost series for the trend chart,
/// and per-period model breakdowns. Periods are always present (zero-filled by SQL `COALESCE`), so the
/// mapper decides what a zero period means; `daily` is empty when no session falls inside the window.
struct HermesUsageScan: Sendable, Equatable {
    var periods: [HermesPeriodUsage]
    var daily: DailyUsageSeries
    var modelUsageByPeriod: [HermesPeriod: [HermesModelUsage]]
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
        let hasModelTable = try? (sqlite.queryValue(path: path, sql: Self.modelTableProbeSQL) != nil)

        for (period, start) in starts {
            guard let sumJSON = try sqlite.queryValue(path: path, sql: Self.periodSQL(start: start)),
                  let counts = Self.parsePeriod(sumJSON) else {
                continue
            }
            periods.append(HermesPeriodUsage(
                period: period,
                counts: counts.counts,
                costUSD: counts.costUSD,
                apiCallCount: counts.apiCallCount
            ))
            if let modelJSON = try? sqlite.queryValue(path: path, sql: Self.modelsSQL(start: start, detailed: hasModelTable == true)) {
                modelUsage[period] = Self.parseModels(modelJSON)
            }
        }

        let dailyCutoff = calendar.date(byAdding: .day, value: -UsageHistoryWindow.previousDays, to: calendar.startOfDay(for: now))
            ?? calendar.startOfDay(for: now)
        let daily: DailyUsageSeries
        if let dailyJSON = try sqlite.queryValue(path: path, sql: Self.dailySQL(cutoff: dailyCutoff)) {
            daily = Self.parseDaily(dailyJSON)
        } else {
            daily = DailyUsageSeries(daily: [])
        }

        return HermesUsageScan(periods: periods, daily: daily, modelUsageByPeriod: modelUsage)
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

    /// Period row shape: `[input, output, cacheRead, cacheWrite, reasoning, apiCallCount, costUSD]`.
    private struct ParsedPeriod {
        var counts: HermesTokenCounts
        var costUSD: Double?
        var apiCallCount: Int
    }

    private static func parsePeriod(_ json: String) -> ParsedPeriod? {
        guard let data = json.data(using: .utf8),
              let array = (try? JSONSerialization.jsonObject(with: data)) as? [Any],
              array.count >= 7 else {
            return nil
        }
        func int(_ index: Int) -> Int {
            Int(min(max(ProviderParse.number(array[index]) ?? 0, 0), 1e15))
        }
        let cost = ProviderParse.number(array[6]).flatMap { $0 > 0 ? $0 : nil }
        return ParsedPeriod(
            counts: HermesTokenCounts(
                input: int(0), output: int(1), cacheRead: int(2), cacheWrite: int(3), reasoning: int(4)
            ),
            costUSD: cost,
            apiCallCount: int(5)
        )
    }

    /// Model row shape: `[model, tokens, costUSD]`; a missing or non-string model reads as
    /// "Unattributed" (mirrors the spend tiles' handling of models the source can't name).
    private static func parseModels(_ json: String) -> [HermesModelUsage] {
        guard let data = json.data(using: .utf8),
              let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else {
            return []
        }
        var rows: [HermesModelUsage] = []
        rows.reserveCapacity(parsed.count)
        for element in parsed {
            guard let entry = element as? [Any], entry.count >= 3,
                  let tokens = ProviderParse.number(entry[1]) else {
                continue
            }
            let model = (entry[0] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            rows.append(HermesModelUsage(
                model: (model?.nilIfEmpty ?? ""),
                tokens: Int(min(max(tokens, 0), 1e15)),
                costUSD: ProviderParse.number(entry[2]).flatMap { $0 > 0 ? $0 : nil }
            ))
        }
        return rows.sorted { lhs, rhs in
            if lhs.tokens != rhs.tokens { return lhs.tokens > rhs.tokens }
            return lhs.model.localizedStandardCompare(rhs.model) == .orderedAscending
        }
    }

    /// Daily row shape: `[yyyy-MM-dd, tokens, costUSD]`.
    private static func parseDaily(_ json: String) -> DailyUsageSeries {
        guard let data = json.data(using: .utf8),
              let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else {
            return DailyUsageSeries(daily: [])
        }
        var daily: [DailyUsageEntry] = []
        daily.reserveCapacity(parsed.count)
        for element in parsed {
            guard let entry = element as? [Any], entry.count >= 2,
                  let day = entry[0] as? String,
                  let tokens = ProviderParse.number(entry[1]), tokens > 0 else {
                continue
            }
            daily.append(DailyUsageEntry(
                date: day,
                totalTokens: Int(min(max(tokens, 0), 1e15)),
                costUSD: ProviderParse.number(entry[2]).flatMap { $0 > 0 ? $0 : nil }
            ))
        }
        return DailyUsageSeries(daily: daily)
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

    static func periodSQL(start: Date) -> String {
        """
        SELECT json_array(
                 COALESCE(SUM(input_tokens),0),
                 COALESCE(SUM(output_tokens),0),
                 COALESCE(SUM(cache_read_tokens),0),
                 COALESCE(SUM(cache_write_tokens),0),
                 COALESCE(SUM(reasoning_tokens),0),
                 COALESCE(SUM(api_call_count),0),
                 COALESCE(SUM(estimated_cost_usd),0))
        FROM sessions
        WHERE started_at >= \(literal(start));
        """
    }

    static func modelsSQL(start: Date, detailed: Bool) -> String {
        // `json_group_array` is itself an aggregate, so SUM() must live in an inner subquery — nesting
        // aggregates directly is a SQLite error. In the detailed case the token columns are qualified
        // with `smu.` because `sessions` carries the same column names (ambiguous without it).
        let modelExpr = detailed ? "smu.model" : "model"
        let tokensExpr = detailed
            ? "smu.input_tokens + smu.output_tokens + smu.cache_read_tokens + smu.cache_write_tokens + smu.reasoning_tokens"
            : "input_tokens + output_tokens + cache_read_tokens + cache_write_tokens + reasoning_tokens"
        let costExpr = detailed ? "smu.estimated_cost_usd" : "estimated_cost_usd"
        let source: String
        if detailed {
            source = """
                FROM session_model_usage smu
                JOIN sessions s ON s.id = smu.session_id
                WHERE s.started_at >= \(literal(start))
                """
        } else {
            source = """
                FROM sessions
                WHERE started_at >= \(literal(start))
                """
        }
        return """
            SELECT json_group_array(json_array(model, tokens, cost)) FROM (
                SELECT \(modelExpr) AS model,
                       CAST(SUM(\(tokensExpr)) AS REAL) AS tokens,
                       COALESCE(SUM(\(costExpr)),0) AS cost
                \(source)
                GROUP BY \(modelExpr)
            );
            """
    }

    static func dailySQL(cutoff: Date) -> String {
        """
        SELECT json_group_array(json_array(day, tokens, cost)) FROM (
            SELECT date(CAST(started_at AS INTEGER),'unixepoch','localtime') AS day,
                   CAST(SUM(input_tokens + output_tokens + cache_read_tokens + cache_write_tokens + reasoning_tokens) AS REAL) AS tokens,
                   COALESCE(SUM(estimated_cost_usd),0) AS cost
            FROM sessions
            WHERE started_at >= \(literal(cutoff))
            GROUP BY day
        );
        """
    }
}
