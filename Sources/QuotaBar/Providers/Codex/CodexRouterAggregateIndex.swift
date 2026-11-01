import Darwin
import Foundation

/// On-disk daily fold of a CodexRouter `usage-events.jsonl`.
///
/// The ledger is append-only and large (tens of MB, well over 100k lines). Keeping those lines as
/// `Event` values blows past the menu-bar RSS budget, the tail cache then evicts itself, and the next
/// tap parses the whole file again. This index stores only the priced daily aggregate plus the byte
/// checkpoint (device, inode, size, mtime, ctime, offset, prefix anchor). A panel open whose stat still
/// matches reads nothing. Growth reads only the new bytes. A new inode or a shorter file rebuilds.
final class CodexRouterAggregateIndex: @unchecked Sendable {
    static let shared = CodexRouterAggregateIndex()
    /// v15 drops the pricing token from the file identity and records what the fold priced, so a
    /// catalogue change that cannot touch the fold's numbers no longer costs a full ledger read.
    /// Also bump this when hardcoded Codex pricing rules change; catalogue dependencies cover rates,
    /// identities and dated resolution, rather than every implementation detail of the cost formula.
    static let schema = 15
    static let maxResidentRecords = 32

    struct Key: Codable, Equatable, Sendable {
        var account: String
        var allowsUnscopedEvents: Bool
        var days: Int
        var since: TimeInterval
        var timeZoneIdentifier: String
        var aliases: [String]
        var pricingToken: String
        var sourcePaths: [String]

        /// Whether two keys describe the same fold apart from the pricing catalogue.
        ///
        /// The pricing token is the one field that must not decide the fold's identity: a catalogue
        /// refresh changes it for every model, including the ones this ledger never used.
        func matchesIgnoringPricing(_ other: Key) -> Bool {
            account == other.account
                && allowsUnscopedEvents == other.allowsUnscopedEvents
                && days == other.days
                && since == other.since
                && timeZoneIdentifier == other.timeZoneIdentifier
                && aliases == other.aliases
                && sourcePaths == other.sourcePaths
        }
    }

    struct FileCheckpoint: Codable, Equatable, Sendable {
        var path: String
        var device: UInt64
        var inode: UInt64
        var size: UInt64
        var mtimeSec: Int64
        var mtimeNsec: Int64
        var ctimeSec: Int64
        var ctimeNsec: Int64
        var offset: UInt64
        var partial: Data
        var discardingOversizedLine: Bool
        var anchor: Data
    }

    struct Record: Codable, Sendable {
        var schema: Int
        var key: Key
        var files: [FileCheckpoint]
        var result: LogUsageScan?
        var nextFutureEventAt: Date?
        var latestIncludedEventAt: Date?
        var complete: Bool
        /// What this fold priced. Absent for records written before the dependency snapshot existed;
        /// those must rebuild rather than be trusted against a changed catalogue.
        var pricingDependencies: CodexRouterPricingDependencySet?
    }

    enum Lookup {
        case hit(LogUsageScan?)
        case append(Record)
        case rebuild
    }

    private struct ParseStats {
        var fullParses = 0
        var tailParses = 0
        var bytesRead = 0
    }

    private let lock = NSLock()
    private var memory: [String: Record] = [:]
    private var stats: [String: ParseStats] = [:]

    private init() {}

    private func remember(_ record: Record, id: String) {
        lock.withLock {
            memory[id] = record
            if memory.count > Self.maxResidentRecords,
               let victim = memory.keys.first(where: { $0 != id }) {
                memory[victim] = nil
            }
        }
    }

    var residentRecordCountForTesting: Int { lock.withLock { memory.count } }

