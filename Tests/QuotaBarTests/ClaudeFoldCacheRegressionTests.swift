import Foundation
import XCTest
@testable import QuotaBar

final class ClaudeFoldCacheRegressionTests: XCTestCase {
    private let now = TestLocalInstant.date(2026, 10, 20, 12)

    private func pricing(_ input: Double) -> ModelPricing {
        ModelPricing(supplement: PricingSupplement(), primary: PricingCatalog(entries: [
            "claude-test-model": ModelRates(inputPerMillion: input, outputPerMillion: 0,
                                             cacheWritePerMillion: input, cacheReadPerMillion: input)
        ]), secondary: PricingCatalog())
    }

    private func line(_ id: String, input: Int = 100, model: String = "claude-test-model", at: Date? = nil) -> String {
        ClaudeLogFixture.usageLine(timestamp: OpenUsageISO8601.string(from: at ?? now), model: model,
                                   input: input, messageID: id, requestID: id)
    }

    func testWarmResultRepricesAndInvalidatesOnRewriteAdditionAndRemoval() async throws {
        let home = try ClaudeLogFixture.makeHome(files: ["project/a.jsonl": line("a")])
        defer { try? FileManager.default.trashItem(at: home, resultingItemURL: nil) }
        let scanner = ClaudeLogFixture.scanner(home: home)
        let first = await scanner.scan(now: now, pricing: pricing(10))
        let warm = await scanner.scan(now: now.addingTimeInterval(1), pricing: pricing(10))
        XCTAssertEqual(first?.series, warm?.series)
        let repriced = await scanner.scan(now: now, pricing: pricing(20))
        XCTAssertEqual(repriced?.series.daily.first?.costUSD ?? 0, 0.002, accuracy: 1e-12)

        let source = home.appendingPathComponent("projects/project/a.jsonl")
        let oldMtime = try source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
        // Same length and restored mtime; ctime must invalidate both the result and parse caches.
        try line("a", input: 200).write(to: source, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: oldMtime], ofItemAtPath: source.path)
        let rewritten = await scanner.scan(now: now, pricing: pricing(10))
        XCTAssertEqual(rewritten?.series.daily.first?.totalTokens, 200)

