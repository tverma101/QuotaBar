//! Chat titles for live Freebuff sessions (`FreebuffDesktopUsageScanner.resolveLocalSessions`).
//!
//! The hosted session meter reports only an instance id and an expiry. Freebuff Desktop records
//! which chat holds each instance (`state.json.session-ends.json`) and names the chat in its
//! project database's `threads` table, so the menu-bar timer can say which session is running.
//! Only the title, thread id and project path are read; transcripts are never touched.

use crate::host::{self, diagnostic_gate};
use crate::model::ActiveSession;
use crate::qlog;
use crate::sqlite::{self, SourceSignature};
use rusqlite::Connection;
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

/// A changed database is re-read for a renamed title at most this often, unless the refresh is
/// manual. An unchanged database keeps its title with no query.
pub const TITLE_REFRESH_SECS: f64 = 60.0;
const SESSION_ENDS_SUBPATH: &str = ".config/freebuff-desktop/state.json.session-ends.json";
const READ_FAILURE_KEY: &str = "provider.freebuff.session-titles.unreadable";
/// Instance ids the hosted meter uses for a session no Desktop chat holds.
const UNOWNED_INSTANCE_IDS: [&str; 2] = ["single", "cli"];

#[derive(Clone, Debug, Default)]
struct ChatInfo {
    title: String,
    project_path: String,
    thread_id: String,
    /// The project database the title came from; `None` when no database named the session.
    source: Option<PathBuf>,
    stamp: SourceSignature,
    fetched_at: f64,
}

struct ChatRow {
    instance_id: String,
    thread_id: String,
    title: String,
    project_path: String,
}

pub struct SessionTitles {
    home: PathBuf,
    cache: Mutex<HashMap<String, ChatInfo>>,
}

impl SessionTitles {
    pub fn new(home: PathBuf) -> Self {
        SessionTitles {
            home,
            cache: Mutex::new(HashMap::new()),
        }
    }

    /// Fill `chat_title`, `thread_id` and `project_path` for each session whose chat can be found.
    /// `database_paths` is consulted only when a session's cached title is stale or unknown.
    pub fn resolve(
        &self,
        sessions: &mut [ActiveSession],
        database_paths: impl FnOnce() -> Vec<PathBuf>,
        now: f64,
        manual: bool,
    ) {
        let mut cache = self.cache.lock().unwrap_or_else(|e| e.into_inner());
        if sessions.is_empty() {
            cache.clear();
            return;
        }
        let active: HashSet<&str> = sessions.iter().map(|s| s.instance_id.as_str()).collect();
        cache.retain(|id, _| active.contains(id.as_str()));

        let mut unresolved: Vec<usize> = Vec::new();
        for (index, session) in sessions.iter_mut().enumerate() {
            if UNOWNED_INSTANCE_IDS.contains(&session.instance_id.as_str()) {
                continue;
            }
            match cache.get(&session.instance_id) {
                Some(cached) if is_reusable(cached, now, manual) => apply(session, cached),
                _ => unresolved.push(index),
            }
        }
        if unresolved.is_empty() {
            return;
        }

        let mut remaining: HashSet<String> = unresolved
            .iter()
            .map(|&index| sessions[index].instance_id.clone())
            .collect();
        let mut failures: Vec<String> = Vec::new();
        let instance_to_thread = self.session_end_threads(&remaining, &mut failures);
        let mut remaining_threads: HashSet<String> = instance_to_thread.values().cloned().collect();

        // A database that already named a session is re-read first; the rest newest-first.
        let mut known: Vec<PathBuf> = unresolved
            .iter()
            .filter_map(|&index| cache.get(&sessions[index].instance_id)?.source.clone())
            .collect();
        known.sort();
        known.dedup();
        for path in &known {
            if remaining.is_empty() {
                break;
            }
            let sets = (&mut remaining, &mut remaining_threads);
            ingest(
                &mut cache,
                path,
                now,
                &instance_to_thread,
                sets,
                &mut failures,
            );
        }
        if !remaining.is_empty() {
            let mut others: Vec<(std::time::SystemTime, PathBuf)> = database_paths()
                .into_iter()
                .filter(|path| !known.contains(path))
                .map(|path| {
                    let modified = std::fs::metadata(&path)
                        .and_then(|meta| meta.modified())
                        .unwrap_or(std::time::UNIX_EPOCH);
                    (modified, path)
                })
                .collect();
            others.sort_by_key(|entry| std::cmp::Reverse(entry.0));
            for (_, path) in others {
                if remaining.is_empty() {
                    break;
                }
                let sets = (&mut remaining, &mut remaining_threads);
                ingest(
                    &mut cache,
                    &path,
                    now,
                    &instance_to_thread,
                    sets,
                    &mut failures,
                );
            }
        }
        // One line per failure episode; a clean search re-arms it.
        match failures.first() {
            Some(detail) => warn_once(detail),
            None => diagnostic_gate::clear(READ_FAILURE_KEY),
        }

        // Not found anywhere: keep a prior title, and wait out the refresh interval before
        // searching again so a nameless session does not re-query every database each poll.
        for id in remaining {
            match cache.get_mut(&id) {
                Some(existing) if existing.source.is_some() => existing.fetched_at = now,
                _ => {
                    cache.insert(
                        id,
                        ChatInfo {
                            fetched_at: now,
                            ..ChatInfo::default()
                        },
                    );
                }
            }
        }
        for index in unresolved {
            if let Some(resolved) = cache.get(&sessions[index].instance_id) {
                apply(&mut sessions[index], resolved);
            }
        }
    }

