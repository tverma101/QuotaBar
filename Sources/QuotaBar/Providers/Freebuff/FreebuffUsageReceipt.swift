import Foundation

/// Only accounting fields survive a hosted history response; never retain prompts or events.
struct FreebuffUsageReceipt: Codable, Equatable, Sendable {
    var id: String
    var timestampMs: Double
    var metricsJSON: String
    var model: String?

    var scannerRow: [String: Any] {
        ["id": id, "timestamp": String(timestampMs), "metrics": metricsJSON,
         "selectedModel": model ?? ""]
    }
}

extension FreebuffDesktopUsageScanner {
    /// Conservative estimate for the retained aggregate. It includes collection overhead and
    /// strings, and stops as soon as the cap is crossed so a pathological breakdown adds little work.
    static func fitsCachedScanBudget(_ scan: Scan) -> Bool {
        var bytes = 512
        func account(_ amount: Int) -> Bool {
            let (total, overflow) = bytes.addingReportingOverflow(amount)
            guard !overflow, total <= maximumCachedScanBytes else { return false }
            bytes = total
            return true
        }

        for day in scan.usage.series.daily {
            guard account(160 + day.date.utf8.count) else { return false }
        }
        for day in scan.usage.modelUsage?.daily ?? [] {
            guard account(112 + day.date.utf8.count) else { return false }
            for model in day.models {
                guard account(192 + model.model.utf8.count) else { return false }
                for variant in model.variants ?? [] {
                    guard account(128 + variant.model.utf8.count) else { return false }
                }
            }
        }
        for (day, models) in scan.usage.unknownModelsByDay {
            guard account(96 + day.utf8.count) else { return false }
            for model in models {
                guard account(80 + model.utf8.count) else { return false }
            }
        }
        for (day, _) in scan.usage.apiEstimateByDay ?? [:] {
            guard account(96 + day.utf8.count) else { return false }
        }
        for day in scan.partialDays {
            guard account(64 + day.utf8.count) else { return false }
        }
        for day in scan.usage.apiEstimateIncompleteDays ?? [] {
            guard account(64 + day.utf8.count) else { return false }
        }
        for day in scan.usage.estimatedCostDays ?? [] {
            guard account(64 + day.utf8.count) else { return false }
        }
        for day in scan.usage.unmeasuredUsageDays ?? [] {
            guard account(64 + day.utf8.count) else { return false }
        }
        return true
    }

}