        let added = home.appendingPathComponent("projects/project/b.jsonl")
        try line("b", input: 50).write(to: added, atomically: true, encoding: .utf8)
        let extended = await scanner.scan(now: now, pricing: pricing(10))
        XCTAssertEqual(extended?.series.daily.first?.totalTokens, 250)
        try FileManager.default.trashItem(at: source, resultingItemURL: nil)
        let removed = await scanner.scan(now: now, pricing: pricing(10))
        XCTAssertEqual(removed?.series.daily.first?.totalTokens, 50)
    }

    func testWindowAndMidnightRolloverCannotReuseOldTotals() async throws {
        let yesterday = now.addingTimeInterval(-86_400)
        let home = try ClaudeLogFixture.makeHome(files: ["project/a.jsonl": line("a", at: yesterday)])
        defer { try? FileManager.default.trashItem(at: home, resultingItemURL: nil) }
        let scanner = ClaudeLogFixture.scanner(home: home)
        let wide = await scanner.scan(daysBack: 1, now: now, pricing: pricing(10))
        let narrow = await scanner.scan(daysBack: 0, now: now, pricing: pricing(10))
        let tomorrow = await scanner.scan(daysBack: 1, now: now.addingTimeInterval(86_400), pricing: pricing(10))
        XCTAssertEqual(wide?.series.daily.first?.totalTokens, 100)
        XCTAssertTrue(narrow?.series.daily.isEmpty == true)
        XCTAssertTrue(tomorrow?.series.daily.isEmpty == true)
    }

    func testClockRollbackRechecksFutureRowsForNativeAndGatewayCaches() async throws {
        let home = try ClaudeLogFixture.makeHome(files: ["project/a.jsonl": line("a", model: "anthropic/opencode_go/model")])
        defer { try? FileManager.default.trashItem(at: home, resultingItemURL: nil) }
        let scanner = ClaudeLogFixture.scanner(home: home)
        _ = await scanner.scan(now: now, pricing: pricing(10))
        let complete = await scanner.foldParsedEntries(now: now, roots: [home], hostedGatewayOnly: true) { _ in }
        XCTAssertTrue(complete)
        let rolledBack = now.addingTimeInterval(-600)
        if case .complete = await scanner.scanResult(now: rolledBack, pricing: pricing(10)) {
            XCTFail("cached totals must not hide a future timestamp after clock rollback")
        }
        let gatewayComplete = await scanner.foldParsedEntries(now: rolledBack, roots: [home], hostedGatewayOnly: true) { _ in
            XCTFail("future gateway rows must not be emitted")
        }
        XCTAssertFalse(gatewayComplete)
    }

    func testWarmCacheStillChecksOwnershipAndCancellation() async throws {
        let home = try ClaudeLogFixture.makeHome(files: ["project/a.jsonl": line("a")])
        defer { try? FileManager.default.trashItem(at: home, resultingItemURL: nil) }
        let readable = Readability()
        let scanner = ClaudeLogUsageScanner(
            environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": home.path]), homeDirectory: { home },
            incrementalScanner: IncrementalJSONLScanner<ClaudeLogUsageScanner.Entry>(),
            organizationUUID: "org-a", ownershipLookup: { _ in readable.lookup() }
        )
        let initial = await scanner.scan(now: now, pricing: pricing(10))
        XCTAssertEqual(initial?.series.daily.first?.totalTokens, 100)
        readable.fail()
        if case .complete = await scanner.scanResult(now: now, pricing: pricing(10)) {
            XCTFail("ownership read failure must remain incomplete on a warm result")
        }
        readable.recover()
        let timestamp = now
        let rates = pricing(10)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await scanner.scanResult(now: timestamp, pricing: rates)
        }
        if case .complete = await cancelled.value { XCTFail("cancelled cache hits must not publish") }
    }

    func testGatewayProjectionDeduplicatesBeforeFilteringAndKeepsRawAPIComplete() async throws {
        let parent = line("parent")
        let replay = ClaudeLogFixture.usageLine(
            timestamp: OpenUsageISO8601.string(from: now), model: "anthropic/opencode_go/model", input: 100,
            messageID: "parent", requestID: "replay", isSidechain: true
        )
        let home = try ClaudeLogFixture.makeHome(files: ["project/a.jsonl":
            [parent, replay, line("gateway", input: 20, model: "anthropic/opencode_go/model")].joined(separator: "\n")
        ])
        defer { try? FileManager.default.trashItem(at: home, resultingItemURL: nil) }
        let scanner = ClaudeLogFixture.scanner(home: home)
        for _ in 0..<2 {
            let values = CollectedEntries()
            let complete = await scanner.foldParsedEntries(now: now, roots: [home], hostedGatewayOnly: true) { values.append($0) }
            XCTAssertTrue(complete)
            XCTAssertEqual(values.entries.map(\.tokens.totalTokens), [20])
        }
        let all = CollectedEntries()
        let complete = await scanner.foldParsedEntries(now: now, roots: [home]) { all.append($0) }
        XCTAssertTrue(complete)
        XCTAssertEqual(all.entries.map(\.tokens.totalTokens).sorted(), [20, 100])
        let added = home.appendingPathComponent("projects/project/b.jsonl")
        try line("new", input: 30, model: "anthropic/opencode_go/model").write(to: added, atomically: true, encoding: .utf8)
        let extended = CollectedEntries()
        let refreshed = await scanner.foldParsedEntries(now: now, roots: [home], hostedGatewayOnly: true) { extended.append($0) }
        XCTAssertTrue(refreshed)
        XCTAssertEqual(extended.entries.map(\.tokens.totalTokens).sorted(), [20, 30])
    }

    func testWarmResultRevalidatesSourceAfterOwnershipLookupSuspends() async throws {
        let home = try ClaudeLogFixture.makeHome(files: ["project/a.jsonl": line("a")])
        defer { try? FileManager.default.trashItem(at: home, resultingItemURL: nil) }
        let ownership = Readability()
        let scanner = ClaudeLogUsageScanner(
            environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": home.path]), homeDirectory: { home },
            incrementalScanner: IncrementalJSONLScanner<ClaudeLogUsageScanner.Entry>(),
            organizationUUID: "org-a", ownershipLookup: { _ in ownership.lookup() }
        )
        _ = await scanner.scan(now: now, pricing: pricing(10))
        let source = home.appendingPathComponent("projects/project/a.jsonl")
        let rewritten = line("a", input: 200)
        ownership.onNextLookup { try! rewritten.write(to: source, atomically: false, encoding: .utf8) }
        if case .complete = await scanner.scanResult(now: now, pricing: pricing(10)) {
            XCTFail("a cached revision observed before the ownership await must be revalidated")
        }
        let recovered = await scanner.scan(now: now, pricing: pricing(10))
        XCTAssertEqual(recovered?.series.daily.first?.totalTokens, 200)
    }

    private final class Readability: @unchecked Sendable {
        private let lock = NSLock()
        private var readable = true
        private var action: (@Sendable () -> Void)?
        func fail() { lock.withLock { readable = false } }
        func recover() { lock.withLock { readable = true } }
        func onNextLookup(_ action: @escaping @Sendable () -> Void) { lock.withLock { self.action = action } }
        func lookup() -> ClaudeSessionOwnershipLookupResult {
            let (readable, action) = lock.withLock {
                defer { self.action = nil }
                return (self.readable, self.action)
            }
            action?()
            return readable ? .readable(organizationID: "org-a", accountID: nil, isAmbiguous: false) : .unreadable
        }
    }

    private final class CollectedEntries: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [ClaudeLogUsageScanner.Entry] = []
        var entries: [ClaudeLogUsageScanner.Entry] { lock.withLock { values } }
        func append(_ value: ClaudeLogUsageScanner.Entry) { lock.withLock { values.append(value) } }
    }
}
