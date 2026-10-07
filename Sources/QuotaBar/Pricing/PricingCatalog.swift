import Foundation

/// One pricing source (LiteLLM or models.dev) as a flat model-key -> rates table with ccusage's
/// lookup semantics: exact key first, then a boundary-aware fuzzy match that tolerates provider
/// prefixes (`xai/grok-4.3`), separator variants (`.` / `@` vs `-`), and date suffixes
/// (`claude-sonnet-4` -> `claude-sonnet-4-20250514`) without conflating numeric versions
/// (`claude-sonnet-4` never matches `claude-sonnet-4-5`).
struct PricingCatalog: Sendable, Equatable {
    var entries: [String: ModelRates]
    /// When the source published its data (informational, for logs).
    var retrievedAt: String?
    /// Per-entry match corpus precomputed at build: raw key bytes plus separator-normalized key
    /// bytes. The fuzzy scan used to materialize both arrays per entry per miss (~20k allocations
    /// for one miss over the LiteLLM snapshot), and misses repeat across distinct gateway-tagged
    /// slug spellings within a refresh.
    var fuzzyIndex: [FuzzyIndexEntry]

    /// One catalog entry's precomputed match bytes. `rates` is carried so a match needs no
    /// dictionary hop.
    struct FuzzyIndexEntry: Sendable {
        var key: String
        var keyBytes: [UInt8]
        var normalizedKeyBytes: [UInt8]
        var rates: ModelRates
    }

    init(entries: [String: ModelRates] = [:], retrievedAt: String? = nil) {
        self.entries = entries
        self.retrievedAt = retrievedAt
        self.fuzzyIndex = Self.buildFuzzyIndex(entries: entries)
    }

    /// Derived from `entries` alone, so equality ignores it (two catalogs that price identically
    /// stay equal regardless of the byte-array duplication).
    static func == (lhs: PricingCatalog, rhs: PricingCatalog) -> Bool {
        lhs.entries == rhs.entries && lhs.retrievedAt == rhs.retrievedAt
    }

    private static func buildFuzzyIndex(entries: [String: ModelRates]) -> [FuzzyIndexEntry] {
        entries.map { key, rates in
            FuzzyIndexEntry(
                key: key,
                keyBytes: Array(key.utf8),
                normalizedKeyBytes: Array(normalizedKey(key).utf8),
                rates: rates
            )
        }
    }

    func findExact(_ model: String) -> (key: String, rates: ModelRates)? {
        entries[model].map { (model, $0) }
    }

    /// Fuzzy lookup over every entry; prefers the longest matching key (then the lexicographically
    /// smallest for determinism). Only called after exact lookups miss.
    func findFuzzy(_ model: String) -> (key: String, rates: ModelRates)? {
        let modelBytes = Array(model.utf8)
        let normalizedModelBytes = Array(Self.normalizedKey(model).utf8)
        var best: (key: String, rates: ModelRates)?
        for entry in fuzzyIndex {
            guard Self.indexKeyMatches(
                entry: entry,
                modelBytes: modelBytes,
                normalizedModelBytes: normalizedModelBytes
            ) else { continue }
            if let current = best {
                if entry.key.count > current.key.count || (entry.key.count == current.key.count && entry.key < current.key) {
                    best = (entry.key, entry.rates)
                }
            } else {
                best = (entry.key, entry.rates)
            }
        }
        return best
    }

    /// Merge another catalog on top of this one; `other`'s entries win per key.
    func merging(_ other: PricingCatalog) -> PricingCatalog {
        var merged = entries
        merged.merge(other.entries) { _, new in new }
        return PricingCatalog(entries: merged, retrievedAt: other.retrievedAt ?? retrievedAt)
    }
}

// MARK: - Fuzzy matching (port of ccusage pricing.rs)

