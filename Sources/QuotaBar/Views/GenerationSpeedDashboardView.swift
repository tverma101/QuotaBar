import SwiftUI

struct GenerationSpeedDashboardView: View {
    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular
    @State private var window = GenerationSpeedWindow.today
    @State private var report: GenerationSpeedReport?
    @State private var scanID = 0
    @State private var isLoading = true
    @State private var didFail = false

    var body: some View {
        PopoverScrollView {
            VStack(alignment: .leading, spacing: density.sectionSpacing) {
                Picker("Period", selection: $window) {
                    ForEach(GenerationSpeedWindow.allCases) { window in
                        Text(window.rawValue).tag(window)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if let report {
                    GenerationSpeedResults(report: report, window: window)
                } else if !didFail {
                    ProgressView("Reading Timing History").controlSize(.small)
                }
                if didFail {
                    Text("Could not read timing history.").font(.subheadline).foregroundStyle(.secondary)
                }
                if didFail || report?.unavailable.isEmpty == false {
                    Button("Retry") { scanID += 1 }.disabled(isLoading)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: scanID) { await reload() }
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let updated = try await GenerationSpeedScanner().scan()
            try Task.checkCancellation()
            report = updated
            didFail = false
        } catch is CancellationError {
            return
        } catch {
            didFail = true
        }
    }
}

struct GenerationSpeedResults: View {
    let report: GenerationSpeedReport
    let window: GenerationSpeedWindow
    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular

    var body: some View {
        let rows = report.rows(window: window)
        VStack(alignment: .leading, spacing: density.sectionSpacing) {
            if rows.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No Timed Responses").font(.subheadline.weight(.semibold))
                    Text("This period has no completed responses with recorded timing from ZCode or Antigravity.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardSurface()
            }
            ForEach(rows) { row in
                GenerationSpeedProviderCard(row: row, density: density)
            }
            ForEach(GenerationSpeedSource.allCases.filter { report.unavailable.contains($0) }) { source in
                Text("\(source.rawValue) timing history could not be read completely.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(GenerationSpeedSource.allCases.filter { report.unsupported.contains($0) }) { source in
                Text("This version of \(source.rawValue) does not record supported timing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !rows.isEmpty {
                Text("Average output tokens per second. Timing differs by provider; not a benchmark.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct GenerationSpeedProviderCard: View {
    let row: GenerationSpeedReport.Row
    let density: DensitySetting

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            line(title: row.id.rawValue, totals: row.totals, minimumSamples: 5, isHeadline: true)
            Text(row.id.timing).font(.caption).foregroundStyle(.secondary)
            Divider()
            ForEach(row.models) { model in
                line(title: model.id, totals: model.totals, minimumSamples: 3, isHeadline: false)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private func line(title: String, totals: GenerationSpeedTotals, minimumSamples: Int, isHeadline: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(isHeadline ? .system(size: density.headerPointSize, weight: .semibold) : .subheadline)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 2)
            VStack(alignment: .trailing, spacing: 2) {
                if let rate = totals.rate(minimumSamples: minimumSamples) {
                    Text("\(rate, format: .number.precision(.fractionLength(1))) tok/s")
                        .monospacedDigit()
                        .font(isHeadline ? .subheadline.weight(.semibold) : .subheadline)
                } else {
                    Text("Not Enough Samples")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("\(totals.samples) \(totals.samples == 1 ? "sample" : "samples")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .accessibilityElement(children: .combine)
    }
}
