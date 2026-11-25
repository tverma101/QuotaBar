import XCTest
@testable import QuotaBar

/// Compares the Rust accounting folds with the Swift reference folds on a synthetic history.
///
/// Opt-in because it builds hundreds of thousands of entries and runs both engines several times:
///
/// ```sh
/// QUOTABAR_RUST_FOLD_BENCH=1 swift test --filter "RustFoldBenchmarkTests"
/// ```
final class RustFoldBenchmarkTests: XCTestCase {
    private let entryCount = 150_000
    private let now = OpenUsageISO8601.date(from: "2026-11-20T12:00:00.000Z")!
    private var since: Date { now.addingTimeInterval(-60 * 86_400) }

    func testClaudeFoldBenchmark() throws {
        guard ProcessInfo.processInfo.environment["QUOTABAR_RUST_FOLD_BENCH"] == "1" else {
            throw XCTSkip("Set QUOTABAR_RUST_FOLD_BENCH=1 to run the fold benchmarks.")
        }
        let entries = claudeCorpus()
        let pricing = claudePricing()
        let boundaries = RustFoldSupport.DayBoundaries.build(since: since, now: now)

        // Warm both engines (pricing memo, dictionary growth, FFI path) before timing.
        let expected = ClaudeLogUsageScanner.aggregate(
            entries: ClaudeLogUsageScanner.dedup(entries), since: since, pricing: pricing
        )
        let warm = try XCTUnwrap(ClaudeRustFold.fold(
            entries: entries, since: since, pricing: pricing, now: now, dayBoundaries: boundaries
        ))
        XCTAssertEqual(warm, expected)

        var rustTimes: [Double] = []
        var inlineTimes: [Double] = []
        var swiftTimes: [Double] = []
        for _ in 0..<3 {
            rustTimes.append(timed {
                XCTAssertNotNil(ClaudeRustFold.fold(
                    entries: entries, since: since, pricing: pricing,
                    now: now, dayBoundaries: boundaries, mode: .backend
                ))
            })
            inlineTimes.append(timed {
                XCTAssertNotNil(ClaudeRustFold.fold(
                    entries: entries, since: since, pricing: pricing,
                    now: now, dayBoundaries: boundaries, mode: .inline
                ))
            })
            swiftTimes.append(timed {
                _ = ClaudeLogUsageScanner.aggregate(
                    entries: ClaudeLogUsageScanner.dedup(entries), since: since, pricing: pricing
                )
            })
        }
        report(
            "CLAUDE_FOLD_BENCH", rustTimes: rustTimes, inlineTimes: inlineTimes,
            swiftTimes: swiftTimes
        )
    }

    func testCodexFoldBenchmark() throws {
        guard ProcessInfo.processInfo.environment["QUOTABAR_RUST_FOLD_BENCH"] == "1" else {
            throw XCTSkip("Set QUOTABAR_RUST_FOLD_BENCH=1 to run the fold benchmarks.")
        }
        let events = codexCorpus()
        let pricing = codexPricing()
        var context = CodexRustFold.FoldContext(since: since, pricing: pricing, now: now)

        let expected = CodexLogUsageScanner.aggregate(events: events, since: since, pricing: pricing)
        let warm = try XCTUnwrap(CodexRustFold.fold(events: events, context: &context))
        XCTAssertEqual(warm, expected)

        var rustTimes: [Double] = []
        var inlineTimes: [Double] = []
        var swiftTimes: [Double] = []
        for _ in 0..<3 {
            rustTimes.append(timed {
                var context = CodexRustFold.FoldContext(
                    since: self.since, pricing: pricing, now: self.now, mode: .backend
                )
                XCTAssertNotNil(CodexRustFold.fold(events: events, context: &context))
            })
            inlineTimes.append(timed {
                var context = CodexRustFold.FoldContext(
                    since: self.since, pricing: pricing, now: self.now, mode: .inline
                )
                XCTAssertNotNil(CodexRustFold.fold(events: events, context: &context))
            })
            swiftTimes.append(timed {
                _ = CodexLogUsageScanner.aggregate(events: events, since: self.since, pricing: pricing)
            })
        }
        report(
            "CODEX_FOLD_BENCH", rustTimes: rustTimes, inlineTimes: inlineTimes,
            swiftTimes: swiftTimes
        )
    }

