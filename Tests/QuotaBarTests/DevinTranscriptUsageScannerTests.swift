import Foundation
import XCTest
@testable import QuotaBar

final class DevinTranscriptUsageScannerTests: XCTestCase {
    func testFoldsMeteredStepsIntoDailyTokensAndSeparatesCacheReads() async throws {
        let home = try DevinTranscriptFixture.makeTranscripts(files: [
            "calm-ocean.json": DevinTranscriptFixture.transcript(steps: [
                .metered(timestamp: TestLocalInstant.iso(2026, 6, 10, 10), prompt: 10_000, completion: 500, cached: 8_000),
                .metered(timestamp: TestLocalInstant.iso(2026, 6, 10, 11), prompt: 5_000, completion: 250, cached: 0)
            ])
        ])
        defer { try? FileManager.default.removeItem(at: home) }

        let scanResult = await scan(home: home, now: TestLocalInstant.date(2026, 6, 18, 12))
        let usage = try XCTUnwrap(scanResult)
        let day = try XCTUnwrap(usage.series.daily.first)

        XCTAssertEqual(day.date, TestLocalInstant.isoDay(2026, 6, 10))
        XCTAssertEqual(day.totalTokens, 15_750, "10k + 5k prompt (cached already inside prompt) + 750 completion")
    }

    func testCachedTokensLandInTheCacheReadBucketNotPlainInput() throws {
        let entry = try XCTUnwrap(DevinTranscriptFixture.parseFirstEntry(
            timestamp: TestLocalInstant.iso(2026, 6, 10, 10),
            prompt: 15_836,
            completion: 1_813,
            cached: 11_776
        ))

        XCTAssertEqual(entry.tokens.input, 4_060, "cached prompt tokens are a subset of prompt_tokens")
        XCTAssertEqual(entry.tokens.cacheRead, 11_776)
        XCTAssertEqual(entry.tokens.output, 1_813)
    }

    func testUnpricedSweModelKeepsTokensWithoutAWarningOrCost() async throws {
        let home = try DevinTranscriptFixture.makeTranscripts(files: [
            "calm-ocean.json": DevinTranscriptFixture.transcript(steps: [
                .metered(timestamp: TestLocalInstant.iso(2026, 6, 10, 10), model: "swe-2-max", prompt: 500_000, completion: 10_000)
            ])
        ])
        defer { try? FileManager.default.removeItem(at: home) }

        let scanResult = await scan(home: home, now: TestLocalInstant.date(2026, 6, 18, 12))
        let usage = try XCTUnwrap(scanResult)
        let day = try XCTUnwrap(usage.series.daily.first)

        // Historical usage predating the documented SWE-2 rates still counts as measured tokens.
        XCTAssertEqual(day.totalTokens, 510_000)
        XCTAssertNil(day.costUSD)
        XCTAssertTrue(usage.unknownModelsByDay.isEmpty)
        XCTAssertEqual(usage.apiEstimateIncompleteDays, [TestLocalInstant.isoDay(2026, 6, 10)])
        XCTAssertEqual(
            usage.modelUsage?.daily.first?.models.map(\.model),
            ["swe-2"],
            "the breakdown groups reasoning settings under the base model"
        )
    }

    func testFinalMetricsAreNotCountedOnTopOfStepMetrics() async throws {
        // The export's `final_metrics` duplicates the summed step metrics. Folding steps only must
        // not double-count the session.
        let home = try DevinTranscriptFixture.makeTranscripts(files: [
            "calm-ocean.json": DevinTranscriptFixture.transcript(steps: [
                .metered(timestamp: TestLocalInstant.iso(2026, 6, 10, 10), prompt: 6_000, completion: 400, cached: 5_000)
            ], finalPrompt: 6_000, finalCompletion: 400, finalCached: 5_000)
        ])
        defer { try? FileManager.default.removeItem(at: home) }

        let scanResult = await scan(home: home, now: TestLocalInstant.date(2026, 6, 18, 12))
        let usage = try XCTUnwrap(scanResult)

        XCTAssertEqual(try XCTUnwrap(usage.series.daily.first).totalTokens, 6_400)
    }

