import Foundation
import XCTest
@testable import QuotaBar

final class JSONLFileReaderEfficiencyTests: XCTestCase {
    func testShortLineCorpusCopiesOnlyChunkBoundaryFragments() throws {
        let directory = try temporaryDirectory(named: "ShortLines")
        defer { try? FileManager.default.removeItem(at: directory) }

        let line = String(repeating: "x", count: 36)
        let lineCount = 10_000
        let data = Data(Array(repeating: line, count: lineCount).joined(separator: "\n").appending("\n").utf8)
        let url = directory.appendingPathComponent("usage.jsonl")
        try data.write(to: url)

        var delivered = 0
        let result = JSONLFileReader.readLines(at: url, chunkSize: 4 * 1024) { slice in
            XCTAssertEqual(slice.count, line.utf8.count)
            delivered += 1
        }

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(delivered, lineCount)
        XCTAssertEqual(result.statistics.bytesRead, data.count)
        XCTAssertLessThan(
            result.statistics.bytesCopiedIntoCarry,
            data.count / 10,
            "short-line JSONL should not be copied wholesale through a second buffer"
        )
        XCTAssertLessThanOrEqual(
            result.statistics.peakCarryBytes,
            line.utf8.count,
            "carry memory should be bounded by the line crossing a chunk boundary, not corpus size"
        )
        XCTAssertEqual(result.statistics.oversizedLinesSkipped, 0)
    }

