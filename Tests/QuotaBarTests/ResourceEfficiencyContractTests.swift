import Foundation
import XCTest
@testable import QuotaBar

/// Deterministic resource-envelope contracts for the local JSONL scanner.
///
/// These deliberately assert work, not wall-clock timing or RSS, so they stay useful on noisy CI hosts.
/// The production invariant is that many sessions/accounts may increase useful work, but must not
/// multiply parse concurrency or cause unchanged history to be decoded again every refresh.
final class ResourceEfficiencyContractTests: XCTestCase {
    @MainActor
    func testMemoryPressureHandlerRunsOnBackgroundQueue() async {
        let unloaded = expectation(description: "Memory pressure unload completed")
        let handler = AppContainer.makeMemoryPressureHandler {
            unloaded.fulfill()
        }

        DispatchQueue.global(qos: .utility).async {
            dispatchPrecondition(condition: .notOnQueue(.main))
            handler()
        }

        await fulfillment(of: [unloaded], timeout: 5)
    }

    func testConcurrentDifferentIdentitiesShareOneGlobalParseBudget() async throws {
        let directory = try makeDirectory("ConcurrentIdentities")
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = try makeFiles(count: 24, in: directory)
        let probe = ConcurrencyProbe()
        let scanner = IncrementalJSONLScanner<Int>(maxConcurrentParses: 2)

        let parser: @Sendable (Data) -> [Int]? = { data in
            probe.begin()
            defer { probe.end() }
            Thread.sleep(forTimeInterval: 0.003)
            return String(data: data, encoding: .utf8).flatMap(Int.init).map { [$0] }
        }

        async let accountA = scanner.items(
            from: files,
            since: .distantPast,
            cacheIdentity: "account-a",
            parse: parser
        )
        async let accountB = scanner.items(
            from: files,
            since: .distantPast,
            cacheIdentity: "account-b",
            parse: parser
        )

        let results = await [accountA, accountB]
        XCTAssertEqual(results[0]?.count, files.count)
        XCTAssertEqual(results[1]?.count, files.count)
        XCTAssertLessThanOrEqual(
            probe.maximumActive,
            2,
            "parallel homes/accounts must share the scanner's global parse permit pool instead of multiplying CPU work"
        )
    }

    func testLargeDormantCorpusSecondRefreshDoesZeroDecodeWork() async throws {
        let directory = try makeDirectory("DormantCorpus")
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = try makeFiles(count: 256, in: directory)
        let counter = ParseCounter()
        let scanner = IncrementalJSONLScanner<Int>(maxConcurrentParses: 2)

        let first = await scanner.items(
            from: files,
            since: .distantPast,
            cacheIdentity: "home",
            parse: counter.parse
        )
        XCTAssertEqual(first?.count, files.count)
        XCTAssertEqual(counter.count, files.count)

        let second = await scanner.items(
            from: files,
            since: .distantPast,
            cacheIdentity: "home",
            parse: counter.parse
        )
        XCTAssertEqual(second?.count, files.count)
        XCTAssertEqual(
            counter.count,
            files.count,
            "an unchanged large history must do metadata/cache work only; decoding it again is a CPU regression"
        )
    }

    func testChangingOneFileInLargeCorpusReparsesOnlyThatFile() async throws {
        let directory = try makeDirectory("OneDirtyFile")
        defer { try? FileManager.default.removeItem(at: directory) }
        var files = try makeFiles(count: 128, in: directory)
        let counter = ParseCounter()
        let scanner = IncrementalJSONLScanner<Int>(maxConcurrentParses: 2)

        _ = await scanner.items(
            from: files,
            since: .distantPast,
            cacheIdentity: "home",
            parse: counter.parse
        )
        XCTAssertEqual(counter.count, files.count)

        let changedIndex = 73
        let changedURL = URL(fileURLWithPath: files[changedIndex].path)
        try Data("9999".utf8).write(to: changedURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2_000_000_000)],
            ofItemAtPath: changedURL.path
        )
        files[changedIndex] = try discovered(changedURL)

        let result = await scanner.items(
            from: files,
            since: .distantPast,
            cacheIdentity: "home",
            parse: counter.parse
        )

        XCTAssertEqual(result?.count, files.count)
        XCTAssertEqual(counter.count, files.count + 1, "one dirty session file must cause exactly one reparse")
        XCTAssertEqual(result?[changedIndex], 9999)
    }

    private func makeDirectory(_ name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsageResourceTests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeFiles(count: Int, in directory: URL) throws -> [JSONLScanning.DiscoveredFile] {
        try (0..<count).map { index in
            let url = directory.appendingPathComponent(String(format: "%04d.jsonl", index))
            try Data("\(index)".utf8).write(to: url)
            return try discovered(url)
        }
    }

    private func discovered(_ url: URL) throws -> JSONLScanning.DiscoveredFile {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return JSONLScanning.DiscoveredFile(
            path: url.path,
            size: try XCTUnwrap(values.fileSize),
            mtime: try XCTUnwrap(values.contentModificationDate)
        )
    }
}
