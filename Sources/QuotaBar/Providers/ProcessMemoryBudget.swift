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
    /// This machine's log corpora are large enough that one provider's warm working set (Codex tail
    /// items + router index + gateway folds) sits at 310-415 MB. At the previous 320 MB the soft
    /// limit fired after *every* heavy provider mid-batch, unloading the parse caches the next
    /// provider was about to share — each card then cold-reparsed and the batch ran several times
    /// longer than the same batch warm. 512 MB lets a full batch keep its caches; the end-of-cycle
    /// unload (`unloadAfterRefreshCycle`) still settles memory between batches.
    static let softLimitBytes: UInt64 = 512 * 1024 * 1024
    /// Never intentionally allow a sustained footprint above this; callers should drop caches and
    /// avoid starting additional concurrent local-log providers.
    static let hardLimitBytes: UInt64 = 768 * 1024 * 1024

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