    /// The one-time cost of publishing a catalogue snapshot to Rust, against the per-refresh rate
    /// table the folds used to build. Measured on the shipped catalogues so the numbers reflect a
    /// real pricing snapshot, not a toy table.
    func testPricingSnapshotBenchmark() throws {
        guard ProcessInfo.processInfo.environment["QUOTABAR_RUST_FOLD_BENCH"] == "1" else {
            throw XCTSkip("Set QUOTABAR_RUST_FOLD_BENCH=1 to run the pricing benchmarks.")
        }
        let pricing = ModelPricing(
            supplement: TestPricing.bundled.supplement,
            primary: TestPricing.bundled.primary,
            secondary: TestPricing.bundled.secondary,
            openRouter: TestPricing.bundled.openRouter
        )
        let models = benchModels(from: pricing)
        // A real scan sees a handful of exact slugs, not 377 catalogue keys. Keep both numbers so
        // the broad sample cannot flatter the result.
        let realistic = [
            "claude-opus-5.5-thinking", "claude-sonnet-5.5", "claude-haiku-4-5",
            "gpt-5.5", "gpt-5.5-fast", "gpt-5.4", "gpt-5.2", "gpt-6.1-sol",
            "gemini-3-pro", "gemini-3-pro-preview-high", "grok-4.7",
            "cursor-grok-4.7-high", "composer-2.5", "auto", "kimi-k3"
        ]
        let realisticModels = realistic.filter { pricing.isPriced($0) }

        let loadTimes = (0..<3).map { _ in
            timed {
                let fresh = ModelPricing(
                    supplement: TestPricing.bundled.supplement,
                    primary: TestPricing.bundled.primary,
                    secondary: TestPricing.bundled.secondary,
                    openRouter: TestPricing.bundled.openRouter
                )
                XCTAssertNotNil(fresh.backendPricingHandle())
            }
        }

        // Cold Swift memo: what a fresh catalogue snapshot paid per scan before the port.
        let swiftCold = (0..<3).map { _ in
            timed {
                let fresh = ModelPricing(
                    supplement: TestPricing.bundled.supplement,
                    primary: TestPricing.bundled.primary,
                    secondary: TestPricing.bundled.secondary,
                    openRouter: TestPricing.bundled.openRouter
                )
                for model in models { _ = fresh.resolve(model: model) }
            }
        }

        let swiftRealisticCold = (0..<3).map { _ in
            timed {
                let fresh = ModelPricing(
                    supplement: TestPricing.bundled.supplement,
                    primary: TestPricing.bundled.primary,
                    secondary: TestPricing.bundled.secondary,
                    openRouter: TestPricing.bundled.openRouter
                )
                for model in realisticModels { _ = fresh.resolve(model: model) }
            }
        }

        // Warm backend snapshot: what each refresh pays now (Rust memo across scans).
        let handle = try XCTUnwrap(pricing.backendPricingHandle())
        var canonicalNames: [String: String] = [:]
        for model in models {
            if let canonical = pricing.canonicalName(for: model) { canonicalNames[model] = canonical }
        }
        _ = try RustBackend.call(op: "pricing.resolve", params: [
            "handle": handle, "models": models, "canonicalNames": canonicalNames
        ])
        var realisticCanonicalNames: [String: String] = [:]
        for model in realisticModels {
            if let canonical = pricing.canonicalName(for: model) {
                realisticCanonicalNames[model] = canonical
            }
        }
        _ = try RustBackend.call(op: "pricing.resolve", params: [
            "handle": handle, "models": realisticModels, "canonicalNames": realisticCanonicalNames
        ])
        let rustRealisticWarm = (0..<3).map { _ in
            timed {
                XCTAssertNotNil(try? RustBackend.call(op: "pricing.resolve", params: [
                    "handle": handle, "models": realisticModels,
                    "canonicalNames": realisticCanonicalNames
                ]))
            }
        }
        let rustWarm = (0..<3).map { _ in
            timed {
                XCTAssertNotNil(try? RustBackend.call(op: "pricing.resolve", params: [
                    "handle": handle, "models": models, "canonicalNames": canonicalNames
                ]))
            }
        }

        func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
        print(
            "PRICING_SNAPSHOT_BENCH models=\(models.count) "
                + "load_ms=\(fmt(loadTimes)) "
                + "swift_cold_resolve_ms=\(fmt(swiftCold)) "
                + "rust_warm_resolve_ms=\(fmt(rustWarm)) "
                + "realistic_models=\(realisticModels.count) "
                + "swift_realistic_cold_ms=\(fmt(swiftRealisticCold)) "
                + "rust_realistic_warm_ms=\(fmt(rustRealisticWarm))"
        )
        XCTAssertLessThan(median(rustWarm), median(swiftCold))
    }

    private func benchModels(from pricing: ModelPricing) -> [String] {
        var names = Set(pricing.supplement.pricing.keys)
        let primaryKeys = pricing.primary.entries.keys.sorted()
        let secondaryKeys = pricing.secondary.entries.keys.sorted()
        names.formUnion(stride(from: 0, to: primaryKeys.count, by: 25).map { primaryKeys[$0] })
        names.formUnion(stride(from: 0, to: secondaryKeys.count, by: 25).map { secondaryKeys[$0] })
        names.formUnion([
            "claude-opus-5.5-thinking", "cursor-grok-4.7-high", "gemini-3-pro-preview-high",
            "openai/gpt-5.5", "xai/grok-4.3", "unknown-benchmark-slug"
        ])
        return names.sorted()
    }

    private func fmt(_ times: [Double]) -> String {
        String(format: "%.1f", times.sorted()[times.count / 2] * 1_000)
    }

    // MARK: - Fixtures

