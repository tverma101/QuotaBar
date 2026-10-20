import CoreFoundation
import Foundation

/// Freebuff Desktop persists the latest measured usage on each assistant message. Read only that
/// narrow JSON column, never transcripts or harness state. A database+WAL revision cache avoids
/// starting sqlite3 or decoding unchanged history on each fold.
actor FreebuffDesktopUsageScanner {
    struct Scan: Sendable {
        var usage: LogUsageScan
        var partialDays: Set<String>
    }

    private struct Revision: Equatable {
        var path: String
        var size: UInt64
        var modified: Date
        var changed: Date
    }

    private struct CachedDatabase {
        var revision: [Revision]
        var rows: [RawRow]
    }

    /// How long the resolved project database list stays fresh.
    static let pathCacheInterval: TimeInterval = 300

    /// One message row as SQLite returned it. A column that was NULL arrives as an empty string, so
    /// an unusable row is skipped instead of taking the whole history with it.
    private struct RawRow {
        var id: String
        var timestamp: String
        var metrics: String
        var selectedModel: String
    }

    private var databases: [String: CachedDatabase] = [:]
    private var routePricing: ModelPricing?
    private var routeCatalogNames: [String: String] = [:]
    private var cachedPaths: [String]?
    private var cachedPathsAt: Date?
    private var modelRoutes: [String: String] = [:]
    private let sqlite: any SQLiteAccessing
    private let databasePaths: @Sendable () throws -> [String]

    init(
        sqlite: any SQLiteAccessing = SQLiteCLIAccessor(),
        databasePaths: @escaping @Sendable () throws -> [String] = FreebuffDesktopUsageScanner.defaultDatabasePaths
    ) {
        self.sqlite = sqlite
        self.databasePaths = databasePaths
    }

    static func defaultDatabasePaths() throws -> [String] {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/freebuff-desktop/projects", isDirectory: true)
        let projects: [URL]
        do {
            projects = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        }
        return projects
            .map { $0.appendingPathComponent("desktop-v2.db").path }
            .filter { FileManager.default.fileExists(atPath: $0) }
            .sorted()
    }

    func hasHistory(now: Date = Date()) throws -> Bool { try !resolvedPaths(now: now).isEmpty }

    /// The project databases, resolved at most once per interval.
    ///
    /// Both the live-quota refresh (which asks whether any Desktop history exists) and the history
    /// fold need this list, and resolving it means a directory read plus a stat per project. A
    /// manual refresh re-resolves it right away; a scheduled refresh reuses the recent answer.
    private func resolvedPaths(now: Date) throws -> [String] {
        if !ProviderRefreshContext.isManual,
           let cachedPaths, let cachedPathsAt,
           now.timeIntervalSince(cachedPathsAt) < Self.pathCacheInterval {
            return cachedPaths
        }
        let paths = try databasePaths().sorted()
        cachedPaths = paths
        cachedPathsAt = now
        return paths
    }

    func scan(now: Date, pricing: ModelPricing = .empty,
              modelCatalog: [String: FreebuffModelCatalog.Entry] = [:]) throws -> Scan? {
        try Task.checkCancellation()
        let paths = try resolvedPaths(now: now)
        guard !paths.isEmpty else { return nil }
        let catalogNames = modelCatalog.mapValues(\.displayName)
        // The pricing snapshot's identity stands in for its content: its aggregate token is hundreds
        // of kilobytes of rate text, and copying it on every fold to compare it was pure overhead.
        // The snapshot instance only changes when the pricing catalogues do.
        if routePricing !== pricing || routeCatalogNames != catalogNames {
            modelRoutes = FreebuffModelCatalog.openRouterRoutes(entries: modelCatalog, pricing: pricing)
            routePricing = pricing
            routeCatalogNames = catalogNames
        }
        databases = databases.filter { paths.contains($0.key) }
        var rows: [RawRow] = []
        for path in paths {
            let before = try revisions([path])
            if let cached = databases[path], cached.revision == before {
                rows.append(contentsOf: cached.rows)
            } else {
                try Task.checkCancellation()
                // Saved selection is used only for the owner's explicitly requested estimate when
                // a receipt lacks its serving model. The provider source note explains that limit.
                //
                // Every selected expression is COALESCEd: SQLite's `||` yields NULL when one side is
                // NULL, and a single NULL element used to fail the whole array cast — taking the
                // entire history with it. An empty value now marks one unreadable row instead.
                let sql = """
                SELECT COALESCE(json_group_array(json_object(
                  'id', COALESCE(m.thread_id || ':' || m.seq, ''),
                  'timestamp', COALESCE(CAST(m.ts AS TEXT), ''),
                  'metrics', COALESCE(m.metrics_json, ''),
                  'selectedModel', COALESCE(t.model, '')
                )), '[]') FROM messages m JOIN threads t ON t.id = m.thread_id
                WHERE t.harness_id = 'codebuff' AND m.role = 'assistant'
                  AND m.metrics_json IS NOT NULL AND m.metrics_json != '{}'
                """
                guard let text = try sqlite.queryValue(path: path, sql: sql),
                      let data = text.data(using: .utf8)
                else { throw FreebuffUsageError.localHistoryUnreadable }
                let decoded = try Self.rawRows(from: data)
                rows.append(contentsOf: decoded)
                // One query is a consistent SQLite snapshot. If another turn commits while it is
                // running, keep that result for this pass and re-read the changed DB on the next.
                if try revisions([path]) == before {
                    databases[path] = CachedDatabase(revision: before, rows: decoded)
                }
            }
        }
        var accumulator = DailyUsageAccumulator()
        var partialDays: Set<String> = []
        var seen: Set<String> = []
        var unreadableRows = 0
        for row in rows {
            try Task.checkCancellation()
            // A row without an identifier or a timestamp cannot be measured or deduplicated. Skip
            // it and keep the rest of the history, instead of failing every day the row is in.
            guard !row.id.isEmpty,
                  let stamp = Double(row.timestamp), stamp.isFinite
            else {
                unreadableRows += 1
                continue
            }
            guard let metrics = ProviderParse.jsonObject(Data(row.metrics.utf8))
            else { throw FreebuffUsageError.localHistoryUnreadable }
            guard seen.insert(row.id).inserted else { continue }
            let date = Date(timeIntervalSince1970: stamp / 1000)
            guard date <= now else { continue }
            let day = DailyUsageAccumulator.dayKey(from: date)
            guard let usage = metrics["usage"] as? [String: Any] else {
                if metrics["usageIncomplete"] as? Bool == true { partialDays.insert(day) }
                continue
            }
            guard let input = Self.count(usage["inputTokens"]),
                  let output = Self.count(usage["outputTokens"])
            else { throw FreebuffUsageError.localHistoryUnreadable }
            let sum = input.addingReportingOverflow(output)
            guard !sum.overflow else { throw FreebuffUsageError.localHistoryUnreadable }
            let total = sum.partialValue
            if let reported = usage["totalTokens"], Self.count(reported) != total {
                throw FreebuffUsageError.localHistoryUnreadable
            }
            guard total > 0 else { continue }
            let cached = try Self.optionalCount(usage["cachedInputTokens"])
            let reasoning = try Self.optionalCount(usage["reasoningOutputTokens"])
            guard cached <= input, reasoning <= output else { throw FreebuffUsageError.localHistoryUnreadable }
            let recordedModel = (usage["model"] as? String)?.nilIfEmpty
            let saved = recordedModel ?? row.selectedModel.nilIfEmpty
            let route = saved.flatMap { pricing.openRouter.entries[$0] != nil ? $0 : modelRoutes[$0] }
            let model = route ?? saved.flatMap { modelCatalog[$0]?.displayName }
                ?? saved.flatMap { (recordedModel != nil || $0.contains("/")) && !$0.hasPrefix("fbm1.") ? $0 : nil }
                ?? ModelUsageEntry.unattributedModelName
            // A turn aggregates multiple requests, so do not apply single-request context tiers.
            // Cached input is already in input; reasoning is already in output.
            let cost = route.flatMap { pricing.openRouter.entries[$0] }?.costDollars(
                for: TokenBreakdown(input: input - cached, cacheRead: cached, output: output),
                applyLongContextRates: false
            )
            accumulator.add(day: day, tokens: total, cost: cost, model: model, costIsComplete: cost != nil)
            if let cost {
                accumulator.markEstimatedCost(day: day)
                accumulator.addApiEstimate(day: day, cost: cost)
            } else {
                accumulator.addUnknownModel(day: day, model: model)
            }
            if metrics["usageIncomplete"] as? Bool == true { partialDays.insert(day) }
        }
        if unreadableRows > 0 {
            DiagnosticGate.logOnce(for: "auth.freebuff.history.unreadable-rows") {
                AppLog.warn(
                    LogTag.auth("freebuff"),
                    "\(unreadableRows) local history row(s) had no identifier or timestamp and were skipped"
                )
            }
        }
        return Scan(usage: accumulator.build(), partialDays: partialDays)
    }

    /// Decode the rows SQLite returned. The payload is decoded as `[[String: Any]]` rather than
    /// `[[String: String]]` because a JSON `null` — which is what a NULL column becomes — fails the
    /// whole array cast instead of just the one row that carries it.
    private static func rawRows(from data: Data) throws -> [RawRow] {
        guard let decoded = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw FreebuffUsageError.localHistoryUnreadable
        }
        return decoded.map { row in
            RawRow(
                id: text(row["id"]),
                timestamp: text(row["timestamp"]),
                metrics: text(row["metrics"]),
                selectedModel: text(row["selectedModel"])
            )
        }
    }

    /// A column's text, with a JSON null (or a non-string) read as empty.
    private static func text(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "" }
        return (value as? String) ?? ""
    }

    private static func optionalCount(_ value: Any?) throws -> Int {
        guard let value else { return 0 }
        guard let count = count(value) else { throw FreebuffUsageError.localHistoryUnreadable }
        return count
    }

    private static func count(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0,
              number.doubleValue < Double(Int.max),
              number.doubleValue.rounded(.towardZero) == number.doubleValue
        else { return nil }
        return number.intValue
    }

    private func revisions(_ paths: [String]) throws -> [Revision] {
        try paths.flatMap { path in
            try [path, path + "-wal"].compactMap { name in
                guard FileManager.default.fileExists(atPath: name) else { return nil }
                let attrs = try FileManager.default.attributesOfItem(atPath: name)
                let url = URL(fileURLWithPath: name)
                let values = try url.resourceValues(forKeys: [.attributeModificationDateKey])
                return Revision(path: name, size: (attrs[.size] as? NSNumber)?.uint64Value ?? 0,
                                modified: attrs[.modificationDate] as? Date ?? .distantPast,
                                changed: values.attributeModificationDate ?? .distantPast)
            }
        }
    }
}
