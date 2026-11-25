//! Read-only projections for Freebuff Desktop's local usage receipts (`FreebuffDesktopUsageSQL.swift`)
//! and the SQLite seam the scanner reads through.

use std::path::Path;
use std::time::Duration;

/// Swift `SQLiteAccessing.queryValue`: the first column of the first row as text. `Ok(None)` when the
/// database is absent or the result is empty. The error is the engine's message, which is what the
/// missing-schema fallbacks below match on.
pub trait SqliteAccess: Send + Sync {
    fn query_value(&self, path: &str, sql: &str) -> Result<Option<String>, String>;
}

/// The engine's in-process SQLite with the wider budget a gigabyte-scale project store needs (a
/// project database can reach gigabytes of turn history, so the five-second default made its
/// periodic reads fail loud every refresh).
pub struct NativeSqlite {
    pub query_timeout: Duration,
}

impl Default for NativeSqlite {
    fn default() -> Self {
        NativeSqlite { query_timeout: Duration::from_secs(30) }
    }
}

impl SqliteAccess for NativeSqlite {
    fn query_value(&self, path: &str, sql: &str) -> Result<Option<String>, String> {
        crate::sqlite::query_text_within(Path::new(path), sql, true, self.query_timeout).map_err(|e| e.to_string())
    }
}

// Current Desktop can clear threads.model during migration while keeping the selected model in
// world_snapshot. Project just that scalar; never fetch the rest of the thread snapshot.
const SELECTED_MODEL: &str = "COALESCE(NULLIF(t.model, ''), CASE WHEN json_valid(t.world_snapshot)\n  THEN json_extract(t.world_snapshot, '$.model') END, '')";

/// Includes assistant usage and the separate auto-run manager call. The outcome receipt is
/// deliberately excluded because it repeats the completed assistant turn's usage.
fn messages_and_mission_managers() -> String {
    format!(
        "SELECT COALESCE(json_group_array(json_object(\n\
  'id', id,\n\
  'timestamp', timestamp,\n\
  'metrics', metrics,\n\
  'selectedModel', selectedModel\n\
)), '[]') FROM (\n\
  SELECT\n\
    COALESCE(CASE WHEN m.request_id LIKE 'cloud:%' THEN m.request_id\n\
      ELSE m.thread_id || ':' || m.seq END, '') AS id,\n\
    COALESCE(CAST(m.ts AS TEXT), '') AS timestamp,\n\
    COALESCE(NULLIF(m.metrics_json, ''), '{{}}') AS metrics,\n\
    {SELECTED_MODEL} AS selectedModel\n\
  FROM messages m JOIN threads t ON t.id = m.thread_id\n\
  WHERE t.harness_id = 'codebuff' AND m.role = 'assistant'\n\
\n\
  UNION ALL\n\
\n\
  SELECT\n\
    COALESCE('mission-manager:' || r.thread_id || ':' || CAST(r.id AS TEXT), '') AS id,\n\
    COALESCE(\n\
      CAST(json_extract(r.manager_json, '$.startedAt') AS TEXT),\n\
      CAST(r.created_at AS TEXT), ''\n\
    ) AS timestamp,\n\
    json_object(\n\
      'usage', json_extract(r.manager_json, '$.usage'),\n\
      'usageIncomplete', COALESCE(json_extract(r.manager_json, '$.usageIncomplete'), 0)\n\
    ) || '' AS metrics,\n\
    COALESCE(NULLIF(json_extract(r.manager_json, '$.model'), ''), {SELECTED_MODEL}) AS selectedModel\n\
  FROM auto_run_decision_receipts r JOIN threads t ON t.id = r.thread_id\n\
  WHERE t.harness_id = 'codebuff'\n\
    AND json_extract(r.manager_json, '$.harnessId') = 'codebuff'\n\
    AND json_type(r.manager_json, '$.usage') = 'object'\n\
)"
    )
}

/// Compatibility query for stores created before mission-manager receipts existed.
fn assistant_messages() -> String {
    format!(
        "SELECT COALESCE(json_group_array(json_object(\n\
  'id', COALESCE(CASE WHEN m.request_id LIKE 'cloud:%' THEN m.request_id\n\
    ELSE m.thread_id || ':' || m.seq END, ''),\n\
  'timestamp', COALESCE(CAST(m.ts AS TEXT), ''),\n\
  'metrics', COALESCE(NULLIF(m.metrics_json, ''), '{{}}'),\n\
  'selectedModel', {SELECTED_MODEL}\n\
)), '[]') FROM messages m JOIN threads t ON t.id = m.thread_id\n\
WHERE t.harness_id = 'codebuff' AND m.role = 'assistant'"
    )
}

fn contains_ci(message: &str, needle: &str) -> bool {
    message.to_lowercase().contains(needle)
}

