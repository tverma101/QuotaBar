import XCTest
@testable import QuotaBar

final class ClaudeAccountingBoundaryTests: XCTestCase {
    func testStreamingScanRejectsUnknownAssistantAccountingShapeAndRecoversAfterCorrection() async throws {
        let home = try ClaudeLogFixture.makeHome(files: ["project/session.jsonl":
            #"{"type":"assistant","timestamp":"2026-02-20T12:00:00Z","usage":{"input_tokens":10,"output_tokens":2}}"#
        ])
        defer { try? FileManager.default.trashItem(at: home, resultingItemURL: nil) }
        let scanner = ClaudeLogFixture.scanner(home: home)
        let now = OpenUsageISO8601.date(from: "2026-02-20T16:00:00Z")!
        guard case .incomplete = await scanner.scanResult(now: now, pricing: .empty) else {
            return XCTFail("an unfamiliar assistant accounting shape must not become a complete empty history")
        }
        let corrected = #"{"type":"assistant","timestamp":"2026-02-20T12:00:00Z","message":{"model":"claude-test-model","usage" : {"input_tokens":10,"output_tokens":2,"speed":null}}}"#
        try corrected.write(to: home.appendingPathComponent("projects/project/session.jsonl"), atomically: true, encoding: .utf8)
        let recovered = await scanner.scan(now: now, pricing: .empty)
        XCTAssertEqual(recovered?.series.daily.first?.totalTokens, 12)
    }

    func testStreamingScanRejectsNullMessageUsage() async throws {
        let home = try ClaudeLogFixture.makeHome(files: ["project/session.jsonl":
            #"{"type":"assistant","timestamp":"2026-02-20T12:00:00Z","message":{"usage":null}}"#
        ])
        defer { try? FileManager.default.trashItem(at: home, resultingItemURL: nil) }
        let scanner = ClaudeLogFixture.scanner(home: home)
        let now = OpenUsageISO8601.date(from: "2026-02-20T16:00:00Z")!
        guard case .incomplete = await scanner.scanResult(now: now, pricing: .empty) else {
            return XCTFail("null accounting must not publish a complete empty history")
        }
    }
}
