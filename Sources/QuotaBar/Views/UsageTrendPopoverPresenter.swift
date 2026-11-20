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
    let popover: NSPopover

    private let host = NSHostingController(rootView: AnyView(EmptyView()))
    private var ignoreNextClose = false

    init(isPresented: Binding<Bool>) {
        self.isPresented = isPresented
        self.popover = NSPopover()
        super.init()
        // `.transient` would close on any click outside the popover — a tap on another panel row or
        // a near-miss inside the popover then tears the surface down. Dismissal is owned by the
        // hover coordinator (hover-out grace, one-popover-at-a-time, panel close), so AppKit only
        // still closes it when the positioning view's window goes away.
        popover.behavior = .applicationDefined
        popover.contentViewController = host
        popover.delegate = self
        Self.live.add(self)
    }

    func update(content: AnyView, reduceAnimations: Bool, anchor: NSView) {
        host.rootView = AnyView(content.animationReduction(reduceAnimations))
        popover.animates = !reduceAnimations
        guard isPresented.wrappedValue else {
            synchronize(with: anchor)
            return
        }
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
        for controller in live.allObjects where controller.popover.isShown {
            controller.popover.performClose(nil)
        }
    }

    func synchronize(with anchor: NSView) {
        guard isPresented.wrappedValue else {
            if popover.isShown { popover.performClose(nil) }
            return
        }
        guard anchor.window != nil, !popover.isShown else { return }
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    func dismissWithoutUpdatingBinding() {
        guard popover.isShown else { return }
        ignoreNextClose = true
        popover.performClose(nil)
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
