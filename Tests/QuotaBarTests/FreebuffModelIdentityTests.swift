import XCTest
@testable import QuotaBar

final class FreebuffModelIdentityTests: XCTestCase {
    private let normalRoute = "deepseek/deepseek-v4.1-flash-1017"
    private let legacyRoute = "deepseek/deepseek-v4-flash"
    private let plainRoute = "deepseek/deepseek-v4.1-flash"
    private let fastRoute = "deepseek-v4.1-flash-fast"
    private let now = TestLocalInstant.date(2026, 10, 31, 12)

    private var catalog: [String: FreebuffModelCatalog.Entry] {
        [
            "m-normal": .init(key: "m-normal", displayName: "DeepSeek V4.1 Flash 10/17",
                               legacyDigests: ["1e303ac563a6f9cc"]),
            "m-fast": .init(key: "m-fast", displayName: "DeepSeek V4.1 Flash Fast 10/17"),
            "m-slow": .init(key: "m-slow", displayName: "DeepSeek V4.1 Flash Slow")
        ]
    }

    private var pricing: ModelPricing {
        let normal = ModelRates(inputPerMillion: 1, outputPerMillion: 2,
                                cacheWritePerMillion: 1, cacheReadPerMillion: 0.1)
        let fast = ModelRates(inputPerMillion: 4, outputPerMillion: 8,
                              cacheWritePerMillion: 4, cacheReadPerMillion: 0.4)
        let rule = PricingSupplement.AliasRule(
            pattern: try! NSRegularExpression(pattern: "^DeepSeek V4\\.1 Flash Fast 10/17$"),
            canonical: fastRoute
        )
        return ModelPricing(supplement: PricingSupplement(pricing: [fastRoute: fast], aliasRules: [rule]),
                            primary: PricingCatalog(), secondary: PricingCatalog(),
                            openRouter: PricingCatalog(entries: [
                                normalRoute: normal, legacyRoute: normal, plainRoute: normal
                            ]))
    }

    private func receipt(_ id: String, model: String) -> FreebuffUsageReceipt {
        FreebuffUsageReceipt(id: id, timestampMs: now.addingTimeInterval(-60).timeIntervalSince1970 * 1_000,
            metricsJSON: #"{"usage":{"inputTokens":100,"outputTokens":50,"cachedInputTokens":80,"totalTokens":150}}"#,
            model: model)
    }

    func testProviderLegacyDigestMatchesPublishedCatalog() {
        XCTAssertEqual(FreebuffModelIdentity.legacyDigest(legacyRoute), "1e303ac563a6f9cc")
        XCTAssertNotEqual(FreebuffModelIdentity.legacyDigest(legacyRoute.uppercased()), "1e303ac563a6f9cc")
    }

    func testCatalogueKeyLegacySlugDatedRouteAndModesShareOnePeriodRow() async throws {
        let scanner = FreebuffDesktopUsageScanner(databasePaths: { [] })
        let result = try await scanner.scan(now: now, pricing: pricing, modelCatalog: catalog,
            hostedReceipts: [
                receipt("key", model: "m-normal"), receipt("legacy", model: legacyRoute),
                receipt("dated", model: normalRoute), receipt("fast", model: "m-fast"),
                receipt("slow", model: "m-slow")
            ])
        let scan = try XCTUnwrap(result)
        let day = try XCTUnwrap(scan.usage.series.daily.first)
        let model = try XCTUnwrap(scan.usage.modelUsage?.daily.first?.models.first)
        XCTAssertEqual(scan.usage.modelUsage?.daily.first?.models.count, 1)
        XCTAssertEqual(model.model, "DeepSeek V4.1 Flash")
        XCTAssertEqual(model.totalTokens, 750)
        XCTAssertEqual(day.totalTokens, 750)
        // Normal: (20*1 + 80*0.1 + 50*2)/1M = 0.000128. The removed Fast mode prices the same —
        // four priced receipts at the base rate.
        XCTAssertEqual(try XCTUnwrap(model.costUSD), 0.000512, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(day.costUSD), 0.000512, accuracy: 1e-12)
        XCTAssertTrue(model.hasIncompleteCost, "the named Slow variant has no verified public rate")
        XCTAssertTrue(scan.usage.unknownModelsByDay.isEmpty, "known but unpriced is not unknown")
        let variants = try XCTUnwrap(model.variants)
        XCTAssertEqual(variants.count, 3)
        let normal = try XCTUnwrap(variants.first { $0.model == "DeepSeek V4.1 Flash 10/17" })
        XCTAssertEqual(normal.totalTokens, 450)
        XCTAssertEqual(try XCTUnwrap(normal.costUSD), 0.000384, accuracy: 1e-12)
        let fast = try XCTUnwrap(variants.first { $0.model == "DeepSeek V4.1 Flash" })
        XCTAssertEqual(fast.totalTokens, 150)
        XCTAssertEqual(try XCTUnwrap(fast.costUSD), 0.000128, accuracy: 1e-12)

        var lines: [MetricLine] = []
        SpendTileMapper.appendTokenUsage(scan.usage.series, to: &lines, now: now,
            unknownModelsByDay: scan.usage.unknownModelsByDay, modelUsage: scan.usage.modelUsage,
            modelSourceNote: "Measured Test Receipts")
        for line in lines where line.label == "Today" || line.label == "Last 30 Days" {
            guard case .values(_, _, _, _, _, let breakdown) = line else { return XCTFail("missing values") }
            XCTAssertEqual(breakdown?.models.map(\.model), ["DeepSeek V4.1 Flash"])
            XCTAssertEqual(breakdown?.totalTokens, 750)
        }
    }

