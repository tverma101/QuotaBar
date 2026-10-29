import Foundation

/// QuotaBar's own pricing feed: curated rate/cache overrides, models that no public catalog carries
/// (Cursor-native `auto`, `composer-*`, `github_bugbot`), fast-variant multipliers the catalogs omit,
/// and alias rules that map provider log/CSV slugs to canonical pricing keys. Ships bundled as
/// `pricing_supplement.json` and refreshes from gh-pages, so entries update without an app release.
struct PricingSupplement: Sendable {
    /// Curated exact rates and Cursor-native entries. These override public catalogues when a
    /// deliberate first-party price or model-specific cache rate is available.
    let pricing: [String: ModelRates]
    /// Base-model -> fast-variant multiplier, for `-fast` slugs whose catalogs carry no `fast` field.
    /// Also applied to the base model's own rates, so requests flagged fast by the scanner (rather
    /// than by a `-fast` slug) bill at the fast rate.
    let fastMultipliers: [String: Double]
    /// `fastMultipliers` keyed by `PricingCatalog.normalizedKey(base)`, precomputed once at decode
    /// instead of re-normalizing every base key per lookup. Collision policy: the most specific raw
    /// key (longest, then lexicographically smallest) wins — raw dictionary order is randomized, so
    /// a collision resolved at iteration order was a latent nondeterminism.
    let normalizedFastMultipliers: [String: Double]
    let aliasRules: [AliasRule]
    /// Cursor-specific aliases. Cursor's CSV can use the same bare slug as a first-party API, while
    /// the two surfaces publish different rates for models such as Grok 4.7.
    let cursorAliasRules: [AliasRule]
    /// Deprecated rate keys removed from newer feeds. This lets a new bundle retire stale entries
    /// from supplements cached by older app versions without dropping unrelated cache-only keys.
    let retiredPricingKeys: Set<String>
    /// Global alias patterns removed from newer feeds. A pattern tombstone prevents an older cache
    /// from restoring an alias whose canonical model is no longer a safe attribution.
    let retiredAliasPatterns: Set<String>
    /// Whether `retiredAliasPatterns` came from a complete feed. Legacy supplements without the
    /// field cannot clear removals shipped in a newer bundle.
    let retiredAliasPatternsAreAuthoritative: Bool
    let updatedAt: String?

    /// Regex slug -> canonical pricing key. Rules apply in order; first match wins.
    struct AliasRule: @unchecked Sendable {
        let pattern: NSRegularExpression
        let canonical: String
    }

    init(
        pricing: [String: ModelRates] = [:],
        fastMultipliers: [String: Double] = [:],
        aliasRules: [AliasRule] = [],
        cursorAliasRules: [AliasRule] = [],
        retiredPricingKeys: Set<String> = [],
        retiredAliasPatterns: Set<String> = [],
        retiredAliasPatternsAreAuthoritative: Bool = false,
        updatedAt: String? = nil
    ) {
        self.pricing = pricing
        self.fastMultipliers = fastMultipliers
        // Collision policy when two raw base keys normalize to the same form (e.g. `gpt-5.6` and
        // `gpt.5.6`): the most specific raw key — longest, then lexicographically smallest — wins.
        // Raw dictionary order is randomized, so resolving collisions at iteration order was a
        // latent nondeterminism.
        var normalizedFast: [String: (multiplier: Double, specificity: Int, rawKey: String)] = [:]
        for (base, multiplier) in fastMultipliers {
            let normalized = PricingCatalog.normalizedKey(base)
            let specificity = base.count
            guard let existing = normalizedFast[normalized] else {
                normalizedFast[normalized] = (multiplier, specificity, base)
                continue
            }
            if specificity > existing.specificity
                || (specificity == existing.specificity && base < existing.rawKey) {
                normalizedFast[normalized] = (multiplier, specificity, base)
            }
        }
        self.normalizedFastMultipliers = normalizedFast.mapValues(\.multiplier)
        self.aliasRules = aliasRules
        self.cursorAliasRules = cursorAliasRules
        self.retiredPricingKeys = retiredPricingKeys
        self.retiredAliasPatterns = retiredAliasPatterns
        self.retiredAliasPatternsAreAuthoritative = retiredAliasPatternsAreAuthoritative
        self.updatedAt = updatedAt
    }

    /// The canonical pricing key for `model` per the alias rules, or nil when no rule matches.
    func canonicalName(for model: String) -> String? {
        let range = NSRange(model.startIndex..., in: model)
        for rule in aliasRules where rule.pattern.firstMatch(in: model, range: range) != nil {
            return rule.canonical
        }
        return nil
    }

    /// Cursor-specific canonical identity for model labels in Cursor's usage export.
    func cursorCanonicalName(for model: String) -> String? {
        let range = NSRange(model.startIndex..., in: model)
        for rule in cursorAliasRules where rule.pattern.firstMatch(in: model, range: range) != nil {
            return rule.canonical
        }
        return nil
    }

