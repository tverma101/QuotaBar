import Foundation

/// Single source of truth for the refresh cadence.
///
/// `interval` is the snapshot-cache TTL and the full-detail cadence while the popover is open (and
/// what tests assert). The periodic loop sleeps on `backgroundInterval` while the panel is closed —
/// still 5 minutes on AC, stretched to 15 minutes on battery / Low Power Mode — so Session/Weekly
/// icons keep updating without a full JSONL history scan every tick.
enum RefreshSetting {
    static let defaultMinutes = 5
    /// Background icons-only cadence while unplugged or in Low Power Mode.
    static let onBatteryBackgroundMinutes = 15

    /// Cache TTL / full-refresh wait while the panel is open. Fixed at 5 minutes so tests and
    /// snapshot freshness stay stable regardless of power source.
    static var interval: TimeInterval {
        TimeInterval(defaultMinutes * 60)
    }

    /// Sleep between periodic passes when the popover is closed (menu-bar / icons-only scope).
    static var backgroundInterval: TimeInterval {
        if ProcessInfo.processInfo.isLowPowerModeEnabled || PowerSourceInfo.isOnBattery {
            return TimeInterval(onBatteryBackgroundMinutes * 60)
        }
        return interval
    }
}
