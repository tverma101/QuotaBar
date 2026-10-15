import Foundation

/// A whole-request price tier selected by the prompt length. The rate feed's threshold is
/// exclusive (for example, Anthropic says "over 100k"), so the tier applies when prompt tokens
/// exceed `thresholdPromptTokens`. Unspecified lanes inherit the model's regular or legacy long
/// context rate.
struct PromptRateTier: Codable, Sendable, Equatable {
    var thresholdPromptTokens: Int
    var includesThreshold: Bool
    var inputPerMillion: Double?
    var outputPerMillion: Double?
    var cacheWritePerMillion: Double?
    var cacheReadPerMillion: Double?
    var cacheWrite1hPerMillion: Double?

    init(
        thresholdPromptTokens: Int,
        includesThreshold: Bool = false,
        inputPerMillion: Double? = nil,
        outputPerMillion: Double? = nil,
        cacheWritePerMillion: Double? = nil,
        cacheReadPerMillion: Double? = nil,
        cacheWrite1hPerMillion: Double? = nil
    ) {
        self.thresholdPromptTokens = thresholdPromptTokens
        self.includesThreshold = includesThreshold
        self.inputPerMillion = inputPerMillion
        self.outputPerMillion = outputPerMillion
        self.cacheWritePerMillion = cacheWritePerMillion
        self.cacheReadPerMillion = cacheReadPerMillion
        self.cacheWrite1hPerMillion = cacheWrite1hPerMillion
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        thresholdPromptTokens = try values.decode(Int.self, forKey: .thresholdPromptTokens)
        includesThreshold = try values.decodeIfPresent(Bool.self, forKey: .includesThreshold) ?? false
        inputPerMillion = try values.decodeIfPresent(Double.self, forKey: .inputPerMillion)
        outputPerMillion = try values.decodeIfPresent(Double.self, forKey: .outputPerMillion)
        cacheWritePerMillion = try values.decodeIfPresent(Double.self, forKey: .cacheWritePerMillion)
        cacheReadPerMillion = try values.decodeIfPresent(Double.self, forKey: .cacheReadPerMillion)
        cacheWrite1hPerMillion = try values.decodeIfPresent(Double.self, forKey: .cacheWrite1hPerMillion)
    }

    enum CodingKeys: String, CodingKey {
        case thresholdPromptTokens = "threshold_prompt_tokens"
        case includesThreshold = "includes_threshold"
        case inputPerMillion = "input_per_million"
        case outputPerMillion = "output_per_million"
        case cacheWritePerMillion = "cache_write_per_million"
        case cacheReadPerMillion = "cache_read_per_million"
        case cacheWrite1hPerMillion = "cache_write_1h_per_million"
    }
}

/// Per-million-token USD rates for one model, plus optional long-context tiers and a fast-variant
/// multiplier. All spend imputation (Claude, Codex, Cursor, Grok) prices through these.
struct ModelRates: Sendable, Equatable {
    var inputPerMillion: Double
    var outputPerMillion: Double
    /// 5-minute ephemeral cache writes (Anthropic-style). For providers without a separate
    /// cache-write price this equals the input rate.
    var cacheWritePerMillion: Double
    var cacheReadPerMillion: Double
    /// Explicit 1-hour cache-write rate when the source publishes one. Otherwise the shared
    /// estimate remains 2x the selected input rate.
    var cacheWrite1hPerMillion: Double? = nil

    /// Source-published prompt-length tiers. Unlike the legacy single 200k fields below, these can
    /// represent several thresholds and distinct cache lanes.
    var promptRateTiers: [PromptRateTier] = []

    /// Rates for requests whose prompt exceeds the model's long-context threshold, where the
    /// provider prices the whole request at the higher tier. Field names retain the catalog's
    /// common `above_200k` terminology; `longContextThresholdTokens` selects the actual boundary.
    var inputAbove200kPerMillion: Double?
    var outputAbove200kPerMillion: Double?
    var cacheWriteAbove200kPerMillion: Double?
    var cacheReadAbove200kPerMillion: Double?

    /// Whether the pricing source explicitly published the cache-read rate. When it did not, spend
    /// uses the selected input rate for cache reads rather than inventing a discount.
    var cacheReadIsExplicit: Bool = true

    /// Prompt-token threshold above which the optional long-context rates apply.
    var longContextThresholdTokens: Int = 200_000

    /// Rate multiplier for the model's "fast" variant (1 when the model has none).
    var fastMultiplier: Double = 1

