import os
import CryptoKit
import Foundation

/// Stat-only identity for a set of log sources, persisted next to the aggregate it produced.
///
/// The digest covers path + size + both mtimes of every discovered file, so an append (size),
/// an in-place rewrite (attribute mtime), a truncate (size), and a rotate (path/inode) each
/// produce a different fingerprint while an unchanged tree costs one stat per file and nothing
/// else. Computing it never reads file bytes.
struct LogUsageSourceFingerprint: Codable, Sendable, Equatable {
    var digest: String
    var fileCount: Int
    var totalBytes: Int64

    static func of(_ files: [JSONLScanning.DiscoveredFile]) -> LogUsageSourceFingerprint {
        var payload = ""
        var totalBytes: Int64 = 0
        for file in files.sorted(by: { $0.path < $1.path }) {
            payload += "\(file.path)|\(file.size)|\(String(format: "%.6f", file.mtime.timeIntervalSince1970))|"
            payload += file.attributeMtime.map { String(format: "%.6f", $0.timeIntervalSince1970) } ?? "-"
            payload += "\n"
            totalBytes += Int64(file.size)
        }
        return LogUsageSourceFingerprint(
            digest: sha256(payload),
            fileCount: files.count,
            totalBytes: totalBytes
        )
    }

    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Identity of the pricing snapshot an aggregate was computed with. Aggregates store dollar
/// costs, so any rate change must invalidate them — including edits that change no key sets. The
/// stamp hashes every rate, tier and qualifier in both catalogs and the supplement, so a price
/// change is always detected here.
///
/// The payload is hashed on every call: rates must be checked field for field, and a fold's
/// hot path can afford microseconds of hashing against hundreds of milliseconds of I/O. Callers
/// that need a stable value memoize it themselves.
enum LogUsagePricingStamp {
    static func of(_ pricing: ModelPricing) -> String {
        computeStamp(pricing)
    }

    private static func computeStamp(_ pricing: ModelPricing) -> String {
        var payload = ""
        payload += "updatedAt=\(pricing.supplement.updatedAt ?? "-")\n"
        for (key, rates) in pricing.supplement.pricing.sorted(by: { $0.key < $1.key }) {
            payload += "suppl|\(key)|\(ratesPayload(rates))\n"
        }
        payload += "fast=\(pricing.supplement.fastMultipliers.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ","))\n"
        payload += "normFast=\(pricing.supplement.normalizedFastMultipliers.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ","))\n"
        payload += "aliases=\(pricing.supplement.aliasRules.map { "\($0.pattern.pattern)>\($0.canonical)" }.joined(separator: "|"))\n"
        payload += "cursorAliases=\(pricing.supplement.cursorAliasRules.map { "\($0.pattern.pattern)>\($0.canonical)" }.joined(separator: "|"))\n"
        payload += "retiredPricing=\(pricing.supplement.retiredPricingKeys.sorted().joined(separator: ","))\n"
        payload += "retiredAliasPatterns=\(pricing.supplement.retiredAliasPatterns.sorted().joined(separator: ","))\n"
        payload += "retiredAliasPatternsAuthoritative=\(pricing.supplement.retiredAliasPatternsAreAuthoritative ? 1 : 0)\n"
        payload += catalogPayload("primary", pricing.primary)
        payload += catalogPayload("secondary", pricing.secondary)
        return LogUsageSourceFingerprint.sha256(payload)
    }

    private static func catalogPayload(_ name: String, _ catalog: PricingCatalog) -> String {
        var section = "catalog=\(name) retired=\(catalog.retiredKeys.sorted().joined(separator: ",")) retiredAuthoritative=\(catalog.retiredKeysAreAuthoritative ? 1 : 0) retrievedAt=\(catalog.retrievedAt ?? "-")\n"
        for (key, rates) in catalog.entries.sorted(by: { $0.key < $1.key }) {
            section += "\(name)|\(key)|\(ratesPayload(rates))\n"
        }
        return section
    }

