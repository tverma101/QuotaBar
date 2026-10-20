import Darwin
import Foundation
import os

struct ProviderSnapshotCache {
    private static let processStoreLock = NSLock()

    private struct Payload: Codable {
        var snapshots: [String: ProviderSnapshot]
        /// Card id → the account identity key that produced the stored snapshot. A sidecar map rather
        /// than a field on `ProviderSnapshot` because that model is serialized verbatim to the local
        /// HTTP API (`LocalUsageAPI`) — the stamp is cache bookkeeping, not wire data. Absent for
        /// providers without an account identity. Claude/Codex/Cursor use their account identity;
        /// OpenCode uses a complete fingerprint of its distinct Go credential inventory.
        var producedByIdentityKeys: [String: String]
        /// Cross-process refresh ordering. `issued` orders work when it starts; `stored` fences late
        /// completions and removal/clear mutations. Missing maps decode as empty for older payloads.
        var issuedRefreshOrders: [String: UInt64]
        var storedRefreshOrders: [String: UInt64]
        /// A refresh only supersedes data in the domain it actually wrote. Meter and history scopes
        /// can overlap without fencing the other domain's still-running result.
        var storedQuotaOrders: [String: UInt64]
        var storedHistoryOrders: [String: UInt64]

        private enum CodingKeys: String, CodingKey {
            case snapshots
            case producedByIdentityKeys
            case issuedRefreshOrders
            case storedRefreshOrders
            case storedQuotaOrders
            case storedHistoryOrders
        }

        init(
            snapshots: [String: ProviderSnapshot],
            producedByIdentityKeys: [String: String],
            issuedRefreshOrders: [String: UInt64] = [:],
            storedRefreshOrders: [String: UInt64] = [:],
            storedQuotaOrders: [String: UInt64] = [:],
            storedHistoryOrders: [String: UInt64] = [:]
        ) {
            self.snapshots = snapshots
            self.producedByIdentityKeys = producedByIdentityKeys
            self.issuedRefreshOrders = issuedRefreshOrders
            self.storedRefreshOrders = storedRefreshOrders
            self.storedQuotaOrders = storedQuotaOrders
            self.storedHistoryOrders = storedHistoryOrders
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            snapshots = try values.decode([String: ProviderSnapshot].self, forKey: .snapshots)
            producedByIdentityKeys = try values.decodeIfPresent(
                [String: String].self,
                forKey: .producedByIdentityKeys
            ) ?? [:]
            issuedRefreshOrders = try values.decodeIfPresent(
                [String: UInt64].self,
                forKey: .issuedRefreshOrders
            ) ?? [:]
            storedRefreshOrders = try values.decodeIfPresent(
                [String: UInt64].self,
                forKey: .storedRefreshOrders
            ) ?? [:]
            storedQuotaOrders = try values.decodeIfPresent(
                [String: UInt64].self,
                forKey: .storedQuotaOrders
            ) ?? [:]
            storedHistoryOrders = try values.decodeIfPresent(
                [String: UInt64].self,
                forKey: .storedHistoryOrders
            ) ?? [:]
        }
    }

    enum StoreResult {
        case stored(ProviderSnapshot?)
        case superseded(ProviderSnapshot?)
        case unchanged(ProviderSnapshot?)
        case unavailable
    }

    /// In-memory mirror of the persisted blob. Reads (`snapshot`, `loadSnapshots`, and the read inside
    /// `store`) hit this instead of re-decoding the whole all-providers JSON from `UserDefaults` on
    /// every call — a refresh pass otherwise paid O(N) full decodes (plus O(N) encodes) per pass on the
    /// MainActor. The blob is decoded at most once per cache instance (first access); writes update the
    /// mirror and persist through. Lock-backed so the value-type cache memoizes across calls and stays
    /// safe to share.
    private let memo = OSAllocatedUnfairLock<Payload?>(initialState: nil)

    /// The raw persisted bytes the mirror in `memo` was built from, or the bytes last written.
    ///
    /// The memo made this cache fast but made it *self-contained*, and the blob is shared: the app and
    /// `quotabar-cli` are separate processes writing the same `UserDefaults` domain. `store` merged into
    /// the memo, so a write rewrote the whole blob from a snapshot of state frozen at first read — and
    /// silently destroyed every entry another process had added since. Reproduced: the CLI wrote
    /// `claude = 95%`, the app's next pass stored `cursor` only, and the blob came back with `claude =
    /// 80%`. The lost value carried a *recent* `refreshedAt`, so it was then served as TTL-fresh.
    ///
    /// Comparing raw bytes is the cheap half of the fix: reading the blob and memcmp-ing it costs a
    /// buffer copy, not a full JSON decode of every provider's snapshot. A full re-decode on every
    /// `store` — the obvious correct alternative — is the O(N) cost `memo` exists to avoid.
    private let persistedBytes = OSAllocatedUnfairLock<Data?>(initialState: nil)

