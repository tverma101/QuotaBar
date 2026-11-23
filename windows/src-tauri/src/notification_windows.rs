//! Usage-alert toasts on Windows. The notification plugin's desktop path cannot
//! report a click, so alerts go through WinRT directly: one toast per alert
//! group, with title / subtitle / body like the macOS notification, and a click
//! opens the panel (the macOS "click opens the dashboard" behavior). Sound stays
//! with the frontend's alert-sound player, so the toast itself is silent.

use std::path::Path;

use tauri::{AppHandle, Manager};
use tauri_winrt_notification::{IconCrop, Toast};

use crate::panel;

/// The installed app is registered under its bundle identifier; `cargo`/`tauri dev`
/// builds are not, so they post through PowerShell's AppUserModelID like the plugin.
fn app_user_model_id(app: &AppHandle) -> String {
    let dev_build = tauri::utils::platform::current_exe()
        .ok()
        .and_then(|exe| exe.parent().map(|dir| dir.to_path_buf()))
        .map(|dir| dir.ends_with("target\\debug") || dir.ends_with("target\\release"))
        .unwrap_or(false);
    if dev_build {
        Toast::POWERSHELL_APP_ID.to_string()
    } else {
        app.config().identifier.clone()
    }
}

#[tauri::command]
pub fn post_usage_notification(
    app_handle: AppHandle,
    title: String,
    subtitle: Option<String>,
    body: String,
    icon_path: Option<String>,
) -> Result<(), String> {
    let mut toast = Toast::new(&app_user_model_id(&app_handle))
        .title(&title)
        .sound(None);
    toast = match subtitle.as_deref().filter(|s| !s.is_empty()) {
        Some(subtitle) => toast.text1(subtitle).text2(&body),
        None => toast.text1(&body),
    };
    if let Some(icon) = icon_path.as_deref().filter(|p| Path::new(p).is_file()) {
        toast = toast.icon(Path::new(icon), IconCrop::Square, "");
    }
    let handle = app_handle.clone();
    toast = toast.on_activated(move |_action| {
        let app = handle.clone();
        let _ = handle.run_on_main_thread(move || {
            if app.get_webview_window("main").is_some() {
                panel::show_panel(&app);
            }
        });
        Ok(())
    });
    toast.show().map_err(|error| {
        log::error!("Usage alert toast failed: {error}");
        format!("Cannot show the notification: {error}")
    })
}
