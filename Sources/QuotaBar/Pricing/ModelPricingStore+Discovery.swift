import Foundation

/// Unknown-model discovery: when the current catalogues cannot price a model a user actually used,
/// revalidate the public OpenRouter catalogue once and fold the result into the next snapshot.
///
/// The whole point is cost control. One ledger can mention the same unpriceable slug thousands of
/// times per pass, and providers re-run on every menu-bar tap, so this path must never turn a miss
/// into a request:
///
/// - `ModelPricing` reports each distinct name once per snapshot; the sink coalesces those reports.
/// - A round waits for an in-flight hourly refresh and reuses that fetch instead of repeating it.
/// - Everything else gets a five-minute floor, whether the catalogue fixed the miss or not.
/// - The unknown names are only a local hint. No name is ever put in a URL, header, or body: the
///   only request this can produce is the same public `/api/v1/models` GET the hourly refresh uses.
extension ModelPricingStore {
    /// Floor between catalogue fetches that a newly seen unknown model triggers. The hourly TTL may be
    /// shortened for a genuinely new model, but never past one fetch per five minutes.
    static let unknownModelRetryInterval: TimeInterval = 5 * 60
    /// Cap on distinct unknown names held in memory. Names never leave the machine, so this only stops
    /// a pathological log from growing the queue and the negative cache without limit.
    static let maxTrackedUnknownModels = 64

    /// Report model names a caller could not price. Duplicate, blank, over-long, and recently
    /// negative-cached names are dropped; everything else is coalesced into one background
    /// OpenRouter revalidation.
    func reportUnknownModels<S: Sequence>(_ names: S) where S.Element == String {
        for name in names { unresolvedSink.record(name) }
    }

    /// Runs any discovery round the sink or this caller has queued. Safe to call from anywhere on the
    /// actor: concurrent calls collapse onto the one in-flight round instead of stacking fetches.
    func runUnresolvedDiscoveryIfNeeded() async {
        loadIfNeeded()
        pendingUnknownModels.formUnion(unresolvedSink.drain())
        boundPendingNames()
        guard !pendingUnknownModels.isEmpty else {
            await unresolvedDiscoveryTask?.value
            return
        }

        let attemptsBefore = openRouterAttemptCount
        if let refreshTask {
            await refreshTask.value
        } else if let inFlight = unresolvedDiscoveryTask {
            await inFlight.value
        }

        // Names stay queued across the whole cooling window: a pricing snapshot can outlive the
        // five-minute floor, and dropping a name on the first attempt would strand it with no later
        // reporter, because that snapshot already marked the name as reported.
        pendingUnknownModels = pendingUnknownModels.filter { !pricing.isPriced($0) }
        let wanted = takeUnknownModelsWorthRevalidating()
        guard !wanted.isEmpty else { return }
        guard openRouterAttemptCount == attemptsBefore else {
            // The fetch we waited on already revalidated OpenRouter and `pricing` reflects it. Back
            // the names off rather than repeating the same GET seconds later.
            backoff(wanted)
            return
        }
        guard isDiscoveryAllowedByRefreshScope() else {
            // A menu-bar tap must not revalidate a catalogue that is already on disk. Re-arm the names
            // so the next full pass retries; they stay in memory the whole time.
            pendingUnknownModels.formUnion(wanted)
            return
        }
        guard !failureRetryBlocked(.openRouter) else {
            // A source that just failed keeps its own 30-minute cool-off. Park the names instead of
            // retrying through the discovery path, so unknown models never shorten failure backoff.
            pendingUnknownModels.formUnion(wanted)
            return
        }
        guard outsideDiscoveryFloor() else {
            backoff(wanted)
            return
        }

        unresolvedDiscoveryTask = Task { await self.discover(wanted) }
        await unresolvedDiscoveryTask?.value
    }

    /// `current()` is synchronous and must stay that way, so it can only *schedule* the queued round.
    /// Without this a name reported during one scan would sit in the queue until something else
    /// happened to call the store again. The guard keeps this to at most one pending task.
    func scheduleUnresolvedDiscoveryIfQueued() {
        pendingUnknownModels.formUnion(unresolvedSink.peek())
        boundPendingNames()
        guard !pendingUnknownModels.isEmpty, unresolvedFlushTask == nil,
              unresolvedDiscoveryTask == nil, refreshTask == nil,
              isDiscoveryAllowedByRefreshScope(), !failureRetryBlocked(.openRouter),
              outsideDiscoveryFloor(), !takeUnknownModelsWorthRevalidating().isEmpty
        else { return }
        unresolvedFlushTask = Task {
            await self.runUnresolvedDiscoveryIfNeeded()
            self.unresolvedFlushTask = nil
        }
    }

