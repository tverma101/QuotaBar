import Foundation

/// Durable, compact view of the OpenCode-owned slice of one CodexRouter ledger.
///
/// The raw router ledger grows without bound and can reach tens of millions of tokens. Keeping every
/// OpenCode row resident made each menu-bar tap repeat work proportional to history, so this aggregate
/// stores only local-calendar day/model sums plus the individual Go rows still needed by the rolling
/// cap meters. Non-Go rows materialize as a few dozen aggregated rows; long-context pricing is disabled
/// for those sums because one bucket is not one request.
final class OpenCodeRouterLedgerAggregate: @unchecked Sendable {
    private static let schema = 3

    struct Bucket: Codable, Sendable {
        var day: String
        var model: String
        var input: Int
        var output: Int
        var cacheRead: Int
    }

    struct GoRow: Codable, Sendable {
        var date: TimeInterval
        var input: Int
        var output: Int
        var cacheRead: Int
        var model: String
    }

    private struct File: Codable {
        var schema: Int
        var path: String
        var timeZoneIdentifier: String
        var device: UInt64
        var inode: UInt64
        var size: UInt64
        var mtimeMillis: Int64
        var offset: UInt64
        var partial: Data
        var discarding: Bool
        var anchor: Data
        var buckets: [Bucket]
        var goRows: [GoRow]
    }

    private var bucketIndex: [String: Int] = [:]
    private var hasBucketIndex = false

    enum Reconcile {
        case rows([OpenCodeUsageScanner.ClaudeGatewayRow])
        case stale
    }

    var path: String
    var device: UInt64
    var inode: UInt64
    var size: UInt64
    var mtimeMillis: Int64
    var offset: UInt64
    var partial: Data
    var discarding: Bool
    var anchor: Data
    var buckets: [Bucket]
    var goRows: [GoRow]

    private init(file: File) {
        path = file.path
        device = file.device
        inode = file.inode
        size = file.size
        mtimeMillis = file.mtimeMillis
        offset = file.offset
        partial = file.partial
        discarding = file.discarding
        anchor = file.anchor
        buckets = file.buckets
        goRows = file.goRows
    }

    static func empty(path: String, revision: AppendOnlyFileRevision) -> OpenCodeRouterLedgerAggregate {
        OpenCodeRouterLedgerAggregate(file: File(
            schema: Self.schema,
            path: path,
            timeZoneIdentifier: Calendar.current.timeZone.identifier,
            device: revision.device,
            inode: revision.inode,
            size: revision.size,
            mtimeMillis: mtimeMillis(URL(fileURLWithPath: path)),
            offset: 0,
            partial: Data(),
            discarding: false,
            anchor: Data(),
            buckets: [],
            goRows: []
        ))
    }

    func seal(
        revision: AppendOnlyFileRevision,
        offset: UInt64,
        partial: Data,
        discarding: Bool,
        anchor: Data
    ) {
        size = revision.size
        self.offset = offset
        self.partial = partial
        self.discarding = discarding
        self.anchor = anchor
        mtimeMillis = Self.mtimeMillis(URL(fileURLWithPath: path))
    }

    func addRow(_ row: OpenCodeUsageScanner.ClaudeGatewayRow) {
        if row.burnsGoQuota {
            goRows.append(GoRow(
                date: row.date.timeIntervalSince1970,
                input: row.input,
                output: row.output,
                cacheRead: row.cacheRead,
                model: row.model
            ))
            return
        }
        let day = DailyUsageAccumulator.dayKey(from: row.date)
        let key = bucketKey(day: day, model: row.model)
        ensureBucketIndex()
        if let index = bucketIndex[key] {
            // Saturating: the router parser clamps a hostile line's counts to `Int.max` instead of
            // rejecting it, so a plain `+=` across rows can overflow and trap.
            buckets[index].input = ProviderParse.addingSaturating(buckets[index].input, row.input)
            buckets[index].output = ProviderParse.addingSaturating(buckets[index].output, row.output)
            buckets[index].cacheRead = ProviderParse.addingSaturating(buckets[index].cacheRead, row.cacheRead)
        } else {
            bucketIndex[key] = buckets.count
            buckets.append(Bucket(
                day: day,
                model: row.model,
                input: row.input,
                output: row.output,
                cacheRead: row.cacheRead
            ))
        }
    }

