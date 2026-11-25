//! Replay deduplication (Swift `ClaudeEntryDeduplication`, `dedup`, `shouldReplace`).

use super::entry::ClaudeEntry;
use std::collections::HashMap;
use std::sync::Arc;

#[derive(Clone, PartialEq, Eq, Hash)]
struct ExactKey {
    message_id: Arc<str>,
    request_id: Option<Arc<str>>,
}

/// Drops replayed usage lines, keeping ccusage's preferences. Entries are keyed by
/// `(message.id, requestId)`; a second index on `message.id` alone catches sidechain logs that replay
/// a parent message under a new request id. On a collision the existing entry is replaced only when
/// the candidate wins [`should_replace`]. Entries without a message id are always kept.
#[derive(Default)]
pub struct ClaudeEntryDeduplication {
    entries: Vec<ClaudeEntry>,
    exact_index: HashMap<ExactKey, usize>,
    message_index: HashMap<Arc<str>, Vec<usize>>,
}

impl ClaudeEntryDeduplication {
    pub fn entries(&self) -> &[ClaudeEntry] {
        &self.entries
    }

    pub fn into_entries(self) -> Vec<ClaudeEntry> {
        self.entries
    }

    pub fn append(&mut self, entry: ClaudeEntry) {
        let Some(message_id) = entry.message_id.clone() else {
            self.entries.push(entry);
            return;
        };
        let key = ExactKey { message_id: message_id.clone(), request_id: entry.request_id.clone() };
        let collision = self.exact_index.get(&key).copied().or_else(|| {
            self.message_index
                .get(&message_id)?
                .iter()
                .copied()
                .find(|&index| entry.is_sidechain || self.entries[index].is_sidechain)
        });
        if let Some(index) = collision {
            if should_replace(&entry, &self.entries[index]) {
                let old = &self.entries[index];
                if let Some(old_id) = &old.message_id {
                    self.exact_index.remove(&ExactKey { message_id: old_id.clone(), request_id: old.request_id.clone() });
                }
                self.entries[index] = entry;
                self.exact_index.insert(key, index);
            }
            return;
        }
        let index = self.entries.len();
        self.entries.push(entry);
        self.exact_index.insert(key, index);
        self.message_index.entry(message_id).or_default().push(index);
    }
}

pub fn dedup(entries: impl IntoIterator<Item = ClaudeEntry>) -> Vec<ClaudeEntry> {
    let mut deduplication = ClaudeEntryDeduplication::default();
    for entry in entries {
        deduplication.append(entry);
    }
    deduplication.into_entries()
}

/// Preference order on a duplicate: the non-sidechain (parent) entry, then the larger token total,
/// then the entry that carries a `speed` field (richer log shape).
pub fn should_replace(candidate: &ClaudeEntry, existing: &ClaudeEntry) -> bool {
    if candidate.is_sidechain != existing.is_sidechain {
        return existing.is_sidechain;
    }
    let (candidate_total, existing_total) = (candidate.tokens.total_tokens(), existing.tokens.total_tokens());
    if candidate_total != existing_total {
        return candidate_total > existing_total;
    }
    candidate.has_speed && !existing.has_speed
}