    /// Fast multiplier for a resolved base model. Exact key match first, then ccusage's
    /// normalized-suffix matching so dated keys (`gpt-5.5-2026-04-23`) still find their base entry.
    func fastMultiplier(for model: String) -> Double? {
        if let exact = fastMultipliers[model] { return exact }
        let normalized = PricingCatalog.normalizedKey(model)
        var matches: [(base: String, multiplier: Double)] = []
        for part in normalized.split(whereSeparator: { $0 == "/" || $0 == ":" }) {
            for (base, multiplier) in normalizedFastMultipliers {
                if Self.matchesModelSuffix(part: String(part), base: base) {
                    matches.append((base, multiplier))
                }
            }
        }
        // A dated `gpt-5.5-…` key also suffix-matches `gpt-5`. Pick the most specific
        // configured model deterministically instead of depending on Dictionary iteration order.
        return matches.sorted {
            if $0.base.count != $1.base.count { return $0.base.count > $1.base.count }
            return $0.base < $1.base
        }.first?.multiplier
    }

    /// `base` occurs in `part` with nothing after it, or followed by a `-` separator.
    private static func matchesModelSuffix(part: String, base: String) -> Bool {
        guard let range = part.range(of: base, options: .backwards) else { return false }
        let suffix = part[range.upperBound...]
        return suffix.isEmpty || suffix.hasPrefix("-")
    }

    /// Merge another supplement on top of this one — `other` wins per key, but base-only keys
    /// survive. Alias rules are unioned (other's rules first, then base's unseen patterns). This
    /// ensures a cached feed never erases newly shipped bundled pins like mimo-v2.5.
    func merging(_ other: PricingSupplement) -> PricingSupplement {
        var mergedPricing = pricing
        mergedPricing.merge(other.pricing) { _, new in new }
        var mergedRetiredKeys = retiredPricingKeys.union(other.retiredPricingKeys)
        for key in other.pricing.keys where !other.retiredPricingKeys.contains(key) {
            mergedRetiredKeys.remove(key)
        }
        for key in mergedRetiredKeys {
            mergedPricing.removeValue(forKey: key)
        }
        var mergedMultipliers = fastMultipliers
        mergedMultipliers.merge(other.fastMultipliers) { _, new in new }
        var mergedRules = other.aliasRules
        let existingPatterns = Set(other.aliasRules.map { $0.pattern.pattern })
        for rule in aliasRules where !existingPatterns.contains(rule.pattern.pattern) {
            mergedRules.append(rule)
        }
        var mergedCursorRules = other.cursorAliasRules
        let existingCursorPatterns = Set(other.cursorAliasRules.map { $0.pattern.pattern })
        for rule in cursorAliasRules where !existingCursorPatterns.contains(rule.pattern.pattern) {
            mergedCursorRules.append(rule)
        }
        var mergedRetiredAliasPatterns = retiredAliasPatterns.union(other.retiredAliasPatterns)
        if other.retiredAliasPatternsAreAuthoritative {
            for rule in other.aliasRules where !other.retiredAliasPatterns.contains(rule.pattern.pattern) {
                mergedRetiredAliasPatterns.remove(rule.pattern.pattern)
            }
        }
        mergedRules.removeAll { mergedRetiredAliasPatterns.contains($0.pattern.pattern) }
        // updated_at is the newer of the two for diagnostics
        let mergedUpdatedAt: String?
        switch (updatedAt, other.updatedAt) {
        case (nil, let o?): mergedUpdatedAt = o
        case (let b?, nil): mergedUpdatedAt = b
        case (let b?, let o?):
            func normalizedDate(_ s: String) -> Date? {
                if let d = OpenUsageISO8601.date(from: s) { return d }
                if s.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
                    return OpenUsageISO8601.date(from: s + "T00:00:00Z")
                }
                return nil
            }
            if let bDate = normalizedDate(b),
               let oDate = normalizedDate(o) {
                mergedUpdatedAt = oDate > bDate ? o : b
            } else {
                mergedUpdatedAt = o > b ? o : b
            }
        case (nil, nil): mergedUpdatedAt = nil
        }
        return PricingSupplement(
            pricing: mergedPricing,
            fastMultipliers: mergedMultipliers,
            aliasRules: mergedRules,
            cursorAliasRules: mergedCursorRules,
            retiredPricingKeys: mergedRetiredKeys,
            retiredAliasPatterns: mergedRetiredAliasPatterns,
            retiredAliasPatternsAreAuthoritative:
                retiredAliasPatternsAreAuthoritative || other.retiredAliasPatternsAreAuthoritative,
            updatedAt: mergedUpdatedAt
        )
    }

    /// Preserve explicit removals from an authority snapshot when an older or otherwise
    /// independently refreshed overlay still contains those entries.
    func preservingRetirements(
        from authority: PricingSupplement,
        preserveAliasPatterns: Bool = true
    ) -> PricingSupplement {
        let retiredKeys = retiredPricingKeys.union(authority.retiredPricingKeys)
        let retiredAliasPatterns = preserveAliasPatterns
            ? self.retiredAliasPatterns.union(authority.retiredAliasPatterns)
            : self.retiredAliasPatterns
        var retainedPricing = pricing
        for key in retiredKeys {
            retainedPricing.removeValue(forKey: key)
        }
        return PricingSupplement(
            pricing: retainedPricing,
            fastMultipliers: fastMultipliers,
            aliasRules: aliasRules.filter { !retiredAliasPatterns.contains($0.pattern.pattern) },
            cursorAliasRules: cursorAliasRules,
            retiredPricingKeys: retiredKeys,
            retiredAliasPatterns: retiredAliasPatterns,
            retiredAliasPatternsAreAuthoritative:
                retiredAliasPatternsAreAuthoritative || authority.retiredAliasPatternsAreAuthoritative,
            updatedAt: updatedAt
        )
    }
}

