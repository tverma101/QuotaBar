import Foundation
import CQuotabarCore

/// Bridge to the quotabar-core Rust implementation of the compact pricing catalog decoder.
///
/// The snapshot format is identical in both paths: Rust parses the same bytes with serde_json and
/// projects the result through the C ABI; Swift reassembles the Swift `ModelRates` values. Rust
/// returns nil for input shapes it doesn't handle (e.g. tier count > 4, count limits exceeded) — the
/// caller then falls back to `PricingCatalogCodecs.catalogFromCompact`, the existing Swift parser.
enum CompactCatalogRustParser {
    static func parse(_ data: Data) -> PricingCatalog? {
        data.withUnsafeBytes { buffer in
            guard let raw = qb_pricing_compact_catalog_parse(
                buffer.baseAddress?.assumingMemoryBound(to: UInt8.self), buffer.count
            ) else {
                return nil
            }
            defer { qb_pricing_compact_catalog_destroy(raw) }

            let entryCount = Int(qb_pricing_compact_catalog_entry_count(raw))
            let tierCount = Int(qb_pricing_compact_catalog_tier_count(raw))

            var stringsPointer: UnsafePointer<UInt8>?
            var stringsLength: UInt32 = 0
            stringsPointer = qb_pricing_compact_catalog_strings(raw, &stringsLength)

            func string(at offset: UInt32, length: UInt32) -> String? {
                guard offset != QB_NIL_STRING_OFFSET, let stringsPointer else { return nil }
                guard UInt64(offset) + UInt64(length) <= UInt64(stringsLength) else { return nil }
                return String(
                    decoding: UnsafeBufferPointer(
                        start: stringsPointer.advanced(by: Int(offset)),
                        count: Int(length)
                    ),
                    as: UTF8.self
                )
            }

            let entriesPointer = qb_pricing_compact_catalog_entries(raw)
            let tiersPointer = qb_pricing_compact_catalog_tiers(raw)

            var entries: [String: ModelRates] = [:]
            entries.reserveCapacity(entryCount)
            for index in 0..<entryCount {
                let ffi = entriesPointer![index]
                guard let key = string(at: ffi.key_offset, length: ffi.key_length) else { return nil }

                let tiers: [PromptRateTier] = (0..<Int(ffi.tier_count)).map { tierIndex in
                    let t = tiersPointer![Int(ffi.tier_offset) + tierIndex]
                    return PromptRateTier(
                        thresholdPromptTokens: Int(t.threshold_prompt_tokens),
                        includesThreshold: t.includes_threshold != 0,
                        inputPerMillion: t.input_per_million.isNaN ? nil : t.input_per_million,
                        outputPerMillion: t.output_per_million.isNaN ? nil : t.output_per_million,
                        cacheWritePerMillion: t.cache_write_per_million.isNaN ? nil : t.cache_write_per_million,
                        cacheReadPerMillion: t.cache_read_per_million.isNaN ? nil : t.cache_read_per_million,
                        cacheWrite1hPerMillion: t.cache_write_1h_per_million.isNaN ? nil : t.cache_write_1h_per_million
                    )
                }

                entries[key] = ModelRates(
                    inputPerMillion: ffi.input_per_million,
                    outputPerMillion: ffi.output_per_million,
                    cacheWritePerMillion: ffi.cache_write_per_million,
                    cacheReadPerMillion: ffi.cache_read_per_million,
                    cacheWrite1hPerMillion: ffi.cache_write_1h_per_million.isNaN ? nil : ffi.cache_write_1h_per_million,
                    promptRateTiers: tiers,
                    utcPriceOverrides: nil,
                    inputAbove200kPerMillion: ffi.input_above_200k_per_million.isNaN ? nil : ffi.input_above_200k_per_million,
                    outputAbove200kPerMillion: ffi.output_above_200k_per_million.isNaN ? nil : ffi.output_above_200k_per_million,
                    cacheWriteAbove200kPerMillion: ffi.cache_write_above_200k_per_million.isNaN ? nil : ffi.cache_write_above_200k_per_million,
                    cacheReadAbove200kPerMillion: ffi.cache_read_above_200k_per_million.isNaN ? nil : ffi.cache_read_above_200k_per_million,
                    cacheReadIsExplicit: ffi.cache_read_is_explicit != 0,
                    fastMultiplier: ffi.fast_multiplier
                )
            }

            let retrievedAt = string(at: qb_pricing_compact_catalog_retrieved_at_offset(raw),
                                     length: qb_pricing_compact_catalog_retrieved_at_length(raw))

            // Retired keys are a contiguous block of length-prefixed UTF-8 strings:
            // [u32le length][bytes]*, count taken from qb_pricing_compact_catalog_retired_count.
            let retiredCount = Int(qb_pricing_compact_catalog_retired_count(raw))
            let retiredOffset = Int(qb_pricing_compact_catalog_retired_offset(raw))
            var retiredSet: Set<String> = []
            if retiredCount > 0 {
                guard let base = qb_pricing_compact_catalog_strings(raw, nil) else { return nil }
                var cursor = retiredOffset
                for _ in 0..<retiredCount {
                    guard cursor >= 0, cursor + 4 <= stringsLength else { return nil }
                    let baseAddr = base.advanced(by: cursor)
                    let b0 = UInt32(baseAddr.pointee)
                    let b1 = UInt32(baseAddr[1])
                    let b2 = UInt32(baseAddr[2])
                    let b3 = UInt32(baseAddr[3])
                    let length = Int(b0 | (b1 << 8) | (b2 << 16) | (b3 << 24))
                    let keyStart = cursor + 4
                    guard keyStart + length <= stringsLength else { return nil }
                    retiredSet.insert(String(decoding: UnsafeBufferPointer(start: base.advanced(by: keyStart), count: length), as: UTF8.self))
                    cursor = keyStart + length
                }
            }

            return PricingCatalog(
                entries: entries,
                retrievedAt: retrievedAt,
                retiredKeys: retiredSet,
                retiredKeysAreAuthoritative: retiredCount > 0
            )
        }
    }
}
