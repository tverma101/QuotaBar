import SwiftUI

struct SnoozeSettingsSection: View {
    @Bindable var snooze: MenuBarSnoozeStore
    @Environment(AppContainer.self) private var container
    @Environment(LayoutStore.self) private var layout
    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular

    var body: some View {
        VStack(alignment: .leading, spacing: density.headerToCardSpacing) {
            Text("Snooze Subscriptions")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text("Snooze Low Usage")
                    Spacer(minLength: 8)
                    Toggle("", isOn: $snooze.isEnabled)
                        .settingsSwitchStyle()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, density.controlRowPadding)

                Text("Temporarily hide menu bar icons for subscriptions that are out of usage or below the threshold until they reset.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if snooze.isEnabled {
                    Divider().opacity(0.4)

                    HStack(spacing: 10) {
                        Text("Threshold")
                        Spacer(minLength: 8)
                        Picker("", selection: $snooze.threshold) {
                            ForEach(SnoozeThreshold.allCases, id: \.self) { threshold in
                                Text(threshold.label).tag(threshold)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .fixedSize()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, density.controlRowPadding)

                    subscriptionRows
                }
            }
            .cardSurface()
        }
    }

    @ViewBuilder
    private var subscriptionRows: some View {
        let enabledProviderIDs = layout.orderedProviderIDs().filter { layout.isProviderEnabled($0) }
        ForEach(enabledProviderIDs, id: \.self) { providerID in
            if let provider = layout.provider(id: providerID) {
                Divider().opacity(0.4)

                let pinned = layout.pinnedMetrics(for: providerID)
                let status = snooze.statusText(
                    for: providerID,
                    pinnedMetrics: pinned,
                    data: { container.dataStore.data(for: $0) }
                )
                HStack(spacing: 8) {
                    if let mark = ProviderMarks.mark(for: provider.icon.providerID) {
                        ProviderIconShape(mark: mark, inset: 0.04)
                            .fill(Color.primary)
                            .frame(width: 14, height: 14)
                    } else {
                        Image(systemName: ProviderMarks.symbolFallback(for: provider.icon.providerID))
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 14, height: 14)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(provider.displayName)
                            .font(.body)
                        if let status {
                            Text(status.text)
                                .font(.caption2)
                                .foregroundStyle(status.isSnoozed ? Color.orange : Color.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    Toggle("", isOn: Binding(
                        get: { snooze.isSubscriptionEnabled(providerID) },
                        set: { snooze.setSubscriptionEnabled(providerID, enabled: $0) }
                    ))
                    .settingsSwitchStyle()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, density.controlRowPadding)
                .contextMenu {
                    if let status, status.isSnoozed {
                        Button("Un-snooze") {
                            snooze.unSnooze(providerID: providerID)
                        }
                    } else if let status, let resetsAt = status.resetsAt {
                        Button("Snooze Until Reset") {
                            snooze.snoozeUntilReset(providerID: providerID, resetsAt: resetsAt)
                        }
                    }
                }
            }
        }
    }
}