// MARK: - JSON decoding

extension PricingSupplement {
    /// Decodes the supplement JSON (bundled resource or the gh-pages feed). Throws on malformed
    /// JSON; individually invalid alias patterns are skipped loudly.
    static func decode(from data: Data) throws -> PricingSupplement {
        let file = try JSONDecoder().decode(SupplementFile.self, from: data)
        var pricing: [String: ModelRates] = [:]
        for (model, entry) in file.pricing {
            pricing[model] = ModelRates(
                inputPerMillion: entry.inputPerMillion,
                outputPerMillion: entry.outputPerMillion,
                cacheWritePerMillion: entry.cacheWritePerMillion ?? entry.inputPerMillion,
                cacheReadPerMillion: entry.cacheReadPerMillion ?? entry.inputPerMillion,
                cacheWrite1hPerMillion: entry.cacheWrite1hPerMillion,
                promptRateTiers: entry.promptRateTiers ?? [],
                cacheReadIsExplicit: entry.cacheReadPerMillion != nil
                    || entry.promptRateTiers?.contains { $0.cacheReadPerMillion != nil } == true,
                // Carry the declared multiplier onto the entry itself: scanners that flag fast mode
                // on the request (Claude's `speed` field) price the base slug, never a `-fast` one.
                fastMultiplier: file.fastMultipliers?[model] ?? 1
            )
        }
        var rules: [AliasRule] = []
        for rule in file.aliasRules {
            do {
                let pattern = try NSRegularExpression(pattern: rule.pattern)
                rules.append(AliasRule(pattern: pattern, canonical: rule.canonical))
            } catch {
                AppLog.warn(.cache, "pricing supplement: invalid alias pattern '\(rule.pattern)' skipped: \(error.localizedDescription)")
            }
        }
        var cursorRules: [AliasRule] = []
        for rule in file.cursorAliasRules ?? [] {
            do {
                let pattern = try NSRegularExpression(pattern: rule.pattern)
                cursorRules.append(AliasRule(pattern: pattern, canonical: rule.canonical))
            } catch {
                AppLog.warn(.cache, "pricing supplement: invalid Cursor alias pattern '\(rule.pattern)' skipped: \(error.localizedDescription)")
            }
        }
        return PricingSupplement(
            pricing: pricing,
            fastMultipliers: file.fastMultipliers ?? [:],
            aliasRules: rules,
            cursorAliasRules: cursorRules,
            retiredPricingKeys: Set(file.retiredPricingKeys ?? []),
            retiredAliasPatterns: Set(file.retiredAliasPatterns ?? []),
            retiredAliasPatternsAreAuthoritative: file.retiredAliasPatterns != nil,
            updatedAt: file.updatedAt
        )
    }

    private struct SupplementFile: Decodable {
        var updatedAt: String?
        var pricing: [String: Entry]
        var fastMultipliers: [String: Double]?
        var aliasRules: [Rule]
        var cursorAliasRules: [Rule]?
        var retiredPricingKeys: [String]?
        var retiredAliasPatterns: [String]?

        struct Entry: Decodable {
            var inputPerMillion: Double
            var outputPerMillion: Double
            var cacheWritePerMillion: Double?
            var cacheReadPerMillion: Double?
            var cacheWrite1hPerMillion: Double?
            var promptRateTiers: [PromptRateTier]?

            enum CodingKeys: String, CodingKey {
                case inputPerMillion = "input_per_million"
                case outputPerMillion = "output_per_million"
                case cacheWritePerMillion = "cache_write_per_million"
                case cacheReadPerMillion = "cache_read_per_million"
                case cacheWrite1hPerMillion = "cache_write_1h_per_million"
                case promptRateTiers = "prompt_rate_tiers"
            }
        }

        struct Rule: Decodable {
            var pattern: String
            var canonical: String
        }

        enum CodingKeys: String, CodingKey {
            case updatedAt = "updated_at"
            case pricing
            case fastMultipliers = "fast_multipliers"
            case aliasRules = "alias_rules"
            case cursorAliasRules = "cursor_alias_rules"
            case retiredPricingKeys = "retired_pricing_keys"
            case retiredAliasPatterns = "retired_alias_patterns"
        }
    }
}
