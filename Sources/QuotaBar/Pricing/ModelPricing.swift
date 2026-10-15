import Foundation
import os

/// An immutable pricing snapshot: the supplement plus three public catalogs, with the resolution
/// order ported from ccusage. `ModelPricingStore` builds one; scanners and mappers use it
/// synchronously for a whole parse pass.
///
/// Resolution for a model name:
/// 1. Supplement alias rules rewrite the slug to a canonical key (raw name kept as fallback).
/// 2. Supplement pricing (exact) — curated rates, Cursor-native models, and cache details.
/// 3. OpenRouter exact — live route prices and unique bare model aliases for automatic discovery.
/// 4. LiteLLM exact.
/// 5. `-fast` suffix: price the base model and scale by its fast multiplier; if no multiplier or
///    exact fast entry exists, leave it unpriced instead of silently using standard-speed rates.
/// 6. LiteLLM fuzzy (boundary-aware substring matching, for non-fast slugs only).
/// 7. models.dev exact — id-level gap-filler only. models.dev aggregates resellers under near-
///    identical bare ids (`glm-5-2` vs `glm-5.2`) with diverging rates, so fuzzy matching against
///    it risks wrong dollars; unknown slug variants stay unpriced (and visibly flagged) instead.
final class ModelPricing: Sendable {
    let supplement: PricingSupplement
    /// OpenRouter `/api/v1/models`; exact route ids and unique bare model ids only.
    let openRouter: PricingCatalog
    /// LiteLLM `model_prices_and_context_window.json` (bundled snapshot merged with fetched data).
    let primary: PricingCatalog
    /// models.dev `api.json` — gap-filler for models LiteLLM misses (e.g. `grok-build-0.1`).
    let secondary: PricingCatalog

    /// Resolution walks every catalog entry on a fuzzy miss, so memoize per model name. Shared
    /// across threads; a pricing snapshot is immutable so entries never invalidate.
    ///
    /// `unresolved(reported:)` remembers that a name had no rate and whether
    /// `onUnresolvedModel` already fired for it. One miss repeats across every usage event in a
    /// ledger, so the hook must run at most once per distinct name per snapshot — including when a
    /// memoized nil is what answered.
    private let memo = OSAllocatedUnfairLock<[String: MemoEntry]>(initialState: [:])
    private enum MemoEntry: Sendable {
        case rates(ModelRates)
        case unresolved(reported: Bool)
    }
    private enum CanonicalNameLookup: Sendable {
        case found(String)
        case missing
    }
    /// Alias misses matter too: local logs repeat the same model slug for thousands of events, and
    /// testing every supplement regex for each event dominates the actual cost fold.
    private let canonicalNameMemo = OSAllocatedUnfairLock<[String: CanonicalNameLookup]>(initialState: [:])
    private let cursorCanonicalNameMemo = OSAllocatedUnfairLock<[String: CanonicalNameLookup]>(initialState: [:])

    init(
        supplement: PricingSupplement,
        primary: PricingCatalog,
        secondary: PricingCatalog,
        openRouter: PricingCatalog = PricingCatalog(),
        onUnresolvedModel: (@Sendable (String) -> Void)? = nil
    ) {
        self.supplement = supplement
        self.primary = primary
        self.secondary = secondary
        self.openRouter = openRouter
        self.onUnresolvedModel = onUnresolvedModel
        self.aggregateCacheToken = Self.makeAggregateCacheToken(
            supplement: supplement, primary: primary, secondary: secondary, openRouter: openRouter
        )
    }

    static let empty = ModelPricing(
        supplement: PricingSupplement(), primary: PricingCatalog(), secondary: PricingCatalog()
    )


    /// Stable across launches for the same catalogs. See `makeAggregateCacheToken`.
    let aggregateCacheToken: String

    /// Called once per distinct model name this snapshot cannot price, so `ModelPricingStore` can
    /// coalesce a newly seen model into one public-catalogue revalidation. Nil by default, keeping
    /// `ModelPricing` a pure value for callers that do not want discovery.
    let onUnresolvedModel: (@Sendable (String) -> Void)?

