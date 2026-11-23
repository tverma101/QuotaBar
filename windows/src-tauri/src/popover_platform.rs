//! Window placement for tray-style popovers on Windows / Linux.
//!
//! **Linux (AppIndicator):** tray icon events often never populate `tauri-plugin-positioner`'s
//! internal state before the user opens the menu, and the plugin **panics** with
//! `"Tray position not set"` for `TrayCenter`. We **do not** use `TrayCenter` on Linux.
//!
//! **Windows:** [`place_windows_panel`] anchors to the tray icon rect with the macOS panel
//! geometry (`popover_geometry`), falling back to the bottom-right of the work area.
//!
//! Call [`move_main_near_tray`] only **after** [`WebviewWindow::show`](tauri::WebviewWindow::show)
//! so `current_monitor()` is usually available.

use tauri::{AppHandle, Manager};

#[cfg(target_os = "linux")]
use gtk::gdk::{self, prelude::*};
#[cfg(any(target_os = "linux", target_os = "windows"))]
use tauri::{PhysicalPosition, Runtime, WebviewWindow};

/// Move the main window using tray geometry from `on_tray_event`, constrained to the work area.
/// Must run **after** `show()`.
pub fn move_main_near_tray(app: &AppHandle) {
    let Some(window) = app.get_webview_window("main") else {
        return;
    };

    if window.current_monitor().ok().flatten().is_none() {
        log::debug!("popover: no current monitor; centering");
        let _ = window.center();
        return;
    }

    #[cfg(target_os = "linux")]
    {
        place_linux_pointer_popover(&window);
        return;
    }

    #[cfg(target_os = "windows")]
    {
        let _ = place_windows_panel(app, &window, None);
    }
}

/// Linux AppIndicator does not reliably expose tray geometry, so anchor the popover near the
/// current pointer/menu position and clamp it to the monitor work area.
#[cfg(target_os = "linux")]
fn place_linux_pointer_popover<R: Runtime>(window: &WebviewWindow<R>) {
    let Ok(outer) = window.outer_size() else {
        let _ = window.center();
        return;
    };

    let Some(display) = gdk::Display::default() else {
        log::debug!("popover: no GDK display; centering");
        let _ = window.center();
        return;
    };

    let Some(pointer) = display.default_seat().and_then(|seat| seat.pointer()) else {
        log::debug!("popover: no pointer device; centering");
        let _ = window.center();
        return;
    };

    let (_, pointer_x, pointer_y) = pointer.position();
    let Some(monitor) = display.monitor_at_point(pointer_x, pointer_y) else {
        log::debug!("popover: no monitor at pointer; centering");
        let _ = window.center();
        return;
    };

    let workarea = monitor.workarea();
    let margin = 12i32;
    let width = outer.width as i32;
    let height = outer.height as i32;
    let min_x = workarea.x() + margin;
    let max_x = workarea.x() + workarea.width() - width - margin;
    let x = (pointer_x - (width / 2)).clamp(min_x, max_x.max(min_x));

    let workarea_mid_y = workarea.y() + (workarea.height() / 2);
    let prefer_top_anchor = pointer_y <= workarea_mid_y;
    let y = if prefer_top_anchor {
        workarea.y() + margin
    } else {
        workarea.y() + workarea.height() - height - margin
    };

    let _ = window.set_position(PhysicalPosition::new(x, y));
}

/// Size and anchor the panel to the tray icon with the macOS panel rules
/// (`popover_geometry`): fixed width, gap from the anchor, screen margin and the
/// height clamp. `requested_height` is the content height in logical points;
/// `None` keeps the current height. The edge nearest the tray stays fixed, so a
/// height change grows away from the taskbar without moving the anchor.
#[cfg(target_os = "windows")]
pub fn place_windows_panel<R: Runtime>(
    app: &AppHandle<R>,
    window: &WebviewWindow<R>,
    requested_height: Option<f64>,
) -> Option<f64> {
    use crate::popover_geometry::{panel_frame, Rect, DEFAULT_HEIGHT};
    use tauri::PhysicalSize;

    let tray_rect = app
        .tray_by_id("tray")
        .and_then(|tray| tray.rect().ok().flatten())
        .map(|rect| {
            let position = rect.position.to_physical::<f64>(1.0);
            let size = rect.size.to_physical::<f64>(1.0);
            Rect::new(position.x, position.y, size.width, size.height)
        })
        .filter(|rect| rect.width > 0.0 && rect.height > 0.0);

    let monitor = tray_rect
        .and_then(|rect| {
            app.monitor_from_point(rect.x + rect.width / 2.0, rect.y + rect.height / 2.0)
                .ok()
                .flatten()
        })
        .or_else(|| window.current_monitor().ok().flatten())
        .or_else(|| window.primary_monitor().ok().flatten());
    let Some(monitor) = monitor else {
        log::warn!("popover: no monitor for the QuotaBar panel; centering");
        let _ = window.center();
        return None;
    };
    let scale = monitor.scale_factor();
    let area = monitor.work_area();
    let work = Rect::new(
        f64::from(area.position.x),
        f64::from(area.position.y),
        f64::from(area.size.width),
        f64::from(area.size.height),
    );
    let height = requested_height.unwrap_or_else(|| {
        window
            .inner_size()
            .map(|size| f64::from(size.height) / window.scale_factor().unwrap_or(scale))
            .unwrap_or(DEFAULT_HEIGHT)
    });
    let frame = panel_frame(tray_rect, work, scale, height);
    // Position first so a monitor change applies the target DPI before sizing.
    let position = PhysicalPosition::new(frame.x.round() as i32, frame.y.round() as i32);
    if let Err(error) = window.set_position(position) {
        log::warn!("popover: cannot position the QuotaBar panel: {error}");
    }
    let size = PhysicalSize::new(frame.width as u32, frame.height as u32);
    if window.inner_size().ok() != Some(size) {
        if let Err(error) = window.set_size(size) {
            log::warn!("popover: cannot size the QuotaBar panel: {error}");
        }
        let _ = window.set_position(position);
    }
    Some(panel_frame(tray_rect, work, scale, f64::INFINITY).height / scale)
}
