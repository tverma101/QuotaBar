import Foundation

/// Direct DeepSeek API comparison only. Prices published by DeepSeek; these are not Freebuff charges.
enum FreebuffFlashComparison {
    static let route = "deepseek/deepseek-v4.1-flash"
    private static let effective = Date(timeIntervalSince1970: 1_789_012_800) // 2026-09-10 04:00 UTC
    private static let offPeak = ModelRates(inputPerMillion: 0.15, outputPerMillion: 0.60,
                                            cacheWritePerMillion: 0.15, cacheReadPerMillion: 0.003)
    private static let peak = ModelRates(inputPerMillion: 0.30, outputPerMillion: 1.20,
                                         cacheWritePerMillion: 0.30, cacheReadPerMillion: 0.006)
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    static func matchesRoute(_ route: String) -> Bool {
        let name = route.lowercased()
        let slug = name.hasPrefix("deepseek/") ? String(name.dropFirst("deepseek/".count)) : name
        switch slug {
        case "deepseek-flash", "deepseek-v4-flash", "deepseek-v4-flash-vision-exp",
             "deepseek-v4.1-flash", "deepseek-v4.1-flash-1017", "deepseek-v4.1-flash-fast":
            return true
        default:
            return false
        }
    }

    static func rates(for route: String, at time: Date) -> ModelRates? {
        guard time >= effective, matchesRoute(route) else { return nil }
        let clock = utc.dateComponents([.year, .month, .day, .weekday, .hour], from: time)
        guard let year = clock.year, let month = clock.month, let day = clock.day,
              let weekday = clock.weekday, let hour = clock.hour,
              (2...6).contains(weekday), (1..<4).contains(hour) || (6..<10).contains(hour),
              let holidays = holidaysByYear[year], !holidays.contains(where: { $0.contains(month * 100 + day) })
        else { return offPeak }
        // Both UTC peak windows fall on the same civil date in China.
        return peak
    }

    // State Council schedules: gov.cn/zhengce/zhengceku/202511/content_7047091.htm
    // and gov.cn/zhengce/content/202611/content_7085101.htm. Unknown years use the off-peak baseline.
    private static let holidaysByYear: [Int: [ClosedRange<Int>]] = [
        2026: [101...103, 215...223, 404...406, 501...505, 619...621, 925...927, 1001...1007],
        2027: [101...103, 205...213, 403...405, 501...505, 609...609, 915...915, 1001...1007]
    ]
}
