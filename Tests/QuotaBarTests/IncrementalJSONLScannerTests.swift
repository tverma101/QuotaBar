import Foundation
import XCTest
@testable import QuotaBar

final class IncrementalJSONLScannerTests: XCTestCase {
    func testPersistedCacheSurvivesFreshScannerInstanceAndIsScopedByIdentity() async throws {
        let base = try makeDirectory("Persistence")
        defer { try? FileManager.default.removeItem(at: base) }
        let file = try makeFile(named: "usage.jsonl", contents: "7", in: base, mtime: Date())
        let persistence = makePersistence(in: base)

        let firstCounter = ParseCounter()
        let first = IncrementalJSONLScanner<Int>(persistence: persistence)
        let firstItems = await first.items(
            from: [file], since: .distantPast, cacheIdentity: "home-a", parse: firstCounter.parse
        )
        XCTAssertEqual(firstItems, [7])
        XCTAssertEqual(firstCounter.count, 1)
        await first.waitForPendingWritesForTesting()

        let relaunchedCounter = ParseCounter()
        let relaunched = IncrementalJSONLScanner<Int>(persistence: persistence)
        let relaunchedItems = await relaunched.items(
            from: [file], since: .distantPast, cacheIdentity: "home-a", parse: relaunchedCounter.parse
        )
        XCTAssertEqual(relaunchedItems, [7])
        XCTAssertEqual(relaunchedCounter.count, 0, "an unchanged file should decode from the persisted cache")

        let otherHomeCounter = ParseCounter()
        let otherHome = IncrementalJSONLScanner<Int>(persistence: persistence)
        _ = await otherHome.items(
            from: [file], since: .distantPast, cacheIdentity: "home-b", parse: otherHomeCounter.parse
        )
        XCTAssertEqual(otherHomeCounter.count, 1, "a different home identity must not inherit another home's cache")
        await otherHome.waitForPendingWritesForTesting()
    }

    func testPersistedCacheInvalidatesWhenSizeOrMtimeChanges() async throws {
        let base = try makeDirectory("StatInvalidation")
        defer { try? FileManager.default.removeItem(at: base) }
        let now = Date()
        let firstFile = try makeFile(named: "a.jsonl", contents: "1", in: base, mtime: now)
        let secondFile = try makeFile(named: "b.jsonl", contents: "2", in: base, mtime: now)
        let persistence = makePersistence(in: base)

        let seed = IncrementalJSONLScanner<Int>(persistence: persistence)
        _ = await seed.items(
            from: [firstFile, secondFile], since: .distantPast, cacheIdentity: "home", parse: ParseCounter().parse
        )
        await seed.waitForPendingWritesForTesting()

        let firstURL = URL(fileURLWithPath: firstFile.path)
        try Data("11".utf8).write(to: firstURL)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: firstFile.path)
        let resizedValues = try firstURL.resourceValues(forKeys: [
            .fileSizeKey, .contentModificationDateKey, .attributeModificationDateKey,
        ])
        let resized = JSONLScanning.DiscoveredFile(
            path: firstFile.path,
            size: try XCTUnwrap(resizedValues.fileSize),
            mtime: try XCTUnwrap(resizedValues.contentModificationDate),
            attributeMtime: resizedValues.attributeModificationDate
        )
        let sizeCounter = ParseCounter()
        let afterSizeChange = IncrementalJSONLScanner<Int>(persistence: persistence)
        let resizedItems = await afterSizeChange.items(
            from: [resized, secondFile], since: .distantPast, cacheIdentity: "home", parse: sizeCounter.parse
        )
        XCTAssertEqual(resizedItems, [11, 2])
        XCTAssertEqual(sizeCounter.count, 1)
        await afterSizeChange.waitForPendingWritesForTesting()

