import Darwin
import Foundation

/// Disk mirror of the folded Devin session-database winners, validated against the database's file
/// stamps and row-id multiset before use. A fresh process — the scan-worker child, or this app after
/// a memory-pressure unload — reloads the per-request winners instead of re-running the windowed
/// `json_extract` fold over every `message_nodes` row. The winners plus the row-id multiset also let
/// a changed database verify its prefix and fold only appended rows, so routine folds stay cheap even
/// while the WAL churns between scans.
enum DevinSessionUsageCache {
    static let schema = 1
    /// Refuse to cache pathological histories that would dominate the log-scan-cache directory.
    static let maximumRecordBytes = 64 * 1_024 * 1_024
    private static let mutationLock = NSLock()
    /// Test seam: redirects the record directory away from the user's real log-scan-cache.
    nonisolated(unsafe) static var directoryOverride: URL?

    struct Record: Codable, Equatable {
        var schema: Int
        /// `[database, wal]` stamps captured when the fold ran; the wal stamp is nil when no WAL
        /// file existed. Both must equal the live stamps for the zero-query fast path.
        var revision: [StoredStamp?]
        var watermark: Int64
        /// Count and sum of every `message_nodes.row_id` present at `watermark` — metered or not.
        /// Together they prove the prefix row set survived unchanged when only appends are possible.
        var rowCount: Int64
        var rowIdSum: Int64
        var winners: [String: StoredWinner]
    }

    struct StoredStamp: Codable, Equatable {
        var inode: Int64
        /// The stamp's `timeIntervalSinceReferenceDate` — Date serializes with sub-second loss
        /// through secondsSince1970 offset arithmetic, and these stamps gate the zero-query fast
        /// path with a strict equality check, so the raw Double is persisted instead.
        var modified: Double
        var size: Int64
    }

    /// One deduplicated metered call: the newest row of its `request_id` partition. Winners whose
    /// request id is NULL or empty are keyed by their own row id and never replace another row.
    struct StoredWinner: Codable, Equatable {
        var rowId: Int64
        var timestamp: Date
        var model: String
        var input: Int
        var cacheWrite5m: Int
        var cacheRead: Int
        var output: Int
    }

    static func fileURL(path: String) -> URL {
        let base = directoryOverride ?? JSONLScanCachePaths.defaultDirectory
        return base
            .appendingPathComponent("devin-session-usage", isDirectory: true)
            .appendingPathComponent("\(JSONLScanCachePaths.stableFingerprint(path)).json")
    }

    /// Records are keyed by path; callers validate the revision stamps and the database inode against
    /// the live file before trusting the winners, so the read itself stays unvalidated.
    static func read(path: String) -> Record? {
        autoreleasepool {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            guard let data = try? Data(contentsOf: fileURL(path: path)),
                  let record = try? decoder.decode(Record.self, from: data),
                  record.schema == schema
            else { return nil }
            return record
        }
    }

    static func write(_ record: Record, path: String) {
        mutationLock.withLock {
            let url = fileURL(path: path)
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .secondsSince1970
                let data = try encoder.encode(record)
                guard data.count <= maximumRecordBytes else {
                    DiagnosticGate.logOnce(
                        for: "provider.devin.session-usage-record-oversized.\(JSONLScanCachePaths.stableFingerprint(path))"
                    ) {
                        AppLog.warn(
                            LogTag.plugin("devin"),
                            "devin session usage record for \(JSONLScanCachePaths.stableFingerprint(path)) is \(data.count / 1_048_576) MB; not persisting it"
                        )
                    }
                    return
                }
                let directory = url.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                // The kernel lock orders app/scan-worker writers on the same file, mirroring the
                // other log-scan-cache records; the write itself is atomic so readers never see a
                // half-written record.
                let descriptor = Darwin.open(
                    directory.appendingPathComponent(".devin-session-usage.lock").path,
                    O_CREAT | O_RDWR | O_CLOEXEC, mode_t(S_IRUSR | S_IWUSR)
                )
                guard descriptor >= 0 else {
                    throw SQLiteError.queryFailed("devin session usage lock file could not be opened (errno \(errno))")
                }
                defer { Darwin.close(descriptor) }
                guard flock(descriptor, LOCK_EX) == 0 else {
                    throw SQLiteError.queryFailed("devin session usage lock could not be acquired (errno \(errno))")
                }
                defer { flock(descriptor, LOCK_UN) }
                try data.write(to: url, options: .atomic)
            } catch {
                // The in-memory fold still holds; a failed disk mirror only costs the next process a
                // SQLite re-read. Log it so persistent failures are visible rather than silently
                // disabling the warm start.
                AppLog.warn(
                    LogTag.plugin("devin"),
                    "devin session usage cache write failed for \(JSONLScanCachePaths.stableFingerprint(path)): \(error.localizedDescription)"
                )
            }
        }
    }
}
