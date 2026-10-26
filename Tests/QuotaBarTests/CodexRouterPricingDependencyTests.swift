import Foundation
import XCTest
@testable import QuotaBar

/// A pricing catalogue change must only cost a ledger read when it can change the fold's numbers.
///
/// The router ledger is append-only and large. The persisted aggregate used to be keyed by a hash
/// of the whole pricing catalogue, so every unrelated catalogue refresh orphaned the saved fold and
/// the next panel open re-read the entire ledger. These tests pin the replacement: the fold records
/// what it priced, and a catalogue change is checked against that instead of against a hash of
/// every catalogue entry.
final class CodexRouterPricingDependencyTests: XCTestCase {
    private let now = TestLocalInstant.date(2026, 10, 4, 12)
    private let day = TestLocalInstant.isoDay(2026, 10, 4)

    // MARK: - Unrelated catalogue change

    func testUnrelatedCatalogueChangeReusesTheFoldWithoutReadingTheLedger() async throws {
        try await withLedger { ledger in
            try line(tokens: 100).write(to: ledger, atomically: true, encoding: .utf8)
            let first = await scan(ledger, pricing: pricing(["test-model": 1, "unrelated-model": 1]))
            XCTAssertEqual(first?.series.daily.first?.totalTokens, 100)
            let cold = try XCTUnwrap(CodexRouterUsageScanner.incrementalReadStatisticsForTesting(path: ledger.path))
            let records = CodexRouterAggregateIndex.recordURLsForTesting(path: ledger.path)
            XCTAssertEqual(records.count, 1)

            // The catalogue changed, but only for a model this ledger never used.
            let warm = await scan(ledger, pricing: pricing(["test-model": 1, "unrelated-model": 2]))
            XCTAssertEqual(warm?.series.daily.first?.totalTokens, 100)
            XCTAssertEqual(try XCTUnwrap(warm?.series.daily.first?.costUSD), 0.0001, accuracy: 1e-12)

            let reused = try XCTUnwrap(CodexRouterUsageScanner.incrementalReadStatisticsForTesting(path: ledger.path))
            XCTAssertEqual(reused.fullParses, cold.fullParses)
            XCTAssertEqual(reused.bytesRead, cold.bytesRead)
            XCTAssertEqual(
                CodexRouterAggregateIndex.recordURLsForTesting(path: ledger.path),
                records,
                "the aggregate file must keep its identity when only the catalogue moved"
            )
        }
    }

    func testRelaunchedAggregateSurvivesUnrelatedCatalogueChange() async throws {
        try await withLedger { ledger in
            try line(tokens: 100).write(to: ledger, atomically: true, encoding: .utf8)
            _ = await scan(ledger, pricing: pricing(["test-model": 1, "unrelated-model": 1]))
            let cold = try XCTUnwrap(CodexRouterUsageScanner.incrementalReadStatisticsForTesting(path: ledger.path))

            // Simulate a relaunch: the resident record is dropped and the fold comes back from disk.
            CodexRouterAggregateIndex.shared.unloadMemoryForTesting(path: ledger.path)
            let warm = await scan(ledger, pricing: pricing(["test-model": 1, "unrelated-model": 2]))
            XCTAssertEqual(warm?.series.daily.first?.totalTokens, 100)
            XCTAssertEqual(try XCTUnwrap(warm?.series.daily.first?.costUSD), 0.0001, accuracy: 1e-12)

            let reused = try XCTUnwrap(CodexRouterUsageScanner.incrementalReadStatisticsForTesting(path: ledger.path))
            XCTAssertEqual(reused.fullParses, cold.fullParses)
            XCTAssertEqual(reused.bytesRead, cold.bytesRead)
        }
    }

    // MARK: - Catalogue changes that move the fold's numbers

