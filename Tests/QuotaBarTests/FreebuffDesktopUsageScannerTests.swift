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
                       ["vendor/model-1", "vendor/recorded-model"], "receipt model wins over saved selection")
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