        let secondURL = URL(fileURLWithPath: secondFile.path)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(1)],
            ofItemAtPath: secondFile.path
        )
        let touchedValues = try secondURL.resourceValues(forKeys: [
            .fileSizeKey, .contentModificationDateKey, .attributeModificationDateKey,
        ])
        let touched = JSONLScanning.DiscoveredFile(
            path: secondFile.path,
            size: try XCTUnwrap(touchedValues.fileSize),
            mtime: try XCTUnwrap(touchedValues.contentModificationDate),
            attributeMtime: touchedValues.attributeModificationDate
        )
        let mtimeCounter = ParseCounter()
        let afterMtimeChange = IncrementalJSONLScanner<Int>(persistence: persistence)
        let touchedItems = await afterMtimeChange.items(
            from: [resized, touched], since: .distantPast, cacheIdentity: "home", parse: mtimeCounter.parse
        )
        XCTAssertEqual(touchedItems, [11, 2])
        XCTAssertEqual(mtimeCounter.count, 1)
        await afterMtimeChange.waitForPendingWritesForTesting()
    }

    func testPersistedCacheInvalidatesOnSchemaVersionChange() async throws {
        let base = try makeDirectory("SchemaInvalidation")
        defer { try? FileManager.default.removeItem(at: base) }
        let file = try makeFile(named: "usage.jsonl", contents: "7", in: base, mtime: Date())
        let versionOne = makePersistence(in: base)
        let seed = IncrementalJSONLScanner<Int>(persistence: versionOne)
        _ = await seed.items(from: [file], since: .distantPast, cacheIdentity: "home", parse: ParseCounter().parse)
        await seed.waitForPendingWritesForTesting()

        let versionTwo = makePersistence(in: base, schemaVersion: 2)
        let counter = ParseCounter()
        let rebuilt = IncrementalJSONLScanner<Int>(persistence: versionTwo)
        let rebuiltItems = await rebuilt.items(
            from: [file], since: .distantPast, cacheIdentity: "home", parse: counter.parse
        )
        XCTAssertEqual(rebuiltItems, [7])
        XCTAssertEqual(counter.count, 1)
        await rebuilt.waitForPendingWritesForTesting()
    }

    func testDebouncedPersistenceWritesLatestPrunedSnapshot() async throws {
        let base = try makeDirectory("Pruning")
        defer { try? FileManager.default.removeItem(at: base) }
        let now = Date()
        let firstFile = try makeFile(
            named: "a.jsonl", contents: "1", in: base, mtime: now.addingTimeInterval(-10)
        )
        let secondFile = try makeFile(named: "b.jsonl", contents: "2", in: base, mtime: now)
        let persistence = makePersistence(in: base)
        let scanner = IncrementalJSONLScanner<Int>(persistence: persistence)
        let parser = ParseCounter()

        _ = await scanner.items(
            from: [firstFile, secondFile], since: .distantPast, cacheIdentity: "home", parse: parser.parse
        )
        _ = await scanner.items(
            from: [secondFile], since: now.addingTimeInterval(-1), cacheIdentity: "home", parse: parser.parse
        )
        await scanner.waitForPendingWritesForTesting()

        let relaunchedParser = ParseCounter()
        let relaunched = IncrementalJSONLScanner<Int>(persistence: persistence)
        let relaunchedItems = await relaunched.items(
            from: [firstFile, secondFile],
            since: .distantPast,
            cacheIdentity: "home",
            parse: relaunchedParser.parse
        )
        XCTAssertEqual(relaunchedItems, [1, 2])
        XCTAssertEqual(relaunchedParser.count, 1, "the pruned file should reparse while the retained file stays cached")
        await relaunched.waitForPendingWritesForTesting()
    }

    func testChangingOneFileRewritesOnlyItsPersistedRecord() async throws {
        let base = try makeDirectory("IncrementalWrites")
        defer { try? FileManager.default.removeItem(at: base) }
        let now = Date()
        let firstFile = try makeFile(named: "a.jsonl", contents: "1", in: base, mtime: now)
        let secondFile = try makeFile(named: "b.jsonl", contents: "2", in: base, mtime: now)
        let persistence = makePersistence(in: base)
        let scanner = IncrementalJSONLScanner<Int>(persistence: persistence)
        _ = await scanner.items(
            from: [firstFile, secondFile], since: .distantPast, cacheIdentity: "home", parse: ParseCounter().parse
        )
        await scanner.waitForPendingWritesForTesting()

        let firstRecordValue = await scanner.cacheRecordURLForTesting(identity: "home", filePath: firstFile.path)
        let secondRecordValue = await scanner.cacheRecordURLForTesting(identity: "home", filePath: secondFile.path)
        let firstRecord = try XCTUnwrap(firstRecordValue)
        let secondRecord = try XCTUnwrap(secondRecordValue)
        let sentinel = Date(timeIntervalSince1970: 1_000_000)
        try FileManager.default.setAttributes([.modificationDate: sentinel], ofItemAtPath: firstRecord.path)
        try FileManager.default.setAttributes([.modificationDate: sentinel], ofItemAtPath: secondRecord.path)

        let changedURL = URL(fileURLWithPath: firstFile.path)
        try Data("11".utf8).write(to: changedURL)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(1)],
            ofItemAtPath: firstFile.path
        )
        let changedValues = try changedURL.resourceValues(forKeys: [
            .fileSizeKey, .contentModificationDateKey, .attributeModificationDateKey,
        ])
        let changed = JSONLScanning.DiscoveredFile(
            path: firstFile.path,
            size: try XCTUnwrap(changedValues.fileSize),
            mtime: try XCTUnwrap(changedValues.contentModificationDate),
            attributeMtime: changedValues.attributeModificationDate
        )
        _ = await scanner.items(
            from: [changed, secondFile], since: .distantPast, cacheIdentity: "home", parse: ParseCounter().parse
        )
        await scanner.waitForPendingWritesForTesting()

        let firstMtime = try modificationDate(of: firstRecord)
        let secondMtime = try modificationDate(of: secondRecord)
        XCTAssertGreaterThan(firstMtime, sentinel)
        XCTAssertEqual(secondMtime, sentinel, "an unchanged source record must not be rewritten")
    }

    func testDisjointScansSharingIdentityKeepEachOthersParsedFiles() async throws {
        let base = try makeDirectory("SharedSubsets")
        defer { try? FileManager.default.removeItem(at: base) }
        let now = Date()
        let firstFile = try makeFile(named: "a.jsonl", contents: "1", in: base, mtime: now)
        let secondFile = try makeFile(named: "b.jsonl", contents: "2", in: base, mtime: now)
        let persistence = makePersistence(in: base)
        let parser = ParseCounter()
        let scanner = IncrementalJSONLScanner<Int>(persistence: persistence)

        let firstItems = await scanner.items(
            from: [firstFile], since: .distantPast, cacheIdentity: "home", parse: parser.parse
        )
        let secondItems = await scanner.items(
            from: [secondFile], since: .distantPast, cacheIdentity: "home", parse: parser.parse
        )
        let firstItemsAgain = await scanner.items(
            from: [firstFile], since: .distantPast, cacheIdentity: "home", parse: parser.parse
        )
        XCTAssertEqual(firstItems, [1])
        XCTAssertEqual(secondItems, [2])
        XCTAssertEqual(firstItemsAgain, [1])
        XCTAssertEqual(parser.count, 2)
        await scanner.waitForPendingWritesForTesting()

        let relaunchedParser = ParseCounter()
        let relaunched = IncrementalJSONLScanner<Int>(persistence: persistence)
        let allItems = await relaunched.items(
            from: [firstFile, secondFile],
            since: .distantPast,
            cacheIdentity: "home",
            parse: relaunchedParser.parse
        )
        XCTAssertEqual(allItems, [1, 2])
        XCTAssertEqual(relaunchedParser.count, 0)
    }

    func testStaleIdentityDirectoryIsPruned() async throws {
        let base = try makeDirectory("IdentityPruning")
        defer { try? FileManager.default.removeItem(at: base) }
        let persistence = makePersistence(in: base)
        let file = try makeFile(named: "usage.jsonl", contents: "7", in: base, mtime: Date())
        let scanner = IncrementalJSONLScanner<Int>(persistence: persistence)
        _ = await scanner.items(from: [file], since: .distantPast, cacheIdentity: "old-home", parse: ParseCounter().parse)
        await scanner.waitForPendingWritesForTesting()

        let identityDirectory = JSONLScanCachePaths.identityDirectory(
            persistence: persistence,
            identity: "old-home"
        )
        let old = Date().addingTimeInterval(-JSONLScanCachePaths.staleIdentityRetention - 60)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: identityDirectory.path)
        await JSONLScanCacheWriter.shared.pruneStaleIdentities(
            persistence: persistence,
            before: Date().addingTimeInterval(-JSONLScanCachePaths.staleIdentityRetention)
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: identityDirectory.path))
    }

    func testConcurrentScansOfSameIdentityParseEachFileOnce() async throws {
        let base = try makeDirectory("SharedScanner")
        defer { try? FileManager.default.removeItem(at: base) }
        let file = try makeFile(named: "usage.jsonl", contents: "7", in: base, mtime: Date())
        let parser = ParseCounter(delay: 0.03)
        let scanner = IncrementalJSONLScanner<Int>()

        async let first = scanner.items(
            from: [file], since: .distantPast, cacheIdentity: "shared-home", parse: parser.parse
        )
        async let second = scanner.items(
            from: [file], since: .distantPast, cacheIdentity: "shared-home", parse: parser.parse
        )

        let results = await [first, second]
        XCTAssertEqual(results, [[7], [7]])
        XCTAssertEqual(parser.count, 1)
    }

    func testLimitsConcurrentParsesAndKeepsFileOrder() async throws {
        let directory = try makeDirectory("Concurrency")
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date()
        let files = try (0..<6).map { index in
            let url = directory.appendingPathComponent(String(format: "%02d.jsonl", index))
            let data = Data("\(index)".utf8)
            try data.write(to: url)
            return JSONLScanning.DiscoveredFile(path: url.path, size: data.count, mtime: now)
        }
        let probe = ConcurrencyProbe()
        let scanner = IncrementalJSONLScanner<Int>(maxConcurrentParses: 3)

        let items = await scanner.items(from: files, since: now.addingTimeInterval(-1)) { data in
            probe.begin()
            defer { probe.end() }
            Thread.sleep(forTimeInterval: 0.01)
            return String(data: data, encoding: .utf8).flatMap(Int.init).map { [$0] }
        }

        XCTAssertEqual(items, Array(0..<6))
        XCTAssertLessThanOrEqual(probe.maximumActive, 3)
    }

    func testURLParserOverloadKeepsFileOrderAndCache() async throws {
        let directory = try makeDirectory("URLParser")
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        let firstFile = try makeFile(named: "a.jsonl", contents: "1", in: directory, mtime: now)
        let secondFile = try makeFile(named: "b.jsonl", contents: "2", in: directory, mtime: now)
        let parser = ParseCounter()
        let scanner = IncrementalJSONLScanner<Int>()

        let first = await scanner.items(
            from: [firstFile, secondFile],
            since: .distantPast,
            cacheIdentity: "home",
            parseFile: parser.parseFile(at:)
        )
        let second = await scanner.items(
            from: [firstFile, secondFile],
            since: .distantPast,
            cacheIdentity: "home",
            parseFile: parser.parseFile(at:)
        )

        XCTAssertEqual(first, [1, 2])
        XCTAssertEqual(second, [1, 2])
        XCTAssertEqual(parser.count, 2)
    }

    func testJSONLFileReaderPreservesLongAndFinalLines() throws {
        let directory = try makeDirectory("StreamingReader")
        defer { try? FileManager.default.removeItem(at: directory) }
        let longLine = String(repeating: "x", count: 70_000)
        let url = directory.appendingPathComponent("usage.jsonl")
        try Data("\(longLine)\nsecond\nfinal".utf8).write(to: url)

        var lines: [String] = []
        XCTAssertTrue(JSONLFileReader.forEachLine(at: url) { line in
            lines.append(String(decoding: line, as: UTF8.self))
        })

        XCTAssertEqual(lines, [longLine, "second", "final"])
    }

    func testUnreadableFileWarnsOnceUntilItRecovers() async throws {
        let directory = try makeDirectory("Warnings")
        defer { try? FileManager.default.removeItem(at: directory) }

        let path = directory.appendingPathComponent("unreadable.jsonl")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let file = JSONLScanning.DiscoveredFile(path: path.path, size: 0, mtime: Date())
        let warnings = WarningRecorder()
        let scanner = IncrementalJSONLScanner<Int>(readFailureWarning: warnings.record)
        let parse: @Sendable (Data) -> [Int]? = { data in
            String(data: data, encoding: .utf8).flatMap(Int.init).map { [$0] }
        }

        _ = await scanner.items(from: [file], since: .distantPast, parse: parse)
        _ = await scanner.items(from: [file], since: .distantPast, parse: parse)
        XCTAssertEqual(warnings.counts, [1])

        try FileManager.default.removeItem(at: path)
        try Data("7".utf8).write(to: path)
        let recoveredFile = JSONLScanning.DiscoveredFile(
            path: path.path,
            size: 1,
            mtime: file.mtime.addingTimeInterval(1)
        )
        let recovered = await scanner.items(from: [recoveredFile], since: .distantPast, parse: parse)
        XCTAssertEqual(recovered, [7])

        try FileManager.default.removeItem(at: path)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let failedAgainFile = JSONLScanning.DiscoveredFile(
            path: path.path,
            size: 0,
            mtime: file.mtime.addingTimeInterval(2)
        )
        _ = await scanner.items(from: [failedAgainFile], since: .distantPast, parse: parse)
        XCTAssertEqual(warnings.counts, [1, 1])
    }

    func testScanningAnotherBatchDoesNotForgetAnUnreadableFile() async throws {
        let directory = try makeDirectory("WarningBatches")
        defer { try? FileManager.default.removeItem(at: directory) }

        let unreadableURL = directory.appendingPathComponent("a.jsonl")
        try FileManager.default.createDirectory(at: unreadableURL, withIntermediateDirectories: true)
        let readableURL = directory.appendingPathComponent("b.jsonl")
        try Data("7".utf8).write(to: readableURL)

        let now = Date()
        let unreadable = JSONLScanning.DiscoveredFile(path: unreadableURL.path, size: 0, mtime: now)
        let readable = JSONLScanning.DiscoveredFile(path: readableURL.path, size: 1, mtime: now)
        let warnings = WarningRecorder()
        let scanner = IncrementalJSONLScanner<Int>(readFailureWarning: warnings.record)
        let parse: @Sendable (Data) -> [Int]? = { data in
            String(data: data, encoding: .utf8).flatMap(Int.init).map { [$0] }
        }

        _ = await scanner.items(from: [unreadable], since: .distantPast, parse: parse)
        _ = await scanner.items(from: [readable], since: .distantPast, parse: parse)
        _ = await scanner.items(from: [unreadable], since: .distantPast, parse: parse)

        XCTAssertEqual(warnings.counts, [1])
    }

    func testJsonlFilesFollowsSymlinkedRoot() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsageScannerSymlink-\(UUID().uuidString)", isDirectory: true)
        let real = base.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try Data("{}".utf8).write(to: real.appendingPathComponent("a.jsonl"))
        let link = base.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let files = JSONLScanning.jsonlFiles(under: link)

        XCTAssertEqual(files.map { ($0.path as NSString).lastPathComponent }, ["a.jsonl"])
    }

    func testMissingFileDoesNotWarn() async {
        let warnings = WarningRecorder()
        let scanner = IncrementalJSONLScanner<Int>(readFailureWarning: warnings.record)
        let file = JSONLScanning.DiscoveredFile(
            path: "/tmp/openusage-missing-\(UUID().uuidString).jsonl",
            size: 0,
            mtime: Date()
        )

        _ = await scanner.items(from: [file], since: .distantPast, parse: { _ in [] })

        XCTAssertEqual(warnings.counts, [])
    }

    func testUnloadAfterReturnClearsResidentItemsAndPersistsNonEmptyRecords() async throws {
        let base = try makeDirectory("UnloadPersist")
        defer { try? FileManager.default.removeItem(at: base) }
        let file = try makeFile(named: "usage.jsonl", contents: "7", in: base, mtime: Date())
        let persistence = makePersistence(in: base)
        let counter = ParseCounter()
        let scanner = IncrementalJSONLScanner<Int>(
            retainResidentItems: false,
            persistence: persistence
        )

        let first = await scanner.items(
            from: [file], since: .distantPast, cacheIdentity: "home", parse: counter.parse
        )
        XCTAssertEqual(first, [7])
        XCTAssertEqual(counter.count, 1)
        let residentAfterFirst = await scanner.residentItemCountForTesting()
        XCTAssertEqual(residentAfterFirst, 0)

        await scanner.waitForPendingWritesForTesting()
        let recordURLValue = await scanner.cacheRecordURLForTesting(identity: "home", filePath: file.path)
        let recordURL = try XCTUnwrap(recordURLValue)
        let recordData = try Data(contentsOf: recordURL)
        let record = try PropertyListDecoder().decode(JSONLScanCacheRecord<Int>.self, from: recordData)
        XCTAssertEqual(record.items, [7], "eager upsert snapshots must persist real items, not an empty unload")

        let second = await scanner.items(
            from: [file], since: .distantPast, cacheIdentity: "home", parse: counter.parse
        )
        XCTAssertEqual(second, [7])
        XCTAssertEqual(counter.count, 1, "unchanged refresh should hydrate from disk instead of reparsing")
        let residentAfterSecond = await scanner.residentItemCountForTesting()
        XCTAssertEqual(residentAfterSecond, 0)
    }

    func testUnloadModeSecondRefreshUsesDiskHydrateWithoutMultiplyingParses() async throws {
        let base = try makeDirectory("UnloadHydrate")
        defer { try? FileManager.default.removeItem(at: base) }
        let now = Date()
        let firstFile = try makeFile(named: "a.jsonl", contents: "1", in: base, mtime: now)
        let secondFile = try makeFile(named: "b.jsonl", contents: "2", in: base, mtime: now)
        let persistence = makePersistence(in: base)
        let counter = ParseCounter()
        let scanner = IncrementalJSONLScanner<Int>(
            retainResidentItems: false,
            persistence: persistence
        )

        let first = await scanner.items(
            from: [firstFile, secondFile],
            since: .distantPast,
            cacheIdentity: "home",
            parse: counter.parse
        )
        XCTAssertEqual(first, [1, 2])
        await scanner.flushPendingWrites()
        let residentAfterFlush = await scanner.residentItemCountForTesting()
        XCTAssertEqual(residentAfterFlush, 0)

        // Fresh scanner forces metadata-only identity load, then per-file hydrate.
        let relaunchedCounter = ParseCounter()
        let relaunched = IncrementalJSONLScanner<Int>(
            retainResidentItems: false,
            persistence: persistence
        )
        let second = await relaunched.items(
            from: [firstFile, secondFile],
            since: .distantPast,
            cacheIdentity: "home",
            parse: relaunchedCounter.parse
        )
        XCTAssertEqual(second, [1, 2])
        XCTAssertEqual(relaunchedCounter.count, 0)
        let residentAfterRelaunch = await relaunched.residentItemCountForTesting()
        XCTAssertEqual(residentAfterRelaunch, 0)
    }

    private func makeDirectory(_ suffix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsageScanner\(suffix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makePersistence(in directory: URL, schemaVersion: Int = 1) -> JSONLScanCachePersistence {
        JSONLScanCachePersistence(
            namespace: "test",
            schemaVersion: schemaVersion,
            directory: directory.appendingPathComponent("cache"),
            writeDebounce: .milliseconds(1)
        )
    }

    private func makeFile(named name: String, contents: String, in directory: URL, mtime: Date) throws
        -> JSONLScanning.DiscoveredFile
    {
        let url = directory.appendingPathComponent(name)
        let data = Data(contents.utf8)
        try data.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        let values = try url.resourceValues(forKeys: [
            .fileSizeKey, .contentModificationDateKey, .attributeModificationDateKey,
        ])
        return JSONLScanning.DiscoveredFile(
            path: url.path,
            size: try XCTUnwrap(values.fileSize),
            mtime: try XCTUnwrap(values.contentModificationDate),
            attributeMtime: values.attributeModificationDate
        )
    }

    private func modificationDate(of url: URL) throws -> Date {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.modificationDate] as? Date)
    }
}

