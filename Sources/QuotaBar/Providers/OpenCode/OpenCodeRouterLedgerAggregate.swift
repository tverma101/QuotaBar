import Foundation
import Darwin

/// Durable, compact view of the OpenCode-owned slice of one CodexRouter ledger.
///
/// The raw router ledger grows without bound and can reach tens of millions of tokens. Keeping every
/// OpenCode row resident made each menu-bar tap repeat work proportional to history, so this aggregate
/// stores only local-calendar day/model/account/measurement sums plus the individual Go rows still
/// needed by rolling cap meters. Non-Go rows materialize as a few dozen aggregated rows; long-context
/// pricing is disabled for those sums because one bucket is not one request.
final class OpenCodeRouterLedgerAggregate: @unchecked Sendable {
    private static let schema = 17
    /// Serialize aggregate-file mutations within the app process as well as across app/CLI processes.
    private static let aggregateFileMutationLock = NSLock()

    struct Bucket: Codable, Equatable, Sendable {
        var day: String
        var model: String
        var totalTokens: Int
        var input: Int
        var output: Int
        var cacheRead: Int
        var accountId: String? = nil
        var accountFingerprint: String? = nil
        var burnsGoQuota: Bool? = nil
        var routerInputWasEstimated: Bool? = nil
        var routerCostBreakdownIsComplete: Bool? = nil
        var tokenCountSaturated: Bool? = nil
    }

    struct GoRow: Codable, Equatable, Sendable {
        var date: TimeInterval
        var totalTokens: Int
        var input: Int
        var output: Int
        var cacheRead: Int
        var model: String
        var accountId: String? = nil
        var accountFingerprint: String? = nil
        var routerInputWasEstimated: Bool? = nil
        var routerCostBreakdownIsComplete: Bool? = nil
        var tokenCountSaturated: Bool? = nil
    }

    private struct AccountTimestamp: Codable, Equatable {
        var accountId: String?
        var accountFingerprint: String?
        var latestTimestamp: TimeInterval
        var hasMalformedRows: Bool
    }

    private struct File: Codable {
        var schema: Int
        var path: String
        var timeZoneIdentifier: String
        var device: UInt64
        var inode: UInt64
        var size: UInt64
        var modificationStamp: OpenCodeRouterLedger.ModificationStamp
        var detailedGoCutoff: TimeInterval
        var offset: UInt64
        var partial: Data
        var discarding: Bool
        var anchor: Data
        var latestAcceptedTimestamp: TimeInterval?
        var accountTimestamps: [AccountTimestamp]
        var buckets: [Bucket]
        var goRows: [GoRow]
    }

    private var bucketIndex: [String: Int] = [:]
    private var hasBucketIndex = false

    enum Reconcile {
        case rows([OpenCodeUsageScanner.ClaudeGatewayRow])
        /// The compact checkpoint retains a malformed row owned by an account that is now enabled.
        case malformed
        case stale
        /// The ledger could not be read this pass — the refresh was cancelled at the deadline, or a
        /// transient I/O error hit mid-read. Device, inode, size, mtime, ctime, and the prefix anchor all
        /// verified intact before the read failed, so this is not evidence of a rewrite: the caller
        /// must keep the aggregate (memory and persisted file) untouched and serve last-good data.
        /// Mapping a failed read to `.stale` here deleted the durable aggregate after every timed-out
        /// refresh, forcing the next refresh into a full cold rebuild of the whole ledger — which
        /// timed out too, in a self-sustaining loop.
        case aborted
        /// The unchanged ledger is already folded, but its latest accepted event is now beyond the
        /// caller's clock bound. Keep the aggregate for when the clock catches up instead of
        /// rebuilding the whole file on every refresh.
        case futureTimestamp(Date)
    }

    var path: String
    let timeZoneIdentifier: String
    var device: UInt64
    var inode: UInt64
    var size: UInt64
    var modificationStamp: OpenCodeRouterLedger.ModificationStamp
    var detailedGoCutoff: TimeInterval
    var offset: UInt64
    var partial: Data
    var discarding: Bool
    var anchor: Data
    var latestAcceptedTimestamp: TimeInterval?
    private var accountTimestamps: [AccountTimestamp]
    var buckets: [Bucket]
    var goRows: [GoRow]

