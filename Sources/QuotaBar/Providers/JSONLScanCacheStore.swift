import Darwin
import Foundation

/// Disk policy for one JSONL parser. `namespace` identifies the provider/parser; the scanner adds a
/// stable provider/home identity below it. Bump `schemaVersion` whenever the persisted item meaning
/// changes, including changes to nested values such as `TokenBreakdown`.
struct JSONLScanCachePersistence: Sendable {
    var namespace: String
    var schemaVersion: Int
    var directory: URL
    var writeDebounce: Duration

    init(
        namespace: String,
        schemaVersion: Int,
        directory: URL = JSONLScanCachePaths.defaultDirectory,
        writeDebounce: Duration = .seconds(2)
    ) {
        precondition(!namespace.isEmpty)
        precondition(namespace.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" })
        precondition(schemaVersion > 0)
        self.namespace = namespace
        self.schemaVersion = schemaVersion
        self.directory = directory
        self.writeDebounce = writeDebounce
    }
}

struct JSONLScanCacheFileMetadata: Codable, Sendable, Equatable {
    var size: Int
    var mtime: Date
    var attributeMtime: Date?
    var recordFileName: String

    init(size: Int, mtime: Date, attributeMtime: Date? = nil, recordFileName: String) {
        self.size = size
        self.mtime = mtime
        self.attributeMtime = attributeMtime
        self.recordFileName = recordFileName
    }
}

struct JSONLScanCacheManifest: Codable, Sendable {
    var formatVersion: Int
    var schemaVersion: Int
    var identity: String
    /// Diagnostic/retention timestamp for the last successful lock-scoped manifest merge.
    var generatedAt: Date
    var files: [String: JSONLScanCacheFileMetadata]
}

struct JSONLScanCacheUpsert: Sendable {
    var metadata: JSONLScanCacheFileMetadata
    var recordData: Data
}

struct JSONLScanCacheWriteBatch: Sendable {
    var persistence: JSONLScanCachePersistence
    var identity: String
    /// Only new or changed source paths are present. The writer verifies each path's current stat before
    /// publishing it, so a slow process cannot replace a newer parse of the same source file.
    var upserts: [String: JSONLScanCacheUpsert]
    /// A removal applies only while the on-disk source revision still equals the value this scanner
    /// observed. Paths added or changed by another app/CLI process are therefore preserved.
    var removals: [String: JSONLScanCacheFileMetadata]
}

struct JSONLScanCacheCommitResult: Sendable {
    var manifest: JSONLScanCacheManifest
    var acceptedUpsertPaths: Set<String>
}

struct JSONLScanCacheRecord<Item: Codable & Sendable>: Codable, Sendable {
    var path: String
    var size: Int
    var mtime: Date
    var attributeMtime: Date?
    var items: [Item]

    init(path: String, size: Int, mtime: Date, attributeMtime: Date? = nil, items: [Item]) {
        self.path = path
        self.size = size
        self.mtime = mtime
        self.attributeMtime = attributeMtime
        self.items = items
    }
}

struct JSONLScanCachedFile<Item: Codable & Sendable>: Sendable {
    var size: Int
    var mtime: Date
    var attributeMtime: Date?
    var items: [Item]

    init(size: Int, mtime: Date, attributeMtime: Date? = nil, items: [Item]) {
        self.size = size
        self.mtime = mtime
        self.attributeMtime = attributeMtime
        self.items = items
    }
}

struct JSONLScanCacheReadSnapshot<Item: Codable & Sendable>: Sendable {
    var manifest: JSONLScanCacheManifest
    var files: [String: JSONLScanCachedFile<Item>]
    var invalidRecords: [String: JSONLScanCacheFileMetadata]
}

enum JSONLScanCachePaths {
    /// v3 makes manifest-referenced record files immutable per source revision. In v2 every revision
    /// of one source path reused the same payload filename, so a stale writer could overwrite bytes
    /// while a newer manifest still pointed at that pathname.
    static let formatVersion = 3
    static let staleIdentityRetention: TimeInterval = 35 * 86_400

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QuotaBar/log-scan-cache", isDirectory: true)
    }

    static func identityDirectory(
        persistence: JSONLScanCachePersistence,
        identity: String
    ) -> URL {
        persistence.directory.appendingPathComponent(
            "\(persistence.namespace)-\(stableFingerprint(identity))",
            isDirectory: true
        )
    }

    static func manifestURL(persistence: JSONLScanCachePersistence, identity: String) -> URL {
        identityDirectory(persistence: persistence, identity: identity)
            .appendingPathComponent("manifest.plist")
    }

