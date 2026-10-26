import Foundation
import XCTest
@testable import QuotaBar

final class FreebuffDesktopUsageScannerTests: XCTestCase {
    private final class SQLite: SQLiteAccessing, @unchecked Sendable {
        var rows: [[String: Any]] = []
        var rowsByPath: [String: [[String: Any]]] = [:]
        var calls = 0
        func queryValue(path: String, sql: String) throws -> String? {
            calls += 1
            XCTAssertTrue(sql.contains("m.role = 'assistant'"))
            XCTAssertFalse(sql.contains("parts_json"), "never read transcript content for accounting")
            return String(decoding: try JSONSerialization.data(withJSONObject: rowsByPath[path] ?? rows), as: UTF8.self)
        }
        func execute(path: String, sql: String) throws { XCTFail("history reads must never write") }
    }

    private let now = TestLocalInstant.date(2026, 10, 18, 12)

    private func row(_ id: String, total: Int = 150, model: String? = nil, incomplete: Bool = false) throws -> [String: Any] {
        var usage: [String: Any] = ["inputTokens": 100, "cachedInputTokens": 80,
                                    "outputTokens": 50, "reasoningOutputTokens": 20, "totalTokens": total]
        if let model { usage["model"] = model }
        let metrics: [String: Any] = ["usage": usage, "usageIncomplete": incomplete, "costUsd": 0]
        return ["id": id, "timestamp": String(now.addingTimeInterval(-60).timeIntervalSince1970 * 1000),
                "metrics": String(decoding: try JSONSerialization.data(withJSONObject: metrics), as: UTF8.self)]
    }

    func testMeasuredTotalsExcludeCacheAndReasoningSubsetsAndDeduplicateCopies() async throws {
        let sqlite = SQLite()
        sqlite.rows = [try row("turn:1"), try row("turn:1"), try row("turn:2", model: "serving-model", incomplete: true)]
        let scanner = FreebuffDesktopUsageScanner(sqlite: sqlite, databasePaths: { ["/fixture/not-a-real.db"] })
        let result = try await scanner.scan(now: now)
        XCTAssertEqual(result?.usage.series.daily.first?.totalTokens, 300)
        let models = result?.usage.modelUsage?.daily.first?.models ?? []
        XCTAssertEqual(Set(models.map(\.model)), ["Unattributed", "serving-model"])
        XCTAssertTrue(models.allSatisfy { $0.costUSD == nil }, "zero CLI charge is not an API-price estimate")
        XCTAssertEqual(result?.partialDays, [DailyUsageAccumulator.dayKey(from: now)])
        let again = try await scanner.scan(now: now)
        XCTAssertEqual(again?.usage.series.daily.first?.totalTokens, 300)
        XCTAssertEqual(sqlite.calls, 1, "unchanged DB/WAL revisions avoid another sqlite subprocess")
    }

    func testInconsistentReceiptFailsInsteadOfPublishingPlausibleTotals() async throws {
        let sqlite = SQLite()
        sqlite.rows = [try row("turn:1", total: 230)]
        let scanner = FreebuffDesktopUsageScanner(sqlite: sqlite, databasePaths: { ["/fixture/not-a-real.db"] })
        do {
            _ = try await scanner.scan(now: now)
            XCTFail("cache-inclusive input must not be counted twice")
        } catch {
            XCTAssertEqual(error as? FreebuffUsageError, .localHistoryUnreadable)
        }
    }

