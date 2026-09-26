import XCTest
@testable import OpenUsage

/// The SQLite scanner: unions `opencode*.db` files and sums combined hosted spend for the tiles/trend.
/// Fed a stub `SQLiteAccessing` that returns crafted `json_group_array` payloads keyed by path.
final class OpenCodeUsageScannerTests: XCTestCase {
    private func d(_ iso: String) -> Date { OpenUsageISO8601.date(from: iso)! }
    private func epochMs(_ iso: String) -> Int { Int(d(iso).timeIntervalSince1970 * 1000) }
    private let now = OpenUsageISO8601.date(from: "2026-07-12T12:00:00.000Z")!

    private var db1: String {
        "[" + [
            openCodeRow("2026-07-12T11:00:00.000Z", "2.0", 1000, "glm-5.2", "opencode-go"),
            openCodeRow("2026-07-12T10:00:00.000Z", "1.0", 500, "gpt-5.5", "opencode"),
            openCodeRow("2026-07-11T10:00:00.000Z", "3.0", 2000, "kimi-k2.6", "opencode-go"),
            openCodeRow("2026-07-12T11:00:00.000Z", "null", 100, "x", "opencode-go"),
            "\"garbage\""
        ].joined(separator: ",") + "]"
    }
    private var db2: String {
        "[" + openCodeRow("2026-07-12T09:00:00.000Z", "4.0", 800, "deepseek-v4-pro", "opencode-go") + "]"
    }

    private func standardScanner() -> OpenCodeUsageScanner {
        let sqlite = OpenCodeFakeSQLite(data: [
            "/oc/opencode.db": db1,
            "/oc/opencode-next.db": db2
        ])
        return OpenCodeUsageScanner(sqlite: sqlite, databasePaths: { ["/oc/opencode.db", "/oc/opencode-next.db"] })
    }

    func testCombinedHostedSeriesUnionsDatabasesAndSkipsGarbage() async throws {
        guard let scan = try await standardScanner().scan(now: now) else { return XCTFail("expected a scan") }
        let totalCost = scan.logScan.series.daily.compactMap(\.costUSD).reduce(0, +)
        let totalTokens = scan.logScan.series.daily.reduce(0) { $0 + $1.totalTokens }
        // opencode-go 2+3+4 plus Zen 1 = 10; the null-cost and "garbage" rows are dropped.
        XCTAssertEqual(totalCost, 10.0, accuracy: 0.0001)
        XCTAssertEqual(totalTokens, 4300) // 1000 + 500 + 2000 + 800
    }

    func testMissingDatabaseReturnsNil() async throws {
        let scanner = OpenCodeUsageScanner(sqlite: OpenCodeFakeSQLite(), databasePaths: { [] })
        let scan = try await scanner.scan(now: now)
        XCTAssertNil(scan)
    }

    func testEmptyDatabaseYieldsEmptyScanNotNil() async throws {
        let scanner = OpenCodeUsageScanner(
            sqlite: OpenCodeFakeSQLite(data: ["/oc/opencode.db": "[]"]),
            databasePaths: { ["/oc/opencode.db"] }
        )
        guard let scan = try await scanner.scan(now: now) else { return XCTFail("expected a scan") }
        XCTAssertTrue(scan.logScan.series.daily.isEmpty)
    }

    func testFailingDatabaseIsSkippedNotFatal() async throws {
        let scanner = OpenCodeUsageScanner(
            sqlite: OpenCodeFakeSQLite(data: ["/oc/opencode-next.db": db2], failing: ["/oc/opencode.db"]),
            databasePaths: { ["/oc/opencode.db", "/oc/opencode-next.db"] }
        )
        guard let scan = try await scanner.scan(now: now) else { return XCTFail("expected a scan") }
        XCTAssertEqual(scan.logScan.series.daily.compactMap(\.costUSD).reduce(0, +), 4.0, accuracy: 0.0001)
    }