    func testUnmeteredStepsAndStepsWithoutTokenKeysAreSkipped() async throws {
        let home = try DevinTranscriptFixture.makeTranscripts(files: [
            "calm-ocean.json": DevinTranscriptFixture.transcript(steps: [
                .unmetered(timestamp: TestLocalInstant.iso(2026, 6, 10, 9)),
                .metricsOnly(timestamp: TestLocalInstant.iso(2026, 6, 10, 10), metrics: ["llm_latency_ms": 3_200]),
                .metered(timestamp: TestLocalInstant.iso(2026, 6, 10, 11), prompt: 1_000, completion: 100)
            ])
        ])
        defer { try? FileManager.default.removeItem(at: home) }

        let scanResult = await scan(home: home, now: TestLocalInstant.date(2026, 6, 18, 12))
        let usage = try XCTUnwrap(scanResult)

        XCTAssertEqual(try XCTUnwrap(usage.series.daily.first).totalTokens, 1_100)
    }

    func testStepWithoutModelFallsBackToTheSessionAgentName() throws {
        let entry = try XCTUnwrap(DevinTranscriptFixture.parseFirstEntry(
            timestamp: TestLocalInstant.iso(2026, 6, 10, 10),
            stepModel: nil,
            agentModel: "SWE-2 Max",
            prompt: 100
        ))

        XCTAssertEqual(entry.model, "SWE-2 Max")
    }

    func testMalformedCountsDamageTheWholeFileSoTheFoldKeepsLastGood() async throws {
        let home = try DevinTranscriptFixture.makeTranscripts(files: [
            "damaged.json": DevinTranscriptFixture.transcript(steps: [
                .metered(timestamp: TestLocalInstant.iso(2026, 6, 10, 10), prompt: 1_000, completion: 100),
                .metricsOnly(timestamp: TestLocalInstant.iso(2026, 6, 10, 11), metrics: ["prompt_tokens": -5])
            ]),
            "healthy.json": DevinTranscriptFixture.transcript(steps: [
                .metered(timestamp: TestLocalInstant.iso(2026, 6, 10, 12), prompt: 2_000, completion: 200)
            ])
        ])
        defer { try? FileManager.default.removeItem(at: home) }

        // One damaged transcript must not publish a partial fold of the healthy ones.
        let usage = await scan(home: home, now: TestLocalInstant.date(2026, 6, 18, 12))
        XCTAssertNil(usage)
    }

    func testMoreCacheThanPromptIsDamagedNotMerelyOdd() async throws {
        let home = try DevinTranscriptFixture.makeTranscripts(files: [
            "impossible.json": DevinTranscriptFixture.transcript(steps: [
                .metricsOnly(
                    timestamp: TestLocalInstant.iso(2026, 6, 10, 10),
                    metrics: ["prompt_tokens": 100, "cached_tokens": 200]
                )
            ])
        ])
        defer { try? FileManager.default.removeItem(at: home) }

        let usage = await scan(home: home, now: TestLocalInstant.date(2026, 6, 18, 12))
        XCTAssertNil(usage)
    }

    func testMeteredStepWithoutATimestampDamagesTheFile() async throws {
        let home = try DevinTranscriptFixture.makeTranscripts(files: [
            "untimed.json": DevinTranscriptFixture.transcript(steps: [
                .metricsOnly(timestamp: nil, metrics: ["prompt_tokens": 100, "completion_tokens": 10])
            ])
        ])
        defer { try? FileManager.default.removeItem(at: home) }

        let usage = await scan(home: home, now: TestLocalInstant.date(2026, 6, 18, 12))
        XCTAssertNil(usage)
    }

    func testMissingDirectoryIsANilScanNotACrash() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("openusage-devin-transcripts-\(UUID().uuidString)", isDirectory: true)

        let usage = await DevinTranscriptUsageScanner(
            transcriptsDirectory: missing,
            incrementalScanner: IncrementalJSONLScanner<DevinTranscriptUsageScanner.Entry>()
        ).scan(daysBack: 30, now: TestLocalInstant.date(2026, 6, 18, 12), pricing: TestPricing.bundled)

