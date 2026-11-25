import XCTest
@testable import QuotaBar

/// Compares the in-process Antigravity fraction of a refresh with the `/usr/bin/sqlite3` oracle on
/// the same frozen database. Opt-in because it builds large fixtures and runs both engines three
/// times:
///
/// ```sh
/// QUOTABAR_ANTIGRAVITY_BENCH=1 swift test --filter AntigravityRustBenchmarkTests
/// ```
final class AntigravityRustBenchmarkTests: XCTestCase {
    private let now = OpenUsageISO8601.date(from: "2026-07-12T12:00:00.000Z")!

    private func antigravityVarint(_ value: UInt64) -> [UInt8] {
        var remaining = value
        var encoded: [UInt8] = []
        repeat {
            var byte = UInt8(remaining & 0x7f)
            remaining >>= 7
            if remaining != 0 { byte |= 0x80 }
            encoded.append(byte)
        } while remaining != 0
        return encoded
    }

    private func varintField(_ number: UInt32, _ value: UInt64) -> [UInt8] {
        antigravityVarint(UInt64(number) << 3) + antigravityVarint(value)
    }

    private func bytesField(_ number: UInt32, _ bytes: [UInt8]) -> [UInt8] {
        antigravityVarint(UInt64(number) << 3 | 2) + antigravityVarint(UInt64(bytes.count)) + bytes
    }

    private enum StoreShape: String {
        case legacy
        case modern
    }

    private func generationBlob(
        model: String,
        input: UInt64,
        output: UInt64,
        timestamp: UInt64?,
        stepUUID: String? = nil,
        botID: String? = nil
    ) -> [UInt8] {
        var usage = varintField(1, 0) + varintField(2, input) + varintField(3, output)
        if let botID { usage += bytesField(7, Array(botID.utf8)) }
        var event = bytesField(19, Array(model.utf8)) + bytesField(4, usage)
        if let timestamp {
            event += bytesField(9, bytesField(4, varintField(1, timestamp)))
        }
        var generation = bytesField(1, event)
        if let stepUUID { generation += bytesField(4, Array(stepUUID.utf8)) }
        return generation
    }

    private func stepMetadata(timestamp: UInt64, stepUUID: String, botID: String) -> [UInt8] {
        var metadata = bytesField(1, varintField(1, timestamp))
        metadata += bytesField(9, bytesField(7, Array(botID.utf8)))
        metadata += bytesField(12, Array(stepUUID.utf8))
        return metadata
    }

    private func makeDatabase(rows: Int, shape: StoreShape) throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("antigravity-rust-bench-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.trashItem(at: directory, resultingItemURL: nil) }
        let path = directory.appendingPathComponent("conversation.db").path
        var sql = "CREATE TABLE gen_metadata(idx INTEGER PRIMARY KEY, data BLOB);"
        if shape == .modern {
            sql += "CREATE TABLE steps(idx INTEGER PRIMARY KEY, metadata BLOB);"
        }
        let base = UInt64(now.addingTimeInterval(-86_400).timeIntervalSince1970)
        for row in 0..<rows {
            let timestamp = base - UInt64(row % 30) * 86_400
            let stepUUID = "turn-\(row)"
            let blob = generationBlob(
                model: row % 3 == 0 ? "gemini-3.6-flash" : "unknown-antigravity-model",
                input: UInt64(100 + row % 1_000),
                output: UInt64(50 + row % 300),
                timestamp: shape == .legacy ? timestamp : nil,
                stepUUID: shape == .modern ? stepUUID : nil,
                botID: shape == .modern ? "bot-1" : nil
            )
            let hex = blob.map { String(format: "%02x", $0) }.joined()
            sql += "INSERT INTO gen_metadata VALUES(\(row), x'\(hex)');"
            if shape == .modern {
                let metadata = stepMetadata(timestamp: timestamp, stepUUID: stepUUID, botID: "bot-1")
                let metadataHex = metadata.map { String(format: "%02x", $0) }.joined()
                sql += "INSERT INTO steps VALUES(\(row), x'\(metadataHex)');"
            }
        }
        // Fixture construction writes thousands of rows through one `sqlite3` process; the
        // product's five-second statement bound is the wrong budget for that write, and a timeout
        // here would fail the benchmark before it measures anything.
        try SQLiteCLIAccessor(processRunner: FixtureProcessRunner(timeout: 120))
            .execute(path: path, sql: sql)
        return directory.path
    }

    private enum EngineVariant: String, CaseIterable {
        case sqliteCLI
        case rust
        /// The pre-change in-process engine: it answered every statement except the `sha3` ones,
        /// so a changed database fell back to the bounded prefix verifier.
        case rustWithoutSHA3
    }

