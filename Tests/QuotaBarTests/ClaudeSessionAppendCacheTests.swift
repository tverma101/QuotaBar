import Foundation
import XCTest
@testable import QuotaBar

/// Append-cache behaviour for the Claude session logs: only the appended bytes are read, a rewritten
/// or rotated file falls back to a full parse, and a row that is completed by a later append is
/// counted exactly once.
final class ClaudeSessionAppendCacheTests: XCTestCase {
    private typealias Entry = ClaudeLogUsageScanner.Entry

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuotaBar-ClaudeAppendCache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Trash instead of delete: the scratch directory stays recoverable until the OS empties it.
        try? FileManager.default.trashItem(at: directory, resultingItemURL: nil)
        directory = nil
    }

    // MARK: - Appending

    func testAppendReadsOnlyTheAppendedBytesAndKeepsExactTotals() throws {
        let url = directory.appendingPathComponent("session.jsonl")
        let first = Self.usageLine(timestamp: "2026-02-20T12:00:00Z", input: 10, output: 5, id: "m1") + "\n"
        let second = Self.usageLine(timestamp: "2026-02-20T12:01:00Z", input: 20, output: 7, id: "m2") + "\n"
        try Data((first + second).utf8).write(to: url)

        let cache = ClaudeSessionAppendCache()
        let initial = try XCTUnwrap(cache.parse(at: url, parseLine: Self.parseLine))
        XCTAssertEqual(initial.map(\.tokens.input), [10, 20])
        XCTAssertEqual(initial.reduce(0) { $0 + $1.tokens.input }, 30)

        var statistics = try XCTUnwrap(cache.statistics(path: url.path))
        XCTAssertEqual(statistics.fullParses, 1)
        XCTAssertEqual(statistics.tailParses, 0)
        XCTAssertEqual(statistics.bytesRead, (first + second).utf8.count)

        let third = Self.usageLine(timestamp: "2026-02-20T12:02:00Z", input: 30, output: 9, id: "m3") + "\n"
        try append(third, to: url)

        let updated = try XCTUnwrap(cache.parse(at: url, parseLine: Self.parseLine))
        XCTAssertEqual(updated.map(\.tokens.input), [10, 20, 30])
        XCTAssertEqual(updated.reduce(0) { $0 + $1.tokens.input }, 60)

        statistics = try XCTUnwrap(cache.statistics(path: url.path))
        XCTAssertEqual(statistics.fullParses, 1, "a growing file must not be re-read from the start")
        XCTAssertEqual(statistics.tailParses, 1)
        XCTAssertEqual(
            statistics.bytesRead,
            (first + second).utf8.count + third.utf8.count,
            "the second refresh must pay only for the appended bytes"
        )
    }

    func testUnchangedFileIsNotReadAgain() throws {
        let url = directory.appendingPathComponent("unchanged.jsonl")
        let text = Self.usageLine(timestamp: "2026-02-20T12:00:00Z", input: 10, output: 5, id: "m1") + "\n"
        try Data(text.utf8).write(to: url)

        let cache = ClaudeSessionAppendCache()
        let first = try XCTUnwrap(cache.parse(at: url, parseLine: Self.parseLine))
        XCTAssertEqual(first.map(\.tokens.input), [10])

        let second = try XCTUnwrap(cache.parse(at: url, parseLine: Self.parseLine))
        XCTAssertEqual(second.map(\.tokens.input), [10])

        let statistics = try XCTUnwrap(cache.statistics(path: url.path))
        XCTAssertEqual(statistics.fullParses, 1)
        XCTAssertEqual(statistics.tailParses, 0)
        XCTAssertEqual(
            statistics.bytesRead,
            text.utf8.count,
            "a file that did not change must not be read a second time"
        )
    }

    // MARK: - Rewrites, truncation and rotation

    func testSameSizeRewriteFallsBackToAFullParse() throws {
        let url = directory.appendingPathComponent("rewrite.jsonl")
        let original = Self.usageLine(timestamp: "2026-02-20T12:00:00Z", input: 10, output: 5, id: "m1") + "\n"
        try Data(original.utf8).write(to: url)

        let cache = ClaudeSessionAppendCache()
        let first = try XCTUnwrap(cache.parse(at: url, parseLine: Self.parseLine))
        XCTAssertEqual(first.map(\.tokens.input), [10])

        // Same length, same inode: only the modification times and the prefix signature can tell
        // that the file was rewritten in place.
        let replacement = Self.usageLine(timestamp: "2026-02-20T12:00:00Z", input: 99, output: 5, id: "m1") + "\n"
        XCTAssertEqual(replacement.utf8.count, original.utf8.count)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Data(replacement.utf8))
        try handle.close()

        let second = try XCTUnwrap(cache.parse(at: url, parseLine: Self.parseLine))
        XCTAssertEqual(second.map(\.tokens.input), [99], "the rewritten row must replace the cached one")

        let statistics = try XCTUnwrap(cache.statistics(path: url.path))
        XCTAssertEqual(statistics.fullParses, 2)
        XCTAssertEqual(statistics.tailParses, 0)
    }

    func testTruncationFallsBackToAFullParse() throws {
        let url = directory.appendingPathComponent("truncated.jsonl")
        let first = Self.usageLine(timestamp: "2026-02-20T12:00:00Z", input: 10, output: 5, id: "m1") + "\n"
        let second = Self.usageLine(timestamp: "2026-02-20T12:01:00Z", input: 20, output: 7, id: "m2") + "\n"
        try Data((first + second).utf8).write(to: url)

        let cache = ClaudeSessionAppendCache()
        _ = try XCTUnwrap(cache.parse(at: url, parseLine: Self.parseLine))

        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(first.utf8.count))
        try handle.close()

        let truncated = try XCTUnwrap(cache.parse(at: url, parseLine: Self.parseLine))
        XCTAssertEqual(truncated.map(\.tokens.input), [10], "the truncated row must not survive")

        let statistics = try XCTUnwrap(cache.statistics(path: url.path))
        XCTAssertEqual(statistics.fullParses, 2)
        XCTAssertEqual(statistics.tailParses, 0)
    }

    func testRotationFallsBackToAFullParse() throws {
        let url = directory.appendingPathComponent("rotated.jsonl")
        let first = Self.usageLine(timestamp: "2026-02-20T12:00:00Z", input: 10, output: 5, id: "m1") + "\n"
        let second = Self.usageLine(timestamp: "2026-02-20T12:01:00Z", input: 20, output: 7, id: "m2") + "\n"
        try Data((first + second).utf8).write(to: url)

        let cache = ClaudeSessionAppendCache()
        let initial = try XCTUnwrap(cache.parse(at: url, parseLine: Self.parseLine))
        XCTAssertEqual(initial.map(\.tokens.input), [10, 20])
        let originalInode = try XCTUnwrap(AppendOnlyFileProbe.revision(at: url)).inode

        // A different file takes the place of the old one: the path now points at another inode.
        // The replacement is created while the original still exists, so it cannot reuse its inode.
        let replacementURL = directory.appendingPathComponent("rotated-replacement.jsonl")
        try Data(first.utf8).write(to: replacementURL)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: replacementURL, to: url)
        let rotatedInode = try XCTUnwrap(AppendOnlyFileProbe.revision(at: url)).inode
        XCTAssertNotEqual(rotatedInode, originalInode, "the test must exercise a real rotation")

        let rotated = try XCTUnwrap(cache.parse(at: url, parseLine: Self.parseLine))
        XCTAssertEqual(rotated.map(\.tokens.input), [10], "the rotated file must be parsed from scratch")

        let statistics = try XCTUnwrap(cache.statistics(path: url.path))
        XCTAssertEqual(statistics.fullParses, 2)
        XCTAssertEqual(statistics.tailParses, 0)
    }

    // MARK: - Provisional final row

    func testFinalRowWithoutNewlineIsCountedOnceWhenItCompletesLater() throws {
        let url = directory.appendingPathComponent("fragment.jsonl")
        let first = Self.usageLine(timestamp: "2026-02-20T12:00:00Z", input: 10, output: 5, id: "m1") + "\n"
        let second = Self.usageLine(timestamp: "2026-02-20T12:01:00Z", input: 20, output: 7, id: "m2")
        try Data((first + second).utf8).write(to: url)

        let cache = ClaudeSessionAppendCache()
        let before = try XCTUnwrap(cache.parse(at: url, parseLine: Self.parseLine))
        XCTAssertEqual(before.map(\.tokens.input), [10, 20], "a complete final row counts once")

        let third = Self.usageLine(timestamp: "2026-02-20T12:02:00Z", input: 30, output: 9, id: "m3") + "\n"
        try append("\n" + third, to: url)

        let after = try XCTUnwrap(cache.parse(at: url, parseLine: Self.parseLine))
        XCTAssertEqual(after.map(\.tokens.input), [10, 20, 30])
        XCTAssertEqual(
            after.reduce(0) { $0 + $1.tokens.input },
            60,
            "the completed final row must not be counted twice"
        )

        let statistics = try XCTUnwrap(cache.statistics(path: url.path))
        XCTAssertEqual(statistics.fullParses, 1)
        XCTAssertEqual(statistics.tailParses, 1)
        XCTAssertEqual(
            statistics.bytesRead,
            (first + second).utf8.count + (second + "\n" + third).utf8.count,
            "the trailing fragment is re-read, the committed history is not"
        )
    }

    func testRowSplitAcrossAppendsIsParsedOnceWhenItCompletes() throws {
        let url = directory.appendingPathComponent("split.jsonl")
        let first = Self.usageLine(timestamp: "2026-02-20T12:00:00Z", input: 10, output: 5, id: "m1") + "\n"
        let second = Self.usageLine(timestamp: "2026-02-20T12:01:00Z", input: 20, output: 7, id: "m2") + "\n"
        // Split the row right before its usage object: the half-written row carries no usage yet, so
        // the intermediate parse is complete and must not be published as a finished row.
        let marker = try XCTUnwrap(second.range(of: #""usage":{"#))
        let head = String(second[..<marker.lowerBound])
        let tail = String(second[marker.lowerBound...])
        try Data((first + head).utf8).write(to: url)

        let cache = ClaudeSessionAppendCache()
        let before = try XCTUnwrap(cache.parse(at: url, parseLine: Self.parseLine))
        XCTAssertEqual(before.map(\.tokens.input), [10], "a half-written row must not be counted")

        try append(tail, to: url)

        let after = try XCTUnwrap(cache.parse(at: url, parseLine: Self.parseLine))
        XCTAssertEqual(after.map(\.tokens.input), [10, 20], "the completed row must be counted exactly once")
        XCTAssertEqual(after.reduce(0) { $0 + $1.tokens.input }, 30)
    }

    // MARK: - Failures

    func testMalformedRowNeverPublishesACheckpointAndTheRetryRecovers() throws {
        let url = directory.appendingPathComponent("malformed.jsonl")
        let first = Self.usageLine(timestamp: "2026-02-20T12:00:00Z", input: 10, output: 5, id: "m1") + "\n"
        try Data(first.utf8).write(to: url)

        let cache = ClaudeSessionAppendCache()
        _ = try XCTUnwrap(cache.parse(at: url, parseLine: Self.parseLine))
        XCTAssertNotNil(cache.statistics(path: url.path))

        let broken = #"{"timestamp":"2026-02-20T12:05:00Z","message":{"usage":{"input_tokens":oops}}"# + "\n"
        try append(broken, to: url)

        XCTAssertNil(
            cache.parse(at: url, parseLine: Self.parseLine),
            "a malformed usage row must make the file unusable"
        )
        XCTAssertNil(cache.statistics(path: url.path), "a malformed scan must not publish a checkpoint")

        // The writer repairs the file: the next parse starts over and returns the valid rows only.
        let second = Self.usageLine(timestamp: "2026-02-20T12:06:00Z", input: 20, output: 7, id: "m2") + "\n"
        try Data((first + second).utf8).write(to: url)

        let recovered = try XCTUnwrap(cache.parse(at: url, parseLine: Self.parseLine))
        XCTAssertEqual(recovered.map(\.tokens.input), [10, 20])
        let statistics = try XCTUnwrap(cache.statistics(path: url.path))
        XCTAssertEqual(statistics.fullParses, 1, "the retry after a malformed scan is a full parse")
        XCTAssertEqual(statistics.tailParses, 0)
    }

    func testUnloadingRetainedRowsForcesAFullReparseWithoutLosingRows() throws {
        let url = directory.appendingPathComponent("unloaded.jsonl")
        let first = Self.usageLine(timestamp: "2026-02-20T12:00:00Z", input: 10, output: 5, id: "m1") + "\n"
        let second = Self.usageLine(timestamp: "2026-02-20T12:01:00Z", input: 20, output: 7, id: "m2") + "\n"
        try Data((first + second).utf8).write(to: url)

        let cache = ClaudeSessionAppendCache()
        let initial = try XCTUnwrap(cache.parse(at: url, parseLine: Self.parseLine))
        XCTAssertEqual(initial.map(\.tokens.input), [10, 20])

        cache.unloadRetainedItems()
        XCTAssertEqual(cache.retainedItemCountForTesting(), 0)

        let third = Self.usageLine(timestamp: "2026-02-20T12:02:00Z", input: 30, output: 9, id: "m3") + "\n"
        try append(third, to: url)

        let after = try XCTUnwrap(cache.parse(at: url, parseLine: Self.parseLine))
        XCTAssertEqual(after.map(\.tokens.input), [10, 20, 30], "an unload must not lose rows")

        let statistics = try XCTUnwrap(cache.statistics(path: url.path))
        XCTAssertEqual(statistics.fullParses, 2, "without retained rows the file has to be parsed again")
        XCTAssertEqual(statistics.tailParses, 0)
    }

    // MARK: - Bounds

    func testCacheStaysBoundedAcrossManyFilesAndRows() throws {
        let cache = ClaudeSessionAppendCache(maxEntries: 2, maxRetainedItems: 4)
        for index in 0..<5 {
            let url = directory.appendingPathComponent("bounded-\(index).jsonl")
            let text = Self.usageLine(timestamp: "2026-02-20T12:00:00Z", input: index + 1, output: 5, id: "m\(index)") + "\n"
                + Self.usageLine(timestamp: "2026-02-20T12:01:00Z", input: index + 1, output: 7, id: "n\(index)") + "\n"
            try Data(text.utf8).write(to: url)
            let entries = try XCTUnwrap(cache.parse(at: url, parseLine: Self.parseLine))
            XCTAssertEqual(entries.count, 2)
        }

        XCTAssertLessThanOrEqual(cache.entryCountForTesting(), 2, "the file count must stay bounded")
        XCTAssertLessThanOrEqual(cache.retainedItemCountForTesting(), 4, "the retained rows must stay bounded")
    }

    func testSharedCacheUsesTheDocumentedBounds() {
        XCTAssertEqual(ClaudeSessionAppendCache.defaultMaxEntries, 8)
        XCTAssertEqual(ClaudeSessionAppendCache.defaultMaxRetainedItems, 16_000)
        XCTAssertEqual(ClaudeSessionAppendCache.shared.maxEntries, 8)
        XCTAssertEqual(ClaudeSessionAppendCache.shared.maxRetainedItems, 16_000)
    }

    func testClearingAPathDropsItsCheckpoint() throws {
        let url = directory.appendingPathComponent("cleared.jsonl")
        let text = Self.usageLine(timestamp: "2026-02-20T12:00:00Z", input: 10, output: 5, id: "m1") + "\n"
        try Data(text.utf8).write(to: url)

        let cache = ClaudeSessionAppendCache()
        _ = try XCTUnwrap(cache.parse(at: url, parseLine: Self.parseLine))
        XCTAssertNotNil(cache.statistics(path: url.path))

        cache.clear(path: url.path)
        XCTAssertNil(cache.statistics(path: url.path))
        XCTAssertEqual(cache.entryCountForTesting(), 0)
    }

    func testCancelledScanReturnsNothingAndPublishesNothing() async throws {
        let url = directory.appendingPathComponent("cancelled.jsonl")
        let text = Self.usageLine(timestamp: "2026-02-20T12:00:00Z", input: 10, output: 5, id: "m1") + "\n"
        try Data(text.utf8).write(to: url)

        let cache = ClaudeSessionAppendCache()
        let task = Task {
            // Wait for the cancellation instead of racing it, so the parse really runs cancelled.
            while !Task.isCancelled { await Task.yield() }
            return ClaudeSessionAppendCacheTests.parseEntries(cache, at: url)
        }
        task.cancel()

        let result = await task.value
        XCTAssertNil(result, "a cancelled scan must not answer with rows")
        XCTAssertNil(cache.statistics(path: url.path), "a cancelled scan must not publish a checkpoint")
        XCTAssertEqual(cache.entryCountForTesting(), 0)
    }

    func testSameSizeRewriteDuringReadOutsideAnchorSamplesCannotPublish() throws {
        let url = directory.appendingPathComponent("rewritten-during-read.jsonl")
        let usage = Self.usageLine(timestamp: "2026-02-20T12:00:00Z", input: 10, output: 5, id: "m1")
        let padding = "{\"kind\":\"padding\",\"text\":\"" + String(repeating: "x", count: 1_000_000) + "\"}"
        try Data((usage + "\n" + padding + "\n").utf8).write(to: url)
        let size = try XCTUnwrap(AppendOnlyFileProbe.revision(at: url)).size
        let beforeAnchor = try XCTUnwrap(AppendOnlyFileProbe.anchor(at: url, endingAt: size))
        var rewrote = false
        let cache = ClaudeSessionAppendCache()
        let result = cache.parse(at: url) { line in
            if !rewrote {
                rewrote = true
                let handle = try! FileHandle(forWritingTo: url)
                try! handle.seek(toOffset: 30_000)
                try! handle.write(contentsOf: Data("y".utf8))
                try! handle.close()
            }
            return Self.parseLine(line) ?? []
        }
        let afterAnchor = try XCTUnwrap(AppendOnlyFileProbe.anchor(at: url, endingAt: size))
        XCTAssertEqual(beforeAnchor, afterAnchor, "the fixture must bypass the sampled-byte detector")
        XCTAssertNil(result, "changed metadata must reject a hybrid read even when its samples match")
        XCTAssertNil(cache.statistics(path: url.path))
    }

    func testCancellationByFinalFragmentParserCannotPublishCheckpoint() async throws {
        let url = directory.appendingPathComponent("cancelled-fragment.jsonl")
        try Data(Self.usageLine(timestamp: "2026-02-20T12:00:00Z", input: 10, output: 5, id: "m1").utf8).write(to: url)
        let cache = ClaudeSessionAppendCache()
        let task = Task {
            ClaudeSessionAppendCacheTests.parseCancellingMidParse(cache, at: url)
        }
        let result = await task.value
        XCTAssertNil(result)
        XCTAssertNil(cache.statistics(path: url.path))
    }

    // MARK: - Helpers

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    private static func usageLine(
        timestamp: String,
        input: Int,
        output: Int,
        id: String
    ) -> String {
        #"{"timestamp":"\#(timestamp)","message":{"id":"\#(id)","model":"claude-test-model","usage":{"input_tokens":\#(input),"output_tokens":\#(output)}}}"#
    }

    /// Mirrors the Claude scanner's line semantics: a row without usage data carries no rows, a
    /// malformed usage row is reported as `nil` so the whole file can be rejected.
    private nonisolated static func parseLine(_ line: Data.SubSequence) -> [Entry]? {
        let data = Data(line)
        guard data.range(of: Data(#""usage":{"#.utf8)) != nil else { return [] }
        guard let entry = ClaudeLogUsageScanner.parseLine(data) else { return nil }
        return [entry]
    }

    /// The cancel tests call `parse` from a Task body, and the CI toolchain's region-based
    /// isolation checker cannot verify a parse call carrying a closure parameter formed there.
    /// Routing through plain nonisolated statics keeps the parse call out of the task closure.
    private nonisolated static func parseEntries(
        _ cache: ClaudeSessionAppendCache,
        at url: URL
    ) -> [Entry]? {
        cache.parse(at: url, parseLine: parseLine)
    }

    /// Parses `url` with a line callback that cancels the running task mid-parse, so a test can
    /// prove a cancellation raised while the fragment parser runs cannot publish a checkpoint.
    private nonisolated static func parseCancellingMidParse(
        _ cache: ClaudeSessionAppendCache,
        at url: URL
    ) -> [Entry]? {
        cache.parse(at: url) { line in
            withUnsafeCurrentTask { $0?.cancel() }
            return parseLine(line)
        }
    }
}