extension IncrementalJSONLScannerTests {
    /// Regression for a real retention bug: the cache was published fully hydrated *before* the
    /// visit loop drained it, so a cancellation between those two points returned with every
    /// file's items still resident in the actor. Nothing released them until the next *successful*
    /// scan, so a refresh that hit its deadline stranded the whole window — up to ~20 MB on a large
    /// corpus, indefinitely.
    ///
    /// Cancellation is routine rather than exotic: `WidgetDataStore` wraps provider refreshes in a
    /// 120 s `ProviderRefreshDeadline`, and the loop re-checks `Task.isCancelled` once per file, so
    /// any corpus long enough to run past the deadline lands here.
    func testCancellationDuringVisitUnloadsItemsTheVisitLoopNeverReached() async throws {
        let base = try makeDirectory("CancelVisitStrand")
        defer { try? FileManager.default.removeItem(at: base) }
        let now = Date()
        let first = try makeFile(named: "a.jsonl", contents: "1", in: base, mtime: now)
        let second = try makeFile(named: "b.jsonl", contents: "2", in: base, mtime: now)
        let scanner = IncrementalJSONLScanner<Int>(
            retainResidentItems: false,
            persistence: makePersistence(in: base)
        )

        // The loop re-checks cancellation per *file*, so cancelling on the first visited item lets
        // `first` drain normally and leaves `second` never reached — the shape that used to strand
        // `second`'s items.
        let visit = FirstVisitSignal()
        let handle = SelfCanceller()
        let task = Task { _ in
            await scanner.foldItems(
                from: [first, second],
                since: .distantPast,
                cacheIdentity: "home",
                parseFile: { _ in [7] },
                visit: { _ in visit.signal() }
            )
        }
        handle.adopt(task)
        // Race-free: fires immediately if the visit already happened, otherwise the moment it does.
        visit.onFirstVisit { handle.cancel() }

        _ = await task.value

        let stranded = await scanner.residentItemCountForTesting()
        XCTAssertEqual(
            stranded, 0,
            "a cancelled fold must not leave unvisited files' items resident in the scanner"
        )
    }

