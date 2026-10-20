import Darwin
import Foundation

/// Watches CodexRouter's append-only `usage-events.jsonl` and posts a coalesced wake so the refresh
/// loop can re-scan the shared incremental tail shortly after a routed turn completes.
///
/// Design constraints (efficiency architecture):
/// - Does **not** reparse the ledger itself — only signals `RefreshWakeSignal`.
/// - Panel-open turns post immediately (spend tiles refresh within ~1s of a routed turn).
///   Closed-panel turns post too, but rate-limited to one per `BackgroundRefreshTrigger.minimumPassInterval`
///   seconds: the loop answers them with a paced `localAccounting` pass (local folds only, no live
///   quota API re-reads), so a turn storm cannot burn ChatGPT Session/Weekly API calls for icons
///   nobody is looking at. Events inside the cooldown coalesce into one trailing wake at the next
///   allowed time, so the final append is caught even if no later event arrives.
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
    /// Mutated only on `queue` (the debounce/tap handlers run there).
    private var closedPanelWakeGate: BackgroundRefreshGate
    private var panelOpenWakeGate: BackgroundRefreshGate

    private typealias SourceRecord = (source: DispatchSourceFileSystemObject, descriptor: Int32)
    private var fileSources: [String: SourceRecord] = [:]
    private var directorySources: [String: SourceRecord] = [:]
    private var debounceWorkItem: DispatchWorkItem?
    private var trailingClosedPanelWakeWorkItem: DispatchWorkItem?
    private var trailingPanelOpenWakeWorkItem: DispatchWorkItem?
    private var started = false
    /// Standardized ledger path → size when last armed/observed (directory-wake filter).
    private var lastLedgerSizes: [String: UInt64] = [:]
    /// Standardized ledger path → device/inode pair, to notice atomic replacement on directory wakes.
    private var lastLedgerIdentities: [String: String] = [:]

    init(
        ledgerPaths: (@Sendable () -> [String])? = nil,
        isPanelOpen: @escaping @Sendable () -> Bool,
        center: NotificationCenter = .default,
        debounceNanoseconds: UInt64 = 1_000_000_000,
        closedPanelWakeGate: BackgroundRefreshGate = BackgroundRefreshGate(
            minimumInterval: BackgroundRefreshTrigger.minimumPassInterval
        ),
        panelOpenWakeGate: BackgroundRefreshGate = BackgroundRefreshGate(
            minimumInterval: 10.0
        )
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
        self.closedPanelWakeGate = closedPanelWakeGate
        self.panelOpenWakeGate = panelOpenWakeGate
    }

    func start() {
        setEnabled(true)
    }

    /// Watches CodexRouter only while at least one Codex card is enabled. Keeping the watcher
    /// dormant otherwise avoids even opening/statting a turned-off provider's source files.
    func setEnabled(_ enabled: Bool) {
        queue.async { [weak self] in
            guard let self, self.started != enabled else { return }
            self.started = enabled
            if enabled {
                self.installSources()
            } else {
                self.teardownSources()
                self.debounceWorkItem?.cancel()
                self.debounceWorkItem = nil
                self.trailingClosedPanelWakeWorkItem?.cancel()
                self.trailingClosedPanelWakeWorkItem = nil
                self.trailingPanelOpenWakeWorkItem?.cancel()
                self.trailingPanelOpenWakeWorkItem = nil
            }
        }
    }

    func stop() {
        setEnabled(false)
    }

    deinit {
        teardownSources()
        debounceWorkItem?.cancel()
        trailingClosedPanelWakeWorkItem?.cancel()
        trailingPanelOpenWakeWorkItem?.cancel()
    }

    private func installSources() {
        teardownSources()
        let paths = standardizedLedgerPaths()
        reconcileDirectorySources(for: paths)
        _ = refreshLedgerFileSources(for: paths)
        if fileSources.isEmpty {
            AppLog.debug("codex", "CodexRouter ledger watcher: no ledger file yet (parent dirs armed)")
        }
    }

    private func standardizedLedgerPaths() -> [String] {
        var seen: Set<String> = []
        return ledgerPaths().compactMap { raw in
            let path = URL(fileURLWithPath: raw).resolvingSymlinksInPath().path
            return seen.insert(path).inserted ? path : nil
        }
    }

    /// Directory notifications are common while a ledger is appended. Keep existing vnode sources
    /// armed and only open a file source when a ledger appears or its inode is replaced; restarting
    /// every watch on each append produced a debug-log storm and gaps where writes were not watched.
    @discardableResult
    private func refreshLedgerFileSources(for paths: [String]) -> (newlyArmed: Bool, sizeChanged: Bool) {
        let configured = Set(paths)
        for stalePath in Array(fileSources.keys) where !configured.contains(stalePath) {
            disarmFileSource(for: stalePath)
        }

        var newlyArmed = false
        var sizeChanged = false
        for path in paths {
            guard let size = fileSize(at: path), let identity = fileIdentity(at: path) else {
                disarmFileSource(for: path)
                continue
            }

            if fileSources[path] == nil || lastLedgerIdentities[path] != identity {
                disarmFileSource(for: path)
                guard installFileSource(for: path) else { continue }
                lastLedgerSizes[path] = size
                lastLedgerIdentities[path] = identity
                newlyArmed = true
                continue
            }

            if let oldSize = lastLedgerSizes[path], oldSize != size {
                sizeChanged = true
            }
            lastLedgerSizes[path] = size
        }
        return (newlyArmed, sizeChanged)
    }

    private func disarmFileSource(for path: String) {
        fileSources.removeValue(forKey: path)?.source.cancel()
        lastLedgerSizes[path] = nil
        lastLedgerIdentities[path] = nil
    }

    @discardableResult
    private func installFileSource(for path: String) -> Bool {
        guard fileSources[path] == nil else { return true }
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
                self.disarmFileSource(for: path)
                _ = self.refreshLedgerFileSources(for: self.standardizedLedgerPaths())
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
        fileSources[path] = (source, fd)
        AppLog.debug("codex", "CodexRouter ledger watcher armed at \(path)")
        return true
    }

    private func installDirectorySource(for directoryPath: String) {
        guard directorySources[directoryPath] == nil else { return }
        let fd = open(directoryPath, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete, .link, .revoke],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let oldSizes = self.lastLedgerSizes
            let oldIdentities = self.lastLedgerIdentities
            let data = source.data
            let paths = self.standardizedLedgerPaths()
            if data.contains(.rename) || data.contains(.delete) || data.contains(.revoke) {
                // A directory vnode stays attached to the old inode after an atomic state-dir
                // replacement. Drop it, then arm the path and its immediate ancestor so a later
                // recreation is noticed even when the path was briefly absent.
                self.directorySources.removeValue(forKey: directoryPath)?.source.cancel()
            }
            self.reconcileDirectorySources(for: paths)
            let state = self.refreshLedgerFileSources(for: paths)
            let pathChanged = paths.contains {
                oldSizes[$0] != self.lastLedgerSizes[$0]
                    || oldIdentities[$0] != self.lastLedgerIdentities[$0]
            }
            if state.newlyArmed || state.sizeChanged || pathChanged {
                self.scheduleDebouncedWake()
            }
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        directorySources[directoryPath] = (source, fd)
    }

    /// Watch each ledger parent plus one ancestor. The extra vnode lets us re-arm a parent directory
    /// after it is renamed away and recreated; it does not wake for unrelated ancestor churn unless
    /// a configured ledger's presence, identity, or size changes.
    private func reconcileDirectorySources(for ledgerPaths: [String]) {
        var desired: Set<String> = []
        for ledgerPath in ledgerPaths {
            var directory = URL(fileURLWithPath: ledgerPath).deletingLastPathComponent().path
            while true {
                desired.insert(directory)
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory),
                   isDirectory.boolValue {
                    // Keep one existing ancestor armed so removal/recreation of this directory can
                    // be discovered even when its own vnode is now attached to a deleted inode.
                    let ancestor = URL(fileURLWithPath: directory).deletingLastPathComponent().path
                    desired.insert(ancestor)
                    break
                }
                let ancestor = URL(fileURLWithPath: directory).deletingLastPathComponent().path
                guard ancestor != directory else { break }
                directory = ancestor
            }
        }
        for stalePath in Array(directorySources.keys) where !desired.contains(stalePath) {
            directorySources.removeValue(forKey: stalePath)?.source.cancel()
        }
        for path in desired where directorySources[path] == nil {
            installDirectorySource(for: path)
        }
    }

    private func teardownSources() {
        for record in fileSources.values { record.source.cancel() }
        for record in directorySources.values { record.source.cancel() }
        fileSources.removeAll()
        directorySources.removeAll()
        lastLedgerSizes.removeAll()
        lastLedgerIdentities.removeAll()
    }

    private func scheduleDebouncedWake() {
        debounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.postIfWorthy()
        }
        debounceWorkItem = work
        queue.asyncAfter(deadline: .now() + .nanoseconds(Int(debounceNanoseconds)), execute: work)
    }

    private func postIfWorthy() {
        // Panel-open wakes have a 10s cooldown to prevent streaming agents from pinning CPU at 100%.
        // Closed-panel wakes pass the 15s background gate. In both cases, a rejected event schedules
        // a trailing wake at the next allowed time, ensuring no final append is lost.
        let now = Date()
        if isPanelOpen() {
            trailingClosedPanelWakeWorkItem?.cancel()
            trailingClosedPanelWakeWorkItem = nil
            guard panelOpenWakeGate.shouldAccept(at: now) else {
                scheduleTrailingPanelOpenWake(after: panelOpenWakeGate.delayUntilNextAcceptance(at: now))
                return
            }
            trailingPanelOpenWakeWorkItem?.cancel()
            trailingPanelOpenWakeWorkItem = nil
            center.post(name: Self.didChangeNotification, object: nil)
            return
        }

        trailingPanelOpenWakeWorkItem?.cancel()
        trailingPanelOpenWakeWorkItem = nil
        guard closedPanelWakeGate.shouldAccept(at: now) else {
            scheduleTrailingClosedPanelWake(after: closedPanelWakeGate.delayUntilNextAcceptance(at: now))
            return
        }
        trailingClosedPanelWakeWorkItem?.cancel()
        trailingClosedPanelWakeWorkItem = nil
        center.post(name: Self.didChangeNotification, object: nil)
    }

    private func scheduleTrailingPanelOpenWake(after delay: TimeInterval) {
        guard trailingPanelOpenWakeWorkItem == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.trailingPanelOpenWakeWorkItem = nil
            self.postIfWorthy()
        }
        trailingPanelOpenWakeWorkItem = work
        queue.asyncAfter(deadline: .now() + max(0, delay), execute: work)
    }

    private func scheduleTrailingClosedPanelWake(after delay: TimeInterval) {
        guard trailingClosedPanelWakeWorkItem == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.trailingClosedPanelWakeWorkItem = nil
            self.postIfWorthy()
        }
        trailingClosedPanelWakeWorkItem = work
        queue.asyncAfter(deadline: .now() + max(0, delay), execute: work)
    }

    private func fileSize(at path: String) -> UInt64? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return UInt64(st.st_size)
    }

    private func fileIdentity(at path: String) -> String? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return "\(st.st_dev):\(st.st_ino)"
    }
}
