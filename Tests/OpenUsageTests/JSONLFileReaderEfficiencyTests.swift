import Foundation
import XCTest
@testable import OpenUsage

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
