import Darwin
import Foundation

/// Cheap identity/revision facts for proving that an append checkpoint still points at the same file.
/// Size is intentionally separate from identity: an append changes size while device+inode stay stable.
struct AppendOnlyFileRevision: Equatable, Sendable {
    var device: UInt64
    var inode: UInt64
    var size: UInt64
}

enum AppendOnlyFileProbe {
    /// Total prefix bytes sampled when validating a large append checkpoint. Small files up to this
    /// size are compared in full. Large files spread the same tiny budget across the historical prefix.
    static let anchorBytes = 4 * 1024
    private static let anchorSamples = 9

    static func revision(at url: URL) -> AppendOnlyFileRevision? {
        // Resolve first, then lstat the concrete path. `stat` is imported into Swift as both the C
        // struct and function name; `lstat` avoids that overload ambiguity while resolution keeps
        // symlink aliases tied to the target file's inode rather than the link object.
        let resolved = url.resolvingSymlinksInPath()
        var value = stat()
        guard Darwin.lstat(resolved.path, &value) == 0, value.st_size >= 0 else { return nil }
        return AppendOnlyFileRevision(
            device: UInt64(value.st_dev),
            inode: UInt64(value.st_ino),
            size: UInt64(value.st_size)
        )
    }

    /// A compact prefix signature for an append checkpoint. For small files it contains the complete
    /// prefix. For large files it samples head/interior/tail positions across the old prefix, catching
    /// replacement, truncate/regrow, and common in-place rewrites without hashing multi-GB history on
    /// every refresh. Device+inode are checked separately by the caller; this signature is a cheap
    /// append-vs-reparse discriminator, not a cryptographic integrity proof against adversarial writes.
    static func anchor(at url: URL, endingAt offset: UInt64, bytes: Int = anchorBytes) -> Data? {
        precondition(bytes > 0)
        let resolved = url.resolvingSymlinksInPath()
        guard let revision = revision(at: resolved), revision.size >= offset else { return nil }
        guard offset > 0 else { return Data() }
        guard let handle = try? FileHandle(forReadingFrom: resolved) else { return nil }
        defer { try? handle.close() }

        do {
            if offset <= UInt64(bytes) {
                try handle.seek(toOffset: 0)
                guard let data = try handle.read(upToCount: Int(offset)), data.count == Int(offset) else {
                    return nil
                }
                return data
            }

            let sampleBytes = max(32, bytes / anchorSamples)
            let sampleLength = min(UInt64(sampleBytes), offset)
            let maxStart = offset - sampleLength
            var starts: [UInt64] = []
            starts.reserveCapacity(anchorSamples)
            for index in 0..<anchorSamples {
                let start = anchorSamples == 1
                    ? maxStart
                    : UInt64(index) * maxStart / UInt64(anchorSamples - 1)
                if starts.last != start {
                    starts.append(start)
                }
            }

            var signature = Data()
            signature.reserveCapacity(starts.count * (sampleBytes + 12))
            for start in starts {
                try handle.seek(toOffset: start)
                guard let sample = try handle.read(upToCount: Int(sampleLength)),
                      sample.count == Int(sampleLength)
                else { return nil }

                var encodedStart = start.littleEndian
                withUnsafeBytes(of: &encodedStart) { signature.append(contentsOf: $0) }
                var encodedLength = UInt32(sample.count).littleEndian
                withUnsafeBytes(of: &encodedLength) { signature.append(contentsOf: $0) }
                signature.append(sample)
            }
            return signature
        } catch {
            return nil
        }
    }
}