    func testAllDatabasesFailingThrowsInsteadOfEmptyScan() async {
        let scanner = OpenCodeUsageScanner(
            sqlite: OpenCodeFakeSQLite(failing: ["/oc/opencode.db", "/oc/opencode-next.db"]),
            databasePaths: { ["/oc/opencode.db", "/oc/opencode-next.db"] }
        )
        do {
            _ = try await scanner.scan(now: now)
            XCTFail("expected databaseUnreadable")
        } catch {
            XCTAssertEqual(error as? OpenCodeUsageError, .databaseUnreadable)
        }
    }

    func testUnreadableDataDirectoryThrowsInsteadOfNil() async {
        let scanner = OpenCodeUsageScanner(
            sqlite: OpenCodeFakeSQLite(),
            databasePaths: { throw CocoaError(.fileReadNoPermission) }
        )
        do {
            _ = try await scanner.scan(now: now)
            XCTFail("expected databaseUnreadable")
        } catch {
            XCTAssertEqual(error as? OpenCodeUsageError, .databaseUnreadable)
        }
    }

    func testHasHostedUsageProbe() {
        let db = "[" + openCodeRow("2026-07-12T10:00:00.000Z", "1.0", 500, "gpt-5.5", "opencode") + "]"
        let withUsage = OpenCodeUsageScanner(
            sqlite: OpenCodeFakeSQLite(data: ["/oc/opencode.db": db]),
            databasePaths: { ["/oc/opencode.db"] }
        )
        XCTAssertTrue(withUsage.hasHostedUsage())

        let empty = OpenCodeUsageScanner(
            sqlite: OpenCodeFakeSQLite(data: ["/oc/opencode.db": "[]"]),
            databasePaths: { ["/oc/opencode.db"] }
        )
        XCTAssertFalse(empty.hasHostedUsage())
    }

    func testSQLCutoffMatchesCalendarTileWindow() async throws {
        let now = d("2026-07-12T18:00:00.000Z")
        let sqlite = OpenCodeFakeSQLite(data: ["/oc/opencode.db": "[]"])
        let scanner = OpenCodeUsageScanner(sqlite: sqlite, databasePaths: { ["/oc/opencode.db"] })
        _ = try await scanner.scan(now: now)

        let tileSinceMs = Int(JSONLScanning.sinceDate(daysBack: 30, now: now).timeIntervalSince1970 * 1000)
        guard let sql = sqlite.lastDataSQL else { return XCTFail("expected a data query") }
        XCTAssertTrue(sql.contains("time_created >= \(tileSinceMs)"), sql)
    }

    func testAbsurdTokenCountIsClampedNotCrashing() async throws {
        let db = "[[\(epochMs("2026-07-12T10:00:00.000Z")),1.0,1e19,\"glm-5.2\",\"opencode-go\"]]"
        let scanner = OpenCodeUsageScanner(
            sqlite: OpenCodeFakeSQLite(data: ["/oc/opencode.db": db]),
            databasePaths: { ["/oc/opencode.db"] }
        )
        guard let scan = try await scanner.scan(now: now) else { return XCTFail("expected a scan") }
        let tokens = scan.logScan.series.daily.reduce(0) { $0 + $1.totalTokens }
        XCTAssertEqual(tokens, 1_000_000_000_000_000)
    }

    func testPartitionCodexHomesSplitsDefaultAndManaged() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openusage-opencode-partition-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let userHome = root.appendingPathComponent("Users/dev", isDirectory: true)
        let defaultCodex = userHome.appendingPathComponent(".codex", isDirectory: true)
        let managed = root.appendingPathComponent("orca/managed-home", isDirectory: true)
        let aliasDefault = defaultCodex  // same path; uniqueCodexHomes must dedupe