    static func recordsDirectory(persistence: JSONLScanCachePersistence, identity: String) -> URL {
        identityDirectory(persistence: persistence, identity: identity)
            .appendingPathComponent("files", isDirectory: true)
    }

    /// Stable path alias retained for test/debug callers. It is never authoritative: v3 manifests
    /// reference the revision-specific filename below. The writer maintains this as a hard link, so
    /// compatibility costs one directory entry rather than a second copy of the payload bytes.
    static func recordFileName(path: String) -> String {
        "\(stableFingerprint(path)).plist"
    }

    /// Immutable payload name for one exact cheap source revision. Different size/content-mtime/ctime
    /// tuples cannot share a manifest-referenced record pathname, so stale work cannot mutate the bytes
    /// belonging to a newer manifest generation.
    static func recordFileName(
        path: String,
        size: Int,
        mtime: Date,
        attributeMtime: Date?
    ) -> String {
        let attributeBits = attributeMtime.map {
            String($0.timeIntervalSinceReferenceDate.bitPattern)
        } ?? "nil"
        let revision = [
            path,
            String(size),
            String(mtime.timeIntervalSinceReferenceDate.bitPattern),
            attributeBits,
        ].joined(separator: "\u{0}")
        return "\(stableFingerprint(path))-\(stableFingerprint(revision)).plist"
    }

    static func recordURL(
        persistence: JSONLScanCachePersistence,
        identity: String,
        fileName: String
    ) -> URL {
        recordsDirectory(persistence: persistence, identity: identity)
            .appendingPathComponent(fileName)
    }

    static func lockURL(persistence: JSONLScanCachePersistence, identity: String) -> URL {
        let directoryName = identityDirectory(persistence: persistence, identity: identity).lastPathComponent
        return persistence.directory.appendingPathComponent(".\(directoryName).lock")
    }

    /// Swift's `Hasher` is randomized per process; FNV-1a gives stable compact names across launches.
    /// Manifests/records also carry and validate the unhashed identity/path, so a theoretical collision
    /// causes a safe reparse instead of serving another source's items.
    static func stableFingerprint(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }
}