    /// Provider IDs whose snapshot was written by `store` *during this cache instance's lifetime* (i.e.
    /// this running session). The freshness gate (`snapshot(providerID:)`) trusts a snapshot only when
    /// its provider is in here — so a snapshot loaded from disk on launch is shown (via `loadSnapshots`)
    /// but never counts as fresh, forcing one refresh on the first post-launch pass. Lock-backed for the
    /// same reason as `memo`: the value-type cache shares it across copies and stays safe. See #697.
    private let sessionWrites = OSAllocatedUnfairLock<Set<String>>(initialState: [])

    private let userDefaults: UserDefaults
    private let storageKey: String
    /// A snapshot written this session stays fresh for exactly one refresh interval, then expires so the
    /// periodic loop refetches on schedule. A snapshot loaded from a *previous* session (off disk) is never
    /// fresh regardless of its `refreshedAt` — see `sessionWrites`. Tests inject a fixed TTL for a
    /// deterministic freshness window.
    private let ttl: TimeInterval
    /// The menu-bar app deliberately refreshes once per launch, even when its persisted snapshot is
    /// young. A one-shot reader has no meaningful session, so it opts into timestamp-only freshness.
    private let allowsPersistedFreshness: Bool
    private let now: () -> Date
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        userDefaults: UserDefaults = .standard,
        // v3: spend / Codex credits / rate-limit-resets rows moved from `.text` (a parsed display string)
        // to `.values` (raw numbers). Bumping the key drops pre-upgrade caches so the new `.values`-based
        // widgets never try to resolve a stale `.text` line — which would misread the fused string
        // (tokens tile showing the dollar amount, combined dropping tokens) until the first refresh.
        // v4/v5: `.values` rows gained Codex reset-credit expiry data — v4 carried a single `resetsAt`,
        // v5 replaced it with an `expiriesAt` list (one per available credit, shown in the row's
        // tooltip). Old payloads decode cleanly (the absent key → empty list), but the bump refetches
        // once so the expiries show immediately on upgrade instead of after the cached snapshot expires.
        // v6: `.values` rows gained `unknownModels` (Cursor spend tiles list the unpriced models behind a
        // warning triangle). Same story — old payloads decode with an empty list, the bump just refetches
        // once so the warning shows immediately instead of after the cached snapshot expires.
        // v7: spend `.values` rows gained `modelBreakdown` for the per-model hover panel. Old payloads
        // decode cleanly without it, but the bump fetches fresh snapshots so hover panels appear right away.
        // v8: provider snapshots gained normalized daily history for iCloud aggregation. Refetch on
        // upgrade so enabling sync can publish a complete first document immediately.
        // v9: entries gained a `producedByIdentityKeys` sidecar (which account produced each snapshot),
        // so a launch after an account swap at the same home can discard previous-account values instead
        // of painting them under the new account's card. Refetch on upgrade so every retained entry
        // carries a stamp from its first write.
        storageKey: String = "openusage.providerSnapshots.v9",
        ttl: TimeInterval = RefreshSetting.interval,
        allowsPersistedFreshness: Bool = false,
        now: @escaping () -> Date = Date.init
    ) {
        self.userDefaults = userDefaults
        self.storageKey = storageKey
        self.ttl = ttl
        self.allowsPersistedFreshness = allowsPersistedFreshness
        self.now = now
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    /// Every stored snapshot for the given providers, including expired ones. Display uses this
    /// (stale-while-revalidate: last-known values keep showing while a refresh runs); refresh gating
    /// still goes through the TTL-checked `snapshot(providerID:)`.
    func loadSnapshots(providerIDs: [String]) -> [String: ProviderSnapshot] {
        let providerIDSet = Set(providerIDs)
        let loaded = loadPayload().snapshots.filter { providerID, _ in
            providerIDSet.contains(providerID)
        }
        AppLog.debug(.cache, "loaded \(loaded.count) snapshots from disk")
        return loaded
    }

    /// Trim persisted usage history without treating the old provider values as freshly fetched.
    /// Startup uses one bulk rewrite so years of stale model detail do not remain in the shared
    /// UserDefaults blob or get re-decoded on every later launch.
    func compactHistories(lifetimeDayKeys: Set<String>, detailDayKeys: Set<String>) {
        withPersistentStoreLock {
            // The app and CLI share one UserDefaults blob. Re-read it while holding the process lock
            // so compaction cannot erase a provider another process stored after our last read.
            var payload = decodeStoredPayload(userDefaults.data(forKey: storageKey))
            var changed = false
            for providerID in Array(payload.snapshots.keys) {
                guard var snapshot = payload.snapshots[providerID],
                      let history = snapshot.usageHistory
                else { continue }
                let compacted = history.retainingHistory(
                    lifetimeDayKeys: lifetimeDayKeys,
                    detailDayKeys: detailDayKeys
                )
                guard compacted != history else { continue }
                snapshot.usageHistory = compacted
                payload.snapshots[providerID] = snapshot
                changed = true
            }
            if changed { save(payload) }
        }
    }

    /// Allocate a process-shared sequence before provider work starts. A later request gets a larger
    /// value even when the earlier request takes longer to finish.
    func beginRefreshOrder(providerID: String) -> UInt64? {
        var order: UInt64?
        var saved = false
        let locked = withPersistentStoreLock {
            var payload = decodeStoredPayload(userDefaults.data(forKey: storageKey))
            let previous = max(
                payload.issuedRefreshOrders[providerID, default: 0],
                payload.storedRefreshOrders[providerID, default: 0]
            )
            guard previous < UInt64.max else {
                AppLog.warn(.cache, "refresh order exhausted for \(providerID)")
                return
            }
            let next = previous + 1
            payload.issuedRefreshOrders[providerID] = next
            saved = save(payload)
            if saved { order = next }
        }
        return locked && saved ? order : nil
    }

    /// Discard provider results older than a committed write in a domain they update. An in-flight
    /// newer request does not fence useful data if that request later fails; the final write repeats
    /// this check under the same lock to close the commit race.
    func isCurrentRefresh(
        providerID: String,
        order: UInt64,
        scope: ProviderRefreshContext.Scope,
        hasHistoryDomain: Bool,
        panelMetersIncludesHistory: Bool = false
    ) -> Bool {
        var current = true
        let locked = withPersistentStoreLock {
            let payload = decodeStoredPayload(userDefaults.data(forKey: storageKey))
            let quotaCurrent = scope.refreshesQuotaDomain
                && order >= payload.storedQuotaOrders[providerID, default: 0]
            let historyCurrent = hasHistoryDomain
                && scope.refreshesHistoryDomain(panelMetersIncludesHistory: panelMetersIncludesHistory)
                && order >= payload.storedHistoryOrders[providerID, default: 0]
            current = quotaCurrent || historyCurrent
        }
        return locked ? current : true
    }

    /// Compact the newest persisted history in place. This is maintenance, not a provider refresh,
    /// so it must not replace the entry from a process-local snapshot or change its freshness stamp.
    func compactHistory(providerID: String, through date: Date) {
        withPersistentStoreLock {
            var payload = decodeStoredPayload(userDefaults.data(forKey: storageKey))
            guard var snapshot = payload.snapshots[providerID],
                  let history = snapshot.usageHistory
            else { return }
            let compacted = history.retainingHistory(through: date)
            guard compacted != history else { return }
            snapshot.usageHistory = compacted
            payload.snapshots[providerID] = snapshot
            _ = save(payload)
        }
    }

    func snapshot(providerID: String, freshnessInterval: TimeInterval? = nil) -> ProviderSnapshot? {
        let snapshot = loadPayload().snapshots[providerID]
        guard let snapshot else { return nil }
        // Freshness has two requirements, and disk age alone is not enough: the snapshot must have been
        // written *this session* AND still be within TTL. A snapshot served from a previous session's
        // persisted blob is shown for instant paint but never gates a refresh, so every launch refetches
        // promptly instead of waiting out the previous session's remaining interval (#697).
        let writtenThisSession = sessionWrites.withLock { $0.contains(providerID) }
        // Age reads the OLDER of the wall stamp and the meters' own stamp. Fold-only passes
        // (`.localAccounting` / `.panelAccounting`) write a fresh `refreshedAt` while carrying
        // meters recovered from the previous snapshot; gating on `refreshedAt` alone let a
        // closed-panel ledger wake (one per routed turn) keep a snapshot whose meters the live
        // API had not answered in hours TTL-fresh forever, so panel-open passes cache-hit and
        // the subscription usage meters never updated. `quotaRefreshedAt` is nil on legacy
        // payloads and falls back to `refreshedAt` (today's behavior).
        let meterStamp = snapshot.quotaRefreshedAt ?? snapshot.refreshedAt
        // Meter-only callers ask about quota freshness. Full and fold callers ask whether the
        // whole snapshot is fresh, so stale history must still trigger a new accounting pass there.
        let historyStamp: Date
        if snapshot.usageHistory != nil || snapshot.historyWarning != nil {
            historyStamp = snapshot.historyRefreshedAt
                ?? (snapshot.historyWarning == nil ? snapshot.refreshedAt : .distantPast)
        } else {
            historyStamp = snapshot.refreshedAt
        }
        let freshnessStamp = freshnessInterval == nil
            ? min(snapshot.refreshedAt, min(meterStamp, historyStamp))
            : meterStamp
        let age = now().timeIntervalSince(freshnessStamp)
        let trusted = allowsPersistedFreshness || writtenThisSession
        let effectiveTTL = freshnessInterval ?? ttl
        let fresh = trusted && age < effectiveTTL
        let reason = !trusted ? "stale (not written this session)"
            : fresh ? "fresh" : "stale"
        AppLog.debug(.cache, "\(providerID) staleness \(Int(age))s vs ttl \(Int(effectiveTTL))s -> \(reason)")
        return fresh ? snapshot : nil
    }

    /// `producedByIdentityKey` is the account identity that produced this snapshot (the card's identity
    /// at write time); `nil` for providers without account identity, or when the identity is unresolved.
    @discardableResult
    func store(
        _ snapshot: ProviderSnapshot,
        producedByIdentityKey: String? = nil,
        refreshOrder: UInt64? = nil,
        scope: ProviderRefreshContext.Scope? = nil,
        historyDescriptor: UsageHistoryDescriptor? = nil,
        panelMetersIncludesHistory: Bool = false,
        now: Date = Date()
    ) -> StoreResult {
        guard !snapshot.lines.contains(where: \.isError) else {
            AppLog.debug(.cache, "skip write \(snapshot.providerID) (error snapshot)")
            return .unavailable
        }
        guard scope == nil || refreshOrder != nil else {
            // Production refresh writes always carry their cross-process sequence. An unordered
            // fallback after sequence allocation failed could let an older result win the race.
            return .unavailable
        }
        AppLog.debug(.cache, "write \(snapshot.providerID)")
        var result: StoreResult = .unavailable
        let locked = withPersistentStoreLock {
            var payload = decodeStoredPayload(userDefaults.data(forKey: storageKey))
            let providerID = snapshot.providerID
            let quotaOrder = payload.storedQuotaOrders[providerID, default: 0]
            let historyOrder = payload.storedHistoryOrders[providerID, default: 0]
            let quotaCandidate = scope?.refreshesQuotaDomain ?? true
            let historyCandidate: Bool
            if let scope {
                historyCandidate = scope.refreshesHistoryDomain(
                    panelMetersIncludesHistory: panelMetersIncludesHistory
                )
                    && (historyDescriptor != nil)
                    && snapshot.usageHistory != nil
                    && snapshot.carriesPriorHistory != true
            } else {
                historyCandidate = true
            }
            let quotaAccepted = quotaCandidate
                && (refreshOrder.map { $0 >= quotaOrder } ?? true)
            let historyAccepted = historyCandidate
                && (refreshOrder.map { $0 >= historyOrder } ?? true)
            let hasFreshDomain = quotaAccepted || historyAccepted
            if !hasFreshDomain {
                if quotaCandidate || historyCandidate {
                    result = .superseded(payload.snapshots[providerID])
                } else if let historyWarning = snapshot.historyWarning {
                    let latestIssuedOrder = payload.issuedRefreshOrders[providerID, default: 0]
                    guard refreshOrder.map({ $0 >= latestIssuedOrder }) ?? true else {
                        result = .superseded(payload.snapshots[providerID])
                        return
                    }
                    var warningSnapshot = payload.snapshots[providerID] ?? snapshot
                    guard warningSnapshot.historyWarning != historyWarning else {
                        result = .unchanged(warningSnapshot)
                        return
                    }
                    warningSnapshot.historyWarning = historyWarning
                    if payload.snapshots[providerID] == nil {
                        // A warning-only first fold has no evidence that either data domain is fresh.
                        warningSnapshot.quotaRefreshedAt = .distantPast
                        warningSnapshot.historyRefreshedAt = .distantPast
                        warningSnapshot.refreshedAt = .distantPast
                        payload.producedByIdentityKeys[providerID] = producedByIdentityKey
                    }
                    payload.snapshots[providerID] = warningSnapshot
                    result = save(payload) ? .stored(warningSnapshot) : .unavailable
                } else {
                    // A completed fold with no history is not authoritative. Preserve the previous
                    // snapshot without making it fresh or fencing an older successful history scan.
                    result = .unchanged(payload.snapshots[providerID])
                }
                return
            }

            var storedSnapshot = snapshot
            let identityMatches = payload.producedByIdentityKeys[providerID] == producedByIdentityKey
            if let scope, identityMatches {
                storedSnapshot = Self.merge(
                    snapshot,
                    over: payload.snapshots[providerID],
                    scope: scope,
                    updateQuota: quotaAccepted,
                    updateHistory: historyAccepted,
                    historyDescriptor: historyDescriptor,
                    panelMetersIncludesHistory: panelMetersIncludesHistory,
                    now: now
                )
            } else if let scope, providerID == "antigravity", let previous = payload.snapshots[providerID] {
                // Antigravity quota belongs to the Google account, but its conversation database is
                // machine-local. An account switch clears plan/meters and can safely carry the local
                // history into the newly attributed snapshot.
                storedSnapshot = Self.merge(
                    snapshot,
                    over: Self.clearingQuotaState(previous),
                    scope: scope,
                    updateQuota: quotaAccepted,
                    updateHistory: historyAccepted,
                    historyDescriptor: historyDescriptor,
                    panelMetersIncludesHistory: panelMetersIncludesHistory,
                    now: now
                )
            }
            payload.snapshots[providerID] = storedSnapshot
            // Stamp (or clear) the producing account alongside the entry. A nil identity must clear
            // any prior stamp rather than falsely bless an unattributable snapshot at next launch.
            payload.producedByIdentityKeys[providerID] = producedByIdentityKey
            if let refreshOrder {
                payload.issuedRefreshOrders[providerID] = max(
                    payload.issuedRefreshOrders[providerID, default: 0],
                    refreshOrder
                )
                payload.storedRefreshOrders[providerID] = max(
                    payload.storedRefreshOrders[providerID, default: 0],
                    refreshOrder
                )
                if quotaAccepted { payload.storedQuotaOrders[providerID] = refreshOrder }
                if historyAccepted { payload.storedHistoryOrders[providerID] = refreshOrder }
            }
            result = save(payload) ? .stored(storedSnapshot) : .unavailable
        }
        guard locked else { return .unavailable }
        // Mark this provider as written this session only after the shared payload write completed.
        if case .stored = result {
            sessionWrites.withLock { _ = $0.insert(snapshot.providerID) }
        }
        return result
    }

    private static func merge(
        _ incoming: ProviderSnapshot,
        over previous: ProviderSnapshot?,
        scope: ProviderRefreshContext.Scope,
        updateQuota: Bool,
        updateHistory: Bool,
        historyDescriptor: UsageHistoryDescriptor?,
        panelMetersIncludesHistory: Bool,
        now: Date
    ) -> ProviderSnapshot {
        guard let previous else {
            var initial = incoming
            initial.replacesPriorQuotaProgress = nil
            if !updateQuota {
                initial.plan = nil
                initial.lines.removeAll { if case .progress = $0 { return true }; return false }
                initial.warning = nil
                // WidgetDataStore stamps this as stale when the provider declares quota meters.
                // Preserve that decision: a history-only provider must not get an artificial stale
                // meter stamp, since cache freshness falls back to `refreshedAt` when this is nil.
            }
            if !updateHistory {
                initial.usageHistory = nil
                initial.carriesPriorHistory = nil
                initial.historyRefreshedAt = nil
            }
            return initial
        }

        if !scope.isFull {
            if panelMetersIncludesHistory && !updateHistory {
                // Hermes's meter pass is also its history pass. Those rows share one computation and
                // cannot be safely refreshed independently if a newer fold has already committed.
                return previous
            }
            var merged = scope.refreshesQuotaDomain && updateQuota
                ? incoming.mergingMenuBarUpdate(over: previous)
                : previous
            if updateHistory, let history = incoming.usageHistory, let historyDescriptor {
                merged = renderingHistory(
                    history,
                    from: incoming,
                    over: merged,
                    descriptor: historyDescriptor,
                    now: now
                )
            } else if let history = previous.usageHistory {
                if let historyDescriptor {
                    merged = renderingHistory(
                        history,
                        from: previous,
                        over: merged,
                        descriptor: historyDescriptor,
                        now: now
                    )
                } else {
                    merged.usageHistory = history
                    merged.historyRefreshedAt = previous.historyRefreshedAt ?? previous.refreshedAt
                }
                // The incoming non-full result carried this history forward; the renderer copies
                // the source marker, so set it after rendering just as the full-scope merge does.
                // Without this marker, panel-accounting refreshes can cache-hit forever after a
                // meters-only pass re-stamps the quota domain.
                merged.carriesPriorHistory = true
                // Re-rendering preserved history uses its original stamp. A successful quota update
                // must retain its own newer stamp so meter-only cache hits do not refetch immediately.
                if updateQuota { merged.refreshedAt = incoming.refreshedAt }
            } else if !updateHistory {
                merged.usageHistory = nil
                merged.carriesPriorHistory = nil
            }
            if incoming.historyWarning != nil {
                merged.historyWarning = incoming.historyWarning
            } else if updateHistory, incoming.usageHistory != nil {
                merged.historyWarning = nil
            }
            return merged
        }

        var merged = updateQuota
            ? incoming.preservingOmittedQuotaProgress(over: previous)
            : previous
        if updateHistory, let history = incoming.usageHistory, let historyDescriptor {
            merged = renderingHistory(
                history,
                from: incoming,
                over: merged,
                descriptor: historyDescriptor,
                now: now
            )
        } else if let history = previous.usageHistory {
            if let historyDescriptor {
                merged = renderingHistory(
                    history,
                    from: previous,
                    over: merged,
                    descriptor: historyDescriptor,
                    now: now
                )
            } else {
                merged.usageHistory = history
                merged.historyRefreshedAt = previous.historyRefreshedAt ?? previous.refreshedAt
            }
            merged.carriesPriorHistory = true
            // The preserved history keeps its own stamp. A successful full quota refresh still
            // owns the snapshot-level stamp and must not roll it back to the older history scan.
            if updateQuota { merged.refreshedAt = incoming.refreshedAt }
        }
        if incoming.historyWarning != nil {
            merged.historyWarning = incoming.historyWarning
        } else if updateHistory, incoming.usageHistory != nil {
            merged.historyWarning = nil
        }
        return merged
    }

    private static func renderingHistory(
        _ history: ProviderUsageHistory,
        from source: ProviderSnapshot,
        over base: ProviderSnapshot,
        descriptor: UsageHistoryDescriptor,
        now: Date
    ) -> ProviderSnapshot {
        var merged = base
        merged.refreshedAt = source.refreshedAt
        merged = UsageHistorySnapshotRenderer.render(
            local: merged,
            history: history,
            descriptor: descriptor,
            now: now,
            combined: false
        )
        merged.carriesPriorHistory = source.carriesPriorHistory
        merged.historyRefreshedAt = source.historyRefreshedAt ?? source.refreshedAt
        if source.usageHistory != nil || source.historyWarning != nil {
            merged.historyWarning = source.historyWarning
        }
        return merged
    }

    /// Remove a provider snapshot and its account stamp after the provider proves a different account
    /// is active. Keeping the old row on disk would let a later unresolved startup repaint it.
    @discardableResult
    func removeSnapshot(providerID: String, refreshOrder: UInt64? = nil) -> Bool {
        var didStore = false
        var accepted = false
        let stored = withPersistentStoreLock {
            var payload = decodeStoredPayload(userDefaults.data(forKey: storageKey))
            let newestOrder = max(
                payload.issuedRefreshOrders[providerID, default: 0],
                payload.storedRefreshOrders[providerID, default: 0]
            )
            let newestCommittedDomainOrder = max(
                payload.storedQuotaOrders[providerID, default: 0],
                payload.storedHistoryOrders[providerID, default: 0]
            )
            if let refreshOrder, refreshOrder < newestCommittedDomainOrder { return }
            let order = refreshOrder ?? Self.nextOrder(after: newestOrder)
            payload.snapshots.removeValue(forKey: providerID)
            payload.producedByIdentityKeys.removeValue(forKey: providerID)
            payload.issuedRefreshOrders[providerID] = max(
                payload.issuedRefreshOrders[providerID, default: 0], order
            )
            payload.storedRefreshOrders[providerID] = max(
                payload.storedRefreshOrders[providerID, default: 0], order
            )
            payload.storedQuotaOrders[providerID] = order
            payload.storedHistoryOrders[providerID] = order
            accepted = true
            didStore = save(payload)
        }
        guard stored, didStore, accepted else { return false }
        sessionWrites.withLock { _ = $0.remove(providerID) }
        return true
    }

    /// Clear account-bound quota values from the latest persisted snapshot while retaining its local
    /// history. A standalone invalidation gets a fresh order and fences any older in-flight refresh.
    @discardableResult
    func clearQuotaState(providerID: String, refreshOrder: UInt64? = nil) -> StoreResult {
        var result: StoreResult = .unavailable
        let locked = withPersistentStoreLock {
            var payload = decodeStoredPayload(userDefaults.data(forKey: storageKey))
            let newestOrder = max(
                payload.issuedRefreshOrders[providerID, default: 0],
                payload.storedRefreshOrders[providerID, default: 0]
            )
            let newestQuotaOrder = payload.storedQuotaOrders[providerID, default: 0]
            if let refreshOrder, refreshOrder < newestQuotaOrder {
                result = .superseded(payload.snapshots[providerID])
                return
            }
            let order = refreshOrder ?? Self.nextOrder(after: newestOrder)
            let cleared = payload.snapshots[providerID].map(Self.clearingQuotaState)
            if let cleared { payload.snapshots[providerID] = cleared }
            payload.issuedRefreshOrders[providerID] = max(
                payload.issuedRefreshOrders[providerID, default: 0], order
            )
            payload.storedRefreshOrders[providerID] = max(
                payload.storedRefreshOrders[providerID, default: 0], order
            )
            payload.storedQuotaOrders[providerID] = order
            result = save(payload) ? .stored(cleared) : .unavailable
        }
        guard locked else { return .unavailable }
        if case .stored = result {
            sessionWrites.withLock { _ = $0.remove(providerID) }
        }
        return result
    }

    private static func nextOrder(after current: UInt64) -> UInt64 {
        current == UInt64.max ? current : current + 1
    }

    private static func clearingQuotaState(_ snapshot: ProviderSnapshot) -> ProviderSnapshot {
        var cleared = snapshot
        cleared.plan = nil
        cleared.lines.removeAll { line in
            if case .progress = line { return true }
            return false
        }
        cleared.warning = nil
        cleared.clearsPriorMenuBarQuotaState = nil
        cleared.replacesPriorQuotaProgress = nil
        cleared.invalidatesQuotaIdentity = nil
        cleared.quotaRefreshedAt = nil
        return cleared
    }

    /// The account identity stamped when this provider's entry was stored, or `nil` when the entry is
    /// absent or was written without one. Launch filtering compares this against the card's current
    /// identity before showing a cached snapshot for an account-aware card (see `WidgetDataStore.init`).
    func producedByIdentityKey(providerID: String) -> String? {
        loadPayload().producedByIdentityKeys[providerID]
    }

    /// Whether this provider's stored entry cannot be attributed to `currentIdentityKey`: the entry
    /// exists, the card's current identity is known, and the stamp is missing or names another
    /// account. Every read path must reject its stale quota data — the launch paint filter
    /// (`WidgetDataStore.init`), the refresh cache-hit gate (`WidgetDataStore.refresh`), and the
    /// one-shot CLI's persisted-freshness reads (`UsageReader`) — or a swap at the same home would
    /// serve the previous account's data. OpenCode retains only its machine-local history. `false`
    /// when the identity is unresolved (`nil`): an
    /// unverifiable entry keeps painting exactly as it did before account stamps existed.
    func hasStaleAccountStamp(providerID: String, currentIdentityKey: String?) -> Bool {
        guard let currentIdentityKey else { return false }
        let payload = loadPayload()
        guard payload.snapshots[providerID] != nil else { return false }
        return payload.producedByIdentityKeys[providerID] != currentIdentityKey
    }

    /// Drop this-session freshness for the given provider IDs so the next `snapshot(providerID:)`
    /// miss forces a refetch without deleting the last-good persisted blob (launch paint / SWR).
    /// Used when CodexRouter's ledger appends while the panel is open — otherwise the 5-minute
    /// snapshot TTL would swallow the wake and leave Today / charts stale until the timer fires.
    func invalidateSessionFreshness(providerIDs: [String]) {
        guard !providerIDs.isEmpty else { return }
        let ids = providerIDs
        sessionWrites.withLock { writes in
            for id in ids {
                writes.remove(id)
            }
        }
    }

    private func loadPayload() -> Payload {
        let currentBytes = userDefaults.data(forKey: storageKey)
        let knownBytes = persistedBytes.withLock { $0 }
        // Only trust the mirror if the blob on disk is byte-identical to what produced it. Any
        // difference means another process wrote, so the mirror is stale and must be rebuilt.
        if currentBytes == knownBytes, let mirror = memo.withLock({ $0 }) { return mirror }
        // Decode the exact bytes observed above. Re-reading UserDefaults here could pair one writer's
        // blob with another writer's byte stamp and bless a stale mirror as current.
        let loaded = decodeStoredPayload(currentBytes)
        memo.withLock { $0 = loaded }
        persistedBytes.withLock { $0 = currentBytes }
        return loaded
    }

    private func decodeStoredPayload(_ data: Data?) -> Payload {
        // No stored data is the legitimate first-launch / cleared-cache case — recover to empty
        // silently. Data present but undecodable is a real problem (post-upgrade schema drift, a
        // half-written blob, a manual `defaults` edit): fail loudly, then recover to empty. A silent
        // drop here empties ALL providers' caches at once and feeds the refresh storm. Mirrors the
        // loud `save` path above. Runs at most once per cache instance (then memoized).
        guard let data else {
            return Payload(snapshots: [:], producedByIdentityKeys: [:])
        }
        do {
            return try decoder.decode(Payload.self, from: data)
        } catch {
            AppLog.warn(.cache, "cache decode failed, dropping stored snapshots: \(error.localizedDescription)")
            return Payload(snapshots: [:], producedByIdentityKeys: [:])
        }
    }

    @discardableResult
    private func save(_ payload: Payload) -> Bool {
        do {
            let data = try encoder.encode(payload)
            userDefaults.set(data, forKey: storageKey)
            memo.withLock { $0 = payload }
            persistedBytes.withLock { $0 = data }
            return true
        } catch {
            AppLog.warn(.cache, "encode failed, snapshot not persisted: \(error.localizedDescription)")
            return false
        }
    }

    /// UserDefaults has no atomic read–modify–write operation. The app and `quotabar-cli` both store a
    /// whole-provider payload, so serialize their writes and merge from the newest blob under one
    /// kernel lock. A failed lock acquisition skips the write instead of risking another process's
    /// last-good snapshots.
    @discardableResult
    private func withPersistentStoreLock(_ body: () -> Void) -> Bool {
        Self.processStoreLock.lock()
        defer { Self.processStoreLock.unlock() }

        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            logPersistentStoreLockFailure("Application Support directory unavailable")
            return false
        }
        let directory = applicationSupport.appendingPathComponent("QuotaBar", isDirectory: true)
        let lockURL = directory.appendingPathComponent("provider-snapshot-cache.lock")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch {
            logPersistentStoreLockFailure(error.localizedDescription)
            return false
        }
        var fd = Darwin.open(lockURL.path, O_RDWR | O_CLOEXEC, mode_t(S_IRUSR | S_IWUSR))
        if fd < 0, errno == ENOENT {
            fd = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(S_IRUSR | S_IWUSR))
            if fd >= 0 { _ = Darwin.fchmod(fd, mode_t(S_IRUSR | S_IWUSR)) }
        }
        guard fd >= 0 else {
            logPersistentStoreLockFailure(String(cString: strerror(errno)))
            return false
        }
        defer {
            flock(fd, LOCK_UN)
            Darwin.close(fd)
        }
        guard flock(fd, LOCK_EX) == 0 else {
            logPersistentStoreLockFailure(String(cString: strerror(errno)))
            return false
        }
        DiagnosticGate.clearFailure("cache.providerSnapshots.lock")
        body()
        return true
    }

    private func logPersistentStoreLockFailure(_ message: String) {
        DiagnosticGate.logOnce(for: "cache.providerSnapshots.lock") {
            AppLog.warn(.cache, "snapshot cache write lock unavailable: \(message)")
        }
    }
}
