import AppKit
import SwiftUI

extension View {
    /// SwiftUI's `.popover` exposes neither `NSPopover.animates` (reduced motion) nor
    /// `NSPopover.behavior`, and the default `.transient` behavior closes the popover on any click
    /// outside it — including taps elsewhere in the panel that were meant to keep it. Every hover
    /// popover therefore presents through the AppKit controller below; SwiftUI remains the source
    /// of truth through `isPresented`.
    func motionAwareHoverPopover<PopoverContent: View>(
        isPresented: Binding<Bool>,
        reduceAnimations: Bool,
        @ViewBuilder content: @escaping () -> PopoverContent
    ) -> some View {
        modifier(MotionAwareHoverPopoverModifier(
            isPresented: isPresented,
            reduceAnimations: reduceAnimations,
            popoverContent: content
        ))
    }
}

private struct MotionAwareHoverPopoverModifier<PopoverContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    let reduceAnimations: Bool
    @ViewBuilder let popoverContent: () -> PopoverContent

    func body(content: Content) -> some View {
        content.background {
            HoverPopoverPresenter(
                isPresented: $isPresented,
                reduceAnimations: reduceAnimations,
                popoverContent: popoverContent
            )
        }
    }
}

/// An invisible anchor that owns the AppKit presentation details SwiftUI does not expose:
/// `NSPopover.animates` and `.applicationDefined` behavior (the hover coordinator in
/// `HoverPopoverState` is the sole owner of dismissal — hover-out grace, single-popover
/// supersede, panel close).
private struct HoverPopoverPresenter<PopoverContent: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    let reduceAnimations: Bool
    @ViewBuilder let popoverContent: () -> PopoverContent

    func makeCoordinator() -> HoverPopoverController {
        HoverPopoverController(isPresented: $isPresented)
    }

    func makeNSView(context: Context) -> PopoverAnchorView {
        let view = PopoverAnchorView()
        view.onWindowChange = { [weak coordinator = context.coordinator, weak view] in
            guard let view else { return }
            coordinator?.synchronize(with: view)
        }
        return view
    }

    func updateNSView(_ nsView: PopoverAnchorView, context: Context) {
        context.coordinator.isPresented = $isPresented
        // Building the content (detail views, AnyView erasure) is only needed once actually
        // presented — building it while hidden re-erased the subtree on every row render of a
        // fresh dashboard mount. When not presented, just reconcile the close state.
        guard isPresented else {
            context.coordinator.synchronize(with: nsView)
            return
        }
        context.coordinator.update(
            content: AnyView(popoverContent()),
            reduceAnimations: reduceAnimations,
            anchor: nsView
        )
    }

    static func dismantleNSView(_ nsView: PopoverAnchorView, coordinator: HoverPopoverController) {
        nsView.onWindowChange = nil
        coordinator.dismissWithoutUpdatingBinding()
    }

    @MainActor
    final class PopoverAnchorView: NSView {
        var onWindowChange: (() -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChange?()
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }
    }
}

/// Owns the AppKit objects and delegate lifecycle outside the generic SwiftUI representable.
@MainActor
final class HoverPopoverController: NSObject, NSPopoverDelegate {
    private static let live = NSHashTable<HoverPopoverController>.weakObjects()

    var isPresented: Binding<Bool>

    /// `nil` until the first presentation: every `motionAwareHoverPopover` site builds one of these
    /// coordinators at mount (one per hoverable row), but most are never hovered, so the NSPopover
    /// and its hosting controller stay unallocated until a popover actually opens.
    private var createdPopover: NSPopover?
    private var host: NSHostingController<AnyView>?
    /// Bumped on each fresh presentation and applied as `.id` to the hosted view. The hosting
    /// controller survives `performClose`, so without a new identity the popover's @State —
    /// expanded rows, claim banners, pending request IDs — would reopen with its previous values.
    private var presentationGeneration = 0

    /// The popover, materialized on first access. Internal (not private) so tests can reach the
    /// AppKit object; production paths must use `createdPopover`/`ensurePopover()` instead, so a
    /// never-presented site never allocates one.
    var popover: NSPopover {
        ensurePopover().popover
    }

    private var ignoreNextClose = false

    init(isPresented: Binding<Bool>) {
        self.isPresented = isPresented
        super.init()
        Self.live.add(self)
    }

    /// The popover + content host pair, allocated on first use. `.transient` would close on any
    /// click outside the popover — a tap on another panel row or a near-miss inside the popover then
    /// tears the surface down. Dismissal is owned by the hover coordinator (hover-out grace,
    /// one-popover-at-a-time, panel close), so AppKit only still closes it when the positioning
    /// view's window goes away.
    private func ensurePopover() -> (popover: NSPopover, host: NSHostingController<AnyView>) {
        if let createdPopover, let host { return (createdPopover, host) }
        let host = NSHostingController(rootView: AnyView(EmptyView()))
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.contentViewController = host
        popover.delegate = self
        self.host = host
        self.createdPopover = popover
        return (popover, host)
    }

    func update(content: AnyView, reduceAnimations: Bool, anchor: NSView) {
        // `updateNSView` only reaches this while presented; bail before `ensurePopover` so a
        // close-path call can never allocate the popover just to tear it down.
        guard isPresented.wrappedValue else {
            synchronize(with: anchor)
            return
        }
        let (popover, host) = ensurePopover()
        if !popover.isShown { presentationGeneration += 1 }
        host.rootView = AnyView(content.animationReduction(reduceAnimations).id(presentationGeneration))
        popover.animates = !reduceAnimations
        host.view.layoutSubtreeIfNeeded()
        let size = host.view.fittingSize
        if size.width > 0, size.height > 0 {
            popover.contentSize = size
        }
        synchronize(with: anchor)
    }

    /// Closing the panel still dismisses AppKit hover presentations synchronously: even with the
    /// dashboard host torn down to EmptyView, a live NSPopover can otherwise linger one frame.
    static func dismissAll() {
        for controller in live.allObjects where controller.createdPopover?.isShown == true {
            controller.createdPopover?.performClose(nil)
        }
    }

    func synchronize(with anchor: NSView) {
        guard isPresented.wrappedValue else {
            if let createdPopover, createdPopover.isShown { createdPopover.performClose(nil) }
            return
        }
        guard anchor.window != nil, createdPopover?.isShown != true else { return }
        ensurePopover().popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    func dismissWithoutUpdatingBinding() {
        guard let createdPopover, createdPopover.isShown else { return }
        ignoreNextClose = true
        createdPopover.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        if ignoreNextClose {
            ignoreNextClose = false
            return
        }
        if isPresented.wrappedValue {
            isPresented.wrappedValue = false
        }
    }
}
