import Foundation
import XCTest
@testable import OpenUsage

/// Long-run deterministic contracts. These count actual work/state instead of asserting noisy wall-clock
/// time or RSS on shared CI hardware. A stable corpus may incur metadata/cache lookups each refresh, but
/// it must not repeatedly decode session contents, multiply parser concurrency, or retain every account
/// or home identity ever observed during a long-running menu-bar process.
final class ResourceSoakContractTests: XCTestCase {
    func testOneThousandUnchangedRefreshesDoZeroAdditionalDecodeWork() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsage-Soak-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let now = Date()
        let files = try (0..<64).map { index -> JSONLScanning.DiscoveredFile in
            let url = directory.appendingPathComponent(String(format: "%03d.jsonl", index))
            let data = Data("\(index)".utf8)
            try data.write(to: url)
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

        let counter = ParseCounter()
        let scanner = IncrementalJSONLScanner<Int>(maxConcurrentParses: 2)
        let first = await scanner.items(
            from: files,
            since: now.addingTimeInterval(-60),
            cacheIdentity: "stable-home",
            parse: counter.parse
        )
        XCTAssertEqual(first?.count, files.count)
        XCTAssertEqual(counter.count, files.count)

        for _ in 0..<1_000 {
            let result = await scanner.items(
                from: files,
                since: now.addingTimeInterval(-60),
                cacheIdentity: "stable-home",
                parse: counter.parse
            )
            XCTAssertEqual(result?.count, files.count)
        }

        XCTAssertEqual(
            counter.count,
            files.count,
            "a stable 64-session corpus refreshed 1,000 times must decode each file exactly once"
        )
    }

    func testManyParallelCallersStillShareOneScannerParseBudget() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsage-ParallelSoak-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let url = directory.appendingPathComponent("usage.jsonl")
        try Data("7".utf8).write(to: url)
        let values = try url.resourceValues(forKeys: [
            .fileSizeKey, .contentModificationDateKey, .attributeModificationDateKey,
        ])
        let file = JSONLScanning.DiscoveredFile(
            path: url.path,
            size: try XCTUnwrap(values.fileSize),
            mtime: try XCTUnwrap(values.contentModificationDate),
            attributeMtime: values.attributeModificationDate
        )
        let probe = ConcurrencyProbe()
        let scanner = IncrementalJSONLScanner<Int>(maxConcurrentParses: 2)

        await withTaskGroup(of: Void.self) { group in
            for identity in 0..<32 {
                group.addTask {
                    _ = await scanner.items(
                        from: [file],
                        since: .distantPast,
                        cacheIdentity: "home-\(identity)"
                    ) { data in
                        probe.begin()
                        defer { probe.end() }
                        Thread.sleep(forTimeInterval: 0.002)
                        return String(data: data, encoding: .utf8).flatMap(Int.init).map { [$0] }
                    }
                }
            }
        }

