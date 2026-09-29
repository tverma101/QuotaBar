import Foundation

/// Reads Muse session logs (`~/.local/share/muse/sessions/**/*.jsonl`) and folds
/// Muse's OpenCode Go-billed usage into the OpenCode provider's tiles + trend.
///
/// Muse, when launched via `muse-go`, routes Meta Muse Spark through
/// `https://opencode.ai/zen/go/v1` — the same hosted Go account as `opencode-go`.
/// That bridge bypasses `opencode.db`, so without a fold Muse spend is invisible.
/// Muse's runtime emits `goal_usage_attribution` with per-step token counts;
/// this scanner sums the `reported:true` rows (the provider-billed ones) and
/// attributes them to the session's model (`muse-spark-1.*` → Go).
///
/// Analogous to `ClaudeLogUsageScanner.parsedEntries` / `CodexLogUsageScanner.parsedEvents`:
/// the caller passes `roots` so tests stay hermetic, and the persistent
/// `IncrementalJSONLScanner` cache is shared — unchanged session files aren't
/// re-parsed on every 5-minute refresh.
actor MuseUsageScanner {
    private let homeDirectory: @Sendable () -> URL
    private let scanner: IncrementalJSONLScanner<Entry>

    struct Entry: Codable, Sendable, Equatable {
        var timestamp: Date
        var tokens: TokenBreakdown
        var model: String?
    }

    private static let sharedScanner = IncrementalJSONLScanner<Entry>(
        retainResidentItems: false,
        logTag: LogTag.plugin("muse"),
        persistence: JSONLScanCachePersistence(namespace: "muse", schemaVersion: 1)
    )

    static func flushPersistentCacheWrites() async {
        await sharedScanner.flushPendingWrites()
    }

    init(
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser },
        incrementalScanner: IncrementalJSONLScanner<Entry>? = nil
    ) {
        self.homeDirectory = homeDirectory
        self.scanner = incrementalScanner ?? Self.sharedScanner
    }

    /// Default Muse sessions root on this machine.
    static func defaultSessionsRoot(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        MusePaths.sessionsDirectory(homeDirectory: homeDirectory)
    }

    /// Raw usage entries from the last `daysBack` days — the same incremental scan the
    /// OpenCode fold calls, but returning Entry items so both consumers share one cache.
    func parsedEntries(daysBack: Int = 33, now: Date = Date(), roots: [URL]) async -> [Entry] {
        let since = JSONLScanning.sinceDate(daysBack: daysBack, now: now)
        let identityPaths = Set(roots.map { $0.resolvingSymlinksInPath().standardizedFileURL.path })
            .sorted()
        let cacheIdentity = identityPaths.isEmpty ? "no-muse-root" : identityPaths.joined(separator: "\n")
        let files = Self.usageFiles(under: roots)
        guard !files.isEmpty else { return [] }
        return await scanner.items(
            from: files, since: since, cacheIdentity: cacheIdentity, parseFile: { url in Self.parseFile(at: url) }
        ) ?? []
    }

    /// Every `session.jsonl` under each root, path-sorted. Only session files
    /// carry `goal_usage_attribution` — the `approval-review/` and `process-owners/`
    /// trees hold unrelated review logs. Restricting to `session.jsonl` cuts the
    /// parse set from ~1755 to ~700 files without missing any billed usage
    /// (subagent sessions also use `session.jsonl` inside `subagent/<id>/`).
    static func usageFiles(under roots: [URL]) -> [JSONLScanning.DiscoveredFile] {
        roots.flatMap { JSONLScanning.jsonlFiles(under: $0) }
            .filter { $0.path.hasSuffix("/session.jsonl") }
            .sorted { $0.path < $1.path }
    }

    /// Streaming parser — a large session file never becomes one giant Data allocation.
    nonisolated static func parseFile(at url: URL) -> [Entry]? {
        var entries: [Entry] = []
        let readSucceeded = JSONLFileReader.forEachLine(at: url) { line in
            appendEntries(from: line, to: &entries)
        }
        guard readSucceeded else { return nil }
        return entries
    }

    static func parseFile(_ data: Data) -> [Entry] {
        var entries: [Entry] = []
        for line in data.split(separator: UInt8(ascii: "\n")) {
            appendEntries(from: line, to: &entries)
        }
        return entries
    }

    // Fast pre-filter: only lines mentioning the attribution kind carry usage.
    private static let marker = Data("\"goal_usage_attribution\"".utf8)

    private static func appendEntries(from line: Data.SubSequence, to entries: inout [Entry]) {
        guard line.range(of: marker) != nil else { return }
        let lineData = Data(line)
        guard let object = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any],
              let payload = object["payload"] as? [String: Any],
              let event = payload["event"] as? [String: Any],
              event["kind"] as? String == "goal_usage_attribution",
              let record = event["record"] as? [String: Any],
              let quantity = record["quantity"] as? [String: Any],
              (quantity["reported"] as? Bool) == true,
              quantity["unit"] as? String == "tokens"
        else { return }

        let input = ProviderParse.number(quantity["input_tokens"]) ?? 0
        let output = ProviderParse.number(quantity["output_tokens"]) ?? 0
        let cached = ProviderParse.number(quantity["cached_tokens"]) ?? 0
        let reasoning = ProviderParse.number(quantity["reasoning_tokens"]) ?? 0
        // Muse attribution is per-step, not incremental — each line already is one billed turn.
        // Input is total; cached is the prefix-hit portion inside it.
        let uncachedInput = max(0, input - cached)

        // Timestamp is the durable `recorded_at` (microseconds since epoch).
        // Every real Muse session carries it; a line without it is skipped.
        guard let micros = ProviderParse.number(object["recorded_at"]) else { return }
        let timestamp = Date(timeIntervalSince1970: micros / 1_000_000)

        // Model: from the run's metadata in the same file would be ideal, but Muse's
        // attribution line doesn't carry it. The sessions root's metadata file holds
        // provider/model, but per-line we assume the bridged Muse model (muse-spark)
        // when the session's harness IS opencode-go. Callers map this to Go billing;
        // a non-Go Muse session (direct Meta, not via bridge) still folds under Go
        // when the model is muse-spark — the quota is the same upstream.
        let model = (record["model"] as? String)
            ?? (quantity["model"] as? String)
            ?? "muse-spark-1.2-contributor"

        // Zero-token attributions are bookkeeping placeholders (reported:false filtered above,
        // but reported:true can still be 0-0 on some control steps) — skip them.
        let total = uncachedInput + output + cached + reasoning
        guard total > 0 else { return }

        entries.append(Entry(
            timestamp: timestamp,
            tokens: TokenBreakdown(
                // Saturating: a malformed record must cost a wrong number, never a process kill. This
                // scanner has no dedicated test file, so the hazard was entirely unexercised.
                input: ProviderParse.intFromClampedDouble(uncachedInput),
                cacheWrite5m: 0,
                cacheRead: ProviderParse.intFromClampedDouble(cached),
                output: ProviderParse.intFromClampedDouble(output + reasoning)
            ),
            model: model
        ))
    }
}
