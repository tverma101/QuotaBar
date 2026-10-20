import Foundation
import CoreFoundation

/// Parsers for the three public pricing feeds, plus the compact catalog format QuotaBar uses for
/// its bundled snapshots and on-disk caches (cost fields only — the full feeds are megabytes).
enum PricingCatalogCodecs {
    // MARK: - OpenRouter (/api/v1/models)

    struct OpenRouterCatalogPage {
        let models: [[String: Any]]
        let totalCount: Int
        let nextOffset: Int?
    }

    /// Reads one page's pagination metadata. The store follows `nextOffset` using the configured
    /// OpenRouter endpoint, then validates the combined list before replacing its on-disk catalog.
    static func openRouterCatalogPage(from data: Data) throws -> OpenRouterCatalogPage {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["data"] as? [[String: Any]],
              let totalCount = integerValue(root["total_count"]),
              let links = root["links"] as? [String: Any],
              let next = links["next"] else {
            throw PricingCodecError.incompleteModelList
        }

        let nextOffset: Int?
        if next is NSNull {
            nextOffset = nil
        } else if let nextURL = next as? String,
                  let components = URLComponents(string: nextURL),
                  let rawOffset = components.queryItems?.first(where: { $0.name == "offset" })?.value,
                  let offset = Int(rawOffset), offset >= 0 {
            nextOffset = offset
        } else {
            throw PricingCodecError.incompleteModelList
        }

        return OpenRouterCatalogPage(models: models, totalCount: totalCount, nextOffset: nextOffset)
    }

    /// Builds an exact-match estimate catalog from OpenRouter's public model list. Prices are USD
    /// per token in the API; QuotaBar stores per-million rates. Retain published cache prices and
    /// prompt-length overrides, while ignoring time/day overrides that cannot be resolved for
    /// historical usage without event timestamps. Bare aliases are added only when exactly one
    /// non-variant route owns them.
    static func catalogFromOpenRouter(_ data: Data) throws -> PricingCatalog {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["data"] as? [[String: Any]] else {
            throw PricingCodecError.notAnObject
        }

        guard let totalCount = integerValue(root["total_count"]),
              totalCount == models.count,
              let links = root["links"] as? [String: Any],
              let next = links["next"], next is NSNull else {
            throw PricingCodecError.incompleteModelList
        }

        var routes: [String: ModelRates] = [:]
        var aliases: [String: [String]] = [:]
        routes.reserveCapacity(models.count)
        for model in models {
            guard let id = model["id"] as? String else { continue }
            let key = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, routes[key] == nil,
                  let pricing = model["pricing"] as? [String: Any],
                  let prompt = nonnegativeFiniteDouble(pricing["prompt"]),
                  let completion = nonnegativeFiniteDouble(pricing["completion"]),
                  prompt <= Double.greatestFiniteMagnitude / 1_000_000,
                  completion <= Double.greatestFiniteMagnitude / 1_000_000 else { continue }

            let input = prompt * 1_000_000
            let cacheWrite = perMillionRate(pricing["input_cache_write"])
            let cacheRead = perMillionRate(pricing["input_cache_read"])
            let promptTiers = openRouterPromptRateTiers(pricing["overrides"], modelID: key)
            routes[key] = ModelRates(
                inputPerMillion: input,
                outputPerMillion: completion * 1_000_000,
                cacheWritePerMillion: cacheWrite ?? input,
                cacheReadPerMillion: cacheRead ?? input,
                cacheWrite1hPerMillion: perMillionRate(pricing["input_cache_write_1h"]),
                promptRateTiers: promptTiers,
                cacheReadIsExplicit: cacheRead != nil || promptTiers.contains { $0.cacheReadPerMillion != nil }
            )

            let components = key.split(separator: "/", omittingEmptySubsequences: false)
            guard components.count == 2,
                  !components[1].contains(":"),
                  !components[1].isEmpty else { continue }
            let alias = components[1].lowercased()
            aliases[alias, default: []].append(key)
        }

        guard !routes.isEmpty else { throw PricingCodecError.noUsableEntries }

        var entries = routes
        for (alias, routeIDs) in aliases where routeIDs.count == 1 && entries[alias] == nil {
            if let rates = routes[routeIDs[0]] {
                entries[alias] = rates
            }
        }
        return PricingCatalog(entries: entries)
    }

    // MARK: - LiteLLM (model_prices_and_context_window.json)

