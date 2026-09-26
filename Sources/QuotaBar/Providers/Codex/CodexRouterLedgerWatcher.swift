import Darwin
import Foundation

/// Watches CodexRouter's append-only `usage-events.jsonl` and posts a coalesced wake so the refresh
/// loop can re-scan the shared incremental tail shortly after a routed turn completes.
///
/// Design constraints (efficiency architecture):
/// - Does **not** reparse the ledger itself — only signals `RefreshWakeSignal`.
/// - Posts only while the panel is open (menuBar scope skips JSONL history; waking on every turn
///   while closed would burn ChatGPT Session/Weekly API calls for no icon benefit).
/// - Debounces write storms (~1s) so a multi-tool turn does not enqueue a refresh per line.
/// - Uses `DispatchSource` vnode watches (cheap, no polling). Recreates the source after rename
///   rotate so a truncated/replaced ledger is not silently ignored.
/// - Also watches each ledger's parent directory so a ledger that appears after launch (first
///   routed turn / state-dir move) is armed without requiring an app restart. Directory events
///   only wake when a configured ledger path is newly present or its size changes — unrelated
///   churn under the router state dir does not invalidate Codex caches.
final class CodexRouterLedgerWatcher: @unchecked Sendable {
    static let didChangeNotification = Notification.Name("QuotaBar.CodexRouterLedgerDidChange")

    private let queue = DispatchQueue(label: "QuotaBar.CodexRouterLedgerWatcher")
    private let ledgerPaths: @Sendable () -> [String]
    private let isPanelOpen: @Sendable () -> Bool
    private let center: NotificationCenter
    private let debounceNanoseconds: UInt64

    private var sources: [DispatchSourceFileSystemObject] = []
    private var openDescriptors: [Int32] = []
    private var debounceWorkItem: DispatchWorkItem?
    private var started = false
    /// Standardized ledger path → size when last armed/observed (directory-wake filter).
    private var lastLedgerSizes: [String: UInt64] = [:]
    private var armedLedgerPaths: Set<String> = []

    init(
        ledgerPaths: (@Sendable () -> [String])? = nil,
        isPanelOpen: @escaping @Sendable () -> Bool,
        center: NotificationCenter = .default,
        debounceNanoseconds: UInt64 = 1_000_000_000
    ) {
        self.ledgerPaths = ledgerPaths ?? {
            CodexRouterUsageScanner.defaultLedgerPaths(
                environment: QuotaBarEnvironmentReader(),
                homeDirectory: FileManager.default.homeDirectoryForCurrentUser
            )
        }
        self.isPanelOpen = isPanelOpen
        self.center = center
        self.debounceNanoseconds = debounceNanoseconds
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !self.started else { return }
            self.started = true
            self.installSources()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.started = false
            self.teardownSources()
            self.debounceWorkItem?.cancel()
            self.debounceWorkItem = nil
        }
    }

    deinit {
        teardownSources()
        debounceWorkItem?.cancel()
    }

    private func installSources() {
        teardownSources()
        armedLedgerPaths.removeAll(keepingCapacity: true)
        var seenFiles: Set<String> = []
        var seenDirs: Set<String> = []
        for path in ledgerPaths() {
            let standardized = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            guard seenFiles.insert(standardized).inserted else { continue }
            let parent = URL(fileURLWithPath: standardized).deletingLastPathComponent().path
            if seenDirs.insert(parent).inserted {
                installDirectorySource(for: parent)
            }
            if installFileSource(for: standardized) {
                armedLedgerPaths.insert(standardized)
                if let size = fileSize(at: standardized) {
                    lastLedgerSizes[standardized] = size
                }
            }
        }
        if armedLedgerPaths.isEmpty {
            AppLog.debug("codex", "CodexRouter ledger watcher: no ledger file yet (parent dirs armed)")
        }
    }

    @discardableResult
    private func installFileSource(for path: String) -> Bool {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return false }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete, .link, .revoke, .attrib],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let data = source.data
            if data.contains(.rename) || data.contains(.delete) || data.contains(.revoke) {
                self.installSources()
                self.scheduleDebouncedWake()
                return
            }
            if let size = self.fileSize(at: path) {
                self.lastLedgerSizes[path] = size
            }
            self.scheduleDebouncedWake()
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        openDescriptors.append(fd)
        sources.append(source)
        AppLog.debug("codex", "CodexRouter ledger watcher armed at \(path)")
        return true
    }

    private func installDirectorySource(for directoryPath: String) {
        let fd = open(directoryPath, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete, .link, .revoke],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let beforeArmed = self.armedLedgerPaths
            let beforeSizes = self.lastLedgerSizes
            self.installSources()
            let newlyArmed = !self.armedLedgerPaths.isSubset(of: beforeArmed)
            let sizeChanged = self.ledgerPaths().contains { raw in
                let path = URL(fileURLWithPath: raw).resolvingSymlinksInPath().path
                let newSize = self.fileSize(at: path)
                let oldSize = beforeSizes[path]
                return newSize != oldSize
            }
            if newlyArmed || sizeChanged {
                self.scheduleDebouncedWake()
            }
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        openDescriptors.append(fd)
        sources.append(source)
    }

    private func teardownSources() {
        for source in sources {
            source.cancel()
        }
        sources.removeAll()
        openDescriptors.removeAll()
        armedLedgerPaths.removeAll(keepingCapacity: true)
    }

    private func scheduleDebouncedWake() {
        debounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.postIfPanelOpen()
        }
        debounceWorkItem = work
        queue.asyncAfter(deadline: .now() + .nanoseconds(Int(debounceNanoseconds)), execute: work)
    }

    private func postIfPanelOpen() {
        guard isPanelOpen() else { return }
        center.post(name: Self.didChangeNotification, object: nil)
    }

    private func fileSize(at path: String) -> UInt64? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return UInt64(st.st_size)
    }
}