    private static func makeAggregateCacheToken(
        supplement: PricingSupplement,
        primary: PricingCatalog,
        secondary: PricingCatalog,
        openRouter: PricingCatalog
    ) -> String {
        var parts: [String] = ["pricing-v3"]
        func rateStamp(_ rates: ModelRates) -> String {
            let base = [
                String(rates.inputPerMillion), String(rates.outputPerMillion),
                String(rates.cacheWritePerMillion), String(rates.cacheReadPerMillion),
                rates.cacheWrite1hPerMillion.map { String($0) } ?? "nil",
                rates.inputAbove200kPerMillion.map { String($0) } ?? "nil",
                rates.outputAbove200kPerMillion.map { String($0) } ?? "nil",
                rates.cacheWriteAbove200kPerMillion.map { String($0) } ?? "nil",
                rates.cacheReadAbove200kPerMillion.map { String($0) } ?? "nil",
                String(rates.cacheReadIsExplicit), String(rates.longContextThresholdTokens),
                String(rates.fastMultiplier)
            ]
            let tiers = rates.promptRateTiers.map { tier in
                [
                    String(tier.thresholdPromptTokens),
                    String(tier.includesThreshold),
                    tier.inputPerMillion.map { String($0) } ?? "nil",
                    tier.outputPerMillion.map { String($0) } ?? "nil",
                    tier.cacheWritePerMillion.map { String($0) } ?? "nil",
                    tier.cacheReadPerMillion.map { String($0) } ?? "nil",
                    tier.cacheWrite1hPerMillion.map { String($0) } ?? "nil"
                ].joined(separator: ":")
            }
            return (base + tiers).joined(separator: ":")
        }
        func stamp(_ name: String, _ entries: [String: ModelRates]) {
            parts.append(name)
            for key in entries.keys.sorted() {
                guard let rates = entries[key] else { continue }
                parts.append("\(key):\(rateStamp(rates))")
            }
        }
        // Retrieval dates describe network freshness, not a price change. Identical rates keep the
        // same key so fetching the catalogue does not trigger another full ledger fold.
        stamp("primary", primary.entries)
        stamp("secondary", secondary.entries)
        stamp("openRouter", openRouter.entries)
        stamp("supplement", supplement.pricing)
        for rule in supplement.aliasRules {
            parts.append("alias:\(rule.pattern.pattern):\(rule.pattern.options.rawValue):\(rule.canonical)")
        }
        for rule in supplement.cursorAliasRules {
            parts.append("cursor-alias:\(rule.pattern.pattern):\(rule.pattern.options.rawValue):\(rule.canonical)")
        }
        for key in supplement.retiredPricingKeys.sorted() {
            parts.append("retired-pricing:\(key)")
        }
        for key in supplement.fastMultipliers.keys.sorted() {
            parts.append("fast:\(key):\(supplement.fastMultipliers[key]!)")
        }
        return JSONLScanCachePaths.stableFingerprint(parts.joined(separator: "\n"))
    }

    /// Rates for `model`, or nil when no source can price it (caller shows the unknown-model
    /// warning and counts tokens at $0).
    /// The catalog key a slug should be *identified* by, preferring an exact catalog entry among
    /// `candidates` and falling back to the first that resolves.
    ///
    /// Pricing *rates* do not need this — `resolve` matches fuzzily, so a gateway-tagged slug
    /// `anthropic/openai/gpt-5.6-luna` prices correctly by containing `gpt-5.6-luna`. Identity does.
    /// The fuzzy match happily accepts the whole prefixed string, so the slug stayed the row's name and
    /// one model appeared as two rows. Walking the candidates longest-suffix-first for an *exact* key
    /// picks the bare model id, which is what the row should be called.
    func canonicalKey(for candidates: [String]) -> String? {
        // Longest suffix first: the bare model id is the most specific identity available.
        for candidate in candidates.sorted(by: { $0.count < $1.count }) {
            if let key = exactKey(candidate: candidate) { return key }
        }
        return candidates.first { resolveQuietly(model: $0) != nil }
    }

    private func exactKey(candidate: String) -> String? {
        if let hit = canonicalName(for: candidate) { return hit }
        if supplement.pricing[candidate] != nil { return candidate }
        if openRouter.findExact(candidate) != nil { return candidate }
        if primary.findExact(candidate) != nil { return candidate }
        if secondary.findExact(candidate) != nil { return candidate }
        return nil
    }

    func canonicalName(for model: String) -> String? {
        if let cached = canonicalNameMemo.withLock({ $0[model] }) {
            if case .found(let name) = cached { return name }
            return nil
        }
        let resolved = supplement.canonicalName(for: model)
        canonicalNameMemo.withLock {
            $0[model] = resolved.map(CanonicalNameLookup.found) ?? .missing
        }
        return resolved
    }

    /// Cursor-specific identity for exports whose rates differ from the matching public API model.
    func cursorCanonicalName(for model: String) -> String? {
        if let cached = cursorCanonicalNameMemo.withLock({ $0[model] }) {
            if case .found(let name) = cached { return name }
            return nil
        }
        let resolved = supplement.cursorCanonicalName(for: model)
        cursorCanonicalNameMemo.withLock {
            $0[model] = resolved.map(CanonicalNameLookup.found) ?? .missing
        }
        return resolved
    }

