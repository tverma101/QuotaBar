import Foundation
import XCTest
@testable import QuotaBar

final class CodexRouterLedgerWatcherTests: XCTestCase {
    private final class PanelState: @unchecked Sendable {
        private let lock = NSLock()
        private var _isOpen = false

        var isOpen: Bool {
            get {
                lock.lock()
                defer { lock.unlock() }
                return _isOpen
            }
            set {
                lock.lock()
                _isOpen = newValue
                lock.unlock()
            }
        }
    }

    func testLedgerAppendPostsWakeWhilePanelOpen() async throws {
        let (directory, ledger) = try makeLedger()
        defer { try? FileManager.default.removeItem(at: directory) }

        let center = NotificationCenter()
        let name = CodexRouterLedgerWatcher.didChangeNotification
        let panel = PanelState()
        panel.isOpen = true
        let watcher = CodexRouterLedgerWatcher(
            ledgerPaths: { [ledger.path] },
            isPanelOpen: { panel.isOpen },
            center: center,
            debounceNanoseconds: 50_000_000
        )
        watcher.start()
        defer { watcher.stop() }
        guard await watcher.waitUntilSourcesArmed() else {
            XCTFail("Ledger vnode source was not armed")
            return
        }

        let woke = expectation(description: "panel-open append wakes the refresh loop")
        let observer = center.addObserver(forName: name, object: nil, queue: nil) { _ in
            woke.fulfill()
        }
        defer { center.removeObserver(observer) }

        try append(line: #"{"at":"2026-09-24T12:00:01Z"}"#, to: ledger)
        await fulfillment(of: [woke], timeout: 5)
    }

    func testClosedPanelAppendPostsRateLimitedWake() async throws {
        let (directory, ledger) = try makeLedger()
        defer { try? FileManager.default.removeItem(at: directory) }

        let center = NotificationCenter()
        let name = CodexRouterLedgerWatcher.didChangeNotification
        let panel = PanelState()
        let watcher = CodexRouterLedgerWatcher(
            ledgerPaths: { [ledger.path] },
            isPanelOpen: { panel.isOpen },
            center: center,
            debounceNanoseconds: 50_000_000,
            closedPanelWakeGate: BackgroundRefreshGate(minimumInterval: 60)
        )
        watcher.start()
        defer { watcher.stop() }
        guard await watcher.waitUntilSourcesArmed() else {
            XCTFail("Ledger vnode source was not armed")
            return
        }

        // First closed-panel append wakes the loop.
        do {
            let first = expectation(description: "first closed-panel wake")
            let observer = center.addObserver(forName: name, object: nil, queue: nil) { _ in
                first.fulfill()
            }
            defer { center.removeObserver(observer) }
            try append(line: #"{"at":"2026-09-24T12:00:00Z"}"#, to: ledger)
            await fulfillment(of: [first], timeout: 5)
        }

        // Another append inside the 60-second gate must not wake it.
        do {
            let suppressed = expectation(description: "second closed-panel wake is gated")
            suppressed.isInverted = true
            let observer = center.addObserver(forName: name, object: nil, queue: nil) { _ in
                suppressed.fulfill()
            }
            defer { center.removeObserver(observer) }
            try append(line: #"{"at":"2026-09-24T12:00:01Z"}"#, to: ledger)
            await fulfillment(of: [suppressed], timeout: 1)
        }

        // Opening the panel bypasses the closed-panel cooldown.
        panel.isOpen = true
        do {
            let resumed = expectation(description: "open-panel wake bypasses closed-panel gate")
            let observer = center.addObserver(forName: name, object: nil, queue: nil) { _ in
                resumed.fulfill()
            }
            defer { center.removeObserver(observer) }
            try append(line: #"{"at":"2026-09-24T12:00:02Z"}"#, to: ledger)
            await fulfillment(of: [resumed], timeout: 5)
        }
    }

    func testPanelOpenAppendHasCooldownGate() async throws {
        let (directory, ledger) = try makeLedger()
        defer { try? FileManager.default.removeItem(at: directory) }

        let center = NotificationCenter()
        let name = CodexRouterLedgerWatcher.didChangeNotification
        let watcher = CodexRouterLedgerWatcher(
            ledgerPaths: { [ledger.path] },
            isPanelOpen: { true },
            center: center,
            debounceNanoseconds: 50_000_000,
            panelOpenWakeGate: BackgroundRefreshGate(minimumInterval: 60)
        )
        watcher.start()
        defer { watcher.stop() }
        guard await watcher.waitUntilSourcesArmed() else {
            XCTFail("Ledger vnode source was not armed")
            return
        }

        do {
            let first = expectation(description: "first panel-open wake")
            let observer = center.addObserver(forName: name, object: nil, queue: nil) { _ in
                first.fulfill()
            }
            defer { center.removeObserver(observer) }
            try append(line: #"{"at":"2026-09-24T12:00:00Z"}"#, to: ledger)
            await fulfillment(of: [first], timeout: 5)
        }

        // Streaming append while the panel is open remains in the 60s cooldown.
        do {
            let suppressed = expectation(description: "panel-open cooldown suppresses second wake")
            suppressed.isInverted = true
            let observer = center.addObserver(forName: name, object: nil, queue: nil) { _ in
                suppressed.fulfill()
            }
            defer { center.removeObserver(observer) }
            try append(line: #"{"at":"2026-09-24T12:00:01Z"}"#, to: ledger)
            await fulfillment(of: [suppressed], timeout: 1)
        }
    }

    private func makeLedger() throws -> (directory: URL, ledger: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("quotabar-ledger-watch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ledger = directory.appendingPathComponent("usage-events.jsonl")
        try Data().write(to: ledger)
        return (directory, ledger)
    }

    private func append(line: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
    }
}
