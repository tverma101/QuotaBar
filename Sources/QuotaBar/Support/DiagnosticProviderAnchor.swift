import AppKit
import SwiftUI

/// A diagnostic-only scroll anchor for the AppKit-backed menu panel. Scrolling the actual native
/// section into view also works when SwiftUI's scroll-target lookup cannot see a nested group.
struct DiagnosticProviderAnchor: NSViewRepresentable {
    let providerID: String

    func makeNSView(context: Context) -> AnchorView { AnchorView(providerID: providerID) }
    func updateNSView(_ view: AnchorView, context: Context) { view.providerID = providerID }

    final class AnchorView: NSView {
        var providerID: String

        init(providerID: String) {
            self.providerID = providerID
            super.init(frame: .zero)
            NotificationCenter.default.addObserver(
                self, selector: #selector(focus(_:)),
                name: Notification.Name("com.quotabar.diagnostics.focus"), object: nil
            )
        }

        required init?(coder: NSCoder) { nil }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        @objc private func focus(_ notification: Notification) {
            guard notification.object as? String == providerID else { return }
            guard let scroll = enclosingScrollView, let document = scroll.documentView else {
                AppLog.error(.statusItem, "diagnostic provider section has no scroll container")
                return
            }
            let before = scroll.contentView.bounds.origin.y
            let section = convert(bounds, to: document)
            _ = scrollToVisible(bounds)
            let viewport = scroll.contentView.bounds
            let overlap = viewport.intersection(section)
            guard section.height > 1, viewport.height > 1, !overlap.isNull,
                  overlap.height >= min(section.height, viewport.height) - 1 else {
                AppLog.error(.statusItem, "diagnostic provider focus failed (sectionY=\(Int(section.minY)), sectionHeight=\(Int(section.height)), viewportY=\(Int(viewport.minY)), viewportHeight=\(Int(viewport.height)))")
                return
            }
            AppLog.info(.statusItem, "diagnostic provider visible (beforeY=\(Int(before)), afterY=\(Int(viewport.minY)), sectionY=\(Int(section.minY)), sectionHeight=\(Int(section.height)))")
        }
    }
}