    private static func ratesPayload(_ rates: ModelRates) -> String {
        var payload = "i=\(rates.inputPerMillion),o=\(rates.outputPerMillion),cw=\(rates.cacheWritePerMillion),cr=\(rates.cacheReadPerMillion)"
        payload += ",cw1h=\(rates.cacheWrite1hPerMillion.map { String($0) } ?? "-")"
        payload += ",cri=\(rates.cacheReadIsExplicit ? 1 : 0)"
        payload += ",lct=\(rates.longContextThresholdTokens)"
        payload += ",fast=\(rates.fastMultiplier)"
        for tier in rates.promptRateTiers {
            payload += ",tier{threshold=\(tier.thresholdPromptTokens),incl=\(tier.includesThreshold ? 1 : 0),i=\(tier.inputPerMillion.map { String($0) } ?? "-"),o=\(tier.outputPerMillion.map { String($0) } ?? "-"),cw=\(tier.cacheWritePerMillion.map { String($0) } ?? "-"),cr=\(tier.cacheReadPerMillion.map { String($0) } ?? "-"),cw1h=\(tier.cacheWrite1hPerMillion.map { String($0) } ?? "-")}"
        }
        if let lanes = rates.utcPriceOverrides {
            for lane in lanes {
                payload += ",utc{days=\((lane.utcDays ?? []).sorted().joined(separator: ".")),start=\(lane.utcStartMinute.map { String($0) } ?? "-"),end=\(lane.utcEndMinute.map { String($0) } ?? "-"),i=\(lane.inputPerMillion.map { String($0) } ?? "-"),o=\(lane.outputPerMillion.map { String($0) } ?? "-"),cw=\(lane.cacheWritePerMillion.map { String($0) } ?? "-"),cr=\(lane.cacheReadPerMillion.map { String($0) } ?? "-"),cw1h=\(lane.cacheWrite1hPerMillion.map { String($0) } ?? "-")}"
            }
        }
        payload += ",i200k=\(rates.inputAbove200kPerMillion.map { String($0) } ?? "-")"
        payload += ",o200k=\(rates.outputAbove200kPerMillion.map { String($0) } ?? "-")"
        payload += ",cw200k=\(rates.cacheWriteAbove200kPerMillion.map { String($0) } ?? "-")"
        payload += ",cr200k=\(rates.cacheReadAbove200kPerMillion.map { String($0) } ?? "-")"
        return payload
    }
}

/// Persistent per-card daily aggregates for the expensive local-log scans.
///
/// The incremental JSONL machinery already bounds *parsing* to appended bytes, but a scan still
/// replayed every retained parsed event through pricing on every refresh — a menu-bar tap re-folded
/// the whole 35-day event window (decoded from the parse-cache records, folded, then unloaded
/// again) for each Codex card. This cache closes that loop: after a scan produces its
/// `LogUsageScan`, the finished daily/model aggregate is persisted keyed by cheap source
/// fingerprints, and a later refresh with unchanged sources skips parsing, hydration, replay,
/// and re-encoding entirely — it returns the persisted aggregate filtered to the requested window.
///
/// Correctness rules:
/// - Any input change (append, rewrite, truncate, rotate, source added/removed) changes a
///   fingerprint and forces one recompute through the ordinary incremental path.
/// - A pricing or catalog change changes the pricing stamp and forces a recompute.
/// - Reuse is time-bounded (`maxReuseAge`) so the sliding day window can never fall outside the
///   retention horizon the original scan covered.
/// - Cached scans are day-keyed, so serving them through the sliding window is exact: days that
///   aged out are dropped, and days inside the window are byte-identical to the day they were computed.
enum LogUsageAggregatePaths {
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QuotaBar/log-usage-aggregates", isDirectory: true)
    }
}



/// Computed by the caller's fold and handed to the cache; `.foldComplete` with a nil scan means
/// the fold finished but produced a complete-but-empty history (not persisted, so the next call
/// recomputes rather than serving a stale empty aggregate).
///
/// `damagedLines` counts records the fold skipped as damaged (torn or malformed lines). Damage is
/// not incompleteness: the rest of the corpus still folded, and the count travels with the
/// aggregate so a cache hit reports the same caveat as the fold that produced it.
enum AggregateComputeResult: Sendable {
    case complete(LogUsageScan?, validUntil: Date?, damagedLines: Int = 0)
    case incomplete
}

/// What callers should do with the fold result.
enum AggregateCacheOutcome: Sendable {
    case complete(LogUsageScan?, damagedLines: Int = 0)
    case incomplete
}

