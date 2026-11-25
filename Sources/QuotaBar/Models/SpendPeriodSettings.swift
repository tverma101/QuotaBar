import Foundation

struct SpendPeriodSettings: Codable, Equatable {
    enum Preset: String, CaseIterable, Identifiable, Codable {
        case today = "Today"
        case yesterday = "Yesterday"
        case week = "Last 7 Days"
        case month = "Last 30 Days"
        case custom = "Custom"

        var id: Self { self }
    }

    struct Selection: Codable, Equatable {
        var preset: Preset
        var customDays = 14

        // Bound the picker to the app's retained local history window.
        static let dayRange = 1...3653

        var days: Int {
            switch preset {
            case .today, .yesterday: 1
            case .week: 7
            case .month: 30
            case .custom: min(max(customDays, Self.dayRange.lowerBound), Self.dayRange.upperBound)
            }
        }

        var legacyLineLabel: String? {
            if preset == .yesterday { return "Yesterday" }
            if days == 1 { return "Today" }
            return days == 30 ? "Last 30 Days" : nil
        }

        var title: String {
            if let legacyLineLabel { return legacyLineLabel }
            return "Last \(days) Days"
        }

        var shortTitle: String {
            if days == 1 { return title }
            return "\(days) Days"
        }

        func dayKeys(through now: Date, calendar: Calendar = .current) -> Set<String> {
            let end = preset == .yesterday ? calendar.date(byAdding: .day, value: -1, to: now) : now
            guard let end else { return [] }
            return UsageHistoryWindow.dayKeys(through: end, count: days, calendar: calendar)
        }
    }

    static let key = "QuotaBar.spendPeriodSettings"
    var first = Selection(preset: .today)
    var middle = Selection(preset: .week)
    var last = Selection(preset: .month)

    func selection(for period: TotalSpendPeriod) -> Selection {
        switch period {
        case .today: first
        case .yesterday: middle
        case .last30: last
        }
    }

    func selection(for descriptor: WidgetDescriptor) -> Selection? {
        guard descriptor.isSpendTile, let period = TotalSpendPeriod(rawValue: descriptor.metricLabel) else {
            return nil
        }
        return selection(for: period)
    }
}