    func testUsedModelRateChangeForcesRebuildWithNewCost() async throws {
        try await withLedger { ledger in
            try line(tokens: 100).write(to: ledger, atomically: true, encoding: .utf8)
            let first = await scan(ledger, pricing: pricing(["test-model": 1]))
            XCTAssertEqual(try XCTUnwrap(first?.series.daily.first?.costUSD), 0.0001, accuracy: 1e-12)
            let cold = try XCTUnwrap(CodexRouterUsageScanner.incrementalReadStatisticsForTesting(path: ledger.path))

            let repriced = await scan(ledger, pricing: pricing(["test-model": 2]))
            XCTAssertEqual(repriced?.series.daily.first?.totalTokens, 100)
            XCTAssertEqual(try XCTUnwrap(repriced?.series.daily.first?.costUSD), 0.0002, accuracy: 1e-12)

            let rebuilt = try XCTUnwrap(CodexRouterUsageScanner.incrementalReadStatisticsForTesting(path: ledger.path))
            XCTAssertEqual(rebuilt.fullParses, cold.fullParses + 1)
            XCTAssertGreaterThan(rebuilt.bytesRead, cold.bytesRead)
        }
    }

    func testUsedModelAliasChangeForcesRebuildWithNewCost() async throws {
        try await withLedger { ledger in
            try line(tokens: 100).write(to: ledger, atomically: true, encoding: .utf8)
            let first = await scan(ledger, pricing: pricing(["test-model": 1]))
            XCTAssertEqual(try XCTUnwrap(first?.series.daily.first?.costUSD), 0.0001, accuracy: 1e-12)

            // The supplement now points the same slug at another catalog key.
            let alias = try PricingSupplement.AliasRule(
                pattern: NSRegularExpression(pattern: "^test-model$"),
                canonical: "aliased-model"
            )
            let aliased = pricing(
                ["test-model": 1, "aliased-model": 5],
                supplement: PricingSupplement(aliasRules: [alias])
            )
            let repriced = await scan(ledger, pricing: aliased)
            XCTAssertEqual(repriced?.series.daily.first?.totalTokens, 100)
            XCTAssertEqual(try XCTUnwrap(repriced?.series.daily.first?.costUSD), 0.0005, accuracy: 1e-12)
        }
    }

    func testUnknownModelThatBecomesPricedForcesRebuild() async throws {
        try await withLedger { ledger in
            try line(tokens: 100, model: "mystery-model")
                .write(to: ledger, atomically: true, encoding: .utf8)
            let first = await scan(ledger, pricing: pricing(["unrelated-model": 1]))
            let unknownScan = try XCTUnwrap(first)
            XCTAssertEqual(unknownScan.unknownModelsByDay[day], ["mystery-model"])
            XCTAssertNil(unknownScan.series.daily.first?.costUSD)

            let priced = await scan(ledger, pricing: pricing(["unrelated-model": 1, "mystery-model": 1]))
            let pricedScan = try XCTUnwrap(priced)
            XCTAssertTrue(pricedScan.unknownModelsByDay.isEmpty)
            XCTAssertEqual(try XCTUnwrap(pricedScan.series.daily.first?.costUSD), 0.0001, accuracy: 1e-12)
        }
    }

    func testDatedReserveFallbackRebuildsWhenItsPricedModelChanges() async throws {
        try await withLedger { ledger in
            // A reserve slug prices through the dated Luna fallback, so the fold depends on the
            // fallback model for that UTC day.
            try line(tokens: 100_000, model: "gpt-reserve")
                .write(to: ledger, atomically: true, encoding: .utf8)
            let first = await scan(ledger, pricing: pricing(["gpt-6-luna": 1]))
            let firstScan = try XCTUnwrap(first)
            XCTAssertEqual(try XCTUnwrap(firstScan.series.daily.first?.costUSD), 0.1, accuracy: 1e-9)
            XCTAssertTrue(firstScan.unknownModelsByDay.isEmpty)
            // The row keeps the reserve slug as its own identity: it is priced like another model.
            XCTAssertEqual(firstScan.modelUsage?.daily.first?.models.first?.model, "gpt-reserve")

            let repriced = await scan(ledger, pricing: pricing(["gpt-6-luna": 2]))
            let repricedScan = try XCTUnwrap(repriced)
            XCTAssertEqual(try XCTUnwrap(repricedScan.series.daily.first?.costUSD), 0.2, accuracy: 1e-9)
        }
    }

