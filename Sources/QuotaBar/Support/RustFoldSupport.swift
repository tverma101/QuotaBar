import Foundation
import os

/// Which pricing source a fold uses. `backend` lets Rust resolve model names from one snapshot per
/// `ModelPricing`; `inline` keeps the pre-resolved rate table so the Swift resolver stays exercised
/// as the parity oracle and can be measured against the backend path.
enum RustFoldPricingMode: Sendable {
    case backend
    case inline
}

/// Shared inputs for the Rust accounting folds (`claude.fold`, `codex.fold`).
///
/// The folds still take calendar policy from Swift:
///
/// - `DayBoundaries` is the local-calendar day map for the scan window, built with the same
///   `Calendar.current` and `DailyUsageAccumulator.dayKey` the Swift fold uses. Rust only picks the
///   last boundary at or before a timestamp, so month/day bucketing cannot drift.
/// - `encodeRates` serializes an already-resolved `ModelRates` value for the inline fallback path.
///   The default path sends model names plus a backend snapshot handle, and Rust resolves them.
enum RustFoldSupport {
    /// Wire shape of a fold response: the scan plus the names that need an OpenRouter catalogue
    /// recheck, reported once per backend snapshot.
    struct FoldEnvelope: Decodable {
        let scan: LogUsageScan
        let recheckModels: [String]
    }

    #if DEBUG
    /// Test-only evidence that a scan was actually served by the backend rather than silently
    /// falling back to the Swift oracle. Never read by shipping code.
    private static let completedFolds = OSAllocatedUnfairLock(initialState: 0)
    static var completedFoldsForTesting: Int { completedFolds.withLock { $0 } }
    static func noteCompletedFold() { completedFolds.withLock { $0 += 1 } }

    /// Test-only evidence that a fold priced through the Rust snapshot rather than the inline table.
    private static let backendPricedFolds = OSAllocatedUnfairLock(initialState: 0)
    static var backendPricedFoldsForTesting: Int { backendPricedFolds.withLock { $0 } }
    static func noteBackendPricedFold() { backendPricedFolds.withLock { $0 += 1 } }
    #endif

    /// Ascending local-day starts and their `yyyy-MM-dd` keys.
    struct DayBoundaries: Sendable {
        private let starts: [Double]
        private let keys: [String]

        /// The window from `since`'s local day through `now`'s local day, inclusive.
        static func build(
            since: Date,
            now: Date,
            calendar: Calendar = .current
        ) -> DayBoundaries {
            let end = calendar.startOfDay(for: now)
            var cursor = calendar.startOfDay(for: since)
            var starts: [Double] = []
            var keys: [String] = []
            // The lifetime window is ten years; cap at twelve so a poisoned date cannot spin here.
            while cursor <= end, starts.count < 4_400 {
                starts.append(cursor.timeIntervalSince1970)
                keys.append(DailyUsageAccumulator.dayKey(from: cursor, calendar: calendar))
                guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
                cursor = next
            }
            if starts.isEmpty {
                starts = [cursor.timeIntervalSince1970]
                keys = [DailyUsageAccumulator.dayKey(from: cursor, calendar: calendar)]
            }
            return DayBoundaries(starts: starts, keys: keys)
        }

        /// The `[[start, "yyyy-MM-dd"], …]` shape the backend parses.
        var jsonObject: [[Any]] {
            zip(starts, keys).map { [$0.0, $0.1] as [Any] }
        }
    }

    /// Serialize the rates `ModelPricing.resolve` returned for one model. Nil means the model is
    /// unpriced, which the fold reports as an unknown model rather than inventing dollars.
    static func encodeRates(_ rates: ModelRates) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(rates),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }

    /// Restore the exact ordering `DailyUsageAccumulator.build` promises: cost descending (nil as
    /// zero), tokens descending, then `localizedStandardCompare` on the name. Rust applies the
    /// numeric order; the localized tie-break stays here because it is a Foundation comparator.
    static func normalize(_ scan: LogUsageScan) -> LogUsageScan {
        guard var usage = scan.modelUsage else { return scan }
        usage.daily = usage.daily.map { day in
            var day = day
            day.models.sort { lhs, rhs in
                let lhsCost = lhs.costUSD ?? 0
                let rhsCost = rhs.costUSD ?? 0
                if lhsCost != rhsCost { return lhsCost > rhsCost }
                if lhs.totalTokens != rhs.totalTokens { return lhs.totalTokens > rhs.totalTokens }
                return lhs.model.localizedStandardCompare(rhs.model) == .orderedAscending
            }
            return day
        }
        var normalized = scan
        normalized.modelUsage = usage
        return normalized
    }
}
