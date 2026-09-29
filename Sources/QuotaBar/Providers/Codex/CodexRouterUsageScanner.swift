import Foundation

/// Reads CodexRouter's append-only `usage-events.jsonl` ledger so QuotaBar can attribute
/// Codex-CLI traffic that was routed through the local router into the Codex card's daily
/// token/cost history.
///
/// CodexRouter meters every routed turn (native OpenAI and alternate providers reached via the
/// Codex CLI → router path) into `~/.codex/codex-router/usage-events.jsonl`. QuotaBar already
/// merges native session logs with FCC's SQLite proxy ledger; this scanner is the CodexRouter
/// equivalent of `CodexProxyUsageScanner`.
///
/// Provider attribution: every successful event in the ledger is Codex-CLI-routed traffic, so
/// non-`openai` providers (e.g. `opencode-go`) are eligible — but OpenCode Go/Zen gateway models
/// are skipped so Total Spend does not double-count the same turn on the OpenCode card (mirrors
/// `CodexLogUsageScanner`).
///
/// Account scoping: new router events stamp `accountFingerprint` (FCC-compatible
/// `acct_` + SHA256("openai\\0" + accountId)[:6]). When a card has an `expectedIdentityKey`, only
/// matching fingerprints (or raw `accountId`) are kept. Legacy rows without identity are only
/// absorbed when `allowsUnscopedEvents` is true (single/default Codex card) so multi-account
/// installs never cross-attribute unscoped history.
///
/// Efficiency: production reads stream through `JSONLFileReader` and keep an append-only tail
/// checkpoint so a growing ledger is not fully re-parsed every 5 minutes. Both Codex cards share
/// one process-wide parse cache (`cacheIdentity` = "codex-router") so a multi-account refresh does
/// not double the I/O. Tests may inject `readFile` to keep an in-memory ledger without touching disk.
actor CodexRouterUsageScanner {
    private let environment: EnvironmentReading
    private let homeDirectory: @Sendable () -> URL
    private let ledgerPaths: @Sendable () -> [String]
    /// When non-nil, production disk/incremental paths are skipped (unit-test injection).
    private let readFile: (@Sendable (String) -> String?)?
    /// Optional alias map (lowercased key → ChatGPT account UUID) so pool opaque ids
    /// (`acct_<base64url>`) stamped on ledger rows still match QuotaBar cards keyed by UUID.
    private let identityAliases: @Sendable () -> [String: String]
    private let scanner: IncrementalJSONLScanner<Event>

    /// Empty checkpoint: router lines are independent (no cross-line parser state).
    private struct ParserCheckpoint: Sendable, Equatable {}

    private static let sharedTailCache = AppendOnlyFileTailCache<Event, ParserCheckpoint>(
        maxEntries: 8,
        maxRetainedItems: 64_000
    )

    private static let sharedScanner = IncrementalJSONLScanner<Event>(
        maxResidentIdentities: 2,
        retainResidentItems: false,
        logTag: LogTag.plugin("codex"),
        persistence: JSONLScanCachePersistence(namespace: "codex-router", schemaVersion: 1)
    )

    /// Shared across every Codex card so two accounts do not re-parse the same ledger.
    private static let sharedCacheIdentity = "codex-router"

    static func flushPersistentCacheWrites() async {
        await sharedScanner.flushPendingWrites()
    }

    static func unloadSharedTailCacheItems() {
        sharedTailCache.unloadRetainedItems()
    }

    /// Test hook: append-only parse counters for the shared router ledger path.
    static func incrementalReadStatisticsForTesting(path: String) -> (fullParses: Int, tailParses: Int, bytesRead: Int)? {
        guard let stats = sharedTailCache.statistics(for: path) else { return nil }
        return (stats.fullParses, stats.tailParses, stats.bytesRead)
    }

    init(
        environment: EnvironmentReading = QuotaBarEnvironmentReader(),
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser },
        ledgerPaths: (@Sendable () -> [String])? = nil,
        readFile: (@Sendable (String) -> String?)? = nil,
        identityAliases: (@Sendable () -> [String: String])? = nil,
        incrementalScanner: IncrementalJSONLScanner<Event>? = nil
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.ledgerPaths = ledgerPaths ?? {
            Self.defaultLedgerPaths(environment: environment, homeDirectory: homeDirectory())
        }
        self.readFile = readFile
        self.identityAliases = identityAliases ?? {
            Self.loadPoolIdentityAliases(environment: environment, homeDirectory: homeDirectory())
        }
        self.scanner = incrementalScanner ?? Self.sharedScanner
    }

    /// Scan the CodexRouter ledger for one Codex card. Returns `nil` when nothing matched so the
    /// caller leaves native logs / FCC untouched.
    func scan(
        accountIdentityKey: String?,
        allowsUnscopedEvents: Bool,
        daysBack: Int = UsageHistoryWindow.previousDays,
        now: Date = Date(),
        pricing: ModelPricing
    ) async -> LogUsageScan? {
        let days = max(1, daysBack)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let since = calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today
        let fold = AggregateFoldState()
        let expectedFingerprint = CodexProxyUsageScanner.accountFingerprint(for: accountIdentityKey)
        let expectedAccountId = accountIdentityKey?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        let aliases = identityAliases()
        // Reverse map: UUID → pool opaque ids that belong to this card.
        let expectedAliasIds: Set<String> = {
            guard let expectedAccountId else { return [] }
            let needle = expectedAccountId.lowercased()
            return Set(aliases.compactMap { (key, value) in
                value.lowercased() == needle ? key.lowercased() : nil
            })
        }()

        let visitOne: @Sendable (Event) -> Void = { event in
            guard Self.isSuccessfulStatus(event.status) else { return }
            guard Self.belongsToAccount(
                event,
                expectedFingerprint: expectedFingerprint,
                expectedAccountId: expectedAccountId,
                expectedAliasIds: expectedAliasIds,
                allowsUnscopedEvents: allowsUnscopedEvents
            ) else { return }
            guard event.timestamp >= since else { return }

            let model = event.model
            // Same gateway skip as session logs: OpenCode card owns these turns.
            if OpenCodeUsageScanner.isHostedGatewayModel(model) { return }

            let input = event.inputTokens
            let cached = min(event.cachedInputTokens, input)
            let output = event.outputTokens
            let reasoning = event.reasoningTokens
            // OpenAI/Codex `total_tokens` is input+output; reasoning is a subset of output. Never
            // add reasoning on top when totalTokens is absent — that double-counted tokens.
            let total = event.totalTokens ?? {
                let result = input.addingReportingOverflow(output)
                return result.overflow ? input : result.partialValue
            }()
            guard total > 0 else { return }

            fold.sawRows = true
            let day = DailyUsageAccumulator.dayKey(from: event.timestamp, calendar: calendar)
            // Use the same Codex cost helper as session logs (priority multiplier, long-context
            // tiers, cache-discount rules). Plain ModelPricing.estimatedCostDollars understates
            // ChatGPT/Codex routed spend relative to the Codex card.
            // Resolve pricing against slug candidates, then the dated Luna fallback used for
            // auto-review / gpt-reserve (same as CodexLogUsageScanner) so new/unknown reserve
            // slugs still count tokens instead of vanishing into the warning-only set.
            let atISO = OpenUsageISO8601.string(from: event.timestamp)
            let candidates = Self.pricingModelCandidates(for: model) + [
                CodexLogUsageScanner.pricingFallbackModel(
                    for: model,
                    at: atISO
                )
            ].compactMap { $0 }
            // Prefer an exact catalog key so a gateway-tagged slug is identified as the model it routes
            // to. `resolve` alone would match the whole prefixed string fuzzily, which prices correctly
            // but leaves the row named `anthropic/openai/gpt-5.6-luna` — a second row for one model.
            let exactIdentity = pricing.canonicalKey(for: candidates)
            guard let pricingModel = exactIdentity ?? candidates.first(where: { pricing.resolve(model: $0) != nil }),
                  let rates = pricing.resolve(model: pricingModel)
            else {
                if total > 0 {
                    fold.accumulator.addUnknownModel(day: day, model: model)
                }
                return
            }
            // Match session-log rules: only priority/fast tiers apply the Codex multiplier.
            // Router rows omit serviceTier today (and Codex config often uses `default`), so
            // standard API rates apply unless the ledger stamps priority/fast.
            let isPriorityTier = event.serviceTier == "fast" || event.serviceTier == "priority"
            let logEvent = CodexLogUsageScanner.Event(
                timestamp: event.timestamp,
                model: model,
                pricingModel: pricingModel,
                input: input,
                cached: cached,
                output: output,
                reasoning: reasoning,
                total: total,
                isFast: isPriorityTier
            )
            let cost = CodexLogUsageScanner.cost(
                rates: rates,
                event: logEvent,
                model: pricingModel,
                fastTier: isPriorityTier,
                fastMultiplier: CodexLogUsageScanner.codexPriorityMultiplier(
                    for: pricingModel,
                    rates: rates
                )
            )
            // `pricingModel` is the identity: the router stamps the upstream path onto its slugs, so the
            // same model arrives tagged and untagged. Keying the row by the raw slug split it in two and
            // double-counted it in the period total; the observed spelling still reaches the tooltip as a
            // variant, so nothing is lost by grouping on what pricing actually resolved.
            fold.accumulator.add(
                day: day,
                tokens: total,
                cost: cost,
                model: model,
                canonical: GatewaySlug.identity(of: model, resolvedPricingModel: pricingModel)
            )
        }

        // Unit tests inject an in-memory ledger; keep that path allocation-light and deterministic.
        if let readFile {
            for path in ledgerPaths() {
                guard !Task.isCancelled else { return nil }
                guard let contents = readFile(path) else { continue }
                for line in contents.split(whereSeparator: \.isNewline) {
                    guard !Task.isCancelled else { return nil }
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty,
                          let data = trimmed.data(using: .utf8),
                          let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                          let event = Self.parseEvent(object)
                    else { continue }
                    visitOne(event)
                }
            }
        } else {
            let files = Self.discoveredLedgers(paths: ledgerPaths())
            // Keep ~35 days of parsed rows in the append checkpoint so multi-account refreshes
            // share one parse without retaining the entire historical ledger in RAM.
            let retentionDays = max(days, 35)
            let emitSince = JSONLScanning.sinceDate(daysBack: retentionDays, now: now)
            // Ledger mtime is usually "now" (append-only). Use a deep since so the file is not
            // skipped by IncrementalJSONLScanner's mtime window; account filtering still uses `since`.
            let cacheSince = Date.distantPast
            let ok = await scanner.foldItems(
                from: files,
                since: cacheSince,
                cacheIdentity: Self.sharedCacheIdentity,
                parseFile: { url in
                    Self.parseFileIncrementally(at: url, emitSince: emitSince)
                },
                visit: { event in
                    if event.timestamp >= since {
                        visitOne(event)
                    }
                }
            )
            if !ok { return nil }
        }

        guard fold.sawRows else { return nil }
        let result = fold.accumulator.build()
        return result.series.daily.isEmpty && result.unknownModelsByDay.isEmpty ? nil : result
    }

    /// Escaping fold visits cannot capture `inout` accumulators; this tiny box owns them.
    private final class AggregateFoldState: @unchecked Sendable {
        var sawRows = false
        var accumulator = DailyUsageAccumulator()
    }

    static func defaultLedgerPaths(
        environment: EnvironmentReading,
        homeDirectory: URL
    ) -> [String] {
        let configured = [
            environment.value(for: "OPENUSAGE_CODEX_ROUTER_USAGE_EVENTS"),
            environment.value(for: "CODEX_ROUTER_STATE_DIR").map {
                URL(fileURLWithPath: $0).appendingPathComponent("usage-events.jsonl").path
            },
            environment.value(for: "MODEL_ROUTER_STATE_DIR").map {
                URL(fileURLWithPath: $0).appendingPathComponent("usage-events.jsonl").path
            }
        ].flatMap(splitPaths)
        guard configured.isEmpty else { return unique(configured) }
        return [
            homeDirectory
                .appendingPathComponent(".codex/codex-router/usage-events.jsonl")
                .path
        ]
    }

    // MARK: - Incremental parse

    private static func discoveredLedgers(paths: [String]) -> [JSONLScanning.DiscoveredFile] {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .attributeModificationDateKey
        ]
        var files: [JSONLScanning.DiscoveredFile] = []
        var seen: Set<String> = []
        for path in paths {
            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            let standardized = url.path
            guard seen.insert(standardized).inserted else { continue }
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true
            else { continue }
            files.append(JSONLScanning.DiscoveredFile(
                path: standardized,
                size: values.fileSize ?? 0,
                mtime: values.contentModificationDate ?? .distantPast,
                attributeMtime: values.attributeModificationDate
            ))
        }
        return files
    }

    /// Read only bytes after the prior EOF when the file still proves to be an append of the same
    /// prefix. Otherwise stream a full parse and replace the checkpoint.
    nonisolated private static func parseFileIncrementally(
        at url: URL,
        emitSince: Date
    ) -> [Event]? {
        let key = url.resolvingSymlinksInPath().path
        let currentRevision = AppendOnlyFileProbe.revision(at: url)

        if let currentRevision,
           let cached = sharedTailCache.entry(for: key),
           currentRevision.device == cached.revision.device,
           currentRevision.inode == cached.revision.inode,
           currentRevision.size == cached.offset,
           AppendOnlyFileProbe.anchor(at: url, endingAt: cached.offset) == cached.anchor
        {
            if cached.itemsAvailable {
                return cached.items.filter { $0.timestamp >= emitSince }
            }
            // Checkpoint valid but items were unloaded (memory pressure). Must full-reparse —
            // returning [] would silently drop history. Routine refresh paths no longer unload
            // this cache; pressure unload still can.
            return fullParseAndCheckpoint(at: url, emitSince: emitSince, key: key)
        }

        if let currentRevision,
           let cached = sharedTailCache.entry(for: key),
           cached.itemsAvailable,
           currentRevision.device == cached.revision.device,
           currentRevision.inode == cached.revision.inode,
           currentRevision.size > cached.offset,
           AppendOnlyFileProbe.anchor(at: url, endingAt: cached.offset) == cached.anchor
        {
            var collected: [Event] = []
            var read = JSONLFileReader.readLines(
                at: url,
                chunkSize: 64 * 1024,
                startOffset: cached.offset,
                initialCarry: cached.partialLine,
                discardingOversizedLine: cached.isDiscardingOversizedLine,
                deliverFinalPartial: false
            ) { line in
                if let event = parseLine(line), event.timestamp >= emitSince {
                    collected.append(event)
                }
            }
            guard read.succeeded else { return nil }
            guard AppendOnlyFileProbe.anchor(at: url, endingAt: cached.offset) == cached.anchor else {
                return fullParseAndCheckpoint(at: url, emitSince: emitSince, key: key)
            }

            // If a final partial line is itself a complete JSON object, accept it (writers that omit
            // the trailing newline on the last record).
            if !read.finalPartial.isEmpty,
               let event = parseLine(read.finalPartial[...]),
               event.timestamp >= emitSince {
                collected.append(event)
                read.finalPartial = Data()
            }

            let newOffset = cached.offset + UInt64(read.statistics.bytesRead)
            if let after = AppendOnlyFileProbe.revision(at: url),
               after.device == currentRevision.device,
               after.inode == currentRevision.inode,
               after.size >= newOffset,
               let anchor = AppendOnlyFileProbe.anchor(at: url, endingAt: newOffset)
            {
                var merged = cached.items.filter { $0.timestamp >= emitSince }
                merged.append(contentsOf: collected)
                sharedTailCache.store(
                    AppendOnlyFileTailCache<Event, ParserCheckpoint>.Entry(
                        revision: after,
                        offset: newOffset,
                        anchor: anchor,
                        partialLine: read.finalPartial,
                        isDiscardingOversizedLine: read.isDiscardingOversizedLine,
                        parserState: ParserCheckpoint(),
                        items: merged
                    ),
                    for: key,
                    parseKind: .tail,
                    bytesRead: read.statistics.bytesRead
                )
                return merged
            }
            return fullParseAndCheckpoint(at: url, emitSince: emitSince, key: key)
        }

        return fullParseAndCheckpoint(at: url, emitSince: emitSince, key: key)
    }

    nonisolated private static func fullParseAndCheckpoint(
        at url: URL,
        emitSince: Date,
        key: String
    ) -> [Event]? {
        var collected: [Event] = []
        var read = JSONLFileReader.readLines(
            at: url,
            chunkSize: 64 * 1024,
            deliverFinalPartial: false
        ) { line in
            if let event = parseLine(line), event.timestamp >= emitSince {
                collected.append(event)
            }
        }
        guard read.succeeded else { return nil }
        if !read.finalPartial.isEmpty,
           let event = parseLine(read.finalPartial[...]),
           event.timestamp >= emitSince {
            collected.append(event)
            read.finalPartial = Data()
        }
        if let revision = AppendOnlyFileProbe.revision(at: url),
           let anchor = AppendOnlyFileProbe.anchor(at: url, endingAt: revision.size) {
            sharedTailCache.store(
                AppendOnlyFileTailCache<Event, ParserCheckpoint>.Entry(
                    revision: revision,
                    offset: revision.size,
                    anchor: anchor,
                    partialLine: read.finalPartial,
                    isDiscardingOversizedLine: read.isDiscardingOversizedLine,
                    parserState: ParserCheckpoint(),
                    items: collected
                ),
                for: key,
                parseKind: .full,
                bytesRead: read.statistics.bytesRead
            )
        }
        return collected
    }

    nonisolated private static func parseLine(_ line: Data.SubSequence) -> Event? {
        guard !line.isEmpty,
              let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any]
        else { return nil }
        return parseEvent(object)
    }

    // MARK: - Parsing

    struct Event: Codable, Equatable, Sendable {
        var timestamp: Date
        var model: String
        var provider: String
        var status: Int
        var inputTokens: Int
        var cachedInputTokens: Int
        var outputTokens: Int
        var reasoningTokens: Int
        var totalTokens: Int?
        var accountId: String?
        var accountFingerprint: String?
        /// Codex `service_tier` when the router stamped it (`priority` / `fast` / `default` / …).
        var serviceTier: String?
    }

    static func parseEvent(_ json: [String: Any]) -> Event? {
        guard let atRaw = (json["at"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let timestamp = OpenUsageISO8601.date(from: atRaw)
        else { return nil }
        let model = (json["model"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
            ?? ModelUsageEntry.unattributedModelName
        let provider = (json["provider"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
            ?? "unknown"
        let status = intValue(json["status"]) ?? 0
        return Event(
            timestamp: timestamp,
            model: model,
            provider: provider,
            status: status,
            inputTokens: max(0, intValue(json["inputTokens"]) ?? 0),
            cachedInputTokens: max(0, intValue(json["cachedInputTokens"]) ?? 0),
            outputTokens: max(0, intValue(json["outputTokens"]) ?? 0),
            reasoningTokens: max(0, intValue(json["reasoningTokens"]) ?? 0),
            totalTokens: intValue(json["totalTokens"]).map { max(0, $0) },
            accountId: (json["accountId"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty,
            accountFingerprint: (json["accountFingerprint"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty,
            serviceTier: (json["serviceTier"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty?
                .lowercased()
        )
    }

    static func isSuccessfulStatus(_ status: Int) -> Bool {
        (200..<300).contains(status)
    }

    static func belongsToAccount(
        _ event: Event,
        expectedFingerprint: String?,
        expectedAccountId: String?,
        expectedAliasIds: Set<String> = [],
        allowsUnscopedEvents: Bool
    ) -> Bool {
        let hasIdentity = event.accountFingerprint != nil || event.accountId != nil
        if hasIdentity {
            if let expectedFingerprint, let fingerprint = event.accountFingerprint,
               fingerprint.caseInsensitiveCompare(expectedFingerprint) == .orderedSame {
                return true
            }
            if let expectedAccountId, let accountId = event.accountId,
               accountId.caseInsensitiveCompare(expectedAccountId) == .orderedSame {
                return true
            }
            if let accountId = event.accountId?.lowercased(), expectedAliasIds.contains(accountId) {
                return true
            }
            // Stamped for a different account — never leak across cards.
            if expectedFingerprint != nil || expectedAccountId != nil {
                return false
            }
            // Default card with no expected identity: stamped events are still Codex traffic.
            return allowsUnscopedEvents
        }
        return allowsUnscopedEvents
    }

    /// Read `chatgpt-account-pool.json` → map pool opaque id / email aliases onto the ChatGPT
    /// `identity.accountId` UUID QuotaBar cards use as `expectedIdentityKey`.
    static func loadPoolIdentityAliases(
        environment: EnvironmentReading,
        homeDirectory: URL
    ) -> [String: String] {
        let candidates: [String] = {
            var paths: [String] = []
            if let override = environment.value(for: "MODEL_ROUTER_CHATGPT_ACCOUNT_POOL")?
                .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
                paths.append(override)
            }
            for key in ["CODEX_ROUTER_STATE_DIR", "MODEL_ROUTER_STATE_DIR"] {
                if let state = environment.value(for: key)?
                    .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
                    paths.append(
                        URL(fileURLWithPath: state)
                            .appendingPathComponent("chatgpt-account-pool.json").path
                    )
                }
            }
            paths.append(
                homeDirectory
                    .appendingPathComponent(".codex/codex-router/chatgpt-account-pool.json")
                    .path
            )
            return paths
        }()

        for path in candidates {
            guard FileManager.default.isReadableFile(atPath: path),
                  let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let accounts = root["accounts"] as? [String: Any]
            else { continue }
            var aliases: [String: String] = [:]
            for (poolId, value) in accounts {
                guard let account = value as? [String: Any] else { continue }
                let identity = account["identity"] as? [String: Any]
                let uuid = ((identity?["accountId"] as? String) ?? (account["accountId"] as? String))?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nilIfEmpty?
                    .lowercased()
                guard let uuid, !uuid.isEmpty else { continue }
                aliases[poolId.lowercased()] = uuid
                // Also accept the FCC fingerprint as an alias key when present in events.
                if let fingerprint = CodexProxyUsageScanner.accountFingerprint(for: uuid) {
                    aliases[fingerprint.lowercased()] = uuid
                }
            }
            if !aliases.isEmpty { return aliases }
        }
        return [:]
    }

    private static func pricingModelCandidates(for model: String) -> [String] {
        // FCC / gateway slugs are often multi-segment (`anthropic/openai/gpt-6-luna`).
        // Emit every suffix after a `/` plus the final path component so supplement pins and
        // catalog keys resolve even when an intermediate segment does not fuzzy-match.
        var candidates = [model]
        var remainder = model
        while let separator = remainder.firstIndex(of: "/") {
            remainder = String(remainder[remainder.index(after: separator)...])
            guard !remainder.isEmpty else { break }
            candidates.append(remainder)
        }
        return unique(candidates)
    }

    private static func intValue(_ value: Any?) -> Int? {
        guard let number = ProviderParse.number(value), number >= 0, number <= Double(Int.max) else {
            return nil
        }
        return Int(number.rounded(.down))
    }

    private static func splitPaths(_ raw: String?) -> [String] {
        guard let raw else { return [] }
        return raw.split { $0 == "," || $0 == "\n" || $0 == "\r" }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func unique(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        return paths.filter { seen.insert($0).inserted }
    }
}