        let partitioned = OpenCodeUsageScanner.partitionCodexHomes(
            [defaultCodex, managed, aliasDefault],
            homeDirectory: { userHome }
        )
        XCTAssertEqual(
            partitioned.managed.map { $0.resolvingSymlinksInPath().standardizedFileURL.path },
            [managed.resolvingSymlinksInPath().standardizedFileURL.path]
        )
        XCTAssertEqual(
            partitioned.defaultHomes.map { $0.resolvingSymlinksInPath().standardizedFileURL.path },
            [defaultCodex.resolvingSymlinksInPath().standardizedFileURL.path]
        )
    }

    /// OpenCode's Codex fold must scan default without stripping hardlinks, and pass default as
    /// peerHomes when scanning managed so shared hardlinks are not double-folded.
    func testPartitionPlusPeerHomesManagedSkipsDefaultHardlinks() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openusage-opencode-peer-wire-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let userHome = root.appendingPathComponent("Users/dev", isDirectory: true)
        let defaultCodex = userHome.appendingPathComponent(".codex", isDirectory: true)
        let managed = root.appendingPathComponent("orca/managed-home", isDirectory: true)
        let defaultSessions = defaultCodex.appendingPathComponent("sessions/2026/09/06", isDirectory: true)
        let managedSessions = managed.appendingPathComponent("sessions/2026/09/06", isDirectory: true)
        try FileManager.default.createDirectory(at: defaultSessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: managedSessions, withIntermediateDirectories: true)

        let defaultFile = defaultSessions.appendingPathComponent("a.jsonl")
        try "{\"type\":\"session_meta\"}\n".write(to: defaultFile, atomically: true, encoding: .utf8)
        let managedHardlink = managedSessions.appendingPathComponent("a.jsonl")
        try FileManager.default.linkItem(at: defaultFile, to: managedHardlink)

        let partitioned = OpenCodeUsageScanner.partitionCodexHomes(
            [defaultCodex, managed],
            homeDirectory: { userHome }
        )
        // Mirror OpenCodeUsageScanner.scan wiring: default with no peers, managed with peerHomes=default.
        let defaultFiles = CodexLogUsageScanner.sessionFiles(
            homes: partitioned.defaultHomes,
            peerHomes: [],
            homeDirectory: { userHome }
        )
        let managedFiles = CodexLogUsageScanner.sessionFiles(
            homes: partitioned.managed,
            peerHomes: partitioned.defaultHomes,
            homeDirectory: { userHome }
        )
        XCTAssertEqual(defaultFiles.count, 1)
        XCTAssertTrue(
            managedFiles.isEmpty,
            "managed must skip hardlinks present under peer ~/.codex when OpenCode passes default peerHomes; got \(managedFiles.map(\.path))"
        )
    }
}

/// One `[time_created, cost, tokens, model, provider]` row in the `json_group_array` shape both
/// OpenCode test suites feed the stub.
func openCodeRow(_ iso: String, _ cost: String, _ tokens: Int, _ model: String, _ provider: String) -> String {
    let epochMs = Int(OpenUsageISO8601.date(from: iso)!.timeIntervalSince1970 * 1000)
    return "[\(epochMs),\(cost),\(tokens),\"\(model)\",\"\(provider)\"]"
}

/// Stub that returns crafted payloads per database path and classifies the query by SQL shape.
/// Shared by the OpenCode scanner and provider tests.
final class OpenCodeFakeSQLite: SQLiteAccessing, @unchecked Sendable {
    var data: [String: String]
    var failing: Set<String>
    var lastDataSQL: String?

    init(data: [String: String] = [:], failing: Set<String> = []) {
        self.data = data
        self.failing = failing
    }

    func queryValue(path: String, sql: String) throws -> String? {
        if failing.contains(path) { throw SQLiteError.queryFailed("boom") }
        if sql.contains("json_group_array") {
            lastDataSQL = sql
            return data[path]
        }
        if sql.contains("SELECT 1") {
            let payload = data[path]
            return (payload != nil && payload != "[]" && !(payload ?? "").isEmpty) ? "1" : nil
        }
        return nil
    }

    func execute(path: String, sql: String) throws {}
}
