import Foundation

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
    /// drop Codex *session* sharedTailCache Event arrays (checkpoints remain).
    ///
    /// Deliberately does **not** unload `CodexRouterUsageScanner`'s append-only tail items: that
    /// ledger is append-heavy (~15MB / tens of thousands of rows) and shared by every Codex card.
    /// Routine unload forced a full reparse on the next panel-open full refresh (itemsAvailable=false
    /// cannot tail-merge). The router cache is already capped (`maxRetainedItems`); memory-pressure
    /// still clears it via `unloadForMemoryPressure`.
    static func unloadAfterRefreshCycle() async {
        await flushPendingWrites()
        CodexLogUsageScanner.unloadSharedTailCacheItems()
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
        if let summary = ProcessMemoryBudget.footprintSummary() {
            AppLog.warn(.refresh, "memory-pressure unload complete (\(summary))")
        }
    }
}
