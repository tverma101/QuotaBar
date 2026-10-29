import AppKit

/// Owns the optional local diagnostic bridge alongside the existing status-item controller.
@MainActor
final class DiagnosticDashboardController {
    private let dataStore: WidgetDataStore
    private let show: () -> Void
    private let close: () -> Void
    private var control: DiagnosticControl?
    private var refreshTask: Task<Void, Never>?
    private var refreshGate = BackgroundRefreshGate(minimumInterval: 5.0)

    init(dataStore: WidgetDataStore, show: @escaping () -> Void,
         close: @escaping () -> Void) {
        self.dataStore = dataStore
        self.show = show
        self.close = close
        control = DiagnosticControl { [weak self] in self?.handle($0) }
    }

    func stop() {
        control = nil
        refreshTask?.cancel()
        refreshTask = nil
    }

    private func handle(_ request: DiagnosticRequest) {
        switch request {
        case .show(let providerID):
            show()
            if let providerID {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(300))
                    NotificationCenter.default.post(name: Notification.Name("com.quotabar.diagnostics.focus"),
                                                    object: providerID)
                }
            }
            AppLog.info(.statusItem, "diagnostic dashboard opened")
        case .close: close()
        case .refresh(let providerID):
            guard refreshGate.shouldAccept(at: Date()) else {
                AppLog.debug(.refresh, "ignored rate-limited diagnostic refresh command")
                return
            }
            guard refreshTask == nil else { return }
            refreshTask = ProviderRefreshContext.withBackgroundContext {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    defer { self.refreshTask = nil }
                    AppLog.info(.refresh, "diagnostic forced refresh started (Keychain UI disabled)")
                    if let providerID {
                        _ = await self.dataStore.refresh(providerID: providerID, force: true)
                    } else {
                        await self.dataStore.refreshAll(force: true)
                    }
                    AppLog.info(.refresh, "diagnostic forced refresh completed")
                }
            }
        }
    }

}
