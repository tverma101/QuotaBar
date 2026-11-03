import Observation

/// Local-only setup hints shown in Customize. A match never changes provider enablement.
@MainActor
@Observable
final class ProviderSetupDiscoveryStore {
    private(set) var isScanning = false
    private(set) var hasScanned = false
    private(set) var foundProviderIDs: Set<String> = []

    @ObservationIgnored private var scanTask: Task<Void, Never>?

    var foundProviderFamilyCount: Int {
        Set(foundProviderIDs.map { ProviderAccountID.family(of: $0) }).count
    }

    func hasLocalSetup(for providerID: String) -> Bool {
        foundProviderIDs.contains(providerID)
            || foundProviderIDs.contains(ProviderAccountID.family(of: providerID))
    }

    func scanIfNeeded(providers: [ProviderRuntime]) {
        guard !hasScanned else { return }
        scan(providers: providers)
    }

    func rescan(providers: [ProviderRuntime]) {
        scan(providers: providers)
    }

    private func scan(providers: [ProviderRuntime]) {
        guard !isScanning else { return }
        isScanning = true
        hasScanned = false
        foundProviderIDs = []

        scanTask = Task { @MainActor [weak self] in
            var matches: Set<String> = []
            // Bound concurrent Keychain, SQLite, and file probes while keeping the screen responsive.
            for start in stride(from: 0, to: providers.count, by: 3) {
                let end = min(start + 3, providers.count)
                let batch = providers[start..<end].map { provider in
                    Task { @MainActor in
                        await provider.hasLocalCredentials() ? provider.provider.id : nil
                    }
                }
                for probe in batch {
                    if let providerID = await probe.value {
                        matches.insert(providerID)
                    }
                }
            }

            guard let self else { return }
            self.foundProviderIDs = matches
            self.hasScanned = true
            self.isScanning = false
            self.scanTask = nil
        }
    }
}
