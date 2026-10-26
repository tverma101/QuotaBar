import Darwin
import Foundation

/// Bounded append cache for the Claude Code session logs that are written while a session runs.
///
/// Claude Code appends one JSONL row per turn to `<config dir>/projects/**.jsonl`. Re-reading a whole
/// session file on every refresh costs O(file size) per refresh, so this cache keeps the rows of the
/// completed lines and reads only the bytes appended since the last checkpoint.
///
/// Guarantees:
/// - A checkpoint is published only for a file that still proves to be the file that was parsed:
///   same device + inode, same size, same content/attribute modification times and the same sampled
///   prefix signature. A same-size rewrite, a truncation, a rotation or an in-place edit therefore
///   fall back to a full re-parse instead of trusting stale rows.
/// - A file that did not grow while it was read must not have been rewritten either: its
///   modification times are captured before and after the read and compared. Unreadable stamps fail
///   closed — they never count as "unchanged" and never earn a checkpoint.
/// - The trailing newline-less fragment of a file is *provisional*. Its rows are kept apart from the
///   committed rows and are re-read from the file, so a row that is completed by a later append is
///   parsed once — never counted twice, never lost.
/// - A malformed, cancelled or failed read never publishes a checkpoint; the next parse starts over
///   from the beginning of the file.
///
/// Integrity limitation: the prefix signature is a sampled window over the historical bytes (see
/// `AppendOnlyFileProbe`), not a cryptographic digest of the whole file, so a rewrite of a large
/// file that lands entirely outside the sampled windows can go unnoticed. The modification times
/// cover the same-size rewrite case, and the incremental scanner revalidates the source metadata.
final class ClaudeSessionAppendCache: Sendable {
    typealias Entry = ClaudeLogUsageScanner.Entry

    /// Per-file state that `AppendOnlyFileTailCache` does not model on its own.
    struct Checkpoint: Sendable {
        /// Bytes of the trailing fragment that was not newline-terminated when the checkpoint was
        /// taken. The next read starts there so a half-written row is parsed once, as a whole.
        var fragmentBytes: Int = 0
        /// Content modification time of the parsed file.
        var mtime: Date?
        /// Attribute modification time — the ctime-like signal that changes on an in-place rewrite
        /// even when a writer restores the content modification time.
        var attributeMtime: Date?
    }

    /// Read statistics for one path: full parses, append-only parses and the bytes read in total.
    struct Statistics: Equatable, Sendable {
        var fullParses = 0
        var tailParses = 0
        var bytesRead = 0
    }

    /// The shared cache used by the Claude card. Bounded so it cannot become the long-running RAM
    /// leak it exists to prevent: at most eight files and 16 000 rows are retained at a time.
    static let shared = ClaudeSessionAppendCache()

    static let defaultMaxEntries = 8
    static let defaultMaxRetainedItems = 16_000

    /// The number of files whose rows may be retained at once.
    let maxEntries: Int
    /// The number of rows that may be retained across all files.
    let maxRetainedItems: Int

    private static let chunkSize = 64 * 1024

    private let cache: AppendOnlyFileTailCache<Entry, Checkpoint>

    init(
        maxEntries: Int = ClaudeSessionAppendCache.defaultMaxEntries,
        maxRetainedItems: Int = ClaudeSessionAppendCache.defaultMaxRetainedItems
    ) {
        precondition(maxEntries > 0)
        precondition(maxRetainedItems > 0)
        self.maxEntries = maxEntries
        self.maxRetainedItems = maxRetainedItems
        self.cache = AppendOnlyFileTailCache<Entry, Checkpoint>(
            maxEntries: maxEntries,
            maxRetainedItems: maxRetainedItems
        )
    }

    // MARK: - Parsing

