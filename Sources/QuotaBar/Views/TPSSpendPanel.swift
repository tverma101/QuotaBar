import SwiftUI

/// The Total Spend panel's TPS lens: everything TPS, nothing about spend. A two-line header row
/// keeps the card's chrome, the ring shows each provider's share of generation pace, and the
/// model list ranks what the machine was actually generating. Data comes from `TPSTotal` — the
/// same snapshot the live meters read, never a fetch.
struct TPSSpendPanel: View {
    let tps: TPSTotal
    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TotalSpendRingContent(projection: tps.projection())
            caption
            if !tps.slices.isEmpty {
                Divider()
                modelHeader
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(tps.slices) { slice in
                        providerSection(slice)
                    }
                }
            }
        }
    }

    /// One quiet line so the number never reads as a measured provider rate.
    private var caption: some View {
        Text("Estimated from local session logs · tool-call gaps excluded · not a benchmark")
            .font(.system(size: 10, weight: .regular))
            .foregroundStyle(.tertiary)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var modelHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Model TPS")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(tps.windowLabel)
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(.tertiary)
        }
    }

    /// One block per provider — its own rate and its own models — instead of a single merged list, so
    /// each provider's generation pace and model mix read separately. Providers arrive ranked by rate.
    private func providerSection(_ slice: TPSTotal.Slice) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 7) {
                Circle()
                    .fill(TotalSpendPalette.color(for: slice.provider.id))
                    .frame(width: 8, height: 8)
                Text(slice.provider.displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(slice.rate, format: .number.precision(.fractionLength(1)))
                    .monospacedDigit()
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("tok/s")
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(.tertiary)
            }
            .padding(.bottom, 1)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(slice.models.prefix(6)) { model in
                    modelRow(model)
                }
                if slice.models.count > 6 {
                    moreRow(hidden: slice.models.count - 6)
                }
            }
            .padding(.leading, 15)
        }
    }

    private func moreRow(hidden: Int) -> some View {
        Text("… \(hidden) more models")
            .font(.system(size: 10, weight: .regular))
            .foregroundStyle(.tertiary)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func modelRow(_ model: TPSTotal.ModelRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(model.name)
                .font(.system(size: density.supportingPointSize, weight: .regular))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if let rate = model.rate {
                Text(rate, format: .number.precision(.fractionLength(1)))
                    .monospacedDigit()
                    .font(.system(size: density.supportingPointSize, weight: .medium))
                    .foregroundStyle(.primary)
                Text("tok/s")
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(.tertiary)
            } else {
                Text(MetricFormatter.number(model.tokens, kind: .count, style: .row))
                    .monospacedDigit()
                    .font(.system(size: density.supportingPointSize, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Text("· \(MetricFormatter.number(model.tokens, kind: .count, style: .row))")
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .padding(.vertical, 3)
    }
}