    private init(file: File) {
        path = file.path
        timeZoneIdentifier = file.timeZoneIdentifier
        device = file.device
        inode = file.inode
        size = file.size
        modificationStamp = file.modificationStamp
        detailedGoCutoff = file.detailedGoCutoff
        offset = file.offset
        partial = file.partial
        discarding = file.discarding
        anchor = file.anchor
        latestAcceptedTimestamp = file.latestAcceptedTimestamp
        accountTimestamps = file.accountTimestamps
        buckets = file.buckets
        goRows = file.goRows
    }

    var sourceSnapshot: OpenCodeRouterLedger.SourceSnapshot {
        OpenCodeRouterLedger.SourceSnapshot(
            revision: AppendOnlyFileRevision(device: device, inode: inode, size: size),
            offset: offset,
            anchor: anchor,
            modificationStamp: modificationStamp
        )
    }

    /// Another process may compact this unchanged ledger while this process retains its in-memory
    /// aggregate. Adopt that newer checkpoint before materializing rows so detailed Go entries do
    /// not use per-request pricing after the persisted version moved them into daily buckets.
    func refreshFromPersistedIfNewer() {
        var persisted: OpenCodeRouterLedgerAggregate?
        _ = Self.withAggregateFileLock(path: path) {
            persisted = Self.loadUnlocked(path: path)
        }
        guard let persisted,
              persisted.sourceSnapshot == sourceSnapshot,
              persisted.timeZoneIdentifier == timeZoneIdentifier,
              persisted.detailedGoCutoff > detailedGoCutoff
        else { return }
        adopt(persisted)
    }

    private func adopt(_ other: OpenCodeRouterLedgerAggregate) {
        device = other.device
        inode = other.inode
        size = other.size
        modificationStamp = other.modificationStamp
        detailedGoCutoff = other.detailedGoCutoff
        offset = other.offset
        partial = other.partial
        discarding = other.discarding
        anchor = other.anchor
        latestAcceptedTimestamp = other.latestAcceptedTimestamp
        accountTimestamps = other.accountTimestamps
        buckets = other.buckets
        goRows = other.goRows
        bucketIndex.removeAll(keepingCapacity: true)
        hasBucketIndex = false
    }

    static func empty(
        path: String,
        revision: AppendOnlyFileRevision,
        modificationStamp: OpenCodeRouterLedger.ModificationStamp = .unavailable,
        detailedGoCutoff: Date = .distantPast
    ) -> OpenCodeRouterLedgerAggregate {
        OpenCodeRouterLedgerAggregate(file: File(
            schema: Self.schema,
            path: path,
            timeZoneIdentifier: Calendar.current.timeZone.identifier,
            device: revision.device,
            inode: revision.inode,
            size: revision.size,
            modificationStamp: modificationStamp,
            detailedGoCutoff: detailedGoCutoff.timeIntervalSince1970,
            offset: 0,
            partial: Data(),
            discarding: false,
            anchor: Data(),
            latestAcceptedTimestamp: nil,
            accountTimestamps: [],
            buckets: [],
            goRows: []
        ))
    }

    func seal(
        revision: AppendOnlyFileRevision,
        offset: UInt64,
        partial: Data,
        discarding: Bool,
        anchor: Data,
        modificationStamp: OpenCodeRouterLedger.ModificationStamp
    ) {
        size = revision.size
        self.offset = offset
        self.partial = partial
        self.discarding = discarding
        self.anchor = anchor
        self.modificationStamp = modificationStamp
    }

