use std::thread;
use std::time::Duration;

use tauri::{AppHandle, Manager};
use windows_sys::Win32::Foundation::HWND;
use windows_sys::Win32::UI::WindowsAndMessaging::{
    GA_ROOT, GW_OWNER, GetAncestor, GetForegroundWindow, GetWindow,
};

use crate::popover_platform;

/// Show the panel anchored to the tray when possible.
pub fn show_panel(app_handle: &AppHandle) {
    if let Some(window) = app_handle.get_webview_window("main") {
        let _ = window.show();
        popover_platform::move_main_near_tray(app_handle);
        let _ = window.set_focus();
    }
}

/// Toggle panel visibility (global shortcut). Positions near tray when opening.
pub fn toggle_panel(app_handle: &AppHandle) {
    if let Some(window) = app_handle.get_webview_window("main") {
        if window.is_visible().unwrap_or(false) {
            log::debug!("toggle_panel: hiding window");
            let _ = window.hide();
        } else {
            log::debug!("toggle_panel: showing window");
            let _ = window.show();
            popover_platform::move_main_near_tray(app_handle);
            let _ = window.set_focus();
        }
    }
}

/// True when `foreground` belongs to the popover: it is the window itself, a
/// descendant (e.g. the WebView2 child — focusing web content must NOT count as
/// blur, which is why `WindowEvent::Focused` can't be used for this), or an
/// owned popup such as a tray menu or native dialog.
unsafe fn foreground_is_panel(foreground: HWND, panel: HWND) -> bool {
    if foreground == panel {
        return true;
    }
    let fg_root = GetAncestor(foreground, GA_ROOT);
    if !fg_root.is_null() && fg_root == GetAncestor(panel, GA_ROOT) {
        return true;
    }
    // Owned popups (context menus, file dialogs) chain up to their owner.
    let mut owner = foreground;
    for _ in 0..8 {
        owner = GetWindow(owner, GW_OWNER);
        if owner.is_null() {
            break;
        }
        if owner == panel {
            return true;
        }
    }
    false
}

/// Popover semantics: dismiss when the user clicks away (mirrors the macOS
/// panel's `window_did_resign_key` handler). `WindowEvent::Focused` is unusable
/// here because focus moving into the WebView2 child reports a blur; poll the
/// real foreground window instead.
fn spawn_blur_watcher(app_handle: AppHandle, panel: usize) {
    thread::spawn(move || loop {
        let panel = panel as HWND;
        thread::sleep(Duration::from_millis(250));
        let Some(window) = app_handle.get_webview_window("main") else {
            return;
        };
        if !window.is_visible().unwrap_or(false) {
            continue;
        }
        let foreground = unsafe { GetForegroundWindow() };
        if foreground.is_null() {
            continue;
        }
        if !unsafe { foreground_is_panel(foreground, panel) } {
            let _ = window.hide();
        }
    });
}

pub fn init(app_handle: &tauri::AppHandle) -> tauri::Result<()> {
    if let Some(window) = app_handle.get_webview_window("main") {
        // Frameless tray popover (same shape as the macOS panel): the
        // borderless/transparent/skip-taskbar flags come from tauri.conf.json,
        // this just pins the compact popover size and menu-bar behaviors:
        // click the tray icon to toggle, click away to dismiss.
        // Content-driven height: `resize_panel` resizes to whatever the webview
        // reports, so the minimum only guards a degenerate near-zero state.
        let _ = window.set_min_size(Some(tauri::Size::Logical(tauri::LogicalSize {
            width: 360.0,
            height: 300.0,
        })));
        let _ = window.set_size(tauri::Size::Logical(tauri::LogicalSize {
            width: 400.0,
            height: 640.0,
        }));

        let handle = app_handle.clone();
        window.on_window_event(move |event| {
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                api.prevent_close();
                if let Some(w) = handle.get_webview_window("main") {
                    let _ = w.hide();
                }
            }
        });

        if let Ok(hwnd) = window.hwnd() {
            spawn_blur_watcher(app_handle.clone(), hwnd.0 as usize);
        }
    }

    Ok(())
}
