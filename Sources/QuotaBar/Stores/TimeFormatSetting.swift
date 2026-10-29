import Foundation
import os

/// How wall-clock times read (the absolute reset labels): the system's 12/24-hour convention, or
/// an explicit override — matching the original app's Auto/12h/24h setting.
enum TimeFormatSetting: String, Hashable, Sendable, CaseIterable, UserDefaultsBacked {
    case auto
    case twelveHour = "12h"
    case twentyFourHour = "24h"

    static let key = "timeFormat"
    static var fallback: TimeFormatSetting { .auto }

    // `current` (the user's current choice, read live) comes from `UserDefaultsBacked`.

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .twelveHour: return "12-hour"
        case .twentyFourHour: return "24-hour"
        }
    }

    /// Short time string ("5:30 PM" / "17:30") honoring the override, via the locale's hour cycle.
    ///
    /// The locale is cached per (setting, base locale). `Locale.Components(locale:)` +
    /// `Locale(components:)` are among the priciest Foundation constructors and this used to run per
    /// absolute reset label per render — across a dashboard of rows that is dozens per mount.
    private static let locales = OSAllocatedUnfairLock<[String: Locale]>(initialState: [:])

    func shortTime(_ date: Date, base: Locale = .current) -> String {
        let locale = Self.cachedLocale(for: self, base: base)
        return date.formatted(
            Date.FormatStyle(date: .omitted, time: .shortened, locale: locale)
        )
    }

    private static func cachedLocale(for setting: TimeFormatSetting, base: Locale) -> Locale {
        let key = "\(setting.rawValue)|\(base.identifier)"
        return locales.withLock { cache in
            if let cached = cache[key] { return cached }
            var components = Locale.Components(locale: base)
            switch setting {
            case .auto:
                break
            case .twelveHour:
                components.hourCycle = .oneToTwelve
            case .twentyFourHour:
                components.hourCycle = .zeroToTwentyThree
            }
            let locale = Locale(components: components)
            cache[key] = locale
            return locale
        }
    }
}
