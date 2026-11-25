import XCTest
@testable import QuotaBar

/// Compares the in-process Freebuff Desktop history fold with the `/usr/bin/sqlite3` oracle on the
/// same frozen project database. Opt-in because it builds large fixtures and runs both engines
/// three times:
///
/// ```sh
/// QUOTABAR_FREEBUFF_BENCH=1 swift test --filter FreebuffRustBenchmarkTests
/// ```
///
/// The measured span is one full local-history fold: SQLite read, receipt decode, and the priced
/// daily aggregate. Both engines run cold (fresh in-memory and disk caches) on every iteration, so
/// the number isolates the engine rather than a warm memo.
final class FreebuffRustBenchmarkTests: XCTestCase {
    private let now = OpenUsageISO8601.date(from: "2026-07-12T12:00:00.000Z")!

    private func makeStore(rows: Int) throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("freebuff-rust-bench-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.trashItem(at: directory, resultingItemURL: nil) }
        let path = directory.appendingPathComponent("desktop-v2.db").path
        let threads = max(1, rows / 10)
        let base = Int(now.addingTimeInterval(-1_800).timeIntervalSince1970 * 1_000)
        try SQLiteCLIAccessor().execute(path: path, sql: """
        CREATE TABLE threads(id TEXT PRIMARY KEY, model TEXT, harness_id TEXT, world_snapshot TEXT,
                             freebuff_instance_id TEXT, title TEXT, project_path TEXT);
        CREATE TABLE messages(thread_id TEXT, seq INTEGER, request_id TEXT, ts INTEGER,
                              metrics_json TEXT, role TEXT);
        CREATE TABLE auto_run_decision_receipts(id INTEGER PRIMARY KEY, thread_id TEXT,
                                                created_at INTEGER, manager_json TEXT);
        WITH RECURSIVE thread(i) AS (SELECT 0 UNION ALL SELECT i+1 FROM thread WHERE i < \(threads - 1))
        INSERT INTO threads SELECT 'thread-' || i, NULL, 'codebuff',
          '{"model":"vendor/model-' || (i % 7) || '"}', 'inst-' || (i % 50), 'Chat ' || i, '/work/' || i
          FROM thread;
        WITH RECURSIVE n(i) AS (SELECT 0 UNION ALL SELECT i+1 FROM n WHERE i < \(rows - 1))
        INSERT INTO messages
          SELECT 'thread-' || (i % \(threads)), i,
                 CASE WHEN i % 97 = 0 THEN 'cloud:run-' || i ELSE NULL END,
                 \(base) - (i % 30) * 86400000,
                 '{"usage":{"inputTokens":' || (100 + i % 900) || ',"outputTokens":' || (20 + i % 200)
                   || ',"cachedInputTokens":' || (i % 80) || '}}',
                 'assistant'
          FROM n;
        WITH RECURSIVE n(i) AS (SELECT 0 UNION ALL SELECT i+1 FROM n WHERE i < \(max(1, rows / 20) - 1))
        INSERT INTO auto_run_decision_receipts
          SELECT i, 'thread-' || (i % \(threads)), \(base) - (i % 30) * 86400000,
                 '{"harnessId":"codebuff","model":"vendor/model-' || (i % 7) || '","startedAt":'
                   || (\(base) - (i % 30) * 86400000) || ',"usage":{"inputTokens":30,"outputTokens":10}}'
          FROM n;
        """)
        return path
    }

    private func scanner(
        path: String,
        engine: FreebuffDesktopDatabaseEngine,
        runner: ProcessRunning
    ) -> FreebuffDesktopUsageScanner {
        let fallback = SQLiteCLIAccessor(processRunner: runner)
        let accessor: SQLiteAccessing = engine == .rust
            ? FreebuffDesktopDatabaseAccess(engine: .rust, sqlite: fallback)
            : fallback
        return FreebuffDesktopUsageScanner(
            sqlite: accessor,
            databasePaths: { [path] },
            sessionEndsPath: { nil }
        )
    }