    func addRow(
        _ row: OpenCodeUsageScanner.ClaudeGatewayRow,
        compactGoBefore detailedGoCutoff: Date? = nil
    ) {
        latestAcceptedTimestamp = max(
            latestAcceptedTimestamp ?? row.date.timeIntervalSince1970,
            row.date.timeIntervalSince1970
        )
        recordLatestTimestamp(for: row)
        guard !row.isMalformed else { return }
        if row.burnsGoQuota {
            if let detailedGoCutoff, row.date < detailedGoCutoff {
                addBucket(
                    day: dayKey(for: row.date),
                    model: row.model,
                    totalTokens: row.tokens,
                    input: row.input,
                    output: row.output,
                    cacheRead: row.cacheRead,
                    accountId: row.accountId,
                    accountFingerprint: row.accountFingerprint,
                    burnsGoQuota: true,
                    routerInputWasEstimated: row.routerInputWasEstimated,
                    routerCostBreakdownIsComplete: row.routerCostBreakdownIsComplete,
                    tokenCountSaturated: row.tokenCountSaturated
                )
                return
            }
            goRows.append(GoRow(
                date: row.date.timeIntervalSince1970,
                totalTokens: row.tokens,
                input: row.input,
                output: row.output,
                cacheRead: row.cacheRead,
                model: row.model,
                accountId: row.accountId,
                accountFingerprint: row.accountFingerprint,
                routerInputWasEstimated: row.routerInputWasEstimated,
                routerCostBreakdownIsComplete: row.routerCostBreakdownIsComplete,
                tokenCountSaturated: row.tokenCountSaturated ? true : nil
            ))
            return
        }
        addBucket(
            day: dayKey(for: row.date),
            model: row.model,
            totalTokens: row.tokens,
            input: row.input,
            output: row.output,
            cacheRead: row.cacheRead,
            accountId: row.accountId,
            accountFingerprint: row.accountFingerprint,
            burnsGoQuota: false,
            routerInputWasEstimated: row.routerInputWasEstimated,
            routerCostBreakdownIsComplete: row.routerCostBreakdownIsComplete,
            tokenCountSaturated: row.tokenCountSaturated
        )
    }

    private func recordLatestTimestamp(for row: OpenCodeUsageScanner.ClaudeGatewayRow) {
        let timestamp = row.date.timeIntervalSince1970
        if let index = accountTimestamps.firstIndex(where: {
            $0.accountId == row.accountId && $0.accountFingerprint == row.accountFingerprint
        }) {
            accountTimestamps[index].latestTimestamp = max(accountTimestamps[index].latestTimestamp, timestamp)
            accountTimestamps[index].hasMalformedRows =
                accountTimestamps[index].hasMalformedRows || row.isMalformed
        } else {
            accountTimestamps.append(AccountTimestamp(
                accountId: row.accountId,
                accountFingerprint: row.accountFingerprint,
                latestTimestamp: timestamp,
                hasMalformedRows: row.isMalformed
            ))
        }
    }

    private func addBucket(
        day: String,
        model: String,
        totalTokens: Int,
        input: Int,
        output: Int,
        cacheRead: Int,
        accountId: String?,
        accountFingerprint: String?,
        burnsGoQuota: Bool?,
        routerInputWasEstimated: Bool?,
        routerCostBreakdownIsComplete: Bool?,
        tokenCountSaturated: Bool
    ) {
        let key = bucketKey(
            day: day,
            model: model,
            accountId: accountId,
            accountFingerprint: accountFingerprint,
            burnsGoQuota: burnsGoQuota,
            routerInputWasEstimated: routerInputWasEstimated,
            routerCostBreakdownIsComplete: routerCostBreakdownIsComplete
        )
        ensureBucketIndex()
        if let index = bucketIndex[key] {
            // Saturating: bounded external counts can still overflow when accumulated across rows.
            let overflowed = Self.wouldOverflow(buckets[index].input, adding: input)
                || Self.wouldOverflow(buckets[index].output, adding: output)
                || Self.wouldOverflow(buckets[index].cacheRead, adding: cacheRead)
                || Self.wouldOverflow(buckets[index].totalTokens, adding: totalTokens)
            buckets[index].input = ProviderParse.addingSaturating(buckets[index].input, input)
            buckets[index].output = ProviderParse.addingSaturating(buckets[index].output, output)
            buckets[index].cacheRead = ProviderParse.addingSaturating(buckets[index].cacheRead, cacheRead)
            buckets[index].totalTokens = ProviderParse.addingSaturating(buckets[index].totalTokens, totalTokens)
            if tokenCountSaturated || overflowed {
                buckets[index].tokenCountSaturated = true
            }
            if overflowed { buckets[index].routerCostBreakdownIsComplete = false }
        } else {
            bucketIndex[key] = buckets.count
            buckets.append(Bucket(
                day: day,
                model: model,
                totalTokens: totalTokens,
                input: input,
                output: output,
                cacheRead: cacheRead,
                accountId: accountId,
                accountFingerprint: accountFingerprint,
                burnsGoQuota: burnsGoQuota,
                routerInputWasEstimated: routerInputWasEstimated,
                routerCostBreakdownIsComplete: routerCostBreakdownIsComplete,
                tokenCountSaturated: tokenCountSaturated ? true : nil
            ))
        }
    }

