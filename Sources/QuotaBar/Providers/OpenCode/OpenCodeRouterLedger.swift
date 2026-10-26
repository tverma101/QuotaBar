import Foundation
import Darwin

/// Reads the OpenCode-owned slice of CodexRouter's append-only usage ledger.
///
/// Small ledgers keep individual rows for exact tests and short-lived history. Large ledgers fold
/// immediately into `OpenCodeRouterLedgerAggregate`, so a tap materializes a few dozen day/model rows
/// instead of replaying tens of megabytes of JSON. Both modes share one append checkpoint and reject
/// truncate/regrow or same-size replacement by device/inode, modification stamps, and a prefix anchor.
final class OpenCodeRouterLedger: @unchecked Sendable {
    static let shared = OpenCodeRouterLedger()

    enum LineResult {
        case row(OpenCodeUsageScanner.ClaudeGatewayRow)
        case irrelevant
        case futureTimestamp(Date)
        case malformed
    }

    struct SourceSnapshot: Equatable, Sendable {
        var revision: AppendOnlyFileRevision
        var offset: UInt64
        var anchor: Data
        var modificationStamp: ModificationStamp
    }

    struct ModificationStamp: Codable, Equatable, Sendable {
        var seconds: Int64
        var nanoseconds: Int64
        var changeSeconds: Int64
        var changeNanoseconds: Int64

        /// Fails source validation for synthetic aggregates and unavailable paths.
        static let unavailable = ModificationStamp(
            seconds: Int64.min,
            nanoseconds: Int64.min,
            changeSeconds: Int64.min,
            changeNanoseconds: Int64.min
        )
    }

    /// Keep the compact per-day history for the ten-year Usage History window, including leap days.
    static let retentionDays = 3_660
    private static let retentionInterval = Double(retentionDays) * 86_400

    private struct ParserCheckpoint: Sendable, Equatable {}

    private static let tailCache = AppendOnlyFileTailCache<OpenCodeUsageScanner.ClaudeGatewayRow, ParserCheckpoint>(
        maxEntries: 8,
        maxRetainedItems: 64_000
    )

    private static let maxCompactAggregates = 8

    private struct FutureTimestampMarker {
        var revision: AppendOnlyFileRevision
        var modificationStamp: ModificationStamp
        var anchor: Data
        var accountPolicyFingerprint: String
        var timestamp: Date
    }

    private let lock = NSLock()
    /// Compact aggregates are tiny; the cap bounds long-running processes that watch rotating ledgers.
    /// Instance-owned and always accessed under `lock` so no shared mutable static state is needed.
    private var aggregates: [String: OpenCodeRouterLedgerAggregate] = [:]
    /// A verified source revision that contains a row beyond the accepted clock bound.
    private var futureTimestampMarkers: [String: FutureTimestampMarker] = [:]
    /// Modification stamp captured whenever a small-ledger tail checkpoint is stored. The tail cache entry
    /// itself carries no timestamp, and the sampled prefix anchor cannot prove that bytes before the
    /// offset are unchanged, so an unchanged length with a changed stamp has to be treated as a rewrite.
    private var tailStamps: [String: ModificationStamp] = [:]

    func rows(atPath path: String, since: Date) -> [OpenCodeUsageScanner.ClaudeGatewayRow] {
        rowsIfComplete(atPath: path, since: since) ?? []
    }

    /// Return `nil` when a discovered ledger could not be read completely. The legacy rows-only
    /// accessor remains for callers that intentionally treat a missing source as empty; the provider
    /// scanner uses this result to avoid publishing a partial history over its last-good snapshot.
    func rowsIfComplete(
        atPath path: String,
        since: Date,
        maximumTimestamp: Date = JSONLScanning.maximumTimestamp(now: Date())
    ) -> [OpenCodeUsageScanner.ClaudeGatewayRow]? {
        // Only the ledger read is unpaced. The provider-wide pacer stays on for SQLite, Claude/Codex,
        // Hermes, and Muse work; pacing a cold tens-of-MB read at 7.5% used to exceed the deadline and
        // restart from zero on the next tap.
        ProviderRefreshContext.$accountingCPUThrottleEnabled.withValue(false) {
            lock.withLock {
                rowsLocked(
                    atPath: path,
                    since: since,
                    maximumTimestamp: maximumTimestamp,
                    enabledIdentityKeys: nil,
                    identifiersToIdentityKeys: [:]
                )
            }
        }
    }

    func rowsWithSourceSnapshotIfComplete(
        atPath path: String,
        since: Date,
        maximumTimestamp: Date = JSONLScanning.maximumTimestamp(now: Date()),
        enabledIdentityKeys: Set<String>? = nil,
        identifiersToIdentityKeys: [String: String] = [:]
    ) -> (rows: [OpenCodeUsageScanner.ClaudeGatewayRow], source: SourceSnapshot)? {
        ProviderRefreshContext.$accountingCPUThrottleEnabled.withValue(false) {
            lock.withLock {
                guard let rows = rowsLocked(
                    atPath: path,
                    since: since,
                    maximumTimestamp: maximumTimestamp,
                    enabledIdentityKeys: enabledIdentityKeys,
                    identifiersToIdentityKeys: identifiersToIdentityKeys
                ),
                      let source = sourceSnapshotLocked(atPath: path)
                else { return nil }
                return (rows, source)
            }
        }
    }