    /// `instanceId → threadId` from Desktop's session-ends ledger, for the requested instances.
    fn session_end_threads(
        &self,
        instance_ids: &HashSet<String>,
        failures: &mut Vec<String>,
    ) -> HashMap<String, String> {
        let path = self.home.join(SESSION_ENDS_SUBPATH);
        let bytes = match std::fs::read(&path) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return HashMap::new(),
            Err(error) => {
                failures.push(format!("session ledger unreadable: {error}"));
                return HashMap::new();
            }
        };
        let Ok(Value::Array(entries)) = serde_json::from_slice::<Value>(&bytes) else {
            failures.push("session ledger is not a JSON array".into());
            return HashMap::new();
        };
        let text = |entry: &Value, key: &str| {
            entry
                .get(key)
                .and_then(Value::as_str)
                .filter(|value| !value.is_empty())
                .map(str::to_string)
        };
        entries
            .iter()
            .filter_map(|entry| Some((text(entry, "instanceId")?, text(entry, "threadId")?)))
            .filter(|(instance, _)| instance_ids.contains(instance))
            .collect()
    }
}

fn is_reusable(cached: &ChatInfo, now: f64, manual: bool) -> bool {
    let fresh = !manual && now - cached.fetched_at < TITLE_REFRESH_SECS;
    match &cached.source {
        None => fresh,
        Some(path) => sqlite::source_signature(path) == cached.stamp || fresh,
    }
}

fn apply(session: &mut ActiveSession, info: &ChatInfo) {
    if info.title.is_empty() {
        return;
    }
    session.chat_title = Some(info.title.clone());
    session.project_path = Some(info.project_path.clone()).filter(|value| !value.is_empty());
    session.thread_id = Some(info.thread_id.clone()).filter(|value| !value.is_empty());
}

