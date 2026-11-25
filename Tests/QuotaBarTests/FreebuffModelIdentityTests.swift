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

    func testCatalogueGroupingKeepsTheAssumedStandardRateSeparate() async throws {
        let scanner = FreebuffDesktopUsageScanner(databasePaths: { [] })
        let result = try await scanner.scan(now: now, pricing: pricing, modelCatalog: catalog,
            hostedReceipts: [
                receipt("key", model: "m-normal"), receipt("legacy", model: legacyRoute),
                receipt("dated", model: normalRoute), receipt("fast", model: "m-fast"),
                receipt("slow", model: "m-slow")
            ])
        let scan = try XCTUnwrap(result)
        let day = try XCTUnwrap(scan.usage.series.daily.first)
        let models = try XCTUnwrap(scan.usage.modelUsage?.daily.first?.models)
        let model = try XCTUnwrap(models.first { $0.model == "DeepSeek V4.1 Flash" })
        let assumed = try XCTUnwrap(models.first { $0.model == "DeepSeek V4.1 Flash (Standard Rate Assumed)" })
        XCTAssertEqual(models.count, 2)
        XCTAssertEqual(model.totalTokens, 600)
        XCTAssertEqual(day.totalTokens, 750)
        // Off-peak DeepSeek comparison: (20*0.15 + 80*0.003 + 50*0.60)/1M = 0.00003324 per receipt.
        XCTAssertEqual(try XCTUnwrap(model.costUSD), 0.00013296, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(day.costUSD), 0.00016620, accuracy: 1e-12)
        XCTAssertEqual(assumed.totalTokens, 150)
        XCTAssertEqual(try XCTUnwrap(assumed.costUSD), 0.00003324, accuracy: 1e-12)
        XCTAssertFalse(model.hasIncompleteCost, "the named Slow variant prices at the standard Flash comparison")
        XCTAssertTrue(scan.usage.unknownModelsByDay.isEmpty, "known but unpriced is not unknown")
        let variants = try XCTUnwrap(model.variants)
        XCTAssertEqual(variants.count, 2)
        let normal = try XCTUnwrap(variants.first { $0.model == "DeepSeek V4.1 Flash 10/17" })
        XCTAssertEqual(normal.totalTokens, 450)
        XCTAssertEqual(try XCTUnwrap(normal.costUSD), 0.00009972, accuracy: 1e-12)

        var lines: [MetricLine] = []
        SpendTileMapper.appendTokenUsage(scan.usage.series, to: &lines, now: now,
            unknownModelsByDay: scan.usage.unknownModelsByDay, modelUsage: scan.usage.modelUsage,
            modelSourceNote: "Measured Test Receipts")
        for line in lines where line.label == "Today" || line.label == "Last 30 Days" {
            guard case .values(_, _, _, _, _, let breakdown) = line else { return XCTFail("missing values") }
            XCTAssertEqual(Set(breakdown?.models.map(\.model) ?? []),
                           ["DeepSeek V4.1 Flash", "DeepSeek V4.1 Flash (Standard Rate Assumed)"])
            XCTAssertEqual(breakdown?.totalTokens, 750)
        }
    }

    func testOnlyReceiptProvenanceCanLabelAnExactFastRoute() {
        var resolver = FreebuffModelIdentity(entries: catalog, pricing: pricing)
        for evidence in [false, true] {
            let opaque = resolver.resolve("m-fast", pricing: pricing, fromReceipt: evidence)
            XCTAssertEqual(opaque.route, plainRoute)
            XCTAssertEqual(opaque.displayName, "DeepSeek V4.1 Flash (Standard Rate Assumed)")
        }
        let selected = resolver.resolve(fastRoute, pricing: pricing)
        XCTAssertEqual(selected.route, plainRoute)
        XCTAssertEqual(selected.displayName, "DeepSeek V4.1 Flash (Standard Rate Assumed)")
        let recorded = resolver.resolve("deepseek/\(fastRoute)", pricing: pricing, fromReceipt: true)
        XCTAssertEqual(recorded.route, fastRoute)
        XCTAssertEqual(recorded.displayName, "DeepSeek V4.1 Flash Fast (Recorded Route)")
        XCTAssertEqual(resolver.resolve(fastRoute, pricing: pricing, fromReceipt: true).route, fastRoute)
        XCTAssertEqual(resolver.resolve(fastRoute, pricing: pricing).route, plainRoute)
        XCTAssertEqual(resolver.resolve(plainRoute, pricing: pricing, fromReceipt: true).route, plainRoute)
        var conflict = catalog
        conflict["m-normal"]?.legacyDigests = nil
        conflict["m-fast"]?.legacyDigests = [FreebuffModelIdentity.legacyDigest(legacyRoute)]
        var conflictingResolver = FreebuffModelIdentity(entries: conflict, pricing: pricing)
        let savedLegacy = conflictingResolver.resolve(legacyRoute, pricing: pricing)
        XCTAssertEqual(savedLegacy.route, plainRoute)
        XCTAssertEqual(savedLegacy.displayName, "DeepSeek V4.1 Flash (Standard Rate Assumed)")
        XCTAssertEqual(conflictingResolver.resolve(legacyRoute, pricing: pricing, fromReceipt: true).route, legacyRoute)
        var missingRates = FreebuffModelIdentity(entries: catalog, pricing: .empty)
        let missing = missingRates.resolve("m-fast", pricing: .empty)
        XCTAssertEqual(missing.route, FreebuffFlashComparison.route)
        XCTAssertEqual(missing.displayName, "DeepSeek V4.1 Flash (Standard Rate Assumed)")
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
            "DeepSeek V4.1 Flash", "DeepSeek V4.2 Flash (Route Unverified)", "DeepSeek V4.1 Pro",
            "GPT-6.1 Sol", "GPT-6.1 Terra", "unknown/flash (Route Unverified)", "Unattributed"
        ])
        XCTAssertEqual(scan?.usage.series.daily.first?.totalTokens, 1_050)
        XCTAssertEqual(scan?.usage.unknownModelsByDay.values.first,
                       ["unknown/flash (Route Unverified)", "Unattributed"])
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
        XCTAssertEqual(resolver.resolve(legacyRoute, pricing: .empty).route, legacyRoute)
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
        let sqlite = NativeSQLiteAccessor()
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
        XCTAssertEqual(scan.usage.modelUsage?.daily.first?.models.map(\.model),
                       ["DeepSeek V4.1 Flash", "DeepSeek V4.1 Flash (Standard Rate Assumed)"])
        XCTAssertEqual(scan.usage.series.daily.first?.totalTokens, 300)
        // The snapshot-restored base route and the assumed-standard Fast label both price.
        XCTAssertEqual(try XCTUnwrap(scan.usage.series.daily.first?.costUSD), 0.00006648, accuracy: 1e-12)
        XCTAssertTrue(scan.usage.unknownModelsByDay.isEmpty)
    }

    func testMissionManagerUsesNestedUsageRouteRatherThanEnvelopeSelection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            let trash = Process()
            trash.executableURL = URL(fileURLWithPath: "/usr/bin/trash")
            trash.arguments = ["-v", directory.path]
            try? trash.run()
            trash.waitUntilExit()
        }
        let path = directory.appendingPathComponent("desktop-v2.db").path
        let stamp = Int64(now.addingTimeInterval(-60).timeIntervalSince1970 * 1_000)
        let sqlite = SQLiteCLIAccessor()
        try sqlite.execute(path: path, sql: """
        CREATE TABLE threads (id TEXT, harness_id TEXT, model TEXT, world_snapshot TEXT);
        CREATE TABLE messages (thread_id TEXT, seq INT, request_id TEXT, ts INT, metrics_json TEXT, role TEXT);
        CREATE TABLE auto_run_decision_receipts (id INT, thread_id TEXT, created_at INT, manager_json TEXT);
        INSERT INTO threads VALUES ('t', 'codebuff', 'm-normal', NULL);
        INSERT INTO auto_run_decision_receipts VALUES
          (1, 't', \(stamp), '{"harnessId":"codebuff","model":"deepseek-v4.1-flash-fast","usage":{"inputTokens":100,"outputTokens":50}}'),
          (2, 't', \(stamp), '{"harnessId":"codebuff","model":"m-fast","usage":{"inputTokens":100,"outputTokens":50,"model":"deepseek-v4.1-flash-fast"}}');
        """)
        let result = try await FreebuffDesktopUsageScanner(databasePaths: { [path] })
            .scan(now: now, pricing: pricing, modelCatalog: catalog)
        XCTAssertEqual(result?.usage.series.daily.first?.totalTokens, 300)
        let models = try XCTUnwrap(result?.usage.modelUsage?.daily.first?.models)
        let recorded = try XCTUnwrap(models.first { $0.model == "DeepSeek V4.1 Flash Fast (Recorded Route)" })
        let assumed = try XCTUnwrap(models.first { $0.model == "DeepSeek V4.1 Flash (Standard Rate Assumed)" })
        XCTAssertEqual(recorded.totalTokens, 150)
        XCTAssertEqual(try XCTUnwrap(recorded.costUSD), 0.000045, accuracy: 1e-12)
        XCTAssertEqual(assumed.totalTokens, 150)
        XCTAssertEqual(try XCTUnwrap(assumed.costUSD), 0.000045, accuracy: 1e-12)
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

    func testDirectFlashComparisonUsesUTCWindowsAndChineseHolidays() throws {
        let formatter = ISO8601DateFormatter()
        for (timestamp, inputRate, cacheRate, outputRate) in [
            ("2026-10-26T00:59:59Z", 0.15, 0.003, 0.60),
            ("2026-10-26T01:00:00Z", 0.30, 0.006, 1.20),
            ("2026-10-26T04:00:00Z", 0.15, 0.003, 0.60),
            ("2026-10-26T06:00:00Z", 0.30, 0.006, 1.20),
            ("2026-10-26T10:00:00Z", 0.15, 0.003, 0.60),
            ("2026-10-01T02:00:00Z", 0.15, 0.003, 0.60),
            ("2026-10-10T02:00:00Z", 0.15, 0.003, 0.60),
            ("2027-02-05T02:00:00Z", 0.15, 0.003, 0.60),
            ("2027-02-15T02:00:00Z", 0.30, 0.006, 1.20)
        ] {
            let time = try XCTUnwrap(formatter.date(from: timestamp))
            for route in ["deepseek-flash", "deepseek/deepseek-v4-flash", normalRoute, fastRoute] {
                let rates = try XCTUnwrap(FreebuffFlashComparison.rates(for: route, at: time))
                XCTAssertEqual(rates.inputPerMillion, inputRate, "\(route) \(timestamp)")
                XCTAssertEqual(rates.cacheReadPerMillion, cacheRate, "\(route) \(timestamp)")
                XCTAssertEqual(rates.outputPerMillion, outputRate, "\(route) \(timestamp)")
            }
        }
        XCTAssertNil(FreebuffFlashComparison.rates(for: "deepseek/deepseek-v4-pro", at: now))
        XCTAssertNil(FreebuffFlashComparison.rates(for: "deepseek-v4-flash-free", at: now))
    }

    func testFastCatalogueSelectionUsesStandardPeakRateWithoutLivePrices() async throws {
        let peak = try XCTUnwrap(OpenUsageISO8601.date(from: "2026-11-20T07:00:00Z"))
        let receipt = FreebuffUsageReceipt(id: "cloud:peak", timestampMs: peak.timeIntervalSince1970 * 1_000,
            metricsJSON: #"{"usage":{"inputTokens":100,"outputTokens":50,"cachedInputTokens":80}}"#,
            model: "m-fast")
        let scan = try await FreebuffDesktopUsageScanner(databasePaths: { [] }).scan(
            now: peak.addingTimeInterval(60), pricing: .empty, modelCatalog: catalog,
            hostedReceipts: [receipt])
        let model = try XCTUnwrap(scan?.usage.modelUsage?.daily.first?.models.first)
        XCTAssertEqual(model.model, "DeepSeek V4.1 Flash (Standard Rate Assumed)")
        XCTAssertEqual(model.totalTokens, 150)
        XCTAssertEqual(try XCTUnwrap(model.costUSD), 0.00006648, accuracy: 1e-12)
    }
}
