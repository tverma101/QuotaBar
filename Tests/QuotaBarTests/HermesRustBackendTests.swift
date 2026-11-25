import XCTest
@testable import QuotaBar

/// Exercises the Rust provider backend through the real boundary: the JSON envelope and C ABI,
/// then the same `HermesUsageScanner` and `ProviderRuntime.refresh()` calls production makes.
final class HermesRustBackendTests: XCTestCase {
    private var directory: URL!
    private var databasePath: String!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("quotabar-hermes-rust-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        databasePath = directory.appendingPathComponent("state.db").path
        try createSchema()
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        directory = nil
        databasePath = nil
        try super.tearDownWithError()
    }

    // MARK: - Boundary

    func testBackendEnvelopeReportsTypedErrors() {
        XCTAssertEqual(RustBackend.abiVersion, 3)
        XCTAssertThrowsError(try RustBackend.call(op: "nope", params: [:])) { error in
            XCTAssertEqual((error as? RustBackend.BackendError)?.kind, "unknown_operation")
        }
    }

    // MARK: - Parity

    func testRustAndSwiftScansAgreeOnTheSameDatabase() async throws {
        let now = Date(timeIntervalSince1970: 1_784_800_000)
        try insertMixedCorpus(now: now)

        let rustScan = try await scanner(engine: .rust).scan(now: now)
        let swiftScan = try await scanner(engine: .swift).scan(now: now)
        let rust = try XCTUnwrap(rustScan)
        let swift = try XCTUnwrap(swiftScan)

        XCTAssertEqual(rust.periods, swift.periods)
        XCTAssertEqual(rust.partialDays, swift.partialDays)
        XCTAssertEqual(rust.modelUsageByPeriod, swift.modelUsageByPeriod)
        XCTAssertEqual(
            rust.daily.daily.sorted { $0.date < $1.date },
            swift.daily.daily.sorted { $0.date < $1.date }
        )
        // The rendered rows are the contract the UI consumes, so pin them too.
        XCTAssertEqual(
            HermesUsageMapper.lines(scan: rust, now: now),
            HermesUsageMapper.lines(scan: swift, now: now)
        )
    }

    // MARK: - ProviderRuntime contract

