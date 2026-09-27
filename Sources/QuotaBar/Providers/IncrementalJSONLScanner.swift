import Foundation

/// The `Item`-independent half of the incremental scan machinery: file discovery and the scan-window
/// lower bound. A non-generic namespace keeps file discovery independent of each provider's parsed
/// row type and lets call sites read `JSONLScanning.sinceDate(...)`.
enum JSONLScanning {
    /// A discovered log file plus the stat fields the parse cache is keyed on. Attribute modification
    /// time is the metadata-change timestamp (ctime-like on Darwin): it changes on an in-place rewrite
    /// even when a writer restores the old content mtime and byte length.
    struct DiscoveredFile: Sendable {
        var path: String
        var size: Int
        var mtime: Date
        var attributeMtime: Date? = nil
    }

    /// Start of the day `daysBack` days before `now` — the lower bound of the scan window.
    static func sinceDate(daysBack: Int, now: Date) -> Date {
        let shifted = Calendar.current.date(byAdding: .day, value: -daysBack, to: now) ?? now
        return Calendar.current.startOfDay(for: shifted)
    }

    /// Every `*.jsonl` regular file under `dir` (recursively), path-sorted so a keep-first dedup is
    /// deterministic. Empty when `dir` can't be enumerated.
    static func jsonlFiles(under dir: URL) -> [DiscoveredFile] {
        // `FileManager.enumerator` silently yields nothing when `dir` itself is a symlink.
        // Resolve first so the enumeration sees the real directory.
        let dir = dir.resolvingSymlinksInPath()
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .attributeModificationDateKey,
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: keys, options: []
        ) else { return [] }
        var files: [DiscoveredFile] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true
            else { continue }
            files.append(DiscoveredFile(
                path: url.path,
                size: values.fileSize ?? 0,
                mtime: values.contentModificationDate ?? .distantPast,
                attributeMtime: values.attributeModificationDate
            ))
        }
        return files.sorted { $0.path < $1.path }
    }
}

