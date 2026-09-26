import SwiftUI

/// A native dashboard control for the separate GLM-5.3 Kaggle TPU allocation. The card is intentionally
/// at the bottom of the scrolling dashboard: it is discoverable by scrolling without changing the
/// provider layout/customization model, and Turn On/Turn Off remain explicit user actions.
struct KaggleComputeCard: View {
    @Environment(AppContainer.self) private var container

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 1)) { context in
            card(now: context.date)
        }
        .onAppear { container.kaggleCompute.startPolling() }
    }

    private func card(now: Date) -> some View {
        let service = container.kaggleCompute
        let snapshot = service.snapshot
        let elapsed = liveElapsed(snapshot, now: now)
        let remaining = snapshot.allocationLimitSeconds > 0
            ? max(0, snapshot.allocationLimitSeconds - elapsed)
            : snapshot.remainingSeconds
        let active = snapshot.state == .running || snapshot.state == .starting

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "cpu")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Kaggle Compute")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                statusPill(snapshot)
            }

            Text("GLM-5.3-Flash - TPU v5e-8")
                .font(.caption)
                .foregroundStyle(.secondary)

            if active || snapshot.state == .stopping {
                if snapshot.allocationLimitSeconds > 0 {
                    ProgressView(value: Double(elapsed), total: Double(snapshot.allocationLimitSeconds))
                        .tint(.accentColor)
                        .accessibilityLabel("Kaggle allocation time used")
                }
                HStack(spacing: 14) {
                    metric("Elapsed", duration(elapsed), systemImage: "clock")
                    metric("Remaining", duration(remaining), systemImage: "hourglass")
                }
                HStack(spacing: 14) {
                    metric("Requests", snapshot.requests.formatted(), systemImage: "arrow.triangle.2.circlepath")
                    metric("Tokens", totalTokens(snapshot).formatted(), systemImage: "text.word.spacing")
                    metric("API equivalent", Formatters.currency(snapshot.estimatedAPICostUSD), systemImage: "dollarsign.circle")
                }
            } else if snapshot.state == .unconfigured {
                Text("Install the local GLM bridge, then use Turn On here. No notebook starts automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if snapshot.state == .stopped {
                Text("Off. Turn On starts the configured Kaggle notebook; it remains idle-safe and shuts down after five minutes without requests.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let message = snapshot.errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button {
                    service.turnOn()
                } label: {
                    Label("Turn On", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(service.isExecuting || active)

                Button {
                    service.turnOff()
                } label: {
                    Label("Turn Off", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(service.isExecuting || !active)

                Spacer(minLength: 0)
                Button {
                    service.refresh()
                } label: {
                    if service.isBusy {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Refresh Kaggle compute status")
                .disabled(service.isExecuting)
            }
        }
        .padding(12)
        .cardSurface()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Kaggle Compute, GLM-5.3-Flash on TPU v5e-8")
    }

    private func statusPill(_ snapshot: KaggleComputeSnapshot) -> some View {
        let title: String
        let tint: Color
        switch snapshot.state {
        case .running: title = snapshot.endpointReady ? "Ready" : "Starting"; tint = .green
        case .starting: title = "Starting"; tint = .orange
        case .stopping: title = "Stopping"; tint = .orange
        case .stopped: title = "Off"; tint = .secondary
        case .unconfigured: title = "Not installed"; tint = .secondary
        case .error: title = "Needs attention"; tint = .red
        }
        return Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint.opacity(0.12), in: Capsule())
    }

    private func metric(_ label: String, _ value: String, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(label, systemImage: systemImage)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
            Text(value)
                .font(.caption.weight(.medium))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func liveElapsed(_ snapshot: KaggleComputeSnapshot, now: Date) -> Int {
        guard snapshot.state == .running || snapshot.state == .starting,
              let startedAt = snapshot.startedAt else { return snapshot.elapsedSeconds }
        return max(snapshot.elapsedSeconds, Int(max(0, now.timeIntervalSince(startedAt))))
    }

    private func duration(_ seconds: Int) -> String {
        guard seconds > 0 else { return "0m" }
        return Formatters.compactDuration(TimeInterval(seconds)) ?? "0m"
    }

    private func totalTokens(_ snapshot: KaggleComputeSnapshot) -> Int {
        snapshot.inputTokens + snapshot.outputTokens
    }
}
