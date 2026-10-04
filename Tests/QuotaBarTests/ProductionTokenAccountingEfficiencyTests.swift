import Darwin
import Foundation
import XCTest
@testable import QuotaBar

/// Measures actual production aggregate paths on a clean hosted Mac using synthetic data only.
final class ProductionTokenAccountingEfficiencyTests: XCTestCase {
    func testNativeGatewayProjectionAvoidsFullHistoryDecodeOnWarmRefresh() async throws {
        guard ProcessInfo.processInfo.environment["QUOTABAR_PRODUCTION_ACCOUNTING_BENCH"] == "1" else {
            throw XCTSkip("Enable the production accounting benchmark on an isolated Mac")
        }
        let fixture = try await GatewayProjectionFixture(rowCount: 8_192)
        defer { fixture.cleanup() }
        let file = try XCTUnwrap(CodexLogUsageScanner.sessionFiles(homes: [fixture.home]).first)
        let projection = CodexGatewayCacheProjection.load(persistence: fixture.native,
            identity: fixture.identity, files: [file])
        let metadata = try XCTUnwrap(projection.metadata[file.path])
        let nativeDecode = await measure {
            try? JSONLScanCacheWriter.shared.loadRecord(persistence: fixture.native,
                identity: fixture.identity, path: file.path, metadata: metadata,
                itemType: CodexLogUsageScanner.Event.self)
        }
        XCTAssertEqual(nativeDecode.result?.items.count, 8_192)
        let scanner = fixture.gatewayScanner()
        let cold = await measure { await fixture.fold(using: scanner) }
        XCTAssertEqual(cold.result.count, 32)
        XCTAssertEqual(cold.result.reduce(0) { $0 + $1.total }, 4_800)
        await scanner.flushPendingWrites()
        let relaunched = fixture.gatewayScanner()
        _ = await fixture.fold(using: relaunched)
        let warm = await measure { () async -> Void in
            for _ in 0..<20 {
                let events = await fixture.fold(using: relaunched)
                XCTAssertEqual(events.count, 32)
                XCTAssertEqual(events.reduce(0) { $0 + $1.total }, 4_800)
            }
        }
        XCTAssertNil(CodexLogUsageScanner.incrementalReadStatisticsForTesting(path: fixture.source.path))
        XCTAssertLessThan(warm.cpu / 20, nativeDecode.cpu / 10,
                          "warm gateway refresh must not repeat the native history decode")
        print(String(format: "PRODUCTION_ACCOUNTING_BENCH provider=opencode-native-gateway rows=8192 gatewayRows=32 nativeDecodeCPU=%.6fs projectionCPU=%.6fs warm20CPU=%.6fs warm20Wall=%.6fs sourceBytes=0", nativeDecode.cpu, cold.cpu, warm.cpu, warm.wall))
    }

