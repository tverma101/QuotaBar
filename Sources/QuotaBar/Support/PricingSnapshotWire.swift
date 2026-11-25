import Foundation

/// Lossless JSON for the `pricing.load` request.
///
/// `JSONEncoder` formats doubles with 15 significant digits on Darwin, which is enough for display
/// but not for parity: a catalogue rate such as `0.09999999999999999` came back as `0.1` and priced
/// a scan one ULP off the Swift oracle. This encoder writes every `Double` with Swift's shortest
/// round-trip description, so Rust parses back the exact bit pattern the catalog holds.
///
/// The shape matches `ModelRates`' synthesized `Codable` keys (and `PromptRateTier`'s explicit
/// snake_case keys) so the existing Rust deserializers apply unchanged.
enum PricingSnapshotWire {
    static func request(
        supplementPricing: [String: ModelRates],
        fastMultipliers: [String: Double],
        primary: [String: ModelRates],
        secondary: [String: ModelRates],
        openRouter: [String: ModelRates]
    ) -> Data? {
        var data = Data()
        data.reserveCapacity(
            supplementPricing.count * 320 + primary.count * 320 + secondary.count * 320
                + openRouter.count * 320 + fastMultipliers.count * 40 + 256
        )
        data.append(contentsOf: #"{"op":"pricing.load","params":{"supplement":{"pricing":"#.utf8)
        guard appendRates(supplementPricing, to: &data) else { return nil }
        data.append(contentsOf: #","fastMultipliers":"#.utf8)
        guard appendDoubles(fastMultipliers, to: &data) else { return nil }
        data.append(contentsOf: #"},"primary":"#.utf8)
        guard appendRates(primary, to: &data) else { return nil }
        data.append(contentsOf: #","secondary":"#.utf8)
        guard appendRates(secondary, to: &data) else { return nil }
        data.append(contentsOf: #","openRouter":"#.utf8)
        guard appendRates(openRouter, to: &data) else { return nil }
        data.append(contentsOf: "}}".utf8)
        return data
    }

    private static func appendRates(_ entries: [String: ModelRates], to data: inout Data) -> Bool {
        data.append(UInt8(ascii: "{"))
        var first = true
        for (key, rates) in entries {
            if !first { data.append(UInt8(ascii: ",")) }
            first = false
            appendString(key, to: &data)
            data.append(UInt8(ascii: ":"))
            guard appendRates(rates, to: &data) else { return false }
        }
        data.append(UInt8(ascii: "}"))
        return true
    }

    private static func appendDoubles(_ entries: [String: Double], to data: inout Data) -> Bool {
        data.append(UInt8(ascii: "{"))
        var first = true
        for (key, value) in entries {
            if !first { data.append(UInt8(ascii: ",")) }
            first = false
            appendString(key, to: &data)
            data.append(UInt8(ascii: ":"))
            guard appendDouble(value, to: &data) else { return false }
        }
        data.append(UInt8(ascii: "}"))
        return true
    }

    private static func appendRates(_ rates: ModelRates, to data: inout Data) -> Bool {
        data.append(contentsOf: #"{"inputPerMillion":"#.utf8)
        guard appendDouble(rates.inputPerMillion, to: &data) else { return false }
        data.append(contentsOf: #","outputPerMillion":"#.utf8)
        guard appendDouble(rates.outputPerMillion, to: &data) else { return false }
        data.append(contentsOf: #","cacheWritePerMillion":"#.utf8)
        guard appendDouble(rates.cacheWritePerMillion, to: &data) else { return false }
        data.append(contentsOf: #","cacheReadPerMillion":"#.utf8)
        guard appendDouble(rates.cacheReadPerMillion, to: &data) else { return false }
        if let write1h = rates.cacheWrite1hPerMillion {
            data.append(contentsOf: #","cacheWrite1hPerMillion":"#.utf8)
            guard appendDouble(write1h, to: &data) else { return false }
        }
        data.append(contentsOf: #","promptRateTiers":["#.utf8)
        for (index, tier) in rates.promptRateTiers.enumerated() {
            if index > 0 { data.append(UInt8(ascii: ",")) }
            data.append(contentsOf: #"{"threshold_prompt_tokens":"#.utf8)
            data.append(contentsOf: String(tier.thresholdPromptTokens).utf8)
            data.append(contentsOf: #","includes_threshold":"#.utf8)
            data.append(contentsOf: (tier.includesThreshold ? "true" : "false").utf8)
            guard appendOptionalDouble(
                tier.inputPerMillion, key: "input_per_million", to: &data
            ) else { return false }
            guard appendOptionalDouble(
                tier.outputPerMillion, key: "output_per_million", to: &data
            ) else { return false }
            guard appendOptionalDouble(
                tier.cacheWritePerMillion, key: "cache_write_per_million", to: &data
            ) else { return false }
            guard appendOptionalDouble(
                tier.cacheReadPerMillion, key: "cache_read_per_million", to: &data
            ) else { return false }
            guard appendOptionalDouble(
                tier.cacheWrite1hPerMillion, key: "cache_write_1h_per_million", to: &data
            ) else { return false }
            data.append(UInt8(ascii: "}"))
        }
        data.append(UInt8(ascii: "]"))
        if let overrides = rates.utcPriceOverrides {
            data.append(contentsOf: #","utcPriceOverrides":["#.utf8)
            for (index, override) in overrides.enumerated() {
                if index > 0 { data.append(UInt8(ascii: ",")) }
                data.append(UInt8(ascii: "{"))
                var first = true
                if let days = override.utcDays {
                    data.append(contentsOf: #""utcDays":["#.utf8)
                    for (dayIndex, day) in days.enumerated() {
                        if dayIndex > 0 { data.append(UInt8(ascii: ",")) }
                        appendString(day, to: &data)
                    }
                    data.append(UInt8(ascii: "]"))
                    first = false
                }
                guard appendConditionalInt(
                    override.utcStartMinute, key: "utcStartMinute", to: &data, first: &first
                ) else { return false }
                guard appendConditionalInt(
                    override.utcEndMinute, key: "utcEndMinute", to: &data, first: &first
                ) else { return false }
                guard appendConditionalDouble(
                    override.inputPerMillion, key: "inputPerMillion", to: &data, first: &first
                ) else { return false }
                guard appendConditionalDouble(
                    override.outputPerMillion, key: "outputPerMillion", to: &data, first: &first
                ) else { return false }
                guard appendConditionalDouble(
                    override.cacheWritePerMillion, key: "cacheWritePerMillion",
                    to: &data, first: &first
                ) else { return false }
                guard appendConditionalDouble(
                    override.cacheReadPerMillion, key: "cacheReadPerMillion",
                    to: &data, first: &first
                ) else { return false }
                guard appendConditionalDouble(
                    override.cacheWrite1hPerMillion, key: "cacheWrite1hPerMillion",
                    to: &data, first: &first
                ) else { return false }
                data.append(UInt8(ascii: "}"))
            }
            data.append(UInt8(ascii: "]"))
        }
        guard appendOptionalDouble(
            rates.inputAbove200kPerMillion, key: "inputAbove200kPerMillion", to: &data
        ) else { return false }
        guard appendOptionalDouble(
            rates.outputAbove200kPerMillion, key: "outputAbove200kPerMillion", to: &data
        ) else { return false }
        guard appendOptionalDouble(
            rates.cacheWriteAbove200kPerMillion, key: "cacheWriteAbove200kPerMillion", to: &data
        ) else { return false }
        guard appendOptionalDouble(
            rates.cacheReadAbove200kPerMillion, key: "cacheReadAbove200kPerMillion", to: &data
        ) else { return false }
        data.append(contentsOf: #","cacheReadIsExplicit":"#.utf8)
        data.append(contentsOf: (rates.cacheReadIsExplicit ? "true" : "false").utf8)
        data.append(contentsOf: #","longContextThresholdTokens":"#.utf8)
        data.append(contentsOf: String(rates.longContextThresholdTokens).utf8)
        data.append(contentsOf: #","fastMultiplier":"#.utf8)
        guard appendDouble(rates.fastMultiplier, to: &data) else { return false }
        data.append(UInt8(ascii: "}"))
        return true
    }

    /// Omitted keys keep the Rust `#[serde(default)]` value, exactly like synthesized `Codable`.
    private static func appendOptionalDouble(
        _ value: Double?,
        key: String,
        to data: inout Data
    ) -> Bool {
        guard let value else { return true }
        data.append(UInt8(ascii: ","))
        appendString(key, to: &data)
        data.append(UInt8(ascii: ":"))
        return appendDouble(value, to: &data)
    }

    private static func appendConditionalDouble(
        _ value: Double?,
        key: String,
        to data: inout Data,
        first: inout Bool
    ) -> Bool {
        guard let value else { return true }
        if !first { data.append(UInt8(ascii: ",")) }
        first = false
        appendString(key, to: &data)
        data.append(UInt8(ascii: ":"))
        return appendDouble(value, to: &data)
    }

    private static func appendConditionalInt(
        _ value: Int?,
        key: String,
        to data: inout Data,
        first: inout Bool
    ) -> Bool {
        guard let value else { return true }
        if !first { data.append(UInt8(ascii: ",")) }
        first = false
        appendString(key, to: &data)
        data.append(UInt8(ascii: ":"))
        data.append(contentsOf: String(value).utf8)
        return true
    }

    private static func appendDouble(_ value: Double, to data: inout Data) -> Bool {
        guard value.isFinite else { return false }
        data.append(contentsOf: String(describing: value).utf8)
        return true
    }

    private static func appendString(_ value: String, to data: inout Data) {
        data.append(UInt8(ascii: "\""))
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"":
                data.append(contentsOf: "\\\"".utf8)
            case "\\":
                data.append(contentsOf: "\\\\".utf8)
            case "\n":
                data.append(contentsOf: "\\n".utf8)
            case "\r":
                data.append(contentsOf: "\\r".utf8)
            case "\t":
                data.append(contentsOf: "\\t".utf8)
            default:
                if scalar.value < 0x20 {
                    data.append(contentsOf: String(format: "\\u%04x", scalar.value).utf8)
                } else {
                    data.append(contentsOf: String(scalar).utf8)
                }
            }
        }
        data.append(UInt8(ascii: "\""))
    }
}
