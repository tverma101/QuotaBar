import Foundation
import os

/// Memoizes a fully checked future-dated JSONL source so repeated refreshes can keep last-good data
/// without rebuilding its parsed rows. Appends are safe to defer while the known future row remains
/// in the verified prefix; a rewrite, rotation, or clock catch-up forces a fresh scan.
enum FutureTimestampRevisionGate {
    private struct Key: Hashable {
        var identity: String
        var path: String
    }

    private struct Marker: Sendable {
        var device: UInt64
        var inode: UInt64
        var size: UInt64
        var mtime: Date
        var attributeMtime: Date?
        var timestamp: Date
        var anchor: Data
    }

    private struct Facts: Equatable {
        var revision: AppendOnlyFileRevision
        var mtime: Date
        var attributeMtime: Date?
        var anchor: Data
    }

    private static let maximumMarkers = 512
    private static let markers = OSAllocatedUnfairLock<[Key: Marker]>(initialState: [:])

    static func retain(identity: String, paths: Set<String>) {
        markers.withLock { entries in
            entries = entries.filter { $0.key.identity != identity || paths.contains($0.key.path) }
        }
    }

    /// Returns true only when the same future row is still present in the verified source prefix.
    static func shouldDefer(
        identity: String,
        file: JSONLScanning.DiscoveredFile,
        maximumTimestamp: Date
    ) -> Bool {
        let key = Key(identity: identity, path: file.path)
        guard let marker = markers.withLock({ $0[key] }) else { return false }
        guard let facts = currentFacts(for: file),
              facts.revision.device == marker.device,
              facts.revision.inode == marker.inode
        else {
            clear(key)
            return false
        }

        let sameRevision = facts.revision.size == marker.size
            && facts.mtime == marker.mtime
            && facts.attributeMtime == marker.attributeMtime
            && facts.anchor == marker.anchor
        if sameRevision {
            guard marker.timestamp > maximumTimestamp else {
                clear(key)
                return false
            }
            return true
        }

        // Appending does not remove the known future contribution. Validate the sampled old-prefix
        // anchor, then advance the marker without visiting every cached event again.
        guard facts.revision.size > marker.size,
              AppendOnlyFileProbe.anchor(
                  at: URL(fileURLWithPath: file.path),
                  endingAt: marker.size
              ) == marker.anchor
        else {
            clear(key)
            return false
        }
        guard marker.timestamp > maximumTimestamp else {
            clear(key)
            return false
        }
        guard let verifiedFacts = currentFacts(for: file), verifiedFacts == facts else {
            clear(key)
            return false
        }
        markers.withLock { entries in
            entries[key] = Marker(
                device: facts.revision.device,
                inode: facts.revision.inode,
                size: facts.revision.size,
                mtime: facts.mtime,
                attributeMtime: facts.attributeMtime,
                timestamp: marker.timestamp,
                anchor: facts.anchor
            )
        }
        return true
    }

    /// Records a future timestamp only when the scanned bytes still match discovery after folding.
    @discardableResult
    static func record(
        _ timestamp: Date,
        identity: String,
        file: JSONLScanning.DiscoveredFile
    ) -> Bool {
        let key = Key(identity: identity, path: file.path)
        guard let facts = currentFacts(for: file),
              let verifiedFacts = currentFacts(for: file), verifiedFacts == facts
        else { return false }
        markers.withLock { entries in
            entries[key] = Marker(
                device: facts.revision.device,
                inode: facts.revision.inode,
                size: facts.revision.size,
                mtime: facts.mtime,
                attributeMtime: facts.attributeMtime,
                timestamp: timestamp,
                anchor: facts.anchor
            )
            if entries.count > maximumMarkers,
               let victim = entries.keys.first(where: { $0 != key }) {
                entries[victim] = nil
            }
        }
        return true
    }

    static func clear(identity: String, path: String) {
        clear(Key(identity: identity, path: path))
    }

    private static func clear(_ key: Key) {
        markers.withLock { $0[key] = nil }
    }

    private static func currentFacts(for file: JSONLScanning.DiscoveredFile) -> Facts? {
        let url = URL(fileURLWithPath: file.path)
        guard let revision = AppendOnlyFileProbe.revision(at: url),
              revision.size == UInt64(file.size),
              let values = try? url.resourceValues(forKeys: Set([
                  .fileSizeKey, .contentModificationDateKey, .attributeModificationDateKey
              ])),
              values.fileSize == file.size,
              values.contentModificationDate == file.mtime,
              values.attributeModificationDate == file.attributeMtime,
              let anchor = AppendOnlyFileProbe.anchor(at: url, endingAt: revision.size),
              AppendOnlyFileProbe.revision(at: url) == revision
        else { return nil }
        return Facts(
            revision: revision,
            mtime: file.mtime,
            attributeMtime: file.attributeMtime,
            anchor: anchor
        )
    }
}

/// Collects scan output and the latest future timestamp by source file while `foldItems` visits files
/// sequentially. The scanner still returns incomplete as soon as any future timestamp is present.
final class FutureTimestampFoldBucket<Item: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var currentPath: String?
    private var collectedItems: [Item] = []
    private var futureTimestampsByPath: [String: Date] = [:]

    func begin(_ path: String) {
        lock.lock()
        currentPath = path
        lock.unlock()
    }

    func append(_ item: Item, timestamp: Date, maximumTimestamp: Date) {
        lock.lock()
        collectedItems.append(item)
        noteFutureTimestamp(timestamp, maximumTimestamp: maximumTimestamp)
        lock.unlock()
    }

    func observe(timestamp: Date, maximumTimestamp: Date) {
        lock.lock()
        noteFutureTimestamp(timestamp, maximumTimestamp: maximumTimestamp)
        lock.unlock()
    }

    func finish(_ path: String) {
        lock.lock()
        if currentPath == path { currentPath = nil }
        lock.unlock()
    }

    var items: [Item] {
        lock.lock()
        defer { lock.unlock() }
        return collectedItems
    }

    var futureTimestamps: [String: Date] {
        lock.lock()
        defer { lock.unlock() }
        return futureTimestampsByPath
    }

    private func noteFutureTimestamp(_ timestamp: Date, maximumTimestamp: Date) {
        if timestamp > maximumTimestamp, let currentPath,
           futureTimestampsByPath[currentPath].map({ timestamp > $0 }) ?? true {
            futureTimestampsByPath[currentPath] = timestamp
        }
    }
}
