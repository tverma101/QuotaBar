import XCTest
@testable import QuotaBar

/// Compares the in-process OpenCode database read with the `/usr/bin/sqlite3` path on the same
/// fixtures. Opt-in because it builds several large databases and runs both engines repeatedly:
///
/// ```sh
/// QUOTABAR_OPENCODE_BENCH=1 swift test --filter OpenCodeRustBenchmarkTests
/// ```
final class OpenCodeRustBenchmarkTests: XCTestCase {
    private let databaseCount = 3
    private let now = OpenUsageISO8601.date(from: "2026-07-12T12:00:00.000Z")!

    private func makeDatabase(index: Int, rowsPerDatabase: Int) throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode-rust-bench-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.trashItem(at: directory, resultingItemURL: nil) }
        let path = directory.appendingPathComponent("opencode-\(index).db").path

        var statements = """
            CREATE TABLE message (
              id text PRIMARY KEY,
              session_id text NOT NULL,
              time_created integer NOT NULL,
              time_updated integer NOT NULL,
              data text NOT NULL
            );
            CREATE INDEX message_time_created_idx ON message (time_created);
            """
        statements.reserveCapacity(rowsPerDatabase * 220)
        let windowMs = 30 * 86_400_000
        for row in 0..<rowsPerDatabase {
            let ms = Int(now.timeIntervalSince1970 * 1000) - 3_600_000 - (row * windowMs / rowsPerDatabase)
            let provider = row % 3 == 0 ? "opencode" : "opencode-go"
            let model = ["glm-5.2", "gpt-5.5", "kimi-k2.6", "deepseek-v4-pro"][row % 4]
            let cost = row % 7 == 0 ? "null" : String(format: "%.4f", Double(row % 97) / 10)
            statements += """
                INSERT INTO message (id,session_id,time_created,time_updated,data) VALUES
                ('m\(index)-\(row)','ses_\(row / 20)',\(ms),\(ms),
                '{"role":"assistant","modelID":"\(model)","providerID":"\(provider)","cost":\(cost),"tokens":{"input":\(400 + row % 900),"output":\(100 + row % 300)}}');

                """
        }
        try SQLiteCLIAccessor().execute(path: path, sql: statements)
        return path
    }

    private func scanner(
        paths: [String],
        engine: OpenCodeDatabaseEngine,
        hermesPath: String? = nil
    ) -> OpenCodeUsageScanner {
        OpenCodeUsageScanner(
            sqlite: SQLiteCLIAccessor(),
            databaseEngine: engine,
            databasePaths: { paths },
            claudeRoots: { [] },
            codexHomes: { [] },
            hermesStateDBPath: { hermesPath },
            routerLedgerPaths: { [] },
            museRoots: { [] }
        )
    }

    /// A Hermes `sessions` fixture with rows billed to OpenCode. Used by the full-refresh benchmark
    /// so the gateway value query is included on both engines.
    private func makeHermesDatabase() throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode-rust-bench-hermes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.trashItem(at: directory, resultingItemURL: nil) }
        let path = directory.appendingPathComponent("state.db").path
        var statements = """
            CREATE TABLE sessions (
              id TEXT PRIMARY KEY, model TEXT, started_at REAL NOT NULL,
              billing_provider TEXT, billing_base_url TEXT,
              input_tokens INTEGER DEFAULT 0, output_tokens INTEGER DEFAULT 0,
              cache_read_tokens INTEGER DEFAULT 0, cache_write_tokens INTEGER DEFAULT 0,
              reasoning_tokens INTEGER DEFAULT 0, ended_at REAL
            );
            """
        for row in 0..<500 {
            let started = now.timeIntervalSince1970 - Double(row * 600)
            statements += """
                INSERT INTO sessions (id, model, started_at, billing_provider, billing_base_url,
                  input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, reasoning_tokens, ended_at)
                VALUES ('s\(row)', 'deepseek-v4-flash', \(started), 'opencode-go',
                  'https://opencode.ai/zen/go/v1', \(100 + row), 20, 500, 0, 0, \(started + 60));

                """
        }
        try SQLiteCLIAccessor().execute(path: path, sql: statements)
        return path
    }

    /// Move the file revision so the Rust memo is cold on the next read. The CLI oracle has no memo
    /// after the single-owner change, so this makes both engines perform probe + data + anchor. The
    /// touch runs outside the timed block and does not change database content.
    private func makeEnginesCold(_ paths: [String]) {
        for (index, path) in paths.enumerated() {
            let stamp = Date(timeIntervalSince1970: 1_000_000 + Double(index) + Double(coldTick))
            coldTick += 1
            try? FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: path)
        }
    }

    private var coldTick = 0

    private func timed(_ body: () async throws -> Void) async rethrows -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        try await body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private func measure(rowsPerDatabase: Int) async throws {
        let paths = try (0..<databaseCount).map {
            try makeDatabase(index: $0, rowsPerDatabase: rowsPerDatabase)
        }
        let cutoffMs = Int(now.addingTimeInterval(-30 * 86_400).timeIntervalSince1970 * 1000)
        let maximumTimestampMs = (now.timeIntervalSince1970 + 300) * 1000

        let rustAccess = OpenCodeDatabaseAccess(engine: .rust, sqlite: SQLiteCLIAccessor())
        func rustRead() async -> Int {
            let stage = await rustAccess.readMessageDatabases(
                paths: paths, cutoffMs: cutoffMs, maximumTimestampMs: maximumTimestampMs
            )
            XCTAssertTrue(stage?.failures.isEmpty == true)
            return stage?.rows.count ?? 0
        }
        func cliRead() async -> Int {
            let stage = await OpenCodeUsageScanner.readDatabasesViaCLI(
                paths: paths, cutoffMs: cutoffMs, maximumTimestampMs: maximumTimestampMs,
                sqlite: SQLiteCLIAccessor()
            )
            XCTAssertTrue(stage?.failures.isEmpty == true)
            return stage?.rows.count ?? 0
        }

        // Prove the reads agree, then make every timed iteration cold on both engines.
        let expectedRows = await cliRead()
        let warmRows = await rustRead()
        XCTAssertEqual(warmRows, expectedRows)
        XCTAssertGreaterThan(warmRows, 0)

        var rustTimes: [Double] = []
        var cliTimes: [Double] = []
        for _ in 0..<3 {
            makeEnginesCold(paths)
            rustTimes.append(try await timed {
                let rows = await rustRead()
                XCTAssertEqual(rows, expectedRows)
            })
            makeEnginesCold(paths)
            cliTimes.append(try await timed {
                let rows = await cliRead()
                XCTAssertEqual(rows, expectedRows)
            })
        }
        let rust = rustTimes.sorted()[1]
        let cli = cliTimes.sorted()[1]

        // Same payload, both decode strategies: the bridge's previous result round-trip and the
        // current single-pass field read. This isolates the decode change from SQL and engine cost.
        let dataSQL = OpenCodeDatabaseSQL.dataSQL(cutoffMs: cutoffMs, schema: .legacy)
        let payload = try XCTUnwrap(
            try OpenCodeRustScan.query(path: paths[0], sql: dataSQL).value
        )
        let decode = try BridgeDecodeBenchmark.measure(payload: payload)

        print(
            "OPENCODE_SQLITE_BENCH cold=1 rows=\(rowsPerDatabase * databaseCount) "
                + "databases=\(databaseCount) spawns=\(databaseCount * 3)->0 "
                + "rust_ms=\(String(format: "%.1f", rust)) cli_ms=\(String(format: "%.1f", cli)) "
                + "speedup=\(String(format: "%.2f", cli / rust))x "
                + "rust_runs=\(rustTimes.map { String(format: "%.1f", $0) }) "
                + "cli_runs=\(cliTimes.map { String(format: "%.1f", $0) })"
                + " payload_bytes=\(decode.payloadBytes)"
                + " decode_old_ms=\(String(format: "%.1f", decode.oldMs))"
                + " decode_new_ms=\(String(format: "%.1f", decode.newMs))"
        )
    }

    func testOpenCodeRefreshBenchmark() async throws {
        guard ProcessInfo.processInfo.environment["QUOTABAR_OPENCODE_BENCH"] == "1" else {
            throw XCTSkip("Set QUOTABAR_OPENCODE_BENCH=1 to run the OpenCode database benchmark.")
        }
        let rowsPerDatabase = 10_000
        let paths = try (0..<databaseCount).map {
            try makeDatabase(index: $0, rowsPerDatabase: rowsPerDatabase)
        }
        let hermes = try makeHermesDatabase()
        let rustScanner = scanner(paths: paths, engine: .rust, hermesPath: hermes)
        let cliScanner = scanner(paths: paths, engine: .sqliteCLI, hermesPath: hermes)

        // Warm both engines and prove the complete refreshes agree.
        let oracle = try await cliScanner.scan(
            now: now, pricing: TestPricing.bundled, gatewaySources: [.hermes]
        )
        let rust = try await rustScanner.scan(
            now: now, pricing: TestPricing.bundled, gatewaySources: [.hermes]
        )
        XCTAssertEqual(rust?.logScan, oracle?.logScan)
        XCTAssertNotNil(rust)

        var rustTimes: [Double] = []
        var cliTimes: [Double] = []
        let coldPaths = paths + [hermes]
        for _ in 0..<3 {
            makeEnginesCold(coldPaths)
            rustTimes.append(try await timed {
                let scan = try await rustScanner.scan(
                    now: now, pricing: TestPricing.bundled, gatewaySources: [.hermes]
                )
                XCTAssertEqual(scan?.logScan, oracle?.logScan)
            })
            makeEnginesCold(coldPaths)
            cliTimes.append(try await timed {
                let scan = try await cliScanner.scan(
                    now: now, pricing: TestPricing.bundled, gatewaySources: [.hermes]
                )
                XCTAssertEqual(scan?.logScan, oracle?.logScan)
            })
        }
        let rustTime = rustTimes.sorted()[1]
        let cliTime = cliTimes.sorted()[1]
        let scanSpawns = databaseCount * 3 + 1
        print(
            "OPENCODE_REFRESH_BENCH cold=1 rows=\(10_000 * databaseCount) "
                + "databases=\(databaseCount) scan_spawns=\(scanSpawns)->0 "
                + "rust_ms=\(String(format: "%.1f", rustTime)) cli_ms=\(String(format: "%.1f", cliTime)) "
                + "speedup=\(String(format: "%.2f", cliTime / rustTime))x "
                + "rust_runs=\(rustTimes.map { String(format: "%.1f", $0) }) "
                + "cli_runs=\(cliTimes.map { String(format: "%.1f", $0) })"
        )
    }

    func testOpenCodeDatabaseReadBenchmark() async throws {
        guard ProcessInfo.processInfo.environment["QUOTABAR_OPENCODE_BENCH"] == "1" else {
            throw XCTSkip("Set QUOTABAR_OPENCODE_BENCH=1 to run the OpenCode database benchmark.")
        }
        try await measure(rowsPerDatabase: 200)
        try await measure(rowsPerDatabase: 10_000)
    }
}