    private static func wouldOverflow(_ current: Int, adding value: Int) -> Bool {
        value > 0 && current > Int.max - value
    }

    func reconcile(
        url: URL,
        current: AppendOnlyFileRevision,
        since: Date,
        detailedGoCutoff: Date,
        maximumTimestamp: Date,
        shouldCheckFuture: @escaping (String?, String?) -> Bool = { _, _ in true }
    ) -> Reconcile {
        guard current.device == device, current.inode == inode else { return .stale }
        let maximumTimestampValue = maximumTimestamp.timeIntervalSince1970
        let futureAcceptedTimestamp = accountTimestamps
            .filter { shouldCheckFuture($0.accountId, $0.accountFingerprint) }
            .map(\.latestTimestamp)
            .filter { $0 > maximumTimestampValue }
            .max()
        .map(Date.init(timeIntervalSince1970:))
        guard let freshStamp = OpenCodeRouterLedger.modificationStamp(at: url) else { return .stale }
        if current.size == offset, current.size == size {
            guard AppendOnlyFileProbe.anchor(at: url, endingAt: offset) == anchor else { return .stale }
            if freshStamp != modificationStamp {
                // Same length, new timestamp: an in-place rewrite anywhere in the file is possible, and
                // the sampled prefix anchor cannot prove earlier events are intact. Rebuild rather than
                // trust the folded totals — same policy as the Codex router aggregate index.
                return .stale
            }
            guard !hasMalformedEnabledAccount(shouldCheckFuture: shouldCheckFuture) else { return .malformed }
            if let futureAcceptedTimestamp { return .futureTimestamp(futureAcceptedTimestamp) }
            guard let rows = materializeLatest(since: since) else { return .aborted }
            return .rows(rows)
        }

        // Truncate or replace: the caller rebuilds. Growth reads only the tail below.
        guard current.size > offset,
              AppendOnlyFileProbe.anchor(at: url, endingAt: offset) == anchor
        else { return .stale }
        guard !hasMalformedEnabledAccount(shouldCheckFuture: shouldCheckFuture) else { return .malformed }
        // The old prefix still contains a future-dated contribution. The append is verified, but
        // materializing it would retain that future contribution in compact day/model buckets.
        if let futureAcceptedTimestamp { return .futureTimestamp(futureAcceptedTimestamp) }

        var timestampCache = CodexRouterEventLineParser.TimestampCache()
        var appended: [OpenCodeUsageScanner.ClaudeGatewayRow] = []
        var rejectedFutureTimestamp: Date?
        var malformedLine = false
        var read = JSONLFileReader.readLines(
            at: url,
            chunkSize: 256 * 1024,
            startOffset: offset,
            initialCarry: partial,
            discardingOversizedLine: discarding,
            deliverFinalPartial: false
        ) { line in
            switch OpenCodeRouterLedger.parseRow(
                from: line,
                timestampCache: &timestampCache,
                maximumTimestamp: maximumTimestamp,
                shouldCheckFuture: { row in
                    shouldCheckFuture(row.accountId, row.accountFingerprint)
                }
            ) {
            case .row(let row): appended.append(row)
            case .irrelevant: break
            case .futureTimestamp(let timestamp):
                if rejectedFutureTimestamp.map({ timestamp > $0 }) ?? true {
                    rejectedFutureTimestamp = timestamp
                }
            case .malformed: malformedLine = true
            }
        }
        // A cancelled read (deadline hit) or transient I/O error says nothing about the ledger's
        // contents — every identity check above already passed. Report an abort, not staleness.
        guard read.isComplete, !malformedLine else { return .aborted }
        if !read.finalPartial.isEmpty,
           CodexRouterEventLineParser.looksLikeCompleteObject(read.finalPartial[...]) {
            switch OpenCodeRouterLedger.parseRow(
                from: read.finalPartial[...],
                timestampCache: &timestampCache,
                maximumTimestamp: maximumTimestamp,
                shouldCheckFuture: { row in
                    shouldCheckFuture(row.accountId, row.accountFingerprint)
                }
            ) {
            case .row(let row):
                appended.append(row)
                read.finalPartial = Data()
            case .irrelevant:
                read.finalPartial = Data()
            case .futureTimestamp(let timestamp):
                if rejectedFutureTimestamp.map({ timestamp > $0 }) ?? true {
                    rejectedFutureTimestamp = timestamp
                }
                read.finalPartial = Data()
            case .malformed:
                return .aborted
            }
        }

        let newOffset = offset + UInt64(max(0, read.statistics.bytesRead))
        guard let after = AppendOnlyFileProbe.revision(at: url),
              after.device == device,
              after.inode == inode,
              after.size == newOffset,
              let newAnchor = AppendOnlyFileProbe.anchor(at: url, endingAt: newOffset),
              OpenCodeRouterLedger.modificationStamp(at: url) == freshStamp
        else { return .stale }

        if let rejectedFutureTimestamp { return .futureTimestamp(rejectedFutureTimestamp) }

        absorb(appended, compactGoBefore: detailedGoCutoff)
        OpenCodeRouterLedger.noteCompactTail(path: path, bytesRead: read.statistics.bytesRead)
        offset = newOffset
        size = after.size
        partial = read.finalPartial
        discarding = read.isDiscardingOversizedLine
        anchor = newAnchor
        // Revalidate after folding too. A rewrite during absorb must not be recorded as the
        // revision represented by these rows; save() and the scanner's final validation then
        // compare against the stamp that was actually validated around the read.
        guard let finalRevision = AppendOnlyFileProbe.revision(at: url),
              finalRevision.device == after.device,
              finalRevision.inode == after.inode,
              finalRevision.size == after.size,
              AppendOnlyFileProbe.anchor(at: url, endingAt: newOffset) == newAnchor,
              OpenCodeRouterLedger.modificationStamp(at: url) == freshStamp
        else { return .stale }
        modificationStamp = freshStamp
        // The router logs other providers' traffic too, so most refreshes advance the offset while
        // absorbing nothing. Only rewrite the compact file when its contents actually changed.
        if !appended.isEmpty {
            save()
        }
        guard let rows = materializeLatest(since: since) else { return .aborted }
        return .rows(rows)
    }

