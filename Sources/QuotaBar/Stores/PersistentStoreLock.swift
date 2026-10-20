import Darwin
import Foundation
import os

/// The cross-process lock that serializes writes to the shared snapshot blob.
///
/// `UserDefaults` has no atomic read–modify–write operation, and the app and `quotabar-cli` both
/// store a whole-provider payload under the same key, so their writes have to be serialized against
/// each other under one kernel lock.
///
/// The lock file is opened **once per process** and the descriptor is reused. Re-creating the
/// directory, re-applying its permissions and re-opening the file on every acquisition cost three
/// syscalls per take — and the lock is taken three times per provider refresh. The descriptor is
/// re-validated against the file on disk, so a deleted or replaced lock file cannot silently leave
/// the two processes locking different inodes.
enum PersistentStoreLock {
    /// The lock file, opened once per process.
    struct Handle {
        var url: URL
        var descriptor: Int32
    }

    /// The cached descriptor, or `nil` before the first acquisition.
    private static let cached = OSAllocatedUnfairLock<Handle?>(initialState: nil)

    /// Test instrumentation: how many times this process opened the lock file. The lock is opened
    /// once and reused, so the count must not grow with the number of cache operations.
    static let openCount = OSAllocatedUnfairLock(initialState: 0)

    /// Take the lock, run `body`, then release it. Returns `false` when the lock could not be taken —
    /// the caller skips the write rather than risking the other process's last-good snapshots.
    @discardableResult
    static func withLock(_ body: () -> Void) -> Bool {
        let descriptor = acquireDescriptor()
        guard descriptor >= 0 else { return false }
        guard flock(descriptor, LOCK_EX) == 0 else {
            logFailure(String(cString: strerror(errno)))
            return false
        }
        defer { flock(descriptor, LOCK_UN) }
        DiagnosticGate.clearFailure("cache.providerSnapshots.lock")
        body()
        return true
    }

    /// The cached descriptor, re-opened when it no longer refers to the lock file on disk.
    private static func acquireDescriptor() -> Int32 {
        let existing = cached.withLock { $0 }
        if let existing, existing.descriptor >= 0, descriptorMatchesFile(existing.descriptor, path: existing.url) {
            return existing.descriptor
        }
        guard let opened = openLockFile() else { return -1 }
        if let existing, existing.descriptor >= 0 { Darwin.close(existing.descriptor) }
        cached.withLock { $0 = opened }
        return opened.descriptor
    }

    private static func openLockFile() -> Handle? {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            logFailure("Application Support directory unavailable")
            return nil
        }
        let directory = applicationSupport.appendingPathComponent("QuotaBar", isDirectory: true)
        let lockURL = directory.appendingPathComponent("provider-snapshot-cache.lock")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch {
            logFailure(error.localizedDescription)
            return nil
        }
        var fd = Darwin.open(lockURL.path, O_RDWR | O_CLOEXEC, mode_t(S_IRUSR | S_IWUSR))
        if fd < 0, errno == ENOENT {
            fd = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(S_IRUSR | S_IWUSR))
            if fd >= 0 { _ = Darwin.fchmod(fd, mode_t(S_IRUSR | S_IWUSR)) }
        }
        guard fd >= 0 else {
            logFailure(String(cString: strerror(errno)))
            return nil
        }
        openCount.withLock { $0 += 1 }
        return Handle(url: lockURL, descriptor: fd)
    }

    /// Whether the cached descriptor still refers to the lock file on disk. A deleted or replaced file
    /// would otherwise leave the process locking a private inode — the other process would lock a
    /// different one and the two writes would no longer exclude each other.
    private static func descriptorMatchesFile(_ descriptor: Int32, path: URL) -> Bool {
        var descriptorInfo = stat()
        guard fstat(descriptor, &descriptorInfo) == 0 else { return false }
        var pathInfo = stat()
        guard stat(path.path, &pathInfo) == 0 else { return false }
        return descriptorInfo.st_dev == pathInfo.st_dev && descriptorInfo.st_ino == pathInfo.st_ino
    }

    private static func logFailure(_ message: String) {
        DiagnosticGate.logOnce(for: "cache.providerSnapshots.lock") {
            AppLog.warn(.cache, "snapshot cache write lock unavailable: \(message)")
        }
    }
}