    private func accessor(variant: EngineVariant, runner: ProcessRunning) -> SQLiteAccessing {
        let fallback = SQLiteCLIAccessor(
            processRunner: runner,
            allowsReadWriteFallback: false
        )
        switch variant {
        case .sqliteCLI:
            return fallback
        case .rust:
            return AntigravityDatabaseAccess(engine: .rust, sqlite: fallback)
        case .rustWithoutSHA3:
            return AntigravitySHA3BlindAccess(
                inner: AntigravityDatabaseAccess(engine: .rust, sqlite: fallback)
            )
        }
    }

    private func scanner(directory: String, engine: AntigravityDatabaseEngine, runner: ProcessRunning) -> AntigravityDbUsageScanner {
        AntigravityDbUsageScanner(
            sqlite: accessor(variant: engine == .rust ? .rust : .sqliteCLI, runner: runner),
            conversationsDirectory: { directory }
        )
    }

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Rows appended between the cold scan and the measured scan: the case the SHA3 gap affected,
    /// because a changed database used to re-read its whole history to verify the cached prefix.
    private func appendedRowsSQL(start: Int, count: Int) -> String {
        let timestamp = UInt64(now.addingTimeInterval(-1_800).timeIntervalSince1970)
        var sql = ""
        for offset in 0..<count {
            let row = start + offset
            let stepUUID = "changed-\(row)"
            let blob = generationBlob(
                model: "gemini-3.6-flash", input: 100, output: 50, timestamp: nil,
                stepUUID: stepUUID, botID: "bot-1"
            )
            let metadata = stepMetadata(timestamp: timestamp, stepUUID: stepUUID, botID: "bot-1")
            sql += "INSERT INTO gen_metadata VALUES(\(row), x'\(hex(blob))');"
            sql += "INSERT INTO steps VALUES(\(row), x'\(hex(metadata))');"
        }
        return sql
    }

    private func copyDatabase(_ directory: String, label: String) throws -> String {
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("antigravity-changed-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: directory).appendingPathComponent("conversation.db"),
            to: target.appendingPathComponent("conversation.db")
        )
        addTeardownBlock { try? FileManager.default.trashItem(at: target, resultingItemURL: nil) }
        return target.path
    }

