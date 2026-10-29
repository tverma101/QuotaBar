import Foundation
import os

/// The process-shared refresh-order allocator.
///
/// A provider refresh takes a monotonic order *before* its work starts, so a late result can be
/// fenced against a newer one. The order has to be visible to the *other* process that shares this
/// `UserDefaults` domain (`quotabar-cli`), so it is persisted — but not inside the snapshot blob:
/// allocating an order used to re-encode and rewrite the whole (tens of kilobytes) payload just to
/// bump a counter, which doubled the write volume of every refresh pass. It lives in its own small
/// key instead.
///
/// The map is also kept in memory, and re-read only when the persisted bytes change, so the common
/// case costs one small `UserDefaults` read and one small write instead of a whole-blob round trip.
final class RefreshOrderAllocator: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    private let state = OSAllocatedUnfairLock<(bytes: Data?, orders: [String: UInt64])>(
        initialState: (bytes: nil, orders: [:])
    )

    init(defaults: UserDefaults, key: String) {
        self.defaults = defaults
        self.key = key
    }

    /// The highest order issued for `providerID` across every process, never below `floor`.
    ///
    /// `floor` keeps the allocator ahead of the orders the snapshot blob already committed, so a
    /// cleared allocator key cannot hand out an order the cross-process fence would reject.
    func issuedOrder(providerID: String, floor: UInt64) -> UInt64 {
        max(persistedOrders()[providerID] ?? 0, floor)
    }

    /// Reserve the next order for `providerID` — strictly greater than every order issued so far and
    /// than `floor`. `nil` when the sequence is exhausted or the map cannot be encoded.
    func reserve(providerID: String, floor: UInt64) -> UInt64? {
        var updated = persistedOrders()
        let previous = max(updated[providerID] ?? 0, floor)
        guard previous < UInt64.max else { return nil }
        let next = previous + 1
        updated[providerID] = next
        let orders = updated
        guard let data = try? JSONEncoder().encode(orders) else {
            AppLog.warn(.cache, "refresh order map could not be encoded; order not reserved")
            return nil
        }
        defaults.set(data, forKey: key)
        state.withLock { $0 = (bytes: data, orders: orders) }
        return next
    }

    /// The persisted map, decoded only when the bytes on disk changed.
    private func persistedOrders() -> [String: UInt64] {
        let current = defaults.data(forKey: key)
        let cached = state.withLock { $0 }
        if current == cached.bytes { return cached.orders }
        guard let current else {
            state.withLock { $0 = (bytes: nil, orders: [:]) }
            return [:]
        }
        let decoded = (try? JSONDecoder().decode([String: UInt64].self, from: current)) ?? [:]
        state.withLock { $0 = (bytes: current, orders: decoded) }
        return decoded
    }
}
