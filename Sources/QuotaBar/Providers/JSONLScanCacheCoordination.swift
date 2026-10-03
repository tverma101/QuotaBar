import Foundation
import Darwin

/// Shares a small CPU allowance across token-history indexing and folding. A process-wide lock keeps
/// simultaneous provider scans from multiplying the allowance; work runs in short synchronous slices
/// and pauses according to process CPU time, so disk wait does not consume the CPU budget. The limit
/// applies to full history refreshes, while menu-bar quota-only passes do no history work and are left
/// alone.
final class JSONLAccountingWorkPacer: @unchecked Sendable {
    static let shared = JSONLAccountingWorkPacer()

    static let targetCPUFraction = 0.092
    private static let maxSleepSliceNanoseconds: UInt64 = 5_000_000

    private let lock = NSLock()

    private init() {}

    @discardableResult
    func perform<T>(enabled: Bool? = nil, _ work: () throws -> T) rethrows -> T {
        guard enabled ?? ProviderRefreshContext.accountingCPUThrottleEnabled else {
            return try work()
        }
        if case .menuBar = ProviderRefreshContext.scope { return try work() }

        lock.lock()
        defer { lock.unlock() }

        let startedAt = DispatchTime.now().uptimeNanoseconds
        let cpuStartedAt = processCPUNanoseconds()
        defer {
            let cpuElapsed = processCPUNanoseconds() &- cpuStartedAt
            let targetElapsed = UInt64(Double(cpuElapsed) / Self.targetCPUFraction)
            let targetEnd = startedAt &+ targetElapsed
            while !Task.isCancelled {
                let now = DispatchTime.now().uptimeNanoseconds
                guard now < targetEnd else { break }
                let remaining = targetEnd &- now
                Thread.sleep(forTimeInterval: Double(min(remaining, Self.maxSleepSliceNanoseconds)) / 1_000_000_000)
            }
        }
        return try work()
    }

    /// Run collection folds in bounded pieces so non-JSONL aggregation and deduplication share the
    /// same process-wide CPU allowance as file parsing and cache hydration.
    func forEach<Element>(
        _ elements: [Element],
        batchSize: Int = 512,
        _ body: (Element) -> Void
    ) {
        precondition(batchSize > 0)
        let enabled = ProviderRefreshContext.accountingCPUThrottleEnabled
            && ProviderRefreshContext.scope.isFull
        guard enabled else {
            elements.forEach(body)
            return
        }

        var start = 0
        while start < elements.count {
            let end = min(start + batchSize, elements.count)
            perform {
                for index in start..<end {
                    body(elements[index])
                }
            }
            start = end
        }
    }

    private func processCPUNanoseconds() -> UInt64 {
        var usage = rusage()
        precondition(getrusage(RUSAGE_SELF, &usage) == 0, "getrusage(RUSAGE_SELF) failed")
        let user = UInt64(usage.ru_utime.tv_sec) * 1_000_000_000
            + UInt64(usage.ru_utime.tv_usec) * 1_000
        let system = UInt64(usage.ru_stime.tv_sec) * 1_000_000_000
            + UInt64(usage.ru_stime.tv_usec) * 1_000
        return user + system
    }
}

/// One process-wide background parse budget. Provider scanners each keep their own local fanout cap,
/// but every actual JSONL parse also passes through this semaphore so independently bounded scanners
/// cannot multiply into a launch-time CPU/I/O spike.
private actor JSONLProcessParseBudget {
    static let shared = JSONLProcessParseBudget(limit: 2)

    private struct Waiter {
        var id: UUID
        var continuation: CheckedContinuation<Bool, Never>
    }

    private var available: Int
    private var waiters: [Waiter] = []

    init(limit: Int) {
        precondition(limit > 0)
        self.available = limit
    }

    func acquire() async -> Bool {
        guard !Task.isCancelled else { return false }
        if available > 0 {
            available -= 1
            return true
        }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiters.append(Waiter(id: waiterID, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancel(waiterID: waiterID) }
        }
    }

    func release() {
        guard !waiters.isEmpty else {
            available += 1
            return
        }
        waiters.removeFirst().continuation.resume(returning: true)
    }

    private func cancel(waiterID: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == waiterID }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }
}

