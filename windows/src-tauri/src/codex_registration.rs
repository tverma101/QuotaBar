use crate::AppState;
use quotabar_core::codex_accounts::CodexHome;
use quotabar_core::provider_accounts::{self, ProviderAccount};
use serde::Serialize;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use uuid::Uuid;

static SIGN_IN: Mutex<Option<Arc<AtomicBool>>> = Mutex::new(None);
static REGISTER: Mutex<()> = Mutex::new(());

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct RegisteredCodexAccount {
    instance_id: String,
    label: String,
}

fn app_data_dir(state: &Mutex<AppState>) -> Result<PathBuf, String> {
    Ok(state.lock().map_err(|e| e.to_string())?.app_data_dir.clone())
}

fn register(app_data: &Path, home: CodexHome, label: String) -> Result<RegisteredCodexAccount, String> {
    let _registration = REGISTER.lock().map_err(|e| e.to_string())?;
    let stored = provider_accounts::load_store(app_data).map_err(|e| e.to_string())?;
    let observed = provider_accounts::verified_history_identities(app_data).map_err(|e| e.to_string())?;
    if stored.accounts.values().filter_map(|account| account.codex_home.as_ref())
        .any(|other| other.path == home.path || other.account_id == home.account_id)
        || observed.iter().any(|(id, identity)| {
            (id == "codex" || id.starts_with("codex:")) && *identity == home.account_id
        })
    {
        return Err("This Codex account is already connected.".into());
    }
    let label = label.trim();
    let label = if label.is_empty() { "Account" } else { label }.to_string();
    let instance_id = format!("codex:{}", Uuid::new_v4());
    provider_accounts::upsert_account(app_data, ProviderAccount {
        instance_id: instance_id.clone(),
        base_provider_id: "codex".into(),
        label: label.clone(),
        credential: Default::default(),
        codex_home: Some(home),
    }).map_err(|e| e.to_string())?;
    Ok(RegisteredCodexAccount { instance_id, label })
}

fn codex_executable() -> Option<PathBuf> {
    let name = if cfg!(windows) { "codex.exe" } else { "codex" };
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path).filter(|directory| directory.is_absolute())
        .map(|directory| directory.join(name)).find(|file| file.is_file())
}

fn login_command(executable: &Path, home: &Path) -> Command {
    let mut command = Command::new(executable);
    command.arg("login")
        .env("CODEX_HOME", home)
        .current_dir(home)
        .stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(0x08000000);
    }
    command
}

struct SignInGuard;

impl Drop for SignInGuard {
    fn drop(&mut self) {
        if let Ok(mut active) = SIGN_IN.lock() {
            *active = None;
        }
    }
}

fn run_sign_in(app_data: PathBuf, label: String) -> Result<RegisteredCodexAccount, String> {
    let cancel = Arc::new(AtomicBool::new(false));
    {
        let mut active = SIGN_IN.lock().map_err(|e| e.to_string())?;
        if active.is_some() {
            return Err("A Codex sign-in is already in progress.".into());
        }
        *active = Some(Arc::clone(&cancel));
    }
    let _guard = SignInGuard;
    let executable = codex_executable()
        .ok_or("Install the official Codex CLI and make its executable available on PATH.")?;
    let home = app_data.join("Codex Accounts").join(format!("Account-{}", Uuid::new_v4()));
    std::fs::create_dir_all(&home).map_err(|_| "Could not create a Codex account home.")?;
    let mut child = login_command(&executable, &home).spawn()
        .map_err(|_| "Could not start the official Codex CLI.")?;
    let deadline = Instant::now() + Duration::from_secs(15 * 60);
    loop {
        if cancel.load(Ordering::Acquire) || Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            return Err("Codex sign-in was cancelled or timed out. No account was added.".into());
        }
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) => std::thread::sleep(Duration::from_millis(250)),
            Err(_) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err("Codex sign-in did not complete. No account was added.".into());
            }
        }
    }
    let inspected = CodexHome::inspect(&home)
        .map_err(|_| "Codex did not create an identifiable ChatGPT account. No account was added.")?;
    if cancel.load(Ordering::Acquire) {
        return Err("Codex sign-in was cancelled. No account was added.".into());
    }
    register(&app_data, inspected, label)
}

#[tauri::command]
pub(crate) async fn sign_in_to_codex(
    state: tauri::State<'_, Mutex<AppState>>,
    label: String,
) -> Result<RegisteredCodexAccount, String> {
    let dir = app_data_dir(&state)?;
    tauri::async_runtime::spawn_blocking(move || run_sign_in(dir, label)).await
        .map_err(|_| "Codex sign-in failed.".to_string())?
}

#[tauri::command]
pub(crate) fn cancel_codex_sign_in() -> Result<(), String> {
    if let Some(active) = SIGN_IN.lock().map_err(|e| e.to_string())?.as_ref() {
        active.store(true, Ordering::Release);
    }
    Ok(())
}

#[tauri::command]
pub(crate) async fn register_codex_home(
    state: tauri::State<'_, Mutex<AppState>>,
    path: PathBuf,
    label: String,
) -> Result<RegisteredCodexAccount, String> {
    let dir = app_data_dir(&state)?;
    tauri::async_runtime::spawn_blocking(move || {
        let home = CodexHome::inspect(&path)
            .map_err(|_| "Choose a Codex home with an identifiable Codex sign-in in auth.json.")?;
        register(&dir, home, label)
    }).await.map_err(|_| "Could not register the Codex home.".to_string())?
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn launch_uses_official_browser_login_in_isolated_home() {
        let executable = Path::new("codex.exe");
        let home = Path::new("Codex Home");
        let command = login_command(executable, home);
        assert_eq!(command.get_program(), executable.as_os_str());
        assert_eq!(command.get_args().collect::<Vec<_>>(), ["login"]);
        assert_eq!(command.get_current_dir(), Some(home));
        assert_eq!(command.get_envs().find(|(name, _)| *name == "CODEX_HOME").unwrap().1,
            Some(home.as_os_str()));
    }
}
