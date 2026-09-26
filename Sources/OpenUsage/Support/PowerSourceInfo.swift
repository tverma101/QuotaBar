import Foundation
import IOKit.ps

/// Lightweight AC-vs-battery probe for the background refresh cadence.
///
/// Reads the IOKit power-sources list once per call. Used only to stretch the *icons-only*
/// background interval while unplugged; it never gates on-open or manual full refreshes.
enum PowerSourceInfo {
    /// True when at least one power source reports drawing from battery (not AC Power).
    static var isOnBattery: Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else {
            return false
        }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  let state = description[kIOPSPowerSourceStateKey as String] as? String
            else {
                continue
            }
            if state == (kIOPSBatteryPowerValue as String) {
                return true
            }
        }
        return false
    }
}