    func resolve(model: String) -> ModelRates? {
        if let cached = memo.withLock({ $0[model] }) {
            if case .rates(let rates) = cached { return rates }
            reportUnresolvedIfNeeded(model)
            return nil
        }
        let resolved = resolveUncached(model: model)
        if let resolved {
            memo.withLock { $0[model] = .rates(resolved) }
            return resolved
        }
        memo.withLock { $0[model] = .unresolved(reported: false) }
        reportUnresolvedIfNeeded(model)
        return nil
    }

    /// Same lookup as `resolve`, minus the discovery hook. Internal identity probes walk several
    /// candidate spellings of one slug; only the caller's actual name is worth reporting.
    private func resolveQuietly(model: String) -> ModelRates? {
        if let cached = memo.withLock({ $0[model] }) {
            guard case .rates(let rates) = cached else { return nil }
            return rates
        }
        let resolved = resolveUncached(model: model)
        memo.withLock { $0[model] = resolved.map(MemoEntry.rates) ?? .unresolved(reported: false) }
        return resolved
    }

    /// Marks the memo entry reported *before* calling out, so a re-entrant resolve of the same name
    /// cannot fire the hook twice.
    private func reportUnresolvedIfNeeded(_ model: String) {
        guard let onUnresolvedModel else { return }
        let shouldReport = memo.withLock { (entries: inout [String: MemoEntry]) -> Bool in
            guard case .unresolved(let reported) = entries[model], !reported else { return false }
            entries[model] = .unresolved(reported: true)
            return true
        }
        if shouldReport { onUnresolvedModel(model) }
    }

    /// Whether `model` resolves, without reporting a miss. `ModelPricingStore` uses it to tell
    /// "the catalogue already covers this name" from "still unknown" after a discovery fetch, without
    /// feeding its own probe back into the discovery queue.
    func isPriced(_ model: String) -> Bool {
        resolveQuietly(model: model) != nil
    }

    /// Dollar cost of `tokens` for `model`, or nil when the model can't be priced. Aggregated sources
    /// can disable long-context tiers when they do not preserve individual request boundaries.
    func estimatedCostDollars(
        model: String,
        tokens: TokenBreakdown,
        applyLongContextRates: Bool = true
    ) -> Double? {
        guard let rates = resolve(model: model) else { return nil }
        return rates.costDollars(for: tokens, applyLongContextRates: applyLongContextRates)
    }

    /// Dollar cost for Cursor's usage CSV. Its scoped aliases can select Cursor-specific rates,
    /// while every other model continues through the shared public-catalog lookup.
    func estimatedCursorCostDollars(
        model: String,
        tokens: TokenBreakdown,
        applyLongContextRates: Bool = true
    ) -> Double? {
        let rates: ModelRates?
        if let canonical = cursorCanonicalName(for: model) {
            rates = lookup("cursor-\(canonical)") ?? lookup(canonical) ?? resolve(model: model)
        } else {
            rates = resolve(model: model)
        }
        guard let rates else { return nil }
        return rates.costDollars(for: tokens, applyLongContextRates: applyLongContextRates)
    }

    private func resolveUncached(model: String) -> ModelRates? {
        if let canonical = canonicalName(for: model), canonical != model {
            return lookup(canonical) ?? lookup(model)
        }
        return lookup(model)
    }

    /// The secondary catalog is consulted only after the whole primary lookup misses, like ccusage —
    /// models.dev aggregates resellers whose rates can differ, so LiteLLM wins whenever it knows the
    /// model at all, and models.dev answers exact ids only (see the fuzzy note on the type).
    private func lookup(_ name: String) -> ModelRates? {
        if let entry = supplement.pricing[name] { return entry }
        if let exact = openRouter.findExact(name) { return withSupplementFastMultiplier(name, exact.rates) }
        if let exact = primary.findExact(name) { return withSupplementFastMultiplier(name, exact.rates) }
        // Separator-normalized retry: a log slug spelled with spaces/underscores where the public
        // catalogues hyphenate ("space bunny" ↔ "space-bunny", the stealth-codename case). Exact
        // lookups on the normalized form keep every catalogue's exact-only stance — the fuzzy pass
        // below is unchanged, so this cannot widen what a miss matches.
        let normalized = PricingCatalog.normalizedKey(name)
        if normalized != name {
            if let entry = supplement.pricing[normalized] { return entry }
            if let exact = openRouter.findExact(normalized) { return withSupplementFastMultiplier(name, exact.rates) }
            if let exact = primary.findExact(normalized) { return withSupplementFastMultiplier(name, exact.rates) }
        }
        if let fast = fastVariant(name) { return fast }
        if name.hasSuffix("-fast") { return secondary.findExact(name)?.rates }
        // A free-looking sibling must not inherit a paid catalog entry through the boundary-aware
        // fuzzy matcher. Exact supplement/catalog matches above still price verified free models;
        // this exact-only secondary check is their final public-catalog fallback.
        if hasFreeSuffix(name) { return secondary.findExact(name)?.rates }
        if let fuzzy = primary.findFuzzy(name) { return withSupplementFastMultiplier(name, fuzzy.rates) }
        if let exact = secondary.findExact(name) { return withSupplementFastMultiplier(name, exact.rates) }
        return nil
    }