    /// Parse one session file, reading only the bytes appended since the last checkpoint.
    ///
    /// `parseLine` returns the rows of a single JSONL line and `nil` when the line carries malformed
    /// usage data. A malformed line makes the whole file unusable — the caller receives `nil` and
    /// keeps its last-good history, exactly like the non-cached parse.
    func parse(
        at url: URL,
        parseLine: (Data.SubSequence) -> [Entry]?
    ) -> [Entry]? {
        // A cancelled scan returns nothing at all: it must not publish a checkpoint and it must not
        // serve a cached answer the caller would read as a fresh parse.
        guard !Task.isCancelled else { return nil }
        let key = Self.key(for: url)
        guard let before = AppendOnlyFileProbe.revision(at: url) else {
            cache.remove(key)
            return nil
        }
        if let cached = cache.entry(for: key), cached.itemsAvailable {
            switch route(for: cached, before: before, url: url) {
            case .unchanged:
                // The row callback may cancel the scan, so the cached answer is only served while
                // the scan is still live.
                guard !Task.isCancelled else { return nil }
                return cached.items + cached.appendedItems
            case .append:
                // The read starts at the trailing fragment of the previous checkpoint, so a row that
                // was still being written is read again as a whole instead of being counted twice.
                let fragmentBytes = min(cached.parserState.fragmentBytes, Int(cached.revision.size))
                return readAndCheckpoint(
                    at: url,
                    key: key,
                    before: before,
                    startOffset: cached.revision.size - UInt64(fragmentBytes),
                    committed: cached.items,
                    parseKind: .tail,
                    parseLine: parseLine
                )
            case .full:
                break
            }
        }
        return readAndCheckpoint(
            at: url,
            key: key,
            before: before,
            startOffset: 0,
            committed: [],
            parseKind: .full,
            parseLine: parseLine
        )
    }

    /// Decide how the file may be read: reuse the checkpoint as-is, read the appended bytes, or
    /// re-read the whole file.
    private enum Route {
        case unchanged
        case append
        case full
    }

    private func route(
        for cached: AppendOnlyFileTailCache<Entry, Checkpoint>.Entry,
        before: AppendOnlyFileRevision,
        url: URL
    ) -> Route {
        // Another device or inode means the path now points at a different file (rotation).
        guard before.device == cached.revision.device, before.inode == cached.revision.inode else {
            return .full
        }
        if before.size == cached.revision.size {
            // Same size: only an untouched file may reuse the checkpoint. A same-size rewrite keeps
            // the inode and the length, so the modification times have to rule it out — the
            // attribute time even when the writer restores the content modification time — and the
            // sampled prefix signature catches the rewrite itself.
            let times = Self.modificationTimes(at: url)
            guard Self.matches(times, cached: cached),
                  let anchor = AppendOnlyFileProbe.anchor(at: url, endingAt: cached.revision.size),
                  anchor == cached.anchor
            else { return .full }
            return .unchanged
        }
        // A shorter file was truncated: the checkpoint no longer describes it.
        guard before.size > cached.revision.size else { return .full }
        // The file grew. The sampled signature of the old prefix proves that the rows already
        // parsed are still the rows in the file, so only the appended bytes have to be read. This is
        // a heuristic, not a proof — the source revision and the file metadata are revalidated by
        // the incremental scanner around the scan.
        guard let anchor = AppendOnlyFileProbe.anchor(at: url, endingAt: cached.revision.size),
              anchor == cached.anchor
        else { return .full }
        return .append
    }