extension PricingCatalog {
    /// Normalizes separator variants: `.`, `@`, `_`, and literal spaces become `-`
    /// (`grok-4.3` -> `grok-4-3`, `space bunny` -> `space-bunny`). Public catalogues hyphenate
    /// model ids, while provider logs have been seen to spell the same slug with a space
    /// (stealth/codename models) or an underscore — matching those to a catalogue entry is exactly
    /// the automatic-discovery path.
    static func normalizedKey(_ value: String) -> String {
        guard value.contains(".") || value.contains("@")
                || value.contains(" ") || value.contains("_") else { return value }
        return value.replacingOccurrences(of: ".", with: "-")
            .replacingOccurrences(of: "@", with: "-")
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "_", with: "-")
    }

    /// A candidate key matches when either string contains the other at word boundaries, on the raw
    /// or separator-normalized forms. Byte arrays are supplied by the caller: the fuzzy scan runs
    /// this per catalog entry, so re-materializing UTF-8 views per comparison would dominate.
    static func indexKeyMatches(
        entry: FuzzyIndexEntry,
        modelBytes: [UInt8],
        normalizedModelBytes: [UInt8]
    ) -> Bool {
        if containsKey(modelBytes, key: entry.keyBytes)
            || containsKey(entry.keyBytes, key: modelBytes) {
            return true
        }
        return containsKey(normalizedModelBytes, key: entry.normalizedKeyBytes)
            || containsKey(entry.normalizedKeyBytes, key: normalizedModelBytes)
    }

    /// Finds `key` inside `value` only where the surrounding characters are non-alphanumeric
    /// boundaries, and the suffix does not continue a numeric version.
    static func containsKey(_ valueBytes: [UInt8], key keyBytes: [UInt8]) -> Bool {
        guard !keyBytes.isEmpty else { return false }
        guard keyBytes.count <= valueBytes.count else { return false }
        for start in 0...(valueBytes.count - keyBytes.count) {
            guard valueBytes[start..<(start + keyBytes.count)].elementsEqual(keyBytes) else { continue }
            let beforeOK = start == 0 || !valueBytes[start - 1].isASCIIAlphanumeric
            guard beforeOK else { continue }
            let suffix = Array(valueBytes[(start + keyBytes.count)...])
            if suffixAllowsMatch(key: keyBytes, suffix: suffix) {
                return true
            }
        }
        return false
    }

    private static func suffixAllowsMatch(key: [UInt8], suffix: [UInt8]) -> Bool {
        guard let separator = suffix.first else { return true }
        if separator.isASCIIAlphanumeric { return false }
        return !suffixStartsWithNumericModelVersion(key: key, suffix: suffix)
    }

    /// Rejects matches where the suffix looks like a version continuation of a numeric key
    /// (`claude-sonnet-4` + `-5-...`), while allowing 8-digit date suffixes (`-20250514`).
    private static func suffixStartsWithNumericModelVersion(key: [UInt8], suffix: [UInt8]) -> Bool {
        let dateSuffixDigits = 8
        guard let last = key.last, last.isASCIIDigit else { return false }
        guard let separator = suffix.first, separator == UInt8(ascii: "-") || separator == UInt8(ascii: ".") else {
            return false
        }
        let rest = suffix.dropFirst()
        let digitCount = rest.prefix(while: \.isASCIIDigit).count
        guard digitCount > 0 else { return false }
        let afterDigits = rest.dropFirst(digitCount).first
        let isDateSuffix = digitCount == dateSuffixDigits && (afterDigits.map { !$0.isASCIIAlphanumeric } ?? true)
        return !isDateSuffix
    }
}

private extension UInt8 {
    var isASCIIDigit: Bool { self >= UInt8(ascii: "0") && self <= UInt8(ascii: "9") }
    var isASCIIAlphanumeric: Bool {
        isASCIIDigit
            || (self >= UInt8(ascii: "a") && self <= UInt8(ascii: "z"))
            || (self >= UInt8(ascii: "A") && self <= UInt8(ascii: "Z"))
    }
}