        XCTAssertLessThanOrEqual(
            probe.maximumActive,
            2,
            "dozens of simultaneous homes/sessions on one scanner must not exceed its local parse budget"
        )
    }

    func testDifferentProviderScannersShareOneProcessWideParseBudget() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsage-CrossScannerSoak-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let now = Date()
        let files = try (0..<12).map { index -> JSONLScanning.DiscoveredFile in
            let url = directory.appendingPathComponent(String(format: "%02d.jsonl", index))
            try Data("\(index)".utf8).write(to: url)
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

        let probe = ConcurrencyProbe()
        let providerA = IncrementalJSONLScanner<Int>(maxConcurrentParses: 4)
        let providerB = IncrementalJSONLScanner<Int>(maxConcurrentParses: 4)
        let parser: @Sendable (Data) -> [Int]? = { data in
            probe.begin()
            defer { probe.end() }
            Thread.sleep(forTimeInterval: 0.004)
            return String(data: data, encoding: .utf8).flatMap(Int.init).map { [$0] }
        }

        async let first = providerA.items(
            from: files,
            since: now.addingTimeInterval(-60),
            cacheIdentity: "provider-a",
            parse: parser
        )
        async let second = providerB.items(
            from: files,
            since: now.addingTimeInterval(-60),
            cacheIdentity: "provider-b",
            parse: parser
        )
        let results = await [first, second]

        XCTAssertEqual(results[0]?.count, files.count)
        XCTAssertEqual(results[1]?.count, files.count)
        XCTAssertLessThanOrEqual(
            probe.maximumActive,
            2,
            "independent provider scanners must share the process-wide budget instead of multiplying CPU work"
        )
    }

    func testAccountAndHomeChurnCannotGrowResidentScannerStateWithoutBound() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsage-IdentityChurn-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let url = directory.appendingPathComponent("usage.jsonl")
        try Data("42".utf8).write(to: url)
        let values = try url.resourceValues(forKeys: [
            .fileSizeKey, .contentModificationDateKey, .attributeModificationDateKey,
        ])
        let file = JSONLScanning.DiscoveredFile(
            path: url.path,
            size: try XCTUnwrap(values.fileSize),
            mtime: try XCTUnwrap(values.contentModificationDate),
            attributeMtime: values.attributeModificationDate
        )
        let counter = ParseCounter()
        let scanner = IncrementalJSONLScanner<Int>(
            maxConcurrentParses: 2,
            maxResidentIdentities: 4
        )

        for identity in 0..<100 {
            let result = await scanner.items(
                from: [file],
                since: .distantPast,
                cacheIdentity: "account-or-home-\(identity)",
                parse: counter.parse
            )
            XCTAssertEqual(result, [42])
            let residentCount = await scanner.residentIdentityCountForTesting()
            XCTAssertLessThanOrEqual(
                residentCount,
                4,
                "historical account/home identities must be evicted from RAM instead of accumulating forever"
            )
        }

        let residentCount = await scanner.residentIdentityCountForTesting()
        let residentItems = await scanner.residentItemCountForTesting()
        XCTAssertLessThanOrEqual(residentCount, 4)
        XCTAssertLessThanOrEqual(residentItems, 4)

        let beforeRevisit = counter.count
        let revisit = await scanner.items(
            from: [file],
            since: .distantPast,
            cacheIdentity: "account-or-home-0",
            parse: counter.parse
        )
        XCTAssertEqual(revisit, [42])
        XCTAssertEqual(counter.count, beforeRevisit + 1)
        let finalResidentCount = await scanner.residentIdentityCountForTesting()
        XCTAssertLessThanOrEqual(finalResidentCount, 4)
    }

    func testUnloadModeKeepsResidentItemsNearZeroAcrossRepeatedRefreshes() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsage-UnloadSoak-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let now = Date()
        let files = try (0..<16).map { index -> JSONLScanning.DiscoveredFile in
            let url = directory.appendingPathComponent(String(format: "%02d.jsonl", index))
            let data = Data("\(index)".utf8)
            try data.write(to: url)
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
        let persistence = JSONLScanCachePersistence(
            namespace: "test",
            schemaVersion: 1,
            directory: directory.appendingPathComponent("cache"),
            writeDebounce: .milliseconds(1)
        )
        let counter = ParseCounter()
        let scanner = IncrementalJSONLScanner<Int>(
            maxConcurrentParses: 2,
            retainResidentItems: false,
            persistence: persistence
        )

        let first = await scanner.items(
            from: files,
            since: now.addingTimeInterval(-60),
            cacheIdentity: "unload-home",
            parse: counter.parse
        )
        XCTAssertEqual(first?.count, files.count)
        await scanner.flushPendingWrites()
        let residentAfterFirst = await scanner.residentItemCountForTesting()
        XCTAssertEqual(residentAfterFirst, 0)

        for _ in 0..<50 {
            let result = await scanner.items(
                from: files,
                since: now.addingTimeInterval(-60),
                cacheIdentity: "unload-home",
                parse: counter.parse
            )
            XCTAssertEqual(result?.count, files.count)
            let resident = await scanner.residentItemCountForTesting()
            XCTAssertEqual(resident, 0)
        }

        XCTAssertEqual(
            counter.count,
            files.count,
            "unload mode must hydrate from disk/tail rather than reparse a stable corpus"
        )
    }

    func testFoldItemsNeverRetainsConcatenatedPeak() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsage-FoldSoak-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let now = Date()
        let files = try (0..<32).map { index -> JSONLScanning.DiscoveredFile in
            let url = directory.appendingPathComponent(String(format: "%02d.jsonl", index))
            let payload = (0..<50).map { "\($0 + index * 50)" }.joined(separator: "\n") + "\n"
            try Data(payload.utf8).write(to: url)
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
        let scanner = IncrementalJSONLScanner<Int>(
            maxConcurrentParses: 2,
            retainResidentItems: false
        )
        final class Counter: @unchecked Sendable { var value = 0 }
        let counter = Counter()
        let ok = await scanner.foldItems(
            from: files,
            since: now.addingTimeInterval(-60),
            cacheIdentity: "fold-home",
            parseFile: { url in
                guard let data = try? Data(contentsOf: url),
                      let text = String(data: data, encoding: .utf8)
                else { return nil }
                return text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { Int($0) }
            },
            visit: { _ in counter.value += 1 }
        )
        XCTAssertTrue(ok)
        XCTAssertEqual(counter.value, 32 * 50)
        let resident = await scanner.residentItemCountForTesting()
        XCTAssertEqual(resident, 0)
    }
}