    func reconcile(url: URL, current: AppendOnlyFileRevision, since: Date) -> Reconcile {
        guard current.device == device, current.inode == inode else { return .stale }
        let freshMtime = Self.mtimeMillis(url)
        if current.size == offset, current.size == size {
            if freshMtime != mtimeMillis {
                // Same length, new timestamp: an in-place rewrite anywhere in the file is possible, and
                // the sampled prefix anchor cannot prove earlier events are intact. Rebuild rather than
                // trust the folded totals — same policy as the Codex router aggregate index.
                return .stale
            }
            return .rows(materialize(since: since))
        }

        // Truncate or replace: the caller rebuilds. Growth reads only the tail below.
        guard current.size > offset,
              AppendOnlyFileProbe.anchor(at: url, endingAt: offset) == anchor
        else { return .stale }

        var timestampCache = CodexRouterEventLineParser.TimestampCache()
        var appended: [OpenCodeUsageScanner.ClaudeGatewayRow] = []
        var read = JSONLFileReader.readLines(
            at: url,
            chunkSize: 256 * 1024,
            startOffset: offset,
            initialCarry: partial,
            discardingOversizedLine: discarding,
            deliverFinalPartial: false
        ) { line in
            if let row = OpenCodeRouterLedger.row(from: line, timestampCache: &timestampCache) {
                appended.append(row)
            }
        }
        guard read.succeeded else { return .stale }
        if !read.finalPartial.isEmpty,
           let row = OpenCodeRouterLedger.row(
            from: read.finalPartial[...],
            timestampCache: &timestampCache
           ) {
            appended.append(row)
            read.finalPartial = Data()
        }

        let newOffset = offset + UInt64(max(0, read.statistics.bytesRead))
        guard let after = AppendOnlyFileProbe.revision(at: url),
              after.device == device,
              after.inode == inode,
              after.size >= newOffset,
              let newAnchor = AppendOnlyFileProbe.anchor(at: url, endingAt: newOffset)
        else { return .stale }

        absorb(appended)
        OpenCodeRouterLedger.noteCompactTail(path: path, bytesRead: read.statistics.bytesRead)
        offset = newOffset
        size = after.size
        partial = read.finalPartial
        discarding = read.isDiscardingOversizedLine
        anchor = newAnchor
        mtimeMillis = Self.mtimeMillis(url)
        // The router logs other providers' traffic too, so most refreshes advance the offset while
        // absorbing nothing. Only rewrite the compact file when its contents actually changed.
        if !appended.isEmpty {
            save()
        }
        return .rows(materialize(since: since))
    }

    func materialize(since: Date) -> [OpenCodeUsageScanner.ClaudeGatewayRow] {
        var rows: [OpenCodeUsageScanner.ClaudeGatewayRow] = []
        rows.reserveCapacity(buckets.count + goRows.count)
        // A bucket is a whole local day. The fold always passes a local-midnight cutoff, so including the
        // whole boundary day matches the per-row path exactly; for any other cutoff, keeping the day is
        // the conservative choice — it can over-count part of one day rather than dropping real usage.
        let cutoffDay = DailyUsageAccumulator.dayKey(from: since)
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
                burnsGoQuota: false,
                isInProgress: false,
                isAggregated: true
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
                burnsGoQuota: true,
                isInProgress: false
            ))
        }
        return rows
    }

    /// Drop data that can no longer appear in the 45-day retention or cap-meter windows.
    /// Returns whether persisted state changed and should be written back.
    @discardableResult
    func prune(before cutoff: Date) -> Bool {
        let cutoffDay = DailyUsageAccumulator.dayKey(from: cutoff)
        let oldBucketCount = buckets.count
        buckets.removeAll { $0.day < cutoffDay }
        let oldGoCount = goRows.count
        goRows.removeAll { Date(timeIntervalSince1970: $0.date) < cutoff }
        if buckets.count != oldBucketCount || goRows.count != oldGoCount {
            hasBucketIndex = false
            return true
        }
        return false
    }

    func save() {
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
                mtimeMillis: mtimeMillis,
                offset: offset,
                partial: partial,
                discarding: discarding,
                anchor: anchor,
                buckets: buckets,
                goRows: goRows
            ))
            try data.write(to: url, options: .atomic)
        } catch {
            AppLog.warn(LogTag.plugin("opencode"), "router aggregate save failed: \(error.localizedDescription)")
        }
    }

    static func load(path: String) -> OpenCodeRouterLedgerAggregate? {
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
        try? FileManager.default.removeItem(at: fileURL(path: path))
    }

    private var timeZoneIdentifier: String { Calendar.current.timeZone.identifier }

    private func absorb(_ rows: [OpenCodeUsageScanner.ClaudeGatewayRow]) {
        ensureBucketIndex()
        for row in rows {
            addRow(row)
        }
    }

    private func ensureBucketIndex() {
        guard !hasBucketIndex else { return }
        bucketIndex.removeAll(keepingCapacity: true)
        bucketIndex.reserveCapacity(buckets.count)
        for (index, bucket) in buckets.enumerated() {
            bucketIndex[bucketKey(day: bucket.day, model: bucket.model)] = index
        }
        hasBucketIndex = true
    }

    private func bucketKey(day: String, model: String) -> String {
        day + "\u{1f}" + model
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

    private static func mtimeMillis(_ url: URL) -> Int64 {
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        guard let date else { return 0 }
        return Int64((date.timeIntervalSince1970 * 1000).rounded())
    }
}