    func testSavedSelectionEstimatePricesCacheSubsetAtExactOpenRouterRates() async throws {
        let sqlite = SQLite()
        var selected = try row("turn:1")
        selected["selectedModel"] = "m-known"
        var recorded = try row("turn:2", model: "vendor/recorded-model")
        recorded["selectedModel"] = "m-known"
        sqlite.rows = [selected, recorded]
        let rates = ModelRates(inputPerMillion: 2, outputPerMillion: 10,
                               cacheWritePerMillion: 2, cacheReadPerMillion: 0.2,
                               inputAbove200kPerMillion: 20, outputAbove200kPerMillion: 100,
                               cacheReadIsExplicit: true, longContextThresholdTokens: 1)
        let pricing = ModelPricing(supplement: PricingSupplement(), primary: PricingCatalog(),
                                   secondary: PricingCatalog(), openRouter: PricingCatalog(entries: [
                                    "vendor/model-1": rates, "vendor/recorded-model": rates
                                   ]))
        let scanner = FreebuffDesktopUsageScanner(sqlite: sqlite, databasePaths: { ["/fixture/no.db"] })
        let scan = try await scanner.scan(now: now, pricing: pricing, modelCatalog: [
            "m-known": FreebuffModelCatalog.Entry(key: "m-known", displayName: "Model 1")
        ])
        let day = try XCTUnwrap(scan?.usage.series.daily.first)
        XCTAssertEqual(day.totalTokens, 300)
        XCTAssertEqual(try XCTUnwrap(day.costUSD), 0.001112, accuracy: 0.000000001)
        XCTAssertEqual(Set(scan?.usage.modelUsage?.daily.first?.models.map(\.model) ?? []),
                       ["Model 1", "vendor/recorded-model"],
                       "catalog-named turns title rows with the display name; a receipt model wins over saved selection")
        XCTAssertTrue(day.costIsComplete)
    }

    func testFreshInstallationWithoutDesktopHistoryReturnsNoData() async throws {
        let sqlite = SQLite()
        let scanner = FreebuffDesktopUsageScanner(sqlite: sqlite, databasePaths: { [] })
        let scan = try await scanner.scan(now: now)
        XCTAssertNil(scan)
        XCTAssertEqual(sqlite.calls, 0)
    }

    func testOneUnreadableRowDoesNotFailTheWholeHistory() async throws {
        // A NULL column used to fail the JSON cast for the entire array, so a single odd row took
        // the whole measured history with it.
        let sqlite = SQLite()
        var broken = try row("turn:2")
        broken["timestamp"] = NSNull()
        sqlite.rows = [try row("turn:1"), broken, try row("turn:3")]
        let scanner = FreebuffDesktopUsageScanner(sqlite: sqlite, databasePaths: { ["/fixture/not-a-real.db"] })

        let result = try await scanner.scan(now: now)

        XCTAssertEqual(result?.usage.series.daily.first?.totalTokens, 300,
                       "the readable rows still aggregate")
    }

    func testRowWithoutAnIdentifierIsSkippedInsteadOfFailingTheFold() async throws {
        let sqlite = SQLite()
        var broken = try row("turn:2")
        broken["id"] = NSNull()
        sqlite.rows = [try row("turn:1"), broken]
        let scanner = FreebuffDesktopUsageScanner(sqlite: sqlite, databasePaths: { ["/fixture/not-a-real.db"] })

        let result = try await scanner.scan(now: now)

        XCTAssertEqual(result?.usage.series.daily.first?.totalTokens, 150)
    }

    func testPricingChangeRecomputesTheModelRoutes() async throws {
        // The scanner keys its route table on the pricing snapshot's identity, so a new snapshot
        // must still be picked up.
        let sqlite = SQLite()
        var turn = try row("turn:1")
        turn["selectedModel"] = "m-known"
        sqlite.rows = [turn]
        let scanner = FreebuffDesktopUsageScanner(sqlite: sqlite, databasePaths: { ["/fixture/not-a-real.db"] })
        let catalog: [String: FreebuffModelCatalog.Entry] = [
            "m-known": FreebuffModelCatalog.Entry(key: "m-known", displayName: "Model 1")
        ]

        let withoutRoute = try await scanner.scan(now: now, pricing: .empty, modelCatalog: catalog)
        XCTAssertEqual(withoutRoute?.usage.modelUsage?.daily.first?.models.map(\.model), ["Model 1"])

        let rates = ModelRates(inputPerMillion: 2, outputPerMillion: 10,
                               cacheWritePerMillion: 2, cacheReadPerMillion: 0.2)
        let pricing = ModelPricing(supplement: PricingSupplement(), primary: PricingCatalog(),
                                   secondary: PricingCatalog(), openRouter: PricingCatalog(entries: [
                                    "vendor/model-1": rates
                                   ]))
        let withRoute = try await scanner.scan(now: now, pricing: pricing, modelCatalog: catalog)
        XCTAssertEqual(withRoute?.usage.modelUsage?.daily.first?.models.map(\.model), ["Model 1"],
                       "the route prices the row but the catalog name still titles it")
    }