    /// Read the latest same-source cutoff and materialize while holding the sidecar lock. A refresh
    /// before pruning alone leaves a race where another process compacts after that read but before
    /// these rows are emitted.
    func materializeLatest(since: Date) -> [OpenCodeUsageScanner.ClaudeGatewayRow]? {
        Self.withAggregateFileLock(path: path) {
            if let persisted = Self.loadUnlocked(path: path),
               persisted.sourceSnapshot == sourceSnapshot,
               persisted.timeZoneIdentifier == timeZoneIdentifier,
               persisted.detailedGoCutoff > detailedGoCutoff
            {
                adopt(persisted)
            }
            return materialize(since: since)
        }
    }

    private func hasMalformedEnabledAccount(
        shouldCheckFuture: (String?, String?) -> Bool
    ) -> Bool {
        accountTimestamps.contains {
            $0.hasMalformedRows && shouldCheckFuture($0.accountId, $0.accountFingerprint)
        }
    }

    func materialize(since: Date) -> [OpenCodeUsageScanner.ClaudeGatewayRow] {
        var rows: [OpenCodeUsageScanner.ClaudeGatewayRow] = []
        rows.reserveCapacity(buckets.count + goRows.count)
        // A bucket is a whole local day. The fold always passes a local-midnight cutoff, so including the
        // whole boundary day matches the per-row path exactly; for any other cutoff, keeping the day is
        // the conservative choice — it can over-count part of one day rather than dropping real usage.
        let cutoffDay = dayKey(for: since)
        for bucket in buckets.sorted(by: { ($0.day, $0.model) < ($1.day, $1.model) }) {
            guard bucket.day >= cutoffDay,
                  let date = Self.noon(bucket.day, timeZoneIdentifier: timeZoneIdentifier)
            else {
                continue
            }
            rows.append(OpenCodeUsageScanner.ClaudeGatewayRow(
                date: date,
                input: bucket.input,
                output: bucket.output,
                cacheWrite: 0,
                cacheRead: bucket.cacheRead,
                model: bucket.model,
                totalTokens: bucket.totalTokens,
                burnsGoQuota: bucket.burnsGoQuota == true,
                isInProgress: false,
                isAggregated: true,
                accountId: bucket.accountId,
                accountFingerprint: bucket.accountFingerprint,
                routerInputWasEstimated: bucket.routerInputWasEstimated,
                routerCostBreakdownIsComplete: bucket.routerCostBreakdownIsComplete,
                tokenCountSaturated: bucket.tokenCountSaturated == true
            ))
        }
        for row in goRows.sorted(by: { $0.date < $1.date }) {
            let date = Date(timeIntervalSince1970: row.date)
            guard date >= since else { continue }
            rows.append(OpenCodeUsageScanner.ClaudeGatewayRow(
                date: date,
                input: row.input,
                output: row.output,
                cacheWrite: 0,
                cacheRead: row.cacheRead,
                model: row.model,
                totalTokens: row.totalTokens,
                burnsGoQuota: true,
                isInProgress: false,
                accountId: row.accountId,
                accountFingerprint: row.accountFingerprint,
                routerInputWasEstimated: row.routerInputWasEstimated,
                routerCostBreakdownIsComplete: row.routerCostBreakdownIsComplete,
                tokenCountSaturated: row.tokenCountSaturated == true
            ))
        }
        return rows
    }