    /// `retainResidentItems: true` is an explicit request to keep items, so cancellation must *not*
    /// unload them. Guards the fix from over-reaching.
    func testCancellationKeepsResidentItemsWhenCallerAskedForThem() async throws {
        let base = try makeDirectory("CancelRetainIntent")
        defer { try? FileManager.default.removeItem(at: base) }
        let now = Date()
        let first = try makeFile(named: "a.jsonl", contents: "1", in: base, mtime: now)
        let second = try makeFile(named: "b.jsonl", contents: "2", in: base, mtime: now)
        let scanner = IncrementalJSONLScanner<Int>(
            retainResidentItems: true,
            persistence: makePersistence(in: base)
        )

        let visit = FirstVisitSignal()
        let handle = SelfCanceller()
        let task = Task { _ in
            await scanner.foldItems(
                from: [first, second],
                since: .distantPast,
                cacheIdentity: "home",
                parseFile: { _ in [7] },
                visit: { _ in visit.signal() }
            )
        }
        handle.adopt(task)
        visit.onFirstVisit { handle.cancel() }

        _ = await task.value

        let retained = await scanner.residentItemCountForTesting()
        XCTAssertEqual(retained, 2, "retainResidentItems: true asks for items to stay")
    }
}

/// Runs a closure the first time the visit loop is entered, whether that has already happened or
/// happens later — so a test can react to it without racing the fold.
private final class FirstVisitSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var signalled = false
    private var waiter: (() -> Void)?

    func signal() {
        lock.lock()
        signalled = true
        let pending = waiter
        waiter = nil
        lock.unlock()
        pending?()
    }

    func onFirstVisit(_ block: @escaping () -> Void) {
        lock.lock()
        if signalled {
            lock.unlock()
            block()
        } else {
            waiter = block
            lock.unlock()
        }
    }
}

/// Lets a synchronous closure cancel the task it is running inside, which needs a handle to that
/// task. Adoption and cancellation are both idempotent and lock-guarded.
private final class SelfCanceller: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var cancelled = false

    func adopt(_ task: Task<Void, Never>) {
        lock.lock()
        self.task = task
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        guard !cancelled else { lock.unlock(); return }
        cancelled = true
        let handle = task
        lock.unlock()
        handle?.cancel()
    }
}
