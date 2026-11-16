import AppKit
import SwiftUI

/// The scroll container shared by the popover's screens. Each one fills the region the pinned
/// footer leaves; the overlay scroller stays (the macOS 27 system scroll-edge effect needs the
/// scroll view to keep a vertical scroller) and is invisible, so it reserves no gutter.
///
/// The scroll edge effect (the blur as content passes under the `safeAreaBar`) needs the scroll view
/// to keep a vertical scroller, so indicators are not hidden the SwiftUI way (that removes the
/// scroller and kills the effect). `invisibleOverlayScroller()` instead keeps the overlay scroller
/// (which reserves no gutter) and just makes it invisible: effect intact, no visible bar.
///
/// It also publishes its inner content's ideal height as a `ScrollContentHeightKey` preference so the
/// popover can auto-fit the window to its content (see `DashboardView`'s coordinated-morph resize). A
/// vertical `ScrollView` proposes `nil` height to its children, so the measured value is the content's
/// intrinsic height — invariant to the window/viewport height, which is what keeps the auto-fit from
/// feeding back on itself. The preference bubbles up past the `ScrollView` to the per-screen wrapper.
struct PopoverScrollView<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView(.vertical) {
            content
                .invisibleOverlayScroller()
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: ScrollContentHeightKey.self, value: proxy.size.height)
                    }
                )
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

/// The intrinsic height of a popover screen's scroll content, published by `PopoverScrollView` and
/// read per-screen in `DashboardView` to auto-fit the panel. One emitter per screen subtree, so the
/// reduce just carries the most recent non-zero measurement.
struct ScrollContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 { value = next }
    }
}

extension View {
    /// Sets `top` and `bottom` over a scrolling page of the panel. Content scrolls cleanly under the
    /// top bar, which hides it behind the panel's surface. Content under the bottom bar blurs behind
    /// it: from macOS 27 with the system's soft scroll edge effect, before it with frosted glass.
    /// Nothing is drawn behind the bottom bar while nothing is under it. While the panel isn't yet at
    /// the page's height, the bottom bar hides what is under it behind the panel's surface.
    func panelBars(@ViewBuilder top: () -> some View, @ViewBuilder bottom: () -> some View) -> some View {
        modifier(PanelBars(top: top(), bottom: bottom()))
    }
}

private struct PanelBars<Top: View, Bottom: View>: ViewModifier {
    /// How far content must be under the bottom bar to frost it fully.
    private static var fullFrost: CGFloat { 12 }

    @Environment(\.popoverSurfaceTreatment) private var treatment

    let top: Top
    let bottom: Bottom
    @State private var underBottom: CGFloat = 0
    /// Whether the panel is at another height than this page's. A switch draws its new rows a frame
    /// before the panel takes their height, and in that frame they would show through the bottom bar.
    @State private var isResizing = false

    func body(content: Content) -> some View {
        let barred = content
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                let below = geometry.contentSize.height + geometry.contentInsets.bottom
                    - geometry.containerSize.height - geometry.contentOffset.y
                return min(max(below / Self.fullFrost, 0), 1)
            } action: { _, under in
                underBottom = under
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                guard let clampHeight = MenuBarPopover.clampHeight else { return false }
                let ideal = geometry.contentSize.height + geometry.contentInsets.top + geometry.contentInsets.bottom
                return abs(geometry.visibleRect.height - clampHeight(ideal)) > 1
            } action: { _, resizing in
                isResizing = resizing
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                top.background(barBackground)
            }
        let footer = bottom.background { if isResizing { barBackground } }
        if #available(macOS 27, *) {
            barred
                .safeAreaBar(edge: .bottom, spacing: 0) { footer }
                .scrollEdgeEffectStyle(.soft, for: .bottom)
                .scrollEdgeEffectHidden(true, for: underBottom > 0 ? .top : .vertical)
        } else {
            barred.safeAreaInset(edge: .bottom, spacing: 0) {
                footer.background {
                    FooterFrost(opacity: underBottom)
                        .padding(.top, -FooterFrost.reach)
                }
            }
        }
    }

    /// What hides content behind a bar: the opaque page's tray color, or a frosted material under
    /// Increase Transparency so the desktop stays visible without letting content bleed through.
    @ViewBuilder
    private var barBackground: some View {
        switch treatment {
        case .opaque:
            Theme.traySurface
        case .translucent:
            Rectangle().fill(.regularMaterial)
        }
    }
}

/// The frosted glass behind the bottom bar before macOS 27: an in-window blur of what is under it, in
/// the material whose tint comes closest to the panel's, washed halfway back to the panel's color so the
/// tint barely shows. It is full from the panel's edge to just short of the bar's top and fades out a
/// little above it.
private struct FooterFrost: NSViewRepresentable {
    /// How far the frost reaches above the bar into the page.
    static let reach: CGFloat = 10

    let opacity: CGFloat

    func makeNSView(context: Context) -> FrostView { FrostView() }

    func updateNSView(_ view: FrostView, context: Context) {
        view.alphaValue = opacity
    }

    final class FrostView: NSView {
        private let blur = NSVisualEffectView()
        private let wash = CALayer()
        private let fade = CAGradientLayer()

        init() {
            super.init(frame: .zero)
            blur.material = .menu
            blur.blendingMode = .withinWindow
            blur.state = .active
            addSubview(blur)
            wantsLayer = true
            wash.zPosition = 1
            layer?.addSublayer(wash)
            fade.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
            fade.startPoint = CGPoint(x: 0.5, y: 0)
            fade.endPoint = CGPoint(x: 0.5, y: 1)
            layer?.mask = fade
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            needsLayout = true
        }

        override func layout() {
            super.layout()
            blur.frame = bounds
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            fade.frame = bounds
            wash.frame = bounds
            effectiveAppearance.performAsCurrentDrawingAppearance {
                wash.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.5).cgColor
            }
            let fadeLength = FooterFrost.reach + 4
            fade.locations = [0, NSNumber(value: Double(max(bounds.height - fadeLength, 0) / max(bounds.height, 1))), 1]
            CATransaction.commit()
        }
    }
}