    func testRepeatedProductionRefreshReadsOnlyNewBytes() async throws {
        guard ProcessInfo.processInfo.environment["QUOTABAR_PRODUCTION_ACCOUNTING_BENCH"] == "1" else {
            throw XCTSkip("Enable the production accounting benchmark on an isolated Mac")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("qb-production-bench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ledger = directory.appendingPathComponent("usage-events.jsonl")
        defer {
            CodexRouterUsageScanner.clearSharedTailCacheForTesting(path: ledger.path)
            OpenCodeUsageScanner.routerLedgerClearCacheForTesting(path: ledger.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let now = Date()
        try TokenAccountingEfficiencyTests.writeSyntheticLedger(to: ledger, endingAt: now.addingTimeInterval(-60), rowCount: 8_192, totalBytes: 3_276_800)
        let pricing = TestPricing.bundled
        func scan() async -> LogUsageScan? {
            let scanner = CodexRouterUsageScanner(ledgerPaths: { [ledger.path] }, identityAliases: { [:] })
            return await scanner.scan(accountIdentityKey: "benchmark-first-account",
                                      allowsUnscopedEvents: false, daysBack: 30, now: now, pricing: pricing)
        }
        let cold = await measure { await scan() }
        let expected = 4_096 * 1_801
        XCTAssertEqual(cold.result?.series.daily.reduce(0) { $0 + $1.totalTokens }, expected)
        let initial = try XCTUnwrap(CodexRouterUsageScanner.incrementalReadStatisticsForTesting(path: ledger.path))
        let warm = await measure {
            for _ in 0..<20 {
                let result = await scan()
                XCTAssertEqual(result?.series.daily.reduce(0) { $0 + $1.totalTokens }, expected)
            }
            return ()
        }
        let reused = try XCTUnwrap(CodexRouterUsageScanner.incrementalReadStatisticsForTesting(path: ledger.path))
        XCTAssertEqual(reused.fullParses, initial.fullParses)
        XCTAssertEqual(reused.bytesRead, initial.bytesRead, "repeated refreshes must read zero ledger bytes")
        let fingerprint = CodexProxyUsageScanner.accountFingerprint(for: "benchmark-first-account")!
        let line = "{\"at\":\"\(OpenUsageISO8601.string(from: now.addingTimeInterval(-10)))\",\"model\":\"gpt-5.5\",\"provider\":\"openai\",\"status\":200,\"inputTokens\":100,\"outputTokens\":50,\"totalTokens\":150,\"accountFingerprint\":\"\(fingerprint)\"}\n"
        let handle = try FileHandle(forWritingTo: ledger)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line.utf8))
        try handle.close()
        let appended = await measure { await scan() }
        XCTAssertEqual(appended.result?.series.daily.reduce(0) { $0 + $1.totalTokens }, expected + 150)
        let final = try XCTUnwrap(CodexRouterUsageScanner.incrementalReadStatisticsForTesting(path: ledger.path))
        XCTAssertEqual(final.fullParses, initial.fullParses)
        XCTAssertEqual(final.bytesRead - initial.bytesRead, line.utf8.count)
        XCTAssertLessThan(warm.cpu, cold.cpu / 10, "twenty unchanged refreshes must do far less CPU work than one cold fold")
        XCTAssertLessThan(appended.cpu, cold.cpu / 10, "one appended event must not repeat cold-index work")
        print(String(format: "PRODUCTION_ACCOUNTING_BENCH provider=codex rows=8192 coldCPU=%.6fs coldWall=%.6fs warm20CPU=%.6fs warm20Wall=%.6fs appendCPU=%.6fs appendWall=%.6fs warmBytes=%d appendBytes=%d", cold.cpu, cold.wall, warm.cpu, warm.wall, appended.cpu, appended.wall, reused.bytesRead - initial.bytesRead, final.bytesRead - initial.bytesRead))

        // The same large-file branch used by Router's OpenCode share must retain exact token totals.
        var gatewayLines = ""
        for index in 0..<8_192 {
            let dayOffset = (index / 32) % 8
            let stamp = OpenUsageISO8601.string(from: now.addingTimeInterval(-60 - Double(dayOffset * 86_400)))
            let model = "opencode-free/space-bunny-free-\(index % 32)"
            gatewayLines += "{\"at\":\"\(stamp)\",\"model\":\"\(model)\",\"provider\":\"opencode-free\",\"status\":200,\"inputTokens\":100,\"cachedInputTokens\":25,\"outputTokens\":50,\"totalTokens\":150}\n"
        }
        try gatewayLines.write(to: ledger, atomically: true, encoding: .utf8)
        let since = now.addingTimeInterval(-10 * 86400)
        func gatewayRows() -> [OpenCodeUsageScanner.ClaudeGatewayRow] {
            OpenCodeUsageScanner.routerGatewayRows(atPath: ledger.path, since: since)
        }
        let gatewayCold = await measure { gatewayRows() }
        XCTAssertEqual(gatewayCold.result.reduce(0) { $0 + $1.input + $1.cacheRead + $1.output }, 8_192 * 150)
        let gatewayInitial = try XCTUnwrap(OpenCodeUsageScanner.routerLedgerReadStatisticsForTesting(path: ledger.path))
        let gatewayWarm = await measure { () async -> Void in
            for _ in 0..<20 {
                XCTAssertEqual(gatewayRows().reduce(0) { $0 + $1.input + $1.cacheRead + $1.output }, 8_192 * 150)
            }
        }
        let gatewayFinal = try XCTUnwrap(OpenCodeUsageScanner.routerLedgerReadStatisticsForTesting(path: ledger.path))
        XCTAssertEqual(gatewayFinal.bytesRead, gatewayInitial.bytesRead)
        XCTAssertEqual(gatewayFinal.fullParses, gatewayInitial.fullParses)
        XCTAssertLessThan(gatewayWarm.cpu / 20, gatewayCold.cpu / 10)
        print(String(format: "PRODUCTION_ACCOUNTING_BENCH provider=opencode rows=8192 coldCPU=%.6fs coldWall=%.6fs warm20CPU=%.6fs warm20Wall=%.6fs warmBytes=%d", gatewayCold.cpu, gatewayCold.wall, gatewayWarm.cpu, gatewayWarm.wall, gatewayFinal.bytesRead - gatewayInitial.bytesRead))
    }

    private func measure<T>(_ body: () async -> T) async -> (result: T, cpu: Double, wall: Double) {
        let cpu = cpuSeconds()
        let wall = DispatchTime.now().uptimeNanoseconds
        let result = await body()
        return (result, cpuSeconds() - cpu, Double(DispatchTime.now().uptimeNanoseconds - wall) / 1e9)
    }

    private func cpuSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }
}
