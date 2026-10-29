import Foundation
import XCTest
@testable import QuotaBar

/// Exercises the default production scanner, rather than the injected incremental test scanner.
final class CodexRouterProductionCacheTests: XCTestCase {
    /// Explicit local audit only: reads the owner's ledger, emits aggregate diagnostics without rows
    /// or account IDs, and never changes provider state or credentials.
    func testOptInLocalLedgerParserAudit() async throws {
        guard ProcessInfo.processInfo.environment["QUOTABAR_LOCAL_LEDGER_AUDIT"] == "1" else {
            throw XCTSkip("Enable QUOTABAR_LOCAL_LEDGER_AUDIT for a local read-only parser audit")
        }
        let diagnosticDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("QuotaBarLedgerAudit")
        let previousSink = AppLog.sink
        AppLog.sink = LogFile(directory: diagnosticDirectory, fileName: "audit.log")
        AppLog.sink.open()
        defer { AppLog.sink = previousSink }
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/codex-router/usage-events.jsonl")
        var counts: [String: Int] = [:]
        var firstLine: [String: Int] = [:]
        var lineNumber = 0
        var cache = CodexRouterEventLineParser.TimestampCache()
        func note(_ reason: String) {
            counts[reason, default: 0] += 1
            if firstLine[reason] == nil { firstLine[reason] = lineNumber }
        }
        let read = JSONLFileReader.readLines(at: url, chunkSize: 256 * 1024) { line in
            lineNumber += 1
            switch CodexRouterEventLineParser.parseResult(line, timestampCache: &cache) {
            case .irrelevant: note("irrelevant")
            case .malformed: note("malformed-json-or-timestamp")
            case .event(let event), .malformedEvent(let event):
                note("events")
                if event.isMalformedRouterEvent { note("any-malformed-status-\(event.status)") }
                guard (200..<300).contains(event.status) else { return }
                if !event.hasValidStatusField { note("invalid-status") }
                if !event.hasValidTimestampField { note("invalid-timestamp") }
                if !event.hasValidModelField { note("invalid-model") }
                if !event.hasValidAccountIdentityFields { note("invalid-account") }
                if !event.hasValidNumericCountFields { note("invalid-numeric-fields") }
                if !event.hasUniqueRecognizedFields { note("duplicate-recognized-fields") }
                if event.hasValidProviderField == false { note("invalid-provider") }
                if event.measuredTokenTotal == nil {
                    note("missing-measured-total")
                    if !CodexRouterUsageScanner.isOpenCodeServed(event) && !event.hasNoMeasuredUsageFields {
                        note("incomplete-components-\(event.hasInputTokensField)-\(event.hasOutputTokensField)-\(event.totalTokens == nil)-\(event.cachedInputTokens == 0)-\(event.reasoningTokens == 0)")
                    }
                }
            }
        }
        print("LOCAL_LEDGER_AUDIT lines=\(lineNumber) bytes=\(read.statistics.bytesRead) complete=\(read.isComplete) counts=\(counts) firstLines=\(firstLine)")
        XCTAssertTrue(read.isComplete)
        let scanner = CodexRouterUsageScanner(ledgerPaths: { [url.path] }, identityAliases: { [:] })
        let result = await scanner.scan(accountIdentityKey: nil, allowsUnscopedEvents: true,
                                        daysBack: 30, now: Date(), pricing: .empty)
        print("LOCAL_LEDGER_PRODUCTION_SCAN complete=\(result != nil) days=\(result?.series.daily.count ?? 0)")
        print(try String(contentsOf: diagnosticDirectory.appendingPathComponent("audit.log"), encoding: .utf8))

    }

    private final class AppendOnFinalDiscovery: @unchecked Sendable {
        let ledger: URL
        let extra: Data
        let rewrites: Bool
        private let lock = NSLock()
        private var calls = 0
        init(ledger: URL, extra: Data, rewrites: Bool = false) {
            self.ledger = ledger; self.extra = extra; self.rewrites = rewrites
        }
        func apply() {
            lock.lock()
            defer { lock.unlock() }
            calls += 1
            if calls == 1 {
                let handle = try! FileHandle(forWritingTo: ledger)
                if !rewrites { try! handle.seekToEnd() }
                try! handle.write(contentsOf: extra)
                try! handle.close()
            }
        }
    }