    func testRemovedFastModeCollapsesOntoTheBaseFlashModel() {
        var resolver = FreebuffModelIdentity(entries: catalog, pricing: pricing)
        let resolved = resolver.resolve("m-fast", pricing: pricing)
        XCTAssertEqual(resolved.route, plainRoute,
                       "the removed Fast mode prices as the base Flash model, not the Fast-tier estimate")
        XCTAssertEqual(resolved.displayName, "DeepSeek V4.1 Flash",
                       "the stale Fast label no longer presents anywhere")
        XCTAssertEqual(resolved.group, "DeepSeek V4.1 Flash")
        // A raw persisted Fast-root slug (from before the removal) still prices at the retired
        // Fast-tier rates — the collapse is a catalogue-name rule, not a rate rewrite.
        XCTAssertEqual(resolver.resolve(fastRoute, pricing: pricing).route, fastRoute)
    }

    func testDifferentVersionsAndUnidentifiedSlugsStaySeparate() async throws {
        let entries = catalog.merging([
            "m-new": .init(key: "m-new", displayName: "DeepSeek V4.2 Flash Fast 11/01"),
            "m-pro": .init(key: "m-pro", displayName: "DeepSeek V4.1 Pro"),
            "m-sol": .init(key: "m-sol", displayName: "GPT-6.1 Sol"),
            "m-terra": .init(key: "m-terra", displayName: "GPT-6.1 Terra")
        ]) { _, new in new }
        let models = ["m-normal", "m-new", "m-pro", "m-sol", "m-terra", "unknown/flash-fast", "fbm1.private"]
        let scanner = FreebuffDesktopUsageScanner(databasePaths: { [] })
        let scan = try await scanner.scan(now: now, pricing: pricing, modelCatalog: entries,
            hostedReceipts: models.enumerated().map { receipt("cloud:\($0.offset)", model: $0.element) })
        XCTAssertEqual(Set(scan?.usage.modelUsage?.daily.first?.models.map(\.model) ?? []), [
            "DeepSeek V4.1 Flash", "DeepSeek V4.2 Flash", "DeepSeek V4.1 Pro", "GPT-6.1 Sol",
            "GPT-6.1 Terra", "unknown/flash-fast", "Unattributed"
        ])
        XCTAssertEqual(scan?.usage.series.daily.first?.totalTokens, 1_050)
        XCTAssertEqual(scan?.usage.unknownModelsByDay.values.first, ["unknown/flash-fast", "Unattributed"])
    }

    func testSameNamedCatalogueEntriesDoNotMakeRouteDisplayAmbiguous() {
        var entries = catalog
        entries["m-copy"] = .init(key: "m-copy", displayName: "DeepSeek V4.1 Flash 10/17")
        var resolver = FreebuffModelIdentity(entries: entries, pricing: pricing)
        XCTAssertEqual(resolver.resolve(normalRoute, pricing: pricing).displayName, "DeepSeek V4.1 Flash 10/17")
        XCTAssertEqual(resolver.resolve(normalRoute, pricing: pricing).group, "DeepSeek V4.1 Flash")
    }

    func testAmbiguousLegacyDigestDoesNotAssignAnArbitraryModel() {
        var entries = catalog
        entries["m-collision"] = .init(key: "m-collision", displayName: "Different Model",
                                      legacyDigests: ["1e303ac563a6f9cc"])
        var resolver = FreebuffModelIdentity(entries: entries, pricing: .empty)
        XCTAssertNil(resolver.resolve(legacyRoute, pricing: .empty).displayName)
        XCTAssertNil(resolver.resolve(legacyRoute, pricing: .empty).route)
    }

