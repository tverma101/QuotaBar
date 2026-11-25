import XCTest
@testable import QuotaBar

/// Proves the Rust OpenCode database read serves the same scan the `/usr/bin/sqlite3` path produces,
/// and that the provider refresh actually goes through it.
final class OpenCodeRustParityTests: XCTestCase {
    private let now = OpenUsageISO8601.date(from: "2026-07-12T12:00:00.000Z")!

    private func epochMs(_ iso: String) -> Int {
        Int(OpenUsageISO8601.date(from: iso)!.timeIntervalSince1970 * 1000)
    }

    private func makeDatabase(_ statements: String) throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode-rust-parity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.trashItem(at: directory, resultingItemURL: nil) }
        let path = directory.appendingPathComponent("opencode.db").path
        try SQLiteCLIAccessor().execute(path: path, sql: statements)
        return path
    }

    private let v2Table = """
        CREATE TABLE session_message (
          id text PRIMARY KEY,
          session_id text NOT NULL,
          type text NOT NULL,
          seq integer NOT NULL,
          time_created integer NOT NULL,
          time_updated integer NOT NULL,
          data text NOT NULL
        );
        CREATE INDEX session_message_time_created_idx ON session_message (time_created);
        """

    private let legacyTable = """
        CREATE TABLE message (
          id text PRIMARY KEY,
          session_id text NOT NULL,
          time_created integer NOT NULL,
          time_updated integer NOT NULL,
          data text NOT NULL
        );
        """

    private func v2Row(
        id: String,
        at iso: String,
        model: String?,
        provider: String,
        cost: String,
        tokens: String
    ) -> String {
        let modelJSON = model.map { "'{\"model\":{\"id\":\"\($0)\",\"providerID\":\"\(provider)\"},\"cost\":\(cost),\"tokens\":\(tokens)}'" }
            ?? "'{\"model\":{\"providerID\":\"\(provider)\"},\"cost\":\(cost),\"tokens\":\(tokens)}'"
        return """
            INSERT INTO session_message (id,session_id,type,seq,time_created,time_updated,data)
            VALUES ('\(id)','ses_1','assistant',1,\(epochMs(iso)),\(epochMs(iso)),\(modelJSON));
            """
    }

    private func legacyRow(
        id: String,
        at iso: String,
        model: String,
        provider: String,
        cost: String,
        tokens: String
    ) -> String {
        """
        INSERT INTO message (id,session_id,time_created,time_updated,data)
        VALUES ('\(id)','ses_1',\(epochMs(iso)),\(epochMs(iso)),
        '{"role":"assistant","modelID":"\(model)","providerID":"\(provider)","cost":\(cost),"tokens":\(tokens)}');
        """
    }

    private func hermeticScanner(paths: [String], engine: OpenCodeDatabaseEngine) -> OpenCodeUsageScanner {
        OpenCodeUsageScanner(
            sqlite: SQLiteCLIAccessor(),
            databaseEngine: engine,
            databasePaths: { paths },
            claudeRoots: { [] },
            codexHomes: { [] },
            hermesStateDBPath: { nil },
            routerLedgerPaths: { [] },
            museRoots: { [] }
        )
    }

    private func fixturePaths() throws -> [String] {
        let v2 = try makeDatabase(
            v2Table
                + v2Row(
                    id: "a", at: "2026-07-12T11:00:00.000Z", model: "glm-5.2",
                    provider: "opencode-go", cost: "2.0",
                    tokens: #"{"input":1000,"output":500}"#
                )
                + v2Row(
                    id: "b", at: "2026-07-12T10:00:00.000Z", model: "gpt-5.5",
                    provider: "opencode", cost: "null", tokens: #"{"total":100}"#
                )
                + v2Row(
                    id: "c", at: "2026-07-11T10:00:00.000Z", model: "glm-5.2",
                    provider: "opencode-go", cost: "1.5", tokens: #"{"input":0,"output":0}"#
                )
        )
        let legacy = try makeDatabase(
            legacyTable
                + legacyRow(
                    id: "d", at: "2026-07-12T09:00:00.000Z", model: "  kimi-k2.6  ",
                    provider: "opencode-go", cost: "4.0",
                    tokens: #"{"input":800,"output":200}"#
                )
                + legacyRow(
                    id: "e", at: "2026-07-10T09:00:00.000Z", model: "deepseek-v4-pro",
                    provider: "opencode", cost: "-1", tokens: #"{"total":50}"#
                )
        )
        return [v2, legacy]
    }

    func testDatabaseReadMatchesSwiftOracle() async throws {
        let paths = try fixturePaths()
        let rustScanner = hermeticScanner(paths: paths, engine: .rust)
        let swiftScanner = hermeticScanner(paths: paths, engine: .sqliteCLI)

        #if DEBUG
        let scansBefore = OpenCodeRustScan.completedSchemaReadsForTesting
        #endif
        let rust = try await rustScanner.scan(now: now, gatewaySources: [])
        #if DEBUG
        XCTAssertGreaterThan(
            OpenCodeRustScan.completedSchemaReadsForTesting, scansBefore,
            "the scan never reached opencode.schema"
        )
        #endif
        let oracle = try await swiftScanner.scan(now: now, gatewaySources: [])

        let rustScan = try XCTUnwrap(rust)
        let swiftScan = try XCTUnwrap(oracle)
        XCTAssertEqual(rustScan.logScan, swiftScan.logScan)
        XCTAssertEqual(rustScan.goWindows, swiftScan.goWindows)
        XCTAssertEqual(rustScan.includesEstimatedCost, swiftScan.includesEstimatedCost)
        XCTAssertEqual(rustScan.partialDays, swiftScan.partialDays)

        // Both layouts and the missing-cost marker survive the wire.
        XCTAssertEqual(rustScan.logScan.series.daily.compactMap(\.costUSD).reduce(0, +), 7.5, accuracy: 0.0001)
        let models = Set(rustScan.logScan.modelUsage?.daily.flatMap(\.models).map(\.model) ?? [])
        XCTAssertTrue(models.contains("glm-5.2"))
        XCTAssertTrue(models.contains("kimi-k2.6"))
        XCTAssertTrue(models.contains("gpt-5.5"))
    }

    func testCLIEngineKeepsTheSwiftPath() async throws {
        let fake = OpenCodeFakeSQLite(data: [
            "/oc/opencode.db": "[" + [
                "[\(epochMs("2026-07-12T11:00:00.000Z")),1.0,100,\"glm-5.2\",\"opencode-go\"]"
            ].joined() + "]"
        ])
        let scanner = OpenCodeUsageScanner(
            sqlite: fake,
            databaseEngine: .sqliteCLI,
            databasePaths: { ["/oc/opencode.db"] },
            claudeRoots: { [] },
            codexHomes: { [] },
            hermesStateDBPath: { nil },
            routerLedgerPaths: { [] },
            museRoots: { [] }
        )
        #if DEBUG
        let scansBefore = OpenCodeRustScan.completedSchemaReadsForTesting
        #endif
        _ = try await scanner.scan(now: now, gatewaySources: [])
        #if DEBUG
        XCTAssertEqual(OpenCodeRustScan.completedSchemaReadsForTesting, scansBefore)
        #endif
        XCTAssertNotNil(fake.lastDataSQL)
    }

    @MainActor
    func testProviderRefreshUsesTheRustRead() async throws {
        let path = try makeDatabase(
            legacyTable
                + legacyRow(
                    id: "p", at: "2026-07-12T10:00:00.000Z", model: "glm-5.2",
                    provider: "opencode-go", cost: "2.0",
                    tokens: #"{"input":1000,"output":500}"#
                )
        )
        let scanner = hermeticScanner(paths: [path], engine: .rust)
        let fixedNow = now
        let authStore = OpenCodeAuthStore(
            files: FakeFiles(["/oc/auth.json": #"{"opencode-go":{"type":"api","key":"sk-test"}}"#]),
            environment: FakeEnvironment(["OPENCODE_DATA_DIR": "/oc"]),
            homeDirectory: { URL(fileURLWithPath: "/nonexistent") }
        )
        let http = FakeHTTPClient(
            response: HTTPResponse(
                statusCode: 200, headers: [:],
                body: OpenCodeGoUsageClientTests.livePayloadFixture
            )
        )
        let provider = OpenCodeProvider(
            authStore: authStore,
            usageScanner: scanner,
            usageClient: OpenCodeGoUsageClient(http: http),
            now: { fixedNow },
            goKeyStore: OpenCodeGoKeyStore(files: FakeFiles(), filePath: { "/oc/go-keys.json" }),
            activeKeyID: { nil }
        )

        #if DEBUG
        let scansBefore = OpenCodeRustScan.completedSchemaReadsForTesting
        #endif
        let snapshot = await provider.refresh()
        #if DEBUG
        XCTAssertGreaterThan(
            OpenCodeRustScan.completedSchemaReadsForTesting, scansBefore,
            "the provider refresh never reached opencode.schema"
        )
        #endif
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNotNil(snapshot.line(label: "Today"))
        XCTAssertNotNil(snapshot.line(label: "Usage Trend"))
    }

    /// Renders the spend tiles from each engine's scan. The audit called out that comparing
    /// `LogUsageScan` alone misses the UI contract; these are the `MetricLine`s the panel draws.
    private func spendLines(_ scan: OpenCodeUsageScan) -> [MetricLine] {
        var lines: [MetricLine] = []
        SpendTileMapper.appendTokenUsage(
            scan.logScan.series, to: &lines, now: now,
            estimated: scan.includesEstimatedCost,
            unknownModelsByDay: scan.logScan.unknownModelsByDay,
            modelUsage: scan.logScan.modelUsage,
            modelSourceNote: "From OpenCode logs",
            partialDays: scan.partialDays,
            apiEstimateByDay: scan.logScan.apiEstimateByDay,
            estimatedCostDays: scan.logScan.estimatedCostDays ?? []
        )
        SpendTileMapper.appendUsageTrend(
            scan.logScan.series, to: &lines, now: now,
            note: "From OpenCode logs", partialDays: scan.partialDays
        )
        return lines
    }

    @MainActor
    func testRenderedMetricLinesMatchSwiftOracle() async throws {
        let paths = try fixturePaths()
        let pricing = TestPricing.bundled
        let rustScan = try await hermeticScanner(paths: paths, engine: .rust).scan(
            now: now, pricing: pricing, gatewaySources: []
        )
        let oracleScan = try await hermeticScanner(paths: paths, engine: .sqliteCLI).scan(
            now: now, pricing: pricing, gatewaySources: []
        )
        let rust = try XCTUnwrap(rustScan)
        let oracle = try XCTUnwrap(oracleScan)
        XCTAssertEqual(spendLines(rust), spendLines(oracle))
        XCTAssertEqual(rust.logScan.unknownModelsByDay, oracle.logScan.unknownModelsByDay)
        XCTAssertEqual(rust.logScan.estimatedCostDays, oracle.logScan.estimatedCostDays)
    }

    /// The bridge reads the value straight out of the decoded envelope instead of re-encoding the
    /// result. That must not change what a query returns: exercise the edges SQLite can produce —
    /// unicode, quotes, backslashes, newlines, tabs, NULL and empty cells — on a WAL database, plus
    /// the error classification for a missing table, a corrupt file, and an unreadable file.
    func testQueryBridgeMatchesCLIOnEdgePayloads() throws {
        let path = try makeDatabase(
            """
            PRAGMA journal_mode=WAL;
            CREATE TABLE payloads(id INTEGER PRIMARY KEY, body TEXT);
            INSERT INTO payloads VALUES (1, 'héllo — 日本語 "quote" \\slash' || char(10) || 'line' || char(9) || 'tab');
            INSERT INTO payloads VALUES (2, '');
            INSERT INTO payloads VALUES (3, NULL);
            """
        )
        let sql = """
        SELECT json_group_array(json_object('id', id, 'body', body, 'null', NULL)) FROM payloads ORDER BY id;
        """
        let cli = try XCTUnwrap(try SQLiteCLIAccessor().queryValue(path: path, sql: sql))
        #if DEBUG
        let queriesBefore = OpenCodeRustScan.completedQueriesForTesting
        #endif
        let rust = try OpenCodeRustScan.query(path: path, sql: sql)
        #if DEBUG
        XCTAssertGreaterThan(
            OpenCodeRustScan.completedQueriesForTesting, queriesBefore,
            "the query never reached opencode.query"
        )
        #endif
        XCTAssertNil(rust.error)
        XCTAssertEqual(rust.value, cli)
        XCTAssertTrue(cli.contains("héllo"), "the fixture lost its unicode payload")

        let missingSQL = "SELECT * FROM missing_table;"
        XCTAssertTrue(try OpenCodeRustScan.query(path: path, sql: missingSQL).error?
            .contains("no such table") == true)
        XCTAssertThrowsError(try SQLiteCLIAccessor().queryValue(path: path, sql: missingSQL)) { error in
            XCTAssertTrue(error.localizedDescription.contains("no such table"))
        }

        let corrupt = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode-corrupt-\(UUID().uuidString).db").path
        try Data("not a database".utf8).write(to: URL(fileURLWithPath: corrupt))
        addTeardownBlock { try? FileManager.default.removeItem(atPath: corrupt) }
        let corruptSQL = "SELECT COUNT(*) FROM sqlite_master;"
        XCTAssertTrue(try OpenCodeRustScan.query(path: corrupt, sql: corruptSQL).error?
            .contains("not a database") == true)
        XCTAssertThrowsError(try SQLiteCLIAccessor().queryValue(path: corrupt, sql: corruptSQL)) { error in
            XCTAssertTrue(error.localizedDescription.contains("not a database"))
        }

        // A file the process cannot read is a failure, not an empty result. `chmod 000` is a no-op
        // for root, where the test cannot express the case.
        if geteuid() != 0 {
            let unreadable = try makeDatabase(legacyTable)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o000], ofItemAtPath: unreadable
            )
            addTeardownBlock {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: unreadable
                )
            }
            XCTAssertTrue(try OpenCodeRustScan.query(path: unreadable, sql: corruptSQL).error?
                .contains("unable to open database file") == true)
            XCTAssertThrowsError(try SQLiteCLIAccessor().queryValue(path: unreadable, sql: corruptSQL)) { error in
                XCTAssertTrue(error.localizedDescription.contains("unable to open database file"))
            }
        }
    }

    func testFutureTimestampRowsInvalidateBothEnginesAlike() async throws {
        let future = epochMs("2026-07-12T12:00:00.000Z") + 3_600_000
        let path = try makeDatabase(
            legacyTable
                + legacyRow(
                    id: "past", at: "2026-07-12T11:00:00.000Z", model: "glm-5.2",
                    provider: "opencode-go", cost: "2.0",
                    tokens: #"{"input":1000,"output":100}"#
                )
                + """
                INSERT INTO message (id,session_id,time_created,time_updated,data)
                VALUES ('future','ses_1',\(future),\(future),
                '{"role":"assistant","modelID":"glm-5.2","providerID":"opencode-go","cost":99.0,"tokens":{"input":1,"output":1}}');
                """
        )
        // A future row is not silently dropped: `parseRows` rejects the whole payload, so the scan
        // keeps the last-good snapshot instead of under- or over-reporting. Both engines must agree
        // on that outcome through the provider boundary.
        let rustScan = try? await hermeticScanner(paths: [path], engine: .rust).scan(
            now: now, gatewaySources: []
        )
        let oracleScan = try? await hermeticScanner(paths: [path], engine: .sqliteCLI).scan(
            now: now, gatewaySources: []
        )
        XCTAssertNil(rustScan)
        XCTAssertNil(oracleScan)
    }
}
