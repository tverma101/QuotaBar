import Darwin
import XCTest
@testable import QuotaBar

/// Opt-in benchmark for CodexRouter indexing and refresh. It uses a deterministic synthetic ledger,
/// so it never reads or uploads a user's token history. Output contains aggregate counts and timings only.
final class TokenAccountingEfficiencyTests: XCTestCase {
    private static let syntheticRows = 113_447
    private static let syntheticBytes = 44_879_133

    func testRepeatedRouterAccountingStaysBelowTenPercentOfOneCore() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("qb-token-accounting-bench-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: scratch,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: scratch) }

        guard let mode = ProcessInfo.processInfo.environment["QUOTABAR_TOKEN_ACCOUNTING_MODE"] else {
            throw XCTSkip("Set QUOTABAR_TOKEN_ACCOUNTING_MODE to run the opt-in synthetic benchmark")
        }
        guard mode == "paced" || mode == "raw" else {
            throw XCTSkip("QUOTABAR_TOKEN_ACCOUNTING_MODE must be 'raw' or 'paced'")
        }
        let shouldThrottle = mode == "paced"
        let measurement = try await ProviderRefreshContext.$accountingCPUThrottleEnabled.withValue(shouldThrottle) {
            try await runMode(scratch: scratch)
        }
        let coldOneCoreShare = measurement.coldCPUSeconds / measurement.coldWallSeconds
        let hydrateOneCoreShare = measurement.cacheHydrateCPUSeconds / measurement.cacheHydrateWallSeconds
        // Unchanged snapshots run on RefreshSetting.interval; the file watcher coalesces active
        // append bursts for CodexRouterLedgerWatcher.debounceNanoseconds (one second by default).
        let warmOneCoreShare = measurement.warmCPUSeconds / (3 * RefreshSetting.interval)
        print(String(
            format: "TOKEN_ACCOUNTING_BENCH mode=%@ rows=%d bytes=%llu coldCPU=%.3fs coldWall=%.3fs coldOneCore=%.2f%% cacheHydrateCPU=%.3fs cacheHydrateWall=%.3fs cacheHydrateOneCore=%.2f%% warmCPU=%.3fs warmWall=%.3fs warmOneCore=%.2f%% appendCPU=%.3fs appendWall=%.3fs appendOneCore=%.2f%%",
            mode,
            measurement.residentRows,
            measurement.ledgerBytes,
            measurement.coldCPUSeconds,
            measurement.coldWallSeconds,
            coldOneCoreShare * 100,
            measurement.cacheHydrateCPUSeconds,
            measurement.cacheHydrateWallSeconds,
            hydrateOneCoreShare * 100,
            measurement.warmCPUSeconds,
            measurement.warmActiveWallSeconds,
            warmOneCoreShare * 100,
            measurement.appendCPUSeconds,
            measurement.appendWallSeconds,
            measurement.appendOneCoreShare * 100
        ))

        XCTAssertGreaterThan(measurement.residentRows, 0)
        XCTAssertEqual(measurement.residentRows, Self.syntheticRows, "all synthetic rows must be indexed")
        XCTAssertEqual(measurement.ledgerBytes, UInt64(Self.syntheticBytes), "the fixture size must stay fixed")
        XCTAssertLessThanOrEqual(measurement.residentRows, 128_000, "the active resident index must respect its item cap")
        if shouldThrottle {
            XCTAssertLessThan(coldOneCoreShare, 0.10, "automatic cold indexing must use under 10% of one core")
            XCTAssertLessThan(hydrateOneCoreShare, 0.10, "automatic parse-cache hydration must use under 10% of one core")
            XCTAssertLessThan(warmOneCoreShare, 0.10, "memoized refresh CPU at the configured 5-minute cadence must stay under 10% of one core")
            XCTAssertLessThan(measurement.appendOneCoreShare, 0.10, "tail indexing + incremental token/cost fold must use under 10% of one core")
            XCTAssertLessThan(measurement.coldWallSeconds, 120, "automatic cold indexing must finish before the provider refresh deadline")
            XCTAssertLessThan(measurement.cacheHydrateWallSeconds, 120, "parse-cache hydration must finish before the provider refresh deadline")
        }
    }

    private struct Measurement {
        var coldCPUSeconds: Double
        var coldWallSeconds: Double
        var cacheHydrateCPUSeconds: Double
        var cacheHydrateWallSeconds: Double
        var warmCPUSeconds: Double
        var warmActiveWallSeconds: Double
        var appendCPUSeconds: Double
        var appendWallSeconds: Double
        var appendOneCoreShare: Double
        var residentRows: Int
        var ledgerBytes: UInt64
    }

