use crate::antigravity_proto::GenerationEvent;
use rusqlite::{Connection, OptionalExtension, params};
use std::path::Path;

const MAX_RECORD_BYTES: usize = 512 * 1024;
const MAX_RECORDS: usize = 16;

pub(super) fn open(path: &Path) -> Option<Connection> {
    let result = Connection::open(path).and_then(|conn| {
        conn.execute_batch(
            "PRAGMA busy_timeout = 0;
             CREATE TABLE IF NOT EXISTS folds (
                path TEXT PRIMARY KEY, zone TEXT NOT NULL, digest BLOB NOT NULL,
                events BLOB NOT NULL, updated INTEGER NOT NULL
             );",
        )?;
        Ok(conn)
    });
    result.inspect_err(|e| log::warn!("[antigravity] Could not open history checkpoint: {e}")).ok()
}

pub(super) fn load(
    conn: &Connection,
    path: &str,
    zone: &str,
    digest: &[u8],
) -> Option<Vec<GenerationEvent>> {
    let bytes: Option<Vec<u8>> = conn
        .query_row(
            "SELECT events FROM folds WHERE path = ?1 AND zone = ?2 AND digest = ?3
                AND length(events) <= ?4",
            params![path, zone, digest, MAX_RECORD_BYTES],
            |row| row.get(0),
        )
        .optional()
        .inspect_err(|e| log::warn!("[antigravity] Could not read history checkpoint: {e}"))
        .ok()?;
    serde_json::from_slice(&bytes?)
        .inspect_err(|e| log::warn!("[antigravity] Invalid history checkpoint: {e}"))
        .ok()
}

pub(super) fn save(conn: &Connection, path: &str, zone: &str, digest: &[u8], events: &[GenerationEvent]) {
    if std::mem::size_of_val(events) > MAX_RECORD_BYTES {
        return;
    }
    // The pinned scanner snapshot is still usable if saving the bounded optimization fails.
    let Ok(bytes) = serde_json::to_vec(events) else { return };
    if bytes.len() > MAX_RECORD_BYTES {
        return;
    }
    let result = (|| {
        let tx = conn.unchecked_transaction()?;
        tx.execute(
            "INSERT OR REPLACE INTO folds(path, zone, digest, events, updated)
             VALUES (?1, ?2, ?3, ?4, (SELECT COALESCE(MAX(updated), 0) + 1 FROM folds))",
            params![path, zone, digest, bytes],
        )?;
        tx.execute(
            "DELETE FROM folds WHERE path IN
                (SELECT path FROM folds ORDER BY updated DESC LIMIT -1 OFFSET ?1)",
            [MAX_RECORDS],
        )?;
        tx.commit()
    })();
    if let Err(e) = result {
        log::warn!("[antigravity] Could not save history checkpoint: {e}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn checkpoint_survives_reopen_but_not_different_source_or_time_zone() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("history.db");
        let event = GenerationEvent {
            model: "gemini".into(),
            input_tokens: 10,
            output_tokens: 20,
            cache_read_tokens: 0,
            timestamp_seconds: 1,
        };
        save(&open(&file).unwrap(), "original.db", "UTC", b"revision", &[event.clone()]);
        let conn = open(&file).unwrap();
        assert_eq!(load(&conn, "original.db", "UTC", b"revision").unwrap(), [event]);
        assert!(load(&conn, "replacement.db", "UTC", b"revision").is_none());
        assert!(load(&conn, "original.db", "UTC", b"replacement").is_none());
        assert!(load(&conn, "original.db", "Asia/Tokyo", b"revision").is_none());
    }
}