    @MainActor
    func testProviderRefreshReturnsRenderedSnapshotThroughRust() async throws {
        let now = Date(timeIntervalSince1970: 1_784_800_000)
        try insertMixedCorpus(now: now)

        let provider = HermesProvider(
            usageScanner: scanner(engine: .rust),
            now: { now }
        )
        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.providerID, "hermes")
        XCTAssertEqual(snapshot.displayName, "Hermes")
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.lines.map(\.label), ["Today", "This Week", "This Month", "Usage Trend"])

        guard case .values(let label, let values, _, _, _, let breakdown)? = snapshot.lines.first else {
            return XCTFail("expected the Today spend row first")
        }
        XCTAssertEqual(label, "Today")
        XCTAssertEqual(values.map(\.kind), [.dollars, .count])
        // Priced recent session plus the cost-only session; the OpenCode-billed row belongs to
        // OpenCode's spend instead.
        XCTAssertEqual(values[0].number, 0.67, accuracy: 0.0001)
        XCTAssertTrue(values[0].estimated)
        XCTAssertTrue(values[0].isPartial == true)
        XCTAssertEqual(values[1].number, 9_250)
        XCTAssertEqual(breakdown?.models.first?.model, "kimi/kimi-k2.7")

        let todayKey = DailyUsageAccumulator.dayKey(from: now)
        let ancientKey = DailyUsageAccumulator.dayKey(from: now.addingTimeInterval(-45 * 86_400))
        let history = try XCTUnwrap(snapshot.usageHistory)
        XCTAssertEqual(history.series.daily.reduce(0) { $0 + $1.totalTokens }, 9_250 + 9_900)
        XCTAssertEqual(history.apiEstimateIncompleteDays ?? [], Set([todayKey, ancientKey]))
        XCTAssertEqual(history.partialDays ?? [], Set([todayKey]))
    }

    @MainActor
    func testProviderRefreshSurfacesUnreadableDatabaseAsAnErrorSnapshot() async throws {
        try Data("not a sqlite database".utf8).write(to: URL(fileURLWithPath: databasePath))

        let provider = HermesProvider(usageScanner: scanner(engine: .rust))
        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .credentialAccess)
        XCTAssertEqual(snapshot.lines.map(\.label), [MetricLine.errorBadgeLabel])
    }

    @MainActor
    func testMissingDatabaseStillReportsNotDetected() async throws {
        let provider = HermesProvider(
            usageScanner: HermesUsageScanner(databasePaths: { [] }, engine: .rust)
        )
        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
    }

    // MARK: - Fixtures

    private func scanner(engine: HermesScanEngine) -> HermesUsageScanner {
        let path = databasePath!
        return HermesUsageScanner(databasePaths: { [path] }, engine: engine)
    }

    private func createSchema() throws {
        try sqlite("""
            CREATE TABLE sessions (
                id TEXT PRIMARY KEY,
                model TEXT,
                started_at REAL NOT NULL,
                ended_at REAL DEFAULT 0,
                input_tokens INTEGER DEFAULT 0,
                output_tokens INTEGER DEFAULT 0,
                cache_read_tokens INTEGER DEFAULT 0,
                cache_write_tokens INTEGER DEFAULT 0,
                reasoning_tokens INTEGER DEFAULT 0,
                api_call_count INTEGER DEFAULT 0,
                estimated_cost_usd REAL DEFAULT 0,
                billing_provider TEXT,
                billing_base_url TEXT
            );
            CREATE TABLE session_model_usage (
                session_id TEXT NOT NULL,
                model TEXT NOT NULL,
                input_tokens INTEGER DEFAULT 0,
                output_tokens INTEGER DEFAULT 0,
                cache_read_tokens INTEGER DEFAULT 0,
                cache_write_tokens INTEGER DEFAULT 0,
                reasoning_tokens INTEGER DEFAULT 0,
                estimated_cost_usd REAL DEFAULT 0
            );
            """)
    }

    /// One corpus covering every aggregation branch: a priced recent session (with an active
    /// session making today partial), an OpenCode-billed row, a cost-only row, an ancient row
    /// outside every period, and an attribution-table row.
    private func insertMixedCorpus(now: Date) throws {
        let recent = now.timeIntervalSince1970 - 3_600
        let ancient = now.timeIntervalSince1970 - 45 * 86_400
        try sqlite("""
            INSERT INTO sessions (id, model, started_at, ended_at, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, reasoning_tokens, api_call_count, estimated_cost_usd, billing_provider, billing_base_url) VALUES
              ('recent', 'kimi/kimi-k2.7', \(recent), NULL, 1000, 200, 8000, 0, 50, 12, 0.42, 'anthropic', 'https://api.anthropic.com'),
              ('gateway', 'deepseek-v4-flash', \(recent + 1), \(recent + 2), 500, 60, 0, 0, 0, 3, 0.75, 'opencode-go', 'https://opencode.ai/zen/go/v1'),
              ('cost-only', 'unattributed', \(recent + 2), \(recent + 3), 0, 0, 0, 0, 0, 1, 0.25, NULL, NULL),
              ('ancient', 'glm/glm-5', \(ancient), \(ancient + 5), 9000, 900, 0, 0, 0, 99, 9.99, NULL, NULL);
            INSERT INTO session_model_usage (session_id, model, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, reasoning_tokens, estimated_cost_usd) VALUES
              ('recent', 'kimi/kimi-k2.7', 1000, 200, 8000, 0, 50, 0.42),
              ('recent', 'deepseek/deepseek-v4-flash', 300, 100, 0, 0, 10, 0.05),
              ('gateway', 'deepseek-v4-flash', 500, 60, 0, 0, 0, 0.75),
              ('cost-only', 'unattributed', 0, 0, 0, 0, 0, 0.25);
            """)
    }

    @discardableResult
    private func sqlite(_ sql: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [databasePath, sql]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
}
