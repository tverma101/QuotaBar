import Foundation
import XCTest
@testable import QuotaBar

// Contracts for the persistent daily-aggregate gate: a warm refresh with unchanged sources must
// not parse, hydrate, or replay any ledger/session bytes — it must return the persisted aggregate.

final class LogUsageAggregateCacheTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_777_507_200)

    private func makeCache() -> LogUsageAggregateCache {
        LogUsageAggregateCache(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("openusage-aggregate-\(UUID().uuidString)", isDirectory: true)
        )
    }

    private func file(_ path: String, size: Int, mtime: Date, attributeMtime: Date? = nil) -> JSONLScanning.DiscoveredFile {
        JSONLScanning.DiscoveredFile(path: path, size: size, mtime: mtime, attributeMtime: attributeMtime)
    }

    private func scan(_ days: [(day: String, tokens: Int)]) -> LogUsageScan {
        var accumulator = DailyUsageAccumulator()
        for entry in days {
            accumulator.add(day: entry.day, tokens: entry.tokens, cost: 0.01, model: "gpt-5.2")
        }
        return accumulator.build()
    }

    /// A @Sendable-safe counter box: captured vars cannot be mutated from concurrent closures.
    private final class Counter: @unchecked Sendable {
        var count = 0
    }

    private func countingCompute(_ result: LogUsageScan, _ counter: Counter) -> (@Sendable () async -> LogUsageScan?) {
        { counter.count += 1
            return result }
    }

    func testUnchangedSourcesReturnPersistedAggregateWithoutRecomputing() async {
        let cache = makeCache()
        let fingerprints = ["ledger": LogUsageSourceFingerprint.of([file("/l.jsonl", size: 10, mtime: now)])]
        let counter = Counter()
        let result = scan([("2026-04-29", 100)])

        let first = await cache.scan(
            key: "k", pricingStamp: "p1", daysBack: 30, fingerprints: fingerprints, now: now,
            compute: countingCompute(result, counter)
        )
        XCTAssertEqual(counter.count, 1)
        XCTAssertEqual(first?.series.daily.first?.totalTokens, 100)

        let second = await cache.scan(
            key: "k", pricingStamp: "p1", daysBack: 30, fingerprints: fingerprints, now: now,
            compute: countingCompute(result, counter)
        )
        XCTAssertEqual(counter.count, 1, "unchanged sources must reuse the persisted aggregate")
        XCTAssertEqual(second?.series.daily.first?.totalTokens, 100)
    }

    func testAppendTruncateAndRotateEachRecompute() async {
        let cache = makeCache()
        let mtime = now
        let counter = Counter()
        let result = scan([("2026-04-29", 100)])

        let initial = ["ledger": LogUsageSourceFingerprint.of([file("/l.jsonl", size: 10, mtime: mtime)])]
        _ = await cache.scan(key: "k", pricingStamp: "p1", daysBack: 30, fingerprints: initial, now: now, compute: countingCompute(result, counter))
        XCTAssertEqual(counter.count, 1)

        // Append: size grows.
        let appended = ["ledger": LogUsageSourceFingerprint.of([file("/l.jsonl", size: 20, mtime: mtime.addingTimeInterval(1))])]
        _ = await cache.scan(key: "k", pricingStamp: "p1", daysBack: 30, fingerprints: appended, now: now, compute: countingCompute(result, counter))
        XCTAssertEqual(counter.count, 2, "an append must invalidate the aggregate")

        // Truncate: size shrinks below the prior offset.
        let truncated = ["ledger": LogUsageSourceFingerprint.of([file("/l.jsonl", size: 4, mtime: mtime.addingTimeInterval(2))])]
        _ = await cache.scan(key: "k", pricingStamp: "p1", daysBack: 30, fingerprints: truncated, now: now, compute: countingCompute(result, counter))
        XCTAssertEqual(counter.count, 3, "a truncate must invalidate the aggregate")

        // Rotate: the ledger path is replaced.
        let rotated = ["ledger": LogUsageSourceFingerprint.of([file("/l-2.jsonl", size: 10, mtime: mtime)])]
        _ = await cache.scan(key: "k", pricingStamp: "p1", daysBack: 30, fingerprints: rotated, now: now, compute: countingCompute(result, counter))
        XCTAssertEqual(counter.count, 4, "a rotate must invalidate the aggregate")

        // Same shape again → hit.
        _ = await cache.scan(key: "k", pricingStamp: "p1", daysBack: 30, fingerprints: rotated, now: now, compute: countingCompute(result, counter))
        XCTAssertEqual(counter.count, 4)
    }

    func testInPlaceRewriteChangesAttributeMtimeFingerprint() async {
        let cache = makeCache()
        let counter = Counter()
        let result = scan([("2026-04-29", 100)])
        let original = ["ledger": LogUsageSourceFingerprint.of([
            file("/l.jsonl", size: 10, mtime: now, attributeMtime: now)
        ])]
        _ = await cache.scan(key: "k", pricingStamp: "p1", daysBack: 30, fingerprints: original, now: now, compute: countingCompute(result, counter))
        let rewritten = ["ledger": LogUsageSourceFingerprint.of([
            file("/l.jsonl", size: 10, mtime: now, attributeMtime: now.addingTimeInterval(1))
        ])]
        _ = await cache.scan(key: "k", pricingStamp: "p1", daysBack: 30, fingerprints: rewritten, now: now, compute: countingCompute(result, counter))
        XCTAssertEqual(counter.count, 2, "an in-place rewrite must invalidate the aggregate")
    }

    func testPricingStampChangeRecomputes() async {
        let cache = makeCache()
        let fingerprints = ["ledger": LogUsageSourceFingerprint.of([file("/l.jsonl", size: 10, mtime: now)])]
        let counter = Counter()
        let result = scan([("2026-04-29", 100)])
        _ = await cache.scan(key: "k", pricingStamp: "p1", daysBack: 30, fingerprints: fingerprints, now: now, compute: countingCompute(result, counter))
        _ = await cache.scan(key: "k", pricingStamp: "p2", daysBack: 30, fingerprints: fingerprints, now: now, compute: countingCompute(result, counter))
        XCTAssertEqual(counter.count, 2, "a pricing change must reprice the aggregate")
    }

    func testAggregateSurvivesAcrossCacheInstances() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openusage-aggregate-\(UUID().uuidString)", isDirectory: true)
        let first = LogUsageAggregateCache(directory: directory)
        let fingerprints = ["ledger": LogUsageSourceFingerprint.of([file("/l.jsonl", size: 10, mtime: now)])]
        let counter = Counter()
        let result = scan([("2026-04-29", 100)])
        _ = await first.scan(key: "k", pricingStamp: "p1", daysBack: 30, fingerprints: fingerprints, now: now, compute: countingCompute(result, counter))

        let second = LogUsageAggregateCache(directory: directory)
        let reused = await second.scan(key: "k", pricingStamp: "p1", daysBack: 30, fingerprints: fingerprints, now: now, compute: countingCompute(result, counter))
        XCTAssertEqual(counter.count, 1, "a second process/instance must load the persisted aggregate")
        XCTAssertEqual(reused?.series.daily.first?.totalTokens, 100)
    }

    func testWindowFilterDropsDaysOutsideTheRequestedWindow() {
        let scan = self.scan([("2026-04-29", 100), ("2020-01-01", 500)])
        let filtered = LogUsageAggregateCache.windowFiltered(scan, daysBack: 30, now: now)
        XCTAssertEqual(filtered.series.daily.map(\.date), ["2026-04-29"])
        XCTAssertEqual(filtered.series.daily.first?.totalTokens, 100)
    }

    func testPricingStampTracksSupplementAndCatalogShape() {
        let pricing = TestPricing.bundled
        XCTAssertEqual(LogUsagePricingStamp.of(pricing), LogUsagePricingStamp.of(pricing))
        XCTAssertNotEqual(
            LogUsagePricingStamp.of(pricing),
            LogUsagePricingStamp.of(ModelPricing.empty),
            "an empty pricing snapshot must not collide with the bundled one"
        )
    }
}