    private func hasFreeSuffix(_ name: String) -> Bool {
        let normalized = PricingCatalog.normalizedKey(name).lowercased()
        let lastSegment = normalized.split(separator: "/").last.map(String.init) ?? normalized
        return lastSegment.hasSuffix("-free")
    }

    /// Catalog-resolved entries carry the feed's own fast multiplier, but feeds can drop it
    /// (LiteLLM removed Anthropic's `fast` fields in October 2026). Fall back to the supplement's
    /// curated multiplier so a request the scanner flagged fast on the base slug still bills at the
    /// fast rate — the same intent `PricingSupplement.decode` stamps onto supplement-priced entries.
    /// Never touches dedicated `-fast` cards (already fast-priced) or entries whose multiplier the
    /// feed does supply.
    private func withSupplementFastMultiplier(_ name: String, _ rates: ModelRates) -> ModelRates {
        guard !name.hasSuffix("-fast"), rates.fastMultiplier == 1,
              let multiplier = supplement.fastMultiplier(for: name) else { return rates }
        var stamped = rates
        stamped.fastMultiplier = multiplier
        return stamped
    }

    /// Prices `<base>-fast` slugs from their base entry when a fast multiplier is known. Returns
    /// nil when the multiplier is unknown; the caller may still accept an exact fast entry from
    /// models.dev, but never fuzzy-matches the standard-speed base rate.
    private func fastVariant(_ name: String) -> ModelRates? {
        guard name.hasSuffix("-fast") else { return nil }
        let base = String(name.dropLast("-fast".count))
        guard !base.isEmpty else { return nil }
        guard let (key, rates) = baseEntry(base) else { return nil }
        let multiplier: Double
        if rates.fastMultiplier != 1 {
            multiplier = rates.fastMultiplier
        } else if let supplementMultiplier = supplement.fastMultiplier(for: key) ?? supplement.fastMultiplier(for: base) {
            multiplier = supplementMultiplier
        } else {
            return nil
        }
        return rates.scaled(by: multiplier)
    }

    private func baseEntry(_ base: String) -> (key: String, rates: ModelRates)? {
        if let entry = supplement.pricing[base] { return (base, entry) }
        if let entry = openRouter.findExact(base) { return (base, entry.rates) }
        return primary.findExact(base)
            ?? datedPrimaryEntry(for: base)
            ?? secondary.findExact(base)
    }

    /// Keep the historical dated-slug compatibility for fast variants without letting a nearby
    /// sibling such as `gpt-9-pro` supply the base rates for `gpt-9-fast`.
    private func datedPrimaryEntry(for base: String) -> (key: String, rates: ModelRates)? {
        let normalizedBase = PricingCatalog.normalizedKey(base)
        let baseHasProviderPrefix = normalizedBase.contains("/")
        let baseSlug = normalizedBase.split(separator: "/").last.map(String.init) ?? normalizedBase
        let candidates = primary.entries.compactMap { key, rates -> (key: String, date: String, rates: ModelRates)? in
            let normalizedKey = PricingCatalog.normalizedKey(key)
            let candidateSlug = normalizedKey.split(separator: "/").last.map(String.init) ?? normalizedKey
            let comparableBase = baseHasProviderPrefix ? normalizedBase : baseSlug
            let comparableKey = baseHasProviderPrefix ? normalizedKey : candidateSlug
            let datedPrefix = comparableBase + "-"
            guard comparableKey.hasPrefix(datedPrefix) else { return nil }
            let suffix = comparableKey.dropFirst(datedPrefix.count)
            let date = suffix.prefix(8)
            guard date.utf8.count == 8,
                  date.utf8.allSatisfy({ (48...57).contains($0) }),
                  suffix.count == 8 || suffix.dropFirst(8).first == "-" else { return nil }
            return (key, String(date), rates)
        }
        guard let candidate = candidates.sorted(by: {
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.key.count == $1.key.count ? $0.key < $1.key : $0.key.count > $1.key.count
        }).first else { return nil }
        return (candidate.key, candidate.rates)
    }
}
