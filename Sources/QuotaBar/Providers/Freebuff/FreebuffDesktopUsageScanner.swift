import CoreFoundation
import Foundation

/// Freebuff Desktop persists the latest measured usage on each assistant message. Read only that
/// narrow JSON column, never transcripts or harness state. A database+WAL revision cache avoids
/// starting sqlite3 on each fold, and the cache holds the *derived* numbers rather than the raw
/// JSON, so an unchanged history is not decoded again on every fold.
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
        var rows: [DerivedTurn]
        var unreadableRows: Int
    }

    /// How long the resolved project database list stays fresh.
    static let pathCacheInterval: TimeInterval = 300

    /// The most turns kept in memory across every project database. Freebuff Desktop writes one row
    /// per assistant message, so a long-lived install accumulates tens of thousands of them; the
    /// oldest project's cache is dropped when the cap is reached, and it is read again on the next
    /// fold.
    static let maximumRetainedTurns = 200_000

    /// One assistant message reduced to what the fold needs: the receipt's JSON is parsed once, when
    /// the database changes, instead of on every fold.
    private struct DerivedTurn {
        var id: String
        var timestampMs: Double
        /// `nil` when the receipt carries no usage object at all.
        var usage: DerivedUsage?
        /// The model the receipt named, or the thread's saved selection.
        var savedModel: String?
        /// Whether the model came from the receipt rather than the thread's saved selection.
        var fromReceipt: Bool
        var partial: Bool
    }

    /// The counts of one receipt. `invalid` keeps "the field was there but was not a number" apart
    /// from "the field was not there", because the two are reported differently.
    private enum Count {
        case absent
        case value(Int)
        case invalid
    }

    private enum DerivedUsage {
        case counts(input: Count, output: Count, cached: Count, reasoning: Count, reportedTotal: Count)
    }

    private var databases: [String: CachedDatabase] = [:]
    /// The project databases in the order they were read, so the oldest can be dropped first.
    private var databaseOrder: [String] = []
    private var retainedTurns = 0
    private var routePricing: ModelPricing?
    private var routeCatalogNames: [String: String] = [:]
    private var cachedPaths: [String]?
    private var cachedPathsAt: Date?
    private var modelRoutes: [String: String] = [:]
    private let sqlite: any SQLiteAccessing
    private let databasePaths: @Sendable () throws -> [String]
    /// Decodes one receipt's metrics JSON. Injectable so a test can count how often the history is
    /// decoded.
    private let parseMetrics: @Sendable (String) -> [String: Any]?
    /// The most turns kept in memory across every project database.
    private let maximumRetainedTurns: Int

    init(
        sqlite: any SQLiteAccessing = SQLiteCLIAccessor(),
        databasePaths: @escaping @Sendable () throws -> [String] = FreebuffDesktopUsageScanner.defaultDatabasePaths,
        parseMetrics: @escaping @Sendable (String) -> [String: Any]? = { ProviderParse.jsonObject(Data($0.utf8)) },
        maximumRetainedTurns: Int = FreebuffDesktopUsageScanner.maximumRetainedTurns
    ) {
        self.sqlite = sqlite
        self.databasePaths = databasePaths
        self.parseMetrics = parseMetrics
        self.maximumRetainedTurns = maximumRetainedTurns
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
        dropRemovedDatabases(paths)
        trimRetainedTurns()
        var turns: [DerivedTurn] = []
        var unreadableRows = 0
        for path in paths {
            let before = try revisions([path])
            if let cached = databases[path], cached.revision == before {
                turns.append(contentsOf: cached.rows)
                unreadableRows += cached.unreadableRows
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
                let derived = try Self.deriveTurns(from: data, parseMetrics: parseMetrics)
                turns.append(contentsOf: derived.turns)
                unreadableRows += derived.unreadable
                // One query is a consistent SQLite snapshot. If another turn commits while it is
                // running, keep that result for this pass and re-read the changed DB on the next.
                if try revisions([path]) == before {
                    store(path: path, revision: before, derived: derived)
                }
            }
        }
        var accumulator = DailyUsageAccumulator()
        var partialDays: Set<String> = []
        var seen: Set<String> = []
        for turn in turns {
            try Task.checkCancellation()
            guard seen.insert(turn.id).inserted else { continue }
            let date = Date(timeIntervalSince1970: turn.timestampMs / 1000)
            guard date <= now else { continue }
            let day = DailyUsageAccumulator.dayKey(from: date)
            guard let usage = turn.usage else {
                if turn.partial { partialDays.insert(day) }
                continue
            }
            guard case .counts(let inputCount, let outputCount, let cachedCount,
                              let reasoningCount, let reportedTotal) = usage else { continue }
            let input = try Self.required(inputCount)
            let output = try Self.required(outputCount)
            let sum = input.addingReportingOverflow(output)
            guard !sum.overflow else { throw FreebuffUsageError.localHistoryUnreadable }
            let total = sum.partialValue
            switch reportedTotal {
            case .absent: break
            case .value(let reported): if reported != total { throw FreebuffUsageError.localHistoryUnreadable }
            case .invalid: throw FreebuffUsageError.localHistoryUnreadable
            }
            guard total > 0 else { continue }
            let cached = try Self.optional(cachedCount)
            let reasoning = try Self.optional(reasoningCount)
            guard cached <= input, reasoning <= output else { throw FreebuffUsageError.localHistoryUnreadable }
            let saved = turn.savedModel
            let route = saved.flatMap { pricing.openRouter.entries[$0] != nil ? $0 : modelRoutes[$0] }
            let model = route ?? saved.flatMap { modelCatalog[$0]?.displayName }
                ?? saved.flatMap { (turn.fromReceipt || $0.contains("/")) && !$0.hasPrefix("fbm1.") ? $0 : nil }
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
            if turn.partial { partialDays.insert(day) }
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

    /// Forget the databases whose project directory is gone.
    private func dropRemovedDatabases(_ paths: [String]) {
        let known = Set(paths)
        let removed = databases.keys.filter { !known.contains($0) }
        guard !removed.isEmpty else { return }
        for path in removed {
            if let dropped = databases.removeValue(forKey: path) { retainedTurns -= dropped.rows.count }
            databaseOrder.removeAll { $0 == path }
        }
    }

    /// Keep a database's derived turns. The retained history is trimmed at the start of the next
    /// fold, so the projects read in this pass are not dropped while they are still in use.
    private func store(path: String, revision: [Revision], derived: DerivedTurns) {
        if let existing = databases[path] { retainedTurns -= existing.rows.count }
        databaseOrder.removeAll { $0 == path }
        databaseOrder.append(path)
        databases[path] = CachedDatabase(revision: revision, rows: derived.turns, unreadableRows: derived.unreadable)
        retainedTurns += derived.turns.count
    }

    /// Drop the oldest projects' caches until the retained history fits the cap. Only the projects
    /// beyond the cap are read again on the next fold.
    private func trimRetainedTurns() {
        while retainedTurns > maximumRetainedTurns, let oldest = databaseOrder.first {
            databaseOrder.removeFirst()
            if let dropped = databases.removeValue(forKey: oldest) { retainedTurns -= dropped.rows.count }
        }
    }

    // MARK: - Derivation

    private struct DerivedTurns {
        var turns: [DerivedTurn]
        var unreadable: Int
    }

    /// Reduce the rows SQLite returned to the numbers the fold needs.
    ///
    /// The payload is decoded as `[[String: Any]]` rather than `[[String: String]]` because a JSON
    /// `null` — which is what a NULL column becomes — fails the whole array cast instead of just the
    /// one row that carries it.
    private static func deriveTurns(
        from data: Data,
        parseMetrics: @Sendable (String) -> [String: Any]?
    ) throws -> DerivedTurns {
        guard let decoded = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw FreebuffUsageError.localHistoryUnreadable
        }
        var turns: [DerivedTurn] = []
        turns.reserveCapacity(decoded.count)
        var unreadable = 0
        for row in decoded {
            // A row without an identifier or a timestamp cannot be measured or deduplicated. Skip
            // it and keep the rest of the history, instead of failing every day the row is in.
            guard let turn = try deriveTurn(row, parseMetrics: parseMetrics) else {
                unreadable += 1
                continue
            }
            turns.append(turn)
        }
        return DerivedTurns(turns: turns, unreadable: unreadable)
    }

    private static func deriveTurn(
        _ row: [String: Any],
        parseMetrics: @Sendable (String) -> [String: Any]?
    ) throws -> DerivedTurn? {
        let id = text(row["id"])
        guard !id.isEmpty, let stamp = Double(text(row["timestamp"])), stamp.isFinite else { return nil }
        guard let metrics = parseMetrics(text(row["metrics"])) else {
            throw FreebuffUsageError.localHistoryUnreadable
        }
        let usage = metrics["usage"] as? [String: Any]
        let recordedModel = (usage?["model"] as? String)?.nilIfEmpty
        let savedModel = recordedModel ?? text(row["selectedModel"]).nilIfEmpty
        var derived = DerivedTurn(
            id: id,
            timestampMs: stamp,
            usage: nil,
            savedModel: savedModel,
            fromReceipt: recordedModel != nil,
            partial: metrics["usageIncomplete"] as? Bool == true
        )
        if let usage {
            derived.usage = .counts(
                input: count(usage["inputTokens"]),
                output: count(usage["outputTokens"]),
                cached: count(usage["cachedInputTokens"]),
                reasoning: count(usage["reasoningOutputTokens"]),
                reportedTotal: count(usage["totalTokens"])
            )
        }
        return derived
    }

    /// A column's text, with a JSON null (or a non-string) read as empty.
    private static func text(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "" }
        return (value as? String) ?? ""
    }

    /// A required count: absent and invalid are both "no usable number".
    private static func count(_ value: Any?) -> Count {
        guard let value else { return .absent }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0,
              number.doubleValue < Double(Int.max),
              number.doubleValue.rounded(.towardZero) == number.doubleValue
        else { return .invalid }
        return .value(number.intValue)
    }

    /// A count the receipt must carry.
    private static func required(_ count: Count) throws -> Int {
        switch count {
        case .value(let value): return value
        case .absent, .invalid: throw FreebuffUsageError.localHistoryUnreadable
        }
    }

    /// An optional count: absent counts as zero, invalid is a broken receipt.
    private static func optional(_ count: Count) throws -> Int {
        switch count {
        case .absent: return 0
        case .value(let value): return value
        case .invalid: throw FreebuffUsageError.localHistoryUnreadable
        }
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
