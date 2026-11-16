import Foundation
import CQuotabarCore

/// Bridge to the quotabar-core Rust implementation of the compact pricing catalog decoder.
///
/// The snapshot format is identical in both paths: Rust parses the same bytes with serde_json and
/// projects the result through the C ABI; Swift reassembles the Swift `ModelRates` values. This is
/// the *fallback*: Swift's `catalogFromCompact` runs Foundation's `JSONDecoder` first (byte-exact
/// with the snapshots Foundation itself wrote), and only calls this when Foundation cannot handle
/// the input at all. Returns nil on any anomaly; `catalogFromCompact` then throws.
enum CompactCatalogRustParser {
    static func parse(_ data: Data) -> PricingCatalog? {
        data.withUnsafeBytes { buffer in
            // Swift and Rust disagree on bytes; there is no useful work to do on empty input.
            guard let raw = qb_pricing_compact_catalog_parse(
                buffer.baseAddress?.assumingMemoryBound(to: UInt8.self), buffer.count
            ) else {
                return nil
            }
            defer { qb_pricing_compact_catalog_destroy(raw) }

            let entryCount = Int(qb_pricing_compact_catalog_entry_count(raw))
            let tierCount = Int(qb_pricing_compact_catalog_tier_count(raw))

            var stringsLength: UInt32 = 0
            guard let stringsPointer = qb_pricing_compact_catalog_strings(raw, &stringsLength) else {
                return entryCount == 0 ? PricingCatalog(
                    entries: [:],
                    retrievedAt: nil,
                    retiredKeys: [],
                    retiredKeysAreAuthoritative: false
                ) : nil
            }

            func string(at offset: UInt32, length: UInt32) -> String? {
                guard offset != QB_NIL_STRING_OFFSET else { return nil }
                guard UInt64(offset) + UInt64(length) <= UInt64(stringsLength) else { return nil }
                return String(
                    decoding: UnsafeBufferPointer(
                        start: stringsPointer.advanced(by: Int(offset)),
                        count: Int(length)
                    ),
                    as: UTF8.self
                )
            }

            guard let entriesPointer = qb_pricing_compact_catalog_entries(raw),
                  let tiersPointer = qb_pricing_compact_catalog_tiers(raw) else { return nil }

            var entries: [String: ModelRates] = [:]
            entries.reserveCapacity(entryCount)
            for index in 0..<entryCount {
                let ffi = entriesPointer[index]
                guard let key = string(at: ffi.key_offset, length: ffi.key_length) else { return nil }

                // Rust guarantees tier_offset + tier_count <= tiers.len(), but Swift never trusts
                // the count blindly: a corrupt handle must degrade to the fallback, not read past
                // the end of the tier array.
                guard Int(ffi.tier_offset) + Int(ffi.tier_count) <= tierCount else { return nil }

                let tiers: [PromptRateTier] = (0..<Int(ffi.tier_count)).map { tierIndex in
                    let t = tiersPointer[Int(ffi.tier_offset) + tierIndex]
                    // PromptRateTier stores Int; an out-of-range u64 threshold is not representable.
                    let threshold = Int(exactly: t.threshold_prompt_tokens) ?? -1
                    return PromptRateTier(
                        thresholdPromptTokens: threshold,
                        includesThreshold: t.includes_threshold != 0,
                        inputPerMillion: t.input_per_million.isNaN ? nil : t.input_per_million,
                        outputPerMillion: t.output_per_million.isNaN ? nil : t.output_per_million,
                        cacheWritePerMillion: t.cache_write_per_million.isNaN ? nil : t.cache_write_per_million,
                        cacheReadPerMillion: t.cache_read_per_million.isNaN ? nil : t.cache_read_per_million,
                        cacheWrite1hPerMillion: t.cache_write_1h_per_million.isNaN ? nil : t.cache_write_1h_per_million
                    )
                }
                if tiers.contains(where: { $0.thresholdPromptTokens < 0 }) { return nil }

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
                var cursor = retiredOffset
                for _ in 0..<retiredCount {
                    guard cursor >= 0, cursor + 4 <= Int(stringsLength) else { return nil }
                    let baseAddr = stringsPointer.advanced(by: cursor)
                    let b0 = UInt32(baseAddr.pointee)
                    let b1 = UInt32(baseAddr[1])
                    let b2 = UInt32(baseAddr[2])
                    let b3 = UInt32(baseAddr[3])
                    let length = Int(b0 | (b1 << 8) | (b2 << 16) | (b3 << 24))
                    let keyStart = cursor + 4
                    guard keyStart + length <= Int(stringsLength) else { return nil }
                    retiredSet.insert(String(decoding: UnsafeBufferPointer(start: stringsPointer.advanced(by: keyStart), count: length), as: UTF8.self))
                    cursor = keyStart + length
                }
            }

            return PricingCatalog(
                entries: entries,
                retrievedAt: retrievedAt,
                retiredKeys: retiredSet,
                retiredKeysAreAuthoritative: qb_pricing_compact_catalog_retired_present(raw) != 0
            )
        }
    }
}