    /// Read from `startOffset` up to the captured end of the file and publish a checkpoint for the
    /// bytes that were read. `committed` are the rows parsed before `startOffset`; they are merged
    /// with the rows of this read. A `startOffset` of zero is a full parse.
    private func readAndCheckpoint(
        at url: URL,
        key: String,
        before: AppendOnlyFileRevision,
        startOffset: UInt64,
        committed: [Entry],
        parseKind: AppendOnlyFileTailCache<Entry, Checkpoint>.ParseKind,
        parseLine: (Data.SubSequence) -> [Entry]?
    ) -> [Entry]? {
        guard !Task.isCancelled else {
            cache.remove(key)
            return nil
        }
        // The prefix signature taken before the read is compared with the one taken after it: a
        // file rewritten while it was read cannot be checkpointed.
        guard let prefixBefore = AppendOnlyFileProbe.anchor(at: url, endingAt: before.size) else {
            cache.remove(key)
            return nil
        }
        let timesBefore = Self.modificationTimes(at: url)
        var rows: [Entry] = []
        var malformed = false
        let read = JSONLFileReader.readLines(
            at: url,
            chunkSize: Self.chunkSize,
            startOffset: startOffset,
            endOffset: before.size,
            deliverFinalPartial: false
        ) { line in
            if let parsed = parseLine(line) {
                rows.append(contentsOf: parsed)
            } else {
                malformed = true
            }
        }
        guard read.isComplete, !malformed else {
            cache.remove(key)
            return nil
        }
        guard let fragment = parseFragment(read.finalPartial, parseLine: parseLine) else {
            // An append can stop at EOF halfway through a JSON record. Keep the prior complete
            // checkpoint so the next scan retries from its offset, including the unfinished bytes.
            // A malformed newline-terminated record is rejected above and still invalidates it.
            if startOffset == 0 { cache.remove(key) }
            return nil
        }
        guard let after = AppendOnlyFileProbe.revision(at: url),
              after.device == before.device,
              after.inode == before.inode,
              after.size >= before.size
        else {
            // The file was replaced or truncated while it was read: the parsed bytes cannot be
            // trusted, so nothing is published and the caller keeps its last-good history.
            cache.remove(key)
            return nil
        }
        guard let prefixAfter = AppendOnlyFileProbe.anchor(at: url, endingAt: before.size),
              prefixBefore == prefixAfter else {
            cache.remove(key)
            return nil
        }
        let timesAfter = Self.modificationTimes(at: url)
        guard Self.stayedUnchanged(
            before: timesBefore,
            after: timesAfter,
            grew: after.size > before.size
        ) else {
            // A file that did not grow must not have been rewritten while it was read: the prefix
            // signature alone can miss a rewrite that lands outside the sampled windows.
            cache.remove(key)
            return nil
        }
        // The row callback can cancel the scan after the read finished: publish only while live.
        guard !Task.isCancelled else {
            cache.remove(key)
            return nil
        }
        // The completed fragment rows precede the appended rows in the file, and the fragment rows
        // themselves are never part of `committed`.
        let merged = JSONLAccountingWorkPacer.shared.perform { committed + rows }
        store(
            key: key,
            device: after.device,
            inode: after.inode,
            offset: before.size,
            anchor: prefixAfter,
            committed: merged,
            fragment: fragment,
            fragmentBytes: read.finalPartial.count,
            times: timesAfter,
            parseKind: parseKind,
            bytesRead: read.statistics.bytesRead
        )
        return JSONLAccountingWorkPacer.shared.perform { merged + fragment }
    }

    /// The rows of the trailing newline-less fragment. `nil` means the fragment carries malformed
    /// usage data, which makes the whole file unusable.
    private func parseFragment(
        _ fragment: Data,
        parseLine: (Data.SubSequence) -> [Entry]?
    ) -> [Entry]? {
        guard !fragment.isEmpty else { return [] }
        return parseLine(fragment[...])
    }

    private func store(
        key: String,
        device: UInt64,
        inode: UInt64,
        offset: UInt64,
        anchor: Data,
        committed: [Entry],
        fragment: [Entry],
        fragmentBytes: Int,
        times: ModificationTimes,
        parseKind: AppendOnlyFileTailCache<Entry, Checkpoint>.ParseKind,
        bytesRead: Int
    ) {
        // An unreadable stamp cannot be validated against a later checkpoint, so no checkpoint is
        // published — the next parse re-reads the file.
        guard times.isKnown else {
            cache.remove(key)
            return
        }
        cache.store(
            AppendOnlyFileTailCache<Entry, Checkpoint>.Entry(
                revision: AppendOnlyFileRevision(device: device, inode: inode, size: offset),
                offset: offset,
                anchor: anchor,
                partialLine: Data(),
                isDiscardingOversizedLine: false,
                parserState: Checkpoint(
                    fragmentBytes: fragmentBytes,
                    mtime: times.mtime,
                    attributeMtime: times.attributeMtime
                ),
                items: committed,
                appendedItems: fragment,
                appendedItemsAvailable: true
            ),
            for: key,
            parseKind: parseKind,
            bytesRead: bytesRead
        )
    }

