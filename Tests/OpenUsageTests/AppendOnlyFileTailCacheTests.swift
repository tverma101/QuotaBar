import Foundation
import XCTest
@testable import OpenUsage

final class AppendOnlyFileTailCacheTests: XCTestCase {
    func testAnchorStaysStableAcrossPureAppendAndChangesAcrossPrefixRewrite() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsage-AppendProbe-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("usage.jsonl")
        try Data("abcdef".utf8).write(to: url)

        let initialRevision = try XCTUnwrap(AppendOnlyFileProbe.revision(at: url))
        let initialAnchor = try XCTUnwrap(AppendOnlyFileProbe.anchor(at: url, endingAt: 6))

        let writer = try FileHandle(forWritingTo: url)
        try writer.seekToEnd()
        try writer.write(contentsOf: Data("-append".utf8))
        try writer.close()

        let appendedRevision = try XCTUnwrap(AppendOnlyFileProbe.revision(at: url))
        XCTAssertEqual(appendedRevision.device, initialRevision.device)
        XCTAssertEqual(appendedRevision.inode, initialRevision.inode)
        XCTAssertGreaterThan(appendedRevision.size, initialRevision.size)
        XCTAssertEqual(AppendOnlyFileProbe.anchor(at: url, endingAt: 6), initialAnchor)

        let rewriter = try FileHandle(forWritingTo: url)
        try rewriter.seek(toOffset: 2)
        try rewriter.write(contentsOf: Data("Z".utf8))
        try rewriter.close()

        let rewrittenRevision = try XCTUnwrap(AppendOnlyFileProbe.revision(at: url))
        XCTAssertEqual(rewrittenRevision.inode, initialRevision.inode, "the test must exercise an in-place rewrite")
        XCTAssertNotEqual(AppendOnlyFileProbe.anchor(at: url, endingAt: 6), initialAnchor)
    }

    func testSparsePrefixSignatureDetectsRewriteFarFromOldEOF() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsage-SparseProbe-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("large.jsonl")
        let original = Data(repeating: 0x41, count: 512 * 1024)
        try original.write(to: url)

        let revision = try XCTUnwrap(AppendOnlyFileProbe.revision(at: url))
        let signature = try XCTUnwrap(AppendOnlyFileProbe.anchor(at: url, endingAt: revision.size))

        // Rewrite around the midpoint while preserving inode and size. The old implementation only
        // sampled the final 512 bytes and would have missed this entire class of prefix mutation.
        let rewriter = try FileHandle(forWritingTo: url)
        try rewriter.seek(toOffset: revision.size / 2)
        try rewriter.write(contentsOf: Data(repeating: 0x5A, count: 128))
        try rewriter.close()

        let after = try XCTUnwrap(AppendOnlyFileProbe.revision(at: url))
        XCTAssertEqual(after.device, revision.device)
        XCTAssertEqual(after.inode, revision.inode)
        XCTAssertEqual(after.size, revision.size)
        XCTAssertNotEqual(
            AppendOnlyFileProbe.anchor(at: url, endingAt: revision.size),
            signature,
            "append verification must sample the historical prefix, not only the bytes immediately before EOF"
        )
    }

    func testLRUEvictionBoundsLongRunningCheckpointState() {
        let cache = AppendOnlyFileTailCache<Int, Int>(maxEntries: 2)
        cache.store(entry(items: [1]), for: "a", parseKind: .full, bytesRead: 10)
        cache.store(entry(items: [2]), for: "b", parseKind: .full, bytesRead: 20)
        XCTAssertNotNil(cache.entry(for: "a"), "touch a so b becomes the least-recently-used checkpoint")

        cache.store(entry(items: [3]), for: "c", parseKind: .tail, bytesRead: 3)

        XCTAssertEqual(cache.entryCountForTesting(), 2)
        XCTAssertNotNil(cache.entry(for: "a"))
        XCTAssertNil(cache.entry(for: "b"))
        XCTAssertNotNil(cache.entry(for: "c"))
        XCTAssertEqual(cache.statistics(for: "c")?.tailParses, 1)
        XCTAssertEqual(cache.statistics(for: "c")?.bytesRead, 3)
    }

    func testRetainedItemBudgetEvictsOldCheckpointsBeforeRAMCanGrowWithoutBound() {
        let cache = AppendOnlyFileTailCache<Int, Int>(maxEntries: 100, maxRetainedItems: 10)
        cache.store(entry(items: Array(0..<6)), for: "old", parseKind: .full, bytesRead: 60)
        cache.store(entry(items: Array(10..<16)), for: "new", parseKind: .full, bytesRead: 60)

        XCTAssertLessThanOrEqual(cache.retainedItemCountForTesting(), 10)
        XCTAssertNil(cache.entry(for: "old"), "the least-recently-used retained history should be sacrificed first")
        XCTAssertNotNil(cache.entry(for: "new"))
    }

    func testUnloadRetainedItemsClearsArraysButKeepsCheckpoints() {
        let cache = AppendOnlyFileTailCache<Int, Int>(maxEntries: 10, maxRetainedItems: 100)
        cache.store(entry(items: Array(0..<5)), for: "a", parseKind: .full, bytesRead: 50)
        cache.store(entry(items: Array(5..<9)), for: "b", parseKind: .tail, bytesRead: 40)
        XCTAssertEqual(cache.retainedItemCountForTesting(), 9)
        XCTAssertEqual(cache.entryCountForTesting(), 2)

        cache.unloadRetainedItems()

        XCTAssertEqual(cache.retainedItemCountForTesting(), 0)
        XCTAssertEqual(cache.entryCountForTesting(), 2)
        let a = cache.entry(for: "a")
        let b = cache.entry(for: "b")
        XCTAssertEqual(a?.items, [])
        XCTAssertEqual(b?.items, [])
        XCTAssertEqual(a?.itemsAvailable, false)
        XCTAssertEqual(b?.itemsAvailable, false)
        XCTAssertEqual(a?.offset, 10)
        XCTAssertEqual(b?.offset, 10)
        XCTAssertEqual(a?.anchor, Data("anchor".utf8))

        cache.store(entry(items: [1, 2]), for: "a", parseKind: .full, bytesRead: 20)
        XCTAssertEqual(cache.entry(for: "a")?.itemsAvailable, true)
    }

    private func entry(items: [Int]) -> AppendOnlyFileTailCache<Int, Int>.Entry {
        AppendOnlyFileTailCache<Int, Int>.Entry(
            revision: AppendOnlyFileRevision(device: 1, inode: 1, size: 10),
            offset: 10,
            anchor: Data("anchor".utf8),
            partialLine: Data(),
            isDiscardingOversizedLine: false,
            parserState: 0,
            items: items
        )
    }
}
