import Darwin
import Foundation

/// Disk mirror of one Antigravity conversation database's derived scan state — parsed generation
/// events, the priced daily aggregate, and the step timestamp index — validated against the
/// database's file stamps before use. A fresh process (the scan-worker child, or this app after a
/// memory-pressure unload) reloads the record instead of re-reading SQLite and re-decoding
/// protobufs. Records carry the raw events so a changed database can verify its prefix and fold
/// only appended rows, exactly like the in-memory cache path; the persisted step index is verified
/// the same way (its table fingerprint against the live prefix digest) so reuse never skips the
/// correctness check — it only skips the per-page table scan.
enum AntigravityAggregatePersistence {
    // v2: the oversized-row projection reads in 512-byte chunks, so records produced under the old
    // 4 KiB chunk reader's read-budget refusals are suspect. Keep schema-1 records that never hit a
    // refused oversized row; the rest rescan for real instead of replaying a truncated history.
    static let schema = 2
    /// Refuse to cache pathological histories that would dominate the log-scan-cache directory.
    static let maximumRecordBytes = 64 * 1_024 * 1_024
    private static let mutationLock = NSLock()
    /// Test seam: redirects the record directory away from the user's real log-scan-cache.
    nonisolated(unsafe) static var directoryOverride: URL?

    struct Record: Codable {
        var schema: Int
        var cache: AntigravityDbUsageScanner.CachedDatabase
    }

    static func fileURL(path: String) -> URL {
        let base = directoryOverride ?? JSONLScanCachePaths.defaultDirectory
        return base
            .appendingPathComponent("antigravity-db-derivations", isDirectory: true)
            .appendingPathComponent("\(JSONLScanCachePaths.stableFingerprint(path)).json")
    }

    /// Records are keyed by path and always carry their own file stamps; callers validate the
    /// stamps against the live database, so the read itself stays unvalidated.
    static func read(path: String) -> Record? {
        autoreleasepool {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            guard let data = try? Data(contentsOf: fileURL(path: path)),
                  let record = try? decoder.decode(Record.self, from: data),
                  record.schema == schema
                      || (record.schema == 1 && record.cache.oversizedTimestamps.isEmpty)
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
                        for: "provider.antigravity.derivation-record-oversized.\(JSONLScanCachePaths.stableFingerprint(path))"
                    ) {
                        AppLog.warn(
                            LogTag.plugin("antigravity"),
                            "antigravity derivation record for \(JSONLScanCachePaths.stableFingerprint(path)) is \(data.count / 1_048_576) MB; not persisting it"
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
                    directory.appendingPathComponent(".antigravity-db-derivations.lock").path,
                    O_CREAT | O_RDWR | O_CLOEXEC, mode_t(S_IRUSR | S_IWUSR)
                )
                guard descriptor >= 0 else {
                    throw SQLiteError.queryFailed("antigravity derivation lock file could not be opened (errno \(errno))")
                }
                defer { Darwin.close(descriptor) }
                guard flock(descriptor, LOCK_EX) == 0 else {
                    throw SQLiteError.queryFailed("antigravity derivation lock could not be acquired (errno \(errno))")
                }
                defer { flock(descriptor, LOCK_UN) }
                try data.write(to: url, options: .atomic)
            } catch {
                // The in-memory cache still holds (or re-derives) the state; a failed disk mirror
                // only costs the next process a SQLite re-read. Log it so persistent failures are
                // visible rather than silently disabling the warm start.
                AppLog.warn(
                    LogTag.plugin("antigravity"),
                    "antigravity derivation cache write failed for \(JSONLScanCachePaths.stableFingerprint(path)): \(error.localizedDescription)"
                )
            }
        }
    }
}