        XCTAssertNil(usage)
    }

    func testNonTranscriptJSONInTheDirectoryIsDamaged() async throws {
        let home = try DevinTranscriptFixture.makeTranscripts(files: [
            "settings.json": #"{"theme":"dark"}"#,
            "healthy.json": DevinTranscriptFixture.transcript(steps: [
                .metered(timestamp: TestLocalInstant.iso(2026, 6, 10, 10), prompt: 1_000)
            ])
        ])
        defer { try? FileManager.default.removeItem(at: home) }

        // A foreign JSON document must not silently drop: the fold defers to last-good.
        let usage = await scan(home: home, now: TestLocalInstant.date(2026, 6, 18, 12))
        XCTAssertNil(usage)
    }

    func testAggregatesAcrossFilesAndDays() async throws {
        let home = try DevinTranscriptFixture.makeTranscripts(files: [
            "today.json": DevinTranscriptFixture.transcript(steps: [
                .metered(timestamp: TestLocalInstant.iso(2026, 6, 18, 9), prompt: 3_000, completion: 300)
            ]),
            "yesterday.json": DevinTranscriptFixture.transcript(steps: [
                .metered(timestamp: TestLocalInstant.iso(2026, 6, 17, 9), prompt: 1_000, completion: 100),
                .metered(timestamp: TestLocalInstant.iso(2026, 6, 17, 15), model: "swe-1.5", prompt: 2_000, completion: 200)
            ])
        ])
        defer { try? FileManager.default.removeItem(at: home) }

        let scanResult = await scan(home: home, now: TestLocalInstant.date(2026, 6, 18, 12))
        let usage = try XCTUnwrap(scanResult)

        XCTAssertEqual(usage.series.daily.map(\.date), [TestLocalInstant.isoDay(2026, 6, 18), TestLocalInstant.isoDay(2026, 6, 17)])
        XCTAssertEqual(usage.series.daily.map(\.totalTokens), [3_300, 3_300])
        XCTAssertEqual(
            Set(usage.modelUsage?.daily.first { $0.date == TestLocalInstant.isoDay(2026, 6, 17) }?.models.map(\.model) ?? []),
            ["swe-2", "swe-1-5"]
        )
    }

    func testEventsOlderThanTheWindowAreDropped() async throws {
        let home = try DevinTranscriptFixture.makeTranscripts(files: [
            "old.json": DevinTranscriptFixture.transcript(steps: [
                .metered(timestamp: TestLocalInstant.iso(2026, 5, 1, 10), prompt: 9_000)
            ]),
            "recent.json": DevinTranscriptFixture.transcript(steps: [
                .metered(timestamp: TestLocalInstant.iso(2026, 6, 17, 10), prompt: 1_000)
            ])
        ])
        defer { try? FileManager.default.removeItem(at: home) }

        let scanResult = await scan(home: home, now: TestLocalInstant.date(2026, 6, 18, 12), daysBack: 30)
        let usage = try XCTUnwrap(scanResult)

        XCTAssertEqual(usage.series.daily.map(\.totalTokens), [1_000])
    }

    func testSessionDatabaseCountsMeteredCallsOnceWithoutAnyExport() async throws {
        let home = try DevinTranscriptFixture.makeTranscripts(files: [
            // A same-day export that must not be added on top of the database rows.
            "exported.json": DevinTranscriptFixture.transcript(steps: [
                .metered(timestamp: TestLocalInstant.iso(2026, 6, 10, 12), prompt: 10_000)
            ])
        ])
        defer { try? FileManager.default.removeItem(at: home) }
        let timestamp = TestLocalInstant.date(2026, 6, 10, 10)
        let firstCallMetrics: [String: Any] = [
            "input_tokens": 10,
            "output_tokens": 5,
            "cache_read_tokens": 20,
            "cache_creation_tokens": 30
        ]
        try DevinSessionDatabaseFixture.create(
            at: home.appendingPathComponent("sessions.db"),
            rows: [
                // The CLI rewrites the assistant row while a response streams; both copies carry
                // the same request_id and must fold into one call.
                DevinSessionDatabaseFixture.assistantRow(requestID: "req-first", timestamp: timestamp, metrics: firstCallMetrics),
                DevinSessionDatabaseFixture.assistantRow(requestID: "req-first", timestamp: timestamp, metrics: firstCallMetrics),
                DevinSessionDatabaseFixture.assistantRow(
                    requestID: "req-second",
                    timestamp: timestamp,
                    metrics: ["input_tokens": NSNull(), "output_tokens": 7]
                ),
                DevinSessionDatabaseFixture.userRow(
                    requestID: "req-user",
                    timestamp: timestamp,
                    metrics: ["input_tokens": 999, "output_tokens": 999]
                )
            ]
        )

        let scanner = DevinTranscriptUsageScanner(
            transcriptsDirectory: home.appendingPathComponent("transcripts", isDirectory: true),
            incrementalScanner: IncrementalJSONLScanner<DevinTranscriptUsageScanner.Entry>()
        )
        let scanResult = await scanner.scan(
            daysBack: 30,
            now: TestLocalInstant.date(2026, 6, 18, 12),
            pricing: TestPricing.bundled
        )
        let usage = try XCTUnwrap(scanResult)
        let day = try XCTUnwrap(usage.series.daily.first)

        // req-first folds once: 10 input + 20 cache read + 30 cache write + 5 output = 65 tokens,
        // plus req-second's 7 output-only tokens. The user row and the 10k-token export are not
        // counted — the sources are never added together.
        XCTAssertEqual(day.date, TestLocalInstant.isoDay(2026, 6, 10))
        XCTAssertEqual(day.totalTokens, 72)
        XCTAssertNil(day.costUSD)
        XCTAssertEqual(
            usage.modelUsage?.daily.first?.models.map(\.model),
            ["swe-2"],
            "the model keeps its name in the per-model breakdown"
        )

        // A distinct call appended to the same database must be picked up on the next scan.
        var appended = DevinSessionDatabaseFixture.assistantRow(
            requestID: "req-third",
            timestamp: timestamp,
            metrics: ["input_tokens": NSNull(), "output_tokens": 8]
        )
        // Real assistant rows carry content; the payload also guarantees the database file grows,
        // so the reader's file-stamp revision deterministically differs without sleeping.
        appended.message["content"] = [
            ["type": "text", "text": String(repeating: "x", count: 8_192)]
        ]
        try DevinSessionDatabaseFixture.append(
            at: home.appendingPathComponent("sessions.db"),
            rows: [appended]
        )

        let rescanned = await scanner.scan(
            daysBack: 30,
            now: TestLocalInstant.date(2026, 6, 18, 12),
            pricing: TestPricing.bundled
        )
        let rescanUsage = try XCTUnwrap(rescanned)
        XCTAssertEqual(try XCTUnwrap(rescanUsage.series.daily.first).totalTokens, 80)
    }

    func testSessionDatabaseFutureTimestampKeepsLastGoodInsteadOfPublishing() async throws {
        let home = try DevinTranscriptFixture.makeTranscripts(files: [:])
        defer { try? FileManager.default.removeItem(at: home) }
        try DevinSessionDatabaseFixture.create(
            at: home.appendingPathComponent("sessions.db"),
            rows: [
                DevinSessionDatabaseFixture.assistantRow(
                    requestID: "req-future",
                    timestamp: TestLocalInstant.date(2026, 6, 19, 10),
                    metrics: ["output_tokens": 7]
                )
            ]
        )

        let usage = await DevinTranscriptUsageScanner(
            transcriptsDirectory: home.appendingPathComponent("transcripts", isDirectory: true),
            incrementalScanner: IncrementalJSONLScanner<DevinTranscriptUsageScanner.Entry>()
        ).scan(daysBack: 30, now: TestLocalInstant.date(2026, 6, 18, 12), pricing: TestPricing.bundled)

        XCTAssertNil(usage)
    }

    func testNeonEffortSlugUsesExactPublicRouteAndIsNotReportedCost() throws {
        let rates = try PricingCatalogCodecs.catalogFromOpenRouter(Data(
            #"{"data":[{"id":"google/gemini-4-neon","pricing":{"prompt":"0.000003","completion":"0.000015","input_cache_read":"0.00000015"}}],"total_count":1,"links":{"next":null}}"#.utf8
        ))
        let pricing = ModelPricing(
            supplement: PricingSupplement(),
            primary: PricingCatalog(),
            secondary: PricingCatalog(),
            openRouter: rates
        )
        let now = TestLocalInstant.date(2026, 11, 21, 12)
        let entry = DevinTranscriptUsageScanner.Entry(
            timestamp: now,
            model: "gemini-4-neon-xhigh",
            tokens: TokenBreakdown(input: 1_000_000, cacheRead: 1_000_000, output: 1_000_000)
        )
        let scan = DevinTranscriptUsageScanner.aggregate(entries: [entry], since: .distantPast, pricing: pricing)
        let day = try XCTUnwrap(scan.series.daily.first)
        XCTAssertEqual(try XCTUnwrap(scan.apiEstimateByDay?[day.date]), 18.15, accuracy: 0.000001)
        XCTAssertEqual(day.totalTokens, 3_000_000)
        XCTAssertTrue(scan.estimatedCostDays?.contains(day.date) == true)

        let missingRoute = DevinTranscriptUsageScanner.aggregate(entries: [entry], since: .distantPast, pricing: .empty)
        XCTAssertNil(missingRoute.apiEstimateByDay)
        XCTAssertEqual(missingRoute.series.daily.first?.totalTokens, 3_000_000)
    }

    private func scan(home: URL, now: Date, daysBack: Int = 30) async -> LogUsageScan? {
        await DevinTranscriptUsageScanner(
            transcriptsDirectory: home.appendingPathComponent("transcripts", isDirectory: true),
            incrementalScanner: IncrementalJSONLScanner<DevinTranscriptUsageScanner.Entry>()
        ).scan(daysBack: daysBack, now: now, pricing: TestPricing.bundled)
    }
}

