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
        var hostedReceipts: [FreebuffUsageReceipt]
        var pricingToken: String
        var catalog: [String: FreebuffModelCatalog.Entry]
        var calendar: Calendar
        var computedAt: Date
        var nextFutureTimestamp: Date?
        var result: Scan
    }

    /// How long the resolved project database list stays fresh.
    static let pathCacheInterval: TimeInterval = 300
    /// A renamed chat is picked up on the next refresh after this interval. Automatic refreshes
    /// inside the interval keep the last title, so an active project's WAL does not spawn sqlite3
    /// on every menu-bar poll.
    static let titleRefreshInterval: TimeInterval = 60

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
    private var routeCatalog: [String: FreebuffModelCatalog.Entry] = [:]
    /// Reuses the completed daily fold while the local databases and pricing inputs are unchanged.
    /// File revisions still get checked every refresh; cached derived turns remain the fallback when
    /// pricing changes or a future-dated row crosses into the scan window.
    private var cachedScan: CachedScan?
    private var cachedPaths: [String]?
    private var cachedPathsAt: Date?
    private var modelIdentity = FreebuffModelIdentity(entries: [:], pricing: .empty)
    private let sqlite: any SQLiteAccessing
    private let databasePaths: @Sendable () throws -> [String]
    private let sessionEndsPath: @Sendable () -> String?
    /// Decodes one receipt's metrics JSON. Injectable so a test can count how often the history is
    /// decoded.
    private let parseMetrics: @Sendable (String) -> [String: Any]?
    /// The most usage events kept in memory across every project database.
    private let maximumRetainedTurns: Int

    struct SessionChatInfo: Sendable, Equatable {
        var chatTitle: String
        var projectPath: String
        var threadID: String
        var sourcePath: String
        var sourceStamp: SourceStamp
        var fetchedAt: Date
    }

    /// Size and mtime of a project database and its WAL. A title rename updates one of them.
    struct SourceStamp: Sendable, Equatable {
        var dbSize: UInt64
        var dbModified: TimeInterval
        var walSize: UInt64
        var walModified: TimeInterval

        static let missing = SourceStamp(dbSize: 0, dbModified: 0, walSize: 0, walModified: 0)
    }

    private var cachedSessionChats: [String: SessionChatInfo] = [:]

    init(
        sqlite: any SQLiteAccessing = SQLiteCLIAccessor(),
        databasePaths: @escaping @Sendable () throws -> [String] = FreebuffDesktopUsageScanner.defaultDatabasePaths,
        sessionEndsPath: @escaping @Sendable () -> String? = FreebuffDesktopUsageScanner.defaultSessionEndsPath,
        parseMetrics: @escaping @Sendable (String) -> [String: Any]? = { ProviderParse.jsonObject(Data($0.utf8)) },
        maximumRetainedTurns: Int = FreebuffDesktopUsageScanner.maximumRetainedTurns
    ) {
        self.sqlite = sqlite
        self.databasePaths = databasePaths
        self.sessionEndsPath = sessionEndsPath
        self.parseMetrics = parseMetrics
        self.maximumRetainedTurns = maximumRetainedTurns
    }

    static func defaultSessionEndsPath() -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/freebuff-desktop/state.json.session-ends.json")
        return FileManager.default.fileExists(atPath: url.path) ? url.path : nil
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
              modelCatalog: [String: FreebuffModelCatalog.Entry] = [:],
              hostedReceipts: [FreebuffUsageReceipt] = []) throws -> Scan? {
        try Task.checkCancellation()
        let paths = try resolvedPaths(now: now)
        dropRemovedDatabases(paths)
        guard !paths.isEmpty || !hostedReceipts.isEmpty else {
            cachedScan = nil
            return nil
        }
        let calendar = Calendar.current
        // The content token changes only when prices or aliases change; retrieval timestamps do not
        // force route-index rebuilds or a full token-accounting fold.
        let pricingToken = pricing.aggregateCacheToken
        if routePricingToken != pricingToken || routeCatalog != modelCatalog {
            modelIdentity = FreebuffModelIdentity(entries: modelCatalog, pricing: pricing)
            routePricingToken = pricingToken
            routeCatalog = modelCatalog
        }
        trimRetainedTurns()

        let databaseSnapshots = try paths.map { path in
            DatabaseSnapshot(path: path, revisions: try revisions([path]))
        }
        if let cachedScan,
           cachedScan.databases == databaseSnapshots,
           cachedScan.hostedReceipts == hostedReceipts,
           cachedScan.pricingToken == pricingToken,
           cachedScan.catalog == modelCatalog,
           cachedScan.calendar == calendar,
           now >= cachedScan.computedAt,
           cachedScan.nextFutureTimestamp.map({ now < $0 }) ?? true {
            return cachedScan.result
        }
        cachedScan = nil

        // Keep references to each database's cached turn array instead of flattening every row into
        // a second 200k-element array on every changed-project scan.
        // The current hosted receipt wins over an older Desktop copy of the same cloud:<run>.
        let hosted = try hostedReceipts.compactMap { try Self.deriveTurn($0.scannerRow, parseMetrics: parseMetrics) }
        var turnsByDatabase: [[DerivedTurn]] = [hosted]
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
                let text = try FreebuffDesktopUsageSQL.readRows(sqlite: sqlite, path: path)
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
                guard !seen.contains(turn.id) else { continue }
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
                // A hosted placeholder must not hide a measured older Desktop copy.
                seen.insert(turn.id)
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
                let identity = saved.map { modelIdentity.resolve($0, pricing: pricing) }
                let route = identity?.route
                let displayName = identity?.displayName
                let legacyWithoutIdentity = displayName == nil && !turn.fromReceipt
                    && !turn.id.hasPrefix("cloud:")
                    && (saved == nil || saved?.hasPrefix("m-") == true || saved?.hasPrefix("fbm1.") == true)
                let model = legacyWithoutIdentity ? FreebuffModelIdentity.olderUsageName : displayName
                    ?? saved.flatMap { (turn.fromReceipt || $0.contains("/")) && !$0.hasPrefix("fbm1.") ? $0 : nil }
                    ?? ModelUsageEntry.unattributedModelName
                // A turn aggregates multiple requests, so do not apply single-request context tiers.
                // Cached input is already in input; reasoning is already in output.
                let cost = route.flatMap { pricing.resolve(model: $0) }?.costDollars(
                    for: TokenBreakdown(input: input - cached, cacheRead: cached, output: output),
                    at: date,
                    applyLongContextRates: false
                )
                accumulator.add(day: day, tokens: total, cost: cost, model: model,
                                canonical: identity?.group, costIsComplete: cost != nil)
                if let cost {
                    accumulator.markEstimatedCost(day: day)
                    accumulator.addApiEstimate(day: day, cost: cost)
                } else if legacyWithoutIdentity {
                    // A retired/missing label on older local records is an explained history gap,
                    // not an actionable pricing failure. Preserve tokens and the lower-bound cost.
                    accumulator.addNamedUnpricedModel(day: day, model: model)
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
                hostedReceipts: hostedReceipts,
                pricingToken: pricingToken,
                catalog: modelCatalog,
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

    func resolveLocalSessions(
        _ sessions: [FreebuffActiveSession],
        now: Date = Date()
    ) -> [FreebuffActiveSession] {
        guard !sessions.isEmpty else {
            cachedSessionChats.removeAll(keepingCapacity: false)
            return []
        }
        let activeIDs = Set(sessions.map(\.instanceID))
        cachedSessionChats = cachedSessionChats.filter { activeIDs.contains($0.key) }

        var result = sessions
        var unresolvedIndices: [Int] = []
        let manual = ProviderRefreshContext.isManual

        for (index, session) in sessions.enumerated() {
            if session.instanceID == "single" || session.instanceID == "cli" { continue }
            if let cached = cachedSessionChats[session.instanceID],
               cachedTitleIsReusable(cached, now: now, manual: manual) {
                if !cached.chatTitle.isEmpty {
                    result[index].chatTitle = cached.chatTitle
                    result[index].projectPath = cached.projectPath
                    result[index].threadID = cached.threadID
                }
            } else {
                unresolvedIndices.append(index)
            }
        }
        guard !unresolvedIndices.isEmpty else { return result }

        var remainingInstanceIDs = Set(unresolvedIndices.map { result[$0].instanceID })
        let instanceToThread = sessionEndThreads(for: remainingInstanceIDs)
        var remainingThreadIDs = Set(instanceToThread.values)

        let knownPaths = Array(Set(unresolvedIndices.compactMap { index -> String? in
            cachedSessionChats[result[index].instanceID]?.sourcePath.nilIfEmpty
        }))
        for path in knownPaths where !remainingInstanceIDs.isEmpty {
            ingestSessionChats(
                path: path, now: now,
                instanceToThread: instanceToThread,
                remainingInstanceIDs: &remainingInstanceIDs,
                remainingThreadIDs: &remainingThreadIDs
            )
        }

        if !remainingInstanceIDs.isEmpty, let paths = try? databasePaths() {
            let known = Set(knownPaths)
            let sortedPaths = paths.filter { !known.contains($0) }.sorted { lhs, rhs in
                let left = (try? FileManager.default.attributesOfItem(atPath: lhs)[.modificationDate] as? Date) ?? .distantPast
                let right = (try? FileManager.default.attributesOfItem(atPath: rhs)[.modificationDate] as? Date) ?? .distantPast
                return left > right
            }
            for path in sortedPaths where !remainingInstanceIDs.isEmpty {
                ingestSessionChats(
                    path: path, now: now,
                    instanceToThread: instanceToThread,
                    remainingInstanceIDs: &remainingInstanceIDs,
                    remainingThreadIDs: &remainingThreadIDs
                )
            }
        }

        for id in remainingInstanceIDs {
            if var existing = cachedSessionChats[id], !existing.sourcePath.isEmpty {
                existing.fetchedAt = now
                cachedSessionChats[id] = existing
            } else {
                cachedSessionChats[id] = SessionChatInfo(
                    chatTitle: "", projectPath: "", threadID: "",
                    sourcePath: "", sourceStamp: .missing, fetchedAt: now
                )
            }
        }

        for index in unresolvedIndices {
            let iid = result[index].instanceID
            if let resolved = cachedSessionChats[iid], !resolved.chatTitle.isEmpty {
                result[index].chatTitle = resolved.chatTitle
                result[index].projectPath = resolved.projectPath
                result[index].threadID = resolved.threadID
            }
        }
        return result
    }

    /// An unchanged database keeps its title with no sqlite3 spawn. A changed database waits out
    /// `titleRefreshInterval` unless the user asked for a refresh, so chat traffic does not re-read
    /// titles on every poll. The next read then returns the renamed title.
    private func cachedTitleIsReusable(_ cached: SessionChatInfo, now: Date, manual: Bool) -> Bool {
        if cached.sourcePath.isEmpty {
            return !manual && now.timeIntervalSince(cached.fetchedAt) < Self.titleRefreshInterval
        }
        if sourceStamp(cached.sourcePath) == cached.sourceStamp { return true }
        return !manual && now.timeIntervalSince(cached.fetchedAt) < Self.titleRefreshInterval
    }

    private func sessionEndThreads(for instanceIDs: Set<String>) -> [String: String] {
        guard let endsPath = sessionEndsPath(),
              let data = try? Data(contentsOf: URL(fileURLWithPath: endsPath)),
              let rawArray = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        else { return [:] }
        var instanceToThread: [String: String] = [:]
        for entry in rawArray {
            if let iid = (entry["instanceId"] as? String)?.nilIfEmpty,
               let tid = (entry["threadId"] as? String)?.nilIfEmpty,
               instanceIDs.contains(iid) {
                instanceToThread[iid] = tid
            }
        }
        return instanceToThread
    }

    private func ingestSessionChats(
        path: String,
        now: Date,
        instanceToThread: [String: String],
        remainingInstanceIDs: inout Set<String>,
        remainingThreadIDs: inout Set<String>
    ) {
        guard let jsonString = try? FreebuffDesktopUsageSQL.readActiveSessionChats(
            sqlite: sqlite, path: path,
            instanceIDs: Array(remainingInstanceIDs),
            threadIDs: Array(remainingThreadIDs)
        ),
        let data = jsonString.data(using: .utf8),
        let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return }

        let stamp = sourceStamp(path)
        var best: [String: (preferred: Bool, info: SessionChatInfo)] = [:]
        for row in rows {
            let iid = (row["instanceId"] as? String) ?? ""
            let tid = (row["threadId"] as? String) ?? ""
            let title = ((row["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let project = (row["projectPath"] as? String) ?? ""
            guard !title.isEmpty else { continue }
            let info = SessionChatInfo(
                chatTitle: title, projectPath: project, threadID: tid,
                sourcePath: path, sourceStamp: stamp, fetchedAt: now
            )
            var targets: [String] = []
            if !iid.isEmpty, remainingInstanceIDs.contains(iid) { targets.append(iid) }
            for (targetIID, targetTID) in instanceToThread where targetTID == tid && remainingInstanceIDs.contains(targetIID) {
                targets.append(targetIID)
            }
            guard !targets.isEmpty else { continue }
            for target in Set(targets) {
                let preferred = instanceToThread[target] == tid && !tid.isEmpty
                if let existing = best[target], existing.preferred, !preferred { continue }
                best[target] = (preferred, info)
            }
            if !tid.isEmpty { remainingThreadIDs.remove(tid) }
        }
        for (instanceID, match) in best {
            cachedSessionChats[instanceID] = match.info
            remainingInstanceIDs.remove(instanceID)
        }
    }

    private func sourceStamp(_ path: String) -> SourceStamp {
        func part(_ name: String) -> (UInt64, TimeInterval) {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: name) else { return (0, 0) }
            let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
            let modified = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return (size, modified)
        }
        let db = part(path)
        let wal = part(path + "-wal")
        return SourceStamp(dbSize: db.0, dbModified: db.1, walSize: wal.0, walModified: wal.1)
    }

    func unloadCachesForMemoryPressure() {
        databases.removeAll(keepingCapacity: false)
        databaseOrder.removeAll(keepingCapacity: false)
        retainedTurns = 0
        cachedScan = nil
        cachedPaths = nil
        cachedPathsAt = nil
        routePricingToken = nil
        routeCatalog.removeAll(keepingCapacity: false)
        modelIdentity = FreebuffModelIdentity(entries: [:], pricing: .empty)
        cachedSessionChats.removeAll(keepingCapacity: false)
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
            partial: usage == nil || metrics["usageIncomplete"] as? Bool == true
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
