//! Filesystem locations. The host passes the user's home and the app's private data directory at
//! configure time so the engine never guesses (sandbox containers, test homes, Windows profiles).

use std::path::{Path, PathBuf};
use std::sync::{OnceLock, RwLock};

#[derive(Clone, Debug)]
pub struct Paths {
    /// The user's home directory (`$HOME`, `%USERPROFILE%`).
    pub home: PathBuf,
    /// Private, writable engine state (macOS: `~/Library/Application Support/QuotaBar`,
    /// Windows: `%APPDATA%\com.tverma101.quotabar`).
    pub app_data: PathBuf,
}

fn slot() -> &'static RwLock<Option<Paths>> {
    static SLOT: OnceLock<RwLock<Option<Paths>>> = OnceLock::new();
    SLOT.get_or_init(|| RwLock::new(None))
}

pub fn configure(paths: Paths) {
    *slot().write().unwrap_or_else(|e| e.into_inner()) = Some(paths);
}

pub fn current() -> Paths {
    if let Some(paths) = slot().read().unwrap_or_else(|e| e.into_inner()).clone() {
        return paths;
    }
    let home = default_home();
    Paths {
        app_data: default_app_data(&home),
        home,
    }
}

pub fn home() -> PathBuf {
    current().home
}

pub fn app_data() -> PathBuf {
    current().app_data
}

/// Engine-owned cache directory for one component (created on demand by writers).
pub fn cache_dir(component: &str) -> PathBuf {
    app_data().join("engine-cache").join(component)
}

/// Expand a leading `~` / `~/` against the configured home (Swift `expandHome`).
pub fn expand_home(path: &str) -> PathBuf {
    if path == "~" {
        return home();
    }
    if let Some(rest) = path.strip_prefix("~/").or_else(|| path.strip_prefix("~\\")) {
        return home().join(rest);
    }
    PathBuf::from(path)
}

fn default_home() -> PathBuf {
    #[cfg(windows)]
    {
        if let Some(profile) = std::env::var_os("USERPROFILE") {
            return PathBuf::from(profile);
        }
    }
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."))
}

fn default_app_data(home: &Path) -> PathBuf {
    #[cfg(target_os = "macos")]
    {
        home.join("Library/Application Support/QuotaBar")
    }
    #[cfg(windows)]
    {
        std::env::var_os("APPDATA")
            .map(PathBuf::from)
            .unwrap_or_else(|| home.join("AppData/Roaming"))
            .join("com.tverma101.quotabar")
    }
    #[cfg(not(any(target_os = "macos", windows)))]
    {
        std::env::var_os("XDG_DATA_HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|| home.join(".local/share"))
            .join("quotabar")
    }
}

/// `~/.local/share` on every platform: several agent CLIs (Devin, OpenCode) use the XDG layout even
/// on macOS and Windows.
pub fn xdg_data_home() -> PathBuf {
    std::env::var_os("XDG_DATA_HOME")
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| home().join(".local/share"))
}

/// Per-platform application-support root for Electron/VS Code style apps
/// (macOS `~/Library/Application Support`, Windows `%APPDATA%`, Linux `~/.config`).
pub fn platform_app_support() -> PathBuf {
    #[cfg(target_os = "macos")]
    {
        home().join("Library/Application Support")
    }
    #[cfg(windows)]
    {
        std::env::var_os("APPDATA")
            .map(PathBuf::from)
            .unwrap_or_else(|| home().join("AppData/Roaming"))
    }
    #[cfg(not(any(target_os = "macos", windows)))]
    {
        std::env::var_os("XDG_CONFIG_HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|| home().join(".config"))
    }
}

/// Write `bytes` to `path` atomically (temp file + rename) so readers never see a torn cache.
pub fn write_atomic(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let tmp = path.with_extension(format!("tmp-{}", std::process::id()));
    std::fs::write(&tmp, bytes)?;
    std::fs::rename(&tmp, path).inspect_err(|_| {
        let _ = std::fs::remove_file(&tmp);
    })
}
