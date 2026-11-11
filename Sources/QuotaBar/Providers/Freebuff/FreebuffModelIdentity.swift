import Foundation

/// Display identity is separate from the rate used for each receipt. Modes can share a model row
/// while keeping their own measured tokens and public-rate estimates in its variants — except the
/// removed Flash Fast mode, which collapses onto its base model entirely (`presentedName`).
struct FreebuffModelIdentity {
    static let olderUsageName = "Older Freebuff Usage"
    struct Resolved {
        var route: String?
        var displayName: String?
        var group: String?
    }

    private let entries: [String: FreebuffModelCatalog.Entry]
    private let routes: [String: String]
    private let legacyEntries: [String: FreebuffModelCatalog.Entry]
    private let routeNames: [String: String]
    private var memo: [String: Resolved] = [:]

    init(entries: [String: FreebuffModelCatalog.Entry], pricing: ModelPricing) {
        self.entries = entries
        let routes = FreebuffModelCatalog.pricingRoutes(entries: entries, pricing: pricing)
        self.routes = routes
        let legacyPairs = entries.values.flatMap { entry in
            (entry.legacyDigests ?? []).map { ($0, entry) }
        }
        legacyEntries = Dictionary(grouping: legacyPairs, by: { $0.0 }).compactMapValues { pairs in
            // A collision must not pick an arbitrary model (or its price).
            guard Set(pairs.map { $0.1.key }).count == 1 else { return nil }
            return pairs.first?.1
        }
        routeNames = Dictionary(grouping: routes.keys, by: { routes[$0]! }).compactMapValues { keys in
            let names = Set(keys.compactMap { entries[$0]?.displayName }.map(Self.presentedName))
            // Multiple opaque keys with the same display name still name one model. Distinct
            // catalogue names on one price route do not prove an identity.
            return names.count == 1 ? names.first : nil
        }
    }

    mutating func resolve(_ model: String, pricing: ModelPricing) -> Resolved {
        if let cached = memo[model] { return cached }
        // Use the provider's published migration contract, never guess an opaque key from its name.
        let entry = entries[model] ?? legacyEntries[Self.legacyDigest(model)]
        let route: String?
        if pricing.openRouter.entries[model] != nil || pricing.supplement.pricing[model] != nil {
            route = model
        } else {
            route = entry.flatMap { routes[$0.key] }
        }
        let displayName = (entry?.displayName ?? route.flatMap { routeNames[$0] }).map(Self.presentedName)
        let resolved = Resolved(route: route, displayName: displayName,
                                group: displayName.map(Self.groupName))
        if memo.count < 4_096 { memo[model] = resolved }
        return resolved
    }

    /// The catalogue name a model row presents. Freebuff removed its Flash Fast serving mode, so a
    /// name that still claims it is stale — the key serves the base Flash model (hosted receipts
    /// carry only the plain slug). Present that base name; the removed mode must not reappear as a
    /// model identity or a spelling variant anywhere. Slow remains a real mode and keeps its label.
    static func presentedName(_ name: String) -> String {
        FreebuffModelCatalog.removedModeBaseName(name) ?? name
    }

    /// Matches `freebuffLegacyModelDigest` in Freebuff's common/types/freebuff-model-catalog.ts:
    /// two unsigned FNV-style accumulators over JavaScript UTF-16 code units, not UTF-8 bytes.
    static func legacyDigest(_ model: String) -> String {
        var first: UInt32 = 0x811c9dc5
        var second: UInt32 = 0x01000193 ^ 0x5bd1e995
        for codeUnit in ("freebuff-legacy-model:" + model).utf16 {
            first = (first ^ UInt32(codeUnit)) &* 0x01000193
            second = (second ^ UInt32(codeUnit)) &* 0x5bd1e995
        }
        return String(format: "%08x%08x", first, second)
    }

    /// Catalogue labels retain real model versions, but mode/build/context annotations need not
    /// repeat a model in the compact breakdown. Full source labels survive as accounting variants.
    static func groupName(_ name: String) -> String {
        name.replacingOccurrences(of: #"\s*(?:[·•]\s*)?\d+k\s+context$"#, with: "",
                                  options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\s+\d{1,2}/\d{1,2}$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+(?:Fast|Slow)$"#, with: "",
                                  options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