    private func freshPersistenceDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("antigravity-bench-persistence-\(UUID().uuidString)", isDirectory: true)
    }

    /// A changed modern database: warm the cache, append rows, then time the refresh that has to
    /// re-validate the cached prefix. Every variant scans its own copy of the same database and is
    /// compared with a cold CLI scan of the appended store.
    private func measureChanged(rows: Int, appended: Int) async throws {
        let source = try makeDatabase(rows: rows, shape: .modern)
        let appendSQL = appendedRowsSQL(start: rows, count: appended)
        let fixture = SQLiteCLIAccessor(processRunner: FixtureProcessRunner(timeout: 120))

        let referenceDirectory = try copyDatabase(source, label: "reference")
        try fixture.execute(
            path: referenceDirectory + "/conversation.db",
            sql: appendSQL
        )
        let referencePersistence = freshPersistenceDirectory()
        AntigravityAggregatePersistence.directoryOverride = referencePersistence
        defer {
            AntigravityAggregatePersistence.directoryOverride = nil
            try? FileManager.default.removeItem(at: referencePersistence)
        }
        let expectedScan = await scanner(
            directory: referenceDirectory, engine: .sqliteCLI, runner: AntigravityCountingProcessRunner()
        ).scan(now: now, pricing: TestPricing.bundled)
        guard let expected = expectedScan else {
            XCTFail("the changed-store reference scan produced no result")
            return
        }

        var intervals: [EngineVariant: [Double]] = [:]
        var spawns: [EngineVariant: Int] = [:]
        var queries: [EngineVariant: Int] = [:]

        for variant in EngineVariant.allCases {
            for iteration in 0..<3 {
                let directory = try copyDatabase(source, label: "\(variant.rawValue)-\(iteration)")
                let persistence = freshPersistenceDirectory()
                AntigravityAggregatePersistence.directoryOverride = persistence
                defer { try? FileManager.default.removeItem(at: persistence) }

                let runner = AntigravityCountingProcessRunner()
                let counting = AntigravityCountingAccess(
                    inner: accessor(variant: variant, runner: runner)
                )
                let usageScanner = AntigravityDbUsageScanner(
                    sqlite: counting,
                    conversationsDirectory: { directory }
                )
                print("ANTIGRAVITY_VARIANT \(variant.rawValue) iteration=\(iteration) cold")
                let cold = await usageScanner.scan(now: now, pricing: TestPricing.bundled)
                XCTAssertNotNil(cold)

                try fixture.execute(path: directory + "/conversation.db", sql: appendSQL)
                runner.reset()
                counting.reset()
                print("ANTIGRAVITY_VARIANT \(variant.rawValue) iteration=\(iteration) changed")
                let interval = await timed {
                    let changed = await usageScanner.scan(now: now, pricing: TestPricing.bundled)
                    XCTAssertEqual(changed, Optional(expected))
                }
                intervals[variant, default: []].append(interval)
                if iteration == 0 {
                    spawns[variant] = runner.count
                    queries[variant] = counting.queryCount
                    print("ANTIGRAVITY_SLOWEST \(variant.rawValue) rows=\(rows) \(counting.slowest.map { String(format: "%.1fms %@", $0.1, $0.0) })")
                }
            }
        }
        AntigravityAggregatePersistence.directoryOverride = nil

        func median(_ variant: EngineVariant) -> Double {
            (intervals[variant] ?? []).sorted()[1]
        }
        let cliMs = median(.sqliteCLI)
        let rustMs = median(.rust)
        let blindMs = median(.rustWithoutSHA3)
        print(
            "ANTIGRAVITY_SQLITE_BENCH changed=1 rows=\(rows) appended=\(appended)"
                + " cli_ms=" + String(format: "%.1f", cliMs)
                + " rust_ms=" + String(format: "%.1f", rustMs)
                + " rust_without_sha3_ms=" + String(format: "%.1f", blindMs)
                + " speedup_vs_cli=" + String(format: "%.2f", cliMs / rustMs) + "x"
                + " speedup_vs_blind=" + String(format: "%.2f", blindMs / rustMs) + "x"
                + " spawns cli=\(spawns[.sqliteCLI] ?? -1)->\(spawns[.rust] ?? -1) blind=\(spawns[.rustWithoutSHA3] ?? -1)"
                + " queries cli=\(queries[.sqliteCLI] ?? -1) rust=\(queries[.rust] ?? -1) blind=\(queries[.rustWithoutSHA3] ?? -1)"
                + " rust_runs=\(intervals[.rust]?.map { String(format: "%.1f", $0) } ?? [])"
                + " blind_runs=\(intervals[.rustWithoutSHA3]?.map { String(format: "%.1f", $0) } ?? [])"
                + " cli_runs=\(intervals[.sqliteCLI]?.map { String(format: "%.1f", $0) } ?? [])"
        )
    }

    private func timed(_ body: () async -> Void) async -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        await body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private func measure(rows: Int, shape: StoreShape) async throws {
        let directory = try makeDatabase(rows: rows, shape: shape)
        let cliRunner = AntigravityCountingProcessRunner()
        let rustRunner = AntigravityCountingProcessRunner()
        let initialPersistence = FileManager.default.temporaryDirectory
            .appendingPathComponent("antigravity-bench-persistence-\(UUID().uuidString)", isDirectory: true)
        AntigravityAggregatePersistence.directoryOverride = initialPersistence
        defer {
            AntigravityAggregatePersistence.directoryOverride = nil
            try? FileManager.default.removeItem(at: initialPersistence)
        }

        let oracle = await scanner(directory: directory, engine: .sqliteCLI, runner: cliRunner)
            .scan(now: now, pricing: TestPricing.bundled)
        let rust = await scanner(directory: directory, engine: .rust, runner: rustRunner)
            .scan(now: now, pricing: TestPricing.bundled)
        XCTAssertEqual(rust, oracle)
        XCTAssertNotNil(rust)
        XCTAssertFalse(rust?.series.daily.isEmpty ?? true, "the benchmark fixture produced no usage")

        var rustTimes: [Double] = []
        var cliTimes: [Double] = []
        var firstRustSpawns = 0
        var firstCLISpawns = 0
        for iteration in 0..<3 {
            rustRunner.reset()
            cliRunner.reset()
            let rustPersistence = FileManager.default.temporaryDirectory
                .appendingPathComponent("antigravity-bench-persistence-\(UUID().uuidString)", isDirectory: true)
            AntigravityAggregatePersistence.directoryOverride = rustPersistence
            rustTimes.append(await timed {
                let scan = await scanner(directory: directory, engine: .rust, runner: rustRunner)
                    .scan(now: now, pricing: TestPricing.bundled)
                XCTAssertEqual(scan, oracle)
            })
            if iteration == 0 { firstRustSpawns = rustRunner.count }
            try? FileManager.default.removeItem(at: rustPersistence)

            let cliPersistence = FileManager.default.temporaryDirectory
                .appendingPathComponent("antigravity-bench-persistence-\(UUID().uuidString)", isDirectory: true)
            AntigravityAggregatePersistence.directoryOverride = cliPersistence
            cliTimes.append(await timed {
                let scan = await scanner(directory: directory, engine: .sqliteCLI, runner: cliRunner)
                    .scan(now: now, pricing: TestPricing.bundled)
                XCTAssertEqual(scan, oracle)
            })
            if iteration == 0 { firstCLISpawns = cliRunner.count }
            try? FileManager.default.removeItem(at: cliPersistence)
        }
        AntigravityAggregatePersistence.directoryOverride = nil

        let rustMs = rustTimes.sorted()[1]
        let cliMs = cliTimes.sorted()[1]
        print(
            "ANTIGRAVITY_SQLITE_BENCH cold=1 rows=\(rows) shape=\(shape.rawValue) rust_ms="
                + String(format: "%.1f", rustMs)
                + " cli_ms=" + String(format: "%.1f", cliMs)
                + " speedup=" + String(format: "%.2f", cliMs / rustMs) + "x"
                + " spawns=\(firstCLISpawns)->\(firstRustSpawns)"
                + " rust_runs=\(rustTimes.map { String(format: "%.1f", $0) })"
                + " cli_runs=\(cliTimes.map { String(format: "%.1f", $0) })"
        )
    }

    func testAntigravityDatabaseBenchmark() async throws {
        guard ProcessInfo.processInfo.environment["QUOTABAR_ANTIGRAVITY_BENCH"] == "1" else {
            throw XCTSkip("Set QUOTABAR_ANTIGRAVITY_BENCH=1 to run the Antigravity database benchmark.")
        }
        try await measure(rows: 200, shape: .legacy)
        try await measure(rows: 10_000, shape: .legacy)
        try await measure(rows: 200, shape: .modern)
        try await measure(rows: 10_000, shape: .modern)
        try await measureChanged(rows: 400, appended: 40)
        try await measureChanged(rows: 10_000, appended: 200)
    }
}

