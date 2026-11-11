import SwiftUI

/// Hover detail for active Freebuff sessions: lists each currently running session, its linked local
/// chat title, project workspace, model, and remaining time countdown until expiry.
struct FreebuffActiveSessionsDetail: View {
    let sessions: [FreebuffActiveSession]
    var onHoverChange: (Bool) -> Void
    var now: () -> Date = Date.init

    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular

    private static let width: CGFloat = 300

    var body: some View {
        TimelineView(.everyMinute) { context in
            content(now: context.date)
        }
    }

    private func content(now: Date) -> some View {
        let active = sessions.filter { $0.expiresAt > now }.sorted { $0.expiresAt < $1.expiresAt }
        return VStack(alignment: .leading, spacing: 10) {
            header(count: active.count)
            if active.isEmpty {
                Text("No active sessions")
                    .font(.system(size: density.supportingPointSize))
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(active, id: \.instanceID) { session in
                        sessionRow(session, now: now)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: Self.width)
        .onContinuousHover { phase in
            switch phase {
            case .active:
                onHoverChange(true)
            case .ended:
                onHoverChange(false)
            }
        }
    }

    private func header(count: Int) -> some View {
        HStack {
            Text("Active Sessions")
                .font(.system(size: density.headerPointSize, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer()
            Text(count == 1 ? "1 session" : "\(count) sessions")
                .font(.system(size: density.supportingPointSize - 1))
                .foregroundStyle(.secondary)
        }
    }

    private func sessionRow(_ session: FreebuffActiveSession, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(sessionTitle(for: session))
                    .font(.system(size: density.supportingPointSize, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                let remaining = max(0, session.expiresAt.timeIntervalSince(now))
                Text(Formatters.compactDuration(remaining) ?? "<1m")
                    .font(.system(size: density.supportingPointSize, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let project = projectName(from: session.projectPath) {
                    Text(project)
                        .font(.system(size: density.supportingPointSize - 1))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let model = session.subtitleModel {
                    if session.projectPath?.nilIfEmpty != nil {
                        Text("·")
                            .font(.system(size: density.supportingPointSize - 1))
                            .foregroundStyle(.tertiary)
                    }
                    Text(model)
                        .font(.system(size: density.supportingPointSize - 1))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Text(formatExpiryTime(session.expiresAt))
                    .font(.system(size: density.supportingPointSize - 1))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.quaternary.opacity(0.5))
        )
    }

    private func sessionTitle(for session: FreebuffActiveSession) -> String {
        if let title = session.chatTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        if session.instanceID == "single" || session.instanceID == "cli" {
            return "CLI Session"
        }
        return "Desktop Session"
    }

    private func projectName(from path: String?) -> String? {
        guard let path = path?.nilIfEmpty else { return nil }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private func formatExpiryTime(_ date: Date) -> String {
        DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short)
    }
}
