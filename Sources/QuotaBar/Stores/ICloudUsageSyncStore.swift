import Foundation
import Observation

struct UsageHistoryLoadResult: Sendable {
    var documents: [UsageHistoryDocument]
    var invalidFileMessages: [String]
}

protocol UsageHistoryFileStoring: Sendable {
    func loadDocuments() async throws -> UsageHistoryLoadResult
    func write(_ document: UsageHistoryDocument) async throws
    func delete(deviceID: String) async throws
}

protocol ICloudDeviceIDStoring: Sendable {
    func readDeviceID() throws -> String?
    func writeDeviceID(_ deviceID: String) throws
}

struct KeychainICloudDeviceIDStore: ICloudDeviceIDStoring {
    private let service: String
    private let keychain: any KeychainAccessing

    init(
        keychain: any KeychainAccessing = SecurityKeychainAccessor(),
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.tverma101.quotabar"
    ) {
        self.keychain = keychain
        self.service = "\(bundleIdentifier).icloud-sync-device-id.v1"
    }

    func readDeviceID() throws -> String? {
        try keychain.readGenericPasswordForRefreshForCurrentUser(service: service)
    }

    func writeDeviceID(_ deviceID: String) throws {
        try keychain.writeGenericPasswordForCurrentUser(service: service, value: deviceID)
    }
}

enum ICloudUsageSyncError: Error, LocalizedError {
    case unavailable

    var errorDescription: String? {
        "iCloud Drive isn’t available. Check that this Mac is signed into iCloud and iCloud Drive is on."
    }
}

