import Darwin
import Foundation
import XCTest
@testable import QuotaBar

/// Opt-in, synthetic CPU comparisons. No credentials, network, or production transcripts are read.
final class ProviderScannerEfficiencyTests: XCTestCase {
    func testCodexCatalogueChurnReusesTheProductionCheckpoint() async throws {
        guard ProcessInfo.processInfo.environment["QUOTABAR_PRODUCTION_ACCOUNTING_BENCH"] == "1" else {
            throw XCTSkip("Enable the synthetic production accounting benchmark")
        }
        let now = TestLocalInstant.date(2026, 10, 20, 12)
        let timestamp = OpenUsageISO8601.string(from: now.addingTimeInterval(-60))
        let row = "{\"at\":\"\(timestamp)\",\"model\":\"test-model\",\"provider\":\"openai\",\"status\":200,\"inputTokens\":100,\"outputTokens\":0,\"totalTokens\":100}\n"
        let home = try ClaudeLogFixture.makeHome(files: [:])
        let source = home.appendingPathComponent("usage-events.jsonl")
        defer {
            CodexRouterUsageScanner.clearSharedTailCacheForTesting(path: source.path)
            try? FileManager.default.trashItem(at: home, resultingItemURL: nil)
        }
        try String(repeating: row, count: 8_192).write(to: source, atomically: true, encoding: .utf8)
        func pricing(_ unrelated: Double) -> ModelPricing {
            func rates(_ value: Double) -> ModelRates {
                ModelRates(inputPerMillion: value, outputPerMillion: value,
                           cacheWritePerMillion: value, cacheReadPerMillion: value)
            }
            return ModelPricing(supplement: PricingSupplement(), primary: PricingCatalog(entries: [
                "test-model": rates(1), "unrelated-model": rates(unrelated)
            ]), secondary: PricingCatalog())
        }
        func scan(_ pricing: ModelPricing) async -> LogUsageScan? {
            let scanner = CodexRouterUsageScanner(ledgerPaths: { [source.path] }, identityAliases: { [:] })
            return await scanner.scan(accountIdentityKey: nil, allowsUnscopedEvents: true,
                                      daysBack: 30, now: now, pricing: pricing)
        }
        let cold = await measureCPU {
            let result = await scan(pricing(1))
            XCTAssertEqual(result?.series.daily.first?.totalTokens, 819_200)
        }
        let initial = try XCTUnwrap(CodexRouterUsageScanner.incrementalReadStatisticsForTesting(path: source.path))
        let churn = await measureCPU {
            for revision in 2...21 {
                let result = await scan(pricing(Double(revision)))
                XCTAssertEqual(result?.series.daily.first?.totalTokens, 819_200)
                XCTAssertEqual(result?.series.daily.first?.costUSD ?? 0, 0.8192, accuracy: 1e-10)
            }
        }
        let final = try XCTUnwrap(CodexRouterUsageScanner.incrementalReadStatisticsForTesting(path: source.path))
        XCTAssertEqual(initial.fullParses, final.fullParses)
        XCTAssertEqual(initial.bytesRead, final.bytesRead)
        XCTAssertLessThan(churn / 20, cold / 5)
        print(String(format: "SCANNER_EFFICIENCY provider=codex-pricing rows=8192 coldCPU=%.6fs changedCatalogue20CPU=%.6fs changedCatalogueEventBytes=%d",
                     cold, churn, final.bytesRead - initial.bytesRead))
    }

