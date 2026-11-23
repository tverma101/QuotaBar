use std::sync::mpsc::{self, Receiver, SyncSender};
use std::thread;
use std::time::Duration;

use tauri::{AppHandle, Emitter, Manager};
use windows_sys::Win32::Foundation::{HWND, LPARAM, LRESULT, WPARAM};
use windows_sys::Win32::UI::Shell::{DefSubclassProc, RemoveWindowSubclass, SetWindowSubclass};
use windows_sys::Win32::UI::WindowsAndMessaging::{
    GA_ROOT, GW_OWNER, GetAncestor, GetForegroundWindow, GetWindow, PBT_APMRESUMEAUTOMATIC,
    WM_NCDESTROY, WM_POWERBROADCAST,
};

use crate::popover_platform;

struct BlurWatcher(SyncSender<()>);

fn watch_power_resume(window: HWND, app: AppHandle) {
    let context = Box::into_raw(Box::new(app));
    let id = watch_power_resume as *const () as usize;
    if unsafe { SetWindowSubclass(window, Some(power_broadcast), id, context as usize) } == 0 {
        unsafe { drop(Box::from_raw(context)) };
        log::warn!("Cannot register Windows power-resume handler");
    }
}

unsafe extern "system" fn power_broadcast(
    window: HWND,
    message: u32,
    wparam: WPARAM,
    lparam: LPARAM,
    id: usize,
    context: usize,
) -> LRESULT {
    let app = context as *mut AppHandle;
    if message == WM_NCDESTROY {
        unsafe { RemoveWindowSubclass(window, Some(power_broadcast), id) };
        unsafe { drop(Box::from_raw(app)) };
    } else if message == WM_POWERBROADCAST && wparam == PBT_APMRESUMEAUTOMATIC as usize {
        if let Err(error) = unsafe { &*app }.emit("refresh:power-resume", ()) {
            log::warn!("Cannot notify QuotaBar about Windows power resume: {error}");
        }
    }
    unsafe { DefSubclassProc(window, message, wparam, lparam) }
}

/// Show the panel anchored to the tray when possible.
pub fn show_panel(app_handle: &AppHandle) {
    if let Some(window) = app_handle.get_webview_window("main") {
        if let Err(error) = window.show() {
            log::warn!("Cannot show the QuotaBar window: {error}");
            return;
        }
        popover_platform::move_main_near_tray(app_handle);
        let _ = window.set_focus();
        if let Some(watcher) = app_handle.try_state::<BlurWatcher>() {
            // Coalesce repeated opens while the same window is already being watched.
            let _ = watcher.0.try_send(());
        }
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
            show_panel(app_handle);
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
fn spawn_blur_watcher(app_handle: AppHandle, panel: usize, shown: Receiver<()>) {
    thread::spawn(move || {
        // Block while hidden. Provider refresh and the local API run independently.
        while shown.recv().is_ok() {
            loop {
                thread::sleep(Duration::from_millis(250));
                let Some(window) = app_handle.get_webview_window("main") else {
                    return;
                };
                if !window.is_visible().unwrap_or(false) {
                    break;
                }
                let foreground = unsafe { GetForegroundWindow() };
                if !foreground.is_null()
                    && !unsafe { foreground_is_panel(foreground, panel as HWND) }
                {
                    let _ = window.hide();
                    break;
                }
            }
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
            watch_power_resume(hwnd.0 as HWND, app_handle.clone());
            let (send, shown) = mpsc::sync_channel(1);
            if app_handle.manage(BlurWatcher(send)) {
                spawn_blur_watcher(app_handle.clone(), hwnd.0 as usize, shown);
            }
        }
    }

    Ok(())
}