// MARK: - Scanner integration: a warm scan must not re-parse or replay the ledgers.

final class LogUsageAggregateScannerIntegrationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_777_507_200)

    private func makeCache() -> LogUsageAggregateCache {
        LogUsageAggregateCache(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("openusage-aggregate-\(UUID().uuidString)", isDirectory: true)
        )
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    private func routerLine(at timestamp: String, tokens: Int) -> String {
        let object: [String: Any] = [
            "at": timestamp,
            "model": "gpt-5.6-terra",
            "provider": "openai",
            "status": 200,
            "inputTokens": tokens,
            "cachedInputTokens": 0,
            "outputTokens": 0,
            "reasoningTokens": 0,
            "totalTokens": tokens,
        ]
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }

    func testRouterLedgerWarmScanDoesNotReparseAndAppendTruncateRecompute() async throws {
        let ledger = FileManager.default.temporaryDirectory
            .appendingPathComponent("openusage-router-ledger-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: ledger) }
        let firstLine = routerLine(at: "2026-04-29T08:00:00.000Z", tokens: 100) + "\n"
        try Data(firstLine.utf8).write(to: ledger)

        let cache = makeCache()
        let scanner = CodexRouterUsageScanner(
            ledgerPaths: { [ledger.path] },
            identityAliases: { [:] },
            aggregateCache: cache
        )
        let pricing = TestPricing.bundled

        let first = await scanner.scan(
            accountIdentityKey: nil, allowsUnscopedEvents: true, daysBack: 30, now: now, pricing: pricing
        )
        XCTAssertEqual(first?.series.daily.first?.totalTokens, 100)
        let afterFirst = try XCTUnwrap(CodexRouterUsageScanner.incrementalReadStatisticsForTesting(path: ledger.path))
        XCTAssertEqual(afterFirst.fullParses, 1)

        // Second scan, unchanged ledger: the aggregate is reused, the ledger is not even opened
        // for a tail read (no new full or tail parses).
        let second = await scanner.scan(
            accountIdentityKey: nil, allowsUnscopedEvents: true, daysBack: 30, now: now, pricing: pricing
        )
        XCTAssertEqual(second?.series.daily.first?.totalTokens, 100)
        let afterSecond = try XCTUnwrap(CodexRouterUsageScanner.incrementalReadStatisticsForTesting(path: ledger.path))
        XCTAssertEqual(afterSecond.fullParses, afterFirst.fullParses)
        XCTAssertEqual(afterSecond.tailParses, afterFirst.tailParses)

        // Append: the incremental path tails only the new bytes, and the aggregate refreshes.
        let appendedLine = routerLine(at: "2026-04-29T09:00:00.000Z", tokens: 50) + "\n"
        try append(appendedLine, to: ledger)
        let third = await scanner.scan(
            accountIdentityKey: nil, allowsUnscopedEvents: true, daysBack: 30, now: now, pricing: pricing
        )
        XCTAssertEqual(third?.series.daily.first?.totalTokens, 150)
        let afterThird = try XCTUnwrap(CodexRouterUsageScanner.incrementalReadStatisticsForTesting(path: ledger.path))
        XCTAssertEqual(afterThird.fullParses, afterFirst.fullParses, "an append must tail-parse, never full-parse")
        XCTAssertEqual(afterThird.tailParses, afterFirst.tailParses + 1)

        // Truncate/replace: the fingerprint shrinks, one full parse replaces the ledger's rows.
        let replacement = routerLine(at: "2026-04-29T10:00:00.000Z", tokens: 7) + "\n"
        try replacement.write(to: ledger, atomically: true, encoding: .utf8)
        let fourth = await scanner.scan(
            accountIdentityKey: nil, allowsUnscopedEvents: true, daysBack: 30, now: now, pricing: pricing
        )
        XCTAssertEqual(fourth?.series.daily.first?.totalTokens, 7)
        let afterFourth = try XCTUnwrap(CodexRouterUsageScanner.incrementalReadStatisticsForTesting(path: ledger.path))
        XCTAssertEqual(afterFourth.fullParses, afterFirst.fullParses + 1)
    }

    func testNativeSessionTreeWarmScanDoesNotReparse() async throws {
        let initial = [
            CodexLogFixture.turnContext(timestamp: "2026-04-29T08:00:00.000Z", model: "gpt-5.2"),
            CodexLogFixture.tokenCount(
                timestamp: "2026-04-29T08:01:00.000Z",
                last: CodexLogFixture.usage(input: 100, output: 20)
            ),
        ].joined(separator: "\n") + "\n"
        let home = try CodexLogFixture.makeHome(files: ["sessions/rollout.jsonl": initial])
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent("sessions/rollout.jsonl")

        let cache = makeCache()
        let scanner = CodexLogUsageScanner(
            environment: FakeEnvironment(["CODEX_HOME": home.path]),
            homeDirectory: { FileManager.default.temporaryDirectory.appendingPathComponent("openusage-no-codex-home") },
            aggregateCache: cache
        )
        let pricing = TestPricing.bundled

        let first = await scanner.scan(daysBack: 30, now: now, pricing: pricing)
        XCTAssertEqual(first?.series.daily.first?.totalTokens, 120)
        let afterFirst = try XCTUnwrap(CodexLogUsageScanner.incrementalReadStatisticsForTesting(path: file.path))
        XCTAssertEqual(afterFirst.fullParses, 1)

        let second = await scanner.scan(daysBack: 30, now: now, pricing: pricing)
        XCTAssertEqual(second?.series.daily.first?.totalTokens, 120)
        let afterSecond = try XCTUnwrap(CodexLogUsageScanner.incrementalReadStatisticsForTesting(path: file.path))
        XCTAssertEqual(afterSecond.fullParses, afterFirst.fullParses, "a warm scan must not re-parse the rollout")
        XCTAssertEqual(afterSecond.tailParses, afterFirst.tailParses)

        let appended = CodexLogFixture.tokenCount(
            timestamp: "2026-04-29T08:02:00.000Z",
            last: CodexLogFixture.usage(input: 40, output: 10)
        ) + "\n"
        try append(appended, to: file)
        let third = await scanner.scan(daysBack: 30, now: now, pricing: pricing)
        XCTAssertEqual(third?.series.daily.first?.totalTokens, 170)
        let afterThird = try XCTUnwrap(CodexLogUsageScanner.incrementalReadStatisticsForTesting(path: file.path))
        XCTAssertEqual(afterThird.fullParses, afterFirst.fullParses)
        XCTAssertEqual(afterThird.tailParses, afterFirst.tailParses + 1)
    }
}