import Darwin
import Foundation

/// Disk mirror of `ZCodeUsageScanner`'s whole-result cache. The sqlite read is a bounded aggregate
/// over `model_usage` (hundreds of MB of history), so a fresh scan-worker process that has no
/// in-memory cache pays one sqlite3 spawn plus the row scan on every fold. When neither source's
/// file stamps nor the pricing token changed, the persisted result is exact — the same contract
/// the in-memory cache already uses — and the fold reduces to two stats and a small JSON read.
///
/// Failures are never persisted: a scan that ended in a thrown error or a missing-source `nil`
/// result leaves the record untouched so the next fold retries visibly instead of serving a
/// stale "empty" state.
enum ZCodeUsageCachePersistence {
    static let schema = 1
    static let maximumRecordBytes = 16 * 1_024 * 1_024
    private static let mutationLock = NSLock()
    /// Test seam: redirects the record file away from the user's real log-scan-cache.
    nonisolated(unsafe) static var directoryOverride: URL?

    struct Record: Codable {
        var schema: Int
        /// Both source paths are part of the key: stamps alone could collide between a fixture or
        /// a configured home and the default store.
        var sqlitePath: String
        var leveldbPath: String
        var sqliteSize: UInt64?
        var sqliteMtime: Double?
        var leveldbSize: UInt64?
        var leveldbMtime: Double?
        var pricingToken: String
        /// Reference date of the scan — the one-shot promo invalidation replays it against `now`.
        var scannedAt: Date
        var result: ZCodeUsageResult
    }

    static func fileURL() -> URL {
        let base = directoryOverride ?? JSONLScanCachePaths.defaultDirectory
        return base.appendingPathComponent("zcode-usage.json")
    }

    static func read() -> Record? {
        autoreleasepool {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            guard let data = try? Data(contentsOf: fileURL()),
                  let record = try? decoder.decode(Record.self, from: data),
                  record.schema == schema
            else { return nil }
            return record
        }
    }

    static func write(_ record: Record) {
        mutationLock.withLock {
            let url = fileURL()
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .secondsSince1970
                let data = try encoder.encode(record)
                guard data.count <= maximumRecordBytes else { return }
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let descriptor = Darwin.open(url.deletingLastPathComponent()
                    .appendingPathComponent(".zcode-usage.lock").path,
                    O_CREAT | O_RDWR | O_CLOEXEC, mode_t(S_IRUSR | S_IWUSR))
                guard descriptor >= 0 else { return }
                defer { Darwin.close(descriptor) }
                guard flock(descriptor, LOCK_EX) == 0 else { return }
                defer { flock(descriptor, LOCK_UN) }
                try? data.write(to: url, options: .atomic)
            } catch {
                AppLog.warn(
                    LogTag.plugin("zai"),
                    "zcode usage cache write failed: \(error.localizedDescription)"
                )
            }
        }
    }
}