actor LogUsageAggregateCache {
    static let shared = LogUsageAggregateCache(directory: LogUsageAggregatePaths.defaultDirectory)

    private static let schemaVersion = 2
    /// Reuse bound. Retention windows are ≥ 35 days while request windows are ≤ ~33, so anything
    /// reused within this horizon still covers the full requested window. Beyond it, recompute.
    static let maxReuseAge: TimeInterval = 36 * 3600

    private struct Entry: Codable, Sendable {
        var schemaVersion: Int
        var key: String
        var pricingStamp: String
        var daysBack: Int
        var fingerprints: [String: LogUsageSourceFingerprint]
        var computedAt: Date
        var scan: LogUsageScan
        /// Earliest event the fold excluded because it was in the future at compute time, if any.
        /// Once `now` reaches it, the aggregate is stale by time alone: an event that was "not yet
        /// eligible" then has become eligible now.
        var validUntil: Date?
        /// Damaged records the producing fold skipped. Optional so entries persisted before the
        /// field existed still decode (as zero damage).
        var damagedLines: Int?
    }

    private let directory: URL
    private var entries: [String: Entry] = [:]
    private var loadedKeys: Set<String> = []

    init(directory: URL = LogUsageAggregatePaths.defaultDirectory) {
        self.directory = directory
    }

    /// Returns the persisted aggregate when `key`, pricing, window, and every source fingerprint
    /// match the stored entry; otherwise runs `compute` and persists its result. `compute`
    /// returning `.incomplete` (cancellation, unreadable sources) is never persisted, so the next
    /// caller retries rather than caching a failure.
    func scan(
        key: String,
        pricingStamp: String,
        daysBack: Int,
        fingerprints: [String: LogUsageSourceFingerprint],
        now: Date = Date(),
        compute: @Sendable () async -> AggregateComputeResult
    ) async -> AggregateCacheOutcome {
        precondition(!key.isEmpty)
        let days = max(1, daysBack)
        _ = loadEntryIfNeeded(key: key)
        if let entry = entries[key],
           entry.schemaVersion == Self.schemaVersion,
           entry.pricingStamp == pricingStamp,
           entry.daysBack == days,
           entry.fingerprints == fingerprints,
           entry.validUntil.map({ now < $0 }) ?? true,
           now.timeIntervalSince(entry.computedAt) <= Self.maxReuseAge
        {
            return .complete(
                Self.windowFiltered(entry.scan, daysBack: days, now: now),
                damagedLines: entry.damagedLines ?? 0
            )
        }
        switch await compute() {
        case .incomplete:
            return .incomplete
        case .complete(let fresh, let validUntil, let damagedLines):
            guard let fresh else {
                // A complete fold with no rows persists nothing useful; the empty result is not a
                // failure, it is just not cacheable.
                return .complete(nil, damagedLines: damagedLines)
            }
            let entry = Entry(
                schemaVersion: Self.schemaVersion,
                key: key,
                pricingStamp: pricingStamp,
                daysBack: days,
                fingerprints: fingerprints,
                computedAt: now,
                scan: fresh,
                validUntil: validUntil,
                damagedLines: damagedLines
            )
            entries[key] = entry
            persist(entry)
            return .complete(fresh, damagedLines: damagedLines)
        }
    }

    /// Drops every in-memory and on-disk entry (tests only).
    func invalidateAllForTesting() {
        entries = [:]
        loadedKeys = []
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return }
        for url in files where url.lastPathComponent.hasPrefix("aggregate-") {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Trim a persisted aggregate to the requested day window. The aggregate was built with the
    /// same `daysBack`, so this only removes days the sliding window has aged out — the filtered
    /// result is identical to a fresh scan over the same unchanged sources.
    static func windowFiltered(_ scan: LogUsageScan, daysBack: Int, now: Date) -> LogUsageScan {
        let sinceDay = DailyUsageAccumulator.dayKey(from: JSONLScanning.sinceDate(daysBack: daysBack, now: now))
        return scan.droppingDays(before: sinceDay)
    }

    /// Loads the entry for `key` from disk exactly once per process. Returns whether an entry is
    /// available in memory afterwards; a missing or unreadable file leaves the in-memory map
    /// untouched so the caller recomputes and overwrites.
    private func loadEntryIfNeeded(key: String) -> Bool {
        guard loadedKeys.insert(key).inserted else {
            return entries[key] != nil
        }
        guard let data = try? Data(contentsOf: fileURL(for: key)),
              let entry = try? PropertyListDecoder().decode(Entry.self, from: data),
              entry.key == key
        else { return false }
        entries[key] = entry
        return true
    }

    private func persist(_ entry: Entry) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try PropertyListEncoder().encode(entry)
            try data.write(to: fileURL(for: entry.key), options: .atomic)
        } catch {
            AppLog.warn(.cache, "could not persist usage aggregate: \(error.localizedDescription)")
        }
    }

    private func fileURL(for key: String) -> URL {
        directory.appendingPathComponent("aggregate-\(LogUsageSourceFingerprint.sha256(key)).plist")
    }
}