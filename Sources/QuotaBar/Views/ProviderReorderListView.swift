import SwiftUI

/// A compact list of every provider, including disabled providers, using the dashboard's saved order.
struct ProviderReorderListView: View {
    @Environment(LayoutStore.self) private var layout
    let reorderSpaceName: String
    @Binding var reorderLift: ReorderLift?
    let frameStore: ReorderFrameStore
    @State private var activeProviderID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Drag a provider to change its position.")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
            VStack(spacing: 0) {
                ForEach(layout.customizeProviderRows) { row in
                    ProviderOrderRow(provider: row.provider)
                        .contentShape(Rectangle())
                        .highPriorityGesture(dragGesture(for: row.provider))
                        .opacity(activeProviderID == row.id ? 0 : 1)
                        .reorderFrame(id: row.id, in: .named(reorderSpaceName))
                }
            }
            .cardSurface()
        }
        .animation(Motion.spring, value: layout.orderedProviderIDs())
    }

    private func dragGesture(for provider: Provider) -> some Gesture {
        reorderDragGesture(
            id: provider.id, coordinateSpaceName: reorderSpaceName, frameStore: frameStore,
            active: $activeProviderID, lift: $reorderLift,
            makeLift: { ReorderLift.make(id: provider.id, payload: .providerOrder(provider: provider),
                                        value: $0, frames: frameStore.frames) },
            orderedIDs: { layout.orderedProviderIDs() },
            reorder: { layout.reorderAnyProvider(dragged: provider.id, target: $0) },
            onEditBegan: { layout.beginCoalescedEdit() },
            onEditEnded: { layout.endCoalescedEdit() }
        )
    }
}

struct ProviderOrderRow: View {
    let provider: Provider
    var body: some View {
        HStack(spacing: 10) {
            ReorderGrip()
            ProviderIcon(source: provider.icon).frame(width: 18, height: 18)
            Text(provider.displayName).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}
