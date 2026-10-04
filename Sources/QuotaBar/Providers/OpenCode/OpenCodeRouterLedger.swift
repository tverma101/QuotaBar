import Foundation

/// Reads the OpenCode-owned slice of CodexRouter's append-only usage ledger.
///
/// Small ledgers keep individual rows for exact tests and short-lived history. Large ledgers fold
/// immediately into `OpenCodeRouterLedgerAggregate`, so a tap materializes a few dozen day/model rows
/// instead of replaying tens of megabytes of JSON. Both modes share one append checkpoint and reject
/// truncate/regrow or same-size replacement by device/inode plus a prefix anchor.
final class OpenCodeRouterLedger: @unchecked Sendable {
    static let shared = OpenCodeRouterLedger()

    /// Keep enough history for the 30-day display window plus small clock/window changes.
    static let retentionDays = 45
    private static let retentionInterval = Double(retentionDays) * 86_400

    private struct ParserCheckpoint: Sendable, Equatable {}

    private static let tailCache = AppendOnlyFileTailCache<OpenCodeUsageScanner.ClaudeGatewayRow, ParserCheckpoint>(
        maxEntries: 8,
        maxRetainedItems: 64_000
    )

    private static let maxCompactAggregates = 8

    private let lock = NSLock()
    /// Compact aggregates are tiny; the cap bounds long-running processes that watch rotating ledgers.
    /// Instance-owned and always accessed under `lock` so no shared mutable static state is needed.
    private var aggregates: [String: OpenCodeRouterLedgerAggregate] = [:]
    /// Modification stamp captured whenever a small-ledger tail checkpoint is stored. The tail cache entry
    /// itself carries no timestamp, and the sampled prefix anchor cannot prove that bytes before the
    /// offset are unchanged, so an unchanged length with a changed stamp has to be treated as a rewrite.
    private var tailStamps: [String: Stamp] = [:]

    private struct Stamp: Equatable {
        var seconds: Int64
        var nanoseconds: Int64
    }

