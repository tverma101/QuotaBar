//! One pricing source as a flat key -> rates table with ccusage's lookup semantics (Swift
//! `PricingCatalog.swift`): exact key first, then a boundary-aware fuzzy match that tolerates provider
//! prefixes (`xai/grok-4.3`), separator variants (`.` `@` `_` space vs `-`) and 8-digit date suffixes
//! (`claude-sonnet-4` -> `claude-sonnet-4-20250514`) without conflating numeric versions
//! (`claude-sonnet-4` never matches `claude-sonnet-4-5`).

use super::rates::ModelRates;
use std::borrow::Cow;
use std::collections::{HashMap, HashSet};
use std::sync::{Arc, RwLock};

#[derive(Default)]
pub struct PricingCatalog {
    pub entries: HashMap<String, ModelRates>,
    /// When this snapshot was retrieved or generated; resolves bundle/cache conflicts.
    pub retrieved_at: Option<String>,
    /// Exact ids the source deliberately omits (conflicting reseller rates). These tombstones stop an
    /// older bundled or cached snapshot from restoring an arbitrary rate.
    pub retired_keys: HashSet<String>,
    /// Whether `retired_keys` is a complete snapshot (even when empty).
    pub retired_keys_are_authoritative: bool,
    /// Built on the first fuzzy lookup; dropped by `clear_fuzzy_index` to release memory.
    fuzzy: RwLock<Option<Arc<Vec<FuzzyEntry>>>>,
}

struct FuzzyEntry {
    key: String,
    normalized: String,
}

impl Clone for PricingCatalog {
    fn clone(&self) -> Self {
        PricingCatalog::new(
            self.entries.clone(),
            self.retrieved_at.clone(),
            self.retired_keys.clone(),
            self.retired_keys_are_authoritative,
        )
    }
}

impl PartialEq for PricingCatalog {
    fn eq(&self, other: &Self) -> bool {
        self.entries == other.entries
            && self.retrieved_at == other.retrieved_at
            && self.retired_keys == other.retired_keys
            && self.retired_keys_are_authoritative == other.retired_keys_are_authoritative
    }
}

impl std::fmt::Debug for PricingCatalog {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PricingCatalog")
            .field("entries", &self.entries.len())
            .field("retrieved_at", &self.retrieved_at)
            .field("retired_keys", &self.retired_keys.len())
            .finish()
    }
}

impl PricingCatalog {
    pub fn new(
        entries: HashMap<String, ModelRates>,
        retrieved_at: Option<String>,
        retired_keys: HashSet<String>,
        retired_keys_are_authoritative: bool,
    ) -> PricingCatalog {
        PricingCatalog {
            entries,
            retrieved_at,
            retired_keys,
            retired_keys_are_authoritative,
            fuzzy: RwLock::new(None),
        }
    }

    pub fn from_entries(entries: HashMap<String, ModelRates>) -> PricingCatalog {
        PricingCatalog::new(entries, None, HashSet::new(), false)
    }

    pub fn find_exact(&self, model: &str) -> Option<(&str, &ModelRates)> {
        self.entries
            .get_key_value(model)
            .map(|(k, v)| (k.as_str(), v))
    }

    /// Fuzzy lookup over every entry: the longest matching key wins, then the lexicographically
    /// smallest. Only called after exact lookups miss.
    pub fn find_fuzzy(&self, model: &str) -> Option<(&str, &ModelRates)> {
        let index = self.fuzzy_index();
        let normalized_model = normalized_key(model);
        let (model_bytes, normalized_bytes) = (model.as_bytes(), normalized_model.as_bytes());
        let mut best: Option<&FuzzyEntry> = None;
        for entry in index.iter() {
            let key = entry.key.as_bytes();
            let normalized = entry.normalized.as_bytes();
            let hit = contains_key(model_bytes, key)
                || contains_key(key, model_bytes)
                || contains_key(normalized_bytes, normalized)
                || contains_key(normalized, normalized_bytes);
            if !hit {
                continue;
            }
            best = match best {
                Some(current) if !is_better_key(&entry.key, &current.key) => Some(current),
                _ => Some(entry),
            };
        }
        let key = &best?.key;
        self.entries
            .get_key_value(key.as_str())
            .map(|(k, v)| (k.as_str(), v))
    }

    pub fn clear_fuzzy_index(&self) {
        *self.fuzzy.write().unwrap_or_else(|e| e.into_inner()) = None;
    }

    fn fuzzy_index(&self) -> Arc<Vec<FuzzyEntry>> {
        if let Some(index) = self
            .fuzzy
            .read()
            .unwrap_or_else(|e| e.into_inner())
            .as_ref()
        {
            return index.clone();
        }
        let mut slot = self.fuzzy.write().unwrap_or_else(|e| e.into_inner());
        slot.get_or_insert_with(|| {
            Arc::new(
                self.entries
                    .keys()
                    .map(|key| FuzzyEntry {
                        key: key.clone(),
                        normalized: normalized_key(key).into_owned(),
                    })
                    .collect(),
            )
        })
        .clone()
    }