    /// Keep exact timestamps for recent Go cap meters, while folding older Go turns to day/model
    /// buckets for lifetime history. Drop rows older than the retained history window.
    @discardableResult
    func prune(before cutoff: Date, detailedGoCutoff: Date) -> Bool {
        self.detailedGoCutoff = max(self.detailedGoCutoff, detailedGoCutoff.timeIntervalSince1970)
        let cutoffDay = dayKey(for: cutoff)
        let oldBucketCount = buckets.count
        buckets.removeAll { $0.day < cutoffDay }
        if buckets.count != oldBucketCount {
            hasBucketIndex = false
        }
        let oldGoCount = goRows.count
        let oldGoRows = goRows.filter {
            let date = Date(timeIntervalSince1970: $0.date)
            return date >= cutoff && date < detailedGoCutoff
        }
        goRows.removeAll { Date(timeIntervalSince1970: $0.date) < detailedGoCutoff }
        for row in oldGoRows {
            addBucket(
                day: dayKey(for: Date(timeIntervalSince1970: row.date)),
                model: row.model,
                totalTokens: row.totalTokens,
                input: row.input,
                output: row.output,
                cacheRead: row.cacheRead,
                accountId: row.accountId,
                accountFingerprint: row.accountFingerprint,
                burnsGoQuota: true,
                routerInputWasEstimated: row.routerInputWasEstimated,
                routerCostBreakdownIsComplete: row.routerCostBreakdownIsComplete,
                tokenCountSaturated: row.tokenCountSaturated == true
            )
        }
        if buckets.count != oldBucketCount || goRows.count != oldGoCount {
            hasBucketIndex = false
            return true
        }
        return false
    }

