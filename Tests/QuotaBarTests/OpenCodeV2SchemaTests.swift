import XCTest
@testable import QuotaBar

/// OpenCode 2 moved the session store: v1 kept one row per turn in `message` (the role inside the
/// JSON `data` blob), v2 keeps them in `session_message` (the role in the `type` column, the model
/// nested under `$.model`). The v1→v2 migration copies each old session into `session_v2` under the
/// same id and rewrites its turns into `session_message`, so a store mid-migration holds both tables.
///
/// These tests run against REAL SQLite databases (not a stubbed accessor), so the queries, the
/// schema detection and the accounting rules are exercised end to end.
final class OpenCodeV2SchemaTests: XCTestCase {
    private let now = OpenUsageISO8601.date(from: "2026-07-12T12:00:00.000Z")!

    private func epochMs(_ iso: String) -> Int {
        Int(OpenUsageISO8601.date(from: iso)!.timeIntervalSince1970 * 1000)
    }

    // MARK: - Fixtures

    private let v2TableSQL = """
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

    private let legacyTableSQL = """
        CREATE TABLE message (
          id text PRIMARY KEY,
          session_id text NOT NULL,
          time_created integer NOT NULL,
          time_updated integer NOT NULL,
          data text NOT NULL
        );
        CREATE TABLE part (
          id text PRIMARY KEY,
          message_id text NOT NULL,
          session_id text NOT NULL,
          time_created integer NOT NULL,
          time_updated integer NOT NULL,
          data text NOT NULL
        );
        CREATE TABLE session (
          id text PRIMARY KEY,
          project_id text NOT NULL,
          time_created integer NOT NULL,
          time_updated integer NOT NULL,
          data text NOT NULL
        );
        """

    /// A v2 assistant turn: the role is the `type` column and the model is nested under `$.model`.
    private func v2Row(id: String, at iso: String, model: String, provider: String, cost: String, tokens: String) -> String {
        """
        INSERT INTO session_message (id,session_id,type,seq,time_created,time_updated,data)
        VALUES ('\(id)','ses_1','assistant',1,\(epochMs(iso)),\(epochMs(iso)),
        '{"model":{"id":"\(model)","providerID":"\(provider)"},"cost":\(cost),"tokens":\(tokens)}');
        """
    }

    /// A v1 assistant turn: the role and the model live inside the JSON blob.
    private func legacyRow(id: String, at iso: String, model: String, provider: String, cost: String, tokens: String) -> String {
        """
        INSERT INTO message (id,session_id,time_created,time_updated,data)
        VALUES ('\(id)','ses_1',\(epochMs(iso)),\(epochMs(iso)),
        '{"role":"assistant","modelID":"\(model)","providerID":"\(provider)","cost":\(cost),"tokens":\(tokens)}');
        """
    }

    private func makeDatabase(_ statements: String) throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode-v2-schema-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.trashItem(at: directory, resultingItemURL: nil) }
        let path = directory.appendingPathComponent("opencode.db").path
        try SQLiteCLIAccessor().execute(path: path, sql: statements)
        return path
    }

    private func scanner(path: String) -> OpenCodeUsageScanner {
        OpenCodeUsageScanner(sqlite: SQLiteCLIAccessor(), databasePaths: { [path] })
    }

    /// A scan with every gateway source switched off: these tests are about the database layer, so
    /// nothing outside the fixture may contribute.
    private func scan(_ path: String) async throws -> OpenCodeUsageScan {
        let scan = try await scanner(path: path).scan(now: now, gatewaySources: [])
        return try XCTUnwrap(scan, "expected a scan")
    }

    private func totalTokens(_ scan: OpenCodeUsageScan) -> Int {
        scan.logScan.series.daily.reduce(0) { $0 + $1.totalTokens }
    }

    private func totalCost(_ scan: OpenCodeUsageScan) -> Double {
        scan.logScan.series.daily.compactMap(\.costUSD).reduce(0, +)
    }

    private func modelRow(_ scan: OpenCodeUsageScan, _ model: String) -> ModelUsageEntry? {
        scan.logScan.modelUsage?.daily
            .flatMap(\.models)
            .first { $0.model == model }
    }

    // MARK: - Layout detection

    func testSchemaDetectionClassifiesTheMessageTables() {
        XCTAssertEqual(OpenCodeDatabaseSchemaProbe.schema(fromProbeOutput: "message"), .legacy)
        XCTAssertEqual(OpenCodeDatabaseSchemaProbe.schema(fromProbeOutput: "session_message"), .v2)
        XCTAssertEqual(
            OpenCodeDatabaseSchemaProbe.schema(fromProbeOutput: "session_message,message"),
            .mixed
        )
        XCTAssertEqual(OpenCodeDatabaseSchemaProbe.schema(fromProbeOutput: nil), .unknown)
        XCTAssertEqual(OpenCodeDatabaseSchemaProbe.schema(fromProbeOutput: "other_table"), .unknown)
    }

    func testProbeDetectsTheLayoutOfEachDatabase() throws {
        let v2 = try makeDatabase(v2TableSQL)
        let legacy = try makeDatabase(legacyTableSQL)
        let mixed = try makeDatabase(v2TableSQL + legacyTableSQL)

        let accessor = SQLiteCLIAccessor()
        XCTAssertEqual(try OpenCodeDatabaseSchemaProbe.detect(sqlite: accessor, path: v2), .v2)
        XCTAssertEqual(try OpenCodeDatabaseSchemaProbe.detect(sqlite: accessor, path: legacy), .legacy)
        XCTAssertEqual(try OpenCodeDatabaseSchemaProbe.detect(sqlite: accessor, path: mixed), .mixed)
    }

    // MARK: - Reading each layout

    func testV2OnlyDatabaseReadsHostedUsage() async throws {
        let path = try makeDatabase(v2TableSQL + v2Row(
            id: "msg_1", at: "2026-07-12T10:00:00.000Z", model: "glm-5.2", provider: "opencode-go",
            cost: "1.25", tokens: "{\"input\":100,\"output\":50}"
        ))

        let scan = try await scan(path)
        XCTAssertEqual(totalTokens(scan), 150)
        XCTAssertEqual(totalCost(scan), 1.25, accuracy: 0.0001)
        XCTAssertEqual(modelRow(scan, "glm-5.2")?.totalTokens, 150)
    }

    func testEmptyLegacyTablesWithPopulatedV2StillReadUsage() async throws {
        // The shape a migrated store has: the v1 tables are still there but empty, every turn lives
        // in `session_message`.
        let path = try makeDatabase(v2TableSQL + legacyTableSQL + v2Row(
            id: "msg_1", at: "2026-07-12T10:00:00.000Z", model: "glm-5.2", provider: "opencode-go",
            cost: "2.0", tokens: "{\"input\":40,\"output\":10}"
        ))

        let scan = try await scan(path)
        XCTAssertEqual(totalTokens(scan), 50)
        XCTAssertEqual(totalCost(scan), 2.0, accuracy: 0.0001)
    }

    func testLegacyOnlyDatabaseStillReadsUsage() async throws {
        let path = try makeDatabase(legacyTableSQL + legacyRow(
            id: "msg_1", at: "2026-07-12T10:00:00.000Z", model: "gpt-5.5", provider: "opencode",
            cost: "3.5", tokens: "{\"input\":10,\"output\":20,\"total\":35}"
        ))

        let scan = try await scan(path)
        XCTAssertEqual(totalTokens(scan), 35)
        XCTAssertEqual(totalCost(scan), 3.5, accuracy: 0.0001)
    }

    func testMixedSchemaCountsAMigratedMessageOnce() async throws {
        // The v1→v2 migration copies a turn under the SAME message id, so a store mid-migration
        // holds it twice. The v2 copy is the one OpenCode keeps writing, so it wins and the usage
        // is counted once.
        let path = try makeDatabase(
            v2TableSQL + legacyTableSQL
                + v2Row(
                    id: "msg_shared", at: "2026-07-12T10:00:00.000Z", model: "glm-5.2",
                    provider: "opencode-go", cost: "2.0", tokens: "{\"input\":100,\"output\":50}"
                )
                + legacyRow(
                    id: "msg_shared", at: "2026-07-12T10:00:00.000Z", model: "glm-5.2",
                    provider: "opencode-go", cost: "2.0", tokens: "{\"input\":100,\"output\":50,\"total\":150}"
                )
        )

        let scan = try await scan(path)
        XCTAssertEqual(totalTokens(scan), 150, "the migrated turn must be counted once, not twice")
        XCTAssertEqual(totalCost(scan), 2.0, accuracy: 0.0001)
    }

    func testMixedSchemaKeepsLegacyOnlyMessages() async throws {
        // A session the migration has not reached yet still lives only in `message`.
        let path = try makeDatabase(
            v2TableSQL + legacyTableSQL
                + v2Row(
                    id: "msg_v2", at: "2026-07-12T10:00:00.000Z", model: "glm-5.2",
                    provider: "opencode-go", cost: "2.0", tokens: "{\"input\":100,\"output\":50}"
                )
                + legacyRow(
                    id: "msg_legacy", at: "2026-07-12T11:00:00.000Z", model: "kimi-k2.6",
                    provider: "opencode-go", cost: "1.0", tokens: "{\"input\":10,\"output\":10,\"total\":20}"
                )
        )

        let scan = try await scan(path)
        XCTAssertEqual(totalTokens(scan), 170)
        XCTAssertEqual(totalCost(scan), 3.0, accuracy: 0.0001)
        XCTAssertEqual(modelRow(scan, "kimi-k2.6")?.totalTokens, 20)
        XCTAssertEqual(modelRow(scan, "glm-5.2")?.totalTokens, 150)
    }

    func testUnmigratedProviderRowsStayOutOfTheTotals() async throws {
        // A turn from another provider is not OpenCode-hosted usage, in either layout.
        let path = try makeDatabase(
            v2TableSQL + v2Row(
                id: "msg_1", at: "2026-07-12T10:00:00.000Z", model: "claude", provider: "anthropic",
                cost: "9.0", tokens: "{\"input\":5,\"output\":5}"
            )
        )

        let scan = try await scan(path)
        XCTAssertEqual(totalTokens(scan), 0)
        XCTAssertEqual(totalCost(scan), 0)
    }

    // MARK: - Anchor and probe parity

    func testAnchorQueryReadsTheDetectedLayout() throws {
        let v2 = try makeDatabase(v2TableSQL + v2Row(
            id: "msg_1", at: "2026-07-01T00:00:00.000Z", model: "glm-5.2", provider: "opencode-go",
            cost: "1.0", tokens: "{\"input\":10,\"output\":10}"
        ))
        let legacy = try makeDatabase(legacyTableSQL + legacyRow(
            id: "msg_1", at: "2026-06-01T00:00:00.000Z", model: "glm-5.2", provider: "opencode-go",
            cost: "1.0", tokens: "{\"input\":10,\"output\":10}"
        ))
        let mixed = try makeDatabase(
            v2TableSQL + legacyTableSQL
                + v2Row(
                    id: "msg_v2", at: "2026-07-05T00:00:00.000Z", model: "glm-5.2",
                    provider: "opencode-go", cost: "1.0", tokens: "{\"input\":10,\"output\":10}"
                )
                + legacyRow(
                    id: "msg_legacy", at: "2026-06-15T00:00:00.000Z", model: "glm-5.2",
                    provider: "opencode-go", cost: "1.0", tokens: "{\"input\":10,\"output\":10}"
                )
        )

        let accessor = SQLiteCLIAccessor()
        let v2Schema = try OpenCodeDatabaseSchemaProbe.detect(sqlite: accessor, path: v2)
        let legacySchema = try OpenCodeDatabaseSchemaProbe.detect(sqlite: accessor, path: legacy)
        let mixedSchema = try OpenCodeDatabaseSchemaProbe.detect(sqlite: accessor, path: mixed)

        let v2Anchor = try accessor.queryValue(path: v2, sql: OpenCodeDatabaseSQL.anchorSQL(schema: v2Schema))
        let legacyAnchor = try accessor.queryValue(path: legacy, sql: OpenCodeDatabaseSQL.anchorSQL(schema: legacySchema))
        let mixedAnchor = try accessor.queryValue(path: mixed, sql: OpenCodeDatabaseSQL.anchorSQL(schema: mixedSchema))

        XCTAssertEqual(v2Anchor, "\(epochMs("2026-07-01T00:00:00.000Z"))")
        XCTAssertEqual(legacyAnchor, "\(epochMs("2026-06-01T00:00:00.000Z"))")
        XCTAssertEqual(mixedAnchor, "\(epochMs("2026-06-15T00:00:00.000Z"))")
    }

    func testProbeAndAnchorAgreeOnTheSameLayout() throws {
        // A Go turn: both the probe and the anchor must find it.
        let go = try makeDatabase(v2TableSQL + v2Row(
            id: "msg_1", at: "2026-07-01T00:00:00.000Z", model: "glm-5.2", provider: "opencode-go",
            cost: "1.0", tokens: "{\"input\":10,\"output\":10}"
        ))
        // A Zen-only turn: the probe sees hosted usage, the Go anchor does not.
        let zen = try makeDatabase(v2TableSQL + v2Row(
            id: "msg_1", at: "2026-07-01T00:00:00.000Z", model: "glm-5.2", provider: "opencode",
            cost: "1.0", tokens: "{\"input\":10,\"output\":10}"
        ))

        XCTAssertTrue(scanner(path: go).hasHostedUsage())
        XCTAssertTrue(scanner(path: zen).hasHostedUsage())

        let accessor = SQLiteCLIAccessor()
        let zenSchema = try OpenCodeDatabaseSchemaProbe.detect(sqlite: accessor, path: zen)
        let zenAnchor = try accessor.queryValue(path: zen, sql: OpenCodeDatabaseSQL.anchorSQL(schema: zenSchema))
        XCTAssertNil(zenAnchor, "a Zen-only database has no Go usage to anchor the monthly cycle")
    }

    func testProbeReportsNoUsageForAnEmptyDatabase() throws {
        let path = try makeDatabase(v2TableSQL + legacyTableSQL)
        XCTAssertFalse(scanner(path: path).hasHostedUsage())
    }

    // MARK: - Accounting rules

    func testProviderReportedZeroCostIsPreserved() async throws {
        // A free model the provider bills at $0: the recorded zero is the cost, not a missing cost.
        // It must not become an estimate, an unknown model, or a priced guess.
        let path = try makeDatabase(v2TableSQL + v2Row(
            id: "msg_1", at: "2026-07-12T10:00:00.000Z", model: "minimax-m3.1-flash-free",
            provider: "opencode", cost: "0", tokens: "{\"input\":16843,\"output\":123,\"reasoning\":0,\"cache\":{\"read\":729,\"write\":0}}"
        ))

        let scan = try await scan(path)
        XCTAssertEqual(totalTokens(scan), 17695)
        XCTAssertEqual(totalCost(scan), 0, "the provider's recorded $0 stays $0")

        let model = try XCTUnwrap(modelRow(scan, "minimax-m3.1-flash-free"))
        XCTAssertEqual(model.totalTokens, 17695)
        XCTAssertEqual(model.costUSD ?? -1, 0, accuracy: 0.0001, "a recorded $0 is not a missing cost")
        XCTAssertNil(model.costIsComplete == false ? true : nil, "a recorded $0 is a complete cost")

        let day = try XCTUnwrap(scan.logScan.series.daily.first)
        XCTAssertEqual(day.costUSD ?? -1, 0, accuracy: 0.0001)
        XCTAssertTrue(day.costIsComplete)
        XCTAssertTrue((scan.logScan.unknownModelsByDay[day.date] ?? []).isEmpty, "a recorded cost is never an unknown model")
        XCTAssertNil(scan.logScan.estimatedCostDays, "a recorded cost is never an estimate")
    }

    func testMalformedTokenAccountingIsRejectedInTheV2Layout() async throws {
        let path = try makeDatabase(v2TableSQL + v2Row(
            id: "msg_1", at: "2026-07-12T10:00:00.000Z", model: "glm-5.2", provider: "opencode-go",
            cost: "1.0", tokens: "{\"input\":-5,\"output\":10}"
        ))

        do {
            _ = try await scan(path)
            XCTFail("malformed token accounting must keep the last complete history")
        } catch {
            XCTAssertEqual(error as? OpenCodeUsageError, .databaseUnreadable)
        }
    }

    func testV2MissingCostKeepsMeasuredTokensAsIncompleteCost() async throws {
        let path = try makeDatabase(v2TableSQL + v2Row(
            id: "unpriced", at: "2026-07-12T10:00:00Z", model: "unknown-model", provider: "opencode",
            cost: "null", tokens: "{\"input\":10,\"output\":5}"
        ))
        let result = try await scan(path)
        XCTAssertEqual(totalTokens(result), 15)
        XCTAssertFalse(try XCTUnwrap(result.logScan.series.daily.first).costIsComplete)
    }

    func testMalformedTokenAccountingIsRejectedInTheLegacyLayout() async throws {
        let path = try makeDatabase(legacyTableSQL + legacyRow(
            id: "msg_1", at: "2026-07-12T10:00:00.000Z", model: "glm-5.2", provider: "opencode-go",
            cost: "1.0", tokens: "{\"input\":10,\"output\":-5}"
        ))

        do {
            _ = try await scan(path)
            XCTFail("malformed token accounting must keep the last complete history")
        } catch {
            XCTAssertEqual(error as? OpenCodeUsageError, .databaseUnreadable)
        }
    }

    func testV2TurnWithoutATokenObjectCarriesNoUsage() async throws {
        // A turn that errored before the provider answered records neither tokens nor cost. It is
        // not malformed accounting, and it must not fail the whole scan.
        let path = try makeDatabase(
            v2TableSQL
                + v2Row(
                    id: "msg_1", at: "2026-07-12T10:00:00.000Z", model: "glm-5.2",
                    provider: "opencode-go", cost: "1.0", tokens: "{\"input\":10,\"output\":5}"
                )
                + v2Row(
                    id: "msg_2", at: "2026-07-12T11:00:00.000Z", model: "glm-5.2",
                    provider: "opencode-go", cost: "null", tokens: "null"
                )
        )

        let scan = try await scan(path)
        XCTAssertEqual(totalTokens(scan), 15)
        XCTAssertEqual(totalCost(scan), 1.0, accuracy: 0.0001)
    }
}