    /// Merge `other` on top of this catalog; `other` wins per key. Tombstones from either side apply,
    /// except that an authoritative `other` revives keys it publishes again.
    pub fn merging(&self, other: &PricingCatalog) -> PricingCatalog {
        let mut merged = self.entries.clone();
        merged.extend(other.entries.iter().map(|(k, v)| (k.clone(), v.clone())));
        let mut retired: HashSet<String> = self
            .retired_keys
            .union(&other.retired_keys)
            .cloned()
            .collect();
        if other.retired_keys_are_authoritative {
            for key in other.entries.keys() {
                if !other.retired_keys.contains(key) {
                    retired.remove(key);
                }
            }
        }
        for key in &retired {
            merged.remove(key);
        }
        PricingCatalog::new(
            merged,
            other
                .retrieved_at
                .clone()
                .or_else(|| self.retrieved_at.clone()),
            retired,
            self.retired_keys_are_authoritative || other.retired_keys_are_authoritative,
        )
    }
}

/// Swift `String.count` ordering for keys: more characters wins, then the smaller string.
fn is_better_key(candidate: &str, current: &str) -> bool {
    let (a, b) = (candidate.chars().count(), current.chars().count());
    a > b || (a == b && candidate < current)
}

/// `.`, `@`, `_` and spaces become `-` (`grok-4.3` -> `grok-4-3`, `space bunny` -> `space-bunny`).
pub fn normalized_key(value: &str) -> Cow<'_, str> {
    if !value
        .bytes()
        .any(|b| matches!(b, b'.' | b'@' | b' ' | b'_'))
    {
        return Cow::Borrowed(value);
    }
    Cow::Owned(
        value
            .chars()
            .map(|c| {
                if matches!(c, '.' | '@' | ' ' | '_') {
                    '-'
                } else {
                    c
                }
            })
            .collect(),
    )
}

/// `key` occurs in `value` at a non-alphanumeric boundary, and the suffix does not continue a
/// numeric version.
pub fn contains_key(value: &[u8], key: &[u8]) -> bool {
    if key.is_empty() || key.len() > value.len() {
        return false;
    }
    for start in 0..=(value.len() - key.len()) {
        if &value[start..start + key.len()] != key {
            continue;
        }
        if start > 0 && value[start - 1].is_ascii_alphanumeric() {
            continue;
        }
        if suffix_allows_match(key, &value[start + key.len()..]) {
            return true;
        }
    }
    false
}

fn suffix_allows_match(key: &[u8], suffix: &[u8]) -> bool {
    match suffix.first() {
        None => true,
        Some(separator) if separator.is_ascii_alphanumeric() => false,
        Some(_) => !suffix_starts_with_numeric_model_version(key, suffix),
    }
}

/// `claude-sonnet-4` + `-5-…` continues a version; `-20250514` (exactly 8 digits) is a date.
fn suffix_starts_with_numeric_model_version(key: &[u8], suffix: &[u8]) -> bool {
    if !key.last().is_some_and(u8::is_ascii_digit) {
        return false;
    }
    if !matches!(suffix.first(), Some(b'-' | b'.')) {
        return false;
    }
    let rest = &suffix[1..];
    let digits = rest.iter().take_while(|b| b.is_ascii_digit()).count();
    if digits == 0 {
        return false;
    }
    let after = rest.get(digits);
    let is_date = digits == 8 && after.map_or(true, |b| !b.is_ascii_alphanumeric());
    !is_date
}

#[cfg(test)]
mod tests {
    use super::*;

    fn catalog(keys: &[&str]) -> PricingCatalog {
        PricingCatalog::from_entries(
            keys.iter()
                .map(|k| (k.to_string(), ModelRates::new(1.0, 1.0, 1.0, 1.0)))
                .collect(),
        )
    }

    #[test]
    fn fuzzy_respects_version_and_date_boundaries() {
        let c = catalog(&[
            "claude-sonnet-4-20250514",
            "claude-sonnet-4-5",
            "grok-4-3",
            "gpt-5",
        ]);
        assert_eq!(
            c.find_fuzzy("claude-sonnet-4").unwrap().0,
            "claude-sonnet-4-20250514"
        );
        assert_eq!(c.find_fuzzy("xai/grok-4.3").unwrap().0, "grok-4-3");
        assert!(
            c.find_fuzzy("gpt-5-1").is_none(),
            "numeric continuation must not match"
        );
        assert_eq!(c.find_fuzzy("openai/gpt-5").unwrap().0, "gpt-5");
        assert!(c.find_fuzzy("gpt-55").is_none());
    }

    #[test]
    fn fuzzy_prefers_longest_then_smallest_key() {
        let c = catalog(&["gpt-5", "openai/gpt-5", "azure/gpt-5"]);
        assert_eq!(c.find_fuzzy("x/openai/gpt-5").unwrap().0, "openai/gpt-5");
        let c = catalog(&["b/gpt-5", "a/gpt-5"]);
        assert_eq!(c.find_fuzzy("gpt-5").unwrap().0, "a/gpt-5");
    }

    #[test]
    fn normalization() {
        assert_eq!(normalized_key("space bunny_v1.2@x"), "space-bunny-v1-2-x");
        assert!(matches!(normalized_key("plain"), Cow::Borrowed(_)));
    }

    #[test]
    fn merge_tombstones() {
        let mut base = catalog(&["a", "b", "c"]);
        base.retired_keys_are_authoritative = false;
        let mut newer = catalog(&["a"]);
        newer.retired_keys = ["b".to_string()].into();
        newer.retired_keys_are_authoritative = true;
        let merged = base.merging(&newer);
        assert!(merged.entries.contains_key("a") && merged.entries.contains_key("c"));
        assert!(!merged.entries.contains_key("b"));
        // An authoritative feed that publishes a key again revives it.
        let mut revived = catalog(&["b"]);
        revived.retired_keys_are_authoritative = true;
        assert!(merged.merging(&revived).entries.contains_key("b"));
    }
}
