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
/// costs, so a pricing change must invalidate them. Counts + `updated_at` + the supplement's
/// key/multiplier/rule names are cheap to hash and catch every feed refresh we ship; a rate
/// edit that changes no key set is tolerated until the next source change recomputes anyway.
enum LogUsagePricingStamp {
    static func of(_ pricing: ModelPricing) -> String {
        var payload = ""
        payload += "updatedAt=\(pricing.supplement.updatedAt ?? "-")\n"
        payload += "supplement=\(pricing.supplement.pricing.keys.sorted().joined(separator: ","))\n"
        let fast = pricing.supplement.fastMultipliers
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ",")
        payload += "fast=\(fast)\n"
        payload += "rules=\(pricing.supplement.aliasRules.map(\.pattern.pattern).joined(separator: ","))\n"
        payload += "primary=\(pricing.primary.entries.count)\n"
        payload += "secondary=\(pricing.secondary.entries.count)\n"
        return LogUsageSourceFingerprint.sha256(payload)
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

actor LogUsageAggregateCache {
    static let shared = LogUsageAggregateCache(directory: LogUsageAggregatePaths.defaultDirectory)

    private static let schemaVersion = 1
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
    }

    private let directory: URL
    private var entries: [String: Entry] = [:]
    private var loadedKeys: Set<String> = []

    init(directory: URL = LogUsageAggregatePaths.defaultDirectory) {
        self.directory = directory
    }

    /// Returns the persisted aggregate when `key`, pricing, window, and every source fingerprint
    /// match the stored entry; otherwise runs `compute` and persists its result. `compute`
    /// returning nil (cancellation, unreadable sources) is never persisted, so the next caller
    /// retries rather than caching a failure.
    func scan(
        key: String,
        pricingStamp: String,
        daysBack: Int,
        fingerprints: [String: LogUsageSourceFingerprint],
        now: Date = Date(),
        compute: @Sendable () async -> LogUsageScan?
    ) async -> LogUsageScan? {
        precondition(!key.isEmpty)
        let days = max(1, daysBack)
        _ = loadEntryIfNeeded(key: key)
        if let entry = entries[key],
           entry.schemaVersion == Self.schemaVersion,
           entry.pricingStamp == pricingStamp,
           entry.daysBack == days,
           entry.fingerprints == fingerprints,
           now.timeIntervalSince(entry.computedAt) <= Self.maxReuseAge
        {
            return Self.windowFiltered(entry.scan, daysBack: days, now: now)
        }
        guard let fresh = await compute() else { return nil }
        let entry = Entry(
            schemaVersion: Self.schemaVersion,
            key: key,
            pricingStamp: pricingStamp,
            daysBack: days,
            fingerprints: fingerprints,
            computedAt: now,
            scan: fresh
        )
        entries[key] = entry
        persist(entry)
        return fresh
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
        func keeps(_ day: String) -> Bool { day >= sinceDay }
        let series = DailyUsageSeries(daily: scan.series.daily.filter { keeps($0.date) })
        let modelUsage = scan.modelUsage.map { ModelUsageSeries(daily: $0.daily.filter { keeps($0.date) }) }
        let unknown = scan.unknownModelsByDay.filter { keeps($0.key) }
        return LogUsageScan(series: series, modelUsage: modelUsage, unknownModelsByDay: unknown)
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