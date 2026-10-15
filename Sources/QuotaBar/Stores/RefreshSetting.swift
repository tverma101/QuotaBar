import Foundation

/// Single source of truth for the refresh cadence.
///
/// `interval` is the full-detail cadence and cache age for local accounting. Quota meters use a
/// separate one-minute cache/deadline because menu-bar passes skip heavy history folds.
enum RefreshSetting {
    static let defaultMinutes = 5
    static let quotaMinutes = 1
    /// Menu-bar cadence while unplugged or in Low Power Mode; this scope avoids full history scans.
    static let onBatteryBackgroundMinutes = 2

    /// Cache TTL / full-refresh wait while the panel is open. Fixed at 5 minutes so tests and
    /// snapshot freshness stay stable regardless of power source.
    static var interval: TimeInterval {
        TimeInterval(defaultMinutes * 60)
    }

    /// Freshness window for live quota meters in `.menuBar` and `.panelMeters` scopes.
    static var quotaInterval: TimeInterval {
        TimeInterval(quotaMinutes * 60)
    }

    /// The meter cache expires before the scheduler's one-minute deadline. Using the exact same
    /// boundary made fast providers miss the next refresh by a second (or cache-hit at 59s), so
    /// live subscriptions only fetched on every other tick. The 10s margin absorbs request and
    /// clock-boundary jitter without adding extra scheduled passes.
    static var quotaCacheInterval: TimeInterval {
        max(1, quotaInterval - 10)
    }

    /// Sleep between periodic passes when the popover is closed (menu-bar / icons-only scope).
    static var backgroundInterval: TimeInterval {
        if ProcessInfo.processInfo.isLowPowerModeEnabled || PowerSourceInfo.isOnBattery {
            return TimeInterval(onBatteryBackgroundMinutes * 60)
        }
        return quotaInterval
    }
}
