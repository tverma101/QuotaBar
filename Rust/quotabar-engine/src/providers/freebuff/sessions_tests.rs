//! Session-title resolution against synthetic Desktop project databases.

use super::*;
use tempfile::TempDir;

fn session(id: &str) -> ActiveSession {
    ActiveSession {
        instance_id: id.into(),
        expires_at: 2_000_000_000.0,
        model: None,
        thread_id: None,
        chat_title: None,
        project_path: None,
    }
}

fn project(home: &Path, name: &str, threads: &[(&str, Option<&str>, &str)]) -> PathBuf {
    let dir = home.join(".config/freebuff-desktop/projects").join(name);
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("desktop-v2.db");
    let connection = Connection::open(&path).unwrap();
    connection
        .execute_batch(
            "CREATE TABLE threads (id TEXT PRIMARY KEY, project_path TEXT NOT NULL, \
             title TEXT NOT NULL DEFAULT 'New thread', freebuff_instance_id TEXT);",
        )
        .unwrap();
    for (id, instance, title) in threads {
        connection
            .execute(
                "INSERT INTO threads (id, project_path, title, freebuff_instance_id) VALUES (?1, ?2, ?3, ?4)",
                rusqlite::params![id, format!("/work/{name}"), title, instance],
            )
            .unwrap();
    }
    path
}

fn ledger(home: &Path, entries: &[(&str, &str)]) {
    let dir = home.join(".config/freebuff-desktop");
    std::fs::create_dir_all(&dir).unwrap();
    let json: Vec<Value> = entries
        .iter()
        .map(|(instance, thread)| {
            serde_json::json!({"instanceId": instance, "threadId": thread, "active": true})
        })
        .collect();
    std::fs::write(
        dir.join("state.json.session-ends.json"),
        serde_json::to_vec(&json).unwrap(),
    )
    .unwrap();
}

/// Regression: the Rust port dropped title resolution, so every timer lost its chat name.
#[test]
fn names_sessions_from_the_ledger_and_instance_column() {
    let dir = TempDir::new().unwrap();
    let alpha = project(
        dir.path(),
        "alpha",
        &[("t1", None, "Fix the parser"), ("t9", None, "Other")],
    );
    let beta = project(dir.path(), "beta", &[("t2", Some("i2"), "Write docs")]);
    ledger(dir.path(), &[("i1", "t1")]);
    let titles = SessionTitles::new(dir.path().to_path_buf());
    let mut sessions = vec![session("i1"), session("i2"), session("single")];
    titles.resolve(
        &mut sessions,
        || vec![alpha.clone(), beta.clone()],
        100.0,
        false,
    );
    assert_eq!(sessions[0].chat_title.as_deref(), Some("Fix the parser"));
    assert_eq!(sessions[0].thread_id.as_deref(), Some("t1"));
    assert_eq!(sessions[0].project_path.as_deref(), Some("/work/alpha"));
    assert_eq!(sessions[1].chat_title.as_deref(), Some("Write docs"));
    assert_eq!(sessions[2].chat_title, None);
}

#[test]
fn ledger_thread_beats_a_stale_instance_column_match() {
    let dir = TempDir::new().unwrap();
    let db = project(
        dir.path(),
        "p",
        &[("old", Some("i1"), "Old chat"), ("new", None, "New chat")],
    );
    ledger(dir.path(), &[("i1", "new")]);
    let titles = SessionTitles::new(dir.path().to_path_buf());
    let mut sessions = vec![session("i1")];
    titles.resolve(&mut sessions, || vec![db.clone()], 100.0, false);
    assert_eq!(sessions[0].chat_title.as_deref(), Some("New chat"));
}

#[test]
fn unchanged_database_reuses_the_title_and_a_rename_appears_after_the_interval() {
    let dir = TempDir::new().unwrap();
    let db = project(dir.path(), "p", &[("t1", None, "Non")]);
    ledger(dir.path(), &[("i1", "t1")]);
    let titles = SessionTitles::new(dir.path().to_path_buf());
    let mut first = vec![session("i1")];
    titles.resolve(&mut first, || vec![db.clone()], 100.0, false);
    assert_eq!(first[0].chat_title.as_deref(), Some("Non"));

    // An unchanged database never lists paths again.
    let mut cached = vec![session("i1")];
    titles.resolve(
        &mut cached,
        || panic!("unchanged database must not be searched"),
        500.0,
        false,
    );
    assert_eq!(cached[0].chat_title.as_deref(), Some("Non"));

    Connection::open(&db)
        .unwrap()
        .execute(
            "UPDATE threads SET title = 'Non2 renamed chat' WHERE id = 't1'",
            [],
        )
        .unwrap();
    let mut soon = vec![session("i1")];
    titles.resolve(&mut soon, Vec::new, 100.0 + TITLE_REFRESH_SECS - 1.0, false);
    assert_eq!(soon[0].chat_title.as_deref(), Some("Non"));
    let mut later = vec![session("i1")];
    titles.resolve(
        &mut later,
        Vec::new,
        100.0 + TITLE_REFRESH_SECS + 1.0,
        false,
    );
    assert_eq!(later[0].chat_title.as_deref(), Some("Non2 renamed chat"));
}

#[test]
fn older_schema_without_instance_column_matches_by_ledger_thread() {
    let dir = TempDir::new().unwrap();
    let project_dir = dir.path().join(".config/freebuff-desktop/projects/legacy");
    std::fs::create_dir_all(&project_dir).unwrap();
    let db = project_dir.join("desktop-v2.db");
    Connection::open(&db)
        .unwrap()
        .execute_batch(
            "CREATE TABLE threads (id TEXT PRIMARY KEY, project_path TEXT, title TEXT);
             INSERT INTO threads VALUES ('t1', '/legacy', 'Legacy chat');",
        )
        .unwrap();
    ledger(dir.path(), &[("i1", "t1")]);
    let titles = SessionTitles::new(dir.path().to_path_buf());
    let mut sessions = vec![session("i1")];
    titles.resolve(&mut sessions, || vec![db.clone()], 100.0, false);
    assert_eq!(sessions[0].chat_title.as_deref(), Some("Legacy chat"));
}

#[test]
fn no_active_sessions_clears_the_cache() {
    let dir = TempDir::new().unwrap();
    let db = project(dir.path(), "p", &[("t1", None, "Chat")]);
    ledger(dir.path(), &[("i1", "t1")]);
    let titles = SessionTitles::new(dir.path().to_path_buf());
    titles.resolve(&mut [session("i1")], || vec![db.clone()], 100.0, false);
    titles.resolve(&mut [], Vec::new, 101.0, false);
    assert!(titles.cache.lock().unwrap().is_empty());
}
