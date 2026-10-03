import AppKit
import KeyboardShortcuts
import SwiftUI

/// The dashboard's host window: a borderless, **non-activating** panel that can still become key.
///
/// This is the fix for `NSPopover`'s fundamental limitation in a menu-bar accessory app. A popover's
/// window is only key while the whole app is active, and activating an `LSUIElement` app is
/// asynchronous — on macOS 26+ it lands several runloop ticks later or is denied — so the popover is
/// on-screen but not key, the keystroke goes to the focused status-item button instead (Enter
/// re-toggles it shut; Esc is lost), and you need a second click/keypress. A `.nonactivatingPanel`
/// whose `canBecomeKey` is `true` becomes key the instant it's ordered front, *without* activating the
/// app, so keyboard input (Esc/Return navigation, the Settings shortcut recorder) works on the first
/// try. (The pattern keyboard-first menu-bar apps use; cross-checked via GitHits.)
final class MenuBarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The single QuotaBar menu-bar entry. Its strip is the aggregate of the currently pinned metrics,
/// including multiple Codex account cards and Cursor when those providers have data.
@MainActor
private final class MenuBarStatusItem {
    let statusItem: NSStatusItem
    let imageUpdater: StatusItemImageUpdater

    init(container: AppContainer) {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem = statusItem
        self.imageUpdater = StatusItemImageUpdater(
            container: container
        ) { image in
            statusItem.button?.image = image
        }
    }
}

/// Owns the shared dashboard panel and the menu-bar status items.
///
/// The panel and strip are deliberately aggregate: one click target opens one dashboard containing all
/// enabled provider groups, so two Codex accounts and Cursor stay visible together. Multiple status items
/// would split the same usage surface, make one account look like a duplicate app, and force account-local
/// focus state into a menu-bar interaction that should be a single predictable action.
/// Deliberately not SwiftUI's `MenuBarExtra`: its `.window` panel never became a proper key window for
/// text input (the Settings shortcut recorder silently ignored key presses) and there is no public API
/// to present it programmatically. A plain `NSStatusItem` + a key-capable `NSPanel` gives a real key
/// window and a real show/hide pair the global shortcut can call directly.
@MainActor
final class StatusItemController: NSObject {
    private let container: AppContainer
    private let statusItems: [MenuBarStatusItem]
    private let panel: MenuBarPanel
    private let heightController: PanelHeightController
    private lazy var outsideClickMonitor = PanelOutsideClickMonitor(
        panel: panel,
        statusItems: statusItems.map { $0.statusItem },
        isMorphing: { [weak self] in self?.heightController.isMorphing ?? false },
        onInsidePanelClick: { [weak self] in self?.clearStrayFocus() },
        onDismiss: { [weak self] in self?.hidePanel() }
    )
    private let hostingController: NSHostingController<AnyView>
    /// The panel's backdrop: an opaque tray by default, swapped to a behind-window vibrancy view when
    /// the transparency style is non-opaque. Built once and toggled, so it can't race the style observer.
    private let backdrop = PopoverBackdropView(cornerRadius: StatusItemController.cornerRadius)
    /// Token for the appearance-change observer; held to follow the documented removal pattern.
    private var appearanceObserver: NSObjectProtocol?
    /// The refresh fired by the most recent popover open, so a close can cancel it and a reopen can
    /// supersede it instead of leaving a trail of un-cancellable batches.
    private var popoverRefreshTask: Task<Void, Never>?
    /// Corner radius of the panel surface; tuned to read like a system menu-bar popover.
    private static let cornerRadius: CGFloat = 13

    init(container: AppContainer) {
        self.container = container

        self.statusItems = Self.statusItemScopes().map { _ in MenuBarStatusItem(container: container) }

        // Start with an empty host so the dashboard Observation graph is not kept alive while the
        // panel is closed (same class of leak as japananh/aimonitor#88). Real content is attached
        // lazily in `showPanel` and torn down again in `hidePanel`.
        let hosting = NSHostingController(rootView: AnyView(EmptyView()))
        // The host view fills the panel. SwiftUI measures each screen and drives the panel height;
        // content scrolls only when that height reaches the available-screen limit.
        self.hostingController = hosting

        let panel = MenuBarPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: PanelHeightController.panelWidth,
                height: PanelHeightController.defaultHeight
            ),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        self.panel = panel
        self.heightController = PanelHeightController(panel: panel) { container.layout.screen }