    private func runMode(
        scratch: URL
    ) async throws -> Measurement {
        let modeRoot = scratch.appendingPathComponent("panel-resident", isDirectory: true)
        try FileManager.default.createDirectory(at: modeRoot, withIntermediateDirectories: true)
        let ledger = modeRoot.appendingPathComponent("usage-events.jsonl")
        try Self.writeSyntheticLedger(to: ledger)
        let size = try FileManager.default.attributesOfItem(atPath: ledger.path)[.size] as? NSNumber

        let persistenceDir = modeRoot.appendingPathComponent("index-cache", isDirectory: true)
        try FileManager.default.createDirectory(at: persistenceDir, withIntermediateDirectories: true)
        let scanner = IncrementalJSONLScanner<CodexRouterUsageScanner.Event>(
            maxResidentIdentities: 1,
            maxResidentItems: 128_000,
            retainResidentItems: true,
            logTag: LogTag.plugin("codex"),
            persistence: JSONLScanCachePersistence(
                namespace: "router-benchmark",
                schemaVersion: 1,
                directory: persistenceDir,
                writeDebounce: .milliseconds(10)
            )
        )
        let scannerUnderTest = CodexRouterUsageScanner(
            ledgerPaths: { [ledger.path] },
            identityAliases: { [:] },
            incrementalScanner: scanner
        )
        let now = Date()
        let coldWallStart = DispatchTime.now().uptimeNanoseconds
        let coldStart = Self.cpuSeconds()
        let coldScan = await scannerUnderTest.scan(
            accountIdentityKey: nil,
            allowsUnscopedEvents: true,
            daysBack: 30,
            now: now,
            pricing: TestPricing.bundled
        )
        XCTAssertNotNil(coldScan, "the representative ledger must produce an accounting result")
        let coldCPU = Self.cpuSeconds() - coldStart
        let coldWall = Double(DispatchTime.now().uptimeNanoseconds - coldWallStart) / 1_000_000_000
        await scanner.flushPendingWrites()

        // Simulate the next app launch: a fresh scanner instance must hydrate the durable parsed index
        // and fold a second account without reparsing the source ledger.
        let relaunchedScanner = IncrementalJSONLScanner<CodexRouterUsageScanner.Event>(
            maxResidentIdentities: 1,
            maxResidentItems: 128_000,
            retainResidentItems: true,
            logTag: LogTag.plugin("codex"),
            persistence: JSONLScanCachePersistence(
                namespace: "router-benchmark",
                schemaVersion: 1,
                directory: persistenceDir,
                writeDebounce: .milliseconds(10)
            )
        )
        let secondAccountScanner = CodexRouterUsageScanner(
            ledgerPaths: { [ledger.path] },
            identityAliases: { [:] },
            incrementalScanner: relaunchedScanner
        )
        let hydrateWallStart = DispatchTime.now().uptimeNanoseconds
        let hydrateCPUStart = Self.cpuSeconds()
        let secondAccountBaseline = await secondAccountScanner.scan(
            accountIdentityKey: "benchmark-second-account",
            allowsUnscopedEvents: true,
            daysBack: 30,
            now: now,
            pricing: TestPricing.bundled
        )
        let cacheHydrateCPU = Self.cpuSeconds() - hydrateCPUStart
        let cacheHydrateWall = Double(DispatchTime.now().uptimeNanoseconds - hydrateWallStart) / 1_000_000_000
        let hydratedRows = await relaunchedScanner.residentItemCountForTesting()
        XCTAssertGreaterThan(hydratedRows, 0, "the new scanner must load parsed rows from the on-disk index")

        var warmCPU = 0.0
        var wall = 0.0
        for _ in 0..<3 {
            let slotStart = DispatchTime.now().uptimeNanoseconds
            let cpuStart = Self.cpuSeconds()
            _ = await scannerUnderTest.scan(
                accountIdentityKey: nil,
                allowsUnscopedEvents: true,
                daysBack: 30,
                now: now,
                pricing: TestPricing.bundled
            )
            warmCPU += Self.cpuSeconds() - cpuStart
            wall += Double(DispatchTime.now().uptimeNanoseconds - slotStart) / 1_000_000_000
        }

        // Simulate one new successful router event. This exercises append parsing and the cached
        // account fold without exposing any ledger row contents in test output.
        let stamp = ISO8601DateFormatter().string(from: Date())
        let event = "\n{\"at\":\"\(stamp)\",\"model\":\"space-bunny-free\",\"provider\":\"openai\",\"status\":200,\"inputTokens\":10,\"cachedInputTokens\":2,\"outputTokens\":5,\"totalTokens\":15}\n"
        let handle = try FileHandle(forWritingTo: ledger)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(event.utf8))
        try handle.close()
        let beforeTokens = try XCTUnwrap(coldScan?.series.daily.reduce(0) { $0 + $1.totalTokens })
        let appendSlotStart = DispatchTime.now().uptimeNanoseconds
        let appendCPUStart = Self.cpuSeconds()
        let appendedScan = await scannerUnderTest.scan(
            accountIdentityKey: nil,
            allowsUnscopedEvents: true,
            daysBack: 30,
            now: now,
            pricing: TestPricing.bundled
        )
        let secondAccountAppend = await secondAccountScanner.scan(
            accountIdentityKey: "benchmark-second-account",
            allowsUnscopedEvents: true,
            daysBack: 30,
            now: now,
            pricing: TestPricing.bundled
        )
        let appendCPU = Self.cpuSeconds() - appendCPUStart
        XCTAssertEqual(appendedScan?.series.daily.reduce(0) { $0 + $1.totalTokens }, beforeTokens + 15)
        let secondAccountBefore = secondAccountBaseline?.series.daily.reduce(0) { $0 + $1.totalTokens } ?? 0
        XCTAssertEqual(secondAccountAppend?.series.daily.reduce(0) { $0 + $1.totalTokens }, secondAccountBefore + 15)
        let appendWall = Double(DispatchTime.now().uptimeNanoseconds - appendSlotStart) / 1_000_000_000