    /// Look up the saved fold for `key`.
    ///
    /// `pricingDependenciesUnchanged` is consulted only when the pricing catalogue moved since the
    /// fold was written: it answers whether the resolutions the fold actually priced still hold.
    /// An unrelated catalogue change must not cost another read of the ledger, and a change to a
    /// priced model must fall back to the original full rebuild.
    func lookup(
        key: Key,
        paths: [String],
        now: Date,
        pricingDependenciesUnchanged: (CodexRouterPricingDependencySet) -> Bool
    ) -> Lookup {
        let live = Self.stats(for: paths)
        let id = Self.fingerprint(key)
        func matches(_ candidate: Record) -> Bool {
            guard candidate.schema == Self.schema, candidate.key.matchesIgnoringPricing(key),
                  candidate.complete, let dependencies = candidate.pricingDependencies
            else { return false }
            return candidate.key.pricingToken == key.pricingToken || pricingDependenciesUnchanged(dependencies)
        }
        let primary = lock.withLock { memory[id] } ?? load(id: id)
        let loaded: Record
        if let primary, matches(primary) {
            loaded = primary
        } else if let previous = load(id: id + "-previous"), matches(previous) {
            loaded = previous
        } else {
            return .rebuild
        }
        var record = loaded
        let pricingChanged = record.key.pricingToken != key.pricingToken
        if let future = record.nextFutureEventAt, now >= future {
            return .rebuild
        }
        if let latest = record.latestIncludedEventAt, latest > now {
            return .rebuild
        }
        guard record.files.count == live.count else { return .rebuild }
        var append = false
        for (saved, current) in zip(record.files, live) {
            guard saved.path == current.path,
                  saved.device == current.device,
                  saved.inode == current.inode
            else { return .rebuild }
            if current.size == saved.size, current.size == saved.offset {
                if saved.mtimeSec == current.mtimeSec,
                   saved.mtimeNsec == current.mtimeNsec,
                   saved.ctimeSec == current.ctimeSec,
                   saved.ctimeNsec == current.ctimeNsec {
                    continue
                }
                // Changed content or metadata time can mean an in-place rewrite anywhere in the file.
                // The tail anchor cannot prove that earlier events stayed unchanged.
                return .rebuild
            }
            guard current.size > saved.offset,
                  let anchor = AppendOnlyFileProbe.anchor(
                    at: URL(fileURLWithPath: current.path),
                    endingAt: saved.offset
                  ),
                  anchor == saved.anchor
            else { return .rebuild }
            append = true
        }
        if append { return .append(record) }
        if pricingChanged {
            // Adopt the new catalogue token so the next lookup is a plain hit. The fold itself is
            // unchanged: the dependency check already proved it.
            record.key.pricingToken = key.pricingToken
            save(record)
        }
        return .hit(record.result)
    }

    func save(_ record: Record) {
        let id = Self.fingerprint(record.key)
        let diagnosticKey = "codex.router.aggregate.save.\(id)"
        remember(record, id: id)
        do {
            try CodexRouterAggregatePersistence.write(record, id: id)
            DiagnosticGate.clearFailure(diagnosticKey)
        } catch {
            DiagnosticGate.logOnce(for: diagnosticKey) {
                AppLog.warn(LogTag.plugin("codex"), "router aggregate save failed: \(error.localizedDescription)")
            }
        }
    }

    func noteParse(path: String, full: Bool, bytes: Int) {
        let path = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        lock.withLock {
            var entry = stats[path] ?? ParseStats()
            if full { entry.fullParses += 1 } else { entry.tailParses += 1 }
            entry.bytesRead += max(0, bytes)
            stats[path] = entry
        }
    }

    func statistics(path: String) -> (fullParses: Int, tailParses: Int, bytesRead: Int)? {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return lock.withLock {
            guard let entry = stats[resolved] ?? stats[path] else { return nil }
            return (entry.fullParses, entry.tailParses, entry.bytesRead)
        }
    }

    func unloadMemoryForTesting(path: String) {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        lock.withLock {
            memory = memory.filter { _, record in
                !record.files.contains { $0.path == resolved }
            }
        }
    }

    func clear(path: String) {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let doomed = lock.withLock { () -> [String] in
            stats[resolved] = nil
            stats[path] = nil
            let ids = memory.filter { _, record in
                record.files.contains { $0.path == resolved || $0.path == path }
            }.map(\.key)
            for id in ids { memory[id] = nil }
            return ids
        }
        for id in doomed {
            try? FileManager.default.removeItem(at: Self.fileURL(id: id))
        }
        // Test cleanup includes records evicted from the resident bound.
        let directory = Self.fileURL(id: "").deletingLastPathComponent()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        for url in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            guard url.pathExtension == "json", let data = try? Data(contentsOf: url),
                  let record = try? decoder.decode(Record.self, from: data),
                  record.files.contains(where: { $0.path == resolved || $0.path == path })
            else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Test hook: drop one record from the resident cache and delete its file.
    func removeForTesting(key: Key) {
        let id = Self.fingerprint(key)
        lock.withLock {
            memory[id] = nil
            memory[id + "-previous"] = nil
        }
        try? FileManager.default.removeItem(at: Self.fileURL(id: id))
        try? FileManager.default.removeItem(at: Self.fileURL(id: id + "-previous"))
    }

    /// Test hook: the aggregate record files that describe `path`.
    ///
    /// A pricing change that must not rebuild the fold must also not leave a second record file
    /// behind, so the tests count these instead of guessing at the cache directory.
    static func recordURLsForTesting(path: String) -> [URL] {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let directory = fileURL(id: "").deletingLastPathComponent()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        var urls: [URL] = []
        for url in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            guard url.pathExtension == "json", let data = try? Data(contentsOf: url),
                  let record = try? decoder.decode(Record.self, from: data),
                  record.files.contains(where: { $0.path == resolved || $0.path == path })
            else { continue }
            urls.append(url)
        }
        return urls
    }

