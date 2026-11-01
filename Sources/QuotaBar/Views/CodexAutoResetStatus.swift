import SwiftUI

enum CodexAutoResetStatus: Equatable {
    case off, unverified, checking, monitoring, due
    case scheduled(Date)
    case attention(String)

    var title: String {
        switch self {
        case .off: "Auto-Use Off"
        case .unverified: "Auto-Use Needs Sign-In"
        case .checking: "Checking Reset Credits"
        case .monitoring, .scheduled: "Auto-Use On"
        case .due: "Auto-Use Due"
        case .attention: "Auto-Use Needs Attention"
        }
    }

    var detail: String {
        switch self {
        case .off: "Enable in Settings → Usage Display to use eligible credits before they expire."
        case .unverified: "This account's identity could not be verified. Sign in and reload accounts."
        case .checking: "Checking this account's available credits."
        case .monitoring: "Monitoring this account. No reset is currently scheduled."
        case .scheduled: "Next attempt, one minute before expiry:"
        case .due: "An expiring reset is due for an automatic attempt."
        case .attention(let message): message
        }
    }

    var needsAttention: Bool {
        switch self {
        case .unverified, .attention: true
        default: false
        }
    }
}

struct CodexAutoResetStatusView: View {
    let status: CodexAutoResetStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(status.title).fontWeight(.medium)
                .foregroundStyle(status.needsAttention ? Color.orange : Color.primary)
            Text(status.detail).foregroundStyle(.secondary)
            if case .scheduled(let date) = status {
                Text(date, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .monospacedDigit()
            }
            if status != .off {
                Text("Requires QuotaBar running and the Mac awake.").foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