/// Serializes manifest publication within the process and uses `flock` to order app/CLI writers. Each
/// batch carries path-level mutations, which are merged with the current manifest while locked so
/// overlapping processes preserve one another's work. Revision-immutable records land before the
/// manifest, so a crash can leave an orphan record but never publish metadata for half-written bytes.
actor JSONLScanCacheWriter {
    static let shared = JSONLScanCacheWriter()

    func commit(_ batch: JSONLScanCacheWriteBatch) throws -> JSONLScanCacheCommitResult {
        let persistence = batch.persistence
        let identity = batch.identity
        let manifestURL = JSONLScanCachePaths.manifestURL(
            persistence: persistence,
            identity: identity
        )

        return try Self.withExclusiveLock(
            at: JSONLScanCachePaths.lockURL(persistence: persistence, identity: identity)
        ) {
            let current = Self.readManifest(at: manifestURL)
            let currentIsCompatible = current?.formatVersion == JSONLScanCachePaths.formatVersion
                && current?.schemaVersion == persistence.schemaVersion
                && current?.identity == identity
            var mergedFiles: [String: JSONLScanCacheFileMetadata]
            if currentIsCompatible {
                mergedFiles = current?.files ?? [:]
            } else {
                mergedFiles = [:]
            }

            var didMutateManifest = false
            for (path, expectedMetadata) in batch.removals {
                guard let currentMetadata = mergedFiles[path],
                      Self.sameSourceRevision(currentMetadata, expectedMetadata)
                else { continue }
                mergedFiles[path] = nil
                didMutateManifest = true
            }

            let identityDirectory = JSONLScanCachePaths.identityDirectory(
                persistence: persistence,
                identity: identity
            )
            let recordsDirectory = JSONLScanCachePaths.recordsDirectory(
                persistence: persistence,
                identity: identity
            )
            var acceptedUpsertPaths: Set<String> = []
            if !batch.upserts.isEmpty {
                try Self.createPrivateDirectory(persistence.directory)
                try Self.createPrivateDirectory(identityDirectory)
                try Self.createPrivateDirectory(recordsDirectory)
                for (path, upsert) in batch.upserts
                    where Self.sourceMatchesForPublication(path: path, metadata: upsert.metadata)
                {
                    var publishedMetadata = upsert.metadata
                    publishedMetadata.recordFileName = JSONLScanCachePaths.recordFileName(
                        path: path,
                        size: upsert.metadata.size,
                        mtime: upsert.metadata.mtime,
                        attributeMtime: upsert.metadata.attributeMtime
                    )
                    let immutableURL = recordsDirectory.appendingPathComponent(publishedMetadata.recordFileName)
                    try Self.writePrivate(upsert.recordData, to: immutableURL)

                    // Keep the old path-keyed test/debug surface without making it authoritative. A
                    // hard link shares the immutable record's bytes/inode and adds no second payload.
                    let aliasURL = recordsDirectory.appendingPathComponent(
                        JSONLScanCachePaths.recordFileName(path: path)
                    )
                    try Self.replaceHardLink(to: immutableURL, at: aliasURL)

                    mergedFiles[path] = publishedMetadata
                    acceptedUpsertPaths.insert(path)
                    didMutateManifest = true
                }
            }

            // A batch whose removals were all stale and whose upserts were all rejected must not touch
            // the cache generation at all. In particular it must not rewrite the manifest, run record
            // GC, or delete an identity directory owned by newer work from another process.
            if !didMutateManifest {
                if let current, currentIsCompatible {
                    return JSONLScanCacheCommitResult(
                        manifest: current,
                        acceptedUpsertPaths: acceptedUpsertPaths
                    )
                }
                return JSONLScanCacheCommitResult(
                    manifest: JSONLScanCacheManifest(
                        formatVersion: JSONLScanCachePaths.formatVersion,
                        schemaVersion: persistence.schemaVersion,
                        identity: identity,
                        generatedAt: Date(),
                        files: mergedFiles
                    ),
                    acceptedUpsertPaths: acceptedUpsertPaths
                )
            }

            let manifest = JSONLScanCacheManifest(
                formatVersion: JSONLScanCachePaths.formatVersion,
                schemaVersion: persistence.schemaVersion,
                identity: identity,
                generatedAt: Date(),
                files: mergedFiles
            )
            if mergedFiles.isEmpty {
                if FileManager.default.fileExists(atPath: identityDirectory.path) {
                    try FileManager.default.removeItem(at: identityDirectory)
                }
                return JSONLScanCacheCommitResult(
                    manifest: manifest,
                    acceptedUpsertPaths: acceptedUpsertPaths
                )
            }

            try Self.createPrivateDirectory(persistence.directory)
            try Self.createPrivateDirectory(identityDirectory)
            try Self.createPrivateDirectory(recordsDirectory)
            // Publish metadata last. A reader either sees the complete old generation or complete new one.
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            try Self.writePrivate(try encoder.encode(manifest), to: manifestURL)

            let referenced = Set(mergedFiles.values.map(\.recordFileName))
            let compatibilityAliases = Set(mergedFiles.keys.map { JSONLScanCachePaths.recordFileName(path: $0) })
            let existing = try FileManager.default.contentsOfDirectory(
                at: recordsDirectory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            for url in existing
                where url.pathExtension == "plist"
                    && !referenced.contains(url.lastPathComponent)
                    && !compatibilityAliases.contains(url.lastPathComponent)
            {
                try FileManager.default.removeItem(at: url)
            }
            return JSONLScanCacheCommitResult(
                manifest: manifest,
                acceptedUpsertPaths: acceptedUpsertPaths
            )
        }
    }

    /// Reads one identity under a shared cross-process lock and marks it recently used before releasing
    /// that lock. A concurrent stale-cache cleanup must then re-check the touched directory and keep it.
    nonisolated func load<Item: Codable & Sendable>(
        persistence: JSONLScanCachePersistence,
        identity: String,
        itemType: Item.Type
    ) throws -> JSONLScanCacheReadSnapshot<Item>? {
        _ = itemType
        let identityDirectory = JSONLScanCachePaths.identityDirectory(
            persistence: persistence,
            identity: identity
        )
        guard FileManager.default.fileExists(atPath: identityDirectory.path) else { return nil }
        let manifestURL = JSONLScanCachePaths.manifestURL(
            persistence: persistence,
            identity: identity
        )
        let manifestData = try Self.withSharedLock(
            at: JSONLScanCachePaths.lockURL(persistence: persistence, identity: identity)
        ) {
            let data = try Data(contentsOf: manifestURL, options: .mappedIfSafe)
            do {
                try FileManager.default.setAttributes(
                    [.modificationDate: Date()],
                    ofItemAtPath: identityDirectory.path
                )
            } catch {
                AppLog.warn(
                    .cache,
                    "could not mark \(persistence.namespace) log parse cache as used: \(error.localizedDescription)"
                )
            }
            return data
        }
        let manifest = try JSONLAccountingWorkPacer.shared.perform {
            try PropertyListDecoder().decode(JSONLScanCacheManifest.self, from: manifestData)
        }
        var files: [String: JSONLScanCachedFile<Item>] = [:]
        var invalidRecords: [String: JSONLScanCacheFileMetadata] = [:]
        if manifest.formatVersion == JSONLScanCachePaths.formatVersion,
           manifest.schemaVersion == persistence.schemaVersion,
           manifest.identity == identity
        {
            files.reserveCapacity(manifest.files.count)
            let recordDecoder = PropertyListDecoder()
            for (path, metadata) in manifest.files {
                let url = JSONLScanCachePaths.recordURL(
                    persistence: persistence,
                    identity: identity,
                    fileName: metadata.recordFileName
                )
                let data: Data
                do {
                    data = try Self.withSharedLock(
                        at: JSONLScanCachePaths.lockURL(persistence: persistence, identity: identity)
                    ) {
                        try Data(contentsOf: url, options: .mappedIfSafe)
                    }
                } catch {
                    invalidRecords[path] = metadata
                    continue
                }
                guard let record = JSONLAccountingWorkPacer.shared.perform({
                    try? recordDecoder.decode(JSONLScanCacheRecord<Item>.self, from: data)
                }),
                record.path == path,
                record.size == metadata.size,
                record.mtime == metadata.mtime,
                record.attributeMtime == metadata.attributeMtime
                else {
                    invalidRecords[path] = metadata
                    continue
                }
                files[path] = JSONLScanCachedFile(
                    size: record.size,
                    mtime: record.mtime,
                    attributeMtime: record.attributeMtime,
                    items: record.items
                )
            }
        }
        return JSONLScanCacheReadSnapshot(
            manifest: manifest,
            files: files,
            invalidRecords: invalidRecords
        )
    }

    /// Manifest + touch only. Used when the scanner keeps resident items unloaded and hydrates
    /// individual records on demand.
    nonisolated func loadManifest(
        persistence: JSONLScanCachePersistence,
        identity: String
    ) throws -> JSONLScanCacheManifest? {
        let identityDirectory = JSONLScanCachePaths.identityDirectory(
            persistence: persistence,
            identity: identity
        )
        guard FileManager.default.fileExists(atPath: identityDirectory.path) else { return nil }
        let manifestData = try Self.withSharedLock(
            at: JSONLScanCachePaths.lockURL(persistence: persistence, identity: identity)
        ) {
            let manifestURL = JSONLScanCachePaths.manifestURL(
                persistence: persistence,
                identity: identity
            )
            let manifestData = try Data(contentsOf: manifestURL, options: .mappedIfSafe)
            do {
                try FileManager.default.setAttributes(
                    [.modificationDate: Date()],
                    ofItemAtPath: identityDirectory.path
                )
            } catch {
                AppLog.warn(
                    .cache,
                    "could not mark \(persistence.namespace) log parse cache as used: \(error.localizedDescription)"
                )
            }
            return manifestData
        }
        return try JSONLAccountingWorkPacer.shared.perform {
            try PropertyListDecoder().decode(JSONLScanCacheManifest.self, from: manifestData)
        }
    }

    /// Decode one persisted file record. Returns nil when the bytes are missing or fail validation.
    nonisolated func loadRecord<Item: Codable & Sendable>(
        persistence: JSONLScanCachePersistence,
        identity: String,
        path: String,
        metadata: JSONLScanCacheFileMetadata,
        itemType: Item.Type
    ) throws -> JSONLScanCachedFile<Item>? {
        _ = itemType
        let url = JSONLScanCachePaths.recordURL(
            persistence: persistence,
            identity: identity,
            fileName: metadata.recordFileName
        )
        let data = try Self.withSharedLock(
            at: JSONLScanCachePaths.lockURL(persistence: persistence, identity: identity)
        ) {
            try? Data(contentsOf: url, options: .mappedIfSafe)
        }
        guard let data,
              let record = JSONLAccountingWorkPacer.shared.perform({
                  try? PropertyListDecoder().decode(JSONLScanCacheRecord<Item>.self, from: data)
              }),
              record.path == path,
              record.size == metadata.size,
              record.mtime == metadata.mtime,
              record.attributeMtime == metadata.attributeMtime
        else { return nil }
        return JSONLScanCachedFile(
            size: record.size,
            mtime: record.mtime,
            attributeMtime: record.attributeMtime,
            items: record.items
        )
    }

    /// Removes identity directories that have not been read or written for longer than the retained scan
    /// window. The tiny lock files contain no usage data and intentionally remain: unlinking a lock
    /// file while another process holds its inode would undermine cross-process exclusion.
    func pruneStaleIdentities(
        persistence: JSONLScanCachePersistence,
        before cutoff: Date
    ) {
        let prefix = "\(persistence.namespace)-"
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: persistence.directory,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for directory in contents where directory.lastPathComponent.hasPrefix(prefix) {
            guard let values = try? directory.resourceValues(
                forKeys: [.isDirectoryKey, .contentModificationDateKey]
            ),
            values.isDirectory == true,
            let modified = values.contentModificationDate,
            modified < cutoff
            else { continue }

            let lockURL = persistence.directory.appendingPathComponent(".\(directory.lastPathComponent).lock")
            do {
                try Self.withExclusiveLock(at: lockURL, nonblocking: true) {
                    guard let lockedValues = try? directory.resourceValues(
                        forKeys: [.isDirectoryKey, .contentModificationDateKey]
                    ),
                    lockedValues.isDirectory == true,
                    let lockedModified = lockedValues.contentModificationDate,
                    lockedModified < cutoff
                    else { return }
                    try FileManager.default.removeItem(at: directory)
                }
            } catch let error as POSIXError where error.code == .EWOULDBLOCK {
                continue
            } catch {
                AppLog.warn(
                    .cache,
                    "could not prune stale \(persistence.namespace) log parse cache: \(error.localizedDescription)"
                )
            }
        }
    }

    private static func readManifest(at url: URL) -> JSONLScanCacheManifest? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return try? PropertyListDecoder().decode(JSONLScanCacheManifest.self, from: data)
    }

    private static func sameSourceRevision(
        _ lhs: JSONLScanCacheFileMetadata,
        _ rhs: JSONLScanCacheFileMetadata
    ) -> Bool {
        lhs.size == rhs.size
            && timestampsMatch(lhs.mtime, rhs.mtime)
            && optionalTimestampsMatch(lhs.attributeMtime, rhs.attributeMtime)
    }

    /// Publication is fail-closed on the complete revision tuple when ctime/attribute-time is
    /// available. A stale same-size rewrite that restores content mtime must not be allowed to publish
    /// old parse bytes. Tiny tolerance handles Foundation/filesystem timestamp quantization only.
    private static func sourceMatchesForPublication(
        path: String,
        metadata: JSONLScanCacheFileMetadata
    ) -> Bool {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .attributeModificationDateKey,
        ]
        guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: keys),
              values.isRegularFile == true,
              values.fileSize == metadata.size,
              let currentMtime = values.contentModificationDate,
              timestampsMatch(currentMtime, metadata.mtime)
        else {
            return false
        }
        if let expectedAttributeMtime = metadata.attributeMtime {
            guard let currentAttributeMtime = values.attributeModificationDate,
                  timestampsMatch(currentAttributeMtime, expectedAttributeMtime)
            else { return false }
        }
        return true
    }

    private static func timestampsMatch(_ lhs: Date, _ rhs: Date) -> Bool {
        abs(lhs.timeIntervalSinceReferenceDate - rhs.timeIntervalSinceReferenceDate) <= 0.001
    }

    private static func optionalTimestampsMatch(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none): return true
        case (.some(let lhs), .some(let rhs)): return timestampsMatch(lhs, rhs)
        default: return false
        }
    }

    private static func createPrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private static func writePrivate(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func replaceHardLink(to source: URL, at alias: URL) throws {
        if FileManager.default.fileExists(atPath: alias.path) {
            try FileManager.default.removeItem(at: alias)
        }
        try FileManager.default.linkItem(at: source, to: alias)
    }

    private static func withExclusiveLock<Result>(
        at url: URL,
        nonblocking: Bool = false,
        _ body: () throws -> Result
    ) throws -> Result {
        try withLock(
            at: url,
            operation: LOCK_EX | (nonblocking ? LOCK_NB : 0),
            body
        )
    }

    private static func withSharedLock<Result>(
        at url: URL,
        _ body: () throws -> Result
    ) throws -> Result {
        try withLock(at: url, operation: LOCK_SH, body)
    }

    private static func withLock<Result>(
        at url: URL,
        operation: Int32,
        _ body: () throws -> Result
    ) throws -> Result {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.deletingLastPathComponent().path
        )
        let fd = Darwin.open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(S_IRUSR | S_IWUSR))
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer {
            flock(fd, LOCK_UN)
            Darwin.close(fd)
        }
        guard Darwin.fchmod(fd, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        guard flock(fd, operation) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        return try body()
    }
}
