import Foundation
import XCTest
@testable import QuotaBar

/// Throwaway CI probe: one CI run reveals which Task-closure shapes the CI toolchain's
/// region-based isolation checker rejects, so the real cancel tests can be rewritten into a
/// shape it accepts. Deleted once the ClaudeSessionAppendCache compile failures are resolved.
final class IsolationBisectTests: XCTestCase {
    // MARK: Controls — shapes that compile elsewhere in this target

    /// No captures, nonisolated static call via Self.
    func testControlStaticSelfNoCaptures() async {
        let task = Task { Self.returnOne() }
        _ = await task.value
    }

    /// Captures a Sendable class instance, calls an instance method (Antigravity-style).
    func testControlInstanceMethod() async {
        let cache = ClaudeSessionAppendCache()
        let task = Task { cache.entryCountForTesting() }
        _ = await task.value
    }

    // MARK: Hypothesis variants

    /// Captures a Sendable class instance, calls a nonisolated static via Self.
    func testCaptureClassStaticSelf() async {
        let cache = ClaudeSessionAppendCache()
        let task = Task { Self.count(cache) }
        _ = await task.value
    }

    /// Captures a URL only, calls a nonisolated static via Self.
    func testCaptureURLStaticSelf() async {
        let url = URL(fileURLWithPath: "/tmp/quotabar-bisect")
        let task = Task { Self.urlLength(url) }
        _ = await task.value
    }

    /// Yield loop, no captures.
    func testYieldNoCaptures() async {
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return Self.returnOne()
        }
        _ = await task.value
    }

    /// Full replica of the failing cancelled-scan shape: yield loop + class + URL + static.
    func testReplicaYieldClassURL() async {
        let cache = ClaudeSessionAppendCache()
        let url = URL(fileURLWithPath: "/tmp/quotabar-bisect")
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return Self.count2(cache, url)
        }
        _ = await task.value
    }

    /// Replica without the yield loop (the cancelled-fragment shape).
    func testReplicaClassURL() async {
        let cache = ClaudeSessionAppendCache()
        let url = URL(fileURLWithPath: "/tmp/quotabar-bisect")
        let task = Task { Self.count2(cache, url) }
        _ = await task.value
    }

    /// Original shape: instance parse call with a closure argument formed inside the Task.
    func testReplicaOriginalParse() async {
        let cache = ClaudeSessionAppendCache()
        let url = URL(fileURLWithPath: "/tmp/quotabar-bisect")
        let task = Task { cache.parse(at: url, parseLine: Self.parseLineBisect) }
        _ = await task.value
    }

    /// Detached variant of the replica.
    func testDetachedReplica() async {
        let cache = ClaudeSessionAppendCache()
        let url = URL(fileURLWithPath: "/tmp/quotabar-bisect")
        let task = Task.detached { Self.count2(cache, url) }
        _ = await task.value
    }

    /// Same replica body from a throwing enclosing context.
    func testThrowingEnclosing() async throws {
        let cache = ClaudeSessionAppendCache()
        let url = URL(fileURLWithPath: "/tmp/quotabar-bisect")
        let task = Task { Self.count2(cache, url) }
        _ = await task.value
    }

    /// Capture the locally defined function in the Task operation closure.
    /// Task(body) has no matching initializer on the CI Swift toolchain.
    func testLocalFunctionValue() async {
        let cache = ClaudeSessionAppendCache()
        let url = URL(fileURLWithPath: "/tmp/quotabar-bisect")
        func body() -> Int { Self.count2(cache, url) }
        let task = Task { body() }
        _ = await task.value
    }

    // MARK: - Helpers

    private nonisolated static func returnOne() -> Int { 1 }

    private nonisolated static func count(_ cache: ClaudeSessionAppendCache) -> Int {
        cache.entryCountForTesting()
    }

    private nonisolated static func count2(_ cache: ClaudeSessionAppendCache, _ url: URL) -> Int {
        cache.entryCountForTesting()
    }

    private nonisolated static func urlLength(_ url: URL) -> Int { 1 }

    private nonisolated static func parseLineBisect(
        _ line: Data.SubSequence
    ) -> [ClaudeLogUsageScanner.Entry]? { nil }
}