        super.init()

        configurePanel()
        configureStatusItems()
        statusItems.forEach { $0.imageUpdater.update() }
        applyTransparency()

        appearanceObserver = NotificationCenter.default.addObserver(
            forName: AppearanceSetting.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.panel.appearance = AppearanceSetting.current.nsAppearance
            }
        }
        // Registered once here; the controller lives for the app's whole life.
        KeyboardShortcuts.onKeyUp(for: .togglePopover) { [weak self] in
            AppLog.info(.statusItem, "Global shortcut fired; toggling popover")
            self?.togglePopover()
        }

        // Esc on the dashboard dismisses through the same code path as a status-item click.
        MenuBarPopover.dismissHandler = { [weak self] in
            self?.hidePanel()
        }
        MenuBarPopover.showHandler = { [weak self] in
            guard let self else { return }
            if self.panel.isVisible {
                // Already open on Customize/Settings: navigate home with the normal slide.
                self.container.layout.screen = .dashboard
            } else {
                // Cold open after EmptyView remount — never bump `screenSlideID` into a fresh view.
                self.container.layout.resetForPopoverClose()
            }
            self.showPopover()
        }

        heightController.installBridge()

        AppLog.info(
            .statusItem,
            "Status item ready (count: \(self.statusItems.count), buttons: \(self.statusItems.filter { $0.statusItem.button != nil }.count), shortcut: \(KeyboardShortcuts.getShortcut(for: .togglePopover)?.description ?? "none"))"
        )
    }

    /// There is exactly one QuotaBar status item. Provider/account multiplicity belongs inside the
    /// aggregate strip and dashboard, not in the macOS status-bar item graph.
    static func statusItemScopes() -> [String?] { [nil] }

    /// Tears down the current status-item graph before AppContainer is rebuilt after a newly added
    /// Codex account. Explicit cleanup prevents a transient duplicate menu-bar item and leaves no
    /// event monitor or panel-height bridge pointing at the retired controller.
    func tearDown() {
        if panel.isVisible {
            hidePanel()
        } else {
            outsideClickMonitor.stop()
            heightController.finishClosing()
        }
        appearanceObserver.map(NotificationCenter.default.removeObserver)
        appearanceObserver = nil
        // The account-registration reload creates a new controller in the same process. Remove the
        // old callback before the replacement registers, otherwise one shortcut press toggles twice.
        KeyboardShortcuts.removeHandler(for: .togglePopover)
        MenuBarPopover.dismissHandler = nil
        MenuBarPopover.showHandler = nil
        MenuBarPopover.applyHeight = nil
        MenuBarPopover.clampHeight = nil
        for entry in statusItems {
            entry.statusItem.menu = nil
            NSStatusBar.system.removeStatusItem(entry.statusItem)
        }
        panel.close()
    }

    // MARK: - Panel configuration

    private func configurePanel() {
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.hasShadow = true
        panel.isMovable = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Pin the theme override (nil for System) so the menu bar's appearance doesn't win; tracked
        // live by `appearanceObserver`.
        panel.appearance = AppearanceSetting.current.nsAppearance

        let container = NSView()

        // Backdrop: by default an opaque tray so the data region never shows the desktop through it
        // (Liquid Glass stays reserved for the footer chrome, rendered in-window over this backing). The
        // `PopoverBackdropView` also holds a behind-window vibrancy layer that the transparency style
        // swaps in for Increase Transparency / the secret-code egg. It fills the whole window, so a
        // screen-switch resize can't reveal a transparent strip, and any region SwiftUI leaves unpainted
        // shows the backdrop, not a raw hole. Its opaque tray is `Theme.trayNSColor` (tracks light/dark
        // and the forced appearance override) matching the SwiftUI tray (`DashboardView.PopoverSurface`),
        // rounded via `cornerRadius`. `panel.appearance` (tracked by `appearanceObserver`) pins the mode.
        let host = hostingController.view
        host.translatesAutoresizingMaskIntoConstraints = false
        host.wantsLayer = true
        // Redraw the SwiftUI content on every step of a height change instead of stretching the layer's
        // cached contents (the default `.onSetNeedsDisplay`), which keeps cards steady during a morph.
        host.layerContentsRedrawPolicy = .duringViewResize
        host.layer?.cornerRadius = Self.cornerRadius
        host.layer?.cornerCurve = .continuous
        host.layer?.masksToBounds = true

        container.addSubview(backdrop)
        container.addSubview(host, positioned: .above, relativeTo: backdrop)
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: container.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.topAnchor.constraint(equalTo: container.topAnchor),
            host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        // A plain container VC owns the backdrop; the hosting controller is its child so SwiftUI gets
        // a proper view-controller hierarchy. Panel placement and height live in `heightController`.
        let rootVC = NSViewController()
        rootVC.view = container
        rootVC.addChild(hostingController)
        panel.contentViewController = rootVC
    }

    private func configureStatusItems() {
        for entry in statusItems {
            guard let button = entry.statusItem.button else { continue }
            button.target = self
            button.action = #selector(statusButtonClicked(_:))
            // Left-click toggles the shared popover; right-click (or control-click) drops the native
            // context menu for this exact item.
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "QuotaBar"
            button.setAccessibilityLabel("QuotaBar — usage dashboard")
        }
    }

    // MARK: - Transparency

    /// True once the launch application has run, so subsequent style changes animate (the first one
    /// shouldn't fade in from nothing).
    private var hasAppliedTransparency = false

    /// Applies the resolved transparency style to the panel and re-arms on the next change. Mirrors
    /// `StatusItemImageUpdater.update()`'s `withObservationTracking` re-arm (its `onChange` is
    /// one-shot). Reads the
    /// store's `effectiveStyle`, which folds in the persisted toggle, the egg state, and the system
    /// accessibility flags — so this fires whenever any of them changes. Backdrop already exists (it's a
    /// stored property), so the first call from `init` safely sets the initial look.
    ///
    /// On every change after launch the window alpha and the backdrop crossfade ease together in one
    /// ~0.55s group, matching the SwiftUI side (`tooMuchTransparency`'s `.animation`), so toggling the
    /// egg or Increase Transparency fades in and out instead of snapping.
    private func applyTransparency() {
        let style = withObservationTracking {
            container.transparency.effectiveStyle
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.applyTransparency()
            }
        }
        let mode: PopoverBackdropView.Mode = style.surfaceTreatment == .opaque ? .opaque : .translucent
        let shouldAnimate = hasAppliedTransparency && !ReduceAnimationsSetting.isEnabled
        hasAppliedTransparency = true
        if shouldAnimate {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.55
                context.allowsImplicitAnimation = true
                panel.animator().alphaValue = style.windowAlpha
                backdrop.setMode(mode, animated: true)
            }
        } else {
            panel.alphaValue = style.windowAlpha
            backdrop.setMode(mode, animated: false)
        }
        // Shadow isn't animatable; set it directly (the crossfade masks the change).
        panel.hasShadow = style.wantsShadow
        panel.invalidateShadow()
    }

    // MARK: - Show / hide

    private var selectedMenuBarItem: MenuBarStatusItem? { statusItems.first }

    private func menuBarItem(for sender: Any?) -> MenuBarStatusItem? {
        guard let button = sender as? NSStatusBarButton else { return nil }
        return statusItems.first { $0.statusItem.button === button }
    }

    /// Shared factory for the visible dashboard tree. Used on every `showPanel` so hide/show rebuilds
    /// the same environment injection the panel had historically at init time.
    private func makeDashboardRootView() -> AnyView {
        AnyView(
            DashboardView()
                .reduceAnimationsWhenRequested()
                .environment(container)
                .environment(container.layout)
                .environment(container.dataStore)
                .environment(container.transparency)
                .environment(\.codexResetClaim, container.codexResetClaim)
        )
    }

    @objc private func statusButtonClicked(_ sender: Any?) {
        guard let entry = menuBarItem(for: sender) else {
            AppLog.error(.statusItem, "Status item action arrived without a known sender")
            return
        }
        let event = NSApp.currentEvent
        let isContextClick = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true
        if isContextClick {
            showContextMenu(for: entry)
        } else {
            togglePopover(for: entry)
        }
    }

    /// Right-click / control-click on the status item: a native menu mirroring the Settings and Quit
    /// items in the popover footer's Options menu (same titles, symbols, and ⌘ shortcuts).
    private func showContextMenu(for entry: MenuBarStatusItem) {
        // The context menu is a distinct gesture from the left-click popover: close an open panel
        // first so the menu opens over a clean state (no leftover button highlight, no live
        // outside-click monitors racing the menu's own modal tracking).
        if panel.isVisible { hidePanel() }

        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "Settings", systemSymbol: "gearshape", keyEquivalent: ",") { [weak self] in
            self?.openSettings(anchoredTo: entry)
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Quit QuotaBar", systemSymbol: "power", keyEquivalent: "q") {
            NSApplication.shared.terminate(nil)
        })

        entry.statusItem.menu = menu
        entry.statusItem.button?.performClick(nil)
        entry.statusItem.menu = nil
    }

    /// Opens the dashboard popover on the Settings screen — Settings is an in-popover screen, not a
    /// separate window. The screen is set before showing the panel so it opens already sized to Settings,
    /// but **without** bumping `screenSlideID` (EmptyView remount starts `animatedSlideID` at 0).
    private func openSettings(anchoredTo entry: MenuBarStatusItem? = nil) {
        container.layout.presentWithoutSlide(.settings)
        if !panel.isVisible {
            showPanel(below: entry)
        }
    }

    func togglePopover() {
        if panel.isVisible {
            hidePanel()
        } else {
            showPanel(below: selectedMenuBarItem)
        }
    }

    private func togglePopover(for entry: MenuBarStatusItem) {
        if panel.isVisible {
            hidePanel()
        } else {
            showPanel(below: entry)
        }
    }

    /// Opens the dashboard panel without toggling it shut when already visible — used when an external
    /// trigger (a tapped pace notification) should surface the popover.
    func showPopover() {
        if panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
            highlight(selectedMenuBarItem)
            return
        }
        showPanel(below: selectedMenuBarItem)
    }

    private func showPanel(below entry: MenuBarStatusItem? = nil) {
        let anchor = entry ?? selectedMenuBarItem ?? statusItems.first
        guard let button = anchor?.statusItem.button, let buttonWindow = button.window else {
            AppLog.error(.statusItem, "Cannot show panel: status item has no button")
            return
        }
        let buttonRectOnScreen = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        // Record the display before changing the visibility signal. That signal makes SwiftUI
        // immediately clamp the measured height; without the display anchor the clamp falls back to
        // the fixed opening guess, making large and small displays open at the same height.
        heightController.prepareForOpening(below: buttonRectOnScreen)

        // Rebuild the dashboard tree only while visible. A closed panel keeps EmptyView so Observation
        // objects cannot accumulate off-screen for hours. Attach the host *before* flipping
        // `popoverShown` so DashboardView's onChange/onAppear observers are subscribed when the
        // visibility signal rises (otherwise a same-runloop flip is missed and height/egg seeding
        // depends only on later geometry).
        hostingController.rootView = makeDashboardRootView()

        // Mark the popover on-screen after the dashboard mounts, so the egg's animation loops and the
        // height re-seed path see the rising edge. Read by the SwiftUI egg via `\.popoverIsVisible`;
        // a closed popover keeps the loops unmounted, so a left-on egg costs no CPU.
        container.transparency.setPopoverShown(true)

        // Opening the panel: pull full token/spend/history immediately so the user never waits
        // up to the background interval (or a menuBar-only pass) to see spend rows.
        //
        // Held so `hidePanel` can cancel it. It was previously fire-and-forget, so a user opening and
        // closing the panel repeatedly left one un-cancellable batch per open behind — the tasks the
        // per-provider forced-wait path then piled onto. Reopening supersedes the previous open anyway.
        popoverRefreshTask?.cancel()
        popoverRefreshTask = Task {
            await withThrottledFullAccounting {
                await container.dataStore.refreshAll(force: true)
            }
        }

        // Lay the content out first so the panel opens at the right size (no first-frame flash).
        hostingController.view.layoutSubtreeIfNeeded()

        // `canBecomeKey` + `.nonactivatingPanel` makes this key without activating the app — no
        // activation race, so the dashboard receives keys on the first try.
        panel.makeKeyAndOrderFront(nil)
        // Becoming key, AppKit auto-focuses the first control in the key-view loop (the first row's
        // Used/Left toggle) when system Keyboard Navigation is on — so the popover would open with a
        // stray focus ring nobody asked for. Drop it; keyboard nav still works (it rides a local key
        // monitor, not first responder), and Tab from here focuses the first control as expected.
        clearStrayFocus()
        highlight(anchor)
        outsideClickMonitor.start()
    }

    private func highlight(_ entry: MenuBarStatusItem?) {
        for item in statusItems {
            item.statusItem.button?.highlight(item === entry)
        }
    }

    private func hidePanel() {
        // Stop the open's refresh: nobody is looking at the result any more, and leaving it running
        // meant every open/close cycle added another un-cancellable batch.
        popoverRefreshTask?.cancel()
        popoverRefreshTask = nil
        // Dismiss hover surfaces before tearing the dashboard host down to EmptyView — a tooltip the
        // cursor was resting on otherwise gets no hover-exit and can orphan on screen. Same for the
        // Usage Trend AppKit hover popover.
        HoverTooltips.dismissAll()
        HoverPopoverState.dismissAll()
        ReducedMotionPopoverController.dismissAll()
        // Same survival problem for keyboard focus: a clicked plain-styled control (a row's Used/Left
        // or reset toggle) stays first responder, so its focus ring would reopen with the popover as a
        // stray blue outline. Drop it on close so every reopen starts unfocused.
        clearStrayFocus()
        // Save while the closing screen is still current (Customize/Settings height must not be
        // attributed to dashboard). Then silently reset navigation *before* flipping visibility /
        // EmptyView so `resetTransientState` never assigns `screen` through the slide-bumping path.
        heightController.saveBeforeClosing()
        container.layout.resetForPopoverClose()
        // Closing: drop the on-screen flag so the egg's animation loops unmount their `TimelineView`
        // clocks and stop ticking — the whole point of the gate (no CPU while the egg is left on but the
        // popover is hidden). This is the authoritative hide signal, flipped synchronously with `orderOut`.
        container.transparency.setPopoverShown(false)
        // Detach the dashboard so no SwiftUI view keeps observing AppModel / WidgetDataStore while the
        // panel is ordered out. Keep the NSPanel itself for fast reopen.
        hostingController.rootView = AnyView(EmptyView())
        panel.orderOut(nil)
        outsideClickMonitor.stop()
        highlight(nil)
        heightController.finishClosing()
    }

    /// Drops keyboard focus inside the panel so a clicked plain-styled control (a metric row's
    /// Used/Left + reset toggles) doesn't keep the system focus ring lingering as a stray outline:
    /// AppKit leaves the control first responder until focus moves, which a click on empty space or a
    /// close otherwise never does. Skips a live text field / shortcut recorder, whose focus is the
    /// user's intent — mirrors the `NSText` guard `PopoverKeyReader` uses for the same reason.
    private func clearStrayFocus() {
        guard !ShortcutRecorderField.isRecordingActive,
              !(panel.firstResponder is NSText) else { return }
        panel.makeFirstResponder(nil)
    }

}