    /// A menu-bar refresh may only download a catalogue that is missing entirely; discovery must never
    /// turn that into revalidating a catalogue already on disk.
    private func isDiscoveryAllowedByRefreshScope() -> Bool {
        !ProviderRefreshContext.skipModelCatalogRefresh || !cacheExists(.openRouter)
    }

    /// Even a genuinely new model may not trigger OpenRouter more than once per five minutes.
    private func outsideDiscoveryFloor() -> Bool {
        guard let last = lastOpenRouterAttemptAt else { return true }
        return now().timeIntervalSince(last) >= Self.unknownModelRetryInterval
    }

    private func discover(_ names: Set<String>) async {
        defer { unresolvedDiscoveryTask = nil }
        guard sourceURLs[.openRouter] != nil else {
            backoff(names)
            return
        }
        if await fetch(.openRouter) {
            rebuildPricing()
            let priced = names.filter { pricing.isPriced($0) }
            if !priced.isEmpty {
                AppLog.info("pricing", "catalogue discovery priced \(priced.count) of \(names.count) newly seen model name(s)")
            }
        }
        writeSourceStates()
        // A miss the catalogue cannot fix still gets the five-minute floor, so the next provider pass
        // re-arms at most one fetch rather than one fetch per event.
        backoff(names)
    }

    /// Keep unpriced names queued through their cooldown so a later full refresh can retry them.
    private func backoff(_ names: Set<String>) {
        let until = now().addingTimeInterval(Self.unknownModelRetryInterval)
        for name in names { unresolvedBackoff[name] = until }
        for name in names {
            if pricing.isPriced(name) { pendingUnknownModels.remove(name) }
            else { pendingUnknownModels.insert(name) }
        }
        boundPendingNames()
        trimBackoff()
    }

    /// The names eligible for a revalidation right now. A name inside its cool-off stays queued so a
    /// later `current()` retries it; only names at or past the window leave the queue.
    private func takeUnknownModelsWorthRevalidating() -> Set<String> {
        let timestamp = now()
        var wanted = Set<String>()
        for name in pendingUnknownModels {
            guard let eligibleAt = unresolvedBackoff[name] else {
                wanted.insert(name)
                continue
            }
            if timestamp >= eligibleAt { wanted.insert(name) }
        }
        return Set(wanted.sorted().prefix(Self.maxTrackedUnknownModels))
    }

    private func boundPendingNames() {
        if pendingUnknownModels.count > Self.maxTrackedUnknownModels {
            pendingUnknownModels = Set(pendingUnknownModels.sorted().prefix(Self.maxTrackedUnknownModels))
        }
    }

    private func trimBackoff() {
        let cutoff = now().addingTimeInterval(-Self.unknownModelRetryInterval)
        unresolvedBackoff = unresolvedBackoff.filter { $0.value >= cutoff }
        guard unresolvedBackoff.count > Self.maxTrackedUnknownModels * 2 else { return }
        let newest = unresolvedBackoff.sorted { $0.value > $1.value }
            .prefix(Self.maxTrackedUnknownModels * 2)
        unresolvedBackoff = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
    }
}

/// Synchronous, bounded hand-off from `ModelPricing`'s unresolved-model hook into the store actor.
///
/// Scanners resolve thousands of events, so this may be called very often and from any thread. It
/// does the minimum: bounds the name, keeps a small set, and schedules **one** flush — never a `Task`
/// per name, and never a fetch per event.
final class UnresolvedModelSink: @unchecked Sendable {
    /// Longest name worth remembering. Provider log lines can carry arbitrary text; an over-long
    /// name is a parse artifact, not a model id.
    static let maxNameLength = 200
    /// Cap on names buffered between flushes, so a runaway loop cannot grow memory without bound.
    static let maxBufferedNames = 32

    private let lock = NSLock()
    private var handler: (@Sendable () -> Void)?
    private var names: Set<String> = []
    private var flushScheduled = false

    /// Installs the single flush callback. Handler and buffer share one lock, so a concurrent
    /// `record` either sees this handler or is still counted in the next round's buffer.
    func setHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { self.handler = handler }
    }

    func record(_ rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= Self.maxNameLength else { return }
        let flush: (@Sendable () -> Void)? = lock.withLock { () -> (@Sendable () -> Void)? in
            if names.count < Self.maxBufferedNames { names.insert(name) }
            guard !flushScheduled else { return nil }
            flushScheduled = true
            return handler
        }
        flush?()
    }

    /// Moves the buffered names out and re-arms the flush flag.
    func drain() -> Set<String> {
        lock.withLock {
            flushScheduled = false
            let drained = names
            names.removeAll(keepingCapacity: true)
            return drained
        }
    }

    /// A non-destructive read used by the synchronous `current()` path, which can schedule the next
    /// discovery round but must not consume the buffer or re-arm the flush.
    func peek() -> Set<String> {
        lock.withLock { names }
    }
}
