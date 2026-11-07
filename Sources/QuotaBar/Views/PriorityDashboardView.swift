import SwiftUI

/// Popup summary adapted from upstream's Priority dashboard. It reads the same enabled widgets and
/// existing meter state as All Usage, so Customize and menu-bar pins retain their existing behavior.
struct PriorityDashboardView: View {
    @Environment(LayoutStore.self) private var layout
    @Environment(WidgetDataStore.self) private var dataStore
    let openProvider: (String) -> Void

    private struct Item: Identifiable {
        let provider: Provider
        let descriptor: WidgetDescriptor
        let data: WidgetData
        let section: Section
        var id: String { descriptor.id }
    }

    enum Section: Int, CaseIterable {
        case runningOut, pinned, usedUp
        var title: String {
            switch self {
            case .runningOut: "Running Out"
            case .pinned: "Pinned"
            case .usedUp: "Used Up"
            }
        }
    }

    private func items(now: Date) -> [Item] {
        layout.displayGroups.flatMap { group in
            group.widgets.compactMap { widget -> Item? in
                guard let descriptor = layout.descriptor(for: widget) else { return nil }
                let data = dataStore.data(for: descriptor)
                guard data.hasData else { return nil }
                guard let section = Self.section(for: data, pinned: layout.isPinned(descriptor.id), now: now) else { return nil }
                return Item(provider: group.provider, descriptor: descriptor, data: data, section: section)
            }
        }.sorted { left, right in
            if left.section.rawValue != right.section.rawValue { return left.section.rawValue < right.section.rawValue }
            return left.data.remainingFraction < right.data.remainingFraction
        }
    }

    static func section(for data: WidgetData, pinned: Bool, now: Date = Date()) -> Section? {
        guard data.hasData else { return nil }
        let state = data.meterState(now: now)
        if data.isBounded && state == .spent { return .usedUp }
        if data.isBounded && (state.severity == .warning || state.severity == .critical) { return .runningOut }
        return pinned ? .pinned : nil
    }

    var body: some View {
        VisibilityGatedPeriodicTimeline(every: 30) { now in
            content(items: items(now: now), now: now)
        }
    }

    @ViewBuilder
    private func content(items: [Item], now: Date) -> some View {
        let noticeGroup = layout.displayGroups.first { dataStore.headerNotice(for: $0.provider.id) != nil }
        VStack(alignment: .leading, spacing: 12) {
            if let noticeGroup {
                Button {
                    openProvider(noticeGroup.provider.id)
                } label: {
                    Label("A provider needs attention", systemImage: "exclamationmark.triangle")
                        .font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
            if items.isEmpty {
                VStack(spacing: 6) {
                    Text("No Priority Items").font(.headline)
                    Text("No enabled limits need attention or are available yet. See All Usage for your providers.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 28)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Section.allCases, id: \.rawValue) { section in
                        let rows = items.filter { $0.section == section }
                        if !rows.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(section.title).font(.headline).padding(.horizontal, 8)
                                DashboardMetricCard {
                                    ForEach(rows) { item in row(item, now: now) }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func row(_ item: Item, now: Date) -> some View {
        Button { openProvider(item.provider.id) } label: {
            HStack(spacing: 10) {
                ProviderIcon(source: item.provider.icon, inset: 0.04).frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.descriptor.title).font(.subheadline.weight(.medium))
                    Text(item.provider.displayName).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(item.data.isBounded ? item.data.boundedHeadline : item.data.valueText)
                        .font(.subheadline.weight(.medium)).monospacedDigit()
                    if dataStore.stalenessHint(for: item.provider.id) != nil {
                        Text("Outdated").font(.caption).foregroundStyle(.secondary)
                    } else if item.data.isBounded, let reset = item.data.boundedTrailingText(now: now) {
                        Text(reset).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