    func testDatedReserveFallbackUsesTheModelReleasedForThatDay() async throws {
        try await withLedger { ledger in
            // The day decides the fallback: the 6 Luna model was released on 2026-09-22, so a turn
            // from the day before still prices as the 5.6 Luna model.
            try line(tokens: 100_000, model: "gpt-reserve", date: (2026, 9, 21))
                .write(to: ledger, atomically: true, encoding: .utf8)
            let first = await scan(
                ledger,
                daysBack: 60,
                pricing: pricing(["gpt-6-luna": 1, "gpt-5.6-luna": 4])
            )
            let firstScan = try XCTUnwrap(first)
            XCTAssertTrue(firstScan.unknownModelsByDay.isEmpty)
            XCTAssertEqual(try XCTUnwrap(firstScan.series.daily.first?.costUSD), 0.4, accuracy: 1e-9)

            // Changing the model that priced *that day* must rebuild the fold.
            let repriced = await scan(
                ledger,
                daysBack: 60,
                pricing: pricing(["gpt-6-luna": 1, "gpt-5.6-luna": 8])
            )
            let repricedScan = try XCTUnwrap(repriced)
            XCTAssertEqual(try XCTUnwrap(repricedScan.series.daily.first?.costUSD), 0.8, accuracy: 1e-9)
        }
    }

    func testUnrelatedCatalogueChangeKeepsDatedReserveFallbackPriced() async throws {
        try await withLedger { ledger in
            try line(tokens: 100_000, model: "gpt-reserve")
                .write(to: ledger, atomically: true, encoding: .utf8)
            let first = await scan(ledger, pricing: pricing(["gpt-6-luna": 1]))
            let firstScan = try XCTUnwrap(first)
            XCTAssertEqual(try XCTUnwrap(firstScan.series.daily.first?.costUSD), 0.1, accuracy: 1e-9)
            let cold = try XCTUnwrap(CodexRouterUsageScanner.incrementalReadStatisticsForTesting(path: ledger.path))

            let warm = await scan(
                ledger,
                pricing: pricing(["gpt-6-luna": 1, "unrelated-model": 7])
            )
            let warmScan = try XCTUnwrap(warm)
            XCTAssertEqual(try XCTUnwrap(warmScan.series.daily.first?.costUSD), 0.1, accuracy: 1e-9)
            XCTAssertTrue(warmScan.unknownModelsByDay.isEmpty)

            let reused = try XCTUnwrap(CodexRouterUsageScanner.incrementalReadStatisticsForTesting(path: ledger.path))
            XCTAssertEqual(reused.fullParses, cold.fullParses)
            XCTAssertEqual(reused.bytesRead, cold.bytesRead)
        }
    }

    // MARK: - Tail merges