    func testPeakCarryTracksLongestLineInsteadOfWholeFile() throws {
        let directory = try temporaryDirectory(named: "LongBoundaryLine")
        defer { try? FileManager.default.removeItem(at: directory) }

        let shortLine = "small"
        let longLine = String(repeating: "L", count: 70_000)
        let contents = Array(repeating: shortLine, count: 2_000)
            .joined(separator: "\n") + "\n" + longLine + "\nfinal"
        let data = Data(contents.utf8)
        let url = directory.appendingPathComponent("usage.jsonl")
        try data.write(to: url)

        var lengths: [Int] = []
        let result = JSONLFileReader.readLines(at: url, chunkSize: 4 * 1024) { line in
            lengths.append(line.count)
        }

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.statistics.bytesRead, data.count)
        XCTAssertEqual(lengths.count, 2_002)
        XCTAssertEqual(lengths[2_000], longLine.utf8.count)
        XCTAssertEqual(lengths.last, 5)
        XCTAssertLessThanOrEqual(result.statistics.peakCarryBytes, longLine.utf8.count)
        XCTAssertLessThan(result.statistics.peakCarryBytes, data.count)
    }

    func testChunkBoundaryParsingPreservesEmptyLineAndFinalLineSemantics() throws {
        let directory = try temporaryDirectory(named: "BoundarySemantics")
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("usage.jsonl")
        try Data("alpha\n\nbeta-beta\nfinal".utf8).write(to: url)

        var lines: [String] = []
        let result = JSONLFileReader.readLines(at: url, chunkSize: 3) { line in
            lines.append(String(decoding: line, as: UTF8.self))
        }

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(lines, ["alpha", "beta-beta", "final"])
        XCTAssertTrue(result.finalPartial.isEmpty)
    }

    func testTailReadCarriesHalfWrittenRecordAcrossRefreshes() throws {
        let directory = try temporaryDirectory(named: "TailResume")
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("usage.jsonl")
        let firstBytes = Data("first\npartial".utf8)
        try firstBytes.write(to: url)

        var firstLines: [String] = []
        let first = JSONLFileReader.readLines(
            at: url,
            chunkSize: 4,
            deliverFinalPartial: false
        ) { line in
            firstLines.append(String(decoding: line, as: UTF8.self))
        }
        XCTAssertTrue(first.succeeded)
        XCTAssertEqual(firstLines, ["first"])
        XCTAssertEqual(String(decoding: first.finalPartial, as: UTF8.self), "partial")
        XCTAssertEqual(first.statistics.bytesRead, firstBytes.count)

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("-done\nsecond\n".utf8))
        try handle.close()

        var appendedLines: [String] = []
        let appended = JSONLFileReader.readLines(
            at: url,
            chunkSize: 3,
            startOffset: UInt64(firstBytes.count),
            initialCarry: first.finalPartial,
            deliverFinalPartial: false
        ) { line in
            appendedLines.append(String(decoding: line, as: UTF8.self))
        }

        XCTAssertTrue(appended.succeeded)
        XCTAssertEqual(appendedLines, ["partial-done", "second"])
        XCTAssertEqual(appended.statistics.bytesRead, Data("-done\nsecond\n".utf8).count)
        XCTAssertTrue(appended.finalPartial.isEmpty)
    }

    func testOversizedRecordIsDroppedWithoutUnboundedCarryAndNextRecordSurvives() throws {
        let directory = try temporaryDirectory(named: "Oversized")
        defer { try? FileManager.default.removeItem(at: directory) }

        let maxLineBytes = 32 * 1024
        let oversized = String(repeating: "X", count: maxLineBytes * 8)
        let url = directory.appendingPathComponent("usage.jsonl")
        try Data("\(oversized)\nok\n".utf8).write(to: url)

        var lines: [String] = []
        let result = JSONLFileReader.readLines(
            at: url,
            chunkSize: 4 * 1024,
            maxLineBytes: maxLineBytes
        ) { line in
            lines.append(String(decoding: line, as: UTF8.self))
        }

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(lines, ["ok"])
        XCTAssertEqual(result.statistics.oversizedLinesSkipped, 1)
        XCTAssertLessThanOrEqual(
            result.statistics.peakCarryBytes,
            maxLineBytes,
            "a newline-free corrupt record must never make carry grow beyond the configured resource envelope"
        )
        XCTAssertTrue(result.finalPartial.isEmpty)
    }

    func testOversizedPartialRemainsDiscardedUntilLaterNewline() throws {
        let directory = try temporaryDirectory(named: "OversizedTail")
        defer { try? FileManager.default.removeItem(at: directory) }

        let maxLineBytes = 1_024
        let url = directory.appendingPathComponent("usage.jsonl")
        let firstBytes = Data(String(repeating: "X", count: maxLineBytes * 4).utf8)
        try firstBytes.write(to: url)

        let first = JSONLFileReader.readLines(
            at: url,
            chunkSize: 256,
            deliverFinalPartial: false,
            maxLineBytes: maxLineBytes
        ) { _ in XCTFail("oversized partial must not be delivered") }
        XCTAssertTrue(first.isDiscardingOversizedLine)
        XCTAssertTrue(first.finalPartial.isEmpty)
        XCTAssertEqual(first.statistics.oversizedLinesSkipped, 1)

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("still-giant\nok\n".utf8))
        try handle.close()

        var lines: [String] = []
        let second = JSONLFileReader.readLines(
            at: url,
            chunkSize: 4,
            startOffset: UInt64(firstBytes.count),
            discardingOversizedLine: first.isDiscardingOversizedLine,
            deliverFinalPartial: false,
            maxLineBytes: maxLineBytes
        ) { line in
            lines.append(String(decoding: line, as: UTF8.self))
        }
        XCTAssertTrue(second.succeeded)
        XCTAssertEqual(lines, ["ok"])
        XCTAssertFalse(second.isDiscardingOversizedLine)
    }

    func testMissingFileDoesNoReadWork() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("missing.jsonl")

        let result = JSONLFileReader.readLines(at: url, chunkSize: 4 * 1024) { _ in
            XCTFail("a missing file must not deliver lines")
        }

        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.statistics, JSONLFileReader.Statistics())
    }

    private func temporaryDirectory(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsage-JSONLReader-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

extension JSONLFileReaderEfficiencyTests {
    /// Regression guard for the cold-scan footprint (1,817 MB -> 536 MB).
    ///
    /// `NSFileHandle.read` autoreleases a buffer per chunk, and the read sits in the chunk loop rather
    /// than inside `deliver`'s per-line pool. Before each chunk got its own pool, every buffer a file
    /// allocated piled into the pool the caller opened around the whole parse and only drained at
    /// end-of-file — so retention grew with *corpus size*, not chunk count. `leaks --autoreleasePools`
    /// measured 1,025 MB across 13,126 `NSConcreteData` in pools on a 9.8 GB corpus.
    ///
    /// A 48 MB file read in 4 KB chunks is 12,288 reads. If their buffers are not released per chunk,
    /// the test process grows by more than the file it just read; with the fix it barely moves. The
    /// bound is deliberately loose — this asserts the shape of the fix, not a precise figure, because
    /// a footprint delta is inherently noisy under a shared test runner.
    func testReadBuffersAreReleasedPerChunkNotAccumulatedPerFile() throws {
        let directory = try temporaryDirectory(named: "PerChunkRelease")
        defer { try? FileManager.default.removeItem(at: directory) }

        let line = String(repeating: "y", count: 512)
        let lineCount = 96_000
        let corpusBytes = lineCount * (line.utf8.count + 1)
        let url = directory.appendingPathComponent("usage.jsonl")
        try makeCorpus(at: url, line: line, count: lineCount)

        // Warm the allocator and the reader's own code paths first, so the measurement below reflects
        // steady-state retention rather than one-time first-touch page faults.
        for _ in 0..<2 {
            _ = JSONLFileReader.readLines(at: url, chunkSize: 4 * 1024) { _ in }
        }

        let before = ProcessMemoryBudget.physicalFootprintBytes() ?? 0
        var delivered = 0
        let result = JSONLFileReader.readLines(at: url, chunkSize: 4 * 1024) { _ in delivered += 1 }
        let after = ProcessMemoryBudget.physicalFootprintBytes() ?? 0

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(delivered, lineCount, "the reader must still deliver every line")
        XCTAssertEqual(result.statistics.bytesRead, corpusBytes)
        XCTAssertGreaterThan(result.statistics.chunksRead, 1_000, "the corpus must span many chunks for this to mean anything")

        let growth = after > before ? after - before : 0
        XCTAssertLessThan(
            growth,
            UInt64(corpusBytes) / 2,
            "reading \(corpusBytes / 1_048_576) MB must not retain a multiple of it; growth was \(growth / 1_048_576) MB"
        )
    }

    private func makeCorpus(at url: URL, line: String, count: Int) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? handle.close() }
        // Write in batches so the test does not build a 48 MB string in memory itself.
        let batch = Array(repeating: line, count: 2_000).joined(separator: "\n") + "\n"
        let batches = count / 2_000
        for _ in 0..<batches {
            try handle.write(contentsOf: Data(batch.utf8))
        }
        let remainder = count % 2_000
        if remainder > 0 {
            let tail = Array(repeating: line, count: remainder).joined(separator: "\n") + "\n"
            try handle.write(contentsOf: Data(tail.utf8))
        }
    }
}
