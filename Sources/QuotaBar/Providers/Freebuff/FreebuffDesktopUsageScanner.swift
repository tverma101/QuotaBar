import CoreFoundation
import Foundation

/// Freebuff Desktop persists measured usage on assistant messages and separate mission-manager
/// receipts. Read only those usage fields, never transcripts or harness state. A database+WAL
/// revision cache avoids starting sqlite3 on each fold, and the cache holds the *derived* numbers
/// rather than the raw JSON, so unchanged history is not decoded again on every fold.
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

    private struct DatabaseSnapshot: Equatable {
        var path: String
        var revisions: [Revision]
    }

    private struct CachedDatabase {
        var revision: [Revision]
        var rows: [DerivedTurn]
        var unreadableRows: Int
    }

    private struct CachedScan {
        var databases: [DatabaseSnapshot]
        var pricingToken: String
        var catalogNames: [String: String]
        var calendar: Calendar
        var computedAt: Date
        var nextFutureTimestamp: Date?
        var result: Scan
    }

    /// How long the resolved project database list stays fresh.
    static let pathCacheInterval: TimeInterval = 300

    /// The most usage events kept in memory across project databases. Assistant messages and
    /// auto-run manager receipts both count; older raw caches are dropped at the cap and read again
    /// only if a source or pricing change later requires rebuilding the aggregate.
    static let maximumRetainedTurns = 200_000
    /// Keep the completed UI-ready aggregate small as well; pathological histories can contain a
    /// large number of distinct model spellings and daily breakdown rows.
    static let maximumCachedScanBytes = 8 * 1_024 * 1_024

    /// One assistant or mission-manager usage event reduced to what the fold needs. Its JSON is
    /// parsed once, when the database changes, instead of on every fold.
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
    private var routePricingToken: String?
    private var routeCatalogNames: [String: String] = [:]
    /// Reuses the completed daily fold while the local databases and pricing inputs are unchanged.
    /// File revisions still get checked every refresh; cached derived turns remain the fallback when
    /// pricing changes or a future-dated row crosses into the scan window.
    private var cachedScan: CachedScan?
    private var cachedPaths: [String]?
    private var cachedPathsAt: Date?
    private var modelRoutes: [String: String] = [:]
    /// Inverse of `modelRoutes` (unique pairs only), so a priced turn is titled with the model's
    /// catalog name instead of the OpenRouter routing slug it was priced at.
    private var routeDisplayNames: [String: String] = [:]
    private let sqlite: any SQLiteAccessing
    private let databasePaths: @Sendable () throws -> [String]
    /// Decodes one receipt's metrics JSON. Injectable so a test can count how often the history is
    /// decoded.
    private let parseMetrics: @Sendable (String) -> [String: Any]?
    /// The most usage events kept in memory across every project database.
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
        dropRemovedDatabases(paths)
        guard !paths.isEmpty else {
            cachedScan = nil
            return nil
        }
        let catalogNames = modelCatalog.mapValues(\.displayName)
        let calendar = Calendar.current
        // The content token changes only when prices or aliases change; retrieval timestamps do not
        // force route-index rebuilds or a full token-accounting fold.
        let pricingToken = pricing.aggregateCacheToken
        if routePricingToken != pricingToken || routeCatalogNames != catalogNames {
            modelRoutes = FreebuffModelCatalog.pricingRoutes(entries: modelCatalog, pricing: pricing)
            routeDisplayNames = Self.uniqueRouteDisplayNames(modelRoutes)
            routePricingToken = pricingToken
            routeCatalogNames = catalogNames
        }
        trimRetainedTurns()

        let databaseSnapshots = try paths.map { path in
            DatabaseSnapshot(path: path, revisions: try revisions([path]))
        }
        if let cachedScan,
           cachedScan.databases == databaseSnapshots,
           cachedScan.pricingToken == pricingToken,
           cachedScan.catalogNames == catalogNames,
           cachedScan.calendar == calendar,
           now >= cachedScan.computedAt,
           cachedScan.nextFutureTimestamp.map({ now < $0 }) ?? true {
            return cachedScan.result
        }
        cachedScan = nil

        // Keep references to each database's cached turn array instead of flattening every row into
        // a second 200k-element array on every changed-project scan.
        var turnsByDatabase: [[DerivedTurn]] = []
        turnsByDatabase.reserveCapacity(databaseSnapshots.count)
        var unreadableRows = 0
        var snapshotStable = true
        for snapshot in databaseSnapshots {
            let path = snapshot.path
            let before = snapshot.revisions
            if let cached = databases[path], cached.revision == before {
                turnsByDatabase.append(cached.rows)
                unreadableRows += cached.unreadableRows
            } else {
                try Task.checkCancellation()
                // Saved selection is used only when a receipt lacks its serving model. Mission
                // manager calls carry their own model and are kept separate from assistant turns.
                //
                // Every selected expression is COALESCEd: SQLite's `||` yields NULL when one side is
                // NULL, and a single NULL element used to fail the whole array cast — taking the
                // entire history with it. An empty value now marks one unreadable row instead.
                let text: String?
                do {
                    text = try sqlite.queryValue(
                        path: path,
                        sql: FreebuffDesktopUsageSQL.messagesAndMissionManagers
                    )
                } catch let error as SQLiteError
                    where FreebuffDesktopUsageSQL.isMissingMissionReceiptTable(error) {
                    text = try sqlite.queryValue(path: path, sql: FreebuffDesktopUsageSQL.assistantMessages)
                }
                guard let text,
                      let data = text.data(using: .utf8)
                else { throw FreebuffUsageError.localHistoryUnreadable }
                let derived = try Self.deriveTurns(from: data, parseMetrics: parseMetrics)
                turnsByDatabase.append(derived.turns)
                unreadableRows += derived.unreadable
                // One query is a consistent SQLite snapshot. If another turn commits while it is
                // running, keep that result for this pass and re-read the changed DB on the next.
                if try revisions([path]) == before {
                    store(path: path, revision: before, derived: derived)
                } else {
                    snapshotStable = false
                }
            }
        }
        var accumulator = DailyUsageAccumulator()
        var partialDays: Set<String> = []
        var seen: Set<String> = []
        var nextFutureTimestamp: Date?
        for databaseTurns in turnsByDatabase {
            for turn in databaseTurns {
                try Task.checkCancellation()
                guard seen.insert(turn.id).inserted else { continue }
                let date = Date(timeIntervalSince1970: turn.timestampMs / 1000)
                guard date <= now else {
                    if nextFutureTimestamp.map({ date < $0 }) ?? true { nextFutureTimestamp = date }
                    continue
                }
                let day = DailyUsageAccumulator.dayKey(from: date, calendar: calendar)
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
                // Breakdown rows carry the catalog's display name whenever one is known — the routing
                // slug is pricing plumbing, not what the user picked — so priced and unpriced turns of
                // the same model land in one row instead of splitting across two spellings.
                let displayName = saved.flatMap { modelCatalog[$0]?.displayName }
                    ?? route.flatMap { routeDisplayNames[$0] }
                let model = displayName
                    ?? saved.flatMap { (turn.fromReceipt || $0.contains("/")) && !$0.hasPrefix("fbm1.") ? $0 : nil }
                    ?? ModelUsageEntry.unattributedModelName
                // A turn aggregates multiple requests, so do not apply single-request context tiers.
                // Cached input is already in input; reasoning is already in output.
                let cost = route.flatMap { pricing.resolve(model: $0) }?.costDollars(
                    for: TokenBreakdown(input: input - cached, cacheRead: cached, output: output),
                    at: date,
                    applyLongContextRates: false
                )
                accumulator.add(day: day, tokens: total, cost: cost, model: model, costIsComplete: cost != nil)
                if let cost {
                    accumulator.markEstimatedCost(day: day)
                    accumulator.addApiEstimate(day: day, cost: cost)
                } else if displayName == nil {
                    // A raw receipt slug nothing names and unattributed streams stay unknown: the app
                    // genuinely cannot tell what served them, so the warning stays honest.
                    accumulator.addUnknownModel(day: day, model: model)
                } else {
                    // The catalog names the model but no public route prices it — an explained gap,
                    // not an unknown model. Tokens count; no warning triangle.
                    accumulator.addNamedUnpricedModel(day: day, model: model)
                }
                if turn.partial { partialDays.insert(day) }
            }
        }
        if unreadableRows > 0 {
            DiagnosticGate.logOnce(for: "auth.freebuff.history.unreadable-rows") {
                AppLog.warn(
                    LogTag.auth("freebuff"),
                    "\(unreadableRows) local history row(s) had no identifier or timestamp and were skipped"
                )
            }
        }
        if snapshotStable {
            for snapshot in databaseSnapshots {
                if try revisions([snapshot.path]) != snapshot.revisions {
                    snapshotStable = false
                    break
                }
            }
        }
        let result = Scan(usage: accumulator.build(), partialDays: partialDays)
        if snapshotStable, Self.fitsCachedScanBudget(result) {
            cachedScan = CachedScan(
                databases: databaseSnapshots,
                pricingToken: pricingToken,
                catalogNames: catalogNames,
                calendar: calendar,
                computedAt: now,
                nextFutureTimestamp: nextFutureTimestamp,
                result: result
            )
        } else {
            cachedScan = nil
        }
        return result
    }

    /// Inverts a display-name → route map, keeping only routes a single catalog entry claims. Two
    /// entries resolving to one route leave that route unnamed — titling a row would then merge
    /// distinct models.
    private static func uniqueRouteDisplayNames(_ routes: [String: String]) -> [String: String] {
        var names: [String: String] = [:]
        var contested: Set<String> = []
        for (name, route) in routes {
            if let existing = names[route] {
                if existing != name { contested.insert(route) }
                continue
            }
            names[route] = name
        }
        for route in contested { names.removeValue(forKey: route) }
        return names
    }

    /// Conservative estimate for the retained aggregate. It includes collection overhead and
    /// strings, and stops as soon as the cap is crossed so a pathological breakdown adds little work.
    private static func fitsCachedScanBudget(_ scan: Scan) -> Bool {
        var bytes = 512
        func account(_ amount: Int) -> Bool {
            let (total, overflow) = bytes.addingReportingOverflow(amount)
            guard !overflow, total <= maximumCachedScanBytes else { return false }
            bytes = total
            return true
        }

        for day in scan.usage.series.daily {
            guard account(160 + day.date.utf8.count) else { return false }
        }
        for day in scan.usage.modelUsage?.daily ?? [] {
            guard account(112 + day.date.utf8.count) else { return false }
            for model in day.models {
                guard account(192 + model.model.utf8.count) else { return false }
                for variant in model.variants ?? [] {
                    guard account(128 + variant.model.utf8.count) else { return false }
                }
            }
        }
        for (day, models) in scan.usage.unknownModelsByDay {
            guard account(96 + day.utf8.count) else { return false }
            for model in models {
                guard account(80 + model.utf8.count) else { return false }
            }
        }
        for (day, _) in scan.usage.apiEstimateByDay ?? [:] {
            guard account(96 + day.utf8.count) else { return false }
        }
        for day in scan.partialDays {
            guard account(64 + day.utf8.count) else { return false }
        }
        for day in scan.usage.apiEstimateIncompleteDays ?? [] {
            guard account(64 + day.utf8.count) else { return false }
        }
        for day in scan.usage.estimatedCostDays ?? [] {
            guard account(64 + day.utf8.count) else { return false }
        }
        for day in scan.usage.unmeasuredUsageDays ?? [] {
            guard account(64 + day.utf8.count) else { return false }
        }
        return true
    }

    func unloadCachesForMemoryPressure() {
        databases.removeAll(keepingCapacity: false)
        databaseOrder.removeAll(keepingCapacity: false)
        retainedTurns = 0
        cachedScan = nil
        cachedPaths = nil
        cachedPathsAt = nil
        routePricingToken = nil
        routeCatalogNames.removeAll(keepingCapacity: false)
        modelRoutes.removeAll(keepingCapacity: false)
        routeDisplayNames.removeAll(keepingCapacity: false)
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

    /// Keep a database's derived turns while evicting whole older databases to stay under the cap.
    private func store(path: String, revision: [Revision], derived: DerivedTurns) {
        if let existing = databases.removeValue(forKey: path) { retainedTurns -= existing.rows.count }
        databaseOrder.removeAll { $0 == path }
        guard derived.turns.count <= maximumRetainedTurns else { return }
        while retainedTurns > maximumRetainedTurns - derived.turns.count,
              let oldest = databaseOrder.first {
            databaseOrder.removeFirst()
            if let dropped = databases.removeValue(forKey: oldest) { retainedTurns -= dropped.rows.count }
        }
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
