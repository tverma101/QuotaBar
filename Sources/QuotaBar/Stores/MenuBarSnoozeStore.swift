import Foundation
import Observation

enum SnoozeThreshold: Double, CaseIterable, Sendable {
    case outOfUsage = 0.0
    case fivePercent = 0.05
    case tenPercent = 0.10
    case fifteenPercent = 0.15
    case twentyPercent = 0.20

    var label: String {
        switch self {
        case .outOfUsage: return "0% (Out of Usage)"
        case .fivePercent: return "Below 5%"
        case .tenPercent: return "Below 10%"
        case .fifteenPercent: return "Below 15%"
        case .twentyPercent: return "Below 20%"
        }
    }
}

struct SnoozeStatus: Equatable, Sendable {
    let isSnoozed: Bool
    let text: String
    let resetsAt: Date?
}

@MainActor
@Observable
final class MenuBarSnoozeStore {
    private let defaults: UserDefaults

    static let enabledKey = "quotabar.snooze.enabled"
    static let thresholdKey = "quotabar.snooze.threshold"
    static let excludedSubscriptionsKey = "quotabar.snooze.excludedSubscriptions"
    static let manualSnoozeUntilKey = "quotabar.snooze.manualSnoozeUntil"

    var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Self.enabledKey) }
    }

    var threshold: SnoozeThreshold {
        didSet { defaults.set(threshold.rawValue, forKey: Self.thresholdKey) }
    }

    var excludedProviderIDs: Set<String> {
        didSet { defaults.set(Array(excludedProviderIDs).sorted(), forKey: Self.excludedSubscriptionsKey) }
    }

    var manualSnoozeUntil: [String: Date] {
        didSet {
            let timestamps = manualSnoozeUntil.mapValues { $0.timeIntervalSince1970 }
            defaults.set(timestamps, forKey: Self.manualSnoozeUntilKey)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isEnabled = defaults.bool(forKey: Self.enabledKey, default: false)
        let savedThreshold = defaults.object(forKey: Self.thresholdKey) as? Double ?? SnoozeThreshold.outOfUsage.rawValue
        self.threshold = SnoozeThreshold(rawValue: savedThreshold) ?? .outOfUsage
        self.excludedProviderIDs = Set(defaults.stringArray(forKey: Self.excludedSubscriptionsKey) ?? [])
        if let savedMap = defaults.dictionary(forKey: Self.manualSnoozeUntilKey) as? [String: Double] {
            self.manualSnoozeUntil = savedMap.mapValues { Date(timeIntervalSince1970: $0) }
        } else {
            self.manualSnoozeUntil = [:]
        }
    }

    func isSubscriptionEnabled(_ providerID: String) -> Bool {
        !excludedProviderIDs.contains(providerID)
    }

    func setSubscriptionEnabled(_ providerID: String, enabled: Bool) {
        if enabled {
            excludedProviderIDs.remove(providerID)
        } else {
            excludedProviderIDs.insert(providerID)
        }
    }

    func snoozeUntilReset(providerID: String, resetsAt: Date) {
        manualSnoozeUntil[providerID] = resetsAt
    }

    func unSnooze(providerID: String) {
        manualSnoozeUntil.removeValue(forKey: providerID)
    }

    func isSnoozed(
        providerID: String,
        pinnedMetrics: [WidgetDescriptor],
        data: (WidgetDescriptor) -> WidgetData,
        now: Date = Date()
    ) -> Bool {
        if let manualDate = manualSnoozeUntil[providerID], manualDate > now {
            return true
        }
        guard isEnabled, isSubscriptionEnabled(providerID) else {
            return false
        }
        let auto = evaluateAutoSnooze(pinnedMetrics: pinnedMetrics, data: data, now: now)
        return auto.isSnoozed
    }

    func evaluateAutoSnooze(
        pinnedMetrics: [WidgetDescriptor],
        data: (WidgetDescriptor) -> WidgetData,
        now: Date = Date()
    ) -> (isSnoozed: Bool, reason: String?, resetsAt: Date?) {
        let bounded = pinnedMetrics.filter { $0.sample.isBounded }
        guard !bounded.isEmpty else {
            return (false, nil, nil)
        }
        let datas = bounded.map { (descriptor: $0, data: data($0)) }.filter { $0.data.hasData }
        guard !datas.isEmpty else {
            return (false, nil, nil)
        }
        // Active countdown sessions (e.g. Freebuff) are running tasks and should not be auto-snoozed.
        for item in datas {
            if item.data.trayStyle.isCountdown, item.data.traySessionExpiriesAt.contains(where: { $0 > now }) {
                return (false, nil, nil)
            }
        }
        let cutoff = threshold.rawValue
        for item in datas {
            let remaining = item.data.remainingFraction
            let isSpent = item.data.meterState(now: now) == .spent || remaining <= 0.0001
            let isBelow = isSpent || (cutoff > 0.0001 && remaining <= cutoff)
            if isBelow {
                let percentText = "\(Int((remaining * 100).rounded()))%"
                let reason: String
                if isSpent {
                    reason = "\(item.descriptor.metricLabel) out of usage"
                } else {
                    reason = "\(item.descriptor.metricLabel) \(percentText) left"
                }
                return (true, reason, item.data.resetsAt)
            }
        }
        return (false, nil, nil)
    }

    func statusText(
        for providerID: String,
        pinnedMetrics: [WidgetDescriptor],
        data: (WidgetDescriptor) -> WidgetData,
        now: Date = Date()
    ) -> SnoozeStatus? {
        if let manualDate = manualSnoozeUntil[providerID], manualDate > now {
            let timeStr = Formatters.compactDuration(manualDate.timeIntervalSince(now)) ?? "<1m"
            return SnoozeStatus(isSnoozed: true, text: "Manually snoozed (\(timeStr) left)", resetsAt: manualDate)
        }
        guard isEnabled else { return nil }
        guard isSubscriptionEnabled(providerID) else {
            return SnoozeStatus(isSnoozed: false, text: "Snooze disabled for this subscription", resetsAt: nil)
        }
        let auto = evaluateAutoSnooze(pinnedMetrics: pinnedMetrics, data: data, now: now)
        if auto.isSnoozed {
            var text = auto.reason ?? "Out of usage"
            if let resetsAt = auto.resetsAt, resetsAt > now {
                if let duration = Formatters.compactDuration(resetsAt.timeIntervalSince(now)) {
                    text += " • Resets in \(duration)"
                }
            }
            return SnoozeStatus(isSnoozed: true, text: "Snoozed (\(text))", resetsAt: auto.resetsAt)
        }
        return SnoozeStatus(isSnoozed: false, text: "Active", resetsAt: nil)
    }

    func snoozedProviderIDs(
        groups: [ProviderMetrics],
        data: (WidgetDescriptor) -> WidgetData,
        now: Date = Date()
    ) -> Set<String> {
        var result = Set<String>()
        for group in groups {
            let metrics = group.alwaysShownMetrics + group.expandedMetrics
            if isSnoozed(providerID: group.provider.id, pinnedMetrics: metrics, data: data, now: now) {
                result.insert(group.provider.id)
            }
        }
        return result
    }

    func resetToDefaults() {
        isEnabled = false
        threshold = .outOfUsage
        excludedProviderIDs = []
        manualSnoozeUntil = [:]
        defaults.removeObject(forKey: Self.enabledKey)
        defaults.removeObject(forKey: Self.thresholdKey)
        defaults.removeObject(forKey: Self.excludedSubscriptionsKey)
        defaults.removeObject(forKey: Self.manualSnoozeUntilKey)
    }
}