    func save() {
        let saveFailureKey = Self.saveFailureKey(path: path)
        let url = Self.fileURL(path: path)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(File(
                schema: Self.schema,
                path: path,
                timeZoneIdentifier: timeZoneIdentifier,
                device: device,
                inode: inode,
                size: size,
                modificationStamp: modificationStamp,
                detailedGoCutoff: detailedGoCutoff,
                offset: offset,
                partial: partial,
                discarding: discarding,
                anchor: anchor,
                latestAcceptedTimestamp: latestAcceptedTimestamp,
                accountTimestamps: accountTimestamps,
                buckets: buckets,
                goRows: goRows
            ))
            guard let didSave = try Self.withAggregateFileLock(path: path, {
                // A scan can finish after another process has already advanced this cache. Check
                // the source while holding the sidecar lock so an old revision cannot overwrite or
                // roll back the newer process's durable aggregate.
                guard OpenCodeRouterLedger.sourceSnapshotIsCurrent(sourceSnapshot, atPath: path) else {
                    return false
                }
                if let current = Self.loadUnlocked(path: path), current.sourceSnapshot == sourceSnapshot,
                   current.timeZoneIdentifier == timeZoneIdentifier {
                    if current.buckets == buckets,
                       current.accountTimestamps == accountTimestamps,
                       current.goRows == goRows,
                       current.partial == partial,
                       current.discarding == discarding,
                       current.detailedGoCutoff == detailedGoCutoff {
                        return true
                    }
                    // The source is append-only and this cutoff only advances. If another process
                    // already pruned to a later cutoff, an older scan must not restore those rows.
                    if current.detailedGoCutoff > detailedGoCutoff {
                        adopt(current)
                        return true
                    }
                }
                if let current = Self.loadUnlocked(path: path),
                   current.timeZoneIdentifier == timeZoneIdentifier,
                   current.device == device,
                   current.inode == inode,
                   current.offset < offset,
                   current.size <= size,
                   current.detailedGoCutoff > detailedGoCutoff,
                   AppendOnlyFileProbe.anchor(
                    at: URL(fileURLWithPath: path),
                    endingAt: current.offset
                   ) == current.anchor {
                    // A concurrent writer compacted the old revision while this process tailed a
                    // real append. Keep its newer rolling cutoff on disk; the next pass can advance
                    // that persisted checkpoint through the same append without restoring old Go
                    // detail into the cache.
                    return true
                }
                try data.write(to: url, options: .atomic)
                return true
            }) else {
                DiagnosticGate.logOnce(for: Self.lockFailureKey(path: path)) {
                    AppLog.warn(LogTag.plugin("opencode"), "router aggregate lock unavailable; keeping the existing cache")
                }
                return
            }
            DiagnosticGate.clearFailure(Self.lockFailureKey(path: path))
            DiagnosticGate.clearFailure(saveFailureKey)
            guard didSave else { return }
        } catch {
            DiagnosticGate.logOnce(for: saveFailureKey) {
                AppLog.warn(LogTag.plugin("opencode"), "router aggregate save failed: \(error.localizedDescription)")
            }
        }
    }

    static func load(path: String) -> OpenCodeRouterLedgerAggregate? {
        loadUnlocked(path: path)
    }

    private static func loadUnlocked(path: String) -> OpenCodeRouterLedgerAggregate? {
        let url = fileURL(path: path)
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data),
              file.schema == Self.schema,
              file.path == path,
              file.timeZoneIdentifier == Calendar.current.timeZone.identifier
        else { return nil }
        return OpenCodeRouterLedgerAggregate(file: file)
    }

    static func fileURL(path: String) -> URL {
        JSONLScanCachePaths.defaultDirectory
            .appendingPathComponent("opencode-router-aggregate", isDirectory: true)
            .appendingPathComponent(JSONLScanCachePaths.stableFingerprint(path) + ".json")
    }

    static func removePersistedAggregate(path: String) {
        _ = withAggregateFileLock(path: path) {
            try? FileManager.default.removeItem(at: fileURL(path: path))
        }
    }

    static func removePersistedAggregate(
        path: String,
        matching expected: OpenCodeRouterLedger.SourceSnapshot
    ) {
        _ = withAggregateFileLock(path: path) {
            guard let current = loadUnlocked(path: path), current.sourceSnapshot == expected,
                  !OpenCodeRouterLedger.sourceSnapshotIsCurrent(current.sourceSnapshot, atPath: path)
            else { return }
            try? FileManager.default.removeItem(at: fileURL(path: path))
        }
    }

    /// Remove only a cache that is still unreadable/obsolete after acquiring the lock. A concurrent
    /// process may have repaired it while this process was scanning the source.
    static func removeInvalidPersistedAggregate(path: String) {
        let url = fileURL(path: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        _ = withAggregateFileLock(path: path) {
            guard FileManager.default.fileExists(atPath: url.path), loadUnlocked(path: path) == nil else { return }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func withAggregateFileLock<Result>(
        path: String,
        _ operation: () throws -> Result
    ) rethrows -> Result? {
        aggregateFileMutationLock.lock()
        defer { aggregateFileMutationLock.unlock() }

        let lockPath = fileURL(path: path).appendingPathExtension("lock").path
        let descriptor = lockPath.withCString {
            Darwin.open($0, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(0o600))
        }
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { return nil }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }

    private static func lockFailureKey(path: String) -> String {
        "opencode.router.aggregate.lock.\(JSONLScanCachePaths.stableFingerprint(path))"
    }

    private static func saveFailureKey(path: String) -> String {
        "opencode.router.aggregate.save.\(JSONLScanCachePaths.stableFingerprint(path))"
    }

    private func absorb(_ rows: [OpenCodeUsageScanner.ClaudeGatewayRow], compactGoBefore: Date) {
        ensureBucketIndex()
        for row in rows {
            addRow(row, compactGoBefore: compactGoBefore)
        }
    }

    private func dayKey(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? Calendar.current.timeZone
        return DailyUsageAccumulator.dayKey(from: date, calendar: calendar)
    }

    private func ensureBucketIndex() {
        guard !hasBucketIndex else { return }
        bucketIndex.removeAll(keepingCapacity: true)
        bucketIndex.reserveCapacity(buckets.count)
        for (index, bucket) in buckets.enumerated() {
            bucketIndex[bucketKey(
                day: bucket.day,
                model: bucket.model,
                accountId: bucket.accountId,
                accountFingerprint: bucket.accountFingerprint,
                burnsGoQuota: bucket.burnsGoQuota,
                routerInputWasEstimated: bucket.routerInputWasEstimated,
                routerCostBreakdownIsComplete: bucket.routerCostBreakdownIsComplete
            )] = index
        }
        hasBucketIndex = true
    }

    private func bucketKey(
        day: String,
        model: String,
        accountId: String?,
        accountFingerprint: String?,
        burnsGoQuota: Bool?,
        routerInputWasEstimated: Bool?,
        routerCostBreakdownIsComplete: Bool?
    ) -> String {
        [day, model, accountId ?? "", accountFingerprint ?? "",
         burnsGoQuota.map { $0 ? "1" : "0" } ?? "?",
         routerInputWasEstimated.map { $0 ? "1" : "0" } ?? "?",
         routerCostBreakdownIsComplete.map { $0 ? "1" : "0" } ?? "?"].joined(separator: "\u{1f}")
    }

    private static func noon(_ day: String, timeZoneIdentifier: String) -> Date? {
        let parts = day.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2])
        else { return nil }
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(identifier: timeZoneIdentifier)
        components.year = year
        components.month = month
        components.day = day
        components.hour = 12
        return components.date
    }

}
