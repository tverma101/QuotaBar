import SwiftUI

/// The branded, off-screen PNG for the TPS lens of the Total Spend card's share action — the
/// tokens-per-second counterpart to `TotalSpendShareCardView`. Static header (the metric can't be
/// switched inside an image), the same chrome, tray background and watermark footer, and the
/// ring it exports is exactly what the popover shows.
struct TPSShareCardView: View {
    let tps: TPSTotal
    let appearance: ColorScheme

    var body: some View {
        ShareCardChrome(appearance: appearance) {
            headerRow
            DashboardMetricCard {
                TPSSpendPanel(tps: tps)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
        }
    }

    private var headerRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("TPS")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
            Text(tps.windowLabel)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }
}