    func rows(atPath path: String, since: Date) -> [OpenCodeUsageScanner.ClaudeGatewayRow] {
        // Only the ledger read is unpaced. The provider-wide pacer stays on for SQLite, Claude/Codex,
        // Hermes, and Muse work; pacing a cold tens-of-MB read at 7.5% used to exceed the deadline and
        // restart from zero on the next tap.
        ProviderRefreshContext.$accountingCPUThrottleEnabled.withValue(false) {
            lock.withLock { rowsLocked(atPath: path, since: since) }
        }
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
        // Cheap reject before the full parse. The router meters every provider it fronts, so most lines
        // in a shared ledger belong to other accounts; skipping them on a byte scan keeps the cold read
        // from decoding timestamp/model/account fields for rows that would be discarded anyway.
        // Case-insensitive because `isOpenCodeServed` lowercases the provider first, so `OpenCode-Go`
        // still has to reach the parser. One-directional on purpose: a false positive costs a wasted
        // parse, a false negative would drop real usage.
        guard mayNameOpenCodeProvider(line) else { return nil }
        guard let event = CodexRouterEventLineParser.parse(line, timestampCache: &timestampCache) else {
            return nil
        }
        return row(from: event)
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
    /// OpenCode-served rows, and `OpenCodeUsageScanner.scan` reads this ledger first so it can hand the
    /// covered (day, model) pairs to every native fold as a skip set (`OpenCodeUsageScanner.dayModelKey`).
    /// The router then wins the pairs it covers and native fills only the gaps — one turn, one count.
    static func row(from event: CodexRouterUsageScanner.Event) -> OpenCodeUsageScanner.ClaudeGatewayRow? {
        guard CodexRouterUsageScanner.isOpenCodeServed(event),
              CodexRouterUsageScanner.isSuccessfulStatus(event.status)
        else { return nil }

        let input = max(0, event.inputTokens)
        let cached = min(max(0, event.cachedInputTokens), input)
        let model = OpenCodeUsageScanner.bareRouterModelName(event.model)
        guard !model.isEmpty else { return nil }
        return OpenCodeUsageScanner.ClaudeGatewayRow(
            date: event.timestamp,
            input: input - cached,
            output: max(0, event.outputTokens),
            cacheWrite: 0,
            cacheRead: cached,
            model: model,
            // Only the Go subscription's cap meters are consumed by `opencode-go`; Zen and free tiers
            // are billed outside those caps.
            burnsGoQuota: event.provider.lowercased().hasPrefix("opencode-go"),
            isInProgress: false
        )
    }

    private func rowsLocked(atPath path: String, since: Date) -> [OpenCodeUsageScanner.ClaudeGatewayRow] {
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let key = url.path
        guard let current = AppendOnlyFileProbe.revision(at: url) else {
            Self.tailCache.remove(key)
            tailStamps[key] = nil
            discardAggregate(for: key)
            return []
        }

        let retentionCutoff = Date().addingTimeInterval(-Self.retentionInterval)
        if let aggregate = aggregates[key] ?? OpenCodeRouterLedgerAggregate.load(path: key) {
            if aggregate.prune(before: retentionCutoff) {
                aggregate.save()
            }
            storeAggregate(aggregate, for: key)
            switch aggregate.reconcile(url: url, current: current, since: since) {
            case .rows(let rows):
                return rows
            case .stale:
                // Rotation, truncate/regrow, or in-place rewrite. Drop the checkpoint AND its compact
                // file: a persisted aggregate that can never reconcile would otherwise be decoded on
                // every launch and rejected again on every refresh.
                discardAggregate(for: key)
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
                return cached.items.filter { $0.date >= since }
            }

            if current.size > cached.offset, cached.itemsAvailable,
               let rows = readAppend(
                at: url,
                key: key,
                current: current,
                cached: cached,
                retentionCutoff: retentionCutoff
               ) {
                return rows.filter { $0.date >= since }
            }
        }

        guard let rows = readWholeFile(at: url, key: key, retentionCutoff: retentionCutoff) else {
            return []
        }
        return rows.filter { $0.date >= since }
    }

    /// True when the file still carries the modification stamp recorded with the stored checkpoint.
    private func isUnchanged(at url: URL, key: String) -> Bool {
        guard let recorded = tailStamps[key], let live = Self.modificationStamp(at: url) else {
            return false
        }
        return recorded == live
    }

    private func noteTailCheckpoint(at url: URL, for key: String) {
        tailStamps[key] = Self.modificationStamp(at: url)
    }

    private static func modificationStamp(at url: URL) -> Stamp? {
        var value = stat()
        let path = url.resolvingSymlinksInPath().path
        guard Darwin.lstat(path, &value) == 0 else { return nil }
        return Stamp(
            seconds: Int64(value.st_mtimespec.tv_sec),
            nanoseconds: Int64(value.st_mtimespec.tv_nsec)
        )
    }

    private func discardAggregate(for key: String) {
        aggregates[key] = nil
        OpenCodeRouterLedgerAggregate.removePersistedAggregate(path: key)
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
        retentionCutoff: Date
    ) -> [OpenCodeUsageScanner.ClaudeGatewayRow]? {
        var appended: [OpenCodeUsageScanner.ClaudeGatewayRow] = []
        var timestampCache = CodexRouterEventLineParser.TimestampCache()
        var read = JSONLFileReader.readLines(
            at: url,
            chunkSize: 64 * 1024,
            startOffset: cached.offset,
            initialCarry: cached.partialLine,
            discardingOversizedLine: cached.isDiscardingOversizedLine,
            deliverFinalPartial: false
        ) { line in
            if let row = Self.row(from: line, timestampCache: &timestampCache), row.date >= retentionCutoff {
                appended.append(row)
            }
        }
        guard read.succeeded else { return nil }

        // A writer may close a complete final object without a newline. The parser validates the
        // whole `{...}` object before accepting it; an incomplete object stays in `partialLine`.
        if !read.finalPartial.isEmpty,
           let row = Self.row(
            from: read.finalPartial[...],
            timestampCache: &timestampCache
           ),
           row.date >= retentionCutoff {
            appended.append(row)
            read.finalPartial = Data()
        }

        let newOffset = cached.offset + UInt64(max(0, read.statistics.bytesRead))
        guard let after = AppendOnlyFileProbe.revision(at: url),
              after.device == current.device,
              after.inode == current.inode,
              after.size >= newOffset,
              let anchor = AppendOnlyFileProbe.anchor(at: url, endingAt: newOffset)
        else { return nil }

        let retained = cached.items.filter { $0.date >= retentionCutoff } + appended
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
        noteTailCheckpoint(at: url, for: key)
        return retained
    }

    private func readWholeFile(
        at url: URL,
        key: String,
        retentionCutoff: Date
    ) -> [OpenCodeUsageScanner.ClaudeGatewayRow]? {
        let before = AppendOnlyFileProbe.revision(at: url)
        // Compact immediately once the file is large enough that retaining every parsed row would make
        // menu-bar memory scale with total history instead of the display window.
        if let revision = before, revision.size > 1_048_576 {
            return readWholeFileCompact(
                at: url,
                key: key,
                revision: revision,
                retentionCutoff: retentionCutoff
            )
        }

        var rows: [OpenCodeUsageScanner.ClaudeGatewayRow] = []
        var timestampCache = CodexRouterEventLineParser.TimestampCache()
        var read = JSONLFileReader.readLines(
            at: url,
            chunkSize: 64 * 1024,
            deliverFinalPartial: false
        ) { line in
            if let row = Self.row(from: line, timestampCache: &timestampCache), row.date >= retentionCutoff {
                rows.append(row)
            }
        }
        guard read.succeeded else { return nil }
        if !read.finalPartial.isEmpty,
           let row = Self.row(
            from: read.finalPartial[...],
            timestampCache: &timestampCache
           ),
           row.date >= retentionCutoff {
            rows.append(row)
            read.finalPartial = Data()
        }

        let offset = UInt64(max(0, read.statistics.bytesRead))
        guard let revision = AppendOnlyFileProbe.revision(at: url),
              let before,
              revision.device == before.device,
              revision.inode == before.inode,
              revision.size >= offset,
              let anchor = AppendOnlyFileProbe.anchor(at: url, endingAt: offset)
        else { return rows }

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
        noteTailCheckpoint(at: url, for: key)
        return rows
    }

    private func readWholeFileCompact(
        at url: URL,
        key: String,
        revision: AppendOnlyFileRevision,
        retentionCutoff: Date
    ) -> [OpenCodeUsageScanner.ClaudeGatewayRow]? {
        let aggregate = OpenCodeRouterLedgerAggregate.empty(path: key, revision: revision)
        var timestampCache = CodexRouterEventLineParser.TimestampCache()
        var read = JSONLFileReader.readLines(
            at: url,
            chunkSize: 256 * 1024,
            deliverFinalPartial: false
        ) { line in
            if let row = Self.row(from: line, timestampCache: &timestampCache), row.date >= retentionCutoff {
                aggregate.addRow(row)
            }
        }
        guard read.succeeded else { return nil }
        if !read.finalPartial.isEmpty,
           let row = Self.row(
            from: read.finalPartial[...],
            timestampCache: &timestampCache
           ),
           row.date >= retentionCutoff {
            aggregate.addRow(row)
            read.finalPartial = Data()
        }

        let offset = UInt64(max(0, read.statistics.bytesRead))
        guard let after = AppendOnlyFileProbe.revision(at: url),
              after.device == revision.device,
              after.inode == revision.inode,
              after.size >= offset,
              let anchor = AppendOnlyFileProbe.anchor(at: url, endingAt: offset)
        else { return nil }

        aggregate.seal(
            revision: after,
            offset: offset,
            partial: read.finalPartial,
            discarding: read.isDiscardingOversizedLine,
            anchor: anchor
        )
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
        noteTailCheckpoint(at: url, for: key)
        return aggregate.materialize(since: retentionCutoff)
    }
}
