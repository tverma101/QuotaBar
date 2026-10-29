import Foundation

/// The priced identity one router slug resolved to.
///
/// Everything the fold needs to reproduce a row's dollars: the catalog key that priced it, the
/// identity the row is grouped under, the rates themselves, and the Codex priority multiplier.
struct CodexRouterPricingResolution: Codable, Equatable, Sendable {
    var pricingModel: String
    var canonicalModel: String
    var rates: ModelRates
    var priorityMultiplier: Double
}

/// One pricing resolution the CodexRouter fold depended on.
///
/// The persisted aggregate is identified by the ledger, the account, the window and the alias map —
/// never by the global pricing catalogue. A catalogue refresh that only touches models the ledger
/// never used must not cost another read of a 150 MB ledger, so the fold records what it actually
/// priced. A later catalogue change is then checked against this snapshot instead of against a hash
/// of every catalogue entry.
struct CodexRouterPricingDependency: Codable, Equatable, Sendable {
    /// The slug exactly as the router emitted it.
    var model: String
    /// The UTC day (`yyyy-MM-dd`) a dated reserve fallback was resolved against. Nil when the
    /// resolution cannot depend on the day: catalog prices and models nothing can price.
    var utcDay: String?
    /// The priced identity, or nil when the model could not be priced at all.
    var resolution: CodexRouterPricingResolution?

    /// Stable identity of one recorded resolution.
    var key: String { model + "\u{1f}" + (utcDay ?? "") }
}

/// The pricing resolutions one router fold depended on.
struct CodexRouterPricingDependencySet: Codable, Equatable, Sendable {
    var dependencies: [CodexRouterPricingDependency]

    /// True when every recorded resolution still holds under `pricing`.
    ///
    /// A model that was unknown and is priced now fails here, and so does a dated reserve fallback
    /// whose day now resolves to a different model or different rates. Only a catalogue change that
    /// cannot touch this fold's numbers passes.
    func isEquivalent(under pricing: ModelPricing) -> Bool {
        dependencies.allSatisfy { $0.isEquivalent(under: pricing) }
    }

    /// Union with another set. The same slug resolved twice must land on one entry, and the newer
    /// resolution wins: it was priced under the catalogue the fold is being saved for.
    func merged(with other: CodexRouterPricingDependencySet) -> CodexRouterPricingDependencySet {
        var merged: [String: CodexRouterPricingDependency] = [:]
        for dependency in dependencies { merged[dependency.key] = dependency }
        for dependency in other.dependencies { merged[dependency.key] = dependency }
        return CodexRouterPricingDependencySet(
            dependencies: merged.values.sorted { $0.key < $1.key }
        )
    }
}

extension CodexRouterPricingDependency {
    /// Whether this recorded resolution still holds under `pricing`.
    func isEquivalent(under pricing: ModelPricing) -> Bool {
        if let utcDay {
            // A dated reserve fallback only prices while the catalogue does not price the slug
            // itself, and it prices per UTC day.
            guard CodexRouterPricingResolver.resolveCatalog(model: model, pricing: pricing) == nil else {
                return false
            }
            return CodexRouterPricingResolver.resolveDatedFallback(
                model: model,
                utcDay: utcDay,
                pricing: pricing
            ) == resolution
        }
        // A catalog price — or a model nothing can price — does not depend on the day.
        guard let catalog = CodexRouterPricingResolver.resolveCatalog(model: model, pricing: pricing) else {
            guard resolution == nil else { return false }
            // A reserve slug always prices through the dated fallback, never as an unknown model.
            return !CodexRouterPricingResolver.isDatedFallback(model: model)
        }
        return catalog == resolution
    }
}

/// The pricing resolution the router fold uses for one slug.
///
/// The fold and the dependency check share this code on purpose: a check that resolved a model
/// differently from the way the fold priced it would silently reuse a stale fold.
enum CodexRouterPricingResolver {
    /// The catalog resolution: the exact catalog key wins, then the first candidate that resolves.
    static func resolveCatalog(model: String, pricing: ModelPricing) -> CodexRouterPricingResolution? {
        let candidates = pricingModelCandidates(for: model)
        // Prefer an exact catalog key so gateway-tagged slugs group under the model they route to.
        let exactIdentity = pricing.canonicalKey(for: candidates)
        guard let pricingModel = exactIdentity
            ?? candidates.first(where: { pricing.resolve(model: $0) != nil }),
            let rates = pricing.resolve(model: pricingModel)
        else { return nil }
        return resolution(model: model, pricingModel: pricingModel, rates: rates)
    }

    /// Whether the slug is a dated reserve / auto-review alias whose price depends on the day.
    static func isDatedFallback(model: String) -> Bool {
        CodexLogUsageScanner.pricingFallbackModel(for: model, at: "") != nil
    }

    /// The dated reserve fallback for one UTC day (`yyyy-MM-dd`), priced under `pricing`.
    static func resolveDatedFallback(
        model: String,
        utcDay: String,
        pricing: ModelPricing
    ) -> CodexRouterPricingResolution? {
        guard let fallbackModel = CodexLogUsageScanner.pricingFallbackModel(for: model, at: utcDay),
              let rates = pricing.resolve(model: fallbackModel)
        else { return nil }
        return resolution(model: model, pricingModel: fallbackModel, rates: rates)
    }

    private static func resolution(
        model: String,
        pricingModel: String,
        rates: ModelRates
    ) -> CodexRouterPricingResolution {
        CodexRouterPricingResolution(
            pricingModel: pricingModel,
            canonicalModel: GatewaySlug.identity(of: model, resolvedPricingModel: pricingModel),
            rates: rates,
            priorityMultiplier: CodexLogUsageScanner.codexPriorityMultiplier(
                for: pricingModel,
                rates: rates
            )
        )
    }

    /// Every slug suffix the router may have stamped onto a model name.
    ///
    /// FCC / gateway slugs are often multi-segment (`anthropic/openai/gpt-6-luna`). Emit every
    /// suffix after a `/` plus the final path component so supplement pins and catalog keys resolve
    /// even when an intermediate segment does not fuzzy-match.
    static func pricingModelCandidates(for model: String) -> [String] {
        var candidates = [model]
        var remainder = model
        while let separator = remainder.firstIndex(of: "/") {
            remainder = String(remainder[remainder.index(after: separator)...])
            guard !remainder.isEmpty else { break }
            candidates.append(remainder)
        }
        var seen: Set<String> = []
        return candidates.filter { seen.insert($0).inserted }
    }
}
