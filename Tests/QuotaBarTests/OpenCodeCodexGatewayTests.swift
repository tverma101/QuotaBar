import XCTest
@testable import QuotaBar

/// Codex rollouts routed through the OpenCode gateway (`anthropic/opencode_go/…` /
/// `anthropic/opencode/…` models) burn OpenCode-hosted quota but never appear in `opencode*.db`.
/// The fold reuses the Codex scanner's own parser (cumulative-total deltas, stale-snapshot dedup,
/// child-session replay gating), so these tests lock the gateway filter and the folding into the
/// spend tiles + trend.
final class OpenCodeCodexGatewayTests: XCTestCase {
    private func d(_ iso: String) -> Date { OpenUsageISO8601.date(from: iso)! }
    private func epochMs(_ iso: String) -> Int { Int(d(iso).timeIntervalSince1970 * 1000) }
    private let now = OpenUsageISO8601.date(from: "2026-07-12T12:00:00.000Z")!

    /// A rollout's `turn_context` line, which sets the session's model for the turns that follow.
    private func turnContext(_ iso: String, _ model: String) -> String {
        #"{"timestamp":"\#(iso)","type":"turn_context","payload":{"model":"\#(model)"}}"#
    }

    /// A `token_count` event with both cumulative totals and the turn's own usage.
    private func tokenLine(
        _ iso: String,
        input: Int, cached: Int = 0, output: Int = 0, reasoning: Int = 0
    ) -> String {
        let total = input + output + reasoning
        return """
        {"timestamp":"\(iso)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\(input),"cached_input_tokens":\(cached),"output_tokens":\(output),"reasoning_output_tokens":\(reasoning),"total_tokens":\(total)},"last_token_usage":{"input_tokens":\(input),"cached_input_tokens":\(cached),"output_tokens":\(output),"reasoning_output_tokens":\(reasoning)}}}}
        """
    }

    /// A `token_count` event with cumulative totals only — the parser must recover the turn delta.
    private func totalsOnlyLine(
        _ iso: String,
        input: Int, cached: Int = 0, output: Int = 0, reasoning: Int = 0
    ) -> String {
        let total = input + output + reasoning
        return """
        {"timestamp":"\(iso)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\(input),"cached_input_tokens":\(cached),"output_tokens":\(output),"reasoning_output_tokens":\(reasoning),"total_tokens":\(total)}}}}
        """
    }

    // MARK: - Parser

