import Darwin
import Foundation
import XCTest
@testable import QuotaBar

/// Opt-in benchmark for CodexRouter indexing and refresh. It uses a deterministic synthetic ledger,
/// so it never reads or uploads a user's token history. Output contains aggregate counts and timings only.
final class TokenAccountingEfficiencyTests: XCTestCase {
    private static let syntheticRows = 8_192
    private static let syntheticBytes = 3_276_800

    func testAutomaticFullRefreshPacingIncludesReapedSQLiteStyleChildCPU() async throws {
        let measurement = try await ProviderRefreshContext.$scope.withValue(.full) {
            try await ProviderRefreshContext.$accountingCPUThrottleEnabled.withValue(true) {
                let wallStart = DispatchTime.now().uptimeNanoseconds
                let cpuStart = Self.cpuSeconds()
                try JSONLAccountingWorkPacer.shared.perform {
                    let child = Process()
                    child.executableURL = URL(fileURLWithPath: "/bin/sh")
                    child.arguments = ["-c", #"i=0; while [ "$i" -lt 50000 ]; do i=$((i + 1)); done"#]
                    try child.run()
                    child.waitUntilExit()
                    guard child.terminationStatus == 0 else {
                        throw NSError(domain: "TokenAccountingEfficiencyTests", code: 3)
                    }
                }
                let cpu = Self.cpuSeconds() - cpuStart
                let wall = Double(DispatchTime.now().uptimeNanoseconds - wallStart) / 1_000_000_000
                return (cpu, wall)
            }
        }

        XCTAssertGreaterThan(measurement.0, 0.010,
                             "reaped child CPU must materially contribute to the accounting measurement")
        XCTAssertLessThan(measurement.0 / measurement.1, 0.10,
                          "the automatic menu-bar pass must pace child-process accounting too")
    }

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
        let measurement = try await ProviderRefreshContext.$scope.withValue(.full) {
            try await ProviderRefreshContext.$accountingCPUThrottleEnabled.withValue(shouldThrottle) {
                try await runMode(scratch: scratch)
            }
        }
        let coldOneCoreShare = measurement.coldCPUSeconds / measurement.coldWallSeconds
        let hydrateOneCoreShare = measurement.cacheHydrateCPUSeconds / measurement.cacheHydrateWallSeconds
        // Measure the three unchanged scans over their actual active wall time. Cadence-average
        // CPU would hide a hot refresh behind the five-minute timer gap.
        let warmOneCoreShare = measurement.warmCPUSeconds / measurement.warmActiveWallSeconds
        print(String(
            format: "TOKEN_ACCOUNTING_BENCH mode=%@ rows=%d bytes=%llu coldCPU=%.3fs coldWall=%.3fs coldOneCore=%.2f%% coldScanCPU=%.3fs coldScanWall=%.3fs coldPersistCPU=%.3fs coldPersistWall=%.3fs cacheHydrateCPU=%.3fs cacheHydrateWall=%.3fs cacheHydrateOneCore=%.2f%% warmCPU=%.3fs warmActiveWall=%.3fs warmActiveOneCore=%.2f%% appendCPU=%.3fs appendWall=%.3fs appendOneCore=%.2f%%",
            mode,
            measurement.residentRows,
            measurement.ledgerBytes,
            measurement.coldCPUSeconds,
            measurement.coldWallSeconds,
            coldOneCoreShare * 100,
            measurement.coldScanCPUSeconds,
            measurement.coldScanWallSeconds,
            measurement.coldPersistCPUSeconds,
            measurement.coldPersistWallSeconds,
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
            XCTAssertLessThan(warmOneCoreShare, 0.10, "an active memoized refresh must stay under 10% of one core")
            XCTAssertLessThan(measurement.appendOneCoreShare, 0.10, "tail indexing + incremental token/cost fold must use under 10% of one core")
            XCTAssertLessThan(measurement.coldScanWallSeconds, 120, "automatic cold indexing must finish before the provider refresh deadline")
            XCTAssertLessThan(measurement.cacheHydrateWallSeconds, 120, "parse-cache hydration must finish before the provider refresh deadline")
        }
    }

    private struct Measurement {
        var coldCPUSeconds: Double
        var coldWallSeconds: Double
        var coldScanCPUSeconds: Double
        var coldScanWallSeconds: Double
        var coldPersistCPUSeconds: Double
        var coldPersistWallSeconds: Double
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
        // Leave a second between the fixture's newest timestamp and the scan upper bound. ISO-8601
        // formatting truncates fractional precision; this keeps rounding from putting row zero in
        // the future on some runs.
        let now = Date().addingTimeInterval(2)
        try Self.writeSyntheticLedger(to: ledger, endingAt: now.addingTimeInterval(-1))
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
        let pricing = TestPricing.bundled
        let coldWallStart = DispatchTime.now().uptimeNanoseconds
        let coldStart = Self.cpuSeconds()
        let coldScan = await scannerUnderTest.scan(
            accountIdentityKey: "benchmark-first-account",
            allowsUnscopedEvents: false,
            daysBack: 30,
            now: now,
            pricing: pricing
        )
        let coldScanCPU = Self.cpuSeconds() - coldStart
        let coldScanWall = Double(DispatchTime.now().uptimeNanoseconds - coldWallStart) / 1_000_000_000
        XCTAssertNotNil(coldScan, "the representative ledger must produce an accounting result")
        let expectedFirstAccountTokens = ((Self.syntheticRows + 1) / 2) * 1_801
        XCTAssertEqual(coldScan?.series.daily.reduce(0) { $0 + $1.totalTokens }, expectedFirstAccountTokens)
        XCTAssertTrue(coldScan?.unknownModelsByDay.isEmpty == true, "every benchmark model must be priced")
        XCTAssertGreaterThan(coldScan?.series.daily.compactMap(\.costUSD).reduce(0, +) ?? 0, 0)
        let persistWallStart = DispatchTime.now().uptimeNanoseconds
        let persistCPUStart = Self.cpuSeconds()
        await scanner.flushPendingWrites()
        let persistCPU = Self.cpuSeconds() - persistCPUStart
        let persistWall = Double(DispatchTime.now().uptimeNanoseconds - persistWallStart) / 1_000_000_000
        let coldCPU = Self.cpuSeconds() - coldStart
        let coldWall = Double(DispatchTime.now().uptimeNanoseconds - coldWallStart) / 1_000_000_000

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
            allowsUnscopedEvents: false,
            daysBack: 30,
            now: now,
            pricing: pricing
        )
        let cacheHydrateCPU = Self.cpuSeconds() - hydrateCPUStart
        let cacheHydrateWall = Double(DispatchTime.now().uptimeNanoseconds - hydrateWallStart) / 1_000_000_000
        let hydratedRows = await relaunchedScanner.residentItemCountForTesting()
        XCTAssertGreaterThan(hydratedRows, 0, "the new scanner must load parsed rows from the on-disk index")
        XCTAssertEqual(secondAccountBaseline?.series.daily.reduce(0) { $0 + $1.totalTokens }, (Self.syntheticRows / 2) * 1_801)
        XCTAssertTrue(secondAccountBaseline?.unknownModelsByDay.isEmpty == true)
        XCTAssertGreaterThan(secondAccountBaseline?.series.daily.compactMap(\.costUSD).reduce(0, +) ?? 0, 0)

        var warmCPU = 0.0
        var wall = 0.0
        // Repeat the short active cache-hit path to smooth sub-millisecond timer and CPU sampling
        // noise while preserving per-refresh pacing and filesystem revision checks.
        for _ in 0..<128 {
            let slotStart = DispatchTime.now().uptimeNanoseconds
            let cpuStart = Self.cpuSeconds()
            _ = await scannerUnderTest.scan(
                accountIdentityKey: "benchmark-first-account",
                allowsUnscopedEvents: false,
                daysBack: 30,
                now: now,
                pricing: pricing
            )
            warmCPU += Self.cpuSeconds() - cpuStart
            wall += Double(DispatchTime.now().uptimeNanoseconds - slotStart) / 1_000_000_000
        }

        // Simulate an append burst of successful router events. This exercises tail parsing and the
        // cached account fold without exposing any ledger row contents in test output.
        let stamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-1))
        let secondAccountFingerprint = CodexProxyUsageScanner.accountFingerprint(for: "benchmark-second-account")!
        // Keep the measured burst long enough that scheduler and timer noise do not dominate its
        // CPU ratio. A few thousand new rows is still a small append relative to the cold ledger.
        let appendedEventCount = 4_096
        let appendedTokenCount = appendedEventCount * 15
        let eventLine = "{\"at\":\"\(stamp)\",\"model\":\"space-bunny-free\",\"provider\":\"openai\",\"status\":200,\"inputTokens\":10,\"cachedInputTokens\":2,\"outputTokens\":5,\"totalTokens\":15,\"accountFingerprint\":\"\(secondAccountFingerprint)\"}"
        let event = "\n" + Array(repeating: eventLine, count: appendedEventCount).joined(separator: "\n") + "\n"
        let handle = try FileHandle(forWritingTo: ledger)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(event.utf8))
        try handle.close()
        let beforeTokens = try XCTUnwrap(coldScan?.series.daily.reduce(0) { $0 + $1.totalTokens })
        let appendSlotStart = DispatchTime.now().uptimeNanoseconds
        let appendCPUStart = Self.cpuSeconds()
        let appendedScan = await scannerUnderTest.scan(
            accountIdentityKey: "benchmark-first-account",
            allowsUnscopedEvents: false,
            daysBack: 30,
            now: now,
            pricing: TestPricing.bundled
        )
        let secondAccountAppend = await secondAccountScanner.scan(
            accountIdentityKey: "benchmark-second-account",
            allowsUnscopedEvents: false,
            daysBack: 30,
            now: now,
            pricing: TestPricing.bundled
        )
        await scanner.flushPendingWrites()
        await relaunchedScanner.flushPendingWrites()
        let appendCPU = Self.cpuSeconds() - appendCPUStart
        let appendWall = Double(DispatchTime.now().uptimeNanoseconds - appendSlotStart) / 1_000_000_000
        XCTAssertEqual(appendedScan?.series.daily.reduce(0) { $0 + $1.totalTokens }, beforeTokens)
        let secondAccountBefore = secondAccountBaseline?.series.daily.reduce(0) { $0 + $1.totalTokens } ?? 0
        XCTAssertEqual(
            secondAccountAppend?.series.daily.reduce(0) { $0 + $1.totalTokens },
            secondAccountBefore + appendedTokenCount
        )
        XCTAssertTrue(secondAccountAppend?.unknownModelsByDay.isEmpty == true)
        XCTAssertGreaterThan(secondAccountAppend?.series.daily.compactMap(\.costUSD).reduce(0, +) ?? 0, 0)

        let residentRows = await scanner.residentItemCountForTesting()
        CodexRouterUsageScanner.clearSharedTailCacheForTesting(path: ledger.path)
        return Measurement(
            coldCPUSeconds: coldCPU,
            coldWallSeconds: coldWall,
            coldScanCPUSeconds: coldScanCPU,
            coldScanWallSeconds: coldScanWall,
            coldPersistCPUSeconds: persistCPU,
            coldPersistWallSeconds: persistWall,
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
        cpuSeconds(for: RUSAGE_SELF) + cpuSeconds(for: RUSAGE_CHILDREN)
    }

    private static func cpuSeconds(for process: Int32) -> Double {
        var usage = rusage()
        guard getrusage(process, &usage) == 0 else { return 0 }
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        return user + system
    }

    /// Writes the same fixed number of bytes on every run. Rows resemble successful CodexRouter
    /// events with unique timestamps, real bundled model pricing, and dates safely inside the
    /// 30-day daily-accounting window.
    static func writeSyntheticLedger(to url: URL, endingAt end: Date, rowCount: Int = 8_192, totalBytes: Int = 3_276_800) throws {
        let models: [(name: String, provider: String)] = [
            ("gpt-5.5", "openai"),
            ("gpt-5.4", "openai"),
            ("deepseek-v4-pro", "deepseek"),
            ("claude-sonnet-4-5", "anthropic"),
        ]
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        // Codex's 30-day window includes today and starts at local midnight 29 days ago. Keep the
        // oldest fixture row a full day inside that boundary, regardless of the test time zone.
        let lookbackSeconds = 28 * 24 * 60 * 60
        let timestamps = (0..<rowCount).map { index in
            formatter.string(from: end.addingTimeInterval(
                -Double(lookbackSeconds) * Double(index) / Double(rowCount)
            ))
        }
        let accountFingerprints = [
            CodexProxyUsageScanner.accountFingerprint(for: "benchmark-first-account")!,
            CodexProxyUsageScanner.accountFingerprint(for: "benchmark-second-account")!
        ]

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

        let baseBytes = totalBytes / rowCount
        let extraBytes = totalBytes % rowCount
        var block = Data()
        block.reserveCapacity(1 << 20)
        for index in 0..<rowCount {
            let model = models[index % models.count]
            let accountFingerprint = accountFingerprints[index % accountFingerprints.count]
            let prefix = "{\"at\":\"\(timestamps[index])\",\"model\":\"\(model.name)\",\"provider\":\"\(model.provider)\",\"status\":200,\"inputTokens\":1234,\"cachedInputTokens\":234,\"outputTokens\":567,\"reasoningTokens\":89,\"totalTokens\":1801,\"accountFingerprint\":\"\(accountFingerprint)\",\"serviceTier\":\"default\",\"padding\":\""
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
