import SwiftUI

/// The dashboard-only scrolling content. Screen switching, panel sizing, fixed bars, keyboard handling,
/// and close/reset behavior stay with `DashboardView`.
struct DashboardContentView: View {
    let container: AppContainer
    let layout: LayoutStore
    let reorderSpaceName: String
    let horizontalPadding: CGFloat
    let bottomGap: CGFloat

    @Binding var reorderLift: ReorderLift?
    @Binding var scrollPosition: ScrollPosition

    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular
    @AppStorage(TotalSpendSetting.key) private var showTotalSpend = true

    var body: some View {
        PopoverScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // The one-time first-run hint sits above the provider sections (and above the
                // empty-state line, which a fresh install can hit while nothing has data yet).
                if container.onboarding.isCustomizeHintPending {
                    CustomizeHintCard()
                        .padding(.bottom, density.sectionSpacing)
                        .transition(.scale(scale: 0.95).combined(with: .opacity))
                }
                widgetContent
                // Only offered when it can work. The bridge is a separate binary QuotaBar does not ship,
                // so an unconditional card sat at the bottom of the dashboard permanently reporting a red
                // "Needs attention" for an optional feature the user never enabled — and suggesting a
                // reinstall, which cannot install it.
                if container.kaggleCompute.isBridgeAvailable {
                    KaggleComputeCard()
                        .padding(.top, density.sectionSpacing)
                }
            }
            .animation(Motion.spring, value: container.onboarding.isCustomizeHintPending)
            .padding(.horizontal, horizontalPadding)
            .padding(.top, density.contentTopPadding)
            .padding(.bottom, bottomGap)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollPosition($scrollPosition)
    }

    @ViewBuilder
    private var widgetContent: some View {
        // The cross-provider Total Spend ring stays visible whenever the user allows it and an enabled
        // provider can track spend, even before fresh data arrives or when every metric row is hidden.
        if showTotalSpend, layout.hasSpendCapableProvider {
            TotalSpendCard()
                .padding(.bottom, density.sectionSpacing)
        }
        if layout.displayGroups.isEmpty {
            Text("Turn on Customize to choose what to show.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .padding(.horizontal, 16)
        } else {
            WidgetGroupedListView(
                reorderSpaceName: reorderSpaceName,
                reorderLift: $reorderLift
            )
        }
    }
}