    func testActiveClaudeSessionReadsOnlyAppendedEventBytes() async throws {
        guard ProcessInfo.processInfo.environment["QUOTABAR_PRODUCTION_ACCOUNTING_BENCH"] == "1" else {
            throw XCTSkip("Enable the synthetic production accounting benchmark")
        }
        let timestamp = OpenUsageISO8601.string(from: TestLocalInstant.date(2026, 10, 20, 12))
        let rowCount = 8_192
        func line(_ id: Int) -> String {
            "{\"timestamp\":\"\(timestamp)\",\"requestId\":\"r\(id)\",\"message\":{\"id\":\"m\(id)\",\"model\":\"claude-test-model\",\"usage\":{\"input_tokens\":100,\"output_tokens\":25}}}\n"
        }
        let content = (0..<rowCount).map(line).joined()
        let home = try ClaudeLogFixture.makeHome(files: ["project/session.jsonl": content])
        defer { try? FileManager.default.trashItem(at: home, resultingItemURL: nil) }
        let source = home.appendingPathComponent("projects/project/session.jsonl")
        let cache = ClaudeSessionAppendCache()
        func read() -> [ClaudeLogUsageScanner.Entry]? {
            cache.parse(at: source) { line in
                ClaudeLogUsageScanner.parseLine(Data(line)).map { [$0] }
            }
        }
        let cold = await measureCPU { XCTAssertEqual(read()?.count, rowCount) }
        let initial = try XCTUnwrap(cache.statistics(path: source.path))
        let appendedLine = line(rowCount)
        let handle = try FileHandle(forWritingTo: source)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(appendedLine.utf8))
        try handle.close()
        let append = await measureCPU {
            let entries = read()
            XCTAssertEqual(entries?.count, rowCount + 1)
            XCTAssertEqual(entries?.reduce(0) { $0 + $1.tokens.totalTokens }, (rowCount + 1) * 125)
        }
        let final = try XCTUnwrap(cache.statistics(path: source.path))
        XCTAssertEqual(final.fullParses, initial.fullParses)
        XCTAssertEqual(final.tailParses, initial.tailParses + 1)
        XCTAssertEqual(final.bytesRead - initial.bytesRead, appendedLine.utf8.count)
        XCTAssertLessThan(append, cold / 5)
        print(String(format: "SCANNER_EFFICIENCY provider=claude-append rows=%d coldCPU=%.6fs appendCPU=%.6fs coldEventBytes=%d appendEventBytes=%d",
                     rowCount, cold, append, initial.bytesRead, final.bytesRead - initial.bytesRead))
    }

    func testClaudeUnchangedFoldsAvoidRebuildingNativeAndGatewayHistory() async throws {
        guard ProcessInfo.processInfo.environment["QUOTABAR_PRODUCTION_ACCOUNTING_BENCH"] == "1" else {
            throw XCTSkip("Enable the synthetic production accounting benchmark")
        }
        let now = TestLocalInstant.date(2026, 10, 20, 12)
        let timestamp = OpenUsageISO8601.string(from: now.addingTimeInterval(-60))
        let rowCount = 8_192
        let gatewayRows = 32
        let content = (0..<rowCount).map { i in
            let model = i < gatewayRows ? "anthropic/opencode_go/claude-test-model" : "claude-test-model"
            return "{\"timestamp\":\"\(timestamp)\",\"requestId\":\"r\(i)\",\"message\":{\"id\":\"m\(i)\",\"model\":\"\(model)\",\"usage\":{\"input_tokens\":100,\"output_tokens\":25}}}"
        }.joined(separator: "\n") + "\n"
        let home = try ClaudeLogFixture.makeHome(files: ["project/session.jsonl": content])
        defer { try? FileManager.default.trashItem(at: home, resultingItemURL: nil) }
        let incremental = IncrementalJSONLScanner<ClaudeLogUsageScanner.Entry>()
        func scanner() -> ClaudeLogUsageScanner {
            ClaudeLogUsageScanner(environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": home.path]),
                                 homeDirectory: { home }, incrementalScanner: incremental,
                                 cacheIdentityOverride: home.path)
        }
        let pricing = ModelPricing(supplement: PricingSupplement(), primary: PricingCatalog(entries: [
            "claude-test-model": ModelRates(inputPerMillion: 10, outputPerMillion: 20,
                                             cacheWritePerMillion: 10, cacheReadPerMillion: 1)
        ]), secondary: PricingCatalog())
        let cached = scanner()
        let firstResult = await cached.scan(now: now, pricing: pricing)
        let first = try XCTUnwrap(firstResult)
        XCTAssertEqual(first.series.daily.first?.totalTokens, (rowCount - gatewayRows) * 125)
        // Fresh scanner wrappers deliberately bypass only the result memo. Both sides use the same
        // already-warm parse actor, pricing and source so this isolates avoided fold/dedup work.
        let rebuild = await measureCPU {
            for _ in 0..<5 {
                let result = await scanner().scan(now: now, pricing: pricing)
                XCTAssertEqual(result?.series, first.series)
            }
        }
        let warm = await measureCPU {
            for _ in 0..<20 {
                let result = await cached.scan(now: now, pricing: pricing)
                XCTAssertEqual(result?.series, first.series)
            }
        }
        XCTAssertLessThan(warm / 20, rebuild / 5 / 5)

        func fold(_ instance: ClaudeLogUsageScanner) async {
            let count = Counter()
            let complete = await instance.foldParsedEntries(
                now: now, roots: [home], cacheIdentityOverride: home.path, hostedGatewayOnly: true
            ) { entry in count.add(entry.tokens.totalTokens) }
            XCTAssertTrue(complete)
            XCTAssertEqual(count.total, gatewayRows * 125)
        }
        await fold(cached)
        let gatewayRebuild = await measureCPU { for _ in 0..<5 { await fold(scanner()) } }
        let gatewayWarm = await measureCPU { for _ in 0..<20 { await fold(cached) } }
        XCTAssertLessThan(gatewayWarm / 20, gatewayRebuild / 5 / 5)
        print(String(format: "SCANNER_EFFICIENCY provider=claude rows=%d rebuild5CPU=%.6fs warm20CPU=%.6fs gatewayRebuild5CPU=%.6fs gatewayWarm20CPU=%.6fs gatewayRows=%d",
                     rowCount, rebuild, warm, gatewayRebuild, gatewayWarm, gatewayRows))
    }

    private func measureCPU(_ body: () async -> Void) async -> Double {
        let start = cpuSeconds()
        await body()
        return cpuSeconds() - start
    }

    private func cpuSeconds() -> Double {
        var usage = rusage()
        precondition(getrusage(RUSAGE_SELF, &usage) == 0)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var total: Int { lock.withLock { value } }
        func add(_ tokens: Int) { lock.withLock { value += tokens } }
    }
}
