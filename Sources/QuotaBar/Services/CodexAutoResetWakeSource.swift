import AppKit
import Network

/// Wake the existing per-account workers without cancelling a suspended provider write.
/// Events buffer in RefreshWakeSignal; repeated events coalesce while a check is running.
@MainActor
final class CodexAutoResetWakeSource {
    private let center: NotificationCenter
    private let workspaceCenter: NotificationCenter
    private let monitor: NWPathMonitor
    private var wasOnline: Bool?
    private nonisolated(unsafe) var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init(center: NotificationCenter) {
        self.center = center
        self.workspaceCenter = NSWorkspace.shared.notificationCenter
        self.monitor = NWPathMonitor()
        for (source, name) in [(workspaceCenter, NSWorkspace.didWakeNotification),
                               (NotificationCenter.default, .NSSystemClockDidChange)] {
            let token = source.addObserver(forName: name, object: nil, queue: nil) { [center] _ in
                center.post(name: CodexAutoResetCoordinator.wakeNotification, object: nil)
            }
            observers.append((source, token))
        }
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor [weak self] in self?.connectivityChanged(online: online) }
        }
        monitor.start(queue: DispatchQueue(label: "QuotaBar.CodexResetConnectivity", qos: .utility))
    }

    deinit {
        monitor.cancel()
        for (source, token) in observers { source.removeObserver(token) }
    }

    private func connectivityChanged(online: Bool) {
        defer { wasOnline = online }
        guard wasOnline == false, online else { return }
        center.post(name: CodexAutoResetCoordinator.wakeNotification, object: nil)
    }
}
