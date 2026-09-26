import XCTest
@testable import OpenUsage

final class CodexProxyUsageScannerTests: XCTestCase {
    private final class StubSQLite: SQLiteAccessing, @unchecked Sendable {
        let schema: String
        let payload: String
        var eventQuery: String?

        init(payload: String) {
            self.schema = [
                "request_id", "occurred_at", "local_day", "provider_id", "model", "wire_api",
                "status", "duration_ms", "input_tokens", "output_tokens",
                "cache_read_input_tokens", "cache_creation_input_tokens", "source",
                "account_fingerprint"
            ].enumerated().map { "\($0.offset)|\($0.element)|TEXT|1||0" }.joined(separator: "\n")
            self.payload = payload
        }

        func queryValue(path: String, sql: String) throws -> String? {
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
}