    func checkpoint(
        path: String,
        offset: UInt64,
        partial: Data,
        discardingOversizedLine: Bool
    ) -> FileCheckpoint? {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard let stat = Self.fileStat(url), stat.size >= offset,
              let anchor = AppendOnlyFileProbe.anchor(at: url, endingAt: offset)
        else { return nil }
        return FileCheckpoint(
            path: url.path,
            device: stat.device,
            inode: stat.inode,
            size: stat.size,
            mtimeSec: stat.mtimeSec,
            mtimeNsec: stat.mtimeNsec,
            ctimeSec: stat.ctimeSec,
            ctimeNsec: stat.ctimeNsec,
            offset: offset,
            partial: partial,
            discardingOversizedLine: discardingOversizedLine,
            anchor: anchor
        )
    }

    static func stats(for paths: [String]) -> [FileCheckpoint] {
        var files: [FileCheckpoint] = []
        var seen: Set<String> = []
        for path in paths {
            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            guard seen.insert(url.path).inserted else { continue }
            guard let stat = fileStat(url) else { continue }
            files.append(FileCheckpoint(
                path: url.path,
                device: stat.device,
                inode: stat.inode,
                size: stat.size,
                mtimeSec: stat.mtimeSec,
                mtimeNsec: stat.mtimeNsec,
                ctimeSec: stat.ctimeSec,
                ctimeNsec: stat.ctimeNsec,
                offset: stat.size,
                partial: Data(),
                discardingOversizedLine: false,
                anchor: Data()
            ))
        }
        return files.sorted { $0.path < $1.path }
    }

    private struct RawStat {
        var device: UInt64
        var inode: UInt64
        var size: UInt64
        var mtimeSec: Int64
        var mtimeNsec: Int64
        var ctimeSec: Int64
        var ctimeNsec: Int64
    }

    private static func fileStat(_ url: URL) -> RawStat? {
        var value = stat()
        guard Darwin.lstat(url.path, &value) == 0, value.st_size >= 0 else { return nil }
        let mode = value.st_mode
        guard (mode & S_IFMT) == S_IFREG else { return nil }
        return RawStat(
            device: UInt64(value.st_dev),
            inode: UInt64(value.st_ino),
            size: UInt64(value.st_size),
            mtimeSec: Int64(value.st_mtimespec.tv_sec),
            mtimeNsec: Int64(value.st_mtimespec.tv_nsec),
            ctimeSec: Int64(value.st_ctimespec.tv_sec),
            ctimeNsec: Int64(value.st_ctimespec.tv_nsec)
        )
    }

    private func load(id: String) -> Record? {
        guard let record = CodexRouterAggregatePersistence.read(id: id) else { return nil }
        remember(record, id: id)
        return record
    }

    private static func fingerprint(_ key: Key) -> String {
        let aliases = key.aliases.joined(separator: "\n")
        // The pricing token is deliberately absent: the aggregate file must keep its identity when
        // the catalogue changes, so the saved fold can be checked against the new catalogue
        // instead of being orphaned by a new file name.
        let raw = [
            "codex-router-aggregate-v2",
            "\(key.account)",
            key.allowsUnscopedEvents ? "1" : "0",
            "\(key.days)",
            String(format: "%.3f", key.since),
            key.timeZoneIdentifier,
            aliases,
            key.sourcePaths.joined(separator: "\n")
        ].joined(separator: "\u{1e}")
        return JSONLScanCachePaths.stableFingerprint(raw)
    }

    private static func fileURL(id: String) -> URL {
        CodexRouterAggregatePersistence.fileURL(id: id)
    }
}