    func testSameSizeRewriteDuringFinalValidationDoesNotPublishMixedHistory() async throws {
        try await withLedger { ledger in
            try line(tokens: 100).write(to: ledger, atomically: true, encoding: .utf8)
            let source = AppendOnFinalDiscovery(ledger: ledger, extra: Data(line(tokens: 999).utf8), rewrites: true)
            let scanner = CodexRouterUsageScanner(ledgerPaths: { [ledger.path] }, identityAliases: { [:] },
                                                  beforeAggregateValidationForTesting: source.apply)
            let first = await scanner.scan(accountIdentityKey: nil, allowsUnscopedEvents: true,
                                           daysBack: 30, now: now, pricing: pricing())
            XCTAssertNil(first)
            let second = await scan(ledger)
            XCTAssertEqual(second?.series.daily.first?.totalTokens, 999)
        }
    }

    func testAppendDuringFinalValidationKeepsCompletedPrefixAndReadsTailNext() async throws {
        try await withLedger { ledger in
            try line(tokens: 100).write(to: ledger, atomically: true, encoding: .utf8)
            let extra = Data(line(tokens: 50, hour: 11).utf8)
            let source = AppendOnFinalDiscovery(ledger: ledger, extra: extra)
            let scanner = CodexRouterUsageScanner(ledgerPaths: { [ledger.path] }, identityAliases: { [:] },
                                                  beforeAggregateValidationForTesting: source.apply)
            let prices = pricing()
            let first = await scanner.scan(accountIdentityKey: nil, allowsUnscopedEvents: true,
                                           daysBack: 30, now: now, pricing: prices)
            XCTAssertEqual(first?.series.daily.first?.totalTokens, 100,
                           "a valid completed prefix must survive a concurrent append")
            let initial = try XCTUnwrap(CodexRouterUsageScanner.incrementalReadStatisticsForTesting(path: ledger.path))
            let second = await scan(ledger, pricing: prices)
            XCTAssertEqual(second?.series.daily.first?.totalTokens, 150)
            let final = try XCTUnwrap(CodexRouterUsageScanner.incrementalReadStatisticsForTesting(path: ledger.path))
            XCTAssertEqual(final.fullParses, initial.fullParses)
            XCTAssertEqual(final.bytesRead - initial.bytesRead, extra.count)
        }
    }

    private let now = TestLocalInstant.date(2026, 10, 4, 12)

