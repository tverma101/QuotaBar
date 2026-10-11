import XCTest
@testable import QuotaBar

final class CodexRouterLedgerWatcherTests: XCTestCase {
    func testLedgerAppendPostsWakeWhilePanelOpen() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ou-ledger-watch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ledger = dir.appendingPathComponent("usage-events.jsonl")
        try Data().write(to: ledger)

        let center = NotificationCenter()
        let name = CodexRouterLedgerWatcher.didChangeNotification
        final class Flag: @unchecked Sendable {
            var open = false
        }
        let flag = Flag()
        flag.open = true
        let watcher = CodexRouterLedgerWatcher(
            ledgerPaths: { [ledger.path] },
            isPanelOpen: { flag.open },
            center: center,
            debounceNanoseconds: 50_000_000 // 50ms
        )
        watcher.start()
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(100))

        // Panel-open wakes are ungated: every debounced append reaches the loop so spend tiles
        // refresh within ~1s of a routed turn.
        let woke = expectation(description: "ledger wake")
        let openObs = center.addObserver(forName: name, object: nil, queue: nil) { _ in
            woke.fulfill()
        }
        try append(line: #"{"at":"2026-09-24T12:00:01Z"}"#, to: ledger)
        await fulfillment(of: [woke], timeout: 2)
        center.removeObserver(openObs)
    }

    func testClosedPanelAppendPostsRateLimitedWake() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ou-ledger-watch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ledger = dir.appendingPathComponent("usage-events.jsonl")
        try Data().write(to: ledger)

        let center = NotificationCenter()
        let name = CodexRouterLedgerWatcher.didChangeNotification
        final class Flag: @unchecked Sendable {
            var open = false
            var wakeCount = 0
        }
        let flag = Flag()
        let watcher = CodexRouterLedgerWatcher(
            ledgerPaths: { [ledger.path] },
            isPanelOpen: { flag.open },
            center: center,
            debounceNanoseconds: 50_000_000, // 50ms
            // Long gate window so the second closed-panel append inside it is provably dropped.
            closedPanelWakeGate: BackgroundRefreshGate(minimumInterval: 60)
        )
        watcher.start()
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(100))

        let obs = center.addObserver(forName: name, object: nil, queue: nil) { _ in
            flag.wakeCount += 1
        }
        defer { center.removeObserver(obs) }

        // Two closed-panel appends inside one gate window coalesce into a single wake; the loop's
        // incremental tail parse catches up on both rows.
        try append(line: #"{"at":"2026-09-24T12:00:00Z"}"#, to: ledger)
        try await Task.sleep(for: .milliseconds(150))
        try append(line: #"{"at":"2026-09-24T12:00:01Z"}"#, to: ledger)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(flag.wakeCount, 1)

        // A panel-open append bypasses the gate even inside its cooldown window.
        flag.open = true
        try append(line: #"{"at":"2026-09-24T12:00:02Z"}"#, to: ledger)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(flag.wakeCount, 2)
    }

    private func append(line: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
    }
}