/// Counts statements so the benchmark can report how much work each engine's changed-database
/// path actually does, not only how long it took.
private final class AntigravityCountingAccess: SQLiteAccessing, @unchecked Sendable {
    private let lock = NSLock()
    private let inner: SQLiteAccessing
    private var statements = 0
    private var timings: [(String, Double)] = []

    init(inner: SQLiteAccessing) {
        self.inner = inner
    }

    var queryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return statements
    }

    var slowest: [(String, Double)] {
        lock.lock()
        defer { lock.unlock() }
        return Array(timings.sorted { $0.1 > $1.1 }.prefix(4))
    }

    func reset() {
        lock.lock()
        statements = 0
        timings.removeAll()
        lock.unlock()
    }

    func queryValue(path: String, sql: String) throws -> String? {
        let start = DispatchTime.now().uptimeNanoseconds
        let result = try inner.queryValue(path: path, sql: sql)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        lock.lock()
        statements += 1
        timings.append((String(sql.prefix(90)), ms))
        lock.unlock()
        return result
    }

    func execute(path: String, sql: String) throws {
        try inner.execute(path: path, sql: sql)
    }
}

/// Reproduces the pre-change in-process engine at the only seam where it differed: it had no
/// `sha3`/`sha3_agg`, so the scanner used the bounded prefix verifier instead of a digest.
private final class AntigravitySHA3BlindAccess: SQLiteAccessing, @unchecked Sendable {
    private let inner: SQLiteAccessing

    init(inner: SQLiteAccessing) {
        self.inner = inner
    }

    func queryValue(path: String, sql: String) throws -> String? {
        if sql.lowercased().contains("sha3") {
            throw SQLiteError.queryFailed("no such function: sha3")
        }
        return try inner.queryValue(path: path, sql: sql)
    }

    func execute(path: String, sql: String) throws {
        try inner.execute(path: path, sql: sql)
    }
}

/// Gives the benchmark's own fixture writes a long budget while the measured reads keep the
/// product's normal five-second bound.
private struct FixtureProcessRunner: ProcessRunning {
    private let inner = SystemProcessRunner()
    private let timeout: TimeInterval

    init(timeout: TimeInterval) { self.timeout = timeout }

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) throws -> ProcessResult {
        try inner.run(
            executable: executable, arguments: arguments, environment: environment,
            timeout: self.timeout
        )
    }

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        standardInput: Data?,
        timeout: TimeInterval
    ) throws -> ProcessResult {
        try inner.run(
            executable: executable, arguments: arguments, environment: environment,
            standardInput: standardInput, timeout: self.timeout
        )
    }
}

private final class AntigravityCountingProcessRunner: ProcessRunning, @unchecked Sendable {
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
