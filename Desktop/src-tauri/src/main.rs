//! QuotaBar desktop shell: a Tauri 2 window + tray host for the static
//! dashboard in `../ui`. The only bridge surface is two commands — `refresh`
//! (bounded per-provider fetch in `quotabar_desktop`) and `is_demo`. `--demo`
//! is explicit opt-in: in demo mode no credential file or network is touched.

#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use quotabar_desktop::{Provider, Snapshot};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use tauri::menu::{Menu, MenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{Emitter, Manager, State};

struct RunMode(bool);

#[tauri::command]
async fn refresh(provider: Provider, mode: State<'_, RunMode>) -> Result<Snapshot, String> {
    if mode.0 {
        return Ok(quotabar_desktop::demo(provider));
    }
    tauri::async_runtime::spawn_blocking(move || quotabar_desktop::refresh(provider))
        .await
        .map_err(|_| "QuotaBar couldn't complete the refresh.".to_string())?
}

#[tauri::command]
fn is_demo(mode: State<'_, RunMode>) -> bool {
    mode.0
}

fn show_main_window(app: &tauri::AppHandle) {
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.show();
        let _ = window.unminimize();
        let _ = window.set_focus();
    }
}

fn main() {
    let demo = std::env::args().any(|arg| arg == "--demo");
    // Set only when the tray icon was actually installed — otherwise closing
    // the window must exit normally and never strand the user's only surface.
    let tray_installed = Arc::new(AtomicBool::new(false));
    let tray_flag = Arc::clone(&tray_installed);

    tauri::Builder::default()
        .manage(RunMode(demo))
        .invoke_handler(tauri::generate_handler![refresh, is_demo])
        .setup(move |app| {
            let open = MenuItem::with_id(app, "open", "Open QuotaBar", true, None::<&str>)?;
            let refresh_item = MenuItem::with_id(app, "refresh", "Refresh", true, None::<&str>)?;
            let quit = MenuItem::with_id(app, "quit", "Quit", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&open, &refresh_item, &quit])?;

            let mut builder = TrayIconBuilder::with_id("quotabar-tray")
                .menu(&menu)
                // Right-click opens the menu; left-click release opens the
                // window — on Linux the AppIndicator menu covers both.
                .show_menu_on_left_click(false)
                .on_menu_event(|app, event| match event.id().as_ref() {
                    "open" => show_main_window(app),
                    // A targeted event to the dashboard: refresh works without
                    // bringing the window up.
                    "refresh" => {
                        let _ = app.emit_to("main", "quotabar:refresh", ());
                    }
                    "quit" => app.exit(0),
                    _ => {}
                })
                .on_tray_icon_event(|tray, event| {
                    if let TrayIconEvent::Click {
                        button: MouseButton::Left,
                        button_state: MouseButtonState::Up,
                        ..
                    } = event
                    {
                        show_main_window(tray.app_handle());
                    }
                });
            if let Some(icon) = app.default_window_icon() {
                builder = builder.icon(icon.clone());
            }
            match builder.build(app) {
                Ok(_) => tray_flag.store(true, Ordering::Release),
                Err(error) => {
                    // No AppIndicator/status notifier — run window-only and
                    // say so instead of crashing or hiding the failure.
                    eprintln!(
                        "QuotaBar: system tray unavailable ({error}); \
                         the window stays open and closing it quits the app."
                    );
                }
            }
            Ok(())
        })
        .on_window_event(move |window, event| {
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                // Windows: hide to tray only when the icon actually installed.
                // Linux: a successfully built AppIndicator object does not prove
                // a StatusNotifier host is exposing it, so hiding on close could
                // strand the app with no surface — Close stays Quit (Minimize
                // still parks the window in the taskbar).
                if cfg!(target_os = "windows")
                    && window.label() == "main"
                    && tray_installed.load(Ordering::Acquire)
                {
                    api.prevent_close();
                    let _ = window.hide();
                }
            }
        })
        .run(tauri::generate_context!())
        .expect("error while running QuotaBar");
}
