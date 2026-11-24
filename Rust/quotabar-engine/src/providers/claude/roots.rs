//! Claude root and file discovery (Swift `claudeRoots`, `coworkClaudeDirs`, `parseSourceIdentity`,
//! `usageFilesIfComplete`).

use super::logs::ClaudeLogScanner;
use super::util::{expand_home, resolve_path, stable_fingerprint};
use crate::context::CancelToken;
use crate::host::{self, diagnostic_gate};
use crate::qlog;
use crate::scan::{discover, DiscoveredFile, Extensions, Revision};
use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

/// Foundation's `.whitespaces` (spaces and tabs, no line breaks).
fn trim_horizontal(value: &str) -> &str {
    value.trim_matches(|c: char| c == '\t' || (c.is_whitespace() && !matches!(c, '\n' | '\r' | '\u{b}' | '\u{c}' | '\u{85}' | '\u{2028}' | '\u{2029}')))
}

/// The comma-separated entries of a `CLAUDE_CONFIG_DIR` value, trimmed and non-empty.
fn config_dir_parts(raw: &str) -> impl Iterator<Item = &str> {
    raw.split(',').map(trim_horizontal).filter(|part| !part.is_empty())
}

/// The desktop app's data directory (Swift hard-codes the macOS layout; the Windows app keeps the
/// same tree under `%APPDATA%\Claude`, which a later platform pass can route through here).
pub(super) fn claude_app_support(home: &Path) -> PathBuf {
    home.join("Library/Application Support/Claude")
}

pub(super) fn cowork_base(home: &Path) -> PathBuf {
    claude_app_support(home).join("local-agent-mode-sessions")
}

/// Stable identity for the physical Claude parse source. OpenCode's gateway fold uses this same
/// source, so its supplementary scan reuses the native Claude card's whole-file cache instead of
/// cold-parsing the same terminal sessions under a second identity. Cowork session roots are
/// intentionally excluded: they appear and disappear over time but still share this source cache.
pub fn parse_source_identity(home: &Path, env: &dyn Fn(&str) -> Option<String>) -> String {
    let resolved_home = resolve_path(home).to_string_lossy().into_owned();
    let configured: Vec<PathBuf> = match env("CLAUDE_CONFIG_DIR").map(|raw| raw.trim().to_string()).filter(|raw| !raw.is_empty()) {
        Some(raw) => config_dir_parts(&raw)
            .map(|part| {
                let mut path = expand_home(home, part);
                if path.file_name().is_some_and(|name| name == "projects") {
                    path.pop();
                }
                path
            })
            .collect(),
        None => {
            let xdg = env("XDG_CONFIG_HOME")
                .filter(|v| !v.is_empty())
                .map(|v| expand_home(home, &v))
                .unwrap_or_else(|| home.join(".config"));
            vec![xdg.join("claude"), home.join(".claude")]
        }
    };
    let roots = resolved_set(&configured).into_iter().collect::<Vec<_>>().join("\n");
    format!("home={resolved_home}\nroots={roots}")
}

/// Cache identity for an explicit root list (OpenCode's fold passes its own roots).
pub(super) fn roots_identity(roots: &[PathBuf]) -> String {
    let resolved = resolved_set(roots);
    if resolved.is_empty() {
        "no-claude-root".to_string()
    } else {
        resolved.into_iter().collect::<Vec<_>>().join("\n")
    }
}

fn resolved_set(paths: &[PathBuf]) -> BTreeSet<String> {
    paths.iter().map(|p| resolve_path(p).to_string_lossy().into_owned()).collect()
}

impl ClaudeLogScanner {
    /// Claude config directories that actually contain a `projects/` folder, in ccusage's order: every
    /// entry of `CLAUDE_CONFIG_DIR` when set (an invalid list logs and yields none), else
    /// `$XDG_CONFIG_HOME/claude` (default `~/.config/claude`) and `~/.claude`. Cowork's per-session
    /// `.claude` sandboxes are always appended: they live under the desktop app's own container, so
    /// `CLAUDE_CONFIG_DIR` (a terminal-CLI override) doesn't speak for them.
    pub(super) fn claude_roots(&self) -> Vec<PathBuf> {
        fn add_if_valid(roots: &mut Vec<PathBuf>, dir: PathBuf) {
            if dir.join("projects").exists() && !roots.contains(&dir) {
                roots.push(dir);
            }
        }
        const INVALID_PREFIX: &str = "claude.config-dir.invalid.";
        let mut roots: Vec<PathBuf> = Vec::new();
        let configured = (self.env)("CLAUDE_CONFIG_DIR").map(|raw| raw.trim().to_string()).filter(|raw| !raw.is_empty());
        match &configured {
            Some(raw) => {
                for part in config_dir_parts(raw) {
                    let mut dir = expand_home(&self.home, part);
                    // Accept the `projects/` directory itself as an alias for its parent config dir.
                    if dir.file_name().is_some_and(|name| name == "projects") && dir.exists() {
                        dir.pop();
                    }
                    add_if_valid(&mut roots, dir);
                }
                if roots.is_empty() {
                    diagnostic_gate::log_once(&format!("{INVALID_PREFIX}{}", stable_fingerprint(raw)), || {
                        qlog!(
                            Warn,
                            host::plugin_tag("claude"),
                            "CLAUDE_CONFIG_DIR is set but contains no Claude data directory with projects/"
                        );
                    });
                } else {
                    diagnostic_gate::clear_prefix(INVALID_PREFIX);
                }
            }
            None => {
                diagnostic_gate::clear_prefix(INVALID_PREFIX);
                let xdg = (self.env)("XDG_CONFIG_HOME")
                    .filter(|v| !v.is_empty())
                    .map(|v| expand_home(&self.home, &v))
                    .unwrap_or_else(|| self.home.join(".config"));
                add_if_valid(&mut roots, xdg.join("claude"));
                add_if_valid(&mut roots, self.home.join(".claude"));
            }
        }
        for sandbox in cowork_claude_dirs(&self.home, self.organization_id.as_deref(), self.account_id.as_deref()) {
            add_if_valid(&mut roots, sandbox);
        }
        roots
    }