    func testDeepSeekPeakWindowPricesBaseAndDedicatedFastRoute() async throws {
        let formatter = ISO8601DateFormatter()
        let peakTimestamp = try XCTUnwrap(formatter.date(from: "2026-10-26T02:00:00Z"))
        let scanNow = peakTimestamp.addingTimeInterval(3_600)
        let sqlite = SQLite()
        var base = try row("turn:base")
        base["selectedModel"] = "deepseek-base"
        base["timestamp"] = String(peakTimestamp.timeIntervalSince1970 * 1_000)
        var fast = try row("turn:fast")
        fast["selectedModel"] = "deepseek-fast"
        fast["timestamp"] = String(peakTimestamp.timeIntervalSince1970 * 1_000)
        sqlite.rows = [base, fast]

        let rates = ModelRates(
            inputPerMillion: 0.15,
            outputPerMillion: 0.6,
            cacheWritePerMillion: 0.15,
            cacheReadPerMillion: 0.003,
            utcPriceOverrides: [
                UTCPriceRateOverride(
                    utcDays: ["saturday", "sunday"], utcStartMinute: nil, utcEndMinute: nil,
                    inputPerMillion: 0.15, outputPerMillion: 0.6, cacheWritePerMillion: nil,
                    cacheReadPerMillion: 0.003, cacheWrite1hPerMillion: nil
                ),
                UTCPriceRateOverride(
                    utcDays: ["monday", "tuesday", "wednesday", "thursday", "friday"],
                    utcStartMinute: 60, utcEndMinute: 240,
                    inputPerMillion: 0.3, outputPerMillion: 1.2, cacheWritePerMillion: nil,
                    cacheReadPerMillion: 0.006, cacheWrite1hPerMillion: nil
                )
            ],
            cacheReadIsExplicit: true
        )
        let fastRates = ModelRates(
            inputPerMillion: 0.6, outputPerMillion: 2.4,
            cacheWritePerMillion: 0.6, cacheReadPerMillion: 0.01,
            cacheReadIsExplicit: true
        )
        let fastAlias = try NSRegularExpression(
            pattern: "(?i)^(?:deepseek/)?(?:deepseek[- ]?)?v4(?:\\.1)?[- ]flash[- ]fast(?:[- ]?(?:10/17|1017))?$"
        )
        let supplement = PricingSupplement(
            pricing: ["deepseek-v4.1-flash-fast": fastRates],
            aliasRules: [.init(pattern: fastAlias, canonical: "deepseek-v4.1-flash-fast")]
        )
        let pricing = ModelPricing(
            supplement: supplement, primary: PricingCatalog(), secondary: PricingCatalog(),
            openRouter: PricingCatalog(entries: ["deepseek/deepseek-v4.1-flash-1017": rates])
        )
        let modelCatalog = [
            "deepseek-base": FreebuffModelCatalog.Entry(
                key: "deepseek-base", displayName: "DeepSeek V4.1 Flash 10/17"
            ),
            "deepseek-fast": FreebuffModelCatalog.Entry(
                key: "deepseek-fast", displayName: "DeepSeek V4.1 Flash Fast 10/17"
            )
        ]
        let scanner = FreebuffDesktopUsageScanner(sqlite: sqlite, databasePaths: { ["/fixture/no.db"] })

        let scan = try await scanner.scan(now: scanNow, pricing: pricing, modelCatalog: modelCatalog)
        let day = DailyUsageAccumulator.dayKey(from: peakTimestamp)
        let models = try XCTUnwrap(scan?.usage.modelUsage?.daily.first?.models)
        let fastModel = try XCTUnwrap(models.first { $0.model == "DeepSeek V4.1 Flash Fast 10/17" })

        XCTAssertEqual(scan?.usage.series.daily.first?.totalTokens, 300)
        XCTAssertEqual(try XCTUnwrap(scan?.usage.apiEstimateByDay?[day]), 0.000_199_28, accuracy: 0.000_000_001)
        XCTAssertEqual(try XCTUnwrap(fastModel.costUSD), 0.000_132_8, accuracy: 0.000_000_001)
    }

