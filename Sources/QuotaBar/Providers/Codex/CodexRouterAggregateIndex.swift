import Darwin
import Foundation

/// On-disk daily fold of a CodexRouter `usage-events.jsonl`.
///
/// The ledger is append-only and large (tens of MB, well over 100k lines). Keeping those lines as
/// `Event` values blows past the menu-bar RSS budget, the tail cache then evicts itself, and the next
/// tap parses the whole file again. This index stores only the priced daily aggregate plus the byte
/// checkpoint (device, inode, size, mtime, offset, prefix anchor). A panel open whose stat still
/// matches reads nothing. Growth reads only the new bytes. A new inode or a shorter file rebuilds.
final class CodexRouterAggregateIndex: @unchecked Sendable {
    static let shared = CodexRouterAggregateIndex()
    static let schema = 3
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
    }

    struct FileCheckpoint: Codable, Equatable, Sendable {
        var path: String
        var device: UInt64
        var inode: UInt64
        var size: UInt64
        var mtimeSec: Int64
        var mtimeNsec: Int64
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
        var complete: Bool
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

    func lookup(key: Key, paths: [String], now: Date) -> Lookup {
        let live = Self.stats(for: paths)
        let id = Self.fingerprint(key)
        let record = lock.withLock { memory[id] } ?? load(id: id)
        guard let record, record.schema == Self.schema, record.key == key, record.complete else {
            return .rebuild
        }
        if let future = record.nextFutureEventAt, now >= future {
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
                if saved.mtimeSec == current.mtimeSec, saved.mtimeNsec == current.mtimeNsec {
                    continue
                }
                // A changed timestamp can mean an in-place rewrite anywhere in the file.
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
        return .hit(record.result)
    }

    func save(_ record: Record) {
        let id = Self.fingerprint(record.key)
        remember(record, id: id)
        let url = Self.fileURL(id: id)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            let data = try encoder.encode(record)
            try data.write(to: url, options: .atomic)
        } catch {
            AppLog.warn(LogTag.plugin("codex"), "router aggregate save failed: \(error.localizedDescription)")
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
            mtimeNsec: Int64(value.st_mtimespec.tv_nsec)
        )
    }

    private func load(id: String) -> Record? {
        let url = Self.fileURL(id: id)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let data = try? Data(contentsOf: url),
              let record = try? decoder.decode(Record.self, from: data),
              record.schema == Self.schema
        else { return nil }
        remember(record, id: id)
        return record
    }

    private static func fingerprint(_ key: Key) -> String {
        let aliases = key.aliases.joined(separator: "\n")
        let raw = [
            "\(key.account)",
            key.allowsUnscopedEvents ? "1" : "0",
            "\(key.days)",
            String(format: "%.3f", key.since),
            key.timeZoneIdentifier,
            aliases,
            key.pricingToken,
            key.sourcePaths.joined(separator: "\n")
        ].joined(separator: "\u{1e}")
        return JSONLScanCachePaths.stableFingerprint(raw)
    }

    private static func fileURL(id: String) -> URL {
        JSONLScanCachePaths.defaultDirectory
            .appendingPathComponent("codex-router-aggregate", isDirectory: true)
            .appendingPathComponent("\(id).json")
    }
}