    /// Builds a catalog from LiteLLM's full JSON. Entries without both input and output costs are
    /// skipped (stubs and non-chat modes). Costs are per-token in the feed; stored per-million.
    /// Parsed with JSONSerialization so one malformed entry can't sink the whole feed.
    static func catalogFromLiteLLM(_ data: Data) throws -> PricingCatalog {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PricingCodecError.notAnObject
        }
        var entries: [String: ModelRates] = [:]
        for (key, value) in root {
            guard let entry = value as? [String: Any],
                  let input = doubleValue(entry["input_cost_per_token"]),
                  let output = doubleValue(entry["output_cost_per_token"]) else { continue }
            let cacheWrite = doubleValue(entry["cache_creation_input_token_cost"])
            let cacheRead = doubleValue(entry["cache_read_input_token_cost"])
            let promptRateTiers = liteLLMPromptRateTiers(entry)
            var rates = ModelRates(
                inputPerMillion: input * 1_000_000,
                outputPerMillion: output * 1_000_000,
                cacheWritePerMillion: (cacheWrite ?? input) * 1_000_000,
                cacheReadPerMillion: (cacheRead ?? input) * 1_000_000,
                cacheReadIsExplicit: cacheRead != nil
                    || promptRateTiers.contains { $0.cacheReadPerMillion != nil }
            )
            rates.promptRateTiers = promptRateTiers
            rates.inputAbove200kPerMillion = doubleValue(entry["input_cost_per_token_above_200k_tokens"]).map { $0 * 1_000_000 }
            rates.outputAbove200kPerMillion = doubleValue(entry["output_cost_per_token_above_200k_tokens"]).map { $0 * 1_000_000 }
            rates.cacheWriteAbove200kPerMillion = doubleValue(entry["cache_creation_input_token_cost_above_200k_tokens"]).map { $0 * 1_000_000 }
            rates.cacheReadAbove200kPerMillion = doubleValue(entry["cache_read_input_token_cost_above_200k_tokens"]).map { $0 * 1_000_000 }
            if let providerSpecific = entry["provider_specific_entry"] as? [String: Any],
               let fast = doubleValue(providerSpecific["fast"]) {
                rates.fastMultiplier = fast
            }
            entries[key] = rates
        }
        guard !entries.isEmpty else { throw PricingCodecError.noUsableEntries }
        return PricingCatalog(entries: entries)
    }

    // MARK: - models.dev (api.json)

    /// Builds a catalog from models.dev's api.json (`{provider: {models: {id: {cost: ...}}}}`).
    /// Model ids are stored bare. Duplicate IDs are kept only when every provider publishes the
    /// same rates; an ambiguous reseller price is less useful than leaving the model unpriced.
    /// Costs are already per-million.
    static func catalogFromModelsDev(_ data: Data) throws -> PricingCatalog {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PricingCodecError.notAnObject
        }
        var candidates: [String: [ModelRates]] = [:]
        for providerName in root.keys.sorted() {
            guard let provider = root[providerName] as? [String: Any],
                  let models = provider["models"] as? [String: Any] else { continue }
            for (modelID, value) in models {
                guard let model = value as? [String: Any],
                      let cost = model["cost"] as? [String: Any],
                      let input = doubleValue(cost["input"]),
                      let output = doubleValue(cost["output"]) else { continue }
                var tiers = modelsDevPromptRateTiers(cost["tiers"])
                if !tiers.contains(where: { $0.thresholdPromptTokens == 200_000 }),
                   let longContext = cost["context_over_200k"] as? [String: Any] {
                    if let tier = modelsDevPromptRateTier(longContext, threshold: 200_000) {
                        tiers.append(tier)
                    }
                }
                candidates[modelID, default: []].append(ModelRates(
                    inputPerMillion: input,
                    outputPerMillion: output,
                    cacheWritePerMillion: doubleValue(cost["cache_write"]) ?? input,
                    cacheReadPerMillion: doubleValue(cost["cache_read"]) ?? input,
                    promptRateTiers: tiers.sorted { $0.thresholdPromptTokens < $1.thresholdPromptTokens },
                    cacheReadIsExplicit: cost["cache_read"] != nil
                        || tiers.contains { $0.cacheReadPerMillion != nil }
                ))
            }
        }
        let entries = candidates.compactMapValues { rates -> ModelRates? in
            guard let first = rates.first,
                  rates.dropFirst().allSatisfy({ $0 == first }) else { return nil }
            return first
        }
        guard !entries.isEmpty else { throw PricingCodecError.noUsableEntries }
        let retiredKeys = Set(candidates.keys.filter { entries[$0] == nil })
        return PricingCatalog(
            entries: entries,
            retiredKeys: retiredKeys,
            retiredKeysAreAuthoritative: true
        )
    }

    private static let liteLLMTierThresholds = [100_000, 128_000, 200_000, 272_000, 512_000]

    private static func liteLLMPromptRateTiers(_ entry: [String: Any]) -> [PromptRateTier] {
        liteLLMTierThresholds.compactMap { threshold in
            let suffix = "above_\(threshold / 1_000)k_tokens"
            return makePromptRateTier(
                threshold: threshold,
                includesThreshold: false,
                input: doubleValue(entry["input_cost_per_token_\(suffix)"]).map { $0 * 1_000_000 },
                output: doubleValue(entry["output_cost_per_token_\(suffix)"]).map { $0 * 1_000_000 },
                cacheWrite: doubleValue(entry["cache_creation_input_token_cost_\(suffix)"]).map { $0 * 1_000_000 },
                cacheRead: doubleValue(entry["cache_read_input_token_cost_\(suffix)"]).map { $0 * 1_000_000 }
            )
        }
    }

    private static func modelsDevPromptRateTiers(_ value: Any?) -> [PromptRateTier] {
        guard let tiers = value as? [[String: Any]] else { return [] }
        return tiers.compactMap { tier in
            guard let context = tier["tier"] as? [String: Any],
                  context["type"] as? String == "context",
                  let threshold = integerValue(context["size"]) else { return nil }
            return modelsDevPromptRateTier(tier, threshold: threshold)
        }
    }

    private static func modelsDevPromptRateTier(_ rates: [String: Any], threshold: Int) -> PromptRateTier? {
        makePromptRateTier(
            threshold: threshold,
            includesThreshold: true,
            input: doubleValue(rates["input"]),
            output: doubleValue(rates["output"]),
            cacheWrite: doubleValue(rates["cache_write"]),
            cacheRead: doubleValue(rates["cache_read"])
        )
    }

    private static func makePromptRateTier(
        threshold: Int,
        includesThreshold: Bool,
        input: Double?,
        output: Double?,
        cacheWrite: Double?,
        cacheRead: Double?
    ) -> PromptRateTier? {
        let tier = PromptRateTier(
            thresholdPromptTokens: threshold,
            includesThreshold: includesThreshold,
            inputPerMillion: input,
            outputPerMillion: output,
            cacheWritePerMillion: cacheWrite,
            cacheReadPerMillion: cacheRead
        )
        return tierHasRates(tier) ? tier : nil
    }

    private static func tierHasRates(_ tier: PromptRateTier) -> Bool {
        tier.inputPerMillion != nil || tier.outputPerMillion != nil
            || tier.cacheWritePerMillion != nil || tier.cacheReadPerMillion != nil
            || tier.cacheWrite1hPerMillion != nil
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        return nil
    }

    private static func nonnegativeFiniteDouble(_ value: Any?) -> Double? {
        let result: Double
        if let string = value as? String {
            guard let parsed = Double(string) else { return nil }
            result = parsed
        } else if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            result = number.doubleValue
        } else {
            return nil
        }
        guard result.isFinite, result >= 0 else { return nil }
        return result
    }

    /// OpenRouter expresses per-token values as decimal strings; keep invalid or out-of-range
    /// optional cache/tier lanes absent so the model falls back to its regular prompt rate.
    private static func perMillionRate(_ value: Any?) -> Double? {
        guard let rate = nonnegativeFiniteDouble(value),
              rate <= Double.greatestFiniteMagnitude / 1_000_000 else { return nil }
        return rate * 1_000_000
    }

    /// Only `min_prompt_tokens` overrides describe request-size tiers. OpenRouter also publishes
    /// time/day-dependent overrides; those cannot be selected from aggregate token counts alone.
    private static func openRouterPromptRateTiers(_ value: Any?, modelID: String) -> [PromptRateTier] {
        guard let overrides = value as? [[String: Any]] else { return [] }
        return overrides.compactMap { override in
            guard let threshold = integerValue(override["min_prompt_tokens"]) else { return nil }
            let modelSlug = modelID
                .split(separator: "/", omittingEmptySubsequences: false)
                .last
                .map { String($0).split(separator: ":", maxSplits: 1).first.map(String.init) ?? "" }
                ?? ""
            let normalizedModelSlug = modelSlug.lowercased()
            // OpenRouter expresses GPT-6.1 Sol's published `>272K` direct-price boundary as
            // `min_prompt_tokens: 272000`. Keep the exact 272,000-token request at standard rates.
            let isExclusiveGPT61SolBoundary = normalizedModelSlug == "gpt-6.1-sol" && threshold == 272_000
            let tier = PromptRateTier(
                thresholdPromptTokens: threshold,
                includesThreshold: !isExclusiveGPT61SolBoundary,
                inputPerMillion: perMillionRate(override["prompt"]),
                outputPerMillion: perMillionRate(override["completion"]),
                cacheWritePerMillion: perMillionRate(override["input_cache_write"]),
                cacheReadPerMillion: perMillionRate(override["input_cache_read"]),
                cacheWrite1hPerMillion: perMillionRate(override["input_cache_write_1h"])
            )
            guard tier.inputPerMillion != nil || tier.outputPerMillion != nil
                    || tier.cacheWritePerMillion != nil || tier.cacheReadPerMillion != nil
                    || tier.cacheWrite1hPerMillion != nil else { return nil }
            return tier
        }.sorted { $0.thresholdPromptTokens < $1.thresholdPromptTokens }
    }

    private static func integerValue(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value >= 0, value.rounded(.towardZero) == value,
              value < Double(Int.max) else { return nil }
        return Int(value)
    }

    // MARK: - Compact format (bundled snapshots + disk cache)

    static func catalogFromCompact(_ data: Data) throws -> PricingCatalog {
        let file = try JSONDecoder().decode(CompactCatalog.self, from: data)
        var entries: [String: ModelRates] = [:]
        entries.reserveCapacity(file.models.count)
        for (key, model) in file.models {
            entries[key] = ModelRates(
                inputPerMillion: model.i,
                outputPerMillion: model.o,
                cacheWritePerMillion: model.cw,
                cacheReadPerMillion: model.cr,
                cacheWrite1hPerMillion: model.cw1,
                promptRateTiers: model.tiers ?? [],
                inputAbove200kPerMillion: model.ia,
                outputAbove200kPerMillion: model.oa,
                cacheWriteAbove200kPerMillion: model.cwa,
                cacheReadAbove200kPerMillion: model.cra,
                cacheReadIsExplicit: model.cre ?? true,
                fastMultiplier: model.fast ?? 1
            )
        }
        return PricingCatalog(
            entries: entries,
            retrievedAt: file.retrievedAt,
            retiredKeys: Set(file.retiredKeys ?? []),
            retiredKeysAreAuthoritative: file.retiredKeys != nil
        )
    }

    static func compactData(from catalog: PricingCatalog) throws -> Data {
        var models: [String: CompactCatalog.Model] = [:]
        models.reserveCapacity(catalog.entries.count)
        for (key, rates) in catalog.entries {
            models[key] = CompactCatalog.Model(
                i: rates.inputPerMillion,
                o: rates.outputPerMillion,
                cw: rates.cacheWritePerMillion,
                cr: rates.cacheReadPerMillion,
                cw1: rates.cacheWrite1hPerMillion,
                tiers: rates.promptRateTiers.isEmpty ? nil : rates.promptRateTiers,
                ia: rates.inputAbove200kPerMillion,
                oa: rates.outputAbove200kPerMillion,
                cwa: rates.cacheWriteAbove200kPerMillion,
                cra: rates.cacheReadAbove200kPerMillion,
                cre: rates.cacheReadIsExplicit ? nil : false,
                fast: rates.fastMultiplier == 1 ? nil : rates.fastMultiplier
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(CompactCatalog(
            retrievedAt: catalog.retrievedAt,
            models: models,
            retiredKeys: catalog.retiredKeysAreAuthoritative ? catalog.retiredKeys.sorted() : nil
        ))
    }

    /// Per-million rates keyed by short names to keep snapshots small: `i`nput, `o`utput,
    /// cache lanes, `a`bove-200k variants, optional prompt tiers, plus the `fast` multiplier.
    private struct CompactCatalog: Codable {
        var retrievedAt: String?
        var models: [String: Model]
        /// Presence marks a complete tombstone snapshot. Missing means this was written by an older app.
        var retiredKeys: [String]?

        struct Model: Codable {
            var i: Double
            var o: Double
            var cw: Double
            var cr: Double
            var cw1: Double?
            var tiers: [PromptRateTier]?
            var ia: Double?
            var oa: Double?
            var cwa: Double?
            var cra: Double?
            /// Omitted means explicit for backward compatibility with snapshots written before the
            /// provenance bit existed. Newly compacted synthesized rates write `false`.
            var cre: Bool?
            var fast: Double?
        }

        enum CodingKeys: String, CodingKey {
            case retrievedAt = "retrieved_at"
            case models
            case retiredKeys = "retired"
        }
    }
}

enum PricingCodecError: Error, LocalizedError, Equatable {
    case notAnObject
    case noUsableEntries
    case incompleteModelList

    var errorDescription: String? {
        switch self {
        case .notAnObject: return "Pricing feed is not a JSON object."
        case .noUsableEntries: return "Pricing feed contained no usable model entries."
        case .incompleteModelList: return "OpenRouter returned a paginated or incomplete model list."
        }
    }
}
