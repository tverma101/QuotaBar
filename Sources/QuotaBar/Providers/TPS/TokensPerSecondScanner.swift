import Foundation

/// Folds every local-log corpus QuotaBar tracks into one tokens-per-second estimate for the
/// Total Spend panel's TPS lens. Engine discipline (the lens feeds every accounting pass, so it
/// must stay cheap):
/// - Reuses each corpus's incremental parse caches — unchanged files are never re-parsed. Claude
///   entries share the native card's whole-file cache (`parseSourceIdentity`); Codex shares the
///   rollout cache; Grok and Pi share theirs; Muse streams via its own session-folder fold.
/// - The window is bounded (14 days) so the fold stays proportional to recent work, not the
///   corpus depth.
/// - Folds run sequentially in one pass; each is mostly cache-warm after the first run.
actor TokensPerSecondScanner {
    private let claude: ClaudeLogUsageScanner
    private let codex: CodexLogUsageScanner
    private let grok: GrokLogUsageScanner
    private let muse: MuseUsageScanner
    private let pi: PiUsageScanner
    private let museSessionsRoot: @Sendable () -> URL
    private let zaiDatabasePath: @Sendable () -> String?

    init(
        claude: ClaudeLogUsageScanner = ClaudeLogUsageScanner(),
        codex: CodexLogUsageScanner = CodexLogUsageScanner(),
        grok: GrokLogUsageScanner = GrokLogUsageScanner(),
        muse: MuseUsageScanner = MuseUsageScanner(),
        pi: PiUsageScanner = PiUsageScanner(),
        museSessionsRoot: @escaping @Sendable () -> URL = {
            MusePaths.sessionsDirectory(homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
        },
        zaiDatabasePath: @escaping @Sendable () -> String? = {
            let path = (ZCodeUsageScanner.defaultSqlitePath as NSString).expandingTildeInPath
            return FileManager.default.fileExists(atPath: path) ? path : nil
        }
    ) {
        self.claude = claude
        self.codex = codex
        self.grok = grok
        self.muse = muse
        self.pi = pi
        self.museSessionsRoot = museSessionsRoot
        self.zaiDatabasePath = zaiDatabasePath
    }

    /// `nil` when any source changed mid-fold or could not be read; callers keep last-good data
    /// instead of publishing a partial rate. Absent corpora are normal — the matrix is
    /// machine-local, and a provider with no logs is a missing slice, never a failure.
    func scan(daysBack: Int = TokensPerSecond.windowDays, now: Date = Date()) async -> TokensPerSecondEstimate? {
        let accumulators = Accumulators()

        let claudeComplete = await claude.foldUsageEntries(daysBack: daysBack, now: now) { entry in
            accumulators["claude"].ingest(
                outputTokens: entry.tokens.output,
                at: entry.timestamp,
                model: entry.model
            )
        }
        guard claudeComplete, !Task.isCancelled else { return nil }

        let codexComplete = await codex.foldParsedEvents(daysBack: daysBack, now: now) { event in
            accumulators["codex"].ingest(
                outputTokens: event.output,
                at: event.timestamp,
                model: event.model
            )
        }
        guard codexComplete, !Task.isCancelled else { return nil }

        let grokComplete = await grok.foldUsageEntries(daysBack: daysBack, now: now) { entry in
            accumulators["grok"].ingest(
                outputTokens: entry.tokens.output,
                at: entry.timestamp,
                model: entry.model
            )
        }
        guard grokComplete, !Task.isCancelled else { return nil }

        // Muse: assistant-message entries stream in file order via its parse fold; a missing or
        // unreadable sessions root yields an empty result, not an error.
        let museRoot = museSessionsRoot()
        if let museEntries = await muse.parsedEntriesIfComplete(daysBack: daysBack, now: now, roots: [museRoot]) {
            for entry in museEntries {
                accumulators["muse"].ingest(
                    outputTokens: entry.tokens.output,
                    at: entry.timestamp,
                    model: entry.model
                )
            }
        } else if FileManager.default.fileExists(atPath: museRoot.path) {
            // Root exists but could not be read completely — keep last-good rather than
            // publishing a partial Muse rate; an absent root is just "no Muse data".
            return nil
        }

        let piComplete = await pi.foldUsageEntries(daysBack: daysBack, now: now) { entry in
            accumulators["pi"].ingest(
                outputTokens: entry.tokens.output,
                at: entry.timestamp,
                model: entry.model
            )
        }
        guard piComplete, !Task.isCancelled else { return nil }

        // ZCode rows carry Z.ai's own stream timing when the server reported one; rows without a
        // stream window fold through the same pair rule as every other corpus.
        guard await zaiFold(daysBack: daysBack, now: now, accumulators: accumulators), !Task.isCancelled
        else { return nil }

        return TokensPerSecondEstimate.from(accumulators.accumulators)
    }

    /// One `model_usage` row per ZCode API call with `started_at`/`first_token_at`/`completed_at`
    /// in epoch ms, `model_id`, `output_tokens`, `status`. Rows with a stream window (both token
    /// timestamps, output > 0, ≤5 minutes) get their interval verbatim; the rest join the ordinary
    /// pair fold with their `started_at` as the boundary marker.
    private func zaiFold(
        daysBack: Int,
        now: Date,
        accumulators: Accumulators
    ) async -> Bool {
        guard let path = zaiDatabasePath() else { return true }
        let sinceMs = Int64(JSONLScanning.sinceDate(daysBack: daysBack, now: now).timeIntervalSince1970 * 1000)
        let sql = """
        SELECT started_at || ' | ' || COALESCE(first_token_at,'') || ' | ' || COALESCE(completed_at,'') || ' | ' || model_id || ' | ' || output_tokens
        FROM model_usage
        WHERE started_at >= \(sinceMs) AND status = 'completed'
        ORDER BY started_at
        """
        let raw: String
        do {
            guard let value = try SQLiteCLIAccessor().queryValue(path: path, sql: sql) else {
                // Present but empty: no completed calls in the window — not an error.
                return true
            }
            raw = value
        } catch {
            AppLog.warn(LogTag.plugin("zai"), "TPS fold could not read ZCode's database; keeping last-good data")
            return false
        }
        for line in raw.split(separator: "\n") {
            let fields = line.split(separator: "|", omittingEmptySubsequences: false)
            guard fields.count == 5,
                  let startedMs = Int64(fields[0].trimmingCharacters(in: .whitespaces)),
                  let output = Int(fields[4].trimmingCharacters(in: .whitespaces))
            else { continue }
            let timestamp = Date(timeIntervalSince1970: Double(startedMs) / 1000)
            let firstMs = Int64(fields[1].trimmingCharacters(in: .whitespaces))
            let completedMs = Int64(fields[2].trimmingCharacters(in: .whitespaces))
            let model = fields[3].trimmingCharacters(in: .whitespaces)
            if let firstMs, let completedMs, completedMs >= firstMs, output > 0 {
                let direct = Double(completedMs - firstMs) / 1000
                accumulators["zai"].ingest(outputTokens: output, at: timestamp, model: model, directInterval: direct)
            } else {
                accumulators["zai"].ingest(outputTokens: output, at: timestamp, model: model)
            }
        }
        return true
    }

    private final class Accumulators: @unchecked Sendable {
        var accumulators: [String: TokensPerSecondAccumulator] = [
            "claude": TokensPerSecondAccumulator(),
            "codex": TokensPerSecondAccumulator(),
            "grok": TokensPerSecondAccumulator(),
            "muse": TokensPerSecondAccumulator(),
            "pi": TokensPerSecondAccumulator(),
            "zai": TokensPerSecondAccumulator()
        ]

        subscript(_ key: String) -> TokensPerSecondAccumulator {
            get { accumulators[key]! }
            set { accumulators[key] = newValue }
        }
    }
}