    func testParsePicksOnlyGatewayTurns() {
        let data = Data((
            // Cumulative totals without last_token_usage: the parser must recover the turn deltas.
            turnContext("2026-07-12T11:00:00.000Z", "anthropic/opencode_go/deepseek-v4-flash") + "\n" +
            totalsOnlyLine("2026-07-12T11:00:01.000Z", input: 1000, cached: 800, output: 200, reasoning: 50) + "\n" +
            totalsOnlyLine("2026-07-12T11:00:02.000Z", input: 2000, cached: 1600, output: 400, reasoning: 100) + "\n" +
            // Per-turn usage (last_token_usage) is model-independent.
            turnContext("2026-07-12T11:00:03.000Z", "anthropic/opencode/gpt-5.5") + "\n" +
            tokenLine("2026-07-12T11:00:04.000Z", input: 300, output: 100) + "\n" +
            // Not through the gateway — the Codex provider owns these; must be ignored.
            turnContext("2026-07-12T11:00:05.000Z", "gpt-5.5") + "\n" +
            tokenLine("2026-07-12T11:00:06.000Z", input: 999, output: 999) + "\n"
        ).utf8)
        let rows = OpenCodeUsageScanner.parseCodexGatewayRows(data)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0].model, "deepseek-v4-flash")
        // input 200 uncached + cacheRead 800 + output 250 (reasoning at output rate).
        XCTAssertEqual(rows[0].tokens, 1250)
        XCTAssertTrue(rows[0].burnsGoQuota, "opencode_go prefix burns the Go subscription quota")
        XCTAssertEqual(rows[1].model, "deepseek-v4-flash")
        XCTAssertEqual(rows[1].tokens, 1250)   // the delta, not the cumulative 2500
        XCTAssertTrue(rows[1].burnsGoQuota)
        XCTAssertEqual(rows[2].model, "gpt-5.5")
        XCTAssertEqual(rows[2].tokens, 400)
        XCTAssertFalse(rows[2].burnsGoQuota, "opencode (Zen) prefix bills pay-as-you-go, not the Go cap")
    }

    func testParseSkipsGatewayPrefixWithNoModelSuffix() {
        let data = Data((
            turnContext("2026-07-12T11:00:00.000Z", "anthropic/opencode_go/") + "\n" +
            tokenLine("2026-07-12T11:00:01.000Z", input: 100, output: 50) + "\n"
        ).utf8)
        XCTAssertTrue(OpenCodeUsageScanner.parseCodexGatewayRows(data).isEmpty)
    }

    // MARK: - Folding into the scan

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

    private func fixtureCodexHome(files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openusage-oc-codex-\(UUID().uuidString)", isDirectory: true)
        for (relative, content) in files {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    func testCodexGatewayTurnsFoldIntoTilesWithEstimatedCost() async throws {
        let codexHome = try fixtureCodexHome(files: [
            "sessions/2026/07/12/rollout.jsonl":
                turnContext("2026-07-12T11:00:00.000Z", "anthropic/opencode_go/deepseek-v4-flash") + "\n" +
                tokenLine("2026-07-12T11:00:01.000Z", input: 1000, cached: 800, output: 200, reasoning: 50) + "\n"
        ])
        let ms = epochMs("2026-07-12T11:00:00.000Z")
        let db = "[[\(ms),2.0,500,\"glm-5.2\",\"opencode-go\"]]"
        let scanner = OpenCodeUsageScanner(
            sqlite: StubSQLite(data: ["/oc/opencode.db": db]),
            databasePaths: { ["/oc/opencode.db"] },
            codexHomes: { [codexHome] }
        )
        let scan = try await scanner.scan(now: now, hasGoKey: true, pricing: TestPricing.bundled)
        XCTAssertNotNil(scan)
        XCTAssertTrue(scan!.includesEstimatedCost)

        var lines: [MetricLine] = []
        SpendTileMapper.appendTokenUsage(scan!.logScan.series, to: &lines, now: now, estimated: scan!.includesEstimatedCost)
        guard case let .values(_, values, _, _, _, _)? = lines.first(where: { $0.label == "Today" }) else {
            return XCTFail("expected a Today tile")
        }
        // DB row (500 tokens) + folded gateway turn (1250 tokens).
        let tokens = values.first(where: { $0.kind == .count })?.number ?? 0
        XCTAssertEqual(tokens, 1750)
        XCTAssertTrue(values.contains(where: \.estimated), "imputed dollars must carry the ⓘ marker")
    }

    func testUnpricedCodexGatewayModelSurfacesAsUnknownAndIsExcluded() async throws {
        let codexHome = try fixtureCodexHome(files: [
            "sessions/2026/07/12/rollout.jsonl":
                turnContext("2026-07-12T11:00:00.000Z", "anthropic/opencode_go/not-a-real-model-xyz") + "\n" +
                tokenLine("2026-07-12T11:00:01.000Z", input: 1000, output: 200) + "\n"
        ])
        let scanner = OpenCodeUsageScanner(
            sqlite: StubSQLite(data: ["/oc/opencode.db": "[]"]),
            databasePaths: { ["/oc/opencode.db"] },
            codexHomes: { [codexHome] }
        )
        let scan = try await scanner.scan(now: now, pricing: TestPricing.bundled)
        XCTAssertFalse(scan!.includesEstimatedCost)
        XCTAssertFalse(scan!.logScan.series.daily.contains { $0.totalTokens > 0 })
        XCTAssertTrue(scan!.logScan.unknownModelsByDay.values.contains { $0.contains("not-a-real-model-xyz") })
    }

    func testNoCodexHomesScansNothing() async throws {
        let ms = epochMs("2026-07-12T11:00:00.000Z")
        let db = "[[\(ms),2.0,500,\"glm-5.2\",\"opencode-go\"]]"
        let scanner = OpenCodeUsageScanner(
            sqlite: StubSQLite(data: ["/oc/opencode.db": db]),
            databasePaths: { ["/oc/opencode.db"] },
            codexHomes: { [] }
        )
        let scan = try await scanner.scan(now: now, pricing: TestPricing.bundled)
        XCTAssertFalse(scan!.includesEstimatedCost)
        let totalTokens = scan!.logScan.series.daily.reduce(0) { $0 + $1.totalTokens }
        XCTAssertEqual(totalTokens, 500)
    }
}
