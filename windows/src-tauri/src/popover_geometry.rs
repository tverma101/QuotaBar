//! Pure popover geometry shared by the Windows shell, mirroring the macOS
//! `PanelHeightController` / `PanelGeometry` rules: fixed 320 pt width, a 4 pt gap
//! from the tray anchor, an 8 pt screen margin, a 200 pt minimum height and a
//! maximum of the room beside the anchor or 85% of the work area, whichever is
//! smaller. Windows can put the taskbar on any edge, so the panel opens away
//! from whichever edge holds the tray. All values are physical pixels.

pub const PANEL_WIDTH: f64 = 320.0;
pub const DEFAULT_HEIGHT: f64 = 800.0;
pub const MINIMUM_HEIGHT: f64 = 200.0;
pub const ANCHOR_GAP: f64 = 4.0;
pub const SCREEN_MARGIN: f64 = 8.0;
pub const MAX_HEIGHT_FRACTION: f64 = 0.85;

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl Rect {
    pub fn new(x: f64, y: f64, width: f64, height: f64) -> Self {
        Self { x, y, width, height }
    }
    fn right(&self) -> f64 {
        self.x + self.width
    }
    fn bottom(&self) -> f64 {
        self.y + self.height
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TaskbarEdge {
    Bottom,
    Top,
    Left,
    Right,
}

/// The edge the tray sits on. A tray outside the work area is on the taskbar;
/// one inside it (auto-hide taskbar, overflow flyout) uses the nearest edge.
pub fn taskbar_edge(tray: Rect, work: Rect) -> TaskbarEdge {
    if tray.y >= work.bottom() {
        return TaskbarEdge::Bottom;
    }
    if tray.bottom() <= work.y {
        return TaskbarEdge::Top;
    }
    if tray.right() <= work.x {
        return TaskbarEdge::Left;
    }
    if tray.x >= work.right() {
        return TaskbarEdge::Right;
    }
    let cx = tray.x + tray.width / 2.0;
    let cy = tray.y + tray.height / 2.0;
    let distances = [
        (work.bottom() - cy, TaskbarEdge::Bottom),
        (cy - work.y, TaskbarEdge::Top),
        (cx - work.x, TaskbarEdge::Left),
        (work.right() - cx, TaskbarEdge::Right),
    ];
    distances
        .iter()
        .fold(distances[0], |best, d| if d.0 < best.0 { *d } else { best })
        .1
}

/// Final panel frame for a requested content height (logical points) at `scale`.
/// Without a tray rect the panel opens at the bottom-right of the work area.
pub fn panel_frame(tray: Option<Rect>, work: Rect, scale: f64, requested_height: f64) -> Rect {
    let scale = if scale.is_finite() && scale > 0.0 { scale } else { 1.0 };
    let width = (PANEL_WIDTH * scale).round();
    let gap = ANCHOR_GAP * scale;
    let margin = SCREEN_MARGIN * scale;
    let requested = if requested_height.is_nan() {
        DEFAULT_HEIGHT
    } else {
        requested_height
    };
    let tray = tray.unwrap_or(Rect::new(work.right() - margin, work.bottom(), 0.0, 0.0));
    let edge = taskbar_edge(tray, work);
    let aesthetic_cap = (work.height * MAX_HEIGHT_FRACTION).floor();

    let clamp_x = |x: f64| x.min(work.right() - width - margin).max(work.x + margin);
    let clamp_y = |y: f64, h: f64| y.min(work.bottom() - h - margin).max(work.y + margin);
    let height_for = |room: f64| {
        let max = room.min(aesthetic_cap).max(1.0);
        (requested * scale).max(MINIMUM_HEIGHT * scale).min(max).round()
    };

    match edge {
        TaskbarEdge::Bottom => {
            let anchor = tray.y.min(work.bottom()) - gap;
            let height = height_for(anchor - work.y - margin);
            Rect::new(clamp_x(tray.x), anchor - height, width, height)
        }
        TaskbarEdge::Top => {
            let anchor = tray.bottom().max(work.y) + gap;
            let height = height_for(work.bottom() - margin - anchor);
            Rect::new(clamp_x(tray.x), anchor, width, height)
        }
        TaskbarEdge::Left => {
            let height = height_for(work.height - 2.0 * margin);
            let x = tray.right().max(work.x) + gap;
            Rect::new(x, clamp_y(tray.y, height), width, height)
        }
        TaskbarEdge::Right => {
            let height = height_for(work.height - 2.0 * margin);
            let x = tray.x.min(work.right()) - gap - width;
            Rect::new(x, clamp_y(tray.y, height), width, height)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // 1920x1080 primary with a 48 px bottom taskbar.
    const WORK: Rect = Rect { x: 0.0, y: 0.0, width: 1920.0, height: 1032.0 };

    #[test]
    fn bottom_taskbar_opens_above_the_icon_with_mac_gap_and_margin() {
        let tray = Rect::new(1700.0, 1040.0, 24.0, 32.0);
        let frame = panel_frame(Some(tray), WORK, 1.0, 500.0);
        assert_eq!(frame, Rect::new(1592.0, 1032.0 - 4.0 - 500.0, 320.0, 500.0));
    }

    #[test]
    fn width_is_fixed_and_scales_with_dpi() {
        let work = Rect::new(0.0, 0.0, 2880.0, 1548.0);
        let tray = Rect::new(2500.0, 1560.0, 36.0, 48.0);
        let frame = panel_frame(Some(tray), work, 1.5, 400.0);
        assert_eq!(frame.width, 480.0);
        assert_eq!(frame.height, 600.0);
        assert_eq!(frame.x, 2880.0 - 480.0 - 12.0);
        assert_eq!(frame.y + frame.height, 1548.0 - 6.0);
    }

    #[test]
    fn height_clamps_to_minimum_and_eighty_five_percent() {
        let tray = Rect::new(1700.0, 1040.0, 24.0, 32.0);
        assert_eq!(panel_frame(Some(tray), WORK, 1.0, 50.0).height, 200.0);
        assert_eq!(panel_frame(Some(tray), WORK, 1.0, 5000.0).height, 877.0);
    }

    #[test]
    fn top_taskbar_opens_below() {
        let work = Rect::new(0.0, 48.0, 1920.0, 1032.0);
        let tray = Rect::new(100.0, 8.0, 24.0, 32.0);
        let frame = panel_frame(Some(tray), work, 1.0, 300.0);
        assert_eq!(frame, Rect::new(100.0, 52.0, 320.0, 300.0));
    }

    #[test]
    fn side_taskbars_open_beside_and_stay_on_screen() {
        let left_work = Rect::new(62.0, 0.0, 1858.0, 1080.0);
        let tray = Rect::new(15.0, 1000.0, 32.0, 24.0);
        let frame = panel_frame(Some(tray), left_work, 1.0, 400.0);
        assert_eq!(frame.x, 66.0);
        assert_eq!(frame.y, 1080.0 - 400.0 - 8.0);

        let right_work = Rect::new(0.0, 0.0, 1858.0, 1080.0);
        let tray = Rect::new(1873.0, 20.0, 32.0, 24.0);
        let frame = panel_frame(Some(tray), right_work, 1.0, 400.0);
        assert_eq!(frame.x, 1858.0 - 4.0 - 320.0);
        assert_eq!(frame.y, 20.0);
    }

    #[test]
    fn auto_hide_tray_inside_work_area_uses_nearest_edge() {
        let work = Rect::new(0.0, 0.0, 1920.0, 1080.0);
        let tray = Rect::new(1700.0, 1076.0, 24.0, 4.0);
        assert_eq!(taskbar_edge(tray, work), TaskbarEdge::Bottom);
    }

    #[test]
    fn missing_tray_rect_opens_bottom_right() {
        let frame = panel_frame(None, WORK, 1.0, 400.0);
        assert_eq!(frame, Rect::new(1920.0 - 320.0 - 8.0, 1032.0 - 4.0 - 400.0, 320.0, 400.0));
    }

    #[test]
    fn secondary_monitor_offsets_are_respected() {
        let work = Rect::new(-1280.0, 0.0, 1280.0, 984.0);
        let tray = Rect::new(-200.0, 990.0, 24.0, 32.0);
        let frame = panel_frame(Some(tray), work, 1.0, 400.0);
        assert_eq!(frame.x, -320.0 - 8.0);
    }
}
