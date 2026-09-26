import Foundation

/// The saved half of `LayoutStore`. It owns the key names, encoding, and UserDefaults access so the
/// live store can focus on layout rules and user actions.
@MainActor
final class LayoutPersistence {
    private let defaults: UserDefaults
    private let keys: Keys

    init(defaults: UserDefaults, storageKey: String) {
        self.defaults = defaults
        self.keys = Keys(storageKey: storageKey)
    }

    /// Presence is separate from successful decoding. Existing-but-unreadable data is still an existing
    /// layout, so startup must not mistake corruption for a fresh install and apply fresh-only defaults.
    var hasStoredLayout: Bool { defaults.data(forKey: keys.placed) != nil }
    var hasStoredSeededDefaults: Bool { defaults.data(forKey: keys.seededDefaults) != nil }
    var hasStoredSeededAccountPins: Bool { defaults.data(forKey: keys.seededAccountPins) != nil }

    func loadPlaced() -> [PlacedWidget]? { decode([PlacedWidget].self, forKey: keys.placed) }
    func loadProviderOrder() -> [String]? { decode([String].self, forKey: keys.providerOrder) }
    func loadMetricOrder() -> [String: [String]]? {
        decode([String: [String]].self, forKey: keys.metricOrder)
    }
    func loadSeededDefaults() -> [String]? { decode([String].self, forKey: keys.seededDefaults) }
    func loadSeededAccountPins() -> [String]? { decode([String].self, forKey: keys.seededAccountPins) }

    func loadPins() -> [String]? { defaults.stringArray(forKey: keys.pins) }
    func loadExpandedMetrics() -> [String]? { defaults.stringArray(forKey: keys.expandedMetrics) }
    func loadExpandOnEnable() -> [String]? { defaults.stringArray(forKey: keys.expandOnEnable) }
    func loadExpandedProviders() -> [String]? { defaults.stringArray(forKey: keys.expandedProviders) }
    func loadMenuBarStyle() -> MenuBarStyle { defaults.enumValue(forKey: keys.menuBarStyle, default: .text) }
    func loadHiddenMenuBarProviderIDs() -> Set<String> {
        if defaults.object(forKey: keys.hiddenMenuBarProviderIDs) != nil {
            return Set(defaults.stringArray(forKey: keys.hiddenMenuBarProviderIDs) ?? [])
        }
        guard defaults.object(forKey: keys.legacyHiddenMenuBarIconProviderIDs) != nil else { return [] }
        let legacyIDs = defaults.stringArray(forKey: keys.legacyHiddenMenuBarIconProviderIDs) ?? []
        defaults.set(legacyIDs, forKey: keys.hiddenMenuBarProviderIDs)
        return Set(legacyIDs)
    }

    func savePlaced(_ value: [PlacedWidget]) { encode(value, forKey: keys.placed) }
    func saveProviderOrder(_ value: [String]) { encode(value, forKey: keys.providerOrder) }
    func saveMetricOrder(_ value: [String: [String]]) { encode(value, forKey: keys.metricOrder) }
    func saveSeededDefaults(_ value: Set<String>) {
        encode(Array(value).sorted(), forKey: keys.seededDefaults)
    }
    func saveSeededAccountPins(_ value: Set<String>) {
        encode(Array(value).sorted(), forKey: keys.seededAccountPins)
    }

    func savePins(_ value: Set<String>) { defaults.set(Array(value), forKey: keys.pins) }
    func saveExpandedMetrics(_ value: Set<String>) {
        defaults.set(Array(value), forKey: keys.expandedMetrics)
    }
    func saveExpandOnEnable(_ value: Set<String>) {
        defaults.set(Array(value), forKey: keys.expandOnEnable)
    }
    func saveExpandedProviders(_ value: Set<String>) {
        defaults.set(Array(value), forKey: keys.expandedProviders)
    }
    func saveMenuBarStyle(_ value: MenuBarStyle) {
        defaults.set(value.rawValue, forKey: keys.menuBarStyle)
    }
    func saveHiddenMenuBarProviderIDs(_ value: Set<String>) {
        defaults.set(Array(value).sorted(), forKey: keys.hiddenMenuBarProviderIDs)
    }

    /// Fail loudly: a swallowed encode would silently lose a layout change with no signal.
    private func encode<T: Encodable>(_ value: T, forKey key: String) {
        do {
            defaults.set(try JSONEncoder().encode(value), forKey: key)
        } catch {
            AppLog.warn(.config, "failed to persist layout '\(key)': \(error.localizedDescription)")
        }
    }

    /// Missing data is a normal first launch. Present-but-unreadable data is logged before startup uses
    /// its normal fallback, so a damaged saved layout is never silently hidden.
    private func decode<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            AppLog.warn(.config, "saved layout '\(key)' failed to decode; reseeding default: \(error.localizedDescription)")
            return nil
        }
    }

    private struct Keys {
        let placed: String
        let providerOrder: String
        let metricOrder: String
        let seededDefaults: String
        let seededAccountPins: String
        let pins: String
        let expandedMetrics: String
        let expandOnEnable: String
        let expandedProviders: String
        let menuBarStyle: String
        let hiddenMenuBarProviderIDs: String
        let legacyHiddenMenuBarIconProviderIDs: String

        init(storageKey: String) {
            placed = storageKey
            providerOrder = "\(storageKey).providerOrder"
            metricOrder = "\(storageKey).metricOrderByProvider"
            seededDefaults = "\(storageKey).seededDefaults"
            seededAccountPins = "\(storageKey).seededAccountPins"
            pins = "\(storageKey).menuBarPins"
            expandedMetrics = "\(storageKey).expandedMetrics"
            expandOnEnable = "\(storageKey).expandOnEnable"
            expandedProviders = "\(storageKey).expandedProviders"
            menuBarStyle = "\(storageKey).menuBarStyle"
            hiddenMenuBarProviderIDs = "\(storageKey).hiddenMenuBarProviderIDs"
            legacyHiddenMenuBarIconProviderIDs = "\(storageKey).hiddenMenuBarIconProviderIDs"
        }
    }
}