    private func freshPersistenceDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("freebuff-bench-persistence-\(UUID().uuidString)", isDirectory: true)
    }

    private func timed(_ body: () async -> Void) async -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        await body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private func measure(rows: Int) async throws {
        let path = try makeStore(rows: rows)
        let cliRunner = FreebuffCountingProcessRunner()
        let rustRunner = FreebuffCountingProcessRunner()
        let initialPersistence = freshPersistenceDirectory()
        FreebuffDesktopTurnPersistence.directoryOverride = initialPersistence
        defer {
            FreebuffDesktopTurnPersistence.directoryOverride = nil
            try? FileManager.default.removeItem(at: initialPersistence)
        }

        let oracle = try await scanner(path: path, engine: .sqliteCLI, runner: cliRunner).scan(
            now: now, pricing: TestPricing.bundled, modelCatalog: [:]
        )
        let rust = try await scanner(path: path, engine: .rust, runner: rustRunner).scan(
            now: now, pricing: TestPricing.bundled, modelCatalog: [:]
        )
        XCTAssertNotNil(rust)
        XCTAssertEqual(rust?.usage, oracle?.usage)
        XCTAssertEqual(rust?.partialDays, oracle?.partialDays)
        XCTAssertFalse(rust?.usage.series.daily.isEmpty ?? true, "the benchmark fixture produced no usage")

        var rustTimes: [Double] = []
        var cliTimes: [Double] = []
        var firstRustSpawns = 0
        var firstCLISpawns = 0
        for iteration in 0..<3 {
            rustRunner.reset()
            cliRunner.reset()

            let rustPersistence = freshPersistenceDirectory()
            FreebuffDesktopTurnPersistence.directoryOverride = rustPersistence
            rustTimes.append(await timed {
                let scan = try? await scanner(path: path, engine: .rust, runner: rustRunner).scan(
                    now: now, pricing: TestPricing.bundled, modelCatalog: [:]
                )
                XCTAssertEqual(scan?.usage, oracle?.usage)
            })
            if iteration == 0 { firstRustSpawns = rustRunner.count }
            try? FileManager.default.removeItem(at: rustPersistence)

            let cliPersistence = freshPersistenceDirectory()
            FreebuffDesktopTurnPersistence.directoryOverride = cliPersistence
            cliTimes.append(await timed {
                let scan = try? await scanner(path: path, engine: .sqliteCLI, runner: cliRunner).scan(
                    now: now, pricing: TestPricing.bundled, modelCatalog: [:]
                )
                XCTAssertEqual(scan?.usage, oracle?.usage)
            })
            if iteration == 0 { firstCLISpawns = cliRunner.count }
            try? FileManager.default.removeItem(at: cliPersistence)
        }
        FreebuffDesktopTurnPersistence.directoryOverride = nil

        // The statement alone, with no decode or fold, so the engine delta is separable from the
        // Swift-side accounting cost that both engines pay.
        var rustQueryTimes: [Double] = []
        var cliQueryTimes: [Double] = []
        for _ in 0..<3 {
            rustQueryTimes.append(await timed {
                _ = try? FreebuffDesktopUsageSQL.readRows(
                    sqlite: FreebuffDesktopDatabaseAccess(engine: .rust), path: path
                )
            })
            cliQueryTimes.append(await timed {
                _ = try? FreebuffDesktopUsageSQL.readRows(sqlite: SQLiteCLIAccessor(), path: path)
            })
        }

        // The full statement payload through both decode strategies, so the single-pass field read
        // has a reproducible before/after on this provider's real shape.
        if let payload = try? FreebuffDesktopUsageSQL.readRows(
            sqlite: FreebuffDesktopDatabaseAccess(engine: .rust), path: path
        ) {
            let decode = try BridgeDecodeBenchmark.measure(payload: payload)
            print(
                "FREEBUFF_DECODE_BENCH rows=\(rows) payload_bytes=\(decode.payloadBytes)"
                    + " decode_old_ms=" + String(format: "%.1f", decode.oldMs)
                    + " decode_new_ms=" + String(format: "%.1f", decode.newMs)
            )
        }

        let rustMs = rustTimes.sorted()[1]
        let cliMs = cliTimes.sorted()[1]
        print(
            "FREEBUFF_SQLITE_BENCH cold=1 rows=\(rows) rust_ms="
                + String(format: "%.1f", rustMs)
                + " cli_ms=" + String(format: "%.1f", cliMs)
                + " speedup=" + String(format: "%.2f", cliMs / rustMs) + "x"
                + " spawns=\(firstCLISpawns)->\(firstRustSpawns)"
                + " rust_runs=\(rustTimes.map { String(format: "%.1f", $0) })"
                + " cli_runs=\(cliTimes.map { String(format: "%.1f", $0) })"
                + " query_rust_ms=" + String(format: "%.1f", rustQueryTimes.sorted()[1])
                + " query_cli_ms=" + String(format: "%.1f", cliQueryTimes.sorted()[1])
        )
    }

    func testFreebuffDatabaseBenchmark() async throws {
        guard ProcessInfo.processInfo.environment["QUOTABAR_FREEBUFF_BENCH"] == "1" else {
            throw XCTSkip("Set QUOTABAR_FREEBUFF_BENCH=1 to run the Freebuff Desktop database benchmark.")
        }
        try await measure(rows: 200)
        try await measure(rows: 10_000)
    }
}

private final class FreebuffCountingProcessRunner: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private let inner = SystemProcessRunner()
    private var spawnCount = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return spawnCount
    }

    func reset() {
        lock.lock()
        spawnCount = 0
        lock.unlock()
    }

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) throws -> ProcessResult {
        lock.lock()
        spawnCount += 1
        lock.unlock()
        return try inner.run(
            executable: executable,
            arguments: arguments,
            environment: environment,
            timeout: timeout
        )
    }

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        standardInput: Data?,
        timeout: TimeInterval
    ) throws -> ProcessResult {
        lock.lock()
        spawnCount += 1
        lock.unlock()
        return try inner.run(
            executable: executable,
            arguments: arguments,
            environment: environment,
            standardInput: standardInput,
            timeout: timeout
        )
    }
}
