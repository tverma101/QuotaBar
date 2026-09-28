import XCTest
@testable import QuotaBar

/// Claude Code sessions routed through the OpenCode gateway (`anthropic/opencode_go/…` /
/// `anthropic/opencode/…` models) burn OpenCode-hosted quota but never appear in `opencode*.db`.
/// These tests lock the parser and the folding of those sessions into the spend tiles + trend.
final class OpenCodeClaudeGatewayTests: XCTestCase {
    private func d(_ iso: String) -> Date { OpenUsageISO8601.date(from: iso)! }
    private func epochMs(_ iso: String) -> Int { Int(d(iso).timeIntervalSince1970 * 1000) }
    private let now = TestLocalInstant.date(2026, 7, 12, 12)

    /// One Claude Code assistant log line in the real shape (usage block, ISO timestamp).
    private func line(
        _ iso: String, _ model: String,
        input: Int = 100, output: Int = 50, cacheWrite: Int = 0, cacheRead: Int = 0
    ) -> String {
        """
        {"type":"assistant","timestamp":"\(iso)","message":{"model":"\(model)","usage":{"input_tokens":\(input),"output_tokens":\(output),"cache_creation_input_tokens":\(cacheWrite),"cache_read_input_tokens":\(cacheRead)}}}
        """
    }

    // MARK: - Parser

    /// One Claude scanner entry with the token buckets already normalized.
    private func entry(
        _ iso: String, _ model: String?,
        input: Int = 100, output: Int = 50, cacheWrite: Int = 0, cacheRead: Int = 0
    ) -> ClaudeLogUsageScanner.Entry {
        ClaudeLogUsageScanner.Entry(
            timestamp: d(iso),
            tokens: TokenBreakdown(input: input, cacheWrite5m: cacheWrite, cacheRead: cacheRead, output: output),
            model: model
        )
    }

