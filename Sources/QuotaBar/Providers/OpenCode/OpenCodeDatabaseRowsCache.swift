import Darwin
import Foundation

/// Disk mirror of the sqlite stage's `json_group_array` chunks, validated like the other
/// log-scan caches: an exact revision-stamp match reuses rows for free, and a content
/// fingerprint rescues a stamp that only moved on WAL churn. A fresh process — a cold CLI
/// child, or this app after an unload — skips the chunked whole-history read entirely instead of
/// re-running bounded `sqlite3` queries over ~10 years of billing rows.
enum OpenCodeDatabaseRowsCache {
    static let schema = 1
    /// Chunk JSON is already bounded by the sqlite3 marshaling cap; refuse only pathological stores.
    static let maximumRecordBytes = 256 * 1_024 * 1_024
    private static let mutationLock = NSLock()
    /// Test seam: redirects the record directory away from the user's real log-scan-cache.
    nonisolated(unsafe) static var directoryOverride: URL?

    struct Record: Codable {
        var schema: Int
        var revisionStamp: String
        var chunks: [String]
        /// Aggregate over the source tables captured at read time. A stamp that moved on WAL
        /// churn alone produces the same fingerprint, proving the stored chunks still describe
        /// the live projection. Nil on records written before the gate existed.
        var contentFingerprint: String?
    }

    static func fileURL(path: String) -> URL {
        let base = directoryOverride ?? JSONLScanCachePaths.defaultDirectory
        return base
            .appendingPathComponent("opencode-db-rows", isDirectory: true)
            .appendingPathComponent("\(JSONLScanCachePaths.stableFingerprint(path)).json")
    }

    /// Return the stored chunks only when the record's stamp still matches the live file exactly.
    static func read(path: String, revisionStamp: String) -> Record? {
        load(path: path).flatMap { $0.revisionStamp == revisionStamp ? $0 : nil }
    }

    /// Decode the record regardless of stamp so the caller's fingerprint can rescue WAL churn.
    static func readAnyRevision(path: String) -> Record? {
        load(path: path)
    }

    private static func load(path: String) -> Record? {
        autoreleasepool {
            guard let data = try? Data(contentsOf: fileURL(path: path)),
                  let record = try? JSONDecoder().decode(Record.self, from: data),
                  record.schema == schema
            else { return nil }
            return record
        }
    }

    static func write(_ record: Record, path: String) {
        mutationLock.withLock {
            let url = fileURL(path: path)
            do {
                let data = try JSONEncoder().encode(record)
                guard data.count <= maximumRecordBytes else { return }
                let directory = url.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                // The kernel lock orders app/CLI writers on the same file, mirroring the other
                // log-scan-cache records; the write itself is atomic so readers never see a
                // half-written record.
                let descriptor = Darwin.open(directory.appendingPathComponent(".opencode-db-rows.lock").path,
                                             O_CREAT | O_RDWR | O_CLOEXEC, mode_t(S_IRUSR | S_IWUSR))
                guard descriptor >= 0 else { return }
                defer { Darwin.close(descriptor) }
                guard flock(descriptor, LOCK_EX) == 0 else { return }
                defer { flock(descriptor, LOCK_UN) }
                try? data.write(to: url, options: .atomic)
            } catch {
                AppLog.warn(
                    LogTag.plugin("opencode"),
                    "opencode db rows cache write failed for \(JSONLScanCachePaths.stableFingerprint(path)): \(error.localizedDescription)"
                )
            }
        }
    }
}