    func testUnchangedHistoryIsNotDecodedAgain() async throws {
        // The receipt JSON is decoded once, when the database changes. Re-decoding every retained
        // row on every fold was the whole cost of a history fold.
        let sqlite = SQLite()
        sqlite.rows = [try row("turn:1"), try row("turn:2")]
        let decodes = Counter()
        let scanner = FreebuffDesktopUsageScanner(
            sqlite: sqlite,
            databasePaths: { ["/fixture/not-a-real.db"] },
            parseMetrics: { text in
                decodes.value += 1
                return ProviderParse.jsonObject(Data(text.utf8))
            }
        )

        let first = try await scanner.scan(now: now)
        XCTAssertEqual(first?.usage.series.daily.first?.totalTokens, 300)
        XCTAssertEqual(decodes.value, 2, "each receipt is decoded once")

        let second = try await scanner.scan(now: now)
        XCTAssertEqual(second?.usage.series.daily.first?.totalTokens, 300)
        XCTAssertEqual(decodes.value, 2, "an unchanged history must not be decoded again")
    }

    func testAggregateCacheSurvivesTurnEvictionAndAvoidsSQLiteReads() async throws {
        // Every project's history used to stay resident for the life of the process. Raw turns are
        // now evicted at the cap while the bounded daily aggregate serves unchanged refreshes.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first.db")
        let second = directory.appendingPathComponent("second.db")
        let third = directory.appendingPathComponent("third.db")
        try Data().write(to: first)
        try Data().write(to: second)
        try Data().write(to: third)
        let sqlite = SQLite()
        sqlite.rowsByPath = [
            first.path: [try row("turn:1")],
            second.path: [try row("turn:2")],
            third.path: [try row("turn:3")]
        ]
        let scanner = FreebuffDesktopUsageScanner(
            sqlite: sqlite,
            databasePaths: { [first.path, second.path, third.path] },
            maximumRetainedTurns: 2
        )

        _ = try await scanner.scan(now: now)
        XCTAssertEqual(sqlite.calls, 3)

        _ = try await scanner.scan(now: now)
        XCTAssertEqual(sqlite.calls, 3, "the completed daily fold survives eviction of raw turn rows")

        _ = try await scanner.scan(now: now)
        XCTAssertEqual(sqlite.calls, 3, "unchanged project revisions reuse the aggregate without SQLite")
    }

    func testProjectDatabaseListIsResolvedOncePerInterval() async throws {
        // The live-quota refresh and the history fold both need the project list, and resolving it
        // reads the projects directory and stats every project.
        let enumerations = Counter()
        let scanner = FreebuffDesktopUsageScanner(sqlite: SQLite(), databasePaths: {
            enumerations.value += 1
            return ["/fixture/not-a-real.db"]
        })

        _ = try await scanner.scan(now: now)
        _ = try await scanner.hasHistory(now: now.addingTimeInterval(60))

        XCTAssertEqual(enumerations.value, 1, "the projects directory must not be enumerated twice per tick")
    }

    private final class Counter: @unchecked Sendable {
        var value = 0
    }

    func testWALChangeInvalidatesOnlyChangedProjectAndReplacesLatestTurnTotal() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first.db")
        let second = directory.appendingPathComponent("second.db")
        try Data().write(to: first)
        try Data().write(to: second)
        let sqlite = SQLite()
        sqlite.rowsByPath = [first.path: [try row("turn:1")], second.path: [try row("turn:2")]]
        let scanner = FreebuffDesktopUsageScanner(sqlite: sqlite, databasePaths: { [first.path, second.path] })
        _ = try await scanner.scan(now: now)
        XCTAssertEqual(sqlite.calls, 2)
        _ = try await scanner.scan(now: now)
        XCTAssertEqual(sqlite.calls, 2)
        sqlite.rowsByPath[first.path] = [["id": "turn:1",
                                        "timestamp": String(now.addingTimeInterval(-60).timeIntervalSince1970 * 1000),
                                        "metrics": #"{"usage":{"inputTokens":200,"outputTokens":50,"totalTokens":250}}"#]]
        try Data("newly committed rows".utf8).write(to: URL(fileURLWithPath: first.path + "-wal"))
        let result = try await scanner.scan(now: now)
        XCTAssertEqual(sqlite.calls, 3, "a single active project must not reread every other database")
        XCTAssertEqual(result?.usage.series.daily.first?.totalTokens, 400,
                       "an updated cumulative turn replaces its earlier value instead of adding it again")
    }
}