pub fn is_missing_mission_receipt_table(message: &str) -> bool {
    contains_ci(message, "no such table: auto_run_decision_receipts")
}

/// Older stores may predate either column/table. Retry only a proven missing-schema error;
/// invalid databases and other query failures still reach the provider's visible history error.
pub fn read_rows(sqlite: &dyn SqliteAccess, path: &str) -> Result<Option<String>, String> {
    let mut include_managers = true;
    let mut include_snapshot = true;
    loop {
        let mut sql = if include_managers { messages_and_mission_managers() } else { assistant_messages() };
        if !include_snapshot {
            sql = sql.replace(SELECTED_MODEL, "COALESCE(t.model, '')");
        }
        match sqlite.query_value(path, &sql) {
            Ok(value) => return Ok(value),
            Err(message) => {
                if include_managers && is_missing_mission_receipt_table(&message) {
                    include_managers = false;
                } else if include_snapshot && contains_ci(&message, "no such column: t.world_snapshot") {
                    include_snapshot = false;
                } else {
                    return Err(message);
                }
            }
        }
    }
}

/// One aggregate per source the projections consume — assistant messages carry their joined thread's
/// model fields, and the receipts table is summed wholesale. Any WAL churn that left usage rows alone
/// produces the same fingerprint; a changed fingerprint re-reads in full.
pub const CONTENT_FINGERPRINT_QUERY: &str = "SELECT\n\
  (SELECT COUNT(*) || ':' || COALESCE(SUM(m.rowid),0) || ':' ||\n\
          COALESCE(SUM(LENGTH(m.request_id)+LENGTH(m.metrics_json)+LENGTH(m.ts)+\n\
                         LENGTH(COALESCE(t.model,''))+LENGTH(COALESCE(t.world_snapshot,''))),0)\n\
   FROM messages m JOIN threads t ON t.id = m.thread_id\n\
   WHERE t.harness_id = 'codebuff' AND m.role = 'assistant')\n\
  || '|' ||\n\
  (SELECT COUNT(*) || ':' || COALESCE(SUM(r.rowid),0) || ':' ||\n\
          COALESCE(SUM(LENGTH(r.manager_json)),0)\n\
   FROM auto_run_decision_receipts r)";

/// Cheap proof that the projected rows did not change across a stamp-level revision bump. `None`
/// means unproven — an old schema (missing receipts table or `world_snapshot`) or any query failure —
/// and the caller falls back to the full read.
pub fn content_fingerprint(sqlite: &dyn SqliteAccess, path: &str) -> Option<String> {
    sqlite.query_value(path, CONTENT_FINGERPRINT_QUERY).ok().flatten()
}

fn quote(values: &[String]) -> String {
    values.iter().map(|v| format!("'{}'", v.replace('\'', "''"))).collect::<Vec<_>>().join(", ")
}

pub fn active_session_chats_query(instance_ids: &[String], thread_ids: &[String]) -> String {
    let escaped_instances = quote(instance_ids);
    let escaped_threads = quote(thread_ids);
    let mut conditions: Vec<String> = Vec::new();
    if !escaped_instances.is_empty() {
        conditions.push(format!("freebuff_instance_id IN ({escaped_instances})"));
    }
    if !escaped_threads.is_empty() {
        conditions.push(format!("id IN ({escaped_threads})"));
    }
    let where_clause = if conditions.is_empty() { "1=0".to_string() } else { conditions.join(" OR ") };
    format!(
        "SELECT COALESCE(json_group_array(json_object(\n\
  'instanceId', COALESCE(freebuff_instance_id, ''),\n\
  'threadId', COALESCE(id, ''),\n\
  'title', COALESCE(title, ''),\n\
  'projectPath', COALESCE(project_path, '')\n\
)), '[]') FROM threads\n\
WHERE {where_clause}"
    )
}

pub fn read_active_session_chats(
    sqlite: &dyn SqliteAccess,
    path: &str,
    instance_ids: &[String],
    thread_ids: &[String],
) -> Result<Option<String>, String> {
    if instance_ids.is_empty() && thread_ids.is_empty() {
        return Ok(Some("[]".into()));
    }
    let sql = active_session_chats_query(instance_ids, thread_ids);
    match sqlite.query_value(path, &sql) {
        Err(message)
            if contains_ci(&message, "no such column: freebuff_instance_id") && !thread_ids.is_empty() =>
        {
            let escaped_threads = quote(thread_ids);
            let fallback = format!(
                "SELECT COALESCE(json_group_array(json_object(\n\
  'instanceId', '',\n\
  'threadId', COALESCE(id, ''),\n\
  'title', COALESCE(title, ''),\n\
  'projectPath', COALESCE(project_path, '')\n\
)), '[]') FROM threads\n\
WHERE id IN ({escaped_threads})"
            );
            sqlite.query_value(path, &fallback)
        }
        other => other,
    }
}
