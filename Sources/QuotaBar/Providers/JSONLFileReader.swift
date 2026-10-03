import Foundation

/// Reads a JSONL file without materializing the whole file in memory.
///
/// Complete lines that live inside one read chunk are delivered directly from that chunk. Only the
/// unfinished line at a chunk boundary is copied into `carry`, so ordinary short-line JSONL avoids
/// copying every byte through a second accumulator. The callback is synchronous and must not retain
/// the supplied slice. Empty lines are ignored and, by default, a final line without a trailing newline
/// is delivered. Tail readers can retain that final partial line for the next append instead.
enum JSONLFileReader {
    private static let chunkSize = 64 * 1024
    /// Usage records are normally tiny. A corrupt or prompt-heavy newline-free record must not be able
    /// to make a menu-bar process retain unbounded memory while looking for the next newline.
    private static let maxLineBytes = 64 * 1024 * 1024

    /// Deterministic resource counters used by efficiency regression tests. They measure chunk-level
    /// I/O and carry-buffer copies only, avoiding per-line bookkeeping on the production hot path.
    struct Statistics: Equatable, Sendable {
        var bytesRead = 0
        var chunksRead = 0
        var bytesCopiedIntoCarry = 0
        var peakCarryBytes = 0
        var oversizedLinesSkipped = 0
    }

    /// `finalPartial` and `isDiscardingOversizedLine` are continuation state for an append-only reader.
    /// A normal full-file caller uses only `succeeded`/`statistics`.
    struct ReadResult: Equatable, Sendable {
        var succeeded: Bool
        var statistics: Statistics
        var finalPartial: Data
        var isDiscardingOversizedLine: Bool
    }

    static func forEachLine(at url: URL, _ body: (Data.SubSequence) -> Void) -> Bool {
        readLines(at: url, chunkSize: chunkSize, body).succeeded
    }

    /// Internal/testable form with configurable chunk/record bounds and append-resume state.
    ///
    /// When `deliverFinalPartial` is false, bytes after the final newline are returned in
    /// `finalPartial` instead of being delivered. Pass them back as `initialCarry` while starting the
    /// next read at the previous EOF; this prevents a writer caught halfway through one JSON object
    /// from losing the first half of that object.
    static func readLines(
        at url: URL,
        chunkSize: Int,
        startOffset: UInt64 = 0,
        initialCarry: Data = Data(),
        discardingOversizedLine: Bool = false,
        deliverFinalPartial: Bool = true,
        maxLineBytes: Int = maxLineBytes,
        _ body: (Data.SubSequence) -> Void
    ) -> ReadResult {
        precondition(chunkSize > 0)
        precondition(maxLineBytes > 0)
        precondition(initialCarry.count <= maxLineBytes)
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return ReadResult(
                succeeded: false,
                statistics: Statistics(),
                finalPartial: initialCarry,
                isDiscardingOversizedLine: discardingOversizedLine
            )
        }
        defer { try? handle.close() }

        do {
            if startOffset > 0 {
                try handle.seek(toOffset: startOffset)
            }
        } catch {
            return ReadResult(
                succeeded: false,
                statistics: Statistics(),
                finalPartial: initialCarry,
                isDiscardingOversizedLine: discardingOversizedLine
            )
        }

        var statistics = Statistics()
        var carry = initialCarry
        statistics.peakCarryBytes = carry.count
        carry.reserveCapacity(min(maxLineBytes, max(carry.count, min(chunkSize, 4 * 1024))))
        var discarding = discardingOversizedLine

        func deliver(_ line: Data.SubSequence) {
            guard !line.isEmpty else { return }
            #if canImport(ObjectiveC)
            autoreleasepool {
                body(line)
            }
            #else
            body(line)
            #endif
        }

        // Whether the last chunk attempt hit EOF (stop cleanly) or a read error (fail the scan).
        var readFailed = false
        var reachedEnd = false