/// Coordinated access to the app-private data area of QuotaBar's iCloud Documents container.
actor ICloudUsageHistoryFileStore: UsageHistoryFileStoring {
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func loadDocuments() async throws -> UsageHistoryLoadResult {
        let directory = try historyDirectory(create: false)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return UsageHistoryLoadResult(documents: [], invalidFileMessages: [])
        }

        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "json" }

        var documents: [UsageHistoryDocument] = []
        var errors: [String] = []
        for url in urls {
            do {
                let data = try coordinatedRead(url)
                let document = try decoder.decode(UsageHistoryDocument.self, from: data)
                try document.validate()
                documents.append(document)
            } catch {
                errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
                AppLog.warn(.config, "iCloud history ignored \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return UsageHistoryLoadResult(documents: documents, invalidFileMessages: errors)
    }

    func write(_ document: UsageHistoryDocument) async throws {
        try document.validate()
        let directory = try historyDirectory(create: true)
        let url = directory.appendingPathComponent(document.deviceID).appendingPathExtension("json")
        let data = try encoder.encode(document)
        try coordinatedWrite(data, to: url)
    }

    func delete(deviceID: String) async throws {
        let directory = try historyDirectory(create: false)
        let url = directory.appendingPathComponent(deviceID).appendingPathExtension("json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var coordinationError: NSError?
        var operationError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { coordinatedURL in
            do { try FileManager.default.removeItem(at: coordinatedURL) }
            catch { operationError = error }
        }
        if let coordinationError { throw coordinationError }
        if let operationError { throw operationError }
    }

    private func historyDirectory(create: Bool) throws -> URL {
        guard let container = FileManager.default.url(forUbiquityContainerIdentifier: nil) else {
            throw ICloudUsageSyncError.unavailable
        }
        let directory = container
            .appendingPathComponent("QuotaBar", isDirectory: true)
            .appendingPathComponent("History", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
        if create {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    private func coordinatedRead(_ url: URL) throws -> Data {
        var coordinationError: NSError?
        var result: Result<Data, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            result = Result { try Data(contentsOf: coordinatedURL) }
        }
        if let coordinationError { throw coordinationError }
        return try result?.get() ?? { throw CocoaError(.fileReadUnknown) }()
    }

    private func coordinatedWrite(_ data: Data, to url: URL) throws {
        var coordinationError: NSError?
        var operationError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinatedURL in
            do { try data.write(to: coordinatedURL, options: .atomic) }
            catch { operationError = error }
        }
        if let coordinationError { throw coordinationError }
        if let operationError { throw operationError }
    }
}

@MainActor
@Observable
final class ICloudUsageSyncStore {
    private static let enabledKey = "openusage.icloudSync.enabled.v1"
    private static let deviceIDKey = "openusage.icloudSync.deviceID.v1"

    private let defaults: UserDefaults
    private let fileStore: any UsageHistoryFileStoring
    private var identityError: String?
    private var identityReady = false
    private var pendingEnablementReconciliation = false
    private var enablementReconciliationInProgress = false
    private var disablementReconciliationInProgress = false
    private let dataStore: WidgetDataStore
    private let writeDebounce: Duration
    private let observesMetadataChanges: Bool
    private var writeTask: Task<Void, Never>?
    private var metadataQuery: NSMetadataQuery?
    private var notificationTokens: [NSObjectProtocol] = []
    private var syncActivityCount = 0

    private(set) var deviceID: String
    let deviceName: String
    var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            defaults.set(enabled, forKey: Self.enabledKey)
            pendingEnablementReconciliation = true
            Task { await applyEnabledChange() }
        }
    }
    private(set) var isSyncing = false
    private var operationError: String?
    var serviceError: String? { operationError ?? identityError }
    private(set) var invalidFileMessages: [String] = []
    private(set) var documents: [UsageHistoryDocument] = []

    init(
        dataStore: WidgetDataStore,
        defaults: UserDefaults = .standard,
        fileStore: any UsageHistoryFileStoring = ICloudUsageHistoryFileStore(),
        deviceIDStore: any ICloudDeviceIDStoring = KeychainICloudDeviceIDStore(),
        writeDebounce: Duration = .seconds(3),
        observesMetadataChanges: Bool = true
    ) {
        self.dataStore = dataStore
        self.defaults = defaults
        self.fileStore = fileStore
        self.writeDebounce = writeDebounce
        self.observesMetadataChanges = observesMetadataChanges
        let savedDeviceID = Self.normalizedDeviceID(defaults.string(forKey: Self.deviceIDKey))
        self.deviceID = savedDeviceID
            ?? UUID().uuidString.lowercased()
        self.identityError = nil
        self.deviceName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        self.enabled = defaults.bool(forKey: Self.enabledKey)
        self.pendingEnablementReconciliation = self.enabled
        dataStore.onLocalHistoryChanged = { [weak self] in self?.scheduleWrite() }
        Task { [weak self, defaults, deviceIDStore] in
            let identity = await loadOffMainActor {
                Self.resolveDeviceID(savedID: savedDeviceID, store: deviceIDStore)
            }
            guard let self else { return }
            defaults.set(identity.id, forKey: Self.deviceIDKey)
            self.deviceID = identity.id
            self.identityError = identity.error
            self.identityReady = true
            if self.pendingEnablementReconciliation {
                await self.applyEnabledChange()
            }
        }
    }

    var displayedDocuments: [UsageHistoryDocument] {
        documents.sorted { lhs, rhs in
            if lhs.deviceID == deviceID { return true }
            if rhs.deviceID == deviceID { return false }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    func scheduleWrite() {
        guard enabled, identityReady else { return }
        writeTask?.cancel()
        writeTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: writeDebounce)
            guard !Task.isCancelled else { return }
            await writeNow()
        }
    }

    private func applyEnabledChange() async {
        guard identityReady, pendingEnablementReconciliation else { return }
        let shouldEnable = enabled
        if shouldEnable {
            // Enable work is single-flight so the identity-completion callback and a queued toggle
            // cannot both perform the initial reload/write.
            guard !enablementReconciliationInProgress,
                  !disablementReconciliationInProgress
            else { return }
            enablementReconciliationInProgress = true
            pendingEnablementReconciliation = false
            defer {
                enablementReconciliationInProgress = false
                schedulePendingEnablementReconciliation(after: true)
            }
            startObserving()
            await reload()
            await writeNow()
        } else {
            // Disabling must run while an enable write is in flight: it removes any existing copy,
            // and writeNow removes the just-finished write if the coordinated write returns later.
            guard !disablementReconciliationInProgress else { return }
            disablementReconciliationInProgress = true
            pendingEnablementReconciliation = false
            defer {
                disablementReconciliationInProgress = false
                schedulePendingEnablementReconciliation(after: false)
            }
            writeTask?.cancel()
            stopObserving()
            dataStore.clearPeerHistoryDocuments()
            documents = []
            invalidFileMessages = []
            do {
                try await fileStore.delete(deviceID: deviceID)
                operationError = nil
            } catch {
                report(error, context: "disable")
            }
        }
    }

    private func schedulePendingEnablementReconciliation(after reconciledState: Bool) {
        guard identityReady, pendingEnablementReconciliation else { return }
        if enabled == reconciledState, !disablementReconciliationInProgress {
            pendingEnablementReconciliation = false
            return
        }
        Task { [weak self] in await self?.applyEnabledChange() }
    }

    private func writeNow() async {
        guard enabled, identityReady else { return }
        await withSyncActivity {
            let document = dataStore.localHistoryDocument(
                deviceID: deviceID,
                deviceName: deviceName
            )
            do {
                try await fileStore.write(document)
                // Disabling can run while the coordinated write is in flight. If it did, remove the
                // just-finished write as well so this Mac cannot reappear in peers after opting out.
                guard enabled else {
                    try await fileStore.delete(deviceID: deviceID)
                    return
                }
                operationError = nil
                await reload()
            } catch {
                report(error, context: "write")
            }
        }
    }

    private func reload() async {
        guard enabled, identityReady else { return }
        await withSyncActivity {
            do {
                let result = try await fileStore.loadDocuments()
                // A read that began while enabled must not restore peer state after sync was disabled.
                guard enabled else { return }
                documents = UsageHistoryDocument.newestByDevice(result.documents)
                invalidFileMessages = result.invalidFileMessages
                dataStore.setPeerHistoryDocuments(result.documents, ownDeviceID: deviceID)
                operationError = result.invalidFileMessages.isEmpty
                    ? nil
                    : "Some synced usage data couldn’t be read. Check the log for details."
            } catch {
                report(error, context: "read")
            }
        }
    }

    private func withSyncActivity(_ operation: () async -> Void) async {
        syncActivityCount += 1
        isSyncing = true
        await operation()
        syncActivityCount -= 1
        isSyncing = syncActivityCount > 0
    }

    private func report(_ error: Error, context: String) {
        operationError = error.localizedDescription
        AppLog.warn(.config, "iCloud history \(context) failed: \(error.localizedDescription)")
    }

    nonisolated private static func resolveDeviceID(
        savedID: String?,
        store: any ICloudDeviceIDStoring
    ) -> (id: String, error: String?) {
        do {
            if let stored = normalizedDeviceID(try store.readDeviceID()) {
                return (stored, nil)
            }

            let id = savedID ?? UUID().uuidString.lowercased()
            try store.writeDeviceID(id)
            return (id, nil)
        } catch {
            let id = savedID ?? UUID().uuidString.lowercased()
            let message = "QuotaBar couldn’t save this Mac’s sync identity in Keychain. "
                + "Sync may create a duplicate device if app preferences are reset."
            AppLog.warn(.keychain, "iCloud device identity failed: \(error.localizedDescription)")
            return (id, message)
        }
    }

    nonisolated private static func normalizedDeviceID(_ value: String?) -> String? {
        guard let value, UUID(uuidString: value) != nil else { return nil }
        return value.lowercased()
    }

    private func startObserving() {
        guard observesMetadataChanges else { return }
        guard metadataQuery == nil else { return }
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(format: "%K LIKE '*.json'", NSMetadataItemFSNameKey)
        let center = NotificationCenter.default
        notificationTokens = [
            center.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.metadataQuery?.enableUpdates()
                    await self.reload()
                }
            },
            center.addObserver(forName: .NSMetadataQueryDidUpdate, object: query, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.reload() }
            }
        ]
        metadataQuery = query
        query.start()
    }

    private func stopObserving() {
        metadataQuery?.stop()
        metadataQuery = nil
        for token in notificationTokens { NotificationCenter.default.removeObserver(token) }
        notificationTokens = []
    }
}
