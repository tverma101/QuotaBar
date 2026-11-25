use std::sync::{Mutex, OnceLock};
use std::thread;
use std::time::{Duration, Instant};

use tauri::{AppHandle, Emitter, Manager, WebviewWindow};
use windows_sys::Win32::Foundation::{HWND, LPARAM, LRESULT, WPARAM};
use windows_sys::Win32::UI::Accessibility::{HWINEVENTHOOK, SetWinEventHook};
use windows_sys::Win32::UI::Shell::{DefSubclassProc, RemoveWindowSubclass, SetWindowSubclass};
use windows_sys::Win32::UI::WindowsAndMessaging::{
    DispatchMessageW, EVENT_SYSTEM_FOREGROUND, GA_ROOT, GW_OWNER, GetAncestor, GetMessageW,
    GetWindow, MSG, OBJID_WINDOW, SetWindowDisplayAffinity, WDA_EXCLUDEFROMCAPTURE, WDA_NONE,
    PBT_APMRESUMEAUTOMATIC, WINEVENT_OUTOFCONTEXT, WINEVENT_SKIPOWNPROCESS, WM_NCDESTROY,
    WM_POWERBROADCAST,
};

use crate::{popover_geometry, popover_platform};

/// The panel the foreground hook dismisses, set once at init.
static BLUR_TARGET: OnceLock<(AppHandle, usize)> = OnceLock::new();
/// When click-away last dismissed the panel. Clicking the tray icon moves the
/// foreground to the taskbar first, so the tray press that follows must not reopen it.
static LAST_BLUR_HIDE: Mutex<Option<Instant>> = Mutex::new(None);
const TRAY_REOPEN_GUARD: Duration = Duration::from_millis(400);


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
    }
}

/// Hide the panel and tell the frontend, which resets navigation and scroll the
/// way closing the macOS panel does.
pub fn hide_panel(app_handle: &AppHandle) {
    if let Some(window) = app_handle.get_webview_window("main") {
        hide_window(&window);
    }
}

fn hide_window(window: &WebviewWindow) {
    if let Err(error) = window.hide() {
        log::warn!("Cannot hide the QuotaBar window: {error}");
        return;
    }
    let _ = window.emit("panel:did-hide", ());
}

/// Hide From Screen Share: exclude the panel from screen capture, recording and
/// sharing (`WDA_EXCLUDEFROMCAPTURE`, Windows 10 2004+). The tray icon belongs to
/// Explorer and cannot be excluded, so the frontend swaps its text for the
/// wordmark separately.
pub fn set_capture_excluded(app_handle: &AppHandle, excluded: bool) -> Result<(), String> {
    let affinity = if excluded { WDA_EXCLUDEFROMCAPTURE } else { WDA_NONE };
    for (label, window) in app_handle.webview_windows() {
        let hwnd = window.hwnd().map_err(|e| e.to_string())?;
        if unsafe { SetWindowDisplayAffinity(hwnd.0 as HWND, affinity) } == 0 {
            let error = std::io::Error::last_os_error();
            log::error!("SetWindowDisplayAffinity failed for {label}: {error}");
            return Err(format!("Cannot change screen share protection: {error}"));
        }
    }
    Ok(())
}

/// Toggle panel visibility (global shortcut). Positions near tray when opening.
pub fn toggle_panel(app_handle: &AppHandle) {
    if let Some(window) = app_handle.get_webview_window("main") {
        if window.is_visible().unwrap_or(false) {
            log::debug!("toggle_panel: hiding window");
            hide_window(&window);
        } else if LAST_BLUR_HIDE
            .lock()
            .ok()
            .and_then(|last| *last)
            .is_some_and(|at| at.elapsed() < TRAY_REOPEN_GUARD)
        {
            log::debug!("toggle_panel: panel was just dismissed by this click; keeping it closed");
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
    unsafe {
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
}

/// Popover semantics: dismiss when the user clicks away (mirrors the macOS
/// panel's `window_did_resign_key` handler). `WindowEvent::Focused` is unusable
/// here because focus moving into the WebView2 child reports a blur, so listen
/// for real foreground changes. The WinEvent hook is event-driven: no polling,
/// no CPU while idle. Our own process (panel, WebView2, menus, dialogs) is
/// skipped, so only another app taking the foreground dismisses the panel.
unsafe extern "system" fn on_foreground_changed(
    _hook: HWINEVENTHOOK,
    _event: u32,
    foreground: HWND,
    id_object: i32,
    _id_child: i32,
    _thread: u32,
    _time: u32,
) {
    if id_object != OBJID_WINDOW || foreground.is_null() {
        return;
    }
    let Some((app_handle, panel)) = BLUR_TARGET.get() else {
        return;
    };
    if unsafe { foreground_is_panel(foreground, *panel as HWND) } {
        return;
    }
    let Some(window) = app_handle.get_webview_window("main") else {
        return;
    };
    if window.is_visible().unwrap_or(false) {
        if let Ok(mut last) = LAST_BLUR_HIDE.lock() {
            *last = Some(Instant::now());
        }
        hide_window(&window);
    }
}

fn spawn_blur_watcher(app_handle: AppHandle, panel: usize) {
    if BLUR_TARGET.set((app_handle, panel)).is_err() {
        return;
    }
    thread::spawn(|| unsafe {
        let hook = SetWinEventHook(
            EVENT_SYSTEM_FOREGROUND,
            EVENT_SYSTEM_FOREGROUND,
            std::ptr::null_mut(),
            Some(on_foreground_changed),
            0,
            0,
            WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS,
        );
        if hook.is_null() {
            log::error!(
                "SetWinEventHook failed ({}); click-away will not dismiss the panel",
                std::io::Error::last_os_error()
            );
            return;
        }
        // Out-of-context WinEvents are delivered through this thread's message queue.
        let mut msg: MSG = std::mem::zeroed();
        while GetMessageW(&mut msg, std::ptr::null_mut(), 0, 0) > 0 {
            DispatchMessageW(&msg);
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
        // reports, clamped by `popover_geometry` (320 pt wide like the macOS panel).
        let _ = window.set_min_size(Some(tauri::Size::Logical(tauri::LogicalSize {
            width: popover_geometry::PANEL_WIDTH,
            height: popover_geometry::MINIMUM_HEIGHT,
        })));
        let _ = window.set_size(tauri::Size::Logical(tauri::LogicalSize {
            width: popover_geometry::PANEL_WIDTH,
            height: popover_geometry::DEFAULT_HEIGHT,
        }));

        let handle = app_handle.clone();
        window.on_window_event(move |event| {
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                api.prevent_close();
                hide_panel(&handle);
            }
        });

        if let Ok(hwnd) = window.hwnd() {
            watch_power_resume(hwnd.0 as HWND, app_handle.clone());
            spawn_blur_watcher(app_handle.clone(), hwnd.0 as usize);
        }
    }

    Ok(())
}