        while !reachedEnd {
            // FileHandle reads are synchronous, so cancellation cannot interrupt one in-flight read.
            // Checking once per chunk bounds canceled work to at most one chunk plus its line parsing.
            guard !Task.isCancelled else {
                return ReadResult(
                    succeeded: false,
                    statistics: statistics,
                    finalPartial: carry,
                    isDiscardingOversizedLine: discarding
                )
            }

            // Each chunk gets its own autorelease pool so its read buffer is released every
            // `chunkSize` bytes rather than at end-of-file.
            //
            // `NSFileHandle.read(upToCount:)` autoreleases an ~80 KB buffer per call (it rounds the
            // 64 KB request up to 81,920 bytes), and it is called from the chunk loop — *outside*
            // `deliver`'s per-line pool. So every buffer a file allocated piled into the pool the
            // caller opened around the whole parse, which only drains when that file finishes. On a
            // multi-GB corpus `leaks --autoreleasePools` measured **1,025 MB across 13,126
            // NSConcreteData** sitting in pools, which is the bulk of a cold scan's footprint: the
            // app itself holds almost nothing (live heap ~25 MB, largest owned array 1.06 MB).
            JSONLAccountingWorkPacer.shared.perform {
                autoreleasepool {
                    let chunk: Data
                    do {
                        guard let next = try handle.read(upToCount: chunkSize), !next.isEmpty else {
                            reachedEnd = true
                            return
                        }
                        chunk = next
                    } catch {
                        readFailed = true
                        reachedEnd = true
                        return
                    }

                    statistics.bytesRead += chunk.count
                    statistics.chunksRead += 1
                    Self.splitAndDeliver(
                        chunk,
                        carry: &carry,
                        discarding: &discarding,
                        statistics: &statistics,
                        maxLineBytes: maxLineBytes,
                        deliver: deliver
                    )
                }
            }
        }

        if readFailed {
            return ReadResult(
                succeeded: false,
                statistics: statistics,
                finalPartial: carry,
                isDiscardingOversizedLine: discarding
            )
        }

        if deliverFinalPartial, !discarding, !carry.isEmpty {
            deliver(carry[...])
            carry.removeAll(keepingCapacity: true)
        }
        return ReadResult(
            succeeded: true,
            statistics: statistics,
            finalPartial: carry,
            isDiscardingOversizedLine: discarding
        )
    }

    /// Split one chunk into newline-delimited lines and hand each to `deliver`, carrying an
    /// unterminated tail into the next chunk. Split out of `readLines` so the caller can wrap a whole
    /// chunk — read plus split — in one autorelease pool.
    private static func splitAndDeliver(
        _ chunk: Data,
        carry: inout Data,
        discarding: inout Bool,
        statistics: inout Statistics,
        maxLineBytes: Int,
        deliver: (Data.SubSequence) -> Void
    ) {
        var segmentStart = chunk.startIndex
        while segmentStart < chunk.endIndex,
              let newline = chunk[segmentStart...].firstIndex(of: UInt8(ascii: "\n"))
        {
            if discarding {
                // We already exceeded the bound in an earlier chunk. The newline ends that one
                // rejected logical record; later records in this same chunk remain eligible.
                discarding = false
            } else if carry.isEmpty {
                let line = chunk[segmentStart..<newline]
                if line.count <= maxLineBytes {
                    deliver(line)
                } else {
                    statistics.oversizedLinesSkipped += 1
                }
            } else {
                let continuation = chunk[segmentStart..<newline]
                if carry.count + continuation.count <= maxLineBytes {
                    if !continuation.isEmpty {
                        carry.append(contentsOf: continuation)
                        statistics.bytesCopiedIntoCarry += continuation.count
                        statistics.peakCarryBytes = max(statistics.peakCarryBytes, carry.count)
                    }
                    deliver(carry[...])
                } else {
                    statistics.oversizedLinesSkipped += 1
                }
                carry.removeAll(keepingCapacity: true)
            }
            segmentStart = chunk.index(after: newline)
        }

        if segmentStart < chunk.endIndex, !discarding {
            let tail = chunk[segmentStart..<chunk.endIndex]
            if carry.count + tail.count <= maxLineBytes {
                carry.append(contentsOf: tail)
                statistics.bytesCopiedIntoCarry += tail.count
                statistics.peakCarryBytes = max(statistics.peakCarryBytes, carry.count)
            } else {
                // Drop the accumulated bytes immediately and ignore continuation chunks until
                // the next newline. This is the memory safety boundary for malformed giant rows.
                statistics.oversizedLinesSkipped += 1
                carry.removeAll(keepingCapacity: true)
                discarding = true
            }
        }
}

}