/// Match one database's chats to the remaining sessions. A chat the session-ends ledger names for
/// an instance wins over one that only carries the instance id.
fn ingest(
    cache: &mut HashMap<String, ChatInfo>,
    path: &Path,
    now: f64,
    instance_to_thread: &HashMap<String, String>,
    (remaining, remaining_threads): (&mut HashSet<String>, &mut HashSet<String>),
    failures: &mut Vec<String>,
) {
    let stamp = sqlite::source_signature(path);
    let rows = match read_chats(path, remaining, remaining_threads) {
        Ok(rows) => rows,
        Err(error) => {
            failures.push(format!("project database unreadable: {error}"));
            return;
        }
    };
    let mut best: HashMap<String, (bool, ChatInfo)> = HashMap::new();
    for row in rows {
        let title = row.title.trim();
        if title.is_empty() {
            continue;
        }
        let mut targets: HashSet<&str> = HashSet::new();
        if !row.instance_id.is_empty() && remaining.contains(&row.instance_id) {
            targets.insert(&row.instance_id);
        }
        for (instance, thread) in instance_to_thread {
            if *thread == row.thread_id && remaining.contains(instance) {
                targets.insert(instance);
            }
        }
        if targets.is_empty() {
            continue;
        }
        for target in targets {
            let preferred =
                !row.thread_id.is_empty() && instance_to_thread.get(target) == Some(&row.thread_id);
            if matches!(best.get(target), Some((true, _))) && !preferred {
                continue;
            }
            let info = ChatInfo {
                title: title.to_string(),
                project_path: row.project_path.clone(),
                thread_id: row.thread_id.clone(),
                source: Some(path.to_path_buf()),
                stamp: stamp.clone(),
                fetched_at: now,
            };
            best.insert(target.to_string(), (preferred, info));
        }
        if !row.thread_id.is_empty() {
            remaining_threads.remove(&row.thread_id);
        }
    }
    for (instance, (_, info)) in best {
        remaining.remove(&instance);
        cache.insert(instance, info);
    }
}

fn read_chats(
    path: &Path,
    instance_ids: &HashSet<String>,
    thread_ids: &HashSet<String>,
) -> Result<Vec<ChatRow>, String> {
    if instance_ids.is_empty() && thread_ids.is_empty() {
        return Ok(Vec::new());
    }
    let Some(connection) = sqlite::open_read_only(path).map_err(|e| e.to_string())? else {
        return Ok(Vec::new());
    };
    match query_chats(&connection, instance_ids, thread_ids, true) {
        // Older Desktop schemas have no instance column; the ledger's thread ids still match.
        Err(error)
            if error.contains("no such column: freebuff_instance_id") && !thread_ids.is_empty() =>
        {
            query_chats(&connection, &HashSet::new(), thread_ids, false)
        }
        result => result,
    }
}

fn query_chats(
    connection: &Connection,
    instance_ids: &HashSet<String>,
    thread_ids: &HashSet<String>,
    has_instance_column: bool,
) -> Result<Vec<ChatRow>, String> {
    let placeholders = |count: usize| vec!["?"; count].join(", ");
    let mut conditions = Vec::new();
    if has_instance_column && !instance_ids.is_empty() {
        conditions.push(format!(
            "freebuff_instance_id IN ({})",
            placeholders(instance_ids.len())
        ));
    }
    if !thread_ids.is_empty() {
        conditions.push(format!("id IN ({})", placeholders(thread_ids.len())));
    }
    if conditions.is_empty() {
        return Ok(Vec::new());
    }
    let instance_column = if has_instance_column {
        "COALESCE(CAST(freebuff_instance_id AS TEXT), '')"
    } else {
        "''"
    };
    let sql = format!(
        "SELECT {instance_column}, COALESCE(CAST(id AS TEXT), ''), COALESCE(title, ''), \
         COALESCE(project_path, '') FROM threads WHERE {}",
        conditions.join(" OR ")
    );
    let mut parameters: Vec<&str> = Vec::new();
    if has_instance_column {
        parameters.extend(instance_ids.iter().map(String::as_str));
    }
    parameters.extend(thread_ids.iter().map(String::as_str));
    let mut statement = connection.prepare(&sql).map_err(|e| e.to_string())?;
    let rows = statement
        .query_map(rusqlite::params_from_iter(parameters), |row| {
            Ok(ChatRow {
                instance_id: row.get(0)?,
                thread_id: row.get(1)?,
                title: row.get(2)?,
                project_path: row.get(3)?,
            })
        })
        .map_err(|e| e.to_string())?;
    rows.collect::<Result<Vec<_>, _>>()
        .map_err(|e| e.to_string())
}

fn warn_once(detail: &str) {
    diagnostic_gate::log_once(READ_FAILURE_KEY, || {
        qlog!(
            Warn,
            host::plugin_tag("freebuff"),
            "active session names unavailable ({detail}); timers show without chat titles"
        );
    });
}

#[cfg(test)]
#[path = "sessions_tests.rs"]
mod tests;