    private func claudePricing() -> ModelPricing {
        let models = (0..<8).map { "claude-bench-\($0)" }
        var entries: [String: ModelRates] = [:]
        for (index, model) in models.enumerated() {
            entries[model] = ModelRates(
                inputPerMillion: 3 + Double(index),
                outputPerMillion: 15 + Double(index) * 2,
                cacheWritePerMillion: 3.75,
                cacheReadPerMillion: 0.3,
                fastMultiplier: 2
            )
        }
        return ModelPricing(
            supplement: PricingSupplement(),
            primary: PricingCatalog(entries: entries),
            secondary: PricingCatalog(entries: [:])
        )
    }

    private func claudeCorpus() -> [ClaudeLogUsageScanner.Entry] {
        (0..<entryCount).map { index in
            let timestamp = since.addingTimeInterval(
                Double(index % 60) * 86_400 + Double(index % 86_400)
            )
            let model = index % 97 == 0
                ? "mystery-\(index)"
                : "claude-bench-\(index % 8)"
            return ClaudeLogUsageScanner.Entry(
                timestamp: timestamp,
                tokens: TokenBreakdown(
                    input: 500 + index % 2_000,
                    cacheWrite5m: index % 3 == 0 ? 1_000 : 0,
                    cacheWrite1h: index % 11 == 0 ? 500 : 0,
                    cacheRead: index % 2 == 0 ? 2_000 : 0,
                    output: 100 + index % 500,
                    isFast: index % 13 == 0
                ),
                messageID: "msg_\(index)",
                requestID: "req_\(index)",
                isSidechain: index % 17 == 0,
                hasSpeed: index % 13 == 0,
                costUSD: index % 5 == 0 ? 0.0001 * Double(index % 1_000) : nil,
                model: model
            )
        }
    }

    private func codexPricing() -> ModelPricing {
        ModelPricing(
            supplement: PricingSupplement(),
            primary: PricingCatalog(entries: [
                "gpt-5.5": ModelRates(
                    inputPerMillion: 10, outputPerMillion: 45,
                    cacheWritePerMillion: 10, cacheReadPerMillion: 1
                ),
                "gpt-5.4": ModelRates(
                    inputPerMillion: 2.5, outputPerMillion: 15,
                    cacheWritePerMillion: 2.5, cacheReadPerMillion: 0.25
                ),
                "gpt-6.1-sol": ModelRates(
                    inputPerMillion: 5, outputPerMillion: 20,
                    cacheWritePerMillion: 5, cacheReadPerMillion: 0.5
                ),
                "gpt-5.2": ModelRates(
                    inputPerMillion: 1.25, outputPerMillion: 10,
                    cacheWritePerMillion: 1.25, cacheReadPerMillion: 0.125
                )
            ]),
            secondary: PricingCatalog(entries: [:])
        )
    }

    private func codexCorpus() -> [CodexLogUsageScanner.Event] {
        let models = ["gpt-5.5", "gpt-5.4", "gpt-6.1-sol", "gpt-5.2"]
        return (0..<entryCount).map { index in
            let timestamp = since.addingTimeInterval(
                Double(index % 60) * 86_400 + Double(index % 86_400)
            )
            let cached = index % 2 == 0 ? 1_000 : 0
            let input = 2_000 + index % 4_000
            let output = 200 + index % 800
            return CodexLogUsageScanner.Event(
                timestamp: timestamp,
                model: models[index % models.count],
                input: input,
                cached: cached,
                output: output,
                reasoning: 0,
                total: input + output,
                hasCompleteCostBreakdown: index % 23 != 0,
                isFast: index % 7 == 0,
                serviceTier: index % 29 == 0 ? "priority" : nil
            )
        }
    }

    // MARK: - Measurement

    private func timed(_ work: () -> Void) -> Double {
        let clock = ContinuousClock()
        let elapsed = clock.measure(work)
        return Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
    }

    private func report(
        _ label: String,
        rustTimes: [Double],
        inlineTimes: [Double],
        swiftTimes: [Double]
    ) {
        let rustMedian = rustTimes.sorted()[rustTimes.count / 2]
        let inlineMedian = inlineTimes.sorted()[inlineTimes.count / 2]
        let swiftMedian = swiftTimes.sorted()[swiftTimes.count / 2]
        print(
            "\(label) entries=\(entryCount) "
                + "backend_ms=\(String(format: "%.1f", rustMedian * 1_000)) "
                + "inline_ms=\(String(format: "%.1f", inlineMedian * 1_000)) "
                + "swift_ms=\(String(format: "%.1f", swiftMedian * 1_000)) "
                + "pricing_speedup=\(String(format: "%.2f", inlineMedian / rustMedian))x "
                + "backend_runs=\(rustTimes.map { String(format: "%.1f", $0 * 1_000) }) "
                + "inline_runs=\(inlineTimes.map { String(format: "%.1f", $0 * 1_000) }) "
                + "swift_runs=\(swiftTimes.map { String(format: "%.1f", $0 * 1_000) })"
        )
    }
}