    /// The source files in scope for this scanner: every `*.jsonl` under the roots, narrowed to the
    /// sessions the organization owns when scoped. `None` means the source is incomplete (a root could
    /// not be enumerated, an ownership read failed, a file changed under us, or cancellation).
    pub(super) fn source_files(&self, roots: &[PathBuf], cancel: &CancelToken) -> Option<Vec<DiscoveredFile>> {
        let mut files = usage_files_if_complete(roots, cancel)?;
        if let Some(organization_id) = &self.organization_id {
            files = self.owned_usage_files(&files, organization_id, cancel)?;
            // Ownership lookups take time; a session rewritten meanwhile must not be scanned under its
            // stale discovered revision.
            let changed = files.iter().find(|f| Revision::read(&f.path).map_or(true, |now| now != f.revision));
            if let Some(file) = changed {
                let key = format!("claude.fold.source-changed.{}", stable_fingerprint(&file.path.to_string_lossy()));
                diagnostic_gate::log_once(&key, || {
                    qlog!(
                        Warn,
                        host::plugin_tag("claude"),
                        "session source {} changed during the ownership check; checking the source again next refresh",
                        crate::scan::file_label(&file.path)
                    );
                });
                return None;
            }
        }
        (!cancel.is_cancelled()).then_some(files)
    }
}

/// The `.claude` dirs Cowork (the Claude desktop app's agent mode) creates, one per session, under
/// `<app support>/Claude/local-agent-mode-sessions/<group>/<sub>/local_*` (plus an `agent/local_*`
/// variant one level deeper). Each holds the same `projects/**/*.jsonl` session logs as `~/.claude`,
/// so they scan as additional roots. The walk is bounded to those known levels: session dirs contain
/// full sandbox homes we must not recurse into.
fn cowork_claude_dirs(home: &Path, organization_id: Option<&str>, account_id: Option<&str>) -> Vec<PathBuf> {
    let lowered = |dir: &Path| dir.file_name().map(|n| n.to_string_lossy().to_lowercase());
    let mut dirs = Vec::new();
    for group in subdirectories(&cowork_base(home)) {
        if organization_id.is_some() && account_id.is_some() && lowered(&group).as_deref() != account_id {
            continue;
        }
        for sub in subdirectories(&group) {
            if organization_id.is_some() && lowered(&sub).as_deref() != organization_id {
                continue;
            }
            let mut sessions = subdirectories(&sub);
            let holders: Vec<PathBuf> =
                sessions.iter().filter(|d| d.file_name().is_some_and(|n| n == "agent")).cloned().collect();
            for holder in holders {
                sessions.extend(subdirectories(&holder));
            }
            dirs.extend(sessions.into_iter().map(|session| session.join(".claude")));
        }
    }
    dirs.sort_by_cached_key(|dir| dir.to_string_lossy().into_owned());
    dirs
}

/// Visible child directories (symlinks are not followed). A missing directory is simply empty; any
/// other failure is logged once, since it hides Cowork sessions.
fn subdirectories(dir: &Path) -> Vec<PathBuf> {
    let entries = match std::fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Vec::new(),
        Err(e) => {
            diagnostic_gate::log_once(&format!("claude.cowork.unreadable.{}", stable_fingerprint(&dir.to_string_lossy())), || {
                qlog!(Warn, host::plugin_tag("claude"), "could not list Cowork session directories: {e}");
            });
            return Vec::new();
        }
    };
    entries
        .filter_map(Result::ok)
        .filter(|entry| !entry.file_name().to_string_lossy().starts_with('.'))
        .filter(|entry| entry.file_type().is_ok_and(|kind| kind.is_dir()))
        .map(|entry| entry.path())
        .collect()
}

/// Every `*.jsonl` under each root's `projects/`, path-sorted so the dedup pass (keep-first wins) is
/// deterministic, the same order ccusage scans in. `None` when any root cannot be fully enumerated.
pub fn usage_files_if_complete(roots: &[PathBuf], cancel: &CancelToken) -> Option<Vec<DiscoveredFile>> {
    let mut files = Vec::new();
    for root in roots {
        if cancel.is_cancelled() {
            return None;
        }
        match discover(&root.join("projects"), Extensions::Jsonl) {
            Ok(found) => files.extend(found),
            Err(error) => {
                let key = format!("claude.discovery.{}", stable_fingerprint(&root.to_string_lossy()));
                diagnostic_gate::log_once(&key, || {
                    qlog!(
                        Warn,
                        host::plugin_tag("claude"),
                        "could not enumerate a Claude projects directory ({error}); preserving last-good history"
                    );
                });
                return None;
            }
        }
    }
    files.sort_by_cached_key(|file| file.path.to_string_lossy().into_owned());
    files.dedup_by(|a, b| a.path == b.path);
    Some(files)
}