    // MARK: - Cache maintenance

    /// Drop the retained rows while keeping the append checkpoints. The next parse re-reads the
    /// file in full, so unloading can only cost I/O — never correctness.
    func unloadRetainedItems() {
        cache.unloadRetainedItems()
    }

    /// Forget the checkpoint of one path (the file was rewritten or removed).
    func clear(path: String) {
        cache.remove(Self.key(for: URL(fileURLWithPath: path)))
    }

    /// Forget the checkpoint of one path (the file was rewritten or removed).
    func clear(path: URL) {
        cache.remove(Self.key(for: path))
    }

    /// Read statistics for one path, or `nil` when the path has no checkpoint.
    func statistics(path: String) -> Statistics? {
        guard let statistics = cache.statistics(for: Self.key(for: URL(fileURLWithPath: path))) else {
            return nil
        }
        return Statistics(
            fullParses: statistics.fullParses,
            tailParses: statistics.tailParses,
            bytesRead: statistics.bytesRead
        )
    }

    /// Read statistics for one path, or `nil` when the path has no checkpoint.
    func statistics(path: URL) -> Statistics? {
        statistics(path: path.path)
    }

    /// The number of files with a checkpoint.
    func entryCountForTesting() -> Int {
        cache.entryCountForTesting()
    }

    /// The number of rows retained across all files.
    func retainedItemCountForTesting() -> Int {
        cache.retainedItemCountForTesting()
    }

    // MARK: - Helpers

    private struct ModificationTimes {
        var mtime: Date?
        var attributeMtime: Date?

        /// True only when both stamps could be read. An unreadable stamp is not evidence of
        /// anything: it must never compare equal to another unreadable stamp.
        var isKnown: Bool { mtime != nil && attributeMtime != nil }
    }

    private static func modificationTimes(at url: URL) -> ModificationTimes {
        // URL resource values can remain cached on the caller's URL across a file write. Read fresh
        // filesystem metadata so a rewrite during the parse cannot acquire a valid stale checkpoint.
        var value = stat()
        guard Darwin.lstat(url.resolvingSymlinksInPath().path, &value) == 0 else {
            return ModificationTimes(mtime: nil, attributeMtime: nil)
        }
        return ModificationTimes(
            mtime: Date(timeIntervalSince1970: Double(value.st_mtimespec.tv_sec) + Double(value.st_mtimespec.tv_nsec) / 1e9),
            attributeMtime: Date(timeIntervalSince1970: Double(value.st_ctimespec.tv_sec) + Double(value.st_ctimespec.tv_nsec) / 1e9)
        )
    }

    /// True when the current stamps prove the file did not change since the checkpoint was taken.
    private static func matches(
        _ times: ModificationTimes,
        cached: AppendOnlyFileTailCache<Entry, Checkpoint>.Entry
    ) -> Bool {
        guard times.isKnown,
              let cachedMtime = cached.parserState.mtime,
              let cachedAttributeMtime = cached.parserState.attributeMtime
        else { return false }
        return times.mtime == cachedMtime && times.attributeMtime == cachedAttributeMtime
    }

    /// True when the file may still be checkpointed after a read. A file that grew while it was
    /// read was appended to, so its stamps carry no information about the read itself. A file that
    /// did not grow must not have changed at all. Unreadable stamps fail closed on both sides.
    private static func stayedUnchanged(
        before: ModificationTimes,
        after: ModificationTimes,
        grew: Bool
    ) -> Bool {
        guard before.isKnown, after.isKnown else { return false }
        if grew { return true }
        return before.mtime == after.mtime && before.attributeMtime == after.attributeMtime
    }

    /// The checkpoint key of one path. Symlinks resolve to their target so a file is never tracked
    /// twice under two names.
    private static func key(for url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
