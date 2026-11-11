import Darwin
import Foundation

/// Process-wide physical-footprint budget for the menu-bar app.
///
/// QuotaBar can transiently allocate large JSONL parse arrays while scanning multi-GB Codex/
/// Claude corpora. Soft/hard limits keep that peak from climbing into the gigabyte range: over
/// soft we unload caches aggressively; over hard we also ask callers to serialize heavy work.
enum ProcessMemoryBudget {
    /// Prefer staying under this settled/peak soft ceiling after unload.
    ///
    /// Capped to 96 MB so background idle footprint stays lean; over soft budget we unload parse
    /// caches aggressively and serialize heavy local-log providers.
    static let softLimitBytes: UInt64 = 96 * 1024 * 1024
    /// Never intentionally allow a sustained footprint above this; callers drop caches and
    /// avoid starting additional concurrent local-log providers.
    static let hardLimitBytes: UInt64 = 160 * 1024 * 1024

    /// Current `phys_footprint` for this process, or `nil` when the kernel query fails.
    static func physicalFootprintBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<natural_t>.stride
        )
        let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return UInt64(info.phys_footprint)
    }

    /// Hand the allocator's free pages back to the OS.
    ///
    /// Heavy provider folds (multi-GB JSONL corpora, 30-day token aggregates) transiently grow the
    /// malloc zone by hundreds of MB; libmalloc parks the freed blocks on its free lists instead of
    /// returning the pages, so the process keeps a dirty footprint many times its live heap even
    /// long after every cache has been unloaded. Pressure relief (`nil` zone = all zones, goal 0 =
    /// maximal) releases exactly the free blocks — live allocations are untouched, so this is safe
    /// to call after every refresh cycle, and the next fold only pays the normal page-fault cost of
    /// regrowing its scratch space. Returns the bytes actually released, for logging.
    @discardableResult
    static func releaseAllocatorFreePages() -> UInt64 {
        var total: size_t = malloc_zone_pressure_relief(nil, 0)
        if let defaultZone = malloc_default_zone() {
            total += malloc_zone_pressure_relief(defaultZone, 0)
        }
        return total > 0 ? UInt64(total) : 0
    }

    /// Footprint the last `reliefCheckpointIfGrown` relief returned pages at. Guarded by
    /// `reliefBaselineLock`; `nonisolated(unsafe)` only silences the check the lock already covers.
    private static let reliefBaselineLock = NSLock()
    private nonisolated(unsafe) static var reliefBaselineFootprint: UInt64 = 0
    /// Cumulative bytes returned by `reliefCheckpointIfGrown` since launch, for the cycle-end log.
    private nonisolated(unsafe) static var checkpointReliefTotalBytes: UInt64 = 0

    /// Total bytes `reliefCheckpointIfGrown` has handed back since launch (`nil` probes unavailable).
    static var checkpointReliefSummary: String? {
        reliefBaselineLock.lock()
        defer { reliefBaselineLock.unlock() }
        guard checkpointReliefTotalBytes > 0 else { return nil }
        return String(format: "%.0f MB", Double(checkpointReliefTotalBytes) / (1024.0 * 1024.0))
    }

    /// Relief checkpoint for long-running scans: hand freed pages back only once the footprint has
    /// grown `growthBytes` past the last checkpoint.
    ///
    /// A multi-GB JSONL fold frees each line's parse objects immediately, but libmalloc parks them
    /// on its free lists and the fold's later allocations cannot always reuse them, so the zone (and
    /// with it `phys_footprint`) climbs through the fold and the residue interleaves with the live
    /// heap as un-returnable fragmentation. Checking in periodically returns the churn while it is
    /// still contiguous, capping the fold's peak and the fragmentation the settled footprint keeps.
    /// The footprint probe is a single mach trap, so callers may offer every chunk; relief itself
    /// (a free-list walk) runs only when the threshold is crossed, and small tail reads — which grow
    /// the footprint by far less than the threshold — never pay it.
    @discardableResult
    static func reliefCheckpointIfGrown(by growthBytes: UInt64 = 16 * 1024 * 1024) -> UInt64 {
        guard let current = physicalFootprintBytes() else { return 0 }
        reliefBaselineLock.lock()
        let baseline = reliefBaselineFootprint
        reliefBaselineLock.unlock()
        guard current >= baseline + growthBytes else { return 0 }
        let released = releaseAllocatorFreePages()
        reliefBaselineLock.lock()
        reliefBaselineFootprint = physicalFootprintBytes() ?? current
        checkpointReliefTotalBytes += released
        reliefBaselineLock.unlock()
        if released > 0 {
            AppLog.debug(
                .refresh,
                String(format: "relief checkpoint returned %.0f MB", Double(released) / (1024.0 * 1024.0))
            )
        }
        return released
    }

    static var isOverSoftLimit: Bool {
        guard let bytes = physicalFootprintBytes() else { return false }
        return bytes >= softLimitBytes
    }

    static var isOverHardLimit: Bool {
        guard let bytes = physicalFootprintBytes() else { return false }
        return bytes >= hardLimitBytes
    }

    /// Human-readable footprint for logs (`nil` when unavailable).
    static func footprintSummary() -> String? {
        guard let bytes = physicalFootprintBytes() else { return nil }
        let mb = Double(bytes) / (1024.0 * 1024.0)
        return String(format: "%.0f MB", mb)
    }
}