enum DevinTranscriptFixture {
    /// A step in an ATIF transcript. `.metered` carries the token counters every agent step writes;
    /// `.metricsOnly` writes arbitrary metrics (including malformed ones); `.unmetered` is a user or
    /// system step with no `metrics` object at all.
    enum Step {
        case metered(
            timestamp: String?,
            model: String? = "swe-2-max",
            prompt: Int,
            completion: Int = 0,
            cached: Int = 0
        )
        case metricsOnly(timestamp: String?, metrics: [String: Any])
        case unmetered(timestamp: String?)
    }

    /// A temp dir whose `transcripts/` contains the given `*.json` files (ATIF document text per path).
    static func makeTranscripts(files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openusage-devin-\(UUID().uuidString)", isDirectory: true)
        let transcripts = root.appendingPathComponent("transcripts", isDirectory: true)
        try FileManager.default.createDirectory(at: transcripts, withIntermediateDirectories: true)
        for (name, contents) in files {
            try contents.write(to: transcripts.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        return root
    }

    /// Parse the first metered entry out of a one-file transcript, for token-mapping assertions.
    static func parseFirstEntry(
        timestamp: String,
        stepModel: String? = "swe-2-max",
        agentModel: String = "SWE-2 Max",
        prompt: Int,
        completion: Int = 0,
        cached: Int = 0
    ) throws -> DevinTranscriptUsageScanner.Entry? {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("openusage-devin-entry-\(UUID().uuidString).json")
        try transcript(steps: [.metered(timestamp: timestamp, model: stepModel, prompt: prompt, completion: completion, cached: cached)], agentModel: agentModel)
            .write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        return DevinTranscriptUsageScanner.parseFile(at: file)?.first
    }

    /// A minimal ATIF-v1.7 export. `final*` values mirror how the CLI sums the step counters into
    /// `final_metrics`; callers set them explicitly so a test can verify steps-only folding.
    static func transcript(
        steps: [Step],
        agentModel: String = "SWE-2 Max",
        finalPrompt: Int = 0,
        finalCompletion: Int = 0,
        finalCached: Int = 0
    ) -> String {
        var stepObjects: [[String: Any]] = []
        for (index, step) in steps.enumerated() {
            var object: [String: Any] = ["step_id": index + 1]
            switch step {
            case .metered(let timestamp, let model, let prompt, let completion, let cached):
                object["source"] = "agent"
                object["timestamp"] = timestamp
                if let model { object["model_name"] = model }
                object["metrics"] = [
                    "prompt_tokens": prompt,
                    "completion_tokens": completion,
                    "cached_tokens": cached
                ]
            case .metricsOnly(let timestamp, let metrics):
                object["source"] = "agent"
                object["timestamp"] = timestamp
                object["metrics"] = metrics
            case .unmetered(let timestamp):
                object["source"] = "user"
                object["timestamp"] = timestamp
            }
            stepObjects.append(object)
        }
        let root: [String: Any] = [
            "schema_version": "ATIF-v1.7",
            "session_id": "test-session",
            "agent": ["name": "devin", "version": "3000.14.30821", "model_name": agentModel],
            "steps": stepObjects,
            "final_metrics": [
                "total_prompt_tokens": finalPrompt,
                "total_completion_tokens": finalCompletion,
                "total_cached_tokens": finalCached,
                "total_steps": steps.count
            ]
        ]
        return String(decoding: try! JSONSerialization.data(withJSONObject: root), as: UTF8.self)
    }
}
