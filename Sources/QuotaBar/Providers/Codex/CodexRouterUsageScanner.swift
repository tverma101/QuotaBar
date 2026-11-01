import Darwin
import Foundation

enum CodexRouterUsageScanResult: Sendable {
    case complete(LogUsageScan?)
    case incomplete
}

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
    private let identityAliasSnapshot: @Sendable () -> IdentityAliasSnapshot
    /// The built-in ledger is optional until CodexRouter creates it. A user-configured path is an
    /// expected source and an unreadable or missing file must preserve the last-good combined chart.
    private let optionalDefaultLedgerPath: String?
    private let scanner: IncrementalJSONLScanner<Event>
    /// Production scans fold into the on-disk aggregate. Tests that inject a scanner keep the
    /// event-retaining path so the benchmark can still measure that cache.
    private let usesInjectedScanner: Bool
    private let beforeAggregateValidationForTesting: (@Sendable () -> Void)?

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
        /// If the system clock moves back before an already included event, rebuild instead of
        /// serving a cached current-day total that now lies in the future.
        var latestIncludedEventAt: Date?
    }

    private enum AggregateCacheLookup {
        case miss
        case hit(LogUsageScan?)
    }

    private struct ScanPreflight {
        var sourceFiles: [JSONLScanning.DiscoveredFile]?
        var discoveryComplete: Bool
        var sourceRevisions: [SourceRevision]?
        var aggregateKey: AggregateKey?
        var cacheLookup: AggregateCacheLookup
        var incrementalBase: AggregateCache?
        var skipCountsByPath: [String: Int]
        var expectedFingerprint: String?
        var expectedAccountId: String?
        var expectedAliasIds: Set<String>
        var identityAliasSnapshot: IdentityAliasSnapshot
    }

    private func sourcesAndAliasesStillMatch(_ preflight: ScanPreflight) -> Bool {
        guard let expectedFiles = preflight.sourceFiles else { return true }
        let currentDiscovery = Self.discoveredLedgers(
            paths: ledgerPaths(),
            optionalDefaultPath: optionalDefaultLedgerPath
        )
        guard currentDiscovery.complete,
              Set(currentDiscovery.files.map(\.path)) == Set(expectedFiles.map(\.path)),
              let expectedRevisions = preflight.sourceRevisions,
              let currentRevisions = Self.sourceRevisions(for: currentDiscovery.files),
              currentRevisions == expectedRevisions
        else { return false }
        guard expectedFiles.isEmpty else {
            let currentAliases = identityAliasSnapshot()
            return currentAliases.isComplete
                && currentAliases.aliases == preflight.identityAliasSnapshot.aliases
        }
        return true
    }

    private struct LedgerDiscovery {
        var files: [JSONLScanning.DiscoveredFile]
        var complete: Bool
    }

    private struct IdentityAliasSnapshot: Sendable {
        var aliases: [String: String]
        var isComplete: Bool
    }

    private func identityAliasesStillMatch(
        _ expected: IdentityAliasSnapshot,
        hasLedgerSources: Bool
    ) -> Bool {
        guard hasLedgerSources else { return true }
        let current = identityAliasSnapshot()
        return current.isComplete && current.aliases == expected.aliases
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
        persistence: JSONLScanCachePersistence(namespace: "codex-router", schemaVersion: 7)
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
        incrementalScanner: IncrementalJSONLScanner<Event>? = nil,
        beforeAggregateValidationForTesting: (@Sendable () -> Void)? = nil
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
        let configuredPaths = Self.configuredLedgerPaths(environment: environment)
        self.ledgerPaths = ledgerPaths ?? {
            Self.defaultLedgerPaths(environment: environment, homeDirectory: homeDirectory())
        }
        if ledgerPaths == nil, configuredPaths.isEmpty {
            self.optionalDefaultLedgerPath = homeDirectory()
                .appendingPathComponent(".codex/codex-router/usage-events.jsonl")
                .path
        } else {
            self.optionalDefaultLedgerPath = nil
        }
        self.readFile = readFile
        if let identityAliases {
            self.identityAliasSnapshot = {
                IdentityAliasSnapshot(aliases: identityAliases(), isComplete: true)
            }
        } else {
            self.identityAliasSnapshot = {
                Self.loadPoolIdentityAliasSnapshot(environment: environment, homeDirectory: homeDirectory())
            }
        }
        self.usesInjectedScanner = incrementalScanner != nil
        self.beforeAggregateValidationForTesting = beforeAggregateValidationForTesting
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
        switch await scanResult(
            accountIdentityKey: accountIdentityKey,
            allowsUnscopedEvents: allowsUnscopedEvents,
            daysBack: daysBack,
            now: now,
            pricing: pricing
        ) {
        case .complete(let scan): return scan
        case .incomplete: return nil
        }
    }

    /// Completeness-aware scan for callers that merge router usage with other local sources.
    /// A configured ledger read that fails is distinct from an absent or empty optional ledger.
    func scanResult(
        accountIdentityKey: String?,
        allowsUnscopedEvents: Bool,
        daysBack: Int = UsageHistoryWindow.previousDays,
        now: Date = Date(),
        pricing: ModelPricing
    ) async -> CodexRouterUsageScanResult {
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
            let discovery = readFile == nil
                ? Self.discoveredLedgers(paths: ledgerPaths(), optionalDefaultPath: optionalDefaultLedgerPath)
                : nil
            let sourceFiles = discovery?.files
            let sourceRevisions = sourceFiles.flatMap(Self.sourceRevisions(for:))
            let sourceRevisionComplete = sourceFiles.map { $0.isEmpty || sourceRevisions != nil } ?? true
            let expectedFingerprint = CodexProxyUsageScanner.accountFingerprint(for: accountIdentityKey)
            let expectedAccountId = accountIdentityKey?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
            let aliasSnapshot = identityAliasSnapshot()
            let aliases = aliasSnapshot.aliases
            let aliasMetadataComplete = (sourceFiles?.isEmpty ?? true) || aliasSnapshot.isComplete
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
                let clockMovedBeforeIncludedEvent = aggregateCache.latestIncludedEventAt.map { $0 > now } ?? false
                if aggregateCache.sources == sourceRevisions,
                   !futureEventBecameEligible,
                   !clockMovedBeforeIncludedEvent {
                    cacheLookup = .hit(aggregateCache.result)
                } else if !futureEventBecameEligible, !clockMovedBeforeIncludedEvent,
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
                discoveryComplete: (discovery?.complete ?? true)
                    && sourceRevisionComplete
                    && aliasMetadataComplete,
                sourceRevisions: sourceRevisions,
                aggregateKey: aggregateKey,
                cacheLookup: cacheLookup,
                incrementalBase: incrementalBase,
                skipCountsByPath: skipCountsByPath,
                expectedFingerprint: expectedFingerprint,
                expectedAccountId: expectedAccountId,
                expectedAliasIds: expectedAliasIds,
                identityAliasSnapshot: aliasSnapshot
            )
        }
        guard preflight.discoveryComplete else { return .incomplete }
        if case .hit(let cachedResult) = preflight.cacheLookup {
            guard !Task.isCancelled,
                  sourcesAndAliasesStillMatch(preflight)
            else { return .incomplete }
            return .complete(cachedResult)
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
            if event.isMalformedRouterEvent {
                if Self.malformedRouterEventAffectsAccount(
                    event,
                    expectedFingerprint: expectedFingerprint,
                    expectedAccountId: expectedAccountId,
                    expectedAliasIds: expectedAliasIds,
                    allowsUnscopedEvents: allowsUnscopedEvents
                ) {
                    fold.sawInvalidUsageRow = true
                }
                return
            }
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
            let hasCompleteCostBreakdown = event.hasCompleteMeasuredCostBreakdown
            // OpenAI/Codex `total_tokens` is input+output; reasoning is a subset of output. Never
            // add reasoning on top when totalTokens is absent — that double-counted tokens.
            guard let total = event.measuredTokenTotal else {
                if event.hasNoMeasuredUsageFields {
                    fold.sawRows = true
                    fold.accumulator.markUnmeasuredUsage(day: DailyUsageAccumulator.dayKey(from: event.timestamp, calendar: calendar))
                    return
                }
                fold.sawInvalidUsageRow = true
                return
            }
            guard total > 0 else { return }
            if fold.latestIncludedEventAt.map({ event.timestamp > $0 }) ?? true {
                fold.latestIncludedEventAt = event.timestamp
            }

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
                // Count the tokens with a dashed cost so an unrevealed codename stays visible.
                fold.accumulator.add(
                    day: day,
                    tokens: total,
                    cost: nil,
                    model: model,
                    canonical: model,
                    tokenCountSaturated: event.tokenCountSaturated == true
                )
                return
            }
            // Match session-log rules: only priority/fast tiers apply the Codex multiplier.
            // Router rows omit serviceTier today (and Codex config often uses `default`), so
            // standard API rates apply unless the ledger stamps priority/fast.
            let isPriorityTier = event.serviceTier == "fast" || event.serviceTier == "priority"
            let serviceTierMultiplier = CodexLogUsageScanner.codexServiceTierMultiplier(
                for: resolvedPricing.pricingModel,
                serviceTier: event.serviceTier
            )
            let appliesServiceTier = serviceTierMultiplier != nil
            let logEvent = CodexLogUsageScanner.Event(
                timestamp: event.timestamp,
                model: model,
                pricingModel: resolvedPricing.pricingModel,
                input: input,
                cached: cached,
                output: output,
                reasoning: reasoning,
                total: total,
                isFast: isPriorityTier || appliesServiceTier,
                serviceTier: event.serviceTier
            )
            // Public-API-rate comparison: plain catalog rates, no router priority/fast adjustments.
            let apiEstimate = resolvedPricing.rates.costDollars(
                for: TokenBreakdown(
                    input: max(0, input - cached),
                    cacheRead: cached,
                    output: output
                )
            )
            fold.accumulator.recordApiEstimate(
                day: day,
                cost: hasCompleteCostBreakdown ? apiEstimate : nil,
                tokens: total
            )
            let cost = CodexLogUsageScanner.cost(
                rates: resolvedPricing.rates,
                event: logEvent,
                model: resolvedPricing.pricingModel,
                fastTier: isPriorityTier || appliesServiceTier,
                fastMultiplier: serviceTierMultiplier ?? resolvedPricing.priorityMultiplier
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
                canonical: resolvedPricing.canonicalModel,
                costIsComplete: hasCompleteCostBreakdown,
                tokenCountSaturated: event.tokenCountSaturated == true
            )
            if !hasCompleteCostBreakdown {
                fold.accumulator.markCostIncomplete(
                    day: day,
                    model: model,
                    canonical: resolvedPricing.canonicalModel
                )
            }
        }

        // Unit tests inject an in-memory ledger, but still use the production byte parser so the
        // assertions cover exactly the parser used by automatic indexing.
        if let readFile {
            var malformedEventLine = false
            for path in ledgerPaths() {
                guard !Task.isCancelled else { return .incomplete }
                guard let contents = readFile(path) else { continue }
                for line in contents.split(whereSeparator: \.isNewline) {
                    guard !Task.isCancelled else { return .incomplete }
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    let data = Data(trimmed.utf8)
                    var timestampCache = CodexRouterEventLineParser.TimestampCache()
                    switch CodexRouterEventLineParser.parseResult(data[...], timestampCache: &timestampCache) {
                    case .event(let event): visitOne(event)
                    case .malformedEvent(let event): visitOne(event)
                    case .irrelevant: break
                    case .malformed: malformedEventLine = true
                    }
                }
            }
            guard !malformedEventLine else { return .incomplete }
        } else {
            guard let files = sourceFiles else { return .incomplete }
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
                            guard event.isMalformedRouterEvent || event.timestamp >= since else { return }
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
                        if event.isMalformedRouterEvent || event.timestamp >= since {
                            visitOne(event)
                        }
                    },
                    skipPrefixCounts: skipCounts,
                    fileCompleted: { path, itemCount in
                        fold.itemCountsByPath[path] = itemCount
                    }
                )
                if !ok { return .incomplete }
            }
        }

        // A cancelled tail fold must not publish a partial aggregate for an unchanged source revision.
        guard !Task.isCancelled, !fold.sawInvalidUsageRow else { return .incomplete }

        let result = JSONLAccountingWorkPacer.shared.perform { () -> LogUsageScan? in
            let deltaResult: LogUsageScan?
            if fold.sawRows {
                let built = fold.accumulator.build()
                deltaResult = built.series.daily.isEmpty && built.unknownModelsByDay.isEmpty
                    && built.unmeasuredUsageDays?.isEmpty != false ? nil : built
            } else {
                deltaResult = nil
            }
            return incrementalBase == nil
                ? deltaResult
                : DailyUsageAccumulator.merged([incrementalBase?.result, deltaResult])
        }
        if let aggregateKey, let sourceRevisions {
            let sourceStayedStable = JSONLAccountingWorkPacer.shared.perform { () -> Bool in
                guard sourcesAndAliasesStillMatch(preflight) else { return false }
                let nextFutureEventAt = [incrementalBase?.nextFutureEventAt, fold.nextFutureEventAt]
                    .compactMap { $0 }
                    .min()
                let latestIncludedEventAt = [incrementalBase?.latestIncludedEventAt, fold.latestIncludedEventAt]
                    .compactMap { $0 }
                    .max()
                aggregateCache = AggregateCache(
                    key: aggregateKey,
                    sources: sourceRevisions,
                    itemCountsByPath: fold.itemCountsByPath,
                    result: result,
                    nextFutureEventAt: nextFutureEventAt,
                    latestIncludedEventAt: latestIncludedEventAt
                )
                return true
            }
            guard sourceStayedStable else { return .incomplete }
        }
        return .complete(result)
    }

    /// Escaping fold visits cannot capture `inout` accumulators; this tiny box owns them.
    private final class AggregateFoldState: @unchecked Sendable {
        var sawRows = false
        var sawInvalidUsageRow = false
        var accumulator = DailyUsageAccumulator()
        var itemCountsByPath: [String: Int] = [:]
        var nextFutureEventAt: Date?
        var latestIncludedEventAt: Date?
        let pricingCache = RouterModelPricingCache()
    }

    /// Pricing resolution is stable for a slug within one scan, except the reserve fallback whose
    /// model changes on release dates. Memoizing the common path avoids rebuilding candidate arrays,
    /// running supplement alias regexes, formatting every timestamp, and resolving the same model for
    /// each of the ledger's many events.
    private final class RouterModelPricingCache: @unchecked Sendable {
        private struct FallbackKey: Hashable {
            var model: String
            var utcDay: Int
        }

        private enum ModelState {
            case priced(CodexRouterPricingResolution)
            case datedFallback
            case unpriced
        }

        private enum FallbackState {
            case priced(CodexRouterPricingResolution)
            case unpriced
        }

        private let lock = NSLock()
        private var modelStates: [String: ModelState] = [:]
        private var datedFallbacks: [FallbackKey: FallbackState] = [:]
        /// Every resolution this fold priced, so a later catalogue change can be checked against
        /// what the fold actually used instead of against the whole catalogue.
        private var dependencies: [String: CodexRouterPricingDependency] = [:]

        fileprivate func resolve(
            model: String,
            at timestamp: Date,
            pricing: ModelPricing
        ) -> CodexRouterPricingResolution? {
            let state = lock.withLock { modelStates[model] }
            switch state {
            case .priced(let resolved):
                // The dependency was recorded when the state was created.
                return resolved
            case .unpriced:
                return nil
            case .datedFallback:
                return resolveDatedFallback(model: model, at: timestamp, pricing: pricing)
            case nil:
                break
            }

            if let resolved = CodexRouterPricingResolver.resolveCatalog(model: model, pricing: pricing) {
                store(CodexRouterPricingDependency(model: model, utcDay: nil, resolution: resolved)) {
                    self.modelStates[model] = .priced(resolved)
                }
                return resolved
            }

            guard CodexRouterPricingResolver.isDatedFallback(model: model) else {
                store(CodexRouterPricingDependency(model: model, utcDay: nil, resolution: nil)) {
                    self.modelStates[model] = .unpriced
                }
                return nil
            }
            // A dated reserve slug is recorded per UTC day, not per model: the day decides which
            // model prices it.
            lock.withLock { modelStates[model] = .datedFallback }
            return resolveDatedFallback(model: model, at: timestamp, pricing: pricing)
        }

        private func resolveDatedFallback(
            model: String,
            at timestamp: Date,
            pricing: ModelPricing
        ) -> CodexRouterPricingResolution? {
            let key = FallbackKey(
                model: model,
                utcDay: Int(timestamp.timeIntervalSince1970 / 86_400)
            )
            if let state = lock.withLock({ datedFallbacks[key] }) {
                switch state {
                case .priced(let resolved):
                    // The dependency was recorded when the day was resolved.
                    return resolved
                case .unpriced:
                    return nil
                }
            }

            let timestampString = OpenUsageISO8601.string(from: timestamp)
            let utcDay = String(timestampString.prefix(10))
            let resolved = CodexRouterPricingResolver.resolveDatedFallback(
                model: model,
                utcDay: utcDay,
                pricing: pricing
            )
            store(CodexRouterPricingDependency(model: model, utcDay: utcDay, resolution: resolved)) {
                self.datedFallbacks[key] = resolved.map { FallbackState.priced($0) } ?? .unpriced
            }
            return resolved
        }

        /// Record what the fold priced and update the memo in one step, so the hot path stays a
        /// single dictionary read per event.
        private func store(
            _ dependency: CodexRouterPricingDependency,
            _ update: () -> Void
        ) {
            lock.withLock {
                dependencies[dependency.key] = dependency
                update()
            }
        }

        /// The pricing resolutions this fold depended on.
        fileprivate func dependencySnapshot() -> CodexRouterPricingDependencySet {
            let recorded = lock.withLock { Array(dependencies.values) }
            return CodexRouterPricingDependencySet(
                dependencies: recorded.sorted { $0.key < $1.key }
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

    /// Snapshot folds may finish while the writer is appending. Preserve the completed prefix,
    /// checkpoint its byte offset, and leave new bytes for the next tail read. Requiring identical
    /// final size/mtime discarded every cold fold of a busy ledger and repeatedly reparsed it.
    private static func sourcesAreUnchangedOrAppended(
        _ before: [SourceRevision], _ after: [SourceRevision]
    ) -> Bool {
        guard before.count == after.count else { return false }
        return zip(before, after).allSatisfy { old, new in
            if old == new { return true }
            guard old.path == new.path, old.device == new.device, old.inode == new.inode,
                  new.size > old.size,
                  let anchor = AppendOnlyFileProbe.anchor(
                    at: URL(fileURLWithPath: old.path), endingAt: UInt64(old.size)
                  )
            else { return false }
            return anchor == old.prefixAnchor
        }
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

    private static func configuredLedgerPaths(environment: EnvironmentReading) -> [String] {
        let configured = [
            environment.value(for: "OPENUSAGE_CODEX_ROUTER_USAGE_EVENTS"),
            environment.value(for: "CODEX_ROUTER_STATE_DIR").map {
                URL(fileURLWithPath: $0).appendingPathComponent("usage-events.jsonl").path
            },
            environment.value(for: "MODEL_ROUTER_STATE_DIR").map {
                URL(fileURLWithPath: $0).appendingPathComponent("usage-events.jsonl").path
            }
        ].flatMap(splitPaths)
        return unique(configured)
    }

    static func defaultLedgerPaths(
        environment: EnvironmentReading,
        homeDirectory: URL
    ) -> [String] {
        let configured = configuredLedgerPaths(environment: environment)
        guard configured.isEmpty else { return configured }
        return [
            homeDirectory
                .appendingPathComponent(".codex/codex-router/usage-events.jsonl")
                .path
        ]
    }

    // MARK: - Incremental parse

    private static func discoveredLedgers(
        paths: [String],
        optionalDefaultPath: String?
    ) -> LedgerDiscovery {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .attributeModificationDateKey
        ]
        var files: [JSONLScanning.DiscoveredFile] = []
        var seen: Set<String> = []
        let optionalPath = optionalDefaultPath.map {
            URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path
        }
        for path in paths {
            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            let standardized = url.path
            guard seen.insert(standardized).inserted else { continue }
            var status = stat()
            guard Darwin.lstat(standardized, &status) == 0 else {
                if standardized == optionalPath, errno == ENOENT { continue }
                return LedgerDiscovery(files: files, complete: false)
            }
            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: keys)
            } catch {
                return LedgerDiscovery(files: files, complete: false)
            }
            guard values.isRegularFile == true else {
                return LedgerDiscovery(files: files, complete: false)
            }
            files.append(JSONLScanning.DiscoveredFile(
                path: standardized,
                size: values.fileSize ?? 0,
                mtime: values.contentModificationDate ?? .distantPast,
                attributeMtime: values.attributeModificationDate
            ))
        }
        return LedgerDiscovery(
            files: files.sorted { $0.path < $1.path },
            complete: true
        )
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
            var malformedLine = false
            var timestampCache = CodexRouterEventLineParser.TimestampCache()
            var read = JSONLFileReader.readLines(
                at: url,
                chunkSize: 64 * 1024,
                startOffset: cached.offset,
                initialCarry: cached.partialLine,
                discardingOversizedLine: cached.isDiscardingOversizedLine,
                deliverFinalPartial: false
            ) { line in
                switch parseLine(line, timestampCache: &timestampCache) {
                case .event(let event) where event.timestamp >= emitSince:
                    collected.append(event)
                case .event, .irrelevant:
                    break
                case .malformedEvent(let event):
                    collected.append(event)
                case .malformed:
                    malformedLine = true
                }
            }
            guard read.isComplete, !malformedLine else { return nil }
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
               CodexRouterEventLineParser.looksLikeCompleteObject(read.finalPartial[...]) {
                switch parseLine(read.finalPartial[...], timestampCache: &timestampCache) {
                case .event(let event) where event.timestamp >= emitSince:
                    collected.append(event)
                    read.finalPartial = Data()
                case .event, .irrelevant:
                    read.finalPartial = Data()
                case .malformedEvent(let event):
                    collected.append(event)
                    read.finalPartial = Data()
                case .malformed:
                    return nil
                }
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
        var malformedLine = false
        var timestampCache = CodexRouterEventLineParser.TimestampCache()
        var read = JSONLFileReader.readLines(
            at: url,
            chunkSize: 64 * 1024,
            startOffset: cached.offset,
            initialCarry: cached.partialLine,
            discardingOversizedLine: cached.isDiscardingOversizedLine,
            deliverFinalPartial: false
        ) { line in
            switch parseLine(line, timestampCache: &timestampCache) {
            case .event(let event) where event.timestamp >= emitSince:
                collected.append(event)
            case .event, .irrelevant:
                break
            case .malformedEvent(let event):
                collected.append(event)
            case .malformed:
                malformedLine = true
            }
        }
        guard read.isComplete, !malformedLine,
              AppendOnlyFileProbe.anchor(at: url, endingAt: cached.offset) == cached.anchor
        else { return nil }

        // Match the full reader: a complete JSON object at EOF counts even without a newline.
        if !read.finalPartial.isEmpty,
           CodexRouterEventLineParser.looksLikeCompleteObject(read.finalPartial[...]) {
            switch parseLine(read.finalPartial[...], timestampCache: &timestampCache) {
            case .event(let event) where event.timestamp >= emitSince:
                collected.append(event)
                read.finalPartial = Data()
            case .event, .irrelevant:
                read.finalPartial = Data()
            case .malformedEvent(let event):
                collected.append(event)
                read.finalPartial = Data()
            case .malformed:
                return nil
            }
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
        var malformedLine = false
        var timestampCache = CodexRouterEventLineParser.TimestampCache()
        var read = JSONLFileReader.readLines(
            at: url,
            chunkSize: 64 * 1024,
            deliverFinalPartial: false
        ) { line in
            switch parseLine(line, timestampCache: &timestampCache) {
            case .event(let event) where event.timestamp >= emitSince:
                collected.append(event)
            case .event, .irrelevant:
                break
            case .malformedEvent(let event):
                collected.append(event)
            case .malformed:
                malformedLine = true
            }
        }
        guard read.isComplete, !malformedLine else { return nil }
        if !read.finalPartial.isEmpty,
           CodexRouterEventLineParser.looksLikeCompleteObject(read.finalPartial[...]) {
            switch parseLine(read.finalPartial[...], timestampCache: &timestampCache) {
            case .event(let event) where event.timestamp >= emitSince:
                collected.append(event)
                read.finalPartial = Data()
            case .event, .irrelevant:
                read.finalPartial = Data()
            case .malformedEvent(let event):
                collected.append(event)
                read.finalPartial = Data()
            case .malformed:
                return nil
            }
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
    ) -> CodexRouterEventLineParser.LineResult {
        CodexRouterEventLineParser.parseResult(line, timestampCache: &timestampCache)
    }

    nonisolated private static func recentEvents(_ events: [Event], since: Date) -> [Event] {
        var recent: [Event] = []
        recent.reserveCapacity(events.count)
        JSONLAccountingWorkPacer.shared.forEach(events) { event in
            if event.isMalformedRouterEvent || event.timestamp >= since { recent.append(event) }
        }
        return recent
    }

    // MARK: - Parsing

    struct Event: Codable, Equatable, Sendable {
        var timestamp: Date
        var model: String
        var provider: String
        var status: Int
        var hasValidStatusField: Bool = true
        var hasValidTimestampField: Bool = true
        var hasValidModelField: Bool = true
        var hasUniqueStatusField: Bool = true
        var hasUniqueProviderField: Bool = true
        var hasUniqueModelField: Bool = true
        var hasUniqueAccountIdentityFields: Bool = true
        var hasValidNumericCountFields: Bool = true
        var hasUniqueRecognizedFields: Bool = true
        var inputTokens: Int
        var cachedInputTokens: Int
        var outputTokens: Int
        var reasoningTokens: Int
        var totalTokens: Int?
        /// Preserve field presence separately from numeric zero so a malformed/legacy row with no
        /// usage breakdown cannot claim complete coverage and suppress a native session row.
        var hasInputTokensField = true
        var hasOutputTokensField = true
        var hasValidCachedInputTokensField = true
        var hasValidTotalTokensField = true
        var hasValidEstimatedInputTokensField = true
        /// This estimate is never added to usage. It only tells reconciliation that the router's
        /// input count is incomplete when it reports zero measured input alongside an estimate.
        var hasEstimatedInputTokens: Bool? = nil
        var hasValidAccountIdentityFields = true
        /// An absent legacy provider remains classifiable as unknown, but a present malformed value
        /// must not route metered usage into the wrong provider card.
        var hasValidProviderField: Bool? = true
        /// Missing tiers are valid. A present malformed/unknown tier keeps token usage but makes its
        /// cost estimate incomplete instead of silently pricing it at the default rate.
        var hasValidServiceTierField: Bool? = true
        var accountId: String?
        var accountFingerprint: String?
        /// Codex `service_tier` when the router stamped it (`priority` / `fast` / `default` / …).
        var serviceTier: String?
        /// The source count exceeded the parser's safe range and was retained as a lower bound.
        var tokenCountSaturated: Bool? = nil

        var isMalformedRouterEvent: Bool {
            !hasValidStatusField || !hasValidTimestampField || !hasValidModelField || !hasValidAccountIdentityFields
                || !hasValidNumericCountFields || !hasUniqueRecognizedFields
                || hasValidProviderField == false
        }

        /// Use an explicit provider total when present, otherwise derive one only from two valid
        /// measured components. Invalid or absent components must not become a plausible zero and
        /// suppress the matching native Codex row during source reconciliation.
        var measuredTokenTotal: Int? {
            let componentTotal: Int? = hasInputTokensField && hasOutputTokensField
                ? ProviderParse.addingSaturating(inputTokens, outputTokens)
                : nil
            if let totalTokens {
                if totalTokens == 0,
                   inputTokens > 0 || outputTokens > 0 || cachedInputTokens > 0 || reasoningTokens > 0 {
                    // A zero total cannot erase a positive reported component. Recover it only when
                    // both measured input and output are present; otherwise the source is incomplete.
                    guard let componentTotal, componentTotal > 0 else { return nil }
                    return componentTotal
                }
                return totalTokens
            }
            return componentTotal
        }

        var hasNoMeasuredUsageFields: Bool {
            !hasInputTokensField && !hasOutputTokensField && totalTokens == nil
                && cachedInputTokens == 0 && reasoningTokens == 0
        }

        /// The estimate is deliberately excluded from measured usage. A reported total that cannot be
        /// reconciled to measured input + output likewise lacks a complete priceable breakdown.
        var hasCompleteMeasuredCostBreakdown: Bool {
            guard hasInputTokensField, hasOutputTokensField,
                  hasValidCachedInputTokensField, cachedInputTokens <= inputTokens,
                  hasValidTotalTokensField, hasValidEstimatedInputTokensField,
                  hasValidServiceTierField != false,
                  tokenCountSaturated != true
            else { return false }
            guard hasEstimatedInputTokens != true else { return false }
            guard let totalTokens else { return true }
            let measuredTotal = inputTokens.addingReportingOverflow(outputTokens)
            guard !measuredTotal.overflow else { return false }
            return totalTokens == measuredTotal.partialValue
        }
    }

    /// True when the router metered this turn against an OpenCode-hosted account.
    static func isOpenCodeServed(_ event: Event) -> Bool {
        isOpenCodeProvider(event.provider) || OpenCodeUsageScanner.isHostedGatewayModel(event.model)
    }

    private static func isDefinitelyOpenCodeServed(_ event: Event) -> Bool {
        let providerRoute = event.hasUniqueProviderField
            && event.hasValidProviderField != false
            && isOpenCodeProvider(event.provider)
        let modelRoute = event.hasUniqueModelField
            && event.hasValidModelField
            && OpenCodeUsageScanner.isHostedGatewayModel(event.model)
        return providerRoute || modelRoute
    }

    private static func malformedRouterEventAffectsAccount(
        _ event: Event,
        expectedFingerprint: String?,
        expectedAccountId: String?,
        expectedAliasIds: Set<String>,
        allowsUnscopedEvents: Bool
    ) -> Bool {
        // OpenCode has its own fold. A route is safe to exclude from Codex only when one unique,
        // valid ownership signal proves that route.
        guard !isDefinitelyOpenCodeServed(event) else { return false }
        // Ambiguous stamps cannot be assigned to another card, so keep the existing fail-closed
        // behavior for the requested account.
        guard event.hasValidAccountIdentityFields, event.hasUniqueAccountIdentityFields else { return true }
        let hasIdentity = event.accountFingerprint != nil || event.accountId != nil
        guard hasIdentity else { return allowsUnscopedEvents }

        let fingerprintMatches = event.accountFingerprint.flatMap { fingerprint in
            expectedFingerprint.map { fingerprint.caseInsensitiveCompare($0) == .orderedSame }
        }
        let accountMatches = event.accountId.map { accountId in
            let aliasMatch = expectedAliasIds.contains(accountId.lowercased())
            if let expectedAccountId {
                return accountId.caseInsensitiveCompare(expectedAccountId) == .orderedSame || aliasMatch
            }
            return expectedAliasIds.isEmpty ? false : aliasMatch
        }
        if let fingerprintMatches, let accountMatches, fingerprintMatches != accountMatches {
            return true
        }
        return belongsToAccount(
            event,
            expectedFingerprint: expectedFingerprint,
            expectedAccountId: expectedAccountId,
            expectedAliasIds: expectedAliasIds,
            allowsUnscopedEvents: allowsUnscopedEvents
        )
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
            let fingerprintMatches: Bool? = event.accountFingerprint.flatMap { fingerprint in
                guard let expectedFingerprint else { return nil }
                return fingerprint.caseInsensitiveCompare(expectedFingerprint) == .orderedSame
            }
            let accountMatches: Bool? = event.accountId.flatMap { accountId in
                let aliasMatch = expectedAliasIds.contains(accountId.lowercased())
                if let expectedAccountId {
                    return accountId.caseInsensitiveCompare(expectedAccountId) == .orderedSame
                        || aliasMatch
                }
                return expectedAliasIds.isEmpty ? nil : aliasMatch
            }
            // A malformed row with one identifier for this account and another for a different
            // account must not be accepted by both cards through the old either-ID match.
            if let fingerprintMatches, let accountMatches,
               fingerprintMatches != accountMatches
            {
                return false
            }
            if fingerprintMatches == true || accountMatches == true { return true }
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
        loadPoolIdentityAliasSnapshot(environment: environment, homeDirectory: homeDirectory).aliases
    }

    private static func loadPoolIdentityAliasSnapshot(
        environment: EnvironmentReading,
        homeDirectory: URL
    ) -> IdentityAliasSnapshot {
        var candidates: [String] = []
        func appendCandidate(_ path: String) {
            let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
            if !candidates.contains(normalized) {
                candidates.append(normalized)
            }
        }

        if let override = environment.value(for: "MODEL_ROUTER_CHATGPT_ACCOUNT_POOL")?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            appendCandidate(override)
        }
        for key in ["CODEX_ROUTER_STATE_DIR", "MODEL_ROUTER_STATE_DIR"] {
            if let state = environment.value(for: key)?
                .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
                appendCandidate(
                    URL(fileURLWithPath: state)
                        .appendingPathComponent("chatgpt-account-pool.json").path
                )
            }
        }
        appendCandidate(
            homeDirectory
                .appendingPathComponent(".codex/codex-router/chatgpt-account-pool.json")
                .path
        )

        var aliases: [String: String] = [:]
        var conflicts: Set<String> = []
        var isComplete = true
        func merge(_ alias: String, accountID: String) {
            let key = alias.lowercased()
            guard !key.isEmpty, !conflicts.contains(key) else { return }
            if let existing = aliases[key], existing != accountID {
                aliases.removeValue(forKey: key)
                conflicts.insert(key)
                isComplete = false
            } else {
                aliases[key] = accountID
            }
        }

        for path in candidates {
            var metadata = stat()
            guard Darwin.lstat(path, &metadata) == 0 else {
                if errno == ENOENT { continue }
                // fileExists(atPath:) also returns false for inaccessible parents. Only a true
                // missing optional pool file is absence; other stat failures make attribution
                // incomplete so opaque account IDs cannot silently disappear from the scan.
                isComplete = false
                continue
            }
            guard FileManager.default.isReadableFile(atPath: path),
                  let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let root = object as? [String: Any],
                  let rawAccounts = root["accounts"],
                  let accounts = rawAccounts as? [String: Any]
            else {
                // Existing pool metadata may be needed to assign opaque IDs in a configured ledger.
                // Preserve the last-good history when that mapping cannot be read or decoded.
                isComplete = false
                continue
            }
            for (poolID, value) in accounts {
                guard let account = value as? [String: Any] else {
                    isComplete = false
                    continue
                }
                if let rawIdentity = account["identity"],
                   !(rawIdentity is NSNull),
                   !(rawIdentity is [String: Any]) {
                    isComplete = false
                    continue
                }
                let identity = account["identity"] as? [String: Any]
                if let rawAccountID = identity?["accountId"],
                   !(rawAccountID is NSNull),
                   !(rawAccountID is String) {
                    isComplete = false
                    continue
                }
                if let rawAccountID = account["accountId"],
                   !(rawAccountID is NSNull),
                   !(rawAccountID is String) {
                    isComplete = false
                    continue
                }
                let uuid = ((identity?["accountId"] as? String) ?? (account["accountId"] as? String))?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nilIfEmpty?
                    .lowercased()
                guard let uuid, !uuid.isEmpty else { continue }
                merge(poolID, accountID: uuid)
                // Also accept the FCC fingerprint as an alias key when present in events.
                if let fingerprint = CodexProxyUsageScanner.accountFingerprint(for: uuid) {
                    merge(fingerprint, accountID: uuid)
                }
            }
        }
        return IdentityAliasSnapshot(aliases: aliases, isComplete: isComplete)
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
    ) async -> CodexRouterUsageScanResult {
        let expectedFingerprint = CodexProxyUsageScanner.accountFingerprint(for: accountIdentityKey)
        let expectedAccountId = accountIdentityKey?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        let aliasSnapshot = identityAliasSnapshot()
        let aliases = aliasSnapshot.aliases
        let expectedAliasIds: Set<String> = {
            guard let expectedAccountId else { return [] }
            let needle = expectedAccountId.lowercased()
            return Set(aliases.compactMap { key, value in
                value.lowercased() == needle ? key.lowercased() : nil
            })
        }()
        let index = CodexRouterAggregateIndex.shared
        func incomplete(_ reason: String) -> CodexRouterUsageScanResult {
            DiagnosticGate.logOnce(for: "codex.router.incomplete." + reason) {
                AppLog.warn(LogTag.plugin("codex"), "Router checkpoint rejected: \(reason)")
            }
            return .incomplete
        }
        let paths = ledgerPaths()
        let discovery = Self.discoveredLedgers(
            paths: paths,
            optionalDefaultPath: optionalDefaultLedgerPath
        )
        guard discovery.complete else { return incomplete("source-discovery") }
        guard discovery.files.isEmpty || aliasSnapshot.isComplete else { return incomplete("identity-aliases") }
        guard let initialSourceRevisions = Self.sourceRevisions(for: discovery.files) else {
            return incomplete("initial-source-revision")
        }
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
        let lookup = index.lookup(
            key: key,
            paths: paths,
            now: now,
            pricingDependenciesUnchanged: { dependencies in
                // The catalogue moved. Reuse the saved fold only when every resolution it priced
                // still holds; anything else falls back to the original full rebuild.
                dependencies.isEquivalent(under: pricing)
            }
        )
        let prior: CodexRouterAggregateIndex.Record?
        switch lookup {
        case .hit(let cached):
            guard !Task.isCancelled,
                  identityAliasesStillMatch(aliasSnapshot, hasLedgerSources: !discovery.files.isEmpty)
            else { return incomplete("cached-identity-changed") }
            return .complete(cached)
        case .append(let record):
            prior = record
        case .rebuild:
            prior = nil
        }

        let fold = AggregateFoldState()
        let visit: (Event) -> Void = { event in
            if event.isMalformedRouterEvent {
                if Self.malformedRouterEventAffectsAccount(
                    event,
                    expectedFingerprint: expectedFingerprint,
                    expectedAccountId: expectedAccountId,
                    expectedAliasIds: expectedAliasIds,
                    allowsUnscopedEvents: allowsUnscopedEvents
                ) {
                    fold.sawInvalidUsageRow = true
                }
                return
            }
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
            let hasCompleteCostBreakdown = event.hasCompleteMeasuredCostBreakdown
            guard let total = event.measuredTokenTotal else {
                if event.hasNoMeasuredUsageFields {
                    fold.sawRows = true
                    fold.accumulator.markUnmeasuredUsage(day: DailyUsageAccumulator.dayKey(from: event.timestamp, calendar: calendar))
                    return
                }
                fold.sawInvalidUsageRow = true
                return
            }
            guard total > 0 else { return }
            if fold.latestIncludedEventAt.map({ event.timestamp > $0 }) ?? true {
                fold.latestIncludedEventAt = event.timestamp
            }
            fold.sawRows = true
            let day = DailyUsageAccumulator.dayKey(from: event.timestamp, calendar: calendar)
            guard let resolvedPricing = fold.pricingCache.resolve(
                model: event.model,
                at: event.timestamp,
                pricing: pricing
            ) else {
                fold.accumulator.addUnknownModel(day: day, model: event.model)
                // Unknown router models still represent measured usage. Keep their tokens in the
                // series with a nil cost, matching the event-retaining scan path.
                fold.accumulator.add(
                    day: day,
                    tokens: total,
                    cost: nil,
                    model: event.model,
                    canonical: event.model,
                    tokenCountSaturated: event.tokenCountSaturated == true
                )
                return
            }
            let isPriorityTier = event.serviceTier == "fast" || event.serviceTier == "priority"
            let serviceTierMultiplier = CodexLogUsageScanner.codexServiceTierMultiplier(
                for: resolvedPricing.pricingModel,
                serviceTier: event.serviceTier
            )
            let appliesServiceTier = serviceTierMultiplier != nil
            let logEvent = CodexLogUsageScanner.Event(
                timestamp: event.timestamp,
                model: event.model,
                pricingModel: resolvedPricing.pricingModel,
                input: input,
                cached: cached,
                output: output,
                reasoning: reasoning,
                total: total,
                isFast: isPriorityTier || appliesServiceTier,
                serviceTier: event.serviceTier
            )
            let apiEstimate = resolvedPricing.rates.costDollars(
                for: TokenBreakdown(
                    input: max(0, input - cached),
                    cacheRead: cached,
                    output: output
                )
            )
            fold.accumulator.recordApiEstimate(
                day: day,
                cost: hasCompleteCostBreakdown ? apiEstimate : nil,
                tokens: total
            )
            let cost = CodexLogUsageScanner.cost(
                rates: resolvedPricing.rates,
                event: logEvent,
                model: resolvedPricing.pricingModel,
                fastTier: isPriorityTier || appliesServiceTier,
                fastMultiplier: serviceTierMultiplier ?? resolvedPricing.priorityMultiplier
            )
            fold.accumulator.add(
                day: day,
                tokens: total,
                cost: cost,
                model: event.model,
                canonical: resolvedPricing.canonicalModel,
                costIsComplete: hasCompleteCostBreakdown,
                tokenCountSaturated: event.tokenCountSaturated == true
            )
            if !hasCompleteCostBreakdown {
                fold.accumulator.markCostIncomplete(
                    day: day,
                    model: event.model,
                    canonical: resolvedPricing.canonicalModel
                )
            }
        }

        let priorByPath = Dictionary(uniqueKeysWithValues: (prior?.files ?? []).map { ($0.path, $0) })
        var checkpoints: [CodexRouterAggregateIndex.FileCheckpoint] = []
        let live = CodexRouterAggregateIndex.stats(for: paths)
        guard Set(live.map(\.path)) == Set(discovery.files.map(\.path)) else {
            return incomplete("source-set-changed")
        }
        for file in live {
            guard !Task.isCancelled else { return incomplete("cancelled") }
            let url = URL(fileURLWithPath: file.path)
            let saved = priorByPath[file.path]
            let tail = saved != nil && file.size > (saved?.offset ?? 0)
            if let saved, !tail {
                checkpoints.append(saved)
                continue
            }
            let start = tail ? (saved?.offset ?? 0) : 0
            var timestampCache = CodexRouterEventLineParser.TimestampCache()
            var malformedEventLine = false
            var read = JSONLFileReader.readLines(
                at: url,
                chunkSize: 256 * 1024,
                startOffset: start,
                endOffset: file.size,
                initialCarry: tail ? (saved?.partial ?? Data()) : Data(),
                discardingOversizedLine: tail ? (saved?.discardingOversizedLine ?? false) : false,
                deliverFinalPartial: false
            ) { line in
                switch CodexRouterEventLineParser.parseResult(line, timestampCache: &timestampCache) {
                case .event(let event): visit(event)
                case .malformedEvent(let event): visit(event)
                case .irrelevant: break
                case .malformed: malformedEventLine = true
                }
            }
            guard read.isComplete, !malformedEventLine, !fold.sawInvalidUsageRow else { return incomplete("read-incomplete-parse-\(read.isComplete)-\(malformedEventLine)-\(fold.sawInvalidUsageRow)") }
            if !read.finalPartial.isEmpty,
               CodexRouterEventLineParser.looksLikeCompleteObject(read.finalPartial[...]) {
                switch CodexRouterEventLineParser.parseResult(read.finalPartial[...], timestampCache: &timestampCache) {
                case .event(let event):
                    visit(event)
                    read.finalPartial = Data()
                case .malformedEvent(let event):
                    visit(event)
                    read.finalPartial = Data()
                case .irrelevant:
                    read.finalPartial = Data()
                case .malformed:
                    return incomplete("partial-line-malformed")
                }
            }
            let newOffset = start + UInt64(max(0, read.statistics.bytesRead))
            guard let checkpoint = index.checkpoint(
                path: file.path,
                offset: newOffset,
                partial: read.finalPartial,
                discardingOversizedLine: read.isDiscardingOversizedLine
            ), checkpoint.device == file.device, checkpoint.inode == file.inode else {
                return incomplete("checkpoint-inode")
            }
            // A rotation during the read must never attach old events to the replacement's inode.

            checkpoints.append(checkpoint)
            index.noteParse(path: file.path, full: !tail, bytes: read.statistics.bytesRead)
        }
        guard !Task.isCancelled, !fold.sawInvalidUsageRow else { return incomplete("cancelled-or-invalid-row") }
        beforeAggregateValidationForTesting?()
        let currentDiscovery = Self.discoveredLedgers(
            paths: paths,
            optionalDefaultPath: optionalDefaultLedgerPath
        )
        guard currentDiscovery.complete,
              Set(currentDiscovery.files.map(\.path)) == Set(checkpoints.map(\.path)),
              let finalSourceRevisions = Self.sourceRevisions(for: currentDiscovery.files),
              Self.sourcesAreUnchangedOrAppended(initialSourceRevisions, finalSourceRevisions),
              identityAliasesStillMatch(aliasSnapshot, hasLedgerSources: !currentDiscovery.files.isEmpty)
        else { return incomplete("final-source-or-identity-changed") }

        let delta: LogUsageScan?
        if fold.sawRows {
            let built = fold.accumulator.build()
            delta = built.series.daily.isEmpty && built.unknownModelsByDay.isEmpty
                && built.unmeasuredUsageDays?.isEmpty != false ? nil : built
        } else {
            delta = nil
        }
        let result = prior == nil ? delta : DailyUsageAccumulator.merged([prior?.result, delta])
        let nextFuture = [prior?.nextFutureEventAt, fold.nextFutureEventAt].compactMap { $0 }.min()
        let latestIncluded = [prior?.latestIncludedEventAt, fold.latestIncludedEventAt]
            .compactMap { $0 }
            .max()
        // Keep what the whole fold priced, not just what this pass priced: a tail merge re-prices
        // the new rows only, and the saved fold still has to know what the old rows cost.
        let foldDependencies = fold.pricingCache.dependencySnapshot()
        let dependencies = prior?.pricingDependencies.map { $0.merged(with: foldDependencies) }
            ?? foldDependencies
        index.save(CodexRouterAggregateIndex.Record(
            schema: CodexRouterAggregateIndex.schema,
            key: key,
            files: checkpoints,
            result: result,
            nextFutureEventAt: nextFuture,
            latestIncludedEventAt: latestIncluded,
            complete: true,
            pricingDependencies: dependencies
        ))
        return .complete(result)
    }

}
