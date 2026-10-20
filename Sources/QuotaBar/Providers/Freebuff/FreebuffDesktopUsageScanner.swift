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
        var rows: [[String: String]]
    }
    private var databases: [String: CachedDatabase] = [:]
    private var routeRevision = ""
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

    func hasHistory() throws -> Bool { try !databasePaths().isEmpty }

    func scan(now: Date, pricing: ModelPricing = .empty,
              modelCatalog: [String: FreebuffModelCatalog.Entry] = [:]) throws -> Scan? {
        try Task.checkCancellation()
        let paths = try databasePaths().sorted()
        guard !paths.isEmpty else { return nil }
        let routeRevision = pricing.aggregateCacheToken + modelCatalog.keys.sorted().map {
            "\($0):\(modelCatalog[$0]!.displayName)"
        }.joined(separator: "\n")
        if self.routeRevision != routeRevision {
            modelRoutes = FreebuffModelCatalog.openRouterRoutes(entries: modelCatalog, pricing: pricing)
            self.routeRevision = routeRevision
        }
        databases = databases.filter { paths.contains($0.key) }
        var rows: [[String: String]] = []
        for path in paths {
            let before = try revisions([path])
            if let cached = databases[path], cached.revision == before {
                rows.append(contentsOf: cached.rows)
            } else {
                try Task.checkCancellation()
                // Saved selection is used only for the owner's explicitly requested estimate when
                // a receipt lacks its serving model. The provider source note explains that limit.
                let sql = """
                SELECT COALESCE(json_group_array(json_object(
                  'id', m.thread_id || ':' || m.seq,
                  'timestamp', CAST(m.ts AS TEXT), 'metrics', m.metrics_json,
                  'selectedModel', COALESCE(t.model, '')
                )), '[]') FROM messages m JOIN threads t ON t.id = m.thread_id
                WHERE t.harness_id = 'codebuff' AND m.role = 'assistant'
                  AND m.metrics_json IS NOT NULL AND m.metrics_json != '{}'
                """
                guard let text = try sqlite.queryValue(path: path, sql: sql),
                      let data = text.data(using: .utf8),
                      let decoded = try JSONSerialization.jsonObject(with: data) as? [[String: String]]
                else { throw FreebuffUsageError.localHistoryUnreadable }
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
        for row in rows {
            try Task.checkCancellation()
            guard let id = row["id"],
                  let stamp = row["timestamp"].flatMap(Double.init), stamp.isFinite,
                  let metricsText = row["metrics"],
                  let metrics = ProviderParse.jsonObject(Data(metricsText.utf8))
            else { throw FreebuffUsageError.localHistoryUnreadable }
            guard seen.insert(id).inserted else { continue }
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
            let saved = recordedModel ?? row["selectedModel"]?.nilIfEmpty
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
        return Scan(usage: accumulator.build(), partialDays: partialDays)
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
