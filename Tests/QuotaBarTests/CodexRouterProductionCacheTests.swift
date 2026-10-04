import Foundation
import XCTest
@testable import QuotaBar

/// Exercises the default production scanner, rather than the injected incremental test scanner.
final class CodexRouterProductionCacheTests: XCTestCase {
    private let now = TestLocalInstant.date(2026, 10, 4, 12)

    private func pricing(rate: Double = 1) -> ModelPricing {
        ModelPricing(
            supplement: PricingSupplement(),
            primary: PricingCatalog(entries: ["test-model": ModelRates(
                inputPerMillion: rate, outputPerMillion: rate,
                cacheWritePerMillion: rate, cacheReadPerMillion: rate
            )]),
            secondary: PricingCatalog()
        )
    }

    private func line(tokens: Int, hour: Int = 10) -> String {
        "{\"at\":\"\(TestLocalInstant.iso(2026, 10, 4, hour))\",\"model\":\"test-model\",\"provider\":\"openai\",\"status\":200,\"inputTokens\":\(tokens),\"outputTokens\":0,\"totalTokens\":\(tokens)}\n"
    }

    private func withLedger(_ body: (URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("router-production-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ledger = directory.appendingPathComponent("usage-events.jsonl")
        defer {
            CodexRouterUsageScanner.clearSharedTailCacheForTesting(path: ledger.path)
            try? FileManager.default.removeItem(at: directory)
        }
        try await body(ledger)
    }

    private func scan(_ ledger: URL, pricing: ModelPricing? = nil, now: Date? = nil) async -> LogUsageScan? {
        let scanner = CodexRouterUsageScanner(ledgerPaths: { [ledger.path] }, identityAliases: { [:] })
        return await scanner.scan(
            accountIdentityKey: nil, allowsUnscopedEvents: true,
            daysBack: 30, now: now ?? self.now, pricing: pricing ?? self.pricing()
        )
    }

    func testNewScannerReusesUnchangedAggregateAndReadsOnlyAppend() async throws {
        try await withLedger { ledger in
            try line(tokens: 100).write(to: ledger, atomically: true, encoding: .utf8)
            let first = await scan(ledger)
            XCTAssertEqual(first?.series.daily.first?.totalTokens, 100)
            let cold = try XCTUnwrap(CodexRouterUsageScanner.incrementalReadStatisticsForTesting(path: ledger.path))
            // Simulate releasing resident records/relaunching; the persisted daily index still
            // avoids reading the event ledger.
            CodexRouterAggregateIndex.shared.unloadMemoryForTesting(path: ledger.path)
            let warm = await scan(ledger)
            XCTAssertEqual(warm?.series.daily.first?.totalTokens, 100)
            let reused = try XCTUnwrap(CodexRouterUsageScanner.incrementalReadStatisticsForTesting(path: ledger.path))
            XCTAssertEqual(reused.fullParses, cold.fullParses)
            XCTAssertEqual(reused.bytesRead, cold.bytesRead)
            let delta = Data(line(tokens: 50, hour: 11).utf8)
            let handle = try FileHandle(forWritingTo: ledger)
            try handle.seekToEnd()
            try handle.write(contentsOf: delta)
            try handle.close()
            let appended = await scan(ledger)
            XCTAssertEqual(appended?.series.daily.first?.totalTokens, 150)
            let stats = try XCTUnwrap(CodexRouterUsageScanner.incrementalReadStatisticsForTesting(path: ledger.path))
            XCTAssertEqual(stats.fullParses, cold.fullParses)
            XCTAssertEqual(stats.tailParses, 1)
            XCTAssertEqual(stats.bytesRead - cold.bytesRead, delta.count)
        }
    }

    func testActualPriceChangeRepricesUnchangedLedger() async throws {
        try await withLedger { ledger in
            try line(tokens: 100).write(to: ledger, atomically: true, encoding: .utf8)
            let first = await scan(ledger, pricing: pricing(rate: 1))
            let repriced = await scan(ledger, pricing: pricing(rate: 2))
            XCTAssertEqual(first?.series.daily.first?.totalTokens, 100)
            XCTAssertEqual(repriced?.series.daily.first?.totalTokens, 100)
            XCTAssertEqual(try XCTUnwrap(repriced?.series.daily.first?.costUSD), 0.0002, accuracy: 1e-10)
        }
    }

    func testSameSizeRewriteBeforeUnchangedTailRebuilds() async throws {
        try await withLedger { ledger in
            // Preserve a tail larger than the checkpoint anchor to catch prefix-only mutations.
            let suffix = String(repeating: " ", count: 8192) + "\n"
            try (line(tokens: 100) + suffix).write(to: ledger, atomically: true, encoding: .utf8)
            _ = await scan(ledger)
            let handle = try FileHandle(forWritingTo: ledger)
            try handle.write(contentsOf: Data(line(tokens: 200).utf8))
            try handle.close()
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: ledger.path)
            let rewritten = await scan(ledger)
            XCTAssertEqual(rewritten?.series.daily.first?.totalTokens, 200)
        }
    }

    func testPartialAppendAndAtomicReplacementDoNotDuplicate() async throws {
        try await withLedger { ledger in
            let event = Data(line(tokens: 100).utf8)
            try event.prefix(event.count / 2).write(to: ledger)
            let incomplete = await scan(ledger)
            XCTAssertNil(incomplete)
            let handle = try FileHandle(forWritingTo: ledger)
            try handle.seekToEnd()
            try handle.write(contentsOf: event.suffix(event.count - event.count / 2))
            try handle.close()
            let complete = await scan(ledger)
            XCTAssertEqual(complete?.series.daily.first?.totalTokens, 100)
            try line(tokens: 300).write(to: ledger, atomically: true, encoding: .utf8)
            let replaced = await scan(ledger)
            XCTAssertEqual(replaced?.series.daily.first?.totalTokens, 300)
        }
    }

    func testFutureEventBecomesEligibleOnWarmScan() async throws {
        try await withLedger { ledger in
            try (line(tokens: 100) + line(tokens: 200, hour: 13)).write(to: ledger, atomically: true, encoding: .utf8)
            let before = await scan(ledger)
            XCTAssertEqual(before?.series.daily.first?.totalTokens, 100)
            let after = await scan(ledger, now: TestLocalInstant.date(2026, 10, 4, 14))
            XCTAssertEqual(after?.series.daily.first?.totalTokens, 300)
        }
    }

    func testOpenCodeHostedRowsBelongOnlyToOpenCode() async throws {
        try await withLedger { ledger in
            let gateway = line(tokens: 100)
                .replacingOccurrences(of: "\"provider\":\"openai\"", with: "\"provider\":\"opencode-free\"")
            try gateway.write(to: ledger, atomically: true, encoding: .utf8)
            let codex = await scan(ledger)
            XCTAssertNil(codex, "the production Codex fold must defer Router's OpenCode share")
            let rows = OpenCodeUsageScanner.routerGatewayRows(atPath: ledger.path, since: now.addingTimeInterval(-86400))
            XCTAssertEqual(rows.reduce(0) { $0 + $1.tokens }, 100)
            OpenCodeUsageScanner.routerLedgerClearCacheForTesting(path: ledger.path)
        }
    }

    func testExtremeCountsDoNotCrashAcrossColdWarmAndAppend() async throws {
        try await withLedger { ledger in
            try (line(tokens: .max) + line(tokens: .max, hour: 11)).write(to: ledger, atomically: true, encoding: .utf8)
            let cold = await scan(ledger)
            XCTAssertEqual(cold?.series.daily.first?.totalTokens, 2_000_000_000_000_000)
            let warm = await scan(ledger)
            XCTAssertEqual(warm?.series.daily.first?.totalTokens, 2_000_000_000_000_000)
            let handle = try FileHandle(forWritingTo: ledger)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line(tokens: 1, hour: 11).utf8))
            try handle.close()
            let append = await scan(ledger)
            XCTAssertEqual(append?.series.daily.first?.totalTokens, 2_000_000_000_000_001)
        }
    }

    func testLegacyHostedSlugWithoutProviderStampStillBelongsToOpenCode() async throws {
        try await withLedger { ledger in
            let event = line(tokens: 100)
                .replacingOccurrences(of: "test-model", with: "anthropic/opencode_go/test-model")
                .replacingOccurrences(of: "\"provider\":\"openai\"", with: "\"provider\":\"anthropic\"")
            try event.write(to: ledger, atomically: true, encoding: .utf8)
            let codex = await scan(ledger)
            XCTAssertNil(codex)
            let rows = OpenCodeUsageScanner.routerGatewayRows(atPath: ledger.path, since: now.addingTimeInterval(-86400))
            XCTAssertEqual(rows.reduce(0) { $0 + $1.tokens }, 100)
            OpenCodeUsageScanner.routerLedgerClearCacheForTesting(path: ledger.path)
        }
    }

    func testTinyAdversarialMixedProviderLedgerKeepsExactPartition() async throws {
        try await withLedger { ledger in
            var lines: [String] = []
            var codexTokens = 0
            var openCodeTokens = 0
            for index in 0..<128 {
                let isOpenCode = index % 2 == 1
                let status = index % 5 == 0 ? 502 : 200
                let provider = isOpenCode ? "OpenCode-Free" : "openai"
                let object: [String: Any] = [
                    "at": TestLocalInstant.iso(2026, 10, 4, 10),
                    "provider": provider, "model": "test-model", "status": status,
                    "inputTokens": 10, "cachedInputTokens": 5,
                    "outputTokens": 5, "reasoningTokens": 4, "totalTokens": 15,
                    "metadata": ["status": 200, "inputTokens": 99_999],
                    "padding": "a quoted decoy: \"status\":200"
                ]
                let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
                lines.append(" \t" + String(decoding: data, as: UTF8.self) + " \r")
                if status == 200 {
                    if isOpenCode { openCodeTokens += 15 } else { codexTokens += 15 }
                }
            }
            try lines.joined(separator: "\n").write(to: ledger, atomically: true, encoding: .utf8)
            let codex = await scan(ledger)
            XCTAssertEqual(codex?.series.daily.first?.totalTokens, codexTokens)
            let rows = OpenCodeUsageScanner.routerGatewayRows(atPath: ledger.path, since: now.addingTimeInterval(-86400))
            XCTAssertEqual(rows.reduce(0) { $0 + $1.tokens }, openCodeTokens)
            let before = try XCTUnwrap(CodexRouterUsageScanner.incrementalReadStatisticsForTesting(path: ledger.path))
            let warm = await scan(ledger)
            XCTAssertEqual(warm?.series.daily.first?.totalTokens, codexTokens)
            let after = try XCTUnwrap(CodexRouterUsageScanner.incrementalReadStatisticsForTesting(path: ledger.path))
            XCTAssertEqual(after.bytesRead, before.bytesRead)
            OpenCodeUsageScanner.routerLedgerClearCacheForTesting(path: ledger.path)
        }
    }
}