        let residentRows = await scanner.residentItemCountForTesting()
        CodexRouterUsageScanner.clearSharedTailCacheForTesting(path: ledger.path)
        return Measurement(
            coldCPUSeconds: coldCPU,
            coldWallSeconds: coldWall,
            cacheHydrateCPUSeconds: cacheHydrateCPU,
            cacheHydrateWallSeconds: cacheHydrateWall,
            warmCPUSeconds: warmCPU,
            warmActiveWallSeconds: wall,
            appendCPUSeconds: appendCPU,
            appendWallSeconds: appendWall,
            appendOneCoreShare: appendCPU / appendWall,
            residentRows: residentRows,
            ledgerBytes: size?.uint64Value ?? 0
        )
    }

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        return user + system
    }

    /// Writes the same fixed number of bytes on every run. Rows resemble successful CodexRouter
    /// events, use real bundled model pricing, and span the active 30-day accounting window.
    private static func writeSyntheticLedger(to url: URL) throws {
        let models: [(name: String, provider: String)] = [
            ("gpt-5.5", "openai"),
            ("gpt-5.4", "openai"),
            ("deepseek-v4-pro", "deepseek"),
            ("claude-sonnet-4-5", "anthropic"),
        ]
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let end = ISO8601DateFormatter().date(from: "2026-10-02T12:00:00Z")!
        let timestamps = (0..<720).map { hour in
            formatter.string(from: end.addingTimeInterval(-Double(hour) * 3_600))
        }

        guard FileManager.default.createFile(
            atPath: url.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw NSError(domain: "TokenAccountingEfficiencyTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Could not create synthetic accounting ledger"
            ])
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        let baseBytes = syntheticBytes / syntheticRows
        let extraBytes = syntheticBytes % syntheticRows
        var block = Data()
        block.reserveCapacity(1 << 20)
        for index in 0..<syntheticRows {
            let model = models[index % models.count]
            let prefix = "{\"at\":\"\(timestamps[index % timestamps.count])\",\"model\":\"\(model.name)\",\"provider\":\"\(model.provider)\",\"status\":200,\"inputTokens\":1234,\"cachedInputTokens\":234,\"outputTokens\":567,\"reasoningTokens\":89,\"totalTokens\":1801,\"accountFingerprint\":\"acct_benchmark\",\"serviceTier\":\"default\",\"padding\":\""
            let suffix = "\"}\n"
            let targetRowBytes = baseBytes + (index < extraBytes ? 1 : 0)
            let paddingBytes = targetRowBytes - prefix.utf8.count - suffix.utf8.count
            guard paddingBytes >= 0 else {
                throw NSError(domain: "TokenAccountingEfficiencyTests", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Synthetic event fields exceed the target row size"
                ])
            }
            block.append(contentsOf: prefix.utf8)
            block.append(contentsOf: repeatElement(UInt8(ascii: "x"), count: paddingBytes))
            block.append(contentsOf: suffix.utf8)
            if block.count >= 1 << 20 {
                try handle.write(contentsOf: block)
                block.removeAll(keepingCapacity: true)
            }
        }
        if !block.isEmpty { try handle.write(contentsOf: block) }
        try handle.synchronize()
    }
}
