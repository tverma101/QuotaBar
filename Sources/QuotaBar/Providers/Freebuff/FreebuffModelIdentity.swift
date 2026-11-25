import Foundation

/// Receipt provenance determines whether a Fast-tier name and price can be used. Modes can share
/// a model row while keeping their own measured tokens and public-rate estimates in its variants.
struct FreebuffModelIdentity {
    static let olderUsageName = "Older Freebuff Usage"
    struct Resolved {
        var route: String?
        var displayName: String?
        var group: String?
        /// The raw text looks Fast but nothing identifies it — report unknown, not named-unpriced.
        var hasUnknownRoute: Bool = false
    }

    private let entries: [String: FreebuffModelCatalog.Entry]
    private let routes: [String: String]
    private let legacyEntries: [String: FreebuffModelCatalog.Entry]
    private let routeNames: [String: String]
    private struct LookupKey: Hashable {
        let model: String
        let fromReceipt: Bool
    }
    private var memo: [LookupKey: Resolved] = [:]

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
            let names = Set(keys.compactMap { entries[$0]?.displayName })
            // Multiple opaque keys with the same display name still name one model. Distinct
            // catalogue names on one price route do not prove an identity.
            return names.count == 1 ? names.first : nil
        }
    }

    mutating func resolve(_ model: String, pricing: ModelPricing, fromReceipt: Bool = false) -> Resolved {
        let key = LookupKey(model: model, fromReceipt: fromReceipt)
        if let cached = memo[key] { return cached }
        // A display label, opaque key, or saved selection cannot prove a serving tier.
        let entry = entries[model] ?? legacyEntries[Self.legacyDigest(model)]
        let exact = exactRoute(for: model, pricing: pricing)
        let resolved: Resolved
        if let base = (exact == nil || !fromReceipt
                       ? entry.flatMap({ FreebuffModelCatalog.fastBaseName($0.displayName) }) : nil)
            ?? FreebuffModelCatalog.fastBaseName(model) {
            let name: String
            let route: String?
            if fromReceipt, let exact, FreebuffModelCatalog.fastBaseName(model) != nil {
                name = Self.isDeepSeekFlashFastRoute(model)
                    ? "DeepSeek V4.1 Flash Fast (Recorded Route)" : "\(model) (Recorded Route)"
                route = exact
            } else if Self.isDeepSeekFlashFastRoute(model) || Self.isDeepSeekFlashBaseName(base) {
                route = FreebuffFlashComparison.route
                name = "DeepSeek V4.1 Flash (Standard Rate Assumed)"
            } else {
                let modelName = Self.isDeepSeekFlashFastRoute(model) ? "DeepSeek V4.1 Flash" : base
                name = "\(modelName) (Route Unverified)"
                route = nil
            }
            resolved = Resolved(route: route, displayName: name, group: name,
                                hasUnknownRoute: entry == nil && exact == nil
                                    && !Self.isDeepSeekFlashFastRoute(model)
                                    && !Self.isDeepSeekFlashBaseName(base))
        } else {
            let route = exact ?? entry.flatMap { entry in
                if routes[entry.key] != nil { return routes[entry.key] }
                switch Self.groupName(entry.displayName).lowercased() {
                case "deepseek v4.1 flash": return FreebuffFlashComparison.route
                default: return nil
                }
            }
            let entryName = entry?.displayName
            let displayName = entryName.flatMap { FreebuffModelCatalog.fastBaseName($0) == nil ? $0 : nil }
                ?? route.flatMap { routeNames[$0] }
            resolved = Resolved(route: route, displayName: displayName, group: displayName.map(Self.groupName))
        }
        if memo.count < 4_096 { memo[key] = resolved }
        return resolved
    }

    private static let curatedFastRoute = "deepseek-v4.1-flash-fast"

    private static func isDeepSeekFlashFastRoute(_ name: String) -> Bool {
        name == curatedFastRoute || name == "deepseek/\(curatedFastRoute)"
    }

    /// The one family whose Fast label QuotaBar treats as the standard tier by owner decision.
    private static func isDeepSeekFlashBaseName(_ name: String) -> Bool {
        switch name.lowercased() {
        case "deepseek v4.1 flash", "deepseek-v4.1-flash", "deepseek/deepseek-v4.1-flash": true
        default: false
        }
    }

    private func exactRoute(for model: String, pricing: ModelPricing) -> String? {
        if pricing.openRouter.entries[model] != nil || pricing.supplement.pricing[model] != nil { return model }
        if Self.isDeepSeekFlashFastRoute(model), pricing.supplement.pricing[Self.curatedFastRoute] != nil {
            return Self.curatedFastRoute
        }
        return FreebuffFlashComparison.matchesRoute(model) ? model : nil
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
