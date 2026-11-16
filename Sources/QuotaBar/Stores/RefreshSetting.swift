import Foundation

/// Single source of truth for the refresh cadence.
///
/// `interval` is the full-detail cadence and cache age for local accounting. Quota meters use a
/// separate one-minute cache/deadline because menu-bar passes skip heavy history folds. While the
/// panel is closed, the scheduled history fold widens to `backgroundHistoryInterval`; opening the
/// panel always runs a fresh two-phase pass regardless of the deadline.
enum RefreshSetting {
    static let defaultMinutes = 5
    static let quotaMinutes = 1
    /// Menu-bar cadence while unplugged or in Low Power Mode; this scope avoids full history scans.
    static let onBatteryBackgroundMinutes = 2
    /// Scheduled history folds while the panel is closed. Background spend parsing is the
    /// app's largest recurring CPU consumer, and a spend dashboard nobody is looking at does not
    /// need a five-minute rebuild. Panel opens always run a fresh fold (two-phase panel pass) and
    /// ledger wakes still trigger narrow folds, so this only widens the idle deadline.
    static let backgroundHistoryMinutes = 15

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

    /// Scheduled history folds while the panel is closed (15 minutes). Panel opens and explicit
    /// refreshes still fold on demand, so freshness where the user can see it is unchanged; this
    /// only widens the idle deadline for a dashboard nobody is looking at.
    static var backgroundHistoryInterval: TimeInterval {
        TimeInterval(backgroundHistoryMinutes * 60)
    }
}