    /// The same rates with every dollar figure scaled — used to price `-fast` model slugs off their
    /// base entry.
    func scaled(by factor: Double) -> ModelRates {
        ModelRates(
            inputPerMillion: inputPerMillion * factor,
            outputPerMillion: outputPerMillion * factor,
            cacheWritePerMillion: cacheWritePerMillion * factor,
            cacheReadPerMillion: cacheReadPerMillion * factor,
            cacheWrite1hPerMillion: cacheWrite1hPerMillion.map { $0 * factor },
            promptRateTiers: promptRateTiers.map { tier in
                PromptRateTier(
                    thresholdPromptTokens: tier.thresholdPromptTokens,
                    includesThreshold: tier.includesThreshold,
                    inputPerMillion: tier.inputPerMillion.map { $0 * factor },
                    outputPerMillion: tier.outputPerMillion.map { $0 * factor },
                    cacheWritePerMillion: tier.cacheWritePerMillion.map { $0 * factor },
                    cacheReadPerMillion: tier.cacheReadPerMillion.map { $0 * factor },
                    cacheWrite1hPerMillion: tier.cacheWrite1hPerMillion.map { $0 * factor }
                )
            },
            inputAbove200kPerMillion: inputAbove200kPerMillion.map { $0 * factor },
            outputAbove200kPerMillion: outputAbove200kPerMillion.map { $0 * factor },
            cacheWriteAbove200kPerMillion: cacheWriteAbove200kPerMillion.map { $0 * factor },
            cacheReadAbove200kPerMillion: cacheReadAbove200kPerMillion.map { $0 * factor },
            cacheReadIsExplicit: cacheReadIsExplicit,
            longContextThresholdTokens: longContextThresholdTokens,
            fastMultiplier: 1
        )
    }
}

/// Token counts split into the buckets that price differently. Every scanner normalizes into this.
struct TokenBreakdown: Codable, Sendable, Equatable {
    /// Input tokens billed at the plain input rate (not written to or read from cache).
    var input: Int = 0
    /// Input tokens written to the 5-minute ephemeral cache.
    var cacheWrite5m: Int = 0
    /// Input tokens written to the 1-hour ephemeral cache (billed at 2x input).
    var cacheWrite1h: Int = 0
    var cacheRead: Int = 0
    var output: Int = 0
    /// The request ran the model's "fast" variant (Claude logs carry a `speed` field).
    var isFast: Bool = false

    /// Input that determines whether the request crosses the long-context threshold. Output does not
    /// select the tier, but it is billed at the selected tier once the prompt crosses the threshold.
    var promptTokens: Int {
        let writes = ProviderParse.addingSaturating(cacheWrite5m, cacheWrite1h)
        return ProviderParse.addingSaturating(ProviderParse.addingSaturating(input, writes), cacheRead)
    }
    var totalTokens: Int { ProviderParse.addingSaturating(promptTokens, output) }
}

extension ModelRates {
    /// 1-hour cache writes are billed at twice the input rate (ccusage's rule; matches LiteLLM's
    /// explicit `above_1hr` fields where present).
    private static let cacheWrite1hInputMultiplier = 2.0

    /// Dollar cost of one request at these rates, applying the request-wide long-context tier and
    /// fast multiplier. Aggregated sources can opt out when their totals do not preserve request boundaries.
    func costDollars(for tokens: TokenBreakdown, applyLongContextRates: Bool = true) -> Double {
        let multiplier = tokens.isFast ? fastMultiplier : 1
        let useLongContextRates = applyLongContextRates && tokens.promptTokens > longContextThresholdTokens
        let selectedPromptTier = applyLongContextRates
            ? promptRateTiers
                .filter {
                    $0.includesThreshold
                        ? tokens.promptTokens >= $0.thresholdPromptTokens
                        : tokens.promptTokens > $0.thresholdPromptTokens
                }
                .max { $0.thresholdPromptTokens < $1.thresholdPromptTokens }
            : nil
        let inputRate = selectedRate(base: inputPerMillion, longContext: inputAbove200kPerMillion,
                                     promptTier: selectedPromptTier?.inputPerMillion,
                                     useLongContextRates: useLongContextRates)
        let outputRate = selectedRate(base: outputPerMillion, longContext: outputAbove200kPerMillion,
                                      promptTier: selectedPromptTier?.outputPerMillion,
                                      useLongContextRates: useLongContextRates)
        let cacheWriteRate = selectedRate(base: cacheWritePerMillion, longContext: cacheWriteAbove200kPerMillion,
                                          promptTier: selectedPromptTier?.cacheWritePerMillion,
                                          useLongContextRates: useLongContextRates)
        let cacheReadRate = cacheReadIsExplicit
            ? selectedRate(base: cacheReadPerMillion, longContext: cacheReadAbove200kPerMillion,
                           promptTier: selectedPromptTier?.cacheReadPerMillion,
                           useLongContextRates: useLongContextRates)
            : inputRate
        let cacheWrite1hRate = selectedPromptTier?.cacheWrite1hPerMillion
            ?? cacheWrite1hPerMillion
            ?? selectedRate(base: inputPerMillion, longContext: inputAbove200kPerMillion,
                            promptTier: selectedPromptTier?.inputPerMillion,
                            useLongContextRates: useLongContextRates) * Self.cacheWrite1hInputMultiplier

        let cost = cost(tokens.input, at: inputRate)
            + cost(tokens.output, at: outputRate)
            + cost(tokens.cacheWrite5m, at: cacheWriteRate)
            + cost(tokens.cacheWrite1h, at: cacheWrite1hRate)
            + cost(tokens.cacheRead, at: cacheReadRate)
        return cost * multiplier
    }

    private func selectedRate(
        base: Double,
        longContext: Double?,
        promptTier: Double?,
        useLongContextRates: Bool
    ) -> Double {
        promptTier ?? (useLongContextRates ? (longContext ?? base) : base)
    }

    private func cost(_ tokens: Int, at ratePerMillion: Double) -> Double {
        Double(tokens) * ratePerMillion / 1_000_000
    }
}