    func testRequestsWithoutMeasurementsKeepKnownTokensAndPersistPartialDays() async throws {
        try await withLedger { ledger in
            let missing = "{\"at\":\"\(TestLocalInstant.iso(2026, 10, 4, 10))\",\"model\":\"test-model\",\"provider\":\"openai\",\"status\":200}\n"
            try (line(tokens: 100) + missing).write(to: ledger, atomically: true, encoding: .utf8)
            let first = await scan(ledger)
            XCTAssertEqual(first?.series.daily.first?.totalTokens, 100)
            XCTAssertEqual(first?.unmeasuredUsageDays, ["2026-10-04"])
            let initial = try XCTUnwrap(CodexRouterUsageScanner.incrementalReadStatisticsForTesting(path: ledger.path))
            CodexRouterAggregateIndex.shared.unloadMemoryForTesting(path: ledger.path)
            let warm = await scan(ledger)
            XCTAssertEqual(warm?.unmeasuredUsageDays, ["2026-10-04"])
            let reused = try XCTUnwrap(CodexRouterUsageScanner.incrementalReadStatisticsForTesting(path: ledger.path))
            XCTAssertEqual(reused.bytesRead, initial.bytesRead)
            let handle = try FileHandle(forWritingTo: ledger)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line(tokens: 50, hour: 11).utf8))
            try handle.close()
            let appended = await scan(ledger)
            XCTAssertEqual(appended?.series.daily.first?.totalTokens, 150)
            XCTAssertEqual(appended?.unmeasuredUsageDays, ["2026-10-04"])
        }
    }

    func testHalfSpecifiedUsageStillRejectsIncompleteMeasurement() async throws {
        try await withLedger { ledger in
            let damaged = "{\"at\":\"\(TestLocalInstant.iso(2026, 10, 4, 10))\",\"model\":\"test-model\",\"provider\":\"openai\",\"status\":200,\"inputTokens\":100}\n"
            try (line(tokens: 100) + damaged).write(to: ledger, atomically: true, encoding: .utf8)
            let result = await scan(ledger)
            XCTAssertNil(result)
        }
    }

    func testCancelledTransportStatusZeroDoesNotInvalidateOrInflateMeasuredHistory() async throws {
        try await withLedger { ledger in
            let cancelled = line(tokens: 999).replacingOccurrences(of: "\"status\":200", with: "\"status\":0")
            try (line(tokens: 100) + cancelled).write(to: ledger, atomically: true, encoding: .utf8)
            let first = await scan(ledger)
            XCTAssertEqual(first?.series.daily.first?.totalTokens, 100)
            let initial = try XCTUnwrap(CodexRouterUsageScanner.incrementalReadStatisticsForTesting(path: ledger.path))
            let warm = await scan(ledger)
            XCTAssertEqual(warm?.series.daily.first?.totalTokens, 100)
            let final = try XCTUnwrap(CodexRouterUsageScanner.incrementalReadStatisticsForTesting(path: ledger.path))
            XCTAssertEqual(initial.bytesRead, final.bytesRead)
        }
    }

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

    private func line(tokens: Int, hour: Int = 10, model: String = "test-model") -> String {
        "{\"at\":\"\(TestLocalInstant.iso(2026, 10, 4, hour))\",\"model\":\"\(model)\",\"provider\":\"openai\",\"status\":200,\"inputTokens\":\(tokens),\"outputTokens\":0,\"totalTokens\":\(tokens)}\n"
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

    func testProductionFoldCountsUnpricedTokensAndBuildsAPIEstimates() async throws {
        try await withLedger { ledger in
            try (line(tokens: 100) + line(tokens: 100, hour: 11, model: "future-model"))
                .write(to: ledger, atomically: true, encoding: .utf8)

            let scanned = await scan(ledger)
            let scan = try XCTUnwrap(scanned)
            XCTAssertEqual(scan.series.daily.first?.totalTokens, 200)
            XCTAssertEqual(try XCTUnwrap(scan.series.daily.first?.costUSD), 0.0001, accuracy: 1e-10)
            XCTAssertEqual(scan.unknownModelsByDay["2026-10-04"], ["future-model"])
            XCTAssertEqual(scan.modelUsage?.daily.first?.models.first(where: { $0.model == "future-model" })?.totalTokens, 100)
            XCTAssertNil(scan.modelUsage?.daily.first?.models.first(where: { $0.model == "future-model" })?.costUSD)
            XCTAssertEqual(try XCTUnwrap(scan.apiEstimateByDay?["2026-10-04"]), 0.0001, accuracy: 1e-10)
        }
    }

    func testProductionFoldMarksIncompleteRouterCostCoverage() async throws {
        try await withLedger { ledger in
            let estimatedInput = #"{"at":"\#(TestLocalInstant.iso(2026, 10, 4, 10))","model":"test-model","provider":"openai","status":200,"inputTokens":0,"cachedInputTokens":0,"outputTokens":25,"totalTokens":25,"estimatedInputTokens":1000000000000001}"# + "\n"
            let mismatchedTotal = #"{"at":"\#(TestLocalInstant.iso(2026, 10, 4, 11))","model":"test-model","provider":"openai","status":200,"inputTokens":100,"cachedInputTokens":25,"outputTokens":50,"totalTokens":160}"# + "\n"
            try (estimatedInput + mismatchedTotal).write(to: ledger, atomically: true, encoding: .utf8)

            let maybeScan = await self.scan(ledger)
            let scan = try XCTUnwrap(maybeScan)
            let day = try XCTUnwrap(scan.series.daily.first)

            XCTAssertEqual(day.totalTokens, 185)
            XCTAssertFalse(day.tokenCountSaturated,
                           "an overflowing estimate must not saturate the measured production aggregate")
            XCTAssertFalse(day.costIsComplete)
            XCTAssertNil(scan.apiEstimateByDay?[day.date])
            XCTAssertTrue(scan.apiEstimateIncompleteDays?.contains(day.date) == true)
            XCTAssertEqual(scan.modelUsage?.daily.first?.models.first?.costUSD ?? -1,
                           0.000175, accuracy: 1e-10,
                           "keep the known subtotal while flagging the incomplete router breakdown")

            CodexRouterAggregateIndex.shared.unloadMemoryForTesting(path: ledger.path)
            let maybeRestoredScan = await self.scan(ledger)
            let restoredScan = try XCTUnwrap(maybeRestoredScan)
            let restoredDay = try XCTUnwrap(restoredScan.series.daily.first)
            XCTAssertEqual(restoredDay.totalTokens, 185)
            XCTAssertFalse(restoredDay.tokenCountSaturated,
                           "persisted aggregate metadata separates measured counts from estimates")
            XCTAssertFalse(restoredDay.costIsComplete)
            XCTAssertTrue(restoredScan.apiEstimateIncompleteDays?.contains(restoredDay.date) == true)
        }
    }

    func testResidentAggregateBoundStillAllowsEvictedRecordsToReloadFromDisk() async throws {
        try await withLedger { ledger in
            try line(tokens: 100).write(to: ledger, atomically: true, encoding: .utf8)
            let scanner = CodexRouterUsageScanner(ledgerPaths: { [ledger.path] }, identityAliases: { [:] })
            for account in 0..<40 {
                let result = await scanner.scan(accountIdentityKey: "synthetic-account-\(account)",
                    allowsUnscopedEvents: true, daysBack: 30, now: now, pricing: pricing())
                XCTAssertEqual(result?.series.daily.first?.totalTokens, 100)
            }
            XCTAssertLessThanOrEqual(CodexRouterAggregateIndex.shared.residentRecordCountForTesting,
                                     CodexRouterAggregateIndex.maxResidentRecords)
            let before = try XCTUnwrap(CodexRouterUsageScanner.incrementalReadStatisticsForTesting(path: ledger.path))
            CodexRouterAggregateIndex.shared.unloadMemoryForTesting(path: ledger.path)
            let restored = await scanner.scan(accountIdentityKey: "synthetic-account-0",
                allowsUnscopedEvents: true, daysBack: 30, now: now, pricing: pricing())
            XCTAssertEqual(restored?.series.daily.first?.totalTokens, 100)
            let after = try XCTUnwrap(CodexRouterUsageScanner.incrementalReadStatisticsForTesting(path: ledger.path))
            XCTAssertEqual(after.bytesRead, before.bytesRead)
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
            XCTAssertTrue(cold?.series.daily.first?.tokenCountSaturated == true,
                          "clamped source counts are lower bounds")
            let warm = await scan(ledger)
            XCTAssertEqual(warm?.series.daily.first?.totalTokens, 2_000_000_000_000_000)
            XCTAssertTrue(warm?.series.daily.first?.tokenCountSaturated == true,
                          "the persisted aggregate keeps the lower-bound marker")
            let handle = try FileHandle(forWritingTo: ledger)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line(tokens: 1, hour: 11).utf8))
            try handle.close()
            let append = await scan(ledger)
            XCTAssertEqual(append?.series.daily.first?.totalTokens, 2_000_000_000_000_001)
            XCTAssertTrue(append?.series.daily.first?.tokenCountSaturated == true)
        }
    }

    func testSaturatedUnknownModelStaysCountedAndMarkedAcrossAggregateCache() async throws {
        try await withLedger { ledger in
            try (line(tokens: .max, model: "test-model")
                 + line(tokens: .max, hour: 11, model: "unknown-model"))
                .write(to: ledger, atomically: true, encoding: .utf8)

            for _ in 0..<2 {
                let maybeScan = await self.scan(ledger)
                let scan = try XCTUnwrap(maybeScan)
                let day = try XCTUnwrap(scan.series.daily.first)
                XCTAssertEqual(day.totalTokens, 2_000_000_000_000_000)
                XCTAssertTrue(day.tokenCountSaturated)
                XCTAssertEqual(scan.unknownModelsByDay[day.date], ["unknown-model"])
                let models = try XCTUnwrap(scan.modelUsage?.daily.first?.models)
                XCTAssertTrue(models.first(where: { $0.model == "test-model" })?.tokenCountSaturated == true)
                XCTAssertTrue(models.first(where: { $0.model == "unknown-model" })?.tokenCountSaturated == true)
                XCTAssertNil(models.first(where: { $0.model == "unknown-model" })?.costUSD)
            }
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
