import Darwin
import Foundation

/// Disk mirror of the in-memory per-database derived turn cache, validated against the
/// database's WAL revision before use. A fresh process — the scan-worker child, or this app
/// after a memory-pressure unload — reloads derived turns from the record instead of
/// re-running sqlite3 and re-parsing every receipt's metrics JSON. Hosted receipts change on
/// every active-session pass, so the composed whole-scan result cannot be shared across
/// processes; the per-database rows are the stable unit, and pricing applies at fold time.
enum FreebuffDesktopTurnPersistence {
    static let schema = 1
    /// Refuse to cache pathological histories that would dominate the log-scan-cache directory.
    static let maximumRecordBytes = 64 * 1_024 * 1_024
    private static let mutationLock = NSLock()
    /// Test seam: redirects the record directory away from the user's real log-scan-cache.
    nonisolated(unsafe) static var directoryOverride: URL?

    struct Record: Codable {
        var schema: Int
        var revision: [FreebuffDesktopUsageScanner.Revision]
        var rows: [FreebuffDesktopUsageScanner.DerivedTurn]
        var unreadableRows: Int
    }

    static func fileURL(path: String) -> URL {
        let base = directoryOverride ?? JSONLScanCachePaths.defaultDirectory
        return base
            .appendingPathComponent("freebuff-desktop-turns", isDirectory: true)
            .appendingPathComponent("\(JSONLScanCachePaths.stableFingerprint(path)).json")
    }

    /// Return the cached derived turns only when the record's revision still matches the live
    /// snapshot exactly, so a rewritten database can never serve stale rows.
    static func read(
        path: String,
        revision: [FreebuffDesktopUsageScanner.Revision]
    ) -> Record? {
        guard !revision.isEmpty else { return nil }
        return autoreleasepool {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            guard let data = try? Data(contentsOf: fileURL(path: path)),
                  let record = try? decoder.decode(Record.self, from: data),
                  record.schema == schema,
                  record.revision == revision
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
                guard data.count <= maximumRecordBytes else { return }
                let directory = url.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                // The kernel lock orders app/CLI writers on the same file, mirroring the other
                // log-scan-cache records; the write itself is atomic so readers never see a
                // half-written record.
                let descriptor = Darwin.open(directory.appendingPathComponent(".freebuff-desktop-turns.lock").path,
                                             O_CREAT | O_RDWR | O_CLOEXEC, mode_t(S_IRUSR | S_IWUSR))
                guard descriptor >= 0 else { return }
                defer { Darwin.close(descriptor) }
                guard flock(descriptor, LOCK_EX) == 0 else { return }
                defer { flock(descriptor, LOCK_UN) }
                try? data.write(to: url, options: .atomic)
            } catch {
                // The in-memory cache still holds (or re-derives) the rows; a failed disk mirror
                // only costs the next process a SQLite re-read. Log it so persistent failures
                // are visible rather than silently disabling the warm start.
                AppLog.warn(
                    LogTag.plugin("freebuff"),
                    "freebuff desktop turn cache write failed for \(JSONLScanCachePaths.stableFingerprint(path)): \(error.localizedDescription)"
                )
            }
        }
    }
}