    /// The fold represents a verified prefix, not a promise that the writer will stay idle. An
    /// ordinary append leaves that prefix valid and is consumed next pass. Rotation, truncation,
    /// changed prefix samples, and same-size rewrites still invalidate it, as in the tail cache.
    static func sourceSnapshotIsCurrent(_ snapshot: SourceSnapshot, atPath path: String) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        guard let revision = AppendOnlyFileProbe.revision(at: url),
              revision.device == snapshot.revision.device,
              revision.inode == snapshot.revision.inode,
              revision.size >= snapshot.revision.size,
              snapshot.offset == snapshot.revision.size,
              let stamp = modificationStamp(at: url),
              AppendOnlyFileProbe.anchor(at: url, endingAt: snapshot.offset) == snapshot.anchor,
              AppendOnlyFileProbe.revision(at: url) == revision,
              modificationStamp(at: url) == stamp
        else { return false }
        return revision.size > snapshot.revision.size || stamp == snapshot.modificationStamp
    }

    func statistics(path: String) -> (fullParses: Int, tailParses: Int, bytesRead: Int)? {
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        guard let stats = Self.tailCache.statistics(for: url.path) else { return nil }
        return (stats.fullParses, stats.tailParses, stats.bytesRead)
    }

    func clearForTesting(path: String) {
        let key = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        lock.withLock {
            Self.tailCache.remove(key)
            aggregates[key] = nil
            tailStamps[key] = nil
            futureTimestampMarkers[key] = nil
        }
        OpenCodeRouterLedgerAggregate.removePersistedAggregate(path: key)
    }

    static func noteCompactTail(path: String, bytesRead: Int) {
        guard let entry = tailCache.entry(for: path) else { return }
        tailCache.store(entry, for: path, parseKind: .tail, bytesRead: bytesRead, retainItems: false)
    }

    /// Convert one ledger line into the shared OpenCode gateway-row shape.
    ///
    /// CodexRouter's `inputTokens` is inclusive of `cachedInputTokens`, matching the Codex session-log
    /// contract, so cached is carved out of input. `reasoningTokens` is a subset of output for these
    /// OpenAI-shaped usage events and is never added again.
    ///
    /// The router also emits `estimatedInputTokens` when upstream reported `inputTokens: 0`. That field
    /// is a router-authored approximation for context-window bookkeeping, not a measured count, so it is
    /// deliberately absent from the aggregate parser and never folded into QuotaBar's measured tokens.
    static func row(
        from line: Data.SubSequence,
        timestampCache: inout CodexRouterEventLineParser.TimestampCache
    ) -> OpenCodeUsageScanner.ClaudeGatewayRow? {
        guard case .row(let row) = parseRow(from: line, timestampCache: &timestampCache) else { return nil }
        return row
    }

    static func parseRow(
        from line: Data.SubSequence,
        timestampCache: inout CodexRouterEventLineParser.TimestampCache,
        maximumTimestamp: Date = JSONLScanning.maximumTimestamp(now: Date()),
        shouldCheckFuture: (OpenCodeUsageScanner.ClaudeGatewayRow) -> Bool = { _ in true }
    ) -> LineResult {
        // Cheap reject before the full parse. The router meters every provider it fronts, so most lines
        // in a shared ledger belong to other accounts; skipping them on a byte scan keeps the cold read
        // from decoding timestamp/model/account fields for rows that would be discarded anyway.
        // Case-insensitive because `isOpenCodeServed` lowercases the provider first, so `OpenCode-Go`
        // still has to reach the parser. One-directional on purpose: a false positive costs a wasted
        // parse, a false negative would drop real usage.
        guard mayNameOpenCodeProvider(line) else { return .irrelevant }
        let event: CodexRouterUsageScanner.Event
        switch CodexRouterEventLineParser.parseResult(line, timestampCache: &timestampCache) {
        case .event(let parsed): event = parsed
        case .malformedEvent(let parsed):
            guard let malformedRow = disabledMalformedRow(
                from: parsed,
                shouldCheckFuture: shouldCheckFuture
            ) else { return .malformed }
            return .row(malformedRow)
        case .irrelevant: return .irrelevant
        case .malformed: return .malformed
        }
        guard CodexRouterUsageScanner.isOpenCodeServed(event),
              CodexRouterUsageScanner.isSuccessfulStatus(event.status)
        else { return .irrelevant }
        guard let measuredTokenTotal = event.measuredTokenTotal else {
            // Some router responses report measured reasoning with zero input/output/total and
            // only an estimated input count. Reasoning is a measured subset of output: retain that
            // lower bound without promoting estimated input or freezing every other valid record.
            if event.hasInputTokensField, event.hasOutputTokensField,
               event.inputTokens == 0, event.outputTokens == 0, event.cachedInputTokens == 0,
               event.totalTokens == 0, event.reasoningTokens > 0 {
                let model = OpenCodeUsageScanner.bareRouterModelName(event.model)
                guard !model.isEmpty else { return .malformed }
                let row = OpenCodeUsageScanner.ClaudeGatewayRow(
                    date: event.timestamp, input: 0, output: event.reasoningTokens,
                    cacheWrite: 0, cacheRead: 0, model: model, totalTokens: event.reasoningTokens,
                    burnsGoQuota: event.provider.lowercased().hasPrefix("opencode-go")
                        || OpenCodeUsageScanner.isOpenCodeGoGatewayModel(event.model),
                    isInProgress: false, accountId: event.accountId, accountFingerprint: event.accountFingerprint,
                    routerInputWasEstimated: true, routerCostBreakdownIsComplete: false,
                    tokenCountSaturated: event.tokenCountSaturated == true
                )
                if event.timestamp > maximumTimestamp, shouldCheckFuture(row) {
                    return .futureTimestamp(event.timestamp)
                }
                return .row(row)
            }
            // A successful routed event can be a metadata-only sentinel while the native Codex log
            // carries the measured tokens. Retain it as an incomplete zero row so it cannot claim
            // router coverage and suppress that native record. Partial or invalid count fields still
            // fail closed below because they may represent lost usage.
            if !event.hasInputTokensField, !event.hasOutputTokensField, event.totalTokens == nil {
                let model = OpenCodeUsageScanner.bareRouterModelName(event.model)
                guard !model.isEmpty else {
                    guard let malformedRow = disabledMalformedRow(
                        from: event,
                        shouldCheckFuture: shouldCheckFuture
                    ) else { return .malformed }
                    return .row(malformedRow)
                }
                let row = OpenCodeUsageScanner.ClaudeGatewayRow(
                    date: event.timestamp,
                    input: 0,
                    output: 0,
                    cacheWrite: 0,
                    cacheRead: 0,
                    model: model,
                    totalTokens: 0,
                    burnsGoQuota: event.provider.lowercased().hasPrefix("opencode-go")
                        || OpenCodeUsageScanner.isOpenCodeGoGatewayModel(event.model),
                    isInProgress: false,
                    accountId: event.accountId,
                    accountFingerprint: event.accountFingerprint,
                    routerCostBreakdownIsComplete: false
                )
                if event.timestamp > maximumTimestamp, shouldCheckFuture(row) {
                    return .futureTimestamp(event.timestamp)
                }
                return .row(row)
            }
            guard let malformedRow = disabledMalformedRow(
                from: event,
                shouldCheckFuture: shouldCheckFuture
            ) else { return .malformed }
            return .row(malformedRow)
        }
        guard measuredTokenTotal > 0 else { return .irrelevant }
        guard !OpenCodeUsageScanner.bareRouterModelName(event.model).isEmpty else {
            guard let malformedRow = disabledMalformedRow(
                from: event,
                shouldCheckFuture: shouldCheckFuture
            ) else { return .malformed }
            return .row(malformedRow)
        }
        guard let row = row(from: event) else {
            guard let malformedRow = disabledMalformedRow(
                from: event,
                shouldCheckFuture: shouldCheckFuture
            ) else { return .malformed }
            return .row(malformedRow)
        }
        if event.timestamp > maximumTimestamp, shouldCheckFuture(row) {
            return .futureTimestamp(event.timestamp)
        }
        return .row(row)
    }

    /// Keep malformed ownership visible in the shared cache, but only when a valid OpenCode provider
    /// or hosted-model route, successful status, and every supplied account stamp positively identify
    /// a disabled account. Unknown, contradictory, or malformed identity fields remain fail-closed.
    private static func disabledMalformedRow(
        from event: CodexRouterUsageScanner.Event,
        shouldCheckFuture: (OpenCodeUsageScanner.ClaudeGatewayRow) -> Bool
    ) -> OpenCodeUsageScanner.ClaudeGatewayRow? {
        guard event.hasValidStatusField,
              event.hasUniqueStatusField,
              CodexRouterUsageScanner.isSuccessfulStatus(event.status),
              event.hasUniqueAccountIdentityFields,
              event.hasValidAccountIdentityFields
        else { return nil }
        let providerRouted = event.hasUniqueProviderField
            && event.hasValidProviderField != false
            && CodexRouterUsageScanner.isOpenCodeProvider(event.provider)
        let modelRouted = event.hasUniqueModelField
            && event.hasValidModelField
            && OpenCodeUsageScanner.isHostedGatewayModel(event.model)
        guard providerRouted || modelRouted else { return nil }
        let row = OpenCodeUsageScanner.ClaudeGatewayRow(
            date: event.timestamp,
            input: 0,
            output: 0,
            cacheWrite: 0,
            cacheRead: 0,
            model: OpenCodeUsageScanner.bareRouterModelName(event.model).nilIfEmpty
                ?? ModelUsageEntry.unattributedModelName,
            totalTokens: 0,
            burnsGoQuota: (event.hasUniqueProviderField
                && event.hasValidProviderField != false
                && event.provider.lowercased().hasPrefix("opencode-go"))
                || (event.hasUniqueModelField
                    && event.hasValidModelField
                    && OpenCodeUsageScanner.isOpenCodeGoGatewayModel(event.model)),
            isInProgress: false,
            accountId: event.accountId,
            accountFingerprint: event.accountFingerprint,
            isMalformed: true
        )
        return shouldCheckFuture(row) ? nil : row
    }

    /// Whether a ledger line is worth the full parse. A backslash anywhere means the JSON carries escape
    /// sequences, and a provider can be spelled `"opencode\u002dgo"` or `"\u006fpencode-go"` — the raw
    /// bytes then contain neither the literal substring nor anything the ASCII fold can see. So an escaped
    /// line always goes to the parser instead of being rejected on a guess.
    static func mayNameOpenCodeProvider(_ line: Data.SubSequence) -> Bool {
        if line.contains(UInt8(ascii: "\\")) { return true }
        return containsOpenCodeMarker(line)
    }

    /// ASCII case-insensitive search for `opencode` anywhere in one ledger line. Deliberately loose: it
    /// only has to prove the line *could* name an OpenCode provider, so it also matches model slugs and
    /// any other field, and never treats a match as proof of provider ownership.
    static func containsOpenCodeMarker(_ line: Data.SubSequence) -> Bool {
        let needle = [UInt8(ascii: "o"), UInt8(ascii: "p"), UInt8(ascii: "e"), UInt8(ascii: "n"),
                      UInt8(ascii: "c"), UInt8(ascii: "o"), UInt8(ascii: "d"), UInt8(ascii: "e")]
        guard line.count >= needle.count else { return false }
        let first = needle[0] | 0x20
        let limit = line.index(line.endIndex, offsetBy: -needle.count)
        var index = line.startIndex
        while index <= limit {
            if (line[index] | 0x20) == first {
                var cursor = index
                var matched = true
                for expected in needle {
                    // ASCII letters only, so `| 0x20` folds case without also folding punctuation.
                    if (line[cursor] | 0x20) != expected {
                        matched = false
                        break
                    }
                    cursor = line.index(after: cursor)
                }
                if matched { return true }
            }
            index = line.index(after: index)
        }
        return false
    }

    static func row(from line: Data) -> OpenCodeUsageScanner.ClaudeGatewayRow? {
        var timestampCache = CodexRouterEventLineParser.TimestampCache()
        return row(from: line[...], timestampCache: &timestampCache)
    }

    /// Every OpenCode-served router turn, including the legacy `anthropic/opencode_go/…` /
    /// `anthropic/opencode/…` slugs that also appear in the native Claude/Codex session logs.
    ///
    /// This used to drop the hosted slugs on the assumption that the native fold always had them. That
    /// assumption is wrong whenever the session log is absent, rotated away, or lives in a home this
    /// scan does not open — the turn then vanishes from every card. Instead the ledger owns ALL
    /// OpenCode-served rows, and `OpenCodeUsageScanner.scan` reads it first. Complete measured pairs can
    /// replace matching, identity-resolved native Codex rows; Claude, Hermes, and Muse are independent
    /// sources and always fold separately even when their day/model labels match.
    static func row(from event: CodexRouterUsageScanner.Event) -> OpenCodeUsageScanner.ClaudeGatewayRow? {
        guard CodexRouterUsageScanner.isOpenCodeServed(event),
              CodexRouterUsageScanner.isSuccessfulStatus(event.status),
              let measuredTokenTotal = event.measuredTokenTotal,
              measuredTokenTotal > 0
        else { return nil }

        let input = max(0, event.inputTokens)
        let cached = min(max(0, event.cachedInputTokens), input)
        let output = max(0, event.outputTokens)
        let tokenTotal = measuredTokenTotal
        let model = OpenCodeUsageScanner.bareRouterModelName(event.model)
        guard !model.isEmpty, tokenTotal > 0 else { return nil }
        return OpenCodeUsageScanner.ClaudeGatewayRow(
            date: event.timestamp,
            input: input - cached,
            output: output,
            cacheWrite: 0,
            cacheRead: cached,
            model: model,
            totalTokens: tokenTotal,
            // Only the Go subscription's cap meters are consumed by `opencode-go`; Zen and free tiers
            // are billed outside those caps.
            burnsGoQuota: event.provider.lowercased().hasPrefix("opencode-go")
                || OpenCodeUsageScanner.isOpenCodeGoGatewayModel(event.model),
            isInProgress: false,
            accountId: event.accountId,
            accountFingerprint: event.accountFingerprint,
            routerInputWasEstimated: event.hasEstimatedInputTokens,
            routerCostBreakdownIsComplete: event.hasCompleteMeasuredCostBreakdown,
            tokenCountSaturated: event.tokenCountSaturated == true
        )
    }

    private func rowsLocked(
        atPath path: String,
        since: Date,
        maximumTimestamp: Date,
        enabledIdentityKeys: Set<String>?,
        identifiersToIdentityKeys: [String: String]
    ) -> [OpenCodeUsageScanner.ClaudeGatewayRow]? {
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let key = url.path
        let policyFingerprint = Self.accountPolicyFingerprint(
            enabledIdentityKeys: enabledIdentityKeys,
            identifiersToIdentityKeys: identifiersToIdentityKeys
        )
        let normalizedEnabledIdentityKeys = enabledIdentityKeys.map { Set($0.map { $0.lowercased() }) }
        let shouldCheckFuture: (OpenCodeUsageScanner.ClaudeGatewayRow) -> Bool = { row in
            Self.shouldCheckFuture(
                accountId: row.accountId,
                accountFingerprint: row.accountFingerprint,
                enabledIdentityKeys: normalizedEnabledIdentityKeys,
                identifiersToIdentityKeys: identifiersToIdentityKeys
            )
        }
        guard let current = AppendOnlyFileProbe.revision(at: url) else {
            Self.tailCache.remove(key)
            tailStamps[key] = nil
            futureTimestampMarkers[key] = nil
            if let aggregate = aggregates[key] {
                OpenCodeRouterLedgerAggregate.removePersistedAggregate(
                    path: key,
                    matching: aggregate.sourceSnapshot
                )
            }
            aggregates[key] = nil
            return nil
        }

        let initialStamp = Self.modificationStamp(at: url)
        if let marker = futureTimestampMarkers[key] {
            let liveAnchor = AppendOnlyFileProbe.anchor(at: url, endingAt: current.size)
            if marker.revision == current,
               marker.modificationStamp == initialStamp,
               marker.anchor == liveAnchor,
               marker.accountPolicyFingerprint == policyFingerprint,
               marker.timestamp > maximumTimestamp {
                return nil
            }
            futureTimestampMarkers[key] = nil
        }

        let now = Date()
        let retentionCutoff = now.addingTimeInterval(-Self.retentionInterval)
        let detailedGoCutoff = now.addingTimeInterval(-45 * 86_400)
        var aggregate = aggregates[key] ?? OpenCodeRouterLedgerAggregate.load(path: key)
        if let loadedAggregate = aggregate,
           loadedAggregate.timeZoneIdentifier != Calendar.current.timeZone.identifier {
            // Day/model buckets are calendar-local. An in-memory aggregate can outlive a system
            // timezone change even though persisted aggregates are rejected on load; rebuild it
            // from source so old day labels are never interpreted in the new timezone.
            discardAggregate(for: key, matching: loadedAggregate.sourceSnapshot)
            aggregate = nil
        }
        if aggregate == nil {
            // Invalid or outdated aggregates cannot preserve current token and cost-breakdown fields.
            // Remove only an invalid cache still present after locking; another process may already
            // have replaced it with a valid aggregate for the live ledger.
            OpenCodeRouterLedgerAggregate.removeInvalidPersistedAggregate(path: key)
        }
        if let aggregate {
            aggregate.refreshFromPersistedIfNewer()
            if aggregate.prune(before: retentionCutoff, detailedGoCutoff: detailedGoCutoff) {
                aggregate.save()
            }
            storeAggregate(aggregate, for: key)
            switch aggregate.reconcile(
                url: url,
                current: current,
                since: since,
                detailedGoCutoff: detailedGoCutoff,
                maximumTimestamp: maximumTimestamp,
                shouldCheckFuture: { accountId, accountFingerprint in
                    Self.shouldCheckFuture(
                        accountId: accountId,
                        accountFingerprint: accountFingerprint,
                        enabledIdentityKeys: normalizedEnabledIdentityKeys,
                        identifiersToIdentityKeys: identifiersToIdentityKeys
                    )
                }
            ) {
            case .rows(let rows):
                guard let usableRows = validatedRows(
                    rows,
                    since: since,
                    shouldCheckFuture: shouldCheckFuture
                ), usableRows.allSatisfy({ row in
                    guard shouldCheckFuture(row) else { return true }
                    if row.isAggregated {
                        return DailyUsageAccumulator.dayKey(from: row.date)
                            <= DailyUsageAccumulator.dayKey(from: maximumTimestamp)
                    }
                    return row.date <= maximumTimestamp
                }) else {
                    discardAggregate(for: key, matching: aggregate.sourceSnapshot)
                    Self.tailCache.remove(key)
                    tailStamps[key] = nil
                    return nil
                }
                return usableRows
            case .stale:
                // Rotation, truncate/regrow, or in-place rewrite. Drop the checkpoint AND its compact
                // file: a persisted aggregate that can never reconcile would otherwise be decoded on
                // every launch and rejected again on every refresh.
                discardAggregate(for: key, matching: aggregate.sourceSnapshot)
            case .malformed:
                // The source remains intact and the row may become irrelevant again if its account
                // is disabled. Keep the compact checkpoint for that policy change.
                return nil
            case .aborted:
                // Deadline cancellation or a transient read failure. The aggregate — in memory and on
                // disk — is still the best known state; deleting it here turned every timed-out
                // refresh into a full cold rebuild on the next one. Mark the source incomplete so the
                // provider keeps the last-good snapshot instead of publishing a partial replacement.
                return nil
            case .futureTimestamp(let timestamp):
                rememberFutureTimestamp(
                    timestamp,
                    path: key,
                    url: url,
                    revision: current,
                    modificationStamp: initialStamp,
                    accountPolicyFingerprint: policyFingerprint
                )
                // This source was already parsed, or its append tail was verified, and its future
                // watermark is known. Keep last-good history without repeating that work.
                return nil
            }
        }

        if let cached = Self.tailCache.entry(for: key),
           current.device == cached.revision.device,
           current.inode == cached.revision.inode,
           current.size >= cached.offset,
           AppendOnlyFileProbe.anchor(at: url, endingAt: cached.offset) == cached.anchor {
            // Unchanged length: the cached rows are only reusable when the file was not touched. A
            // same-size rewrite keeps the anchor (the rewrite can land past the sampled positions), so
            // without the stamp check a replaced file would keep serving the previous contents.
            if current.size == cached.offset, cached.itemsAvailable, isUnchanged(at: url, key: key) {
                guard let rows = validatedRows(
                    cached.items,
                    since: since,
                    shouldCheckFuture: shouldCheckFuture
                ) else { return nil }
                guard rows.allSatisfy({ !shouldCheckFuture($0) || $0.date <= maximumTimestamp }) else {
                    Self.tailCache.remove(key)
                    tailStamps[key] = nil
                    return nil
                }
                return rows
            }

            if current.size > cached.offset, cached.itemsAvailable {
                var futureTimestamp: Date?
                let rows = readAppend(
                    at: url,
                    key: key,
                    current: current,
                    cached: cached,
                    initialStamp: initialStamp,
                    retentionCutoff: retentionCutoff,
                    maximumTimestamp: maximumTimestamp,
                    shouldCheckFuture: shouldCheckFuture,
                    futureTimestamp: &futureTimestamp
                )
                if let futureTimestamp {
                    rememberFutureTimestamp(
                        futureTimestamp,
                        path: key,
                        url: url,
                        revision: current,
                        modificationStamp: initialStamp,
                        accountPolicyFingerprint: policyFingerprint
                    )
                    return nil
                }
                if let rows {
                    return validatedRows(rows, since: since, shouldCheckFuture: shouldCheckFuture)
                }
            }
        }

        var futureTimestamp: Date?
        guard let rows = readWholeFile(
            at: url,
            key: key,
            retentionCutoff: retentionCutoff,
            maximumTimestamp: maximumTimestamp,
            shouldCheckFuture: shouldCheckFuture,
            futureTimestamp: &futureTimestamp
        ) else {
            if let futureTimestamp {
                rememberFutureTimestamp(
                    futureTimestamp,
                    path: key,
                    url: url,
                    revision: current,
                    modificationStamp: initialStamp,
                    accountPolicyFingerprint: policyFingerprint
                )
            }
            return nil
        }
        return validatedRows(rows, since: since, shouldCheckFuture: shouldCheckFuture)
    }

    /// A retained malformed sentinel is harmless only while its account still resolves to a
    /// disabled identity. Recheck it on every cache hit so enabling that account exposes the source
    /// error instead of silently keeping the previously filtered history.
    private func validatedRows(
        _ rows: [OpenCodeUsageScanner.ClaudeGatewayRow],
        since: Date,
        shouldCheckFuture: (OpenCodeUsageScanner.ClaudeGatewayRow) -> Bool
    ) -> [OpenCodeUsageScanner.ClaudeGatewayRow]? {
        guard !rows.contains(where: { $0.isMalformed && shouldCheckFuture($0) }) else { return nil }
        return rows.filter { !$0.isMalformed && $0.date >= since }
    }

    /// True when the file still carries the modification stamp recorded with the stored checkpoint.
    private func isUnchanged(at url: URL, key: String) -> Bool {
        guard let recorded = tailStamps[key], let live = Self.modificationStamp(at: url) else {
            return false
        }
        return recorded == live
    }

    private func noteTailCheckpoint(
        for key: String,
        validatedStamp: ModificationStamp
    ) {
        tailStamps[key] = validatedStamp
    }

    private func rememberFutureTimestamp(
        _ timestamp: Date,
        path: String,
        url: URL,
        revision: AppendOnlyFileRevision,
        modificationStamp: ModificationStamp?,
        accountPolicyFingerprint: String
    ) {
        guard let modificationStamp,
              AppendOnlyFileProbe.revision(at: url) == revision,
              Self.modificationStamp(at: url) == modificationStamp,
              let anchor = AppendOnlyFileProbe.anchor(at: url, endingAt: revision.size),
              AppendOnlyFileProbe.revision(at: url) == revision,
              Self.modificationStamp(at: url) == modificationStamp,
              AppendOnlyFileProbe.anchor(at: url, endingAt: revision.size) == anchor
        else { return }
        futureTimestampMarkers[path] = FutureTimestampMarker(
            revision: revision,
            modificationStamp: modificationStamp,
            anchor: anchor,
            accountPolicyFingerprint: accountPolicyFingerprint,
            timestamp: timestamp
        )
        if futureTimestampMarkers.count > Self.maxCompactAggregates,
           let victim = futureTimestampMarkers.keys.first(where: { $0 != path }) {
            futureTimestampMarkers[victim] = nil
        }
    }

    private func sourceSnapshotLocked(atPath path: String) -> SourceSnapshot? {
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let key = url.path
        if let aggregate = aggregates[key] {
            return aggregate.sourceSnapshot
        }
        guard let entry = Self.tailCache.entry(for: key),
              let stamp = tailStamps[key]
        else { return nil }
        return SourceSnapshot(
            revision: entry.revision,
            offset: entry.offset,
            anchor: entry.anchor,
            modificationStamp: stamp
        )
    }

    static func modificationStamp(at url: URL) -> ModificationStamp? {
        var value = stat()
        let path = url.resolvingSymlinksInPath().path
        guard Darwin.lstat(path, &value) == 0 else { return nil }
        return ModificationStamp(
            seconds: Int64(value.st_mtimespec.tv_sec),
            nanoseconds: Int64(value.st_mtimespec.tv_nsec),
            changeSeconds: Int64(value.st_ctimespec.tv_sec),
            changeNanoseconds: Int64(value.st_ctimespec.tv_nsec)
        )
    }

    private static func accountPolicyFingerprint(
        enabledIdentityKeys: Set<String>?,
        identifiersToIdentityKeys: [String: String]
    ) -> String {
        let enabled = enabledIdentityKeys.map { $0.map { $0.lowercased() }.sorted().joined(separator: ",") } ?? "all"
        let identifiers = identifiersToIdentityKeys
            .map { ($0.key.lowercased(), $0.value.lowercased()) }
            .sorted { $0.0 < $1.0 }
            .map { "\($0.0)=\($0.1)" }
            .joined(separator: ",")
        return JSONLScanCachePaths.stableFingerprint("enabled=\(enabled)|identifiers=\(identifiers)")
    }

    private static func shouldCheckFuture(
        accountId: String?,
        accountFingerprint: String?,
        enabledIdentityKeys: Set<String>?,
        identifiersToIdentityKeys: [String: String]
    ) -> Bool {
        guard let enabledIdentityKeys else { return true }
        guard let identity = OpenCodeUsageScanner.routerAccountIdentityKey(
            accountId: accountId,
            accountFingerprint: accountFingerprint,
            identifiersToIdentityKeys: identifiersToIdentityKeys
        ) else {
            // Missing, unknown, or conflicting account identifiers remain additive and must still
            // pass source completeness checks.
            return true
        }
        return enabledIdentityKeys.contains(identity)
    }

    private func discardAggregate(
        for key: String,
        matching expected: OpenCodeRouterLedger.SourceSnapshot
    ) {
        aggregates[key] = nil
        OpenCodeRouterLedgerAggregate.removePersistedAggregate(path: key, matching: expected)
    }

    private func storeAggregate(
        _ aggregate: OpenCodeRouterLedgerAggregate,
        for key: String
    ) {
        aggregates[key] = aggregate
        guard aggregates.count > Self.maxCompactAggregates,
              let victim = aggregates.keys.first(where: { $0 != key })
        else { return }
        aggregates[victim] = nil
    }

    private func readAppend(
        at url: URL,
        key: String,
        current: AppendOnlyFileRevision,
        cached: AppendOnlyFileTailCache<OpenCodeUsageScanner.ClaudeGatewayRow, ParserCheckpoint>.Entry,
        initialStamp: ModificationStamp?,
        retentionCutoff: Date,
        maximumTimestamp: Date,
        shouldCheckFuture: (OpenCodeUsageScanner.ClaudeGatewayRow) -> Bool,
        futureTimestamp: inout Date?
    ) -> [OpenCodeUsageScanner.ClaudeGatewayRow]? {
        var appended: [OpenCodeUsageScanner.ClaudeGatewayRow] = []
        var rejectedFutureTimestamp: Date?
        var timestampCache = CodexRouterEventLineParser.TimestampCache()
        var malformedLine = false
        var read = JSONLFileReader.readLines(
            at: url,
            chunkSize: 64 * 1024,
            startOffset: cached.offset,
            initialCarry: cached.partialLine,
            discardingOversizedLine: cached.isDiscardingOversizedLine,
            deliverFinalPartial: false
        ) { line in
            switch Self.parseRow(
                from: line,
                timestampCache: &timestampCache,
                maximumTimestamp: maximumTimestamp,
                shouldCheckFuture: shouldCheckFuture
            ) {
            case .row(let row) where row.isMalformed || row.date >= retentionCutoff: appended.append(row)
            case .row, .irrelevant: break
            case .futureTimestamp(let timestamp):
                if rejectedFutureTimestamp.map({ timestamp > $0 }) ?? true {
                    rejectedFutureTimestamp = timestamp
                }
            case .malformed: malformedLine = true
            }
        }
        guard read.isComplete, !malformedLine else { return nil }

        // A writer may close a complete final object without a newline. The parser validates the
        // whole `{...}` object before accepting it; an incomplete object stays in `partialLine`.
        if !read.finalPartial.isEmpty,
           CodexRouterEventLineParser.looksLikeCompleteObject(read.finalPartial[...]) {
            switch Self.parseRow(
                from: read.finalPartial[...],
                timestampCache: &timestampCache,
                maximumTimestamp: maximumTimestamp,
                shouldCheckFuture: shouldCheckFuture
            ) {
            case .row(let row) where row.isMalformed || row.date >= retentionCutoff:
                appended.append(row)
                read.finalPartial = Data()
            case .row, .irrelevant:
                read.finalPartial = Data()
            case .futureTimestamp(let timestamp):
                if rejectedFutureTimestamp.map({ timestamp > $0 }) ?? true {
                    rejectedFutureTimestamp = timestamp
                }
                read.finalPartial = Data()
            case .malformed:
                return nil
            }
        }

        let newOffset = cached.offset + UInt64(max(0, read.statistics.bytesRead))
        guard let initialStamp,
              let after = AppendOnlyFileProbe.revision(at: url),
              after.device == current.device,
              after.inode == current.inode,
              after.size == newOffset,
              let afterStamp = Self.modificationStamp(at: url),
              afterStamp == initialStamp,
              let anchor = AppendOnlyFileProbe.anchor(at: url, endingAt: newOffset)
        else { return nil }

        if let rejectedFutureTimestamp {
            futureTimestamp = rejectedFutureTimestamp
            return nil
        }

        let retained = cached.items.filter { $0.isMalformed || $0.date >= retentionCutoff } + appended
        Self.tailCache.store(
            AppendOnlyFileTailCache<OpenCodeUsageScanner.ClaudeGatewayRow, ParserCheckpoint>.Entry(
                revision: after,
                offset: newOffset,
                anchor: anchor,
                partialLine: read.finalPartial,
                isDiscardingOversizedLine: read.isDiscardingOversizedLine,
                parserState: ParserCheckpoint(),
                items: retained
            ),
            for: key,
            parseKind: .tail,
            bytesRead: read.statistics.bytesRead
        )
        noteTailCheckpoint(for: key, validatedStamp: afterStamp)
        return retained
    }

    private func readWholeFile(
        at url: URL,
        key: String,
        retentionCutoff: Date,
        maximumTimestamp: Date,
        shouldCheckFuture: (OpenCodeUsageScanner.ClaudeGatewayRow) -> Bool,
        futureTimestamp: inout Date?
    ) -> [OpenCodeUsageScanner.ClaudeGatewayRow]? {
        guard let before = AppendOnlyFileProbe.revision(at: url),
              let beforeStamp = Self.modificationStamp(at: url)
        else { return nil }
        // Compact immediately once the file is large enough that retaining every parsed row would make
        // menu-bar memory scale with total history instead of the display window.
        if before.size > 1_048_576 {
            return readWholeFileCompact(
                at: url,
                key: key,
                revision: before,
                modificationStamp: beforeStamp,
                retentionCutoff: retentionCutoff,
                detailedGoCutoff: Date().addingTimeInterval(-45 * 86_400),
                maximumTimestamp: maximumTimestamp,
                shouldCheckFuture: shouldCheckFuture,
                futureTimestamp: &futureTimestamp
            )
        }

        var rows: [OpenCodeUsageScanner.ClaudeGatewayRow] = []
        var rejectedFutureTimestamp: Date?
        var timestampCache = CodexRouterEventLineParser.TimestampCache()
        var malformedLine = false
        var read = JSONLFileReader.readLines(
            at: url,
            chunkSize: 64 * 1024,
            deliverFinalPartial: false
        ) { line in
            switch Self.parseRow(
                from: line,
                timestampCache: &timestampCache,
                maximumTimestamp: maximumTimestamp,
                shouldCheckFuture: shouldCheckFuture
            ) {
            case .row(let row) where row.isMalformed || row.date >= retentionCutoff: rows.append(row)
            case .row, .irrelevant: break
            case .futureTimestamp(let timestamp):
                if rejectedFutureTimestamp.map({ timestamp > $0 }) ?? true {
                    rejectedFutureTimestamp = timestamp
                }
            case .malformed: malformedLine = true
            }
        }
        guard read.isComplete, !malformedLine else { return nil }
        if !read.finalPartial.isEmpty,
           CodexRouterEventLineParser.looksLikeCompleteObject(read.finalPartial[...]) {
            switch Self.parseRow(
                from: read.finalPartial[...],
                timestampCache: &timestampCache,
                maximumTimestamp: maximumTimestamp,
                shouldCheckFuture: shouldCheckFuture
            ) {
            case .row(let row) where row.isMalformed || row.date >= retentionCutoff:
                rows.append(row)
                read.finalPartial = Data()
            case .row, .irrelevant:
                read.finalPartial = Data()
            case .futureTimestamp(let timestamp):
                if rejectedFutureTimestamp.map({ timestamp > $0 }) ?? true {
                    rejectedFutureTimestamp = timestamp
                }
                read.finalPartial = Data()
            case .malformed:
                return nil
            }
        }

        let offset = UInt64(max(0, read.statistics.bytesRead))
        guard let revision = AppendOnlyFileProbe.revision(at: url),
              revision == before,
              revision.size == offset,
              let afterStamp = Self.modificationStamp(at: url),
              afterStamp == beforeStamp,
              let anchor = AppendOnlyFileProbe.anchor(at: url, endingAt: offset)
        else { return nil }

        if let rejectedFutureTimestamp {
            futureTimestamp = rejectedFutureTimestamp
            return nil
        }

        Self.tailCache.store(
            AppendOnlyFileTailCache<OpenCodeUsageScanner.ClaudeGatewayRow, ParserCheckpoint>.Entry(
                revision: revision,
                offset: offset,
                anchor: anchor,
                partialLine: read.finalPartial,
                isDiscardingOversizedLine: read.isDiscardingOversizedLine,
                parserState: ParserCheckpoint(),
                items: rows
            ),
            for: key,
            parseKind: .full,
            bytesRead: read.statistics.bytesRead
        )
        noteTailCheckpoint(for: key, validatedStamp: afterStamp)
        return rows
    }

    private func readWholeFileCompact(
        at url: URL,
        key: String,
        revision: AppendOnlyFileRevision,
        modificationStamp: ModificationStamp,
        retentionCutoff: Date,
        detailedGoCutoff: Date,
        maximumTimestamp: Date,
        shouldCheckFuture: (OpenCodeUsageScanner.ClaudeGatewayRow) -> Bool,
        futureTimestamp: inout Date?
    ) -> [OpenCodeUsageScanner.ClaudeGatewayRow]? {
        let aggregate = OpenCodeRouterLedgerAggregate.empty(
            path: key,
            revision: revision,
            modificationStamp: modificationStamp,
            detailedGoCutoff: detailedGoCutoff
        )
        var timestampCache = CodexRouterEventLineParser.TimestampCache()
        var rejectedFutureTimestamp: Date?
        var malformedLine = false
        var read = JSONLFileReader.readLines(
            at: url,
            chunkSize: 256 * 1024,
            deliverFinalPartial: false
        ) { line in
            switch Self.parseRow(
                from: line,
                timestampCache: &timestampCache,
                maximumTimestamp: maximumTimestamp,
                shouldCheckFuture: shouldCheckFuture
            ) {
            case .row(let row) where row.isMalformed || row.date >= retentionCutoff:
                aggregate.addRow(row, compactGoBefore: detailedGoCutoff)
            case .row, .irrelevant: break
            case .futureTimestamp(let timestamp):
                if rejectedFutureTimestamp.map({ timestamp > $0 }) ?? true {
                    rejectedFutureTimestamp = timestamp
                }
            case .malformed: malformedLine = true
            }
        }
        guard read.isComplete, !malformedLine else { return nil }
        if !read.finalPartial.isEmpty,
           CodexRouterEventLineParser.looksLikeCompleteObject(read.finalPartial[...]) {
            switch Self.parseRow(
                from: read.finalPartial[...],
                timestampCache: &timestampCache,
                maximumTimestamp: maximumTimestamp,
                shouldCheckFuture: shouldCheckFuture
            ) {
            case .row(let row) where row.isMalformed || row.date >= retentionCutoff:
                aggregate.addRow(row, compactGoBefore: detailedGoCutoff)
                read.finalPartial = Data()
            case .row, .irrelevant:
                read.finalPartial = Data()
            case .futureTimestamp(let timestamp):
                if rejectedFutureTimestamp.map({ timestamp > $0 }) ?? true {
                    rejectedFutureTimestamp = timestamp
                }
                read.finalPartial = Data()
            case .malformed:
                return nil
            }
        }

        let offset = UInt64(max(0, read.statistics.bytesRead))
        guard let after = AppendOnlyFileProbe.revision(at: url),
              after == revision,
              after.size == offset,
              Self.modificationStamp(at: url) == modificationStamp,
              let anchor = AppendOnlyFileProbe.anchor(at: url, endingAt: offset)
        else { return nil }

        if let rejectedFutureTimestamp {
            futureTimestamp = rejectedFutureTimestamp
            return nil
        }

        aggregate.seal(
            revision: after,
            offset: offset,
            partial: read.finalPartial,
            discarding: read.isDiscardingOversizedLine,
            anchor: anchor,
            modificationStamp: modificationStamp
        )
        _ = aggregate.prune(before: retentionCutoff, detailedGoCutoff: detailedGoCutoff)
        storeAggregate(aggregate, for: key)
        aggregate.save()
        Self.tailCache.store(
            AppendOnlyFileTailCache<OpenCodeUsageScanner.ClaudeGatewayRow, ParserCheckpoint>.Entry(
                revision: after,
                offset: offset,
                anchor: anchor,
                partialLine: read.finalPartial,
                isDiscardingOversizedLine: read.isDiscardingOversizedLine,
                parserState: ParserCheckpoint(),
                items: []
            ),
            for: key,
            parseKind: .full,
            bytesRead: read.statistics.bytesRead,
            retainItems: false
        )
        noteTailCheckpoint(for: key, validatedStamp: modificationStamp)
        return aggregate.materializeLatest(since: retentionCutoff)
    }
}
