import Foundation
import CoreFoundation

/// Parsers for the three public pricing feeds, plus the compact catalog format QuotaBar uses for
/// its bundled snapshots and on-disk caches (cost fields only — the full feeds are megabytes).
enum PricingCatalogCodecs {
    // MARK: - OpenRouter (/api/v1/models)

    /// Builds an exact-match estimate catalog from OpenRouter's public model list. Prompt and
    /// completion prices are USD per token in the API; QuotaBar stores per-million rates. The feed
    /// does not expose generally applicable cache prices, so use the prompt rate without assuming
    /// a cache discount. Bare aliases are added only when exactly one non-variant route owns them.
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
            routes[key] = ModelRates(
                inputPerMillion: input,
                outputPerMillion: completion * 1_000_000,
                cacheWritePerMillion: input,
                cacheReadPerMillion: input,
                cacheReadIsExplicit: false
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
            var rates = ModelRates(
                inputPerMillion: input * 1_000_000,
                outputPerMillion: output * 1_000_000,
                cacheWritePerMillion: (cacheWrite ?? input) * 1_000_000,
                cacheReadPerMillion: (cacheRead ?? input * 0.1) * 1_000_000,
                cacheReadIsExplicit: cacheRead != nil
            )
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
    /// Model ids are stored bare; when the same id appears under several providers the first in
    /// provider-name order wins (rates agree in practice). Costs are already per-million.
    static func catalogFromModelsDev(_ data: Data) throws -> PricingCatalog {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PricingCodecError.notAnObject
        }
        var entries: [String: ModelRates] = [:]
        for providerName in root.keys.sorted() {
            guard let provider = root[providerName] as? [String: Any],
                  let models = provider["models"] as? [String: Any] else { continue }
            for (modelID, value) in models {
                guard entries[modelID] == nil,
                      let model = value as? [String: Any],
                      let cost = model["cost"] as? [String: Any],
                      let input = doubleValue(cost["input"]),
                      let output = doubleValue(cost["output"]) else { continue }
                entries[modelID] = ModelRates(
                    inputPerMillion: input,
                    outputPerMillion: output,
                    cacheWritePerMillion: doubleValue(cost["cache_write"]) ?? input,
                    cacheReadPerMillion: doubleValue(cost["cache_read"]) ?? input * 0.1,
                    cacheReadIsExplicit: cost["cache_read"] != nil
                )
            }
        }
        guard !entries.isEmpty else { throw PricingCodecError.noUsableEntries }
        return PricingCatalog(entries: entries)
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
                inputAbove200kPerMillion: model.ia,
                outputAbove200kPerMillion: model.oa,
                cacheWriteAbove200kPerMillion: model.cwa,
                cacheReadAbove200kPerMillion: model.cra,
                cacheReadIsExplicit: model.cre ?? true,
                fastMultiplier: model.fast ?? 1
            )
        }
        return PricingCatalog(entries: entries, retrievedAt: file.retrievedAt)
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
        return try encoder.encode(CompactCatalog(retrievedAt: catalog.retrievedAt, models: models))
    }

    /// Per-million rates keyed by short names to keep snapshots small: `i`nput, `o`utput,
    /// `c`ache`w`rite, `c`ache`r`ead, with `a`bove-200k variants, plus the `fast` multiplier.
    private struct CompactCatalog: Codable {
        var retrievedAt: String?
        var models: [String: Model]

        struct Model: Codable {
            var i: Double
            var o: Double
            var cw: Double
            var cr: Double
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
