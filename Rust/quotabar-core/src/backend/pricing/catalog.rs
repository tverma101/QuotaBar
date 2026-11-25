//! One pricing catalogue with ccusage's lookup semantics.
//!
//! Mirror of `Pricing/PricingCatalog.swift`: exact key first, then a boundary-aware fuzzy match
//! that tolerates provider prefixes (`xai/grok-4.3`), separator variants (`.` / `@` / `_` / space
//! vs `-`), and date suffixes (`claude-sonnet-4` -> `claude-sonnet-4-20250514`) without conflating
//! numeric versions (`claude-sonnet-4` never matches `claude-sonnet-4-5`).

use std::collections::HashMap;
use std::sync::OnceLock;

use super::super::accounting::ModelRates;

pub(crate) struct Catalog {
    entries: HashMap<String, ModelRates>,
    fuzzy: OnceLock<Vec<FuzzyEntry>>,
}

/// One entry's precomputed match bytes. `rates` are looked up from `entries` once a match wins,
/// so the index does not duplicate every rate struct.
struct FuzzyEntry {
    key: String,
    key_bytes: Vec<u8>,
    normalized_key_bytes: Vec<u8>,
}

impl Catalog {
    pub fn new(entries: HashMap<String, ModelRates>) -> Self {
        Self {
            entries,
            fuzzy: OnceLock::new(),
        }
    }

    pub fn find_exact(&self, model: &str) -> Option<&ModelRates> {
        self.entries.get(model)
    }

    pub fn entries(&self) -> &HashMap<String, ModelRates> {
        &self.entries
    }

    /// Fuzzy lookup over every entry; prefers the longest matching key (then the lexicographically
    /// smallest for determinism). Only called after exact lookups miss.
    pub fn find_fuzzy(&self, model: &str) -> Option<(&str, &ModelRates)> {
        let entries = self.fuzzy.get_or_init(|| build_fuzzy_index(&self.entries));
        if entries.is_empty() {
            return None;
        }
        let model_bytes = model.as_bytes();
        let normalized_model = normalized_key(model);
        let normalized_model_bytes = normalized_model.as_bytes();
        let mut best: Option<&FuzzyEntry> = None;
        for entry in entries {
            if !index_key_matches(entry, model_bytes, normalized_model_bytes) {
                continue;
            }
            let replace = match best {
                None => true,
                Some(current) => {
                    let entry_len = entry.key.chars().count();
                    let current_len = current.key.chars().count();
                    entry_len > current_len || (entry_len == current_len && entry.key < current.key)
                }
            };
            if replace {
                best = Some(entry);
            }
        }
        best.and_then(|entry| {
            self.entries
                .get_key_value(&entry.key)
                .map(|(key, rates)| (key.as_str(), rates))
        })
    }
}

fn build_fuzzy_index(entries: &HashMap<String, ModelRates>) -> Vec<FuzzyEntry> {
    entries
        .keys()
        .map(|key| FuzzyEntry {
            key: key.clone(),
            key_bytes: key.as_bytes().to_vec(),
            normalized_key_bytes: normalized_key(key).into_bytes(),
        })
        .collect()
}

/// Normalizes separator variants: `.`, `@`, `_`, and literal spaces become `-`
/// (`grok-4.3` -> `grok-4-3`, `space bunny` -> `space-bunny`).
pub(crate) fn normalized_key(value: &str) -> String {
    if !value
        .bytes()
        .any(|byte| matches!(byte, b'.' | b'@' | b' ' | b'_'))
    {
        return value.to_string();
    }
    value.replace(['.', '@', ' ', '_'], "-")
}

/// A candidate key matches when either string contains the other at word boundaries, on the raw
/// or separator-normalized forms.
fn index_key_matches(
    entry: &FuzzyEntry,
    model_bytes: &[u8],
    normalized_model_bytes: &[u8],
) -> bool {
    if contains_key(model_bytes, &entry.key_bytes) || contains_key(&entry.key_bytes, model_bytes) {
        return true;
    }
    contains_key(normalized_model_bytes, &entry.normalized_key_bytes)
        || contains_key(&entry.normalized_key_bytes, normalized_model_bytes)
}

