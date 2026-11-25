import SwiftUI

struct SpendPeriodSettingsSection: View {
    @Environment(WidgetDataStore.self) private var dataStore
    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular

    var body: some View {
        @Bindable var store = dataStore
        VStack(alignment: .leading, spacing: density.headerToCardSpacing) {
            Text("Spend Periods")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 8)
            VStack(spacing: 0) {
                periodRow("First Period", selection: $store.spendPeriods.first)
                Divider().opacity(0.4)
                periodRow("Middle Period", selection: $store.spendPeriods.middle)
                Divider().opacity(0.4)
                periodRow("Last Period", selection: $store.spendPeriods.last)
                Text("Multi-day periods include today. Totals use available history.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
            .cardSurface()
        }
    }

    private func periodRow(_ title: String, selection: Binding<SpendPeriodSettings.Selection>) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            Picker(title, selection: selection.preset) {
                ForEach(SpendPeriodSettings.Preset.allCases) { preset in
                    Text(preset.rawValue).tag(preset)
                }
            }
            if selection.wrappedValue.preset == .custom {
                TextField(
                    "\(title) Days",
                    value: Binding(
                        get: { selection.wrappedValue.days },
                        set: { selection.wrappedValue.customDays = $0 }
                    ),
                    format: .number.grouping(.never)
                )
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 68)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, density.controlRowPadding)
    }
}