/// In-memory append checkpoints are deliberately bounded. They are an optimization layer over the
/// authoritative parse cache: eviction can make one future refresh do a full parse, but can never make
/// results incorrect. Both entry count and retained-item count are capped so this optimization cannot
/// itself become the long-running RAM leak it exists to prevent.
final class AppendOnlyFileTailCache<Item: Sendable, ParserState: Sendable>: @unchecked Sendable {
    struct Entry: Sendable {
        var revision: AppendOnlyFileRevision
        var offset: UInt64
        var anchor: Data
        var partialLine: Data
        var isDiscardingOversizedLine: Bool
        var parserState: ParserState
        var items: [Item]
        /// Small append fragments can be shared by multiple account folds that observed the same
        /// file revision. Unlike `items`, this never contains historical rows.
        var appendedFromRevision: AppendOnlyFileRevision? = nil
        var appendedFromAnchor: Data? = nil
        var appendedItems: [Item] = []
        var appendedItemsAvailable = false
        /// False after `unloadRetainedItems()` cleared `items` while keeping the append checkpoint.
        /// Distinguished from a real empty parse (`items.isEmpty && itemsAvailable`).
        var itemsAvailable: Bool = true
    }

    struct Statistics: Equatable, Sendable {
        var fullParses = 0
        var tailParses = 0
        var bytesRead = 0
    }

    enum ParseKind: Sendable {
        case full
        case tail
    }

    private struct Stored {
        var entry: Entry
        var statistics: Statistics
        var accessTick: UInt64
    }

    private let lock = NSLock()
    private let maxEntries: Int
    private let maxRetainedItems: Int
    private var tick: UInt64 = 0
    private var storage: [String: Stored] = [:]

    init(maxEntries: Int = 128, maxRetainedItems: Int = 8_000) {
        precondition(maxEntries > 0)
        precondition(maxRetainedItems > 0)
        self.maxEntries = maxEntries
        self.maxRetainedItems = maxRetainedItems
    }

    func entry(for key: String) -> Entry? {
        lock.withLock {
            guard var stored = storage[key] else { return nil }
            tick &+= 1
            stored.accessTick = tick
            storage[key] = stored
            return stored.entry
        }
    }

    func store(
        _ entry: Entry,
        for key: String,
        parseKind: ParseKind,
        bytesRead: Int,
        retainItems: Bool = true
    ) {
        lock.withLock {
            tick &+= 1
            var stats = storage[key]?.statistics ?? Statistics()
            switch parseKind {
            case .full: stats.fullParses += 1
            case .tail: stats.tailParses += 1
            }
            stats.bytesRead += max(0, bytesRead)
            var storedEntry = entry
            if retainItems {
                storedEntry.itemsAvailable = true
            } else {
                storedEntry.items = []
                storedEntry.itemsAvailable = false
            }
            storage[key] = Stored(entry: storedEntry, statistics: stats, accessTick: tick)
            evictIfNeededLocked()
        }
    }

    func remove(_ key: String) {
        lock.withLock { storage[key] = nil }
    }

    func statistics(for key: String) -> Statistics? {
        lock.withLock { storage[key]?.statistics }
    }

    func entryCountForTesting() -> Int {
        lock.withLock { storage.count }
    }

    func retainedItemCountForTesting() -> Int {
        lock.withLock { retainedItemCountLocked() }
    }

    /// Drop retained item arrays while keeping append checkpoints (revision/offset/anchor/parserState).
    /// Callers that later need historical items must full-reparse when `items` is empty; append merges
    /// are only safe when items are still present.
    func unloadRetainedItems() {
        lock.withLock {
            for key in Array(storage.keys) {
                guard var stored = storage[key] else { continue }
                stored.entry.items = []
                stored.entry.appendedItems = []
                stored.entry.appendedItemsAvailable = false
                stored.entry.itemsAvailable = false
                storage[key] = stored
            }
        }
    }

    private func retainedItemCountLocked() -> Int {
        storage.values.reduce(into: 0) {
            $0 += $1.entry.items.count + $1.entry.appendedItems.count
        }
    }

    private func evictIfNeededLocked() {
        while storage.count > maxEntries || retainedItemCountLocked() > maxRetainedItems {
            guard let victim = storage.min(by: { $0.value.accessTick < $1.value.accessTick })?.key else {
                return
            }
            storage[victim] = nil
        }
    }
}