/// Finds `key` inside `value` only where the surrounding characters are non-alphanumeric
/// boundaries, and the suffix does not continue a numeric version.
fn contains_key(value: &[u8], key: &[u8]) -> bool {
    if key.is_empty() || key.len() > value.len() {
        return false;
    }
    for start in 0..=(value.len() - key.len()) {
        if &value[start..start + key.len()] != key {
            continue;
        }
        let before_ok = start == 0 || !value[start - 1].is_ascii_alphanumeric();
        if !before_ok {
            continue;
        }
        let suffix = &value[start + key.len()..];
        if suffix_allows_match(key, suffix) {
            return true;
        }
    }
    false
}

fn suffix_allows_match(key: &[u8], suffix: &[u8]) -> bool {
    let Some(separator) = suffix.first() else {
        return true;
    };
    if separator.is_ascii_alphanumeric() {
        return false;
    }
    !suffix_starts_with_numeric_model_version(key, suffix)
}

/// Rejects matches where the suffix looks like a version continuation of a numeric key
/// (`claude-sonnet-4` + `-5-...`), while allowing 8-digit date suffixes (`-20250514`).
fn suffix_starts_with_numeric_model_version(key: &[u8], suffix: &[u8]) -> bool {
    const DATE_SUFFIX_DIGITS: usize = 8;
    let Some(last) = key.last() else {
        return false;
    };
    if !last.is_ascii_digit() {
        return false;
    }
    let Some(separator) = suffix.first() else {
        return false;
    };
    if *separator != b'-' && *separator != b'.' {
        return false;
    }
    let rest = &suffix[1..];
    let digit_count = rest.iter().take_while(|byte| byte.is_ascii_digit()).count();
    if digit_count == 0 {
        return false;
    }
    let after_digits = rest.get(digit_count);
    let is_date_suffix = digit_count == DATE_SUFFIX_DIGITS
        && after_digits.map_or(true, |byte| !byte.is_ascii_alphanumeric());
    !is_date_suffix
}

#[cfg(test)]
mod tests {
    use super::*;

    fn catalog(keys: &[&str]) -> Catalog {
        let entries = keys
            .iter()
            .map(|key| (key.to_string(), ModelRates::default()))
            .collect();
        Catalog::new(entries)
    }

    #[test]
    fn normalizes_separator_variants() {
        assert_eq!(normalized_key("grok-4.3"), "grok-4-3");
        assert_eq!(normalized_key("space bunny"), "space-bunny");
        assert_eq!(normalized_key("muse_spark"), "muse-spark");
        assert_eq!(normalized_key("plain-model"), "plain-model");
    }

    #[test]
    fn fuzzy_tolerates_prefixes_and_dates_but_not_versions() {
        let catalog = catalog(&[
            "xai/grok-4.3",
            "claude-sonnet-4",
            "claude-sonnet-4-20250514",
        ]);
        assert_eq!(catalog.find_fuzzy("grok-4.3").unwrap().0, "xai/grok-4.3");
        assert_eq!(
            catalog.find_fuzzy("claude-sonnet-4-preview").unwrap().0,
            "claude-sonnet-4"
        );
        assert_eq!(catalog.find_fuzzy("claude-sonnet-4-5"), None);
        assert_eq!(catalog.find_fuzzy("unrelated-model"), None);
    }

    #[test]
    fn fuzzy_prefers_the_longest_key_then_lexicographic() {
        let catalog = catalog(&["gpt-5", "openai/gpt-5", "gpt-5-mini"]);
        assert_eq!(
            catalog.find_fuzzy("gpt-5-mini-preview").unwrap().0,
            "gpt-5-mini"
        );
    }
}
