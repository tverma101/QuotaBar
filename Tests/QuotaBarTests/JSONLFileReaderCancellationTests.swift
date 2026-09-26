import Foundation
import XCTest
@testable import QuotaBar

final class JSONLFileReaderCancellationTests: XCTestCase {
    func testCancellationStopsBeforeReadingAnotherChunk() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsageJSONLCancellationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("usage.jsonl")
        try Data("first\nsecond\nthird\nfourth\n".utf8).write(to: url, options: .atomic)

        let task = Task {
            var deliveredLines = 0
            return JSONLFileReader.readLines(at: url, chunkSize: 8) { _ in
                deliveredLines += 1
                if deliveredLines == 1 {
                    withUnsafeCurrentTask { current in
                        current?.cancel()
                    }
                }
            }
        }

        let result = await task.value
        XCTAssertFalse(result.succeeded, "a canceled refresh must not report a complete parse")
        XCTAssertEqual(result.statistics.chunksRead, 1, "cancellation must be observed before another chunk read")
        XCTAssertEqual(result.statistics.bytesRead, 8)
    }
}