/// The incremental, off-main-actor scan machinery shared by the Claude, Codex, Grok, and pi log scanners:
/// discover `*.jsonl` files, re-parse only those changed since the last scan (a per-file cache keyed by
/// path + size + content mtime + attribute mtime), and return the parsed items concatenated in file order.
/// Each provider supplies its own file discovery, per-file parser, and post-parse dedup/aggregation; this
/// owns the cache, bounded parallel parse, mtime-window skip, and JSONL enumeration.
///
/// An actor so the parse cache persists across the ~5-minute provider refreshes while staying off the
/// main actor. Provider scanner instances share one actor per parser; `Item` is that parser's row.
actor IncrementalJSONLScanner<Item: Codable & Sendable> {
    private typealias CachedFile = JSONLScanCachedFile<Item>

    private struct IdentityWaiter {
        var id: UUID
        var continuation: CheckedContinuation<Bool, Never>
    }

    /// One in-memory partition per provider/home identity. Provider scanner instances share this actor,
    /// so same-home multi-account cards reuse both memory and disk without letting disjoint homes prune
    /// one another's files. Long-running account/home churn is bounded by an LRU resident-identity cap;
    /// evicted identities reload from the authoritative disk cache (or safely reparse when persistence
    /// is disabled) instead of remaining in RAM forever.
    private var caches: [String: [String: CachedFile]] = [:]
    private var persistedMetadata: [String: [String: JSONLScanCacheFileMetadata]] = [:]
    /// Eagerly snapshotted upsert payloads. Encoding happens when a path becomes dirty so
    /// `CachedFile.items` can be unloaded before the debounced writer runs.
    private var pendingUpserts: [String: [String: JSONLScanCacheUpsert]] = [:]
    private var dirtyRemovals: [String: [String: JSONLScanCacheFileMetadata]] = [:]
    private var invalidPersistenceIdentities: Set<String> = []
    private var loadedIdentities: Set<String> = []
    private var activeIdentities: Set<String> = []
    private var identityWaiters: [String: [IdentityWaiter]] = [:]
    private var writeTasks: [String: Task<Void, Never>] = [:]
    private var writeGenerations: [String: Int] = [:]
    private var residentAccessTick: UInt64 = 0
    private var residentAccessByIdentity: [String: UInt64] = [:]
    private let maxConcurrentParses: Int
    private let maxResidentIdentities: Int
    /// When false, `CachedFile.items` are cleared after each `items()` return and identities load
    /// metadata-only from disk. Codex/Claude/Grok/Muse/Pi enable this so resident parse arrays are
    /// not retained between refreshes (hydrate from disk or reparse on the next scan).
    private let retainResidentItems: Bool
    private let parsePermitPool: JSONLParsePermitPool
    private let readFailureReporter: UsageLogReadFailureReporter
    private let persistence: JSONLScanCachePersistence?

    init(
        maxConcurrentParses: Int = 2,
        maxResidentIdentities: Int = 8,
        retainResidentItems: Bool = true,
        logTag: String = LogTag.refresh.rawValue,
        readFailureWarning: UsageLogReadFailureReporter.Warning? = nil,
        persistence: JSONLScanCachePersistence? = nil
    ) {
        precondition(maxConcurrentParses > 0)
        precondition(maxResidentIdentities > 0)
        self.maxConcurrentParses = maxConcurrentParses
        self.maxResidentIdentities = maxResidentIdentities
        self.retainResidentItems = retainResidentItems
        self.parsePermitPool = JSONLParsePermitPool(limit: maxConcurrentParses)
        self.readFailureReporter = UsageLogReadFailureReporter(logTag: logTag, warning: readFailureWarning)
        self.persistence = persistence
        if let persistence {
            let cutoff = Date().addingTimeInterval(-JSONLScanCachePaths.staleIdentityRetention)
            Task.detached(priority: .utility) {
                await JSONLScanCacheWriter.shared.pruneStaleIdentities(
                    persistence: persistence,
                    before: cutoff
                )
            }
        }
    }

    /// Compatibility overload for parsers that already own a `Data`-based test surface. Production
    /// providers should use the URL overload below so large JSONL files are parsed incrementally.
    func items(
        from files: [JSONLScanning.DiscoveredFile],
        since: Date,
        cacheIdentity: String = "default",
        parse: @Sendable @escaping (Data) -> [Item]?
    ) async -> [Item]? {
        await items(from: files, since: since, cacheIdentity: cacheIdentity, parseFile: { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return parse(data)
        })
    }

    /// Re-parse the in-window files (reusing the cache only when the complete cheap revision tuple
    /// matches), then return every file's items concatenated in input order. Files whose content mtime
    /// predates `since` are skipped, so a years-deep tree stays cheap to rescan; an unreadable file is
    /// skipped and not cached, so a transient read failure doesn't stick. `nil` means cancellation.
    func items(
        from files: [JSONLScanning.DiscoveredFile],
        since: Date,
        cacheIdentity: String = "default",
        parseFile: @Sendable @escaping (URL) -> [Item]?
    ) async -> [Item]? {
        precondition(!cacheIdentity.isEmpty)
        guard await acquire(cacheIdentity) else { return nil }
        defer { release(cacheIdentity) }
        guard !Task.isCancelled else { return nil }

        await loadCacheIfNeeded(identity: cacheIdentity)
        guard !Task.isCancelled else { return nil }
        let currentCache = caches[cacheIdentity] ?? [:]
        // Keep other same-parser scans' files in the shared partition until they age out of the window.
        // This lets multi-account cards with disjoint roots share one actor safely; only the current
        // call's input paths are returned below.
        var nextCache = currentCache.filter { $0.value.mtime >= since }
        var toParse: [JSONLScanning.DiscoveredFile] = []
        for file in files {
            guard file.mtime >= since else { continue }
            if let cached = currentCache[file.path],
               cached.size == file.size,
               cached.mtime == file.mtime,
               cached.attributeMtime == file.attributeMtime
            {
                if cached.items.isEmpty && !retainResidentItems {
                    // Metadata hit after unload (or metadata-only disk load): hydrate one record or reparse.
                    if let hydrated = await hydrateResidentItems(
                        identity: cacheIdentity,
                        path: file.path,
                        expected: cached
                    ) {
                        nextCache[file.path] = hydrated
                    } else {
                        nextCache[file.path] = nil
                        toParse.append(file)
                    }
                } else {
                    nextCache[file.path] = cached
                }
            } else {
                nextCache[file.path] = nil
                toParse.append(file)
            }
        }
        let parseResults = await Self.parseFiles(
            toParse,
            maxConcurrentParses: maxConcurrentParses,
            permitPool: parsePermitPool,
            parseFile: parseFile
        )
        guard !Task.isCancelled else { return nil }
        let checkedPaths = Set(parseResults.lazy.map(\.file.path))
        let unreadablePaths = Set(parseResults.lazy.filter(\.readFailed).map(\.file.path))
        await readFailureReporter.update(checkedPaths: checkedPaths, failingPaths: unreadablePaths)
        guard !Task.isCancelled else { return nil }
        var newlyCached: [(path: String, cached: CachedFile)] = []
        for result in parseResults {
            let (file, parsed) = (result.file, result.items)
            guard let parsed else { continue }
            let cached = CachedFile(
                size: file.size,
                mtime: file.mtime,
                attributeMtime: file.attributeMtime,
                items: parsed
            )
            nextCache[file.path] = cached
            newlyCached.append((file.path, cached))
        }
        for (path, cached) in currentCache where nextCache[path] == nil {
            dirtyRemovals[cacheIdentity, default: [:]][path] = JSONLScanCacheFileMetadata(
                size: cached.size,
                mtime: cached.mtime,
                attributeMtime: cached.attributeMtime,
                recordFileName: JSONLScanCachePaths.recordFileName(path: path)
            )
            // A cancelled earlier debounce may still hold an upsert for this path. Drop it so the
            // prune commit cannot republish the record after removing it from the manifest.
            pendingUpserts[cacheIdentity]?[path] = nil
        }
        if !newlyCached.isEmpty {
            await snapshotPendingUpserts(identity: cacheIdentity, files: newlyCached)
        }
        caches[cacheIdentity] = nextCache
        touchResidentIdentity(cacheIdentity)
        if !(pendingUpserts[cacheIdentity] ?? [:]).isEmpty
            || !dirtyRemovals[cacheIdentity, default: [:]].isEmpty
            || invalidPersistenceIdentities.contains(cacheIdentity)
        {
            scheduleWrite(identity: cacheIdentity)
        }
        trimResidentIdentities(protecting: cacheIdentity)

        // Append then immediately drop resident items per file when unload mode is on, so peak RAM
        // is one growing result array rather than result + full nextCache duplication.
        var items: [Item] = []
        for file in files {
            guard let cached = nextCache[file.path] else { continue }
            items.append(contentsOf: cached.items)
            if !retainResidentItems {
                var cleared = cached
                cleared.items = []
                nextCache[file.path] = cleared
            }
        }
        caches[cacheIdentity] = nextCache
        return Task.isCancelled ? nil : items
    }

    /// Same scan/cache contract as `items`, but visits each file's rows and never builds a concatenated
    /// mega-array. Production Codex/Claude/OpenCode folds use this so a 13 GB session corpus cannot
    /// force a multi-hundred-MB `[Event]` spike on every refresh. Returns `false` on cancellation.
    @discardableResult
    func foldItems(
        from files: [JSONLScanning.DiscoveredFile],
        since: Date,
        cacheIdentity: String = "default",
        parseFile: @Sendable @escaping (URL) -> [Item]?,
        visit: @Sendable (Item) -> Void
    ) async -> Bool {
        precondition(!cacheIdentity.isEmpty)
        guard await acquire(cacheIdentity) else { return false }
        defer { release(cacheIdentity) }
        guard !Task.isCancelled else { return false }

        await loadCacheIfNeeded(identity: cacheIdentity)
        guard !Task.isCancelled else { return false }
        let currentCache = caches[cacheIdentity] ?? [:]
        var nextCache = currentCache.filter { $0.value.mtime >= since }
        var toParse: [JSONLScanning.DiscoveredFile] = []
        for file in files {
            guard file.mtime >= since else { continue }
            if let cached = currentCache[file.path],
               cached.size == file.size,
               cached.mtime == file.mtime,
               cached.attributeMtime == file.attributeMtime
            {
                if cached.items.isEmpty && !retainResidentItems {
                    if let hydrated = await hydrateResidentItems(
                        identity: cacheIdentity,
                        path: file.path,
                        expected: cached
                    ) {
                        nextCache[file.path] = hydrated
                    } else {
                        nextCache[file.path] = nil
                        toParse.append(file)
                    }
                } else {
                    nextCache[file.path] = cached
                }
            } else {
                nextCache[file.path] = nil
                toParse.append(file)
            }
        }
        let parseResults = await Self.parseFiles(
            toParse,
            maxConcurrentParses: maxConcurrentParses,
            permitPool: parsePermitPool,
            parseFile: parseFile
        )
        guard !Task.isCancelled else { return false }
        let checkedPaths = Set(parseResults.lazy.map(\.file.path))
        let unreadablePaths = Set(parseResults.lazy.filter(\.readFailed).map(\.file.path))
        await readFailureReporter.update(checkedPaths: checkedPaths, failingPaths: unreadablePaths)
        guard !Task.isCancelled else { return false }
        var newlyCached: [(path: String, cached: CachedFile)] = []
        for result in parseResults {
            let (file, parsed) = (result.file, result.items)
            guard let parsed else { continue }
            let cached = CachedFile(
                size: file.size,
                mtime: file.mtime,
                attributeMtime: file.attributeMtime,
                items: parsed
            )
            nextCache[file.path] = cached
            newlyCached.append((file.path, cached))
        }
        for (path, cached) in currentCache where nextCache[path] == nil {
            dirtyRemovals[cacheIdentity, default: [:]][path] = JSONLScanCacheFileMetadata(
                size: cached.size,
                mtime: cached.mtime,
                attributeMtime: cached.attributeMtime,
                recordFileName: JSONLScanCachePaths.recordFileName(path: path)
            )
            pendingUpserts[cacheIdentity]?[path] = nil
        }
        if !newlyCached.isEmpty {
            await snapshotPendingUpserts(identity: cacheIdentity, files: newlyCached)
        }
        caches[cacheIdentity] = nextCache
        touchResidentIdentity(cacheIdentity)
        if !(pendingUpserts[cacheIdentity] ?? [:]).isEmpty
            || !dirtyRemovals[cacheIdentity, default: [:]].isEmpty
            || invalidPersistenceIdentities.contains(cacheIdentity)
        {
            scheduleWrite(identity: cacheIdentity)
        }
        trimResidentIdentities(protecting: cacheIdentity)

        // Publishes the post-drain cache on *every* exit path, and unloads anything the visit loop
        // below did not reach.
        //
        // This is a correctness fix, not a precaution. `caches[cacheIdentity]` was already assigned
        // the fully-hydrated `nextCache` above, so a cancellation between that publish and the end
        // of the visit loop used to `return false` with every file's items still resident — stranding
        // the whole window in the actor until the next *successful* scan. Cancellation is routine
        // here, not exotic: `WidgetDataStore` wraps provider refreshes in a 120 s
        // `ProviderRefreshDeadline`, and the loop re-checks `Task.isCancelled` once per file, so any
        // large corpus that runs long hit this. Unvisited items are simply re-hydrated on demand by
        // the next scan, so dropping them costs one re-read, not correctness.
        defer {
            guard !retainResidentItems else { return }
            let unvisited = nextCache.keys.filter { nextCache[$0]?.items.isEmpty == false }
            for path in unvisited {
                guard var cached = nextCache[path] else { continue }
                cached.items = []
                nextCache[path] = cached
            }
            caches[cacheIdentity] = nextCache
        }

        for file in files {
            guard !Task.isCancelled else { return false }
            guard var cached = nextCache[file.path] else { continue }
            for item in cached.items {
                visit(item)
            }
            if !retainResidentItems {
                cached.items = []
                nextCache[file.path] = cached
            }
        }
        return !Task.isCancelled
    }

    /// Wait for the real debounced tasks rather than bypassing them. Tests configure a tiny debounce,
    /// then use this to prove ordinary scans actually schedule and finish persistence.
    func waitForPendingWritesForTesting() async {
        for task in Array(writeTasks.values) {
            await task.value
        }
    }

    /// Commits the latest snapshots immediately. One-shot processes call this before exiting; the
    /// long-lived app keeps the ordinary debounced path so refresh latency is unaffected.
    func flushPendingWrites() async {
        var identities = Set(writeTasks.keys)
        identities.formUnion(pendingUpserts.compactMap { $0.value.isEmpty ? nil : $0.key })
        identities.formUnion(dirtyRemovals.compactMap { $0.value.isEmpty ? nil : $0.key })
        identities.formUnion(invalidPersistenceIdentities)
        for identity in identities {
            writeTasks[identity]?.cancel()
            writeTasks[identity] = nil
            let generation = writeGenerations[identity, default: 0] + 1
            writeGenerations[identity] = generation
            await persistCache(identity: identity, generation: generation)
        }
    }

    func cacheRecordURLForTesting(identity: String, filePath: String) -> URL? {
        guard let persistence else { return nil }
        return JSONLScanCachePaths.recordURL(
            persistence: persistence,
            identity: identity,
            fileName: JSONLScanCachePaths.recordFileName(path: filePath)
        )
    }

    func queuedScanCountForTesting(identity: String) -> Int {
        identityWaiters[identity]?.count ?? 0
    }

    func residentIdentityCountForTesting() -> Int {
        caches.count
    }

    func residentItemCountForTesting() -> Int {
        caches.values.reduce(into: 0) { total, files in
            for cached in files.values {
                total += cached.items.count
            }
        }
    }

    // MARK: - Same-identity scan serialization

    private func acquire(_ identity: String) async -> Bool {
        guard activeIdentities.contains(identity) else {
            activeIdentities.insert(identity)
            return true
        }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    identityWaiters[identity, default: []].append(
                        IdentityWaiter(id: waiterID, continuation: continuation)
                    )
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(identity: identity, waiterID: waiterID) }
        }
    }

    private func cancelWaiter(identity: String, waiterID: UUID) {
        guard var waiters = identityWaiters[identity],
              let index = waiters.firstIndex(where: { $0.id == waiterID })
        else { return }
        let waiter = waiters.remove(at: index)
        identityWaiters[identity] = waiters.isEmpty ? nil : waiters
        waiter.continuation.resume(returning: false)
    }

    private func release(_ identity: String) {
        guard var waiters = identityWaiters[identity], !waiters.isEmpty else {
            activeIdentities.remove(identity)
            identityWaiters[identity] = nil
            return
        }
        let next = waiters.removeFirst()
        identityWaiters[identity] = waiters.isEmpty ? nil : waiters
        next.continuation.resume(returning: true)
    }

    // MARK: - Resident cache bounds

    private func touchResidentIdentity(_ identity: String) {
        residentAccessTick &+= 1
        residentAccessByIdentity[identity] = residentAccessTick
    }

    /// Drop least-recently-used in-memory partitions after their durable state is clean. This bounds
    /// account/home churn without changing the disk-retention policy. A partition with an in-flight or
    /// dirty persistent write is temporarily protected; the next scan can evict it after publication.
    private func trimResidentIdentities(protecting protectedIdentity: String) {
        while caches.count > maxResidentIdentities {
            let candidates = caches.keys.filter { identity in
                guard identity != protectedIdentity,
                      !activeIdentities.contains(identity),
                      identityWaiters[identity]?.isEmpty != false,
                      writeTasks[identity] == nil
                else { return false }

                if persistence != nil {
                    guard pendingUpserts[identity]?.isEmpty != false,
                          dirtyRemovals[identity]?.isEmpty != false,
                          !invalidPersistenceIdentities.contains(identity)
                    else { return false }
                }
                return true
            }
            guard let victim = candidates.min(by: {
                residentAccessByIdentity[$0, default: 0] < residentAccessByIdentity[$1, default: 0]
            }) else { return }
            evictResidentIdentity(victim)
        }
    }

    private func evictResidentIdentity(_ identity: String) {
        caches[identity] = nil
        persistedMetadata[identity] = nil
        pendingUpserts[identity] = nil
        dirtyRemovals[identity] = nil
        invalidPersistenceIdentities.remove(identity)
        loadedIdentities.remove(identity)
        residentAccessByIdentity[identity] = nil
        writeGenerations[identity] = nil
    }

    // MARK: - Persistence

    private func loadCacheIfNeeded(identity: String) async {
        guard loadedIdentities.insert(identity).inserted, let persistence else { return }
        do {
            if retainResidentItems {
                guard let snapshot = try JSONLScanCacheWriter.shared.load(
                    persistence: persistence,
                    identity: identity,
                    itemType: Item.self
                ) else { return }
                let manifest = snapshot.manifest
                guard manifest.formatVersion == JSONLScanCachePaths.formatVersion,
                      manifest.schemaVersion == persistence.schemaVersion,
                      manifest.identity == identity
                else {
                    AppLog.info(.cache, "\(persistence.namespace) log parse cache schema changed; rebuilding")
                    invalidPersistenceIdentities.insert(identity)
                    return
                }
                persistedMetadata[identity] = manifest.files
                caches[identity] = snapshot.files
                dirtyRemovals[identity, default: [:]].merge(snapshot.invalidRecords) { _, new in new }
                if !snapshot.invalidRecords.isEmpty {
                    AppLog.warn(
                        .cache,
                        "\(persistence.namespace) log parse cache has \(snapshot.invalidRecords.count) unreadable file records; reparsing"
                    )
                }
                AppLog.debug(
                    .cache,
                    "loaded \(snapshot.files.count) \(persistence.namespace) log files from parse cache"
                )
            } else {
                guard let manifest = try JSONLScanCacheWriter.shared.loadManifest(
                    persistence: persistence,
                    identity: identity
                ) else { return }
                guard manifest.formatVersion == JSONLScanCachePaths.formatVersion,
                      manifest.schemaVersion == persistence.schemaVersion,
                      manifest.identity == identity
                else {
                    AppLog.info(.cache, "\(persistence.namespace) log parse cache schema changed; rebuilding")
                    invalidPersistenceIdentities.insert(identity)
                    return
                }
                persistedMetadata[identity] = manifest.files
                var metadataOnly: [String: CachedFile] = [:]
                metadataOnly.reserveCapacity(manifest.files.count)
                for (path, metadata) in manifest.files {
                    metadataOnly[path] = CachedFile(
                        size: metadata.size,
                        mtime: metadata.mtime,
                        attributeMtime: metadata.attributeMtime,
                        items: []
                    )
                }
                caches[identity] = metadataOnly
                AppLog.debug(
                    .cache,
                    "loaded \(manifest.files.count) \(persistence.namespace) log files from parse cache (metadata-only)"
                )
            }
        } catch {
            invalidPersistenceIdentities.insert(identity)
            AppLog.warn(
                .cache,
                "\(persistence.namespace) log parse cache unreadable; rebuilding: \(error.localizedDescription)"
            )
        }
    }

    private func scheduleWrite(identity: String) {
        guard let persistence else { return }
        let generation = writeGenerations[identity, default: 0] + 1
        writeGenerations[identity] = generation
        writeTasks[identity]?.cancel()
        writeTasks[identity] = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: persistence.writeDebounce)
            } catch {
                await self.finishWriteTask(identity: identity, generation: generation)
                return
            }
            guard !Task.isCancelled else { return }
            await self.persistCache(identity: identity, generation: generation)
            await self.finishWriteTask(identity: identity, generation: generation)
        }
    }

    private func finishWriteTask(identity: String, generation: Int) {
        guard writeGenerations[identity] == generation else { return }
        writeTasks[identity] = nil
    }

    private func persistCache(identity: String, generation: Int) async {
        guard let persistence,
              writeGenerations[identity] == generation
        else { return }

        var upserts = pendingUpserts[identity] ?? [:]
        let removalSnapshot = dirtyRemovals[identity, default: [:]]
        for path in removalSnapshot.keys {
            upserts[path] = nil
        }
        guard !upserts.isEmpty
            || !removalSnapshot.isEmpty
            || invalidPersistenceIdentities.contains(identity)
        else { return }

        do {
            guard !Task.isCancelled, writeGenerations[identity] == generation else { return }
            let result = try await JSONLScanCacheWriter.shared.commit(
                JSONLScanCacheWriteBatch(
                    persistence: persistence,
                    identity: identity,
                    upserts: upserts,
                    removals: removalSnapshot
                )
            )
            guard writeGenerations[identity] == generation else { return }
            persistedMetadata[identity] = result.manifest.files
            if var pending = pendingUpserts[identity] {
                for path in result.acceptedUpsertPaths {
                    pending[path] = nil
                }
                pendingUpserts[identity] = pending.isEmpty ? nil : pending
            }
            for path in removalSnapshot.keys {
                dirtyRemovals[identity]?[path] = nil
            }
            invalidPersistenceIdentities.remove(identity)
            AppLog.debug(
                .cache,
                "persisted \(result.acceptedUpsertPaths.count) changed / \(result.manifest.files.count) retained \(persistence.namespace) log files"
            )
        } catch is CancellationError {
            return
        } catch {
            AppLog.warn(
                .cache,
                "could not persist \(persistence.namespace) log parse cache: \(error.localizedDescription)"
            )
        }
    }

    /// Encode dirty file payloads immediately so unload-after-return cannot persist empty records.
    private func snapshotPendingUpserts(
        identity: String,
        files: [(path: String, cached: CachedFile)]
    ) async {
        guard persistence != nil, !files.isEmpty else { return }
        let encoded: [String: JSONLScanCacheUpsert]
        do {
            encoded = try await Task.detached(priority: .utility) {
                let encoder = PropertyListEncoder()
                encoder.outputFormat = .binary
                return try Dictionary(uniqueKeysWithValues: files.map { input in
                    let metadata = JSONLScanCacheFileMetadata(
                        size: input.cached.size,
                        mtime: input.cached.mtime,
                        attributeMtime: input.cached.attributeMtime,
                        recordFileName: JSONLScanCachePaths.recordFileName(path: input.path)
                    )
                    let record = JSONLScanCacheRecord(
                        path: input.path,
                        size: input.cached.size,
                        mtime: input.cached.mtime,
                        attributeMtime: input.cached.attributeMtime,
                        items: input.cached.items
                    )
                    return (
                        input.path,
                        JSONLScanCacheUpsert(
                            metadata: metadata,
                            recordData: try encoder.encode(record)
                        )
                    )
                })
            }.value
        } catch {
            AppLog.warn(
                .cache,
                "could not snapshot log parse cache upserts: \(error.localizedDescription)"
            )
            return
        }
        for (path, upsert) in encoded {
            pendingUpserts[identity, default: [:]][path] = upsert
        }
    }

    /// Reload one persisted record whose resident items were unloaded (or never loaded).
    private func hydrateResidentItems(
        identity: String,
        path: String,
        expected: CachedFile
    ) async -> CachedFile? {
        guard let persistence else { return nil }
        let metadata = persistedMetadata[identity]?[path] ?? JSONLScanCacheFileMetadata(
            size: expected.size,
            mtime: expected.mtime,
            attributeMtime: expected.attributeMtime,
            recordFileName: JSONLScanCachePaths.recordFileName(
                path: path,
                size: expected.size,
                mtime: expected.mtime,
                attributeMtime: expected.attributeMtime
            )
        )
        guard metadata.size == expected.size,
              metadata.mtime == expected.mtime,
              metadata.attributeMtime == expected.attributeMtime
        else { return nil }

        do {
            return try JSONLScanCacheWriter.shared.loadRecord(
                persistence: persistence,
                identity: identity,
                path: path,
                metadata: metadata,
                itemType: Item.self
            )
        } catch {
            return nil
        }
    }

    private func metadata(for files: [String: CachedFile]) -> [String: JSONLScanCacheFileMetadata] {
        var result: [String: JSONLScanCacheFileMetadata] = [:]
        result.reserveCapacity(files.count)
        for (path, cached) in files {
            result[path] = JSONLScanCacheFileMetadata(
                size: cached.size,
                mtime: cached.mtime,
                attributeMtime: cached.attributeMtime,
                recordFileName: JSONLScanCachePaths.recordFileName(path: path)
            )
        }
        return result
    }

    /// Read + parse a bounded number of changed files in parallel. Results are keyed back to the input
    /// order; a `nil` item list marks an unreadable file. Each parser is responsible for streaming its
    /// file so concurrency does not multiply whole-file allocations.
    private static func parseFiles(
        _ files: [JSONLScanning.DiscoveredFile],
        maxConcurrentParses: Int,
        permitPool: JSONLParsePermitPool,
        parseFile: @Sendable @escaping (URL) -> [Item]?
    ) async -> [(file: JSONLScanning.DiscoveredFile, items: [Item]?, readFailed: Bool)] {
        await withTaskGroup(
            of: (Int, [Item]?, Bool).self,
            returning: [(file: JSONLScanning.DiscoveredFile, items: [Item]?, readFailed: Bool)].self
        ) { group in
            func addTask(at index: Int) {
                let file = files[index]
                group.addTask {
                    guard await permitPool.acquire() else { return (index, nil, false) }
                    let result: (Int, [Item]?, Bool)
                    if Task.isCancelled || !FileManager.default.fileExists(atPath: file.path) {
                        result = (index, nil, false)
                    } else {
                        let parsed = autoreleasepool {
                            parseFile(URL(fileURLWithPath: file.path))
                        }
                        result = (index, parsed, parsed == nil)
                    }
                    await permitPool.release()
                    return result
                }
            }

            var nextIndex = 0
            let initialCount = min(maxConcurrentParses, files.count)
            for index in 0..<initialCount where !Task.isCancelled {
                addTask(at: index)
                nextIndex += 1
            }

            var results = files.map { (file: $0, items: Optional<[Item]>.none, readFailed: false) }
            for await (index, items, readFailed) in group {
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
                results[index] = (files[index], items, readFailed)
                if nextIndex < files.count {
                    addTask(at: nextIndex)
                    nextIndex += 1
                }
            }
            return results
        }
    }
}
