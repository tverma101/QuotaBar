import XCTest
@testable import OpenUsage

final class CodexRouterLedgerWatcherTests: XCTestCase {
    func testLedgerAppendPostsWakeOnlyWhilePanelOpen() async throws {
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
            var wokeClosed = false
        }
        let flag = Flag()
        let watcher = CodexRouterLedgerWatcher(
            ledgerPaths: { [ledger.path] },
            isPanelOpen: { flag.open },
            center: center,
            debounceNanoseconds: 50_000_000 // 50ms
        )
        watcher.start()
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(100))

        let closedObs = center.addObserver(forName: name, object: nil, queue: nil) { _ in
            flag.wokeClosed = true
        }
        try append(line: #"{"at":"2026-09-24T12:00:00Z"}"#, to: ledger)
        try await Task.sleep(for: .milliseconds(200))
        center.removeObserver(closedObs)
        XCTAssertFalse(flag.wokeClosed)

        flag.open = true
        let woke = expectation(description: "ledger wake")
        let openObs = center.addObserver(forName: name, object: nil, queue: nil) { _ in
            woke.fulfill()
        }
        try append(line: #"{"at":"2026-09-24T12:00:01Z"}"#, to: ledger)
        await fulfillment(of: [woke], timeout: 2)
        center.removeObserver(openObs)
    }

    private func append(line: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
    }
}
