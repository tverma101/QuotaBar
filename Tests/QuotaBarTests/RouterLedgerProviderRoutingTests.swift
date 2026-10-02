import XCTest
@testable import QuotaBar

/// CodexRouter meters *every* routed turn, including the ones it hands to OpenCode. Those turns never
/// reach `opencode*.db` (a free Zen model can bypass the OpenCode server entirely) and the Codex card now
/// defers them, so without an OpenCode-side fold they are counted nowhere: a router configured for
/// `opencode-free/space-bunny-free` logged thousands of turns that no card reported at all.
final class RouterLedgerProviderRoutingTests: XCTestCase {
    /// A timestamp a few minutes ago, so an event is always inside the scan window no matter when the
    /// suite runs. The reader compares day keys as strings, so the leading date must lead the line.
    private static let recentISO = OpenUsageISO8601.string(from: Date().addingTimeInterval(-600))

    private func ledger(_ rows: [(String, String, Int, Int, Int)]) throws -> String {
        let lines = rows.map { provider, model, input, cached, output in
            """
            {"at":"\(Self.recentISO)","model":"\(model)","provider":"\(provider)","status":200,"inputTokens":\(input),"cachedInputTokens":\(cached),"outputTokens":\(output),"totalTokens":\(input + output)}
            """
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qb-router-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("usage-events.jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: path, atomically: true, encoding: .utf8)
        return path.path
    }

    private func rows(_ path: String) -> [OpenCodeUsageScanner.ClaudeGatewayRow] {
        OpenCodeUsageScanner.routerGatewayRows(atPath: path, since: Date().addingTimeInterval(-86_400))
    }

    func testOpenCodeServedTurnsAreFolded() throws {
        let path = try ledger([("opencode-free", "opencode-free/space-bunny-free", 5_000, 3_000, 900)])
        let folded = rows(path)
        XCTAssertEqual(folded.count, 1)
        XCTAssertEqual(folded[0].model, "space-bunny-free", "the row names the model, not the serving account")
        XCTAssertEqual(folded[0].input, 2_000, "cached is carved out of the inclusive input count")
        XCTAssertEqual(folded[0].cacheRead, 3_000)
        XCTAssertEqual(folded[0].output, 900)
    }

    /// The partition has to be exact, or the same turn is on two cards or on none.
    func testOnlyOpenCodeHostedProvidersAreFolded() throws {
        let path = try ledger([
            ("opencode-go", "anthropic/opencode_go/deepseek-v4-flash", 100, 0, 10),
            ("opencode", "deepseek-v4-flash", 100, 0, 10),
            ("opencode-free", "opencode-free/space-bunny-free", 100, 0, 10),
            ("openai", "gpt-6-luna", 100, 0, 10),
            ("anthropic", "claude-opus-4-7", 100, 0, 10)
        ])
        let folded = rows(path)
        XCTAssertEqual(folded.count, 3, "only the three OpenCode-hosted rows belong on this card")
        XCTAssertEqual(Set(folded.map(\.model)), ["deepseek-v4-flash", "space-bunny-free"])
    }

    /// Only the Go subscription's cap meters are consumed by `opencode-go`; Zen and free tiers are billed
    /// outside them, so charging them would push a Session/Weekly meter past 100%.
    func testOnlyTheGoSubscriptionBurnsCapQuota() throws {
        let path = try ledger([
            ("opencode-go", "m", 100, 0, 10),
            ("opencode-free", "f", 100, 0, 10),
            ("opencode", "z", 100, 0, 10)
        ])
        XCTAssertEqual(rows(path).filter(\.burnsGoQuota).count, 1)
    }

    /// A failed request must not be folded as usage.
    func testFailedRequestsAreNotFolded() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qb-router-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("usage-events.jsonl")
        try """
        {"at":"\(Self.recentISO)","model":"opencode-free/space-bunny-free","provider":"opencode-free","status":500,"inputTokens":100,"outputTokens":10}
        """ .write(to: path, atomically: true, encoding: .utf8)
        XCTAssertTrue(rows(path.path).isEmpty)
    }

    /// Chunk boundaries must not corrupt or drop rows: the ledger is read in 1MB chunks and a partial
    /// final line carries over.
    func testRowsSurviveChunkBoundaries() throws {
        let many = (0..<20_000).map { index in
            ("opencode-free", "opencode-free/space-bunny-free", 100 + index, 0, 10)
        }
        let path = try ledger(many)
        XCTAssertEqual(rows(path).count, 20_000, "every line must be read exactly once")
    }

    /// The Codex card defers these turns, so the helper it uses must agree with the one the fold uses.
    func testProviderClassificationIsShared() throws {
        for provider in ["opencode-go", "opencode", "opencode-free", "OpenCode-Go"] {
            XCTAssertTrue(CodexRouterUsageScanner.isOpenCodeProvider(provider), provider)
        }
        for provider in ["openai", "anthropic", "gemini", "", "not-opencode"] {
            XCTAssertFalse(CodexRouterUsageScanner.isOpenCodeProvider(provider), provider)
        }
    }

    func testBareModelNameStripsTheServingAccount() {
        XCTAssertEqual(OpenCodeUsageScanner.bareRouterModelName("opencode-free/space-bunny-free"), "space-bunny-free")
        XCTAssertEqual(OpenCodeUsageScanner.bareRouterModelName("gpt-6-luna"), "gpt-6-luna")
    }
}
