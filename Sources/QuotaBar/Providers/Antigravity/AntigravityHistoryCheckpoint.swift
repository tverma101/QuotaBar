import Darwin
import Foundation

/// Source-scoped accounting only; conversation text and credentials are never stored.
/// Two slots per source let an atomic manifest switch survive an interrupted app/CLI write.
enum AntigravityHistoryCheckpoint {
    struct Record: Codable, Sendable {
        var path: String
        var device: UInt64
        var inode: UInt64
        var revision: String
        var observedAt: Date
        var windowStart: Date
        var stepTimeZone: String?
        var events: [AntigravityProtoDecoder.GenerationEvent]
        var undated: [Int64]
        var oversized: [Int64]
        var invalidTokens: [Int64]
        var malformed: [Int64]
        // Populated from the manifest after decoding; not part of the on-disk source record.
        var checkpointCandidate: Candidate? = nil

        private enum CodingKeys: String, CodingKey {
            case path, device, inode, revision, observedAt, windowStart, stepTimeZone
            case events, undated, oversized, invalidTokens, malformed
        }
    }

    private struct Metadata: Codable {
        var path: String
        var device: UInt64
        var inode: UInt64
        var revision: String
        var observedAt: Date
        var windowStart: Date
        var stepTimeZone: String?
        var slot: Int
        var recordBytes: Int64
        var recordModifiedAt: Date
    }

    private struct Manifest: Codable {
        var version = 1
        var records: [String: Metadata]
    }

    struct Candidate {
        var device: UInt64
        var inode: UInt64
        var revision: String
        var windowStart: Date
        var stepTimeZone: String?
        var slot: Int
        var recordBytes: Int64
        var recordModifiedAt: Date
    }

    private enum FileState { case valid, missing, invalid }

    static var defaultURL: URL {
        JSONLScanCachePaths.defaultDirectory.appendingPathComponent("antigravity-history.plist")
    }

    private static let lock = NSLock()
    private static let maximumRecordBytes = 64 * 1024 * 1024
    private enum CheckpointError: LocalizedError {
        case recordTooLarge
        var errorDescription: String? { "An Antigravity accounting checkpoint exceeds 64 MiB." }
    }

