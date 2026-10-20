import Foundation

enum DiagnosticRequest: Equatable, Sendable {
    case show(providerID: String?)
    case close
    case refresh(providerID: String?)

    init?(command: String?, providerID: Any?) {
        switch command {
        case "show":
            if let providerID, !(providerID is String) { return nil }
            self = .show(providerID: (providerID as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty)
        case "close": self = .close
        case "refresh":
            if let providerID, !(providerID is String) { return nil }
            self = .refresh(providerID: (providerID as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty)
        default: return nil
        }
    }
}

/// Same-user, local-only diagnostic control. No HTTP mutation endpoint, credential interaction, or
/// persisted settings changes. The status-item controller owns the observer and its refresh task.
final class DiagnosticControl: @unchecked Sendable {
    static let name = Notification.Name("com.quotabar.diagnostics")
    private let center: DistributedNotificationCenter
    private var observer: NSObjectProtocol?

    init(
        center: DistributedNotificationCenter = DistributedNotificationCenter(),
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.tverma101.quotabar",
        onRequest: @escaping @MainActor @Sendable (DiagnosticRequest) -> Void
    ) {
        self.center = center
        observer = center.addObserver(forName: Self.name, object: nil, queue: .main) { notification in
            guard notification.userInfo?["bundleID"] as? String == bundleIdentifier else { return }
            guard let request = DiagnosticRequest(command: notification.object as? String,
                                                  providerID: notification.userInfo?["providerID"]) else {
                AppLog.warn(.config, "ignored invalid local diagnostic command")
                return
            }
            Task { @MainActor in onRequest(request) }
        }
    }

    deinit {
        if let observer { center.removeObserver(observer) }
    }
}
