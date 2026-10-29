import XCTest
@testable import QuotaBar

final class CodexProxyUsageScannerTests: XCTestCase {
    private final class StubSQLite: SQLiteAccessing, @unchecked Sendable {
        let schema: String
        let payload: String
        var failingPaths: Set<String>
        var eventQuery: String?

        init(payload: String, schema: String? = nil, failingPaths: Set<String> = []) {
            self.schema = schema ?? [
                "request_id", "occurred_at", "local_day", "provider_id", "model", "wire_api",
                "status", "duration_ms", "input_tokens", "output_tokens",
                "cache_read_input_tokens", "cache_creation_input_tokens", "source",
                "account_fingerprint"
            ].enumerated().map { "\($0.offset)|\($0.element)|TEXT|1||0" }.joined(separator: "\n")
            self.payload = payload
            self.failingPaths = failingPaths
        }

        func queryValue(path: String, sql: String) throws -> String? {
            if failingPaths.contains(path) { throw SQLiteError.queryFailed("database is locked") }
            if sql.hasPrefix("PRAGMA table_info") { return schema }
            eventQuery = sql
            return payload
        }

        func execute(path: String, sql: String) throws {}
    }

    private func pricing() -> ModelPricing {
        ModelPricing(
            supplement: PricingSupplement(),
            primary: PricingCatalog(entries: [
                "gpt-5.6-luna": ModelRates(
                    inputPerMillion: 1_000,
                    outputPerMillion: 3_000,
                    cacheWritePerMillion: 1_000,
                    cacheReadPerMillion: 100
                )
            ]),
            secondary: PricingCatalog(entries: [:])
        )
    }

    func testMatchesFCCAccountFingerprintAndPricesDisjointCounters() async throws {
        let accountID = "1118f6f1-8697-4e7b-9112-1771b3e36099"
        let expectedFingerprint = "acct_1257f3fe5af1"
        XCTAssertEqual(CodexProxyUsageScanner.accountFingerprint(for: accountID), expectedFingerprint)

        let sqlite = StubSQLite(payload: """
        [{"local_day":"2026-09-02","model":"openai/gpt-5.6-luna","input_tokens":100,"output_tokens":50,"cache_read_input_tokens":25,"cache_creation_input_tokens":5}]
        """)
        let scanner = CodexProxyUsageScanner(
            sqlite: sqlite,
            databasePaths: { ["/fcc/usage.db"] }
        )
        let now = OpenUsageISO8601.date(from: "2026-09-03T12:00:00.000Z")!

        let optionalScan = await scanner.scan(
            accountIdentityKey: accountID,
            daysBack: 30,
            now: now,
            pricing: pricing()
        )
        let scan = try XCTUnwrap(optionalScan)

        XCTAssertTrue(sqlite.eventQuery?.contains("account_fingerprint = '\(expectedFingerprint)'") == true)
        XCTAssertEqual(scan.series.daily, [
            DailyUsageEntry(date: "2026-09-02", totalTokens: 180, costUSD: 0.2575)
        ])
        XCTAssertEqual(scan.modelUsage?.daily.first?.models.first?.model, "openai/gpt-5.6-luna")
    }

    func testDoesNotQueryFCCWithoutAnIdentifiableAccount() async {
        let sqlite = StubSQLite(payload: "[]")
        let scanner = CodexProxyUsageScanner(
            sqlite: sqlite,
            databasePaths: { ["/fcc/usage.db"] }
        )

        let result = await scanner.scan(accountIdentityKey: nil, pricing: pricing())

        XCTAssertNil(result)
        XCTAssertNil(sqlite.eventQuery)
    }

    func testConfiguredDatabaseFailureDoesNotPublishRowsFromOtherDatabases() async {
        let sqlite = StubSQLite(
            payload: #"[{"local_day":"2026-09-02","model":"gpt-5.6-luna","input_tokens":100,"output_tokens":50,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}]"#,
            failingPaths: ["/fcc/locked.db"]
        )
        let scanner = CodexProxyUsageScanner(
            sqlite: sqlite,
            databasePaths: { ["/fcc/usage.db", "/fcc/locked.db"] }
        )

        guard case .incomplete = await scanner.scanResult(
            accountIdentityKey: "account-a", daysBack: 30, now: Date(), pricing: pricing()
        ) else {
            return XCTFail("one unreadable configured database must invalidate the multi-database scan")
        }
    }

    func testSchemaAndMalformedRowsMakeConfiguredScanIncomplete() async {
        let accountID = "account-a"
        let oldSchema = StubSQLite(payload: "[]", schema: "0|request_id|TEXT")
        let schemaScanner = CodexProxyUsageScanner(sqlite: oldSchema, databasePaths: { ["/fcc/old.db"] })
        guard case .incomplete = await schemaScanner.scanResult(
            accountIdentityKey: accountID, now: Date(), pricing: pricing()
        ) else {
            return XCTFail("a configured database with a missing required schema must be incomplete")
        }

        let malformedRows = StubSQLite(payload: #"[{"local_day":"2026-09-02","model":"gpt-5.6-luna","input_tokens":"bad","output_tokens":50,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}]"#)
        let rowScanner = CodexProxyUsageScanner(sqlite: malformedRows, databasePaths: { ["/fcc/malformed.db"] })
        guard case .incomplete = await rowScanner.scanResult(
            accountIdentityKey: accountID, now: Date(), pricing: pricing()
        ) else {
            return XCTFail("a malformed usage row must not be silently skipped")
        }
    }

    func testMissingImplicitDefaultDatabaseIsACompleteEmptySource() async {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("fcc-no-default-db-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let scanner = CodexProxyUsageScanner(
            environment: FakeEnvironment([:]),
            homeDirectory: { home },
            databasePaths: nil
        )
        guard case .complete(nil) = await scanner.scanResult(
            accountIdentityKey: "account-a", now: Date(), pricing: pricing()
        ) else {
            return XCTFail("the optional default FCC database may be absent before FCC is used")
        }
    }
}
