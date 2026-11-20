import Foundation

/// Drives a hover-revealed popover (the usage-trend chart on sparkline rows, the model breakdown on
/// spend rows): opens after a short dwell while the inline row is hovered, and closes once the cursor
/// has left BOTH the row and the popover (a brief grace lets the cursor travel between them). An
/// `@Observable` reference type so a SwiftUI `View` can hold it in `@State` and bind `isPresented` to
/// the popover — value-type closure capture can't track this state reliably.
@MainActor
@Observable
final class HoverPopoverState {
    var isPresented = false

    /// Every live coordinator, so the menu-bar panel's close path can dismiss any open hover popover —
    /// the dashboard view tree (and this `@State`) survives the panel's `orderOut`, so `.onDisappear`
    /// alone wouldn't fire and the popover could orphan or re-show on the next open.
    @ObservationIgnored private static let live = NSHashTable<HoverPopoverState>.weakObjects()

    static func dismissAll() {
        for state in live.allObjects { state.dismiss() }
    }

    /// Whether the pointer is over the inline row/value. Unlike the rest of the hover bookkeeping this
    /// is observed and readable, so a view can drive a hover affordance (the value's highlight chip) off
    /// it. Crucially, `dismiss()` clears it, so `dismissAll()` on panel close clears the affordance too —
    /// the dashboard view tree (and a view's own `@State`) survives the panel's `orderOut`, so a plain
    /// `@State` flag would strand `true` and light the chip with no pointer over the value on reopen.
    private(set) var overInline = false
    @ObservationIgnored private var overDetail = false
    /// While pinned, the popover stays open regardless of cursor position — set during a multi-step
    /// interaction inside the popover (the resets claim confirm/in-flight flow) where a cursor slip
    /// outside must not tear the flow down. `dismiss()` still wins (panel close), and clearing it
    /// re-arms the normal hover-out hide. Readable (`isPinned`) so data-driven dismissals — the row's
    /// "credits changed under the popover" onChange — can stand down while the claim flow owns the
    /// popover: the claim itself changes the credits, and dismissing on that change would tear the
    /// popover down before its result ever renders.
    @ObservationIgnored private var pinned = false
    var isPinned: Bool { pinned }
    @ObservationIgnored private var showTask: Task<Void, Never>?
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    /// When the popover last force-closed, for `presentForTap`'s just-dismissed guard. A dismiss
    /// delivered moments before a tap (a data refresh replacing the breakdown under the pointer, the
    /// panel's close path) would otherwise let that tap read "not presented" and immediately re-open
    /// what was just shut.
    @ObservationIgnored private var lastDismissAt: ContinuousClock.Instant?
    /// How long a tap after a dismissal is treated as the tail of that close rather than a fresh
    /// open request. It only needs to cover event-delivery slack; re-opening by tapping right after
    /// a hover-out close is practically impossible anyway — the cursor had to leave the value
    /// (`overInline` false at the close) and come back.
    private static let tapCloseGuardWindow: Duration = .milliseconds(250)

    /// 400ms reveal matches the app's hover-tooltip dwell (see `HoverTooltip`), so the popover opens on
    /// the same deliberate intent as every other hover affordance; 180ms grace lets the cursor cross
    /// from the row into the popover without it closing. Injectable so tests drive it without sleeps.
    private let revealDelay: Duration
    private let hideGrace: Duration

    init(revealDelay: Duration = .milliseconds(400), hideGrace: Duration = .milliseconds(180)) {
        self.revealDelay = revealDelay
        self.hideGrace = hideGrace
        Self.live.add(self)
    }

    func inlineHover(_ active: Bool) {
        // `onContinuousHover` fires every pointer-move frame; only mutate on a real transition so the
        // now-observed `overInline` doesn't post a change notification on every frame of a hover.
        if overInline != active { overInline = active }
        active ? scheduleShow() : scheduleHide()
    }

    /// Tap on the inline row: present immediately, with no reveal dwell.
    ///
    /// The value column is a small target, so a deliberate tap must not also outwait the 400 ms
    /// hover dwell (or risk the cursor having moved on before the reveal lands) — a tap is explicit
    /// intent, so it opens on the spot; tapping while a dwell is still pending skips the wait and
    /// opens now rather than dismissing. A tap only ever opens, never toggles shut: the popover
    /// disappearing under the tap that was meant to keep it reads as flaky. Dismissal belongs to
    /// the hover rules instead — leaving both the row and the popover hides it after the grace,
    /// another row's popover supersedes it, and the panel's close clears it outright. After a
    /// tap-present, the cursor sitting on the row keeps it open (`overInline` reads true).
    func presentForTap() {
        guard !isPresented else { return }
        // A programmatic close (data refresh, popover teardown) can precede a tap by moments —
        // treat that tap as the tail of the close, not a fresh open request.
        if let lastDismissAt, ContinuousClock.now - lastDismissAt < Self.tapCloseGuardWindow {
            return
        }
        showTask?.cancel()
        showTask = nil
        hideTask?.cancel()
        hideTask = nil
        overInline = true
        present()
    }

    func detailHover(_ inside: Bool) {
        overDetail = inside
        if inside { hideTask?.cancel(); hideTask = nil } else { scheduleHide() }
    }

    /// Pin (or unpin) the popover open across a deliberate in-popover interaction. Pinning cancels any
    /// pending hide; unpinning re-arms the normal hover-out grace so it closes once the cursor is away.
    func setPinned(_ active: Bool) {
        guard pinned != active else { return }
        pinned = active
        if active { hideTask?.cancel(); hideTask = nil } else { scheduleHide() }
    }

    /// Force the popover shut (popover/dashboard teardown), so it can't orphan on screen.
    func dismiss() {
        showTask?.cancel(); showTask = nil
        hideTask?.cancel(); hideTask = nil
        overInline = false
        overDetail = false
        pinned = false
        // Only a real close arms the post-dismiss tap guard — a dismiss on a row whose popover
        // never opened must not swallow the next deliberate tap.
        if isPresented { lastDismissAt = ContinuousClock.now }
        isPresented = false
    }

    /// Single choke point for becoming presented: one hover popover at a time. With in-panel taps no
    /// longer closing the popover (`NSPopover`'s behavior is `.applicationDefined` — see the
    /// presenter), two rows would otherwise stack details that only ever left on hover-out. A pinned
    /// popover (e.g. an in-flight reset claim) is never superseded — the pin exists precisely so
    /// pointer movement cannot tear down confirm/result UI.
    private func present() {
        isPresented = true
        for other in Self.live.allObjects where other !== self && other.isPresented && !other.isPinned {
            other.dismiss()
        }
    }

    private func scheduleShow() {
        hideTask?.cancel(); hideTask = nil
        guard !isPresented, showTask == nil else { return }
        let delay = revealDelay
        showTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            if overInline { present() }
            showTask = nil
        }
    }

    private func scheduleHide() {
        guard !pinned else { return }   // a pinned popover ignores hover-out until it's unpinned
        showTask?.cancel(); showTask = nil
        hideTask?.cancel()
        let delay = hideGrace
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            if !overInline, !overDetail, !pinned { isPresented = false }
            hideTask = nil
        }
    }
}