    func testClaudeGatewayRowsFiltersByPrefix() {
        let entries = [
            entry(TestLocalInstant.iso(2026, 7, 12, 11), "anthropic/opencode_go/deepseek-v4-flash", input: 1000, output: 200, cacheRead: 8000),
            entry(TestLocalInstant.iso(2026, 7, 12, 10), "anthropic/opencode/gpt-5.5", input: 300, output: 100),
            // Not through the gateway — the Claude provider owns these; must be ignored.
            entry(TestLocalInstant.iso(2026, 7, 12, 10), "claude-sonnet-4-5", input: 999, output: 999),
            // No model at all (the scanner's <synthetic> placeholder) must not count.
            entry(TestLocalInstant.iso(2026, 7, 12, 10), nil, input: 999, output: 999),
            // No model suffix after the prefix.
            entry(TestLocalInstant.iso(2026, 7, 12, 10), "anthropic/opencode_go/", input: 999, output: 999),
        ]
        let rows = OpenCodeUsageScanner.claudeGatewayRows(from: entries)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].model, "deepseek-v4-flash")
        XCTAssertEqual(rows[0].tokens, 1000 + 200 + 8000)
        XCTAssertTrue(rows[0].burnsGoQuota, "opencode_go prefix burns the Go subscription quota")
        XCTAssertEqual(rows[1].model, "gpt-5.5")
        XCTAssertEqual(rows[1].tokens, 400)
        XCTAssertFalse(rows[1].burnsGoQuota, "opencode (Zen) prefix bills pay-as-you-go, not the Go cap")
    }

    // MARK: - Folding into the scan

    private func fixtureClaudeHome(files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openusage-oc-claude-\(UUID().uuidString)", isDirectory: true)
        for (relative, content) in files {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    private final class StubSQLite: SQLiteAccessing, @unchecked Sendable {
        var data: [String: String]
        init(data: [String: String] = [:]) { self.data = data }
        func queryValue(path: String, sql: String) throws -> String? {
            if sql.contains("json_group_array") { return data[path] }
            if sql.contains("SELECT 1") { return data[path] == nil ? nil : "1" }
            return nil
        }
        func execute(path: String, sql: String) throws {}
    }

    func testClaudeGatewaySessionsFoldIntoTilesWithEstimatedCost() async throws {
        // A DB with one Go row, plus a Claude Code log with one gateway session. Both must land in
        // the tiles; the folded session's cost is imputed (deepseek-v4-flash is in the bundled
        // catalogs), marking the series estimated.
        let claudeHome = try fixtureClaudeHome(files: [
            // Real Claude Code layout: sessions live in per-project subdirectories of `projects/`.
            ".claude/projects/-Users-tejas-Gaming/session.jsonl":
                line(TestLocalInstant.iso(2026, 7, 12, 11), "anthropic/opencode_go/deepseek-v4-flash", input: 1000, output: 200, cacheRead: 8000) + "\n" +
                line(TestLocalInstant.iso(2026, 7, 12, 10), "claude-sonnet-4-5", input: 999, output: 999) + "\n",
            ".claude/projects/-Users-tejas-Experiments/other.jsonl":
                line(TestLocalInstant.iso(2026, 7, 12, 9), "anthropic/opencode_go/deepseek-v4-flash", input: 300, output: 100) + "\n"
        ])
        let ms = epochMs(TestLocalInstant.iso(2026, 7, 12, 11))
        let db = "[[\(ms),2.0,500,\"glm-5.2\",\"opencode-go\"]]"
        let scanner = OpenCodeUsageScanner(
            sqlite: StubSQLite(data: ["/oc/opencode.db": db]),
            databasePaths: { ["/oc/opencode.db"] },
            claudeRoots: { [claudeHome.appendingPathComponent(".claude")] }
        )
        let scan = try await scanner.scan(now: now, hasGoKey: true, pricing: TestPricing.bundled)
        XCTAssertNotNil(scan)
        XCTAssertTrue(scan!.includesEstimatedCost)

        var lines: [MetricLine] = []
        SpendTileMapper.appendTokenUsage(scan!.logScan.series, to: &lines, now: now, estimated: scan!.includesEstimatedCost)
        guard case let .values(_, values, _, _, _, _)? = lines.first(where: { $0.label == "Today" }) else {
            return XCTFail("expected a Today tile")
        }
        // DB row (500 tokens) + both nested gateway sessions (9200 + 400) — the Claude-model line
        // is ignored.
        let tokens = values.first(where: { $0.kind == .count })?.number ?? 0
        XCTAssertEqual(tokens, 10100)
        // No deepseek-v4-flash rows exist in the DB fixture, so the gateway sessions fall back to
        // catalog pricing: 1000/200/8000 → $0.0002184 and 300/100 → $0.00007, plus the DB row's
        // recorded $2.00.
        let dollars = values.first(where: { $0.kind == .dollars })?.number ?? 0
        XCTAssertEqual(dollars, 2.0002884, accuracy: 1e-9)
        XCTAssertTrue(values.contains(where: \.estimated), "imputed dollars must carry the ⓘ marker")
    }

    func testGatewayFoldCalibratesToRecordedModelRate() async throws {
        // The gateway bills DeepSeek cache hits at a fraction of the sticker input rate, so the
        // provider's OWN recorded cost-per-token for a model is the calibration anchor for the
        // token-only folds — not the catalog miss rate. The DB records $0.005 for 10k
        // deepseek-v4-flash tokens ($0.50/M effective); the folded Claude gateway session (9200
        // tokens) must price at that recorded rate, not the catalog's $0.14/M input rate.
        let claudeHome = try fixtureClaudeHome(files: [
            ".claude/projects/-Users-tejas-Gaming/session.jsonl":
                line(TestLocalInstant.iso(2026, 7, 12, 11), "anthropic/opencode_go/deepseek-v4-flash", input: 1000, output: 200, cacheRead: 8000) + "\n",
        ])
        let ms = epochMs(TestLocalInstant.iso(2026, 7, 12, 11))
        let db = "[[\(ms),0.005,10000,\"deepseek-v4-flash\",\"opencode-go\"]]"
        let scanner = OpenCodeUsageScanner(
            sqlite: StubSQLite(data: ["/oc/opencode.db": db]),
            databasePaths: { ["/oc/opencode.db"] },
            claudeRoots: { [claudeHome.appendingPathComponent(".claude")] }
        )
        let scan = try await scanner.scan(now: now, hasGoKey: true, pricing: TestPricing.bundled)
        XCTAssertNotNil(scan)
        XCTAssertTrue(scan!.includesEstimatedCost)

        var lines: [MetricLine] = []
        SpendTileMapper.appendTokenUsage(scan!.logScan.series, to: &lines, now: now, estimated: scan!.includesEstimatedCost)
        guard case let .values(_, values, _, _, _, _)? = lines.first(where: { $0.label == "Today" }) else {
            return XCTFail("expected a Today tile")
        }
        let tokens = values.first(where: { $0.kind == .count })?.number ?? 0
        XCTAssertEqual(tokens, 10000 + 9200)
        // DB row's recorded $0.005 + fold at $0.50/M × 9200 tokens = $0.0046.
        let dollars = values.first(where: { $0.kind == .dollars })?.number ?? 0
        XCTAssertEqual(dollars, 0.0096, accuracy: 1e-9)
    }

    func testGatewayFoldPricedAtZeroWhenRecordedCostIsZero() async throws {
        // A free-tier model the gateway recorded at $0 must fold at $0 — the fold follows the
        // provider's own accounting (calibrated), not the catalog's paid rates.
        let claudeHome = try fixtureClaudeHome(files: [
            ".claude/projects/-Users-tejas-Gaming/session.jsonl":
                line(TestLocalInstant.iso(2026, 7, 12, 11), "anthropic/opencode/deepseek-v4-flash-free", input: 400) + "\n",
        ])
        let ms = epochMs(TestLocalInstant.iso(2026, 7, 12, 11))
        let db = "[[\(ms),0.0,5000,\"deepseek-v4-flash-free\",\"opencode\"]]"
        let scanner = OpenCodeUsageScanner(
            sqlite: StubSQLite(data: ["/oc/opencode.db": db]),
            databasePaths: { ["/oc/opencode.db"] },
            claudeRoots: { [claudeHome.appendingPathComponent(".claude")] }
        )
        let scan = try await scanner.scan(now: now, pricing: TestPricing.bundled)
        XCTAssertNotNil(scan)
        XCTAssertTrue(scan!.includesEstimatedCost)

        var lines: [MetricLine] = []
        SpendTileMapper.appendTokenUsage(scan!.logScan.series, to: &lines, now: now, estimated: scan!.includesEstimatedCost)
        guard case let .values(_, values, _, _, _, _)? = lines.first(where: { $0.label == "Today" }) else {
            return XCTFail("expected a Today tile")
        }
        // 5000 recorded + 450 folded (input 400 + default output 50), all at the recorded $0 rate.
        XCTAssertEqual(values.first(where: { $0.kind == .count })?.number ?? 0, 5450)
        XCTAssertEqual(values.first(where: { $0.kind == .dollars })?.number ?? 0, 0, accuracy: 1e-9)
    }

    func testGoWindowsIncludeGoQuotaFoldsButExcludeZen() async throws {
        // The cap meters' local dollar context must match the tiles: Go-subscription gateway
        // sessions (anthropic/opencode_go/…) count against the caps; Zen pay-as-you-go sessions
        // (anthropic/opencode/…) bill separately and must not inflate the local spend.
        let claudeHome = try fixtureClaudeHome(files: [
            ".claude/projects/-Users-tejas-Gaming/session.jsonl":
                line(TestLocalInstant.iso(2026, 7, 12, 11), "anthropic/opencode_go/deepseek-v4-flash", input: 100_000, output: 20_000, cacheRead: 800_000) + "\n" +
                line(TestLocalInstant.iso(2026, 7, 12, 10), "anthropic/opencode/gpt-5.5", input: 300, output: 100) + "\n",
        ])
        let ms = epochMs(TestLocalInstant.iso(2026, 7, 12, 11))
        let db = "[[\(ms),1.0,1000,\"glm-5.2\",\"opencode-go\"]]"
        let scanner = OpenCodeUsageScanner(
            sqlite: StubSQLite(data: ["/oc/opencode.db": db]),
            databasePaths: { ["/oc/opencode.db"] },
            claudeRoots: { [claudeHome.appendingPathComponent(".claude")] }
        )
        let scan = try await scanner.scan(now: now, hasGoKey: true, pricing: TestPricing.bundled)
        let windows = scan?.goWindows
        XCTAssertNotNil(windows)
        // Recorded $1.00 + the Go fold's catalog price: 100_000/20_000/800_000 at 0.14/0.28/0.0028
        // = 0.014 + 0.0056 + 0.00224 = $0.02184, snapped to the meter's hundredth-of-a-cent
        // precision → 1.0218. The Zen gpt-5.5 fold is excluded — if it leaked (another $0.0045),
        // the monthly spend would snap to 1.0263 instead.
        XCTAssertEqual(windows?.monthlySpend ?? -1, 1.0218, accuracy: 1e-9)
    }

    func testUnpricedGatewayModelSurfacesAsUnknownAndIsExcluded() async throws {
        // A model the catalogs don't know must not fabricate a price: its tokens are excluded and it
        // lands in the unknown-model warning, matching the Claude tiles' convention.
        let claudeHome = try fixtureClaudeHome(files: [
            ".claude/projects/-Users-tejas-Gaming/session.jsonl":
                line(TestLocalInstant.iso(2026, 7, 12, 11), "anthropic/opencode_go/not-a-real-model-xyz", input: 1000, output: 200) + "\n"
        ])
        let scanner = OpenCodeUsageScanner(
            sqlite: StubSQLite(data: ["/oc/opencode.db": "[]"]),
            databasePaths: { ["/oc/opencode.db"] },
            claudeRoots: { [claudeHome.appendingPathComponent(".claude")] }
        )
        let scan = try await scanner.scan(now: now, pricing: TestPricing.bundled)
        XCTAssertFalse(scan!.includesEstimatedCost)
        XCTAssertFalse(scan!.logScan.series.daily.contains { $0.totalTokens > 0 })
        XCTAssertTrue(scan!.logScan.unknownModelsByDay.values.contains { $0.contains("not-a-real-model-xyz") })
    }

    func testNoClaudeRootsScansNothing() async throws {
        let ms = epochMs(TestLocalInstant.iso(2026, 7, 12, 11))
        let db = "[[\(ms),2.0,500,\"glm-5.2\",\"opencode-go\"]]"
        let scanner = OpenCodeUsageScanner(
            sqlite: StubSQLite(data: ["/oc/opencode.db": db]),
            databasePaths: { ["/oc/opencode.db"] },
            claudeRoots: { [] }
        )
        let scan = try await scanner.scan(now: now, pricing: TestPricing.bundled)
        XCTAssertFalse(scan!.includesEstimatedCost)
        let totalTokens = scan!.logScan.series.daily.reduce(0) { $0 + $1.totalTokens }
        XCTAssertEqual(totalTokens, 500)
    }

    // MARK: - Discovery

    func testClaudeUsageFilesWalksProjectSubdirectories() throws {
        // Claude Code stores sessions at projects/<project>/<session>.jsonl. A flat read of the
        // projects/ directory alone finds nothing — this regression locks the recursive walk.
        let claudeHome = try fixtureClaudeHome(files: [
            ".claude/projects/-Users-tejas-Gaming/65b28018-9dd4-4a01-be86-0fa1971fce5d.jsonl": "x\n",
            ".claude/projects/-Users-tejas-Experiments/28272f85-c16c-4c52-b385-9f17ef2dbf43.jsonl": "x\n",
            ".claude/projects/ignored.txt": "x\n"
        ])
        let files = OpenCodeUsageScanner.claudeUsageFiles(under: claudeHome.appendingPathComponent(".claude"))
        XCTAssertEqual(files.count, 2)
        XCTAssertTrue(files.allSatisfy { $0.pathExtension == "jsonl" })
    }
}