    func testLegacyDigestChangeInvalidatesCachedIdentityAndAggregate() async throws {
        let scanner = FreebuffDesktopUsageScanner(databasePaths: { [] })
        var entries = catalog
        entries["m-normal"]?.legacyDigests = nil
        let receipts = [receipt("legacy", model: legacyRoute)]
        let first = try await scanner.scan(now: now, pricing: pricing, modelCatalog: entries, hostedReceipts: receipts)
        XCTAssertEqual(first?.usage.modelUsage?.daily.first?.models.first?.model, legacyRoute)
        entries["m-normal"]?.legacyDigests = ["1e303ac563a6f9cc"]
        let second = try await scanner.scan(now: now, pricing: pricing, modelCatalog: entries, hostedReceipts: receipts)
        XCTAssertEqual(second?.usage.modelUsage?.daily.first?.models.first?.model, "DeepSeek V4.1 Flash")
        XCTAssertEqual(first?.usage.series, second?.usage.series, "display regrouping preserves the same measured totals and rates")
    }

    func testRealSQLiteRestoresClearedModelFromSavedSnapshotWithoutReadingConversation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            let trash = Process()
            trash.executableURL = URL(fileURLWithPath: "/usr/bin/trash")
            trash.arguments = ["-v", directory.path]
            try? trash.run()
            trash.waitUntilExit()
        }
        let path = directory.appendingPathComponent("history.db").path
        let sqlite = SQLiteCLIAccessor()
        let timestamp = Int(now.addingTimeInterval(-60).timeIntervalSince1970 * 1_000)
        try sqlite.execute(path: path, sql: """
        CREATE TABLE threads(id TEXT, model TEXT, harness_id TEXT, world_snapshot TEXT);
        CREATE TABLE messages(thread_id TEXT, seq INTEGER, request_id TEXT, ts INTEGER, metrics_json TEXT, role TEXT);
        INSERT INTO threads VALUES ('restored', NULL, 'codebuff', '{"model":"deepseek/deepseek-v4-flash","unrelated":"never projected"}');
        INSERT INTO threads VALUES ('explicit', 'm-fast', 'codebuff', '{"model":"deepseek/deepseek-v4-flash"}');
        INSERT INTO messages VALUES ('restored', 1, NULL, \(timestamp), '{"usage":{"inputTokens":100,"outputTokens":50,"cachedInputTokens":80}}', 'assistant');
        INSERT INTO messages VALUES ('explicit', 1, NULL, \(timestamp), '{"usage":{"inputTokens":100,"outputTokens":50,"cachedInputTokens":80}}', 'assistant');
        """)
        let projected = try XCTUnwrap(FreebuffDesktopUsageSQL.readRows(sqlite: sqlite, path: path))
        XCTAssertFalse(projected.contains("never projected"))
        let scanner = FreebuffDesktopUsageScanner(databasePaths: { [path] })
        let result = try await scanner.scan(now: now, pricing: pricing, modelCatalog: catalog)
        let scan = try XCTUnwrap(result)
        XCTAssertEqual(scan.usage.modelUsage?.daily.first?.models.map(\.model), ["DeepSeek V4.1 Flash"])
        XCTAssertEqual(scan.usage.series.daily.first?.totalTokens, 300)
        XCTAssertEqual(try XCTUnwrap(scan.usage.series.daily.first?.costUSD), 0.000256, accuracy: 1e-12)
        XCTAssertTrue(scan.usage.unknownModelsByDay.isEmpty)
    }

    func testMissingLegacyLabelsKeepTokensAndExplainedLowerBoundWithoutPricingWarning() async throws {
        let scanner = FreebuffDesktopUsageScanner(databasePaths: { [] })
        let result = try await scanner.scan(now: now, pricing: pricing, modelCatalog: catalog, hostedReceipts: [
            receipt("old:missing", model: "m-retired"), receipt("old:missing2", model: "fbm1.expired"),
            receipt("cloud:known", model: "m-normal")
        ])
        let scan = try XCTUnwrap(result)
        XCTAssertEqual(scan.usage.series.daily.first?.totalTokens, 450)
        XCTAssertFalse(try XCTUnwrap(scan.usage.series.daily.first).costIsComplete)
        XCTAssertEqual(scan.usage.series.daily.first?.hasUnexplainedIncompleteCost, false)
        XCTAssertTrue(scan.usage.unknownModelsByDay.isEmpty)
        var lines: [MetricLine] = []
        SpendTileMapper.appendTokenUsage(scan.usage.series, to: &lines, now: now,
            unknownModelsByDay: scan.usage.unknownModelsByDay, modelUsage: scan.usage.modelUsage,
            modelSourceNote: "Measured Test Receipts")
        let today = try XCTUnwrap(lines.first { $0.label == "Today" })
        guard case .values(_, let values, _, _, let unknown, let breakdown) = today else { return XCTFail("missing values") }
        XCTAssertTrue(unknown.isEmpty, "an explained missing legacy label must not raise a pricing triangle")
        XCTAssertEqual(values.first { $0.kind == .dollars }?.isLowerBound, true)
        XCTAssertEqual(breakdown?.models.first { $0.model == "Older Freebuff Usage" }?.totalTokens, 300)
    }
}