    func testAlternatingAppAndCLIRatesKeepBothDiskCheckpointsIncremental() async throws {
        try await withLedger { ledger in
            try line(tokens: 100).write(to: ledger, atomically: true, encoding: .utf8)
            _ = await scan(ledger, pricing: pricing(["test-model": 1]))
            CodexRouterAggregateIndex.shared.unloadMemoryForTesting(path: ledger.path)
            _ = await scan(ledger, pricing: pricing(["test-model": 2]))
            let cold = try XCTUnwrap(CodexRouterUsageScanner.incrementalReadStatisticsForTesting(path: ledger.path))
            XCTAssertEqual(cold.fullParses, 2)
            for rate in [1.0, 2.0, 1.0, 2.0] {
                CodexRouterAggregateIndex.shared.unloadMemoryForTesting(path: ledger.path)
                let result = await scan(ledger, pricing: pricing(["test-model": rate]))
                XCTAssertEqual(try XCTUnwrap(result?.series.daily.first?.costUSD), rate / 10_000, accuracy: 1e-12)
            }
            let reused = try XCTUnwrap(CodexRouterUsageScanner.incrementalReadStatisticsForTesting(path: ledger.path))
            XCTAssertEqual(reused.bytesRead, cold.bytesRead)

            let handle = try FileHandle(forWritingTo: ledger)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line(tokens: 50, hour: 11).utf8))
            try handle.close()
            for rate in [1.0, 2.0] {
                CodexRouterAggregateIndex.shared.unloadMemoryForTesting(path: ledger.path)
                let result = await scan(ledger, pricing: pricing(["test-model": rate]))
                XCTAssertEqual(result?.series.daily.first?.totalTokens, 150)
                XCTAssertEqual(try XCTUnwrap(result?.series.daily.first?.costUSD), rate * 0.00015, accuracy: 1e-12)
            }
            let appended = try XCTUnwrap(CodexRouterUsageScanner.incrementalReadStatisticsForTesting(path: ledger.path))
            XCTAssertEqual(appended.fullParses, cold.fullParses)
            XCTAssertEqual(CodexRouterAggregateIndex.recordURLsForTesting(path: ledger.path).count, 2)
        }
    }

    func testModelContainingSeparatorCannotHideDatedFallbackDependency() async throws {
        try await withLedger { ledger in
            // Both strings are valid JSON model values. A joined string key used to collide for
            // (codex-auto-review, 2026-10-04) and (codex-auto-review + separator + date, nil).
            let escapedModel = "codex-auto-review\\u001f2026-10-04"
            try (line(tokens: 100_000, model: "codex-auto-review") + line(tokens: 50, model: escapedModel))
                .write(to: ledger, atomically: true, encoding: .utf8)
            let first = await scan(ledger, pricing: pricing(["gpt-6-luna": 1]))
            XCTAssertEqual(first?.series.daily.first?.totalTokens, 100_050)
            XCTAssertEqual(try XCTUnwrap(first?.series.daily.first?.costUSD), 0.1, accuracy: 1e-9)
            XCTAssertEqual(first?.unknownModelsByDay[day], ["codex-auto-review\u{1f}2026-10-04"])
            let initial = try XCTUnwrap(CodexRouterUsageScanner.incrementalReadStatisticsForTesting(path: ledger.path))

            let repriced = await scan(ledger, pricing: pricing(["gpt-6-luna": 2]))
            XCTAssertEqual(try XCTUnwrap(repriced?.series.daily.first?.costUSD), 0.2, accuracy: 1e-9)
            let final = try XCTUnwrap(CodexRouterUsageScanner.incrementalReadStatisticsForTesting(path: ledger.path))
            XCTAssertEqual(final.fullParses, initial.fullParses + 1)
        }
    }

    func testAppendAfterUnrelatedCatalogueChangeKeepsTotalsAndReadsOnlyTheTail() async throws {
        try await withLedger { ledger in
            try line(tokens: 100).write(to: ledger, atomically: true, encoding: .utf8)
            _ = await scan(ledger, pricing: pricing(["test-model": 1, "unrelated-model": 1]))
            let cold = try XCTUnwrap(CodexRouterUsageScanner.incrementalReadStatisticsForTesting(path: ledger.path))

            // An unrelated catalogue change must not cost a ledger read…
            let reused = await scan(ledger, pricing: pricing(["test-model": 1, "unrelated-model": 2]))
            XCTAssertEqual(reused?.series.daily.first?.totalTokens, 100)
            let afterChange = try XCTUnwrap(CodexRouterUsageScanner.incrementalReadStatisticsForTesting(path: ledger.path))
            XCTAssertEqual(afterChange.bytesRead, cold.bytesRead)

            // …and the append after it must still be a tail read with the same totals.
            let handle = try FileHandle(forWritingTo: ledger)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line(tokens: 50, hour: 11).utf8))
            try handle.close()
            let appended = await scan(ledger, pricing: pricing(["test-model": 1, "unrelated-model": 2]))
            XCTAssertEqual(appended?.series.daily.first?.totalTokens, 150)
            XCTAssertEqual(try XCTUnwrap(appended?.series.daily.first?.costUSD), 0.00015, accuracy: 1e-12)

            let stats = try XCTUnwrap(CodexRouterUsageScanner.incrementalReadStatisticsForTesting(path: ledger.path))
            XCTAssertEqual(stats.fullParses, cold.fullParses)
            XCTAssertEqual(stats.tailParses, 1)
        }
    }

    // MARK: - Records without a dependency snapshot

    func testAggregateRecordWithoutPricingDependenciesAlwaysRebuilds() throws {
        let index = CodexRouterAggregateIndex.shared
        let key = CodexRouterAggregateIndex.Key(
            account: "synthetic-account",
            allowsUnscopedEvents: true,
            days: 30,
            since: 0,
            timeZoneIdentifier: TimeZone.current.identifier,
            aliases: [],
            pricingToken: "synthetic-token",
            sourcePaths: []
        )
        defer { index.removeForTesting(key: key) }
        index.save(CodexRouterAggregateIndex.Record(
            schema: CodexRouterAggregateIndex.schema,
            key: key,
            files: [],
            result: nil,
            nextFutureEventAt: nil,
            latestIncludedEventAt: nil,
            complete: true,
            pricingDependencies: nil
        ))

        // A fold that does not say what it priced cannot be checked against a later catalogue, so
        // it must never be reused — not even when the catalogue token did not move. Appending to it
        // would save the new rows' dependencies only and leave the old rows' prices unchecked.
        let unchanged = index.lookup(
            key: key,
            paths: [],
            now: now,
            pricingDependenciesUnchanged: { _ in true }
        )
        guard case .rebuild = unchanged else {
            return XCTFail("a record without pricing dependencies must rebuild")
        }

        var changedKey = key
        changedKey.pricingToken = "synthetic-token-2"
        let changed = index.lookup(
            key: changedKey,
            paths: [],
            now: now,
            pricingDependenciesUnchanged: { _ in true }
        )
        guard case .rebuild = changed else {
            return XCTFail("a record without pricing dependencies must rebuild after a catalogue change")
        }
    }

    // MARK: - Fixtures

    private func pricing(
        _ rates: [String: Double],
        supplement: PricingSupplement = PricingSupplement()
    ) -> ModelPricing {
        ModelPricing(
            supplement: supplement,
            primary: PricingCatalog(entries: rates.mapValues { rate in
                ModelRates(
                    inputPerMillion: rate,
                    outputPerMillion: rate,
                    cacheWritePerMillion: rate,
                    cacheReadPerMillion: rate
                )
            }),
            secondary: PricingCatalog()
        )
    }

    private func line(
        tokens: Int,
        hour: Int = 10,
        model: String = "test-model",
        date: (year: Int, month: Int, day: Int) = (2026, 10, 4)
    ) -> String {
        "{\"at\":\"\(TestLocalInstant.iso(date.year, date.month, date.day, hour))\",\"model\":\"\(model)\",\"provider\":\"openai\",\"status\":200,\"inputTokens\":\(tokens),\"outputTokens\":0,\"totalTokens\":\(tokens)}\n"
    }

    private func withLedger(_ body: (URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("router-pricing-dependency-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ledger = directory.appendingPathComponent("usage-events.jsonl")
        defer {
            CodexRouterUsageScanner.clearSharedTailCacheForTesting(path: ledger.path)
            try? FileManager.default.trashItem(at: directory, resultingItemURL: nil)
        }
        try await body(ledger)
    }

    private func scan(
        _ ledger: URL,
        daysBack: Int = 30,
        pricing: ModelPricing
    ) async -> LogUsageScan? {
        let scanner = CodexRouterUsageScanner(ledgerPaths: { [ledger.path] }, identityAliases: { [:] })
        return await scanner.scan(
            accountIdentityKey: nil,
            allowsUnscopedEvents: true,
            daysBack: daysBack,
            now: now,
            pricing: pricing
        )
    }
}
