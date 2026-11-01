import SwiftUI

enum CodexAutoResetStatus: Equatable {
    case off, unverified, checking, monitoring, due
    case scheduled(Date)
    case attention(String)
    case windowPassed(nextAttempt: Date?)

    var title: String {
        switch self {
        case .off: "Auto-Use Off"
        case .unverified: "Auto-Use Needs Sign-In"
        case .checking: "Checking Reset Credits"
        case .monitoring, .scheduled: "Auto-Use On"
        case .due: "Auto-Use Due"
        case .attention: "Auto-Use Needs Attention"
        case .windowPassed: "Reset Window Passed"
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
        case .windowPassed:
            "A previously seen credit passed its expiry without a confirmed automatic reset. It may have expired or been used elsewhere."
        }
    }

    var needsAttention: Bool {
        switch self {
        case .unverified, .attention, .windowPassed: true
        default: false
        }
    }

    var nextAttempt: Date? {
        switch self {
        case .scheduled(let date): date
        case .windowPassed(let date): date
        default: nil
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
            if let date = status.nextAttempt {
                if case .windowPassed = status { Text("Next scheduled attempt:").foregroundStyle(.secondary) }
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
