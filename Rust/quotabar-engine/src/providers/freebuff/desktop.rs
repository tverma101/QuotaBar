//! Incremental reads of Freebuff Desktop project databases (`FreebuffDesktopUsageSQL`).
//!
//! A message row stores its transcript (`parts_json`, often hundreds of KB) before `metrics_json`
//! and `ts`, so reading either walks the transcript's whole overflow chain: about 830 MB of page
//! reads for a 1.3 GB project, on every pass while a session keeps writing. Each pass instead lists
//! assistant rows by header-only fields (`octet_length` reads a value's size from the record
//! header) and reads text only for rows that are new or whose sizes moved. Mission-manager receipts
//! are small and re-read in full.

use super::scanner::{derive_turn, DerivedTurn};
use rusqlite::{Connection, OpenFlags};
use std::collections::hash_map::DefaultHasher;
use std::collections::{BTreeMap, HashMap};
use std::hash::{Hash, Hasher};
use std::path::Path;

/// Rows per targeted `seq IN (…)` lookup.
const LOOKUP_CHUNK: usize = 500;

/// The last read of one database: every assistant row by `seq`, plus manager receipts.
#[derive(Clone, Default)]
pub(super) struct MessageIndex {
    messages: BTreeMap<i64, IndexedMessage>,
    managers: Vec<DerivedTurn>,
}

#[derive(Clone)]
struct IndexedMessage {
    /// Hash of the header-only fields; a change re-reads the row's text.
    signature: u64,
    turn: Option<DerivedTurn>,
}

impl MessageIndex {
    /// Messages in `seq` order, then manager receipts: the order the full query produced, which
    /// decides the winner when two rows share a receipt id.
    pub(super) fn turns(&self) -> impl Iterator<Item = &DerivedTurn> {
        self.messages
            .values()
            .filter_map(|message| message.turn.as_ref())
            .chain(self.managers.iter())
    }
}

struct Listed {
    seq: i64,
    id: String,
    selected: String,
    signature: u64,
}

/// Read `path`, reusing `prior` rows whose header fields are unchanged. One read transaction keeps
/// the listing and the targeted reads on the same snapshot.
pub(super) fn read(path: &Path, prior: Option<&MessageIndex>) -> rusqlite::Result<MessageIndex> {
    let connection = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY)?;
    connection.execute_batch("BEGIN")?;
    let result = read_snapshot(&connection, prior);
    // A read-only transaction has nothing to commit; ending it only releases the snapshot.
    let _ = connection.execute_batch("COMMIT");
    result
}

fn read_snapshot(
    connection: &Connection,
    prior: Option<&MessageIndex>,
) -> rusqlite::Result<MessageIndex> {
    let mut include_snapshot = true;
    let mut include_parts = true;
    let listed = loop {
        match list_messages(connection, include_snapshot, include_parts) {
            Err(error)
                if include_snapshot && is_missing(&error, "no such column: t.world_snapshot") =>
            {
                include_snapshot = false;
            }
            // Older stores without the transcript column fall back to the metrics size alone.
            Err(error) if include_parts && is_missing(&error, "no such column: m.parts_json") => {
                include_parts = false;
            }
            result => break result?,
        }
    };
    let mut messages = BTreeMap::new();
    let mut pending: Vec<&Listed> = Vec::new();
    for row in &listed {
        match prior.and_then(|index| index.messages.get(&row.seq)) {
            Some(cached) if cached.signature == row.signature => {
                messages.insert(row.seq, cached.clone());
            }
            _ => pending.push(row),
        }
    }
    if !pending.is_empty() {
        let texts = read_texts(connection, &pending, pending.len() == listed.len())?;
        for row in pending {
            let turn = texts.get(&row.seq).and_then(|(timestamp, metrics)| {
                derive_turn(&row.id, timestamp, metrics, &row.selected)
            });
            messages.insert(
                row.seq,
                IndexedMessage {
                    signature: row.signature,
                    turn,
                },
            );
        }
    }
    let managers = loop {
        match read_managers(connection, include_snapshot) {
            Err(error) if is_missing(&error, "no such table: auto_run_decision_receipts") => {
                break Vec::new();
            }
            Err(error)
                if include_snapshot && is_missing(&error, "no such column: t.world_snapshot") =>
            {
                include_snapshot = false;
            }
            result => break result?,
        }
    };
    Ok(MessageIndex { messages, managers })
}

fn is_missing(error: &rusqlite::Error, needle: &str) -> bool {
    error.to_string().to_lowercase().contains(needle)
}

fn selected_model(include_snapshot: bool) -> &'static str {
    if include_snapshot {
        "COALESCE(NULLIF(t.model, ''), CASE WHEN json_valid(t.world_snapshot) THEN json_extract(t.world_snapshot, '$.model') END, '')"
    } else {
        "COALESCE(t.model, '')"
    }
}