/// A scanner-local parse budget layered on top of the process-wide budget. `limit` preserves each
/// scanner's own fanout contract while `JSONLProcessParseBudget` keeps the entire menu-bar process to
/// at most two simultaneous JSONL reads/parsers across Claude, Codex, Grok, pi, homes, and accounts.
actor JSONLParsePermitPool {
    private struct Waiter {
        var id: UUID
        var continuation: CheckedContinuation<Bool, Never>
    }

    private var available: Int
    private var waiters: [Waiter] = []

    init(limit: Int) {
        precondition(limit > 0)
        self.available = limit
    }

    func acquire() async -> Bool {
        guard await acquireLocal() else { return false }
        guard await JSONLProcessParseBudget.shared.acquire() else {
            releaseLocal()
            return false
        }
        return true
    }

    func release() async {
        await JSONLProcessParseBudget.shared.release()
        releaseLocal()
    }

    private func acquireLocal() async -> Bool {
        guard !Task.isCancelled else { return false }
        if available > 0 {
            available -= 1
            return true
        }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiters.append(Waiter(id: waiterID, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancel(waiterID: waiterID) }
        }
    }

    private func releaseLocal() {
        guard !waiters.isEmpty else {
            available += 1
            return
        }
        waiters.removeFirst().continuation.resume(returning: true)
    }

    private func cancel(waiterID: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == waiterID }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }
}

enum PersistentJSONLScanCaches {
    /// A one-shot CLI has no run loop to outlive the debounce, so it explicitly drains every local-log
    /// parser before returning. Scanners without pending work return immediately.
    static func flushPendingWrites() async {
        await ClaudeLogUsageScanner.flushPersistentCacheWrites()
        await CodexLogUsageScanner.flushPersistentCacheWrites()
        await CodexRouterUsageScanner.flushPersistentCacheWrites()
        await GrokLogUsageScanner.flushPersistentCacheWrites()
        await MuseUsageScanner.flushPersistentCacheWrites()
        await PiUsageScanner.flushPersistentCacheWrites()
    }

    /// Bound process-wide RAM after a full provider refresh settles: flush pending disk upserts, then
    /// drop Codex *session* sharedTailCache Event arrays (checkpoints remain). Keep the bounded
    /// CodexRouter parsed index warm only while the panel is open, when ledger appends can trigger
    /// immediate refreshes and repeated plist hydration would otherwise cost CPU.
    ///
    /// Deliberately does **not** unload `CodexRouterUsageScanner`'s append-only tail items: that
    /// ledger is append-heavy (~15MB / tens of thousands of rows) and shared by every Codex card.
    /// Routine unload forced a full reparse on the next panel-open full refresh (itemsAvailable=false
    /// cannot tail-merge). The router cache is already capped (`maxRetainedItems`); memory-pressure
    /// still clears it via `unloadForMemoryPressure`.
    static func unloadAfterRefreshCycle(keepRouterItemsResident: Bool = false) async {
        await flushPendingWrites()
        CodexLogUsageScanner.unloadSharedTailCacheItems()
        if keepRouterItemsResident {
            await CodexRouterUsageScanner.resumeSharedParsedItems()
        } else {
            CodexRouterUsageScanner.unloadSharedTailCacheItems()
            await CodexRouterUsageScanner.unloadSharedParsedItems()
        }
        if let summary = ProcessMemoryBudget.footprintSummary() {
            AppLog.debug(.refresh, "post-unload footprint \(summary)")
        }
    }

    /// Call after a heavy local-log provider (Codex / Claude / OpenCode / …) finishes: unload session
    /// parse arrays immediately so concurrent cards cannot stack multi-home Event buffers into a GB
    /// spike. Router ledger items stay resident (see `unloadAfterRefreshCycle`).
    static func unloadAfterHeavyProvider(providerID: String) async {
        CodexLogUsageScanner.unloadSharedTailCacheItems()
        if ProcessMemoryBudget.isOverSoftLimit {
            await flushPendingWrites()
            CodexLogUsageScanner.unloadSharedTailCacheItems()
            // Soft limit is the one place routine paths may drop the router tail: RSS is already over
            // budget. Prefer this over waiting for a kernel memory-pressure event.
            CodexRouterUsageScanner.unloadSharedTailCacheItems()
            await CodexRouterUsageScanner.unloadSharedParsedItems()
            if let summary = ProcessMemoryBudget.footprintSummary() {
                AppLog.info(
                    .refresh,
                    "memory soft-limit hit after \(providerID); unloaded parse caches (\(summary))"
                )
            }
        }
    }

    /// Memory-pressure / hard-limit path: flush and unload even mid-cycle (including the router tail).
    static func unloadForMemoryPressure() async {
        await flushPendingWrites()
        CodexLogUsageScanner.unloadSharedTailCacheItems()
        CodexRouterUsageScanner.unloadSharedTailCacheItems()
        await CodexRouterUsageScanner.unloadSharedParsedItems()
        if let summary = ProcessMemoryBudget.footprintSummary() {
            AppLog.warn(.refresh, "memory-pressure unload complete (\(summary))")
        }
    }
}