    /// Merge changed sources and load only unavailable sources. Live sources need no checkpoint
    /// decoding, and one changed database does not rewrite the accounting for its siblings.
    static func update(
        at url: URL,
        records: [Record],
        excluding: (String, Candidate) -> Bool,
        tolerateInvalid: (String, Candidate) -> Bool = { _, _ in false },
        valid: (Record) -> Bool
    ) throws -> [Record] {
        try lock.withLock {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let fd = Darwin.open(url.path + ".lock", O_CREAT | O_RDWR | O_CLOEXEC, mode_t(0o600))
            guard fd >= 0 else { throw posixError() }
            defer { Darwin.close(fd) }
            guard flock(fd, LOCK_EX) == 0 else { throw posixError() }
            defer { flock(fd, LOCK_UN) }

            var manifest = try readManifest(at: url)
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            var changed = false
            for record in records {
                try Task.checkCancellation()
                let id = sourceID(device: record.device, inode: record.inode)
                let old = manifest.records[id]
                if let old, old.revision == record.revision,
                   old.stepTimeZone != record.stepTimeZone, old.observedAt > record.observedAt {
                    continue
                }
                if let old, old.revision == record.revision, old.path == record.path,
                   old.stepTimeZone == record.stepTimeZone,
                   old.windowStart <= record.windowStart || old.observedAt > record.observedAt {
                    switch fileState(old, at: recordURL(base: url, id: id, slot: old.slot)) {
                    case .valid:
                        continue
                    case .missing:
                        // A cache cleaner may remove a record while the app is open. Rebuild it
                        // from this verified live source before publishing another manifest.
                        break
                    case .invalid:
                        break
                    }
                }
                guard valid(record) else { continue }
                // A completed scan of a replacement at this path supersedes the previous source.
                for (otherID, other) in manifest.records where otherID != id && other.path == record.path {
                    manifest.records.removeValue(forKey: otherID)
                }
                let slot = old?.slot == 0 ? 1 : 0
                let data = try JSONLAccountingWorkPacer.shared.perform { try encoder.encode(record) }
                guard data.count <= maximumRecordBytes else { throw CheckpointError.recordTooLarge }
                let destination = recordURL(base: url, id: id, slot: slot)
                try writePrivate(data, at: destination)
                let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
                guard let size = attributes[.size] as? NSNumber,
                      let modified = attributes[.modificationDate] as? Date else {
                    throw CocoaError(.fileReadUnknown)
                }
                manifest.records[id] = Metadata(path: record.path, device: record.device, inode: record.inode,
                    revision: record.revision, observedAt: record.observedAt, windowStart: record.windowStart,
                    stepTimeZone: record.stepTimeZone, slot: slot, recordBytes: size.int64Value,
                    recordModifiedAt: modified)
                changed = true
            }
            try Task.checkCancellation()
            let retained = try manifest.records.sorted(by: { $0.key < $1.key }).compactMap { id, metadata -> Record? in
                try Task.checkCancellation()
                let recordURL = recordURL(base: url, id: id, slot: metadata.slot)
                let candidate = Candidate(device: metadata.device, inode: metadata.inode, revision: metadata.revision,
                    windowStart: metadata.windowStart, stepTimeZone: metadata.stepTimeZone,
                    slot: metadata.slot, recordBytes: metadata.recordBytes, recordModifiedAt: metadata.recordModifiedAt)
                let isExcluded = excluding(metadata.path, candidate)
                let attributes: [FileAttributeKey: Any]
                do {
                    attributes = try FileManager.default.attributesOfItem(atPath: recordURL.path)
                } catch {
                    if tolerateInvalid(metadata.path, candidate) { return nil }
                    throw error
                }
                guard let size = attributes[.size] as? NSNumber, size.int64Value <= maximumRecordBytes else {
                    if tolerateInvalid(metadata.path, candidate) { return nil }
                    throw CocoaError(.fileReadTooLarge)
                }
                guard size.int64Value == metadata.recordBytes,
                      (attributes[.modificationDate] as? Date) == metadata.recordModifiedAt else {
                    if tolerateInvalid(metadata.path, candidate) { return nil }
                    throw CocoaError(.fileReadCorruptFile)
                }
                guard !isExcluded else { return nil }
                var record = try JSONLAccountingWorkPacer.shared.perform {
                    try PropertyListDecoder().decode(Record.self, from: Data(contentsOf: recordURL))
                }
                guard record.path == metadata.path, record.device == metadata.device, record.inode == metadata.inode,
                      record.revision == metadata.revision, record.observedAt == metadata.observedAt,
                      record.windowStart == metadata.windowStart, record.stepTimeZone == metadata.stepTimeZone else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                record.checkpointCandidate = candidate
                return record
            }
            try Task.checkCancellation()
            if changed {
                let manifestData = try encoder.encode(manifest)
                guard manifestData.count <= 4 * 1024 * 1024 else { throw CheckpointError.recordTooLarge }
                try writePrivate(manifestData, at: url)
            }
            return retained
        }
    }

    private static func readManifest(at url: URL) throws -> Manifest {
        guard FileManager.default.fileExists(atPath: url.path) else { return Manifest(records: [:]) }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, size.int64Value <= 4 * 1024 * 1024 else {
            throw CocoaError(.fileReadTooLarge)
        }
        let data = try Data(contentsOf: url)
        guard let envelope = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              (envelope["version"] as? NSNumber)?.intValue == 1 else { throw CocoaError(.fileReadCorruptFile) }
        let manifest = try PropertyListDecoder().decode(Manifest.self, from: data)
        guard manifest.version == 1, manifest.records.allSatisfy({ id, entry in
            (entry.slot == 0 || entry.slot == 1) && entry.inode > 0 && !entry.path.isEmpty
                && id == sourceID(device: entry.device, inode: entry.inode)
        }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return manifest
    }

    private static func sourceID(device: UInt64, inode: UInt64) -> String { "\(device)-\(inode)" }
    private static func fileState(_ metadata: Metadata, at url: URL) -> FileState {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = attributes[.size] as? NSNumber,
                  let modified = attributes[.modificationDate] as? Date else { return .invalid }
            return size.int64Value == metadata.recordBytes && modified == metadata.recordModifiedAt ? .valid : .invalid
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .missing
        } catch {
            return .invalid
        }
    }
    private static func recordURL(base: URL, id: String, slot: Int) -> URL {
        base.deletingLastPathComponent().appendingPathComponent("antigravity-\(id)-\(slot).plist")
    }
    private static func writePrivate(_ data: Data, at url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private static func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}