/// Header-only listing: every selected column sits before the transcript, or is a size.
fn list_messages(
    connection: &Connection,
    include_snapshot: bool,
    include_parts: bool,
) -> rusqlite::Result<Vec<Listed>> {
    let parts = if include_parts {
        "octet_length(m.parts_json)"
    } else {
        "0"
    };
    let sql = format!(
        "SELECT m.seq, m.thread_id, COALESCE(m.request_id, ''), octet_length(m.metrics_json), \
         {parts}, {} \
         FROM messages m JOIN threads t ON t.id = m.thread_id \
         WHERE t.harness_id = 'codebuff' AND m.role = 'assistant'",
        selected_model(include_snapshot)
    );
    let mut statement = connection.prepare(&sql)?;
    let rows = statement.query_map([], |row| {
        let seq: i64 = row.get(0)?;
        let thread: String = row.get::<_, Option<String>>(1)?.unwrap_or_default();
        let request: String = row.get(2)?;
        let metrics_len: Option<i64> = row.get(3)?;
        let parts_len: Option<i64> = row.get(4)?;
        let selected: String = row.get::<_, Option<String>>(5)?.unwrap_or_default();
        let mut hasher = DefaultHasher::new();
        (&thread, &request, metrics_len, parts_len, &selected).hash(&mut hasher);
        // Same id rule as the Swift projection: cloud runs keep their request id.
        let id = if request.to_ascii_lowercase().starts_with("cloud:") {
            request
        } else {
            format!("{thread}:{seq}")
        };
        Ok(Listed {
            seq,
            id,
            selected,
            signature: hasher.finish(),
        })
    })?;
    rows.collect()
}

/// `seq → (timestamp, metrics JSON)` for the rows to (re)derive. A cold read scans every assistant
/// row in one pass; an incremental one looks up only the pending rows by primary key.
fn read_texts(
    connection: &Connection,
    pending: &[&Listed],
    everything: bool,
) -> rusqlite::Result<HashMap<i64, (String, String)>> {
    const COLUMNS: &str =
        "m.seq, COALESCE(CAST(m.ts AS TEXT), ''), COALESCE(NULLIF(m.metrics_json, ''), '{}')";
    let mut texts = HashMap::with_capacity(pending.len());
    let mut collect = |sql: &str, parameters: Vec<i64>| -> rusqlite::Result<()> {
        let mut statement = connection.prepare(sql)?;
        let mut rows = statement.query(rusqlite::params_from_iter(parameters))?;
        while let Some(row) = rows.next()? {
            texts.insert(row.get::<_, i64>(0)?, (row.get(1)?, row.get(2)?));
        }
        Ok(())
    };
    if everything {
        collect(
            &format!(
                "SELECT {COLUMNS} FROM messages m JOIN threads t ON t.id = m.thread_id \
                 WHERE t.harness_id = 'codebuff' AND m.role = 'assistant'"
            ),
            Vec::new(),
        )?;
    } else {
        for chunk in pending.chunks(LOOKUP_CHUNK) {
            let placeholders = vec!["?"; chunk.len()].join(", ");
            collect(
                &format!("SELECT {COLUMNS} FROM messages m WHERE m.seq IN ({placeholders})"),
                chunk.iter().map(|row| row.seq).collect(),
            )?;
        }
    }
    Ok(texts)
}

fn read_managers(
    connection: &Connection,
    include_snapshot: bool,
) -> rusqlite::Result<Vec<DerivedTurn>> {
    let sql = format!(
        r#"SELECT
            COALESCE('mission-manager:' || r.thread_id || ':' || CAST(r.id AS TEXT), ''),
            COALESCE(CAST(json_extract(r.manager_json, '$.startedAt') AS TEXT), CAST(r.created_at AS TEXT), ''),
            json_object(
              'usage', json(json_set(json_extract(r.manager_json, '$.usage'), '$.model', json_extract(r.manager_json, '$.model'))),
              'usageIncomplete', COALESCE(json_extract(r.manager_json, '$.usageIncomplete'), 0)
            ) || '',
            {}
          FROM auto_run_decision_receipts r JOIN threads t ON t.id = r.thread_id
          WHERE t.harness_id = 'codebuff'
            AND json_extract(r.manager_json, '$.harnessId') = 'codebuff'
            AND json_type(r.manager_json, '$.usage') = 'object'"#,
        selected_model(include_snapshot)
    );
    let mut statement = connection.prepare(&sql)?;
    let mut rows = statement.query([])?;
    let mut turns = Vec::new();
    while let Some(row) = rows.next()? {
        let text = |index: usize| -> rusqlite::Result<String> {
            Ok(row.get::<_, Option<String>>(index)?.unwrap_or_default())
        };
        if let Some(turn) = derive_turn(&text(0)?, &text(1)?, &text(2)?, &text(3)?) {
            turns.push(turn);
        }
    }
    Ok(turns)
}

#[cfg(test)]
#[path = "desktop_tests.rs"]
mod tests;
