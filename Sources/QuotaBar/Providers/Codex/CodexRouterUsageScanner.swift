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
    /// Production scans fold into the on-disk aggregate. Tests that inject a scanner keep the
    /// event-retaining path so the benchmark can still measure that cache.
    private let usesInjectedScanner: Bool

    /// Reuse the already-priced daily fold when the ledger and all attribution inputs are stable.
    /// The parsed JSONL cache alone avoids disk reads; this avoids walking and pricing every retained
    /// event again on each periodic refresh.
    private struct AggregateKey: Equatable {
        var accountIdentityKey: String?
        var allowsUnscopedEvents: Bool
        var daysBack: Int
        var since: Date
        var timeZoneIdentifier: String
        var aliases: [String]
        var pricingIdentity: ObjectIdentifier
    }

    private struct SourceRevision: Equatable {
        var path: String
        var size: Int
        var mtime: Date
        var attributeMtime: Date?
        var device: UInt64
        var inode: UInt64
        var prefixAnchor: Data
    }

    private struct AggregateCache {
        var key: AggregateKey
        var sources: [SourceRevision]
        var itemCountsByPath: [String: Int]
        var result: LogUsageScan?
        /// A successful, account-matched event just beyond the last scan's `now` bound. The cache
        /// expires when that event becomes eligible, even if no ledger bytes have changed.
        var nextFutureEventAt: Date?
    }

    private enum AggregateCacheLookup {
        case miss
        case hit(LogUsageScan?)
    }

    private struct ScanPreflight {
        var sourceFiles: [JSONLScanning.DiscoveredFile]?
        var sourceRevisions: [SourceRevision]?
        var aggregateKey: AggregateKey?
        var cacheLookup: AggregateCacheLookup
        var incrementalBase: AggregateCache?
        var skipCountsByPath: [String: Int]
        var expectedFingerprint: String?
        var expectedAccountId: String?
        var expectedAliasIds: Set<String>
    }

    private var aggregateCache: AggregateCache?

    /// Empty checkpoint: router lines are independent (no cross-line parser state).
    private struct ParserCheckpoint: Sendable, Equatable {
        var emitSince: Date? = nil
    }

    private static let sharedTailCache = AppendOnlyFileTailCache<Event, ParserCheckpoint>(
        maxEntries: 8,
        maxRetainedItems: 128_000
    )
    private static let sharedTailCacheLock = NSLock()

    private static let sharedScanner = IncrementalJSONLScanner<Event>(
        maxResidentIdentities: 2,
        maxResidentItems: 128_000,
        retainResidentItems: true,
        logTag: LogTag.plugin("codex"),
        persistence: JSONLScanCachePersistence(namespace: "codex-router", schemaVersion: 1)
    )

    /// Shared across every Codex card so two accounts do not re-parse the same ledger. Retention
    /// is part of the identity because the parsed rows are filtered before entering the cache.
    private static func sharedCacheIdentity(retentionDays: Int) -> String {
        "codex-router-retention-\(retentionDays)"
    }

    private static func sharedTailCacheKey(for url: URL, retentionDays: Int) -> String {
        "\(url.resolvingSymlinksInPath().path)#retention-days=\(retentionDays)"
    }

    static func flushPersistentCacheWrites() async {
        await sharedScanner.flushPendingWrites()
    }

    static func unloadSharedTailCacheItems() {
        sharedTailCache.unloadRetainedItems()
    }

    static func clearSharedTailCacheForTesting(path: String, retentionDays: Int = 35) {
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        sharedTailCache.remove(sharedTailCacheKey(for: url, retentionDays: retentionDays))
        CodexRouterAggregateIndex.shared.clear(path: url.path)
    }

    /// Keep the hot parsed index while the panel is active, then release it when hidden or under
    /// pressure. The durable cache lets the next scan hydrate rows without parsing JSON again.
    static func unloadSharedParsedItems() async {
        await sharedScanner.unloadResidentItems()
    }

    static func resumeSharedParsedItems() async {
        // The menu-bar path no longer keeps the parsed ledger resident. Hydrating it here put the
        // whole event index back in RAM on every panel open.
    }

    /// Test hook: append-only parse counters for the shared router ledger path.
    static func incrementalReadStatisticsForTesting(
        path: String,
        retentionDays: Int = 35
    ) -> (fullParses: Int, tailParses: Int, bytesRead: Int)? {
        if let stats = CodexRouterAggregateIndex.shared.statistics(path: path) {
            return stats
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        guard let stats = sharedTailCache.statistics(
            for: sharedTailCacheKey(for: url, retentionDays: retentionDays)
        ) else { return nil }
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
        self.usesInjectedScanner = incrementalScanner != nil
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
        if readFile == nil, !usesInjectedScanner {
            // One unpaced pass seeds the on-disk aggregate inside the 120s provider deadline.
            // Later taps hit that aggregate and do not read the ledger. Leaving the 7.5% pacer on
            // made a 72MB cold fold exceed the deadline and start over on the next tap.
            return await ProviderRefreshContext.$accountingCPUThrottleEnabled.withValue(false) {
                await self.scanPersistentAggregate(
                    accountIdentityKey: accountIdentityKey,
                    allowsUnscopedEvents: allowsUnscopedEvents,
                    days: days,
                    since: since,
                    now: now,
                    calendar: calendar,
                    pricing: pricing
                )
            }
        }
        let fold = AggregateFoldState()
        // Include filesystem discovery, cache revision checks, account-alias preparation, and the
        // aggregate-cache hit in the same budget as the event fold. Otherwise a warm refresh could
        // do its active metadata work outside the measured allowance.
        let preflight = JSONLAccountingWorkPacer.shared.perform {
            let sourceFiles = readFile == nil ? Self.discoveredLedgers(paths: ledgerPaths()) : nil
            let sourceRevisions = sourceFiles.flatMap(Self.sourceRevisions(for:))
            let expectedFingerprint = CodexProxyUsageScanner.accountFingerprint(for: accountIdentityKey)
            let expectedAccountId = accountIdentityKey?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
            let aliases = identityAliases()
            let expectedAliasIds: Set<String> = {
                guard let expectedAccountId else { return [] }
                let needle = expectedAccountId.lowercased()
                return Set(aliases.compactMap { (key, value) in
                    value.lowercased() == needle ? key.lowercased() : nil
                })
            }()
            let aggregateKey = sourceFiles.map { _ in
                AggregateKey(
                    accountIdentityKey: expectedAccountId,
                    allowsUnscopedEvents: allowsUnscopedEvents,
                    daysBack: days,
                    since: since,
                    timeZoneIdentifier: calendar.timeZone.identifier,
                    aliases: aliases.map { "\($0.key.lowercased())=\($0.value.lowercased())" }.sorted(),
                    pricingIdentity: ObjectIdentifier(pricing)
                )
            }

            var cacheLookup = AggregateCacheLookup.miss
            var incrementalBase: AggregateCache?
            var skipCountsByPath: [String: Int] = [:]
            if let aggregateKey,
               let sourceRevisions,
               let aggregateCache,
               aggregateCache.key == aggregateKey {
                let futureEventBecameEligible = aggregateCache.nextFutureEventAt.map { now >= $0 } ?? false
                if aggregateCache.sources == sourceRevisions, !futureEventBecameEligible {
                    cacheLookup = .hit(aggregateCache.result)
                } else if !futureEventBecameEligible,
                          let skipCounts = Self.appendOnlySkipCounts(
                            previous: aggregateCache,
                            current: sourceRevisions
                          ) {
                    incrementalBase = aggregateCache
                    skipCountsByPath = skipCounts
                }
            }
            return ScanPreflight(
                sourceFiles: sourceFiles,
                sourceRevisions: sourceRevisions,
                aggregateKey: aggregateKey,
                cacheLookup: cacheLookup,
                incrementalBase: incrementalBase,
                skipCountsByPath: skipCountsByPath,
                expectedFingerprint: expectedFingerprint,
                expectedAccountId: expectedAccountId,
                expectedAliasIds: expectedAliasIds
            )
        }
        if case .hit(let cachedResult) = preflight.cacheLookup {
            return Task.isCancelled ? nil : cachedResult
        }
        let sourceFiles = preflight.sourceFiles
        let sourceRevisions = preflight.sourceRevisions
        let aggregateKey = preflight.aggregateKey
        let expectedFingerprint = preflight.expectedFingerprint
        let expectedAccountId = preflight.expectedAccountId
        let expectedAliasIds = preflight.expectedAliasIds
        let incrementalBase = preflight.incrementalBase
        let skipCountsByPath = preflight.skipCountsByPath

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
            guard event.timestamp <= now else {
                if fold.nextFutureEventAt.map({ event.timestamp < $0 }) ?? true {
                    fold.nextFutureEventAt = event.timestamp
                }
                return
            }

            let model = event.model
            // Same gateway skip as session logs: the OpenCode card owns these turns.
            //
            // Two signals, because the router serves one traffic class under two spellings. A model slug
            // prefixed `anthropic/opencode_go/` is the Claude/Codex log shape. The router itself stamps a
            // `provider`, and anything OpenCode serves — `opencode-go`, `opencode`, `opencode-free` — is
            // OpenCode traffic even when the slug carries no prefix at all (a router configured for a
            // custom free model emits `provider=opencode-free, model=opencode-free/space-bunny-free`).
            // Matching only the slug left those turns on the Codex card and invisible on OpenCode's.
            if Self.isOpenCodeServed(event) { return }
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
            guard let resolvedPricing = fold.pricingCache.resolve(
                model: model,
                at: event.timestamp,
                pricing: pricing
            ) else {
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
                pricingModel: resolvedPricing.pricingModel,
                input: input,
                cached: cached,
                output: output,
                reasoning: reasoning,
                total: total,
                isFast: isPriorityTier
            )
            let cost = CodexLogUsageScanner.cost(
                rates: resolvedPricing.rates,
                event: logEvent,
                model: resolvedPricing.pricingModel,
                fastTier: isPriorityTier,
                fastMultiplier: resolvedPricing.priorityMultiplier
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
                canonical: resolvedPricing.canonicalModel
            )
        }

        // Unit tests inject an in-memory ledger, but still use the production byte parser so the
        // assertions cover exactly the parser used by automatic indexing.
        if let readFile {
            for path in ledgerPaths() {
                guard !Task.isCancelled else { return nil }
                guard let contents = readFile(path) else { continue }
                for line in contents.split(whereSeparator: \.isNewline) {
                    guard !Task.isCancelled else { return nil }
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    let data = Data(trimmed.utf8)
                    guard let event = CodexRouterEventLineParser.parse(data[...]) else { continue }
                    visitOne(event)
                }
            }
        } else {
            guard let files = sourceFiles else { return nil }
            // Keep ~35 days of parsed rows in the append checkpoint so multi-account refreshes
            // share one parse without retaining the entire historical ledger in RAM.
            let retentionDays = max(days, 35)
            let emitSince = JSONLScanning.sinceDate(daysBack: retentionDays, now: now)
            // Ledger mtime is usually "now" (append-only). Use a deep since so the file is not
            // skipped by IncrementalJSONLScanner's mtime window; account filtering still uses `since`.
            let cacheSince = Date.distantPast
            var usedTailOnlyUpdate = false
            if let incrementalBase, let sourceRevisions {
                let changedSources = zip(incrementalBase.sources, sourceRevisions)
                    .filter { $0.0 != $0.1 }
                var deltas: [(path: String, events: [Event])] = []
                deltas.reserveCapacity(changedSources.count)
                var everyTailReadSucceeded = !changedSources.isEmpty
                for (previous, source) in changedSources {
                    guard let events = Self.parseAppendedEvents(
                        at: URL(fileURLWithPath: source.path),
                        from: previous,
                        emitSince: emitSince,
                        retentionDays: retentionDays
                    ) else {
                        everyTailReadSucceeded = false
                        break
                    }
                    deltas.append((source.path, events))
                }
                if everyTailReadSucceeded {
                    usedTailOnlyUpdate = true
                    fold.itemCountsByPath = incrementalBase.itemCountsByPath
                    for (path, events) in deltas {
                        fold.itemCountsByPath[path, default: 0] += events.count
                        JSONLAccountingWorkPacer.shared.forEach(events) { event in
                            guard event.timestamp >= since else { return }
                            visitOne(event)
                        }
                    }
                }
            }

            if !usedTailOnlyUpdate {
                let skipCounts = skipCountsByPath
                let ok = await scanner.foldItems(
                    from: files,
                    since: cacheSince,
                    cacheIdentity: Self.sharedCacheIdentity(retentionDays: retentionDays),
                    parseFile: { url in
                        Self.parseFileIncrementally(
                            at: url,
                            emitSince: emitSince,
                            retentionDays: retentionDays
                        )
                    },
                    visit: { event in
                        if event.timestamp >= since {
                            visitOne(event)
                        }
                    },
                    skipPrefixCounts: skipCounts,
                    fileCompleted: { path, itemCount in
                        fold.itemCountsByPath[path] = itemCount
                    }
                )
                if !ok { return nil }
            }
        }

        // A cancelled tail fold must not publish a partial aggregate for an unchanged source revision.
        guard !Task.isCancelled else { return nil }

        let result = JSONLAccountingWorkPacer.shared.perform { () -> LogUsageScan? in
            let deltaResult: LogUsageScan?
            if fold.sawRows {
                let built = fold.accumulator.build()
                deltaResult = built.series.daily.isEmpty && built.unknownModelsByDay.isEmpty ? nil : built
            } else {
                deltaResult = nil
            }
            return incrementalBase == nil
                ? deltaResult
                : DailyUsageAccumulator.merged([incrementalBase?.result, deltaResult])
        }
        if let aggregateKey, let sourceRevisions {
            JSONLAccountingWorkPacer.shared.perform {
                let currentFiles = Self.discoveredLedgers(paths: ledgerPaths())
                if let current = Self.sourceRevisions(for: currentFiles), current == sourceRevisions {
                    let nextFutureEventAt = [incrementalBase?.nextFutureEventAt, fold.nextFutureEventAt]
                        .compactMap { $0 }
                        .min()
                    aggregateCache = AggregateCache(
                        key: aggregateKey,
                        sources: sourceRevisions,
                        itemCountsByPath: fold.itemCountsByPath,
                        result: result,
                        nextFutureEventAt: nextFutureEventAt
                    )
                }
            }
        }
        return result
    }

    /// Escaping fold visits cannot capture `inout` accumulators; this tiny box owns them.
    private final class AggregateFoldState: @unchecked Sendable {
        var sawRows = false
        var accumulator = DailyUsageAccumulator()
        var itemCountsByPath: [String: Int] = [:]
        var nextFutureEventAt: Date?
        let pricingCache = RouterModelPricingCache()
    }

    /// Pricing resolution is stable for a slug within one scan, except the reserve fallback whose
    /// model changes on release dates. Memoizing the common path avoids rebuilding candidate arrays,
    /// running supplement alias regexes, formatting every timestamp, and resolving the same model for
    /// each of the ledger's many events.
    private final class RouterModelPricingCache: @unchecked Sendable {
        fileprivate struct Resolved: Sendable {
            var pricingModel: String
            var rates: ModelRates
            var canonicalModel: String
            var priorityMultiplier: Double
        }

        private struct FallbackKey: Hashable {
            var model: String
            var utcDay: Int
        }

        private enum ModelState {
            case priced(Resolved)
            case datedFallback
            case unpriced
        }

        private enum FallbackState {
            case priced(Resolved)
            case unpriced
        }

        private let lock = NSLock()
        private var modelStates: [String: ModelState] = [:]
        private var datedFallbacks: [FallbackKey: FallbackState] = [:]

        fileprivate func resolve(model: String, at timestamp: Date, pricing: ModelPricing) -> Resolved? {
            let state = lock.withLock { modelStates[model] }
            switch state {
            case .priced(let resolved):
                return resolved
            case .unpriced:
                return nil
            case .datedFallback:
                return resolveDatedFallback(model: model, at: timestamp, pricing: pricing)
            case nil:
                break
            }

            let candidates = CodexRouterUsageScanner.pricingModelCandidates(for: model)
            // Prefer an exact catalog key so gateway-tagged slugs group under the model they route to.
            let exactIdentity = pricing.canonicalKey(for: candidates)
            if let pricingModel = exactIdentity
                ?? candidates.first(where: { pricing.resolve(model: $0) != nil }),
               let rates = pricing.resolve(model: pricingModel) {
                let resolved = makeResolved(
                    model: model,
                    pricingModel: pricingModel,
                    rates: rates
                )
                lock.withLock { modelStates[model] = .priced(resolved) }
                return resolved
            }

            guard CodexLogUsageScanner.pricingFallbackModel(for: model, at: "") != nil else {
                lock.withLock { modelStates[model] = .unpriced }
                return nil
            }
            lock.withLock { modelStates[model] = .datedFallback }
            return resolveDatedFallback(model: model, at: timestamp, pricing: pricing)
        }

        private func resolveDatedFallback(
            model: String,
            at timestamp: Date,
            pricing: ModelPricing
        ) -> Resolved? {
            let key = FallbackKey(
                model: model,
                utcDay: Int(timestamp.timeIntervalSince1970 / 86_400)
            )
            if let state = lock.withLock({ datedFallbacks[key] }) {
                switch state {
                case .priced(let resolved): return resolved
                case .unpriced: return nil
                }
            }

            let timestampString = OpenUsageISO8601.string(from: timestamp)
            let fallbackModel = CodexLogUsageScanner.pricingFallbackModel(
                for: model,
                at: timestampString
            )
            let resolved = fallbackModel.flatMap { fallbackModel in
                pricing.resolve(model: fallbackModel).map { rates in
                    makeResolved(model: model, pricingModel: fallbackModel, rates: rates)
                }
            }
            lock.withLock {
                datedFallbacks[key] = resolved.map(FallbackState.priced) ?? .unpriced
            }
            return resolved
        }

        private func makeResolved(
            model: String,
            pricingModel: String,
            rates: ModelRates
        ) -> Resolved {
            Resolved(
                pricingModel: pricingModel,
                rates: rates,
                canonicalModel: GatewaySlug.identity(of: model, resolvedPricingModel: pricingModel),
                priorityMultiplier: CodexLogUsageScanner.codexPriorityMultiplier(
                    for: pricingModel,
                    rates: rates
                )
            )
        }
    }

    private static func sourceRevisions(for files: [JSONLScanning.DiscoveredFile]) -> [SourceRevision]? {
        var revisions: [SourceRevision] = []
        revisions.reserveCapacity(files.count)
        for file in files {
            let url = URL(fileURLWithPath: file.path)
            guard let revision = AppendOnlyFileProbe.revision(at: url),
                  revision.size == UInt64(max(0, file.size)),
                  let anchor = AppendOnlyFileProbe.anchor(at: url, endingAt: revision.size)
            else { return nil }
            revisions.append(SourceRevision(
                path: file.path,
                size: file.size,
                mtime: file.mtime,
                attributeMtime: file.attributeMtime,
                device: revision.device,
                inode: revision.inode,
                prefixAnchor: anchor
            ))
        }
        return revisions
    }

    /// Reuse the previous account fold only when every existing source is byte-prefix-stable and any
    /// changes are strict appends. A replacement, truncation, or removed/new path falls back to a full
    /// fold so no history can be silently retained or dropped.
    private static func appendOnlySkipCounts(
        previous: AggregateCache,
        current: [SourceRevision]
    ) -> [String: Int]? {
        guard previous.sources.count == current.count,
              previous.itemCountsByPath.count == previous.sources.count
        else { return nil }
        var grew = false
        var skipCounts: [String: Int] = [:]
        skipCounts.reserveCapacity(current.count)
        for (old, new) in zip(previous.sources, current) {
            guard old.path == new.path,
                  let itemCount = previous.itemCountsByPath[old.path]
            else { return nil }
            if old == new {
                skipCounts[old.path] = itemCount
                continue
            }
            guard new.size > old.size,
                  new.device == old.device,
                  new.inode == old.inode,
                  let prefix = AppendOnlyFileProbe.anchor(
                    at: URL(fileURLWithPath: new.path),
                    endingAt: UInt64(max(0, old.size))
                  ),
                  prefix == old.prefixAnchor
            else { return nil }
            grew = true
            skipCounts[old.path] = itemCount
        }
        return grew ? skipCounts : nil
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
        emitSince: Date,
        retentionDays: Int
    ) -> [Event]? {
        guard acquireSharedTailCacheLock() else { return nil }
        defer { sharedTailCacheLock.unlock() }
        let key = sharedTailCacheKey(for: url, retentionDays: retentionDays)
        let currentRevision = AppendOnlyFileProbe.revision(at: url)

        if let currentRevision,
           let cached = sharedTailCache.entry(for: key),
           let cachedEmitSince = cached.parserState.emitSince,
           cachedEmitSince <= emitSince,
           currentRevision.device == cached.revision.device,
           currentRevision.inode == cached.revision.inode,
           currentRevision.size == cached.offset,
           AppendOnlyFileProbe.anchor(at: url, endingAt: cached.offset) == cached.anchor
        {
            if cached.itemsAvailable {
                let recent = Self.recentEvents(cached.items, since: emitSince)
                return Task.isCancelled ? nil : recent
            }
            // Checkpoint valid but items were unloaded (memory pressure). Must full-reparse —
            // returning [] would silently drop history. Routine refresh paths no longer unload
            // this cache; pressure unload still can.
            return fullParseAndCheckpoint(
                at: url,
                emitSince: emitSince,
                key: key
            )
        }

        if let currentRevision,
           let cached = sharedTailCache.entry(for: key),
           cached.itemsAvailable,
           let cachedEmitSince = cached.parserState.emitSince,
           cachedEmitSince <= emitSince,
           currentRevision.device == cached.revision.device,
           currentRevision.inode == cached.revision.inode,
           currentRevision.size > cached.offset,
           AppendOnlyFileProbe.anchor(at: url, endingAt: cached.offset) == cached.anchor
        {
            var collected: [Event] = []
            var timestampCache = CodexRouterEventLineParser.TimestampCache()
            var read = JSONLFileReader.readLines(
                at: url,
                chunkSize: 64 * 1024,
                startOffset: cached.offset,
                initialCarry: cached.partialLine,
                discardingOversizedLine: cached.isDiscardingOversizedLine,
                deliverFinalPartial: false
            ) { line in
                if let event = parseLine(line, timestampCache: &timestampCache), event.timestamp >= emitSince {
                    collected.append(event)
                }
            }
            guard read.succeeded else { return nil }
            guard AppendOnlyFileProbe.anchor(at: url, endingAt: cached.offset) == cached.anchor else {
                return fullParseAndCheckpoint(
                    at: url,
                    emitSince: emitSince,
                    key: key
                )
            }

            // If a final partial line is itself a complete JSON object, accept it (writers that omit
            // the trailing newline on the last record).
            if !read.finalPartial.isEmpty,
               let event = parseLine(read.finalPartial[...], timestampCache: &timestampCache),
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
                var merged = Self.recentEvents(cached.items, since: emitSince)
                guard !Task.isCancelled else { return nil }
                merged.append(contentsOf: collected)
                sharedTailCache.store(
                    AppendOnlyFileTailCache<Event, ParserCheckpoint>.Entry(
                        revision: after,
                        offset: newOffset,
                        anchor: anchor,
                        partialLine: read.finalPartial,
                        isDiscardingOversizedLine: read.isDiscardingOversizedLine,
                        parserState: ParserCheckpoint(emitSince: emitSince),
                        items: merged
                    ),
                    for: key,
                    parseKind: .tail,
                    bytesRead: read.statistics.bytesRead
                )
                return merged
            }
            return fullParseAndCheckpoint(
                at: url,
                emitSince: emitSince,
                key: key
            )
        }

        return fullParseAndCheckpoint(
            at: url,
            emitSince: emitSince,
            key: key
        )
    }

    /// Parse an append for the resident account-fold cache without rebuilding the full historical
    /// `[Event]` array. The aggregate cache already owns the old fold; this updates only the byte
    /// checkpoint and hands back the newly appended rows.
    nonisolated private static func parseAppendedEvents(
        at url: URL,
        from previousSource: SourceRevision,
        emitSince: Date,
        retentionDays: Int
    ) -> [Event]? {
        guard acquireSharedTailCacheLock() else { return nil }
        defer { sharedTailCacheLock.unlock() }
        let key = sharedTailCacheKey(for: url, retentionDays: retentionDays)
        guard let currentRevision = AppendOnlyFileProbe.revision(at: url),
              let cached = sharedTailCache.entry(for: key)
        else { return nil }
        let previousRevision = AppendOnlyFileRevision(
            device: previousSource.device,
            inode: previousSource.inode,
            size: UInt64(max(0, previousSource.size))
        )

        // A different account scanner may have already consumed this same append. Reuse its short
        // delta while it is still retained rather than forcing that account to replay full history.
        if cached.revision.device == currentRevision.device,
           cached.revision.inode == currentRevision.inode,
           cached.revision.size == currentRevision.size,
           cached.offset == UInt64(currentRevision.size),
           cached.appendedItemsAvailable,
           cached.appendedFromRevision == previousRevision,
           cached.appendedFromAnchor == previousSource.prefixAnchor,
           cached.parserState.emitSince == emitSince,
           AppendOnlyFileProbe.anchor(at: url, endingAt: previousRevision.size) == previousSource.prefixAnchor,
           AppendOnlyFileProbe.anchor(at: url, endingAt: cached.offset) == cached.anchor {
            return cached.appendedItems
        }

        guard cached.revision == previousRevision,
              currentRevision.device == cached.revision.device,
              currentRevision.inode == cached.revision.inode,
              currentRevision.size > cached.offset,
              AppendOnlyFileProbe.anchor(at: url, endingAt: previousRevision.size) == previousSource.prefixAnchor,
              AppendOnlyFileProbe.anchor(at: url, endingAt: cached.offset) == cached.anchor
        else { return nil }

        var collected: [Event] = []
        var timestampCache = CodexRouterEventLineParser.TimestampCache()
        var read = JSONLFileReader.readLines(
            at: url,
            chunkSize: 64 * 1024,
            startOffset: cached.offset,
            initialCarry: cached.partialLine,
            discardingOversizedLine: cached.isDiscardingOversizedLine,
            deliverFinalPartial: false
        ) { line in
            if let event = parseLine(line, timestampCache: &timestampCache), event.timestamp >= emitSince {
                collected.append(event)
            }
        }
        guard read.succeeded,
              AppendOnlyFileProbe.anchor(at: url, endingAt: cached.offset) == cached.anchor
        else { return nil }

        // Match the full reader: a complete JSON object at EOF counts even without a newline.
        if !read.finalPartial.isEmpty,
           let event = parseLine(read.finalPartial[...], timestampCache: &timestampCache),
           event.timestamp >= emitSince {
            collected.append(event)
            read.finalPartial = Data()
        }

        let newOffset = cached.offset + UInt64(read.statistics.bytesRead)
        guard let after = AppendOnlyFileProbe.revision(at: url),
              after.device == currentRevision.device,
              after.inode == currentRevision.inode,
              after.size >= newOffset,
              let anchor = AppendOnlyFileProbe.anchor(at: url, endingAt: newOffset)
        else { return nil }

        sharedTailCache.store(
            AppendOnlyFileTailCache<Event, ParserCheckpoint>.Entry(
                revision: after,
                offset: newOffset,
                anchor: anchor,
                partialLine: read.finalPartial,
                isDiscardingOversizedLine: read.isDiscardingOversizedLine,
                parserState: ParserCheckpoint(emitSince: emitSince),
                items: [],
                appendedFromRevision: previousRevision,
                appendedFromAnchor: previousSource.prefixAnchor,
                appendedItems: collected,
                appendedItemsAvailable: true
            ),
            for: key,
            parseKind: .tail,
            bytesRead: read.statistics.bytesRead,
            retainItems: false
        )
        return collected
    }

    nonisolated private static func acquireSharedTailCacheLock() -> Bool {
        while !sharedTailCacheLock.try() {
            guard !Task.isCancelled else { return false }
            Thread.sleep(forTimeInterval: 0.005)
        }
        guard !Task.isCancelled else {
            sharedTailCacheLock.unlock()
            return false
        }
        return true
    }

    nonisolated private static func fullParseAndCheckpoint(
        at url: URL,
        emitSince: Date,
        key: String
    ) -> [Event]? {
        var collected: [Event] = []
        var timestampCache = CodexRouterEventLineParser.TimestampCache()
        var read = JSONLFileReader.readLines(
            at: url,
            chunkSize: 64 * 1024,
            deliverFinalPartial: false
        ) { line in
            if let event = parseLine(line, timestampCache: &timestampCache), event.timestamp >= emitSince {
                collected.append(event)
            }
        }
        guard read.succeeded else { return nil }
        if !read.finalPartial.isEmpty,
           let event = parseLine(read.finalPartial[...], timestampCache: &timestampCache),
           event.timestamp >= emitSince {
            collected.append(event)
            read.finalPartial = Data()
        }
        let offset = UInt64(read.statistics.bytesRead)
        if let revision = AppendOnlyFileProbe.revision(at: url),
           revision.size >= offset,
           let anchor = AppendOnlyFileProbe.anchor(at: url, endingAt: offset) {
            sharedTailCache.store(
                AppendOnlyFileTailCache<Event, ParserCheckpoint>.Entry(
                    revision: revision,
                    offset: offset,
                    anchor: anchor,
                    partialLine: read.finalPartial,
                    isDiscardingOversizedLine: read.isDiscardingOversizedLine,
                    parserState: ParserCheckpoint(emitSince: emitSince),
                    items: collected
                ),
                for: key,
                parseKind: .full,
                bytesRead: read.statistics.bytesRead
            )
        }
        return collected
    }

    nonisolated private static func parseLine(
        _ line: Data.SubSequence,
        timestampCache: inout CodexRouterEventLineParser.TimestampCache
    ) -> Event? {
        CodexRouterEventLineParser.parse(line, timestampCache: &timestampCache)
    }

    nonisolated private static func recentEvents(_ events: [Event], since: Date) -> [Event] {
        var recent: [Event] = []
        recent.reserveCapacity(events.count)
        JSONLAccountingWorkPacer.shared.forEach(events) { event in
            if event.timestamp >= since { recent.append(event) }
        }
        return recent
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

    /// True when the router metered this turn against an OpenCode-hosted account.
    static func isOpenCodeServed(_ event: Event) -> Bool {
        isOpenCodeProvider(event.provider) || OpenCodeUsageScanner.isHostedGatewayModel(event.model)
    }

    /// Same test for a raw ledger field, so the OpenCode fold can select its own rows.
    static func isOpenCodeProvider(_ provider: String?) -> Bool {
        guard let provider = provider?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty else { return false }
        return provider.lowercased().hasPrefix("opencode")
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

    /// Stream the ledger into a priced daily aggregate. Unchanged inode+size+mtime returns the
    /// saved fold without opening the file. Growth reads only the appended bytes. Rotate/truncate
    /// rebuilds once. Events are not retained.
    private func scanPersistentAggregate(
        accountIdentityKey: String?,
        allowsUnscopedEvents: Bool,
        days: Int,
        since: Date,
        now: Date,
        calendar: Calendar,
        pricing: ModelPricing
    ) async -> LogUsageScan? {
        let expectedFingerprint = CodexProxyUsageScanner.accountFingerprint(for: accountIdentityKey)
        let expectedAccountId = accountIdentityKey?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        let aliases = identityAliases()
        let expectedAliasIds: Set<String> = {
            guard let expectedAccountId else { return [] }
            let needle = expectedAccountId.lowercased()
            return Set(aliases.compactMap { key, value in
                value.lowercased() == needle ? key.lowercased() : nil
            })
        }()
        let index = CodexRouterAggregateIndex.shared
        let paths = ledgerPaths()
        let key = CodexRouterAggregateIndex.Key(
            account: expectedAccountId ?? "",
            allowsUnscopedEvents: allowsUnscopedEvents,
            days: days,
            since: since.timeIntervalSince1970,
            timeZoneIdentifier: calendar.timeZone.identifier,
            aliases: aliases.map { "\($0.key.lowercased())=\($0.value.lowercased())" }.sorted(),
            pricingToken: pricing.aggregateCacheToken,
            sourcePaths: Array(Set(paths.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path })).sorted()
        )
        let lookup = index.lookup(key: key, paths: paths, now: now)
        let prior: CodexRouterAggregateIndex.Record?
        switch lookup {
        case .hit(let cached):
            return Task.isCancelled ? nil : cached
        case .append(let record):
            prior = record
        case .rebuild:
            prior = nil
        }

        let fold = AggregateFoldState()
        let visit: (Event) -> Void = { event in
            guard Self.isSuccessfulStatus(event.status) else { return }
            guard Self.belongsToAccount(
                event,
                expectedFingerprint: expectedFingerprint,
                expectedAccountId: expectedAccountId,
                expectedAliasIds: expectedAliasIds,
                allowsUnscopedEvents: allowsUnscopedEvents
            ) else { return }
            guard event.timestamp >= since else { return }
            guard event.timestamp <= now else {
                if fold.nextFutureEventAt.map({ event.timestamp < $0 }) ?? true {
                    fold.nextFutureEventAt = event.timestamp
                }
                return
            }
            if Self.isOpenCodeServed(event) { return }
            if OpenCodeUsageScanner.isHostedGatewayModel(event.model) { return }
            let input = event.inputTokens
            let cached = min(event.cachedInputTokens, input)
            let output = event.outputTokens
            let reasoning = event.reasoningTokens
            let total = event.totalTokens ?? {
                let result = input.addingReportingOverflow(output)
                return result.overflow ? input : result.partialValue
            }()
            guard total > 0 else { return }
            fold.sawRows = true
            let day = DailyUsageAccumulator.dayKey(from: event.timestamp, calendar: calendar)
            guard let resolvedPricing = fold.pricingCache.resolve(
                model: event.model,
                at: event.timestamp,
                pricing: pricing
            ) else {
                fold.accumulator.addUnknownModel(day: day, model: event.model)
                return
            }
            let isPriorityTier = event.serviceTier == "fast" || event.serviceTier == "priority"
            let logEvent = CodexLogUsageScanner.Event(
                timestamp: event.timestamp,
                model: event.model,
                pricingModel: resolvedPricing.pricingModel,
                input: input,
                cached: cached,
                output: output,
                reasoning: reasoning,
                total: total,
                isFast: isPriorityTier
            )
            let cost = CodexLogUsageScanner.cost(
                rates: resolvedPricing.rates,
                event: logEvent,
                model: resolvedPricing.pricingModel,
                fastTier: isPriorityTier,
                fastMultiplier: resolvedPricing.priorityMultiplier
            )
            fold.accumulator.add(
                day: day,
                tokens: total,
                cost: cost,
                model: event.model,
                canonical: resolvedPricing.canonicalModel
            )
        }

        let priorByPath = Dictionary(uniqueKeysWithValues: (prior?.files ?? []).map { ($0.path, $0) })
        var checkpoints: [CodexRouterAggregateIndex.FileCheckpoint] = []
        let live = CodexRouterAggregateIndex.stats(for: paths)
        for file in live {
            guard !Task.isCancelled else { return nil }
            let url = URL(fileURLWithPath: file.path)
            let saved = priorByPath[file.path]
            let tail = saved != nil && file.size > (saved?.offset ?? 0)
            if let saved, !tail {
                checkpoints.append(saved)
                continue
            }
            let start = tail ? (saved?.offset ?? 0) : 0
            var timestampCache = CodexRouterEventLineParser.TimestampCache()
            var read = JSONLFileReader.readLines(
                at: url,
                chunkSize: 256 * 1024,
                startOffset: start,
                initialCarry: tail ? (saved?.partial ?? Data()) : Data(),
                discardingOversizedLine: tail ? (saved?.discardingOversizedLine ?? false) : false,
                deliverFinalPartial: false
            ) { line in
                if let event = CodexRouterEventLineParser.parse(line, timestampCache: &timestampCache) {
                    visit(event)
                }
            }
            guard read.succeeded else { return nil }
            if !read.finalPartial.isEmpty,
               let event = CodexRouterEventLineParser.parse(read.finalPartial[...], timestampCache: &timestampCache) {
                visit(event)
                read.finalPartial = Data()
            }
            let newOffset = start + UInt64(max(0, read.statistics.bytesRead))
            guard let checkpoint = index.checkpoint(
                path: file.path,
                offset: newOffset,
                partial: read.finalPartial,
                discardingOversizedLine: read.isDiscardingOversizedLine
            ), checkpoint.device == file.device, checkpoint.inode == file.inode else { return nil }
            // A rotation during the read must never attach old events to the replacement's inode.

            checkpoints.append(checkpoint)
            index.noteParse(path: file.path, full: !tail, bytes: read.statistics.bytesRead)
        }
        guard !Task.isCancelled else { return nil }

        let delta: LogUsageScan?
        if fold.sawRows {
            let built = fold.accumulator.build()
            delta = built.series.daily.isEmpty && built.unknownModelsByDay.isEmpty ? nil : built
        } else {
            delta = nil
        }
        let result = prior == nil ? delta : DailyUsageAccumulator.merged([prior?.result, delta])
        let nextFuture = [prior?.nextFutureEventAt, fold.nextFutureEventAt].compactMap { $0 }.min()
        index.save(CodexRouterAggregateIndex.Record(
            schema: CodexRouterAggregateIndex.schema,
            key: key,
            files: checkpoints,
            result: result,
            nextFutureEventAt: nextFuture,
            complete: true
        ))
        return result
    }

}
