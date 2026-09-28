import Foundation
import os

/// Resolves the log file URL and owns a serial, lock-guarded `FileHandle` appender with single-archive
/// rotation. `@unchecked Sendable` because all mutable state is guarded by an internal `NSLock`, so it
/// can be written to from any isolation (the `Sendable` provider structs, the `@MainActor` UI, etc.) —
/// the `nonisolated`-static-`Logger` precedent in `LocalUsageServer`, plus the lock for the handle.
///
/// Rotation matches the Tauri cap (`.max_file_size(10_000_000)`): when a write would exceed 10 MB the
/// current file becomes `QuotaBar.1.log` and a fresh `QuotaBar.log` opens — bounding disk to ~20 MB
/// while keeping one archive of recent history for user-submitted reports (a deliberate, minor
/// improvement over Tauri's KeepOne, which discards all history). On launch an already-oversize file is
/// rotated once before the first write. If opening/rotating fails the sink fails loudly to `os.Logger`
/// at error and disables itself for the session — never crashes, never silently spins.
final class LogFile: @unchecked Sendable {
    /// The shared production sink. Other code logs through `AppLog`, which writes here. Resolves
    /// `~/Library/Logs/QuotaBar/QuotaBar.log` via `FileManager`, never hardcoded from `$HOME`; the
    /// `Logs/QuotaBar` subfolder is a literal (not bundle-id-keyed), so the dev and release builds
    /// agree on the same file — acceptable since they are separate builds.
    static let shared = LogFile(directory: defaultDirectory(), fileName: "QuotaBar.log")

    /// The advertised log path (logged at startup, copied/revealed from Settings). Derived from the
    /// shared sink so the path shown to the user always equals where logs are actually written.
    static let url: URL = shared.fileURL

    static let defaultMaxBytes = 10_000_000

    /// Where this sink actually writes. Exposed (read-only) so `url` can derive the advertised path
    /// from the single source of truth rather than recomputing it.
    let fileURL: URL
    private let archiveURL: URL
    private let directory: URL
    private let maxBytes: Int
    private let fallbackLogger = Logger(subsystem: "QuotaBar", category: "logfile")

    private let lock = NSLock()
    private var handle: FileHandle?
    private var size = 0
    private var disabled = false
    private var opened = false

    /// - Parameters:
    ///   - directory: the folder the log file lives in (created on open if missing).
    ///   - fileName: the log file name (the archive appends `.1` before the extension).
    ///   - maxBytes: rotation cap; defaults to the 10 MB Tauri cap.
    init(directory: URL, fileName: String, maxBytes: Int = defaultMaxBytes) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent(fileName)
        self.maxBytes = maxBytes
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        let archiveName = ext.isEmpty ? "\(base).1" : "\(base).1.\(ext)"
        self.archiveURL = directory.appendingPathComponent(archiveName)
    }

    /// Environment override for the log directory, e.g. to capture a run's logs somewhere convenient.
    /// Wins over every other rule below.
    static let directoryEnvironmentKey = "QUOTABAR_LOG_DIR"

    /// Where a *shipped* app writes: `~/Library/Logs/QuotaBar`. Split out from `defaultDirectory()` so
    /// the production location stays assertable from tests without tests having to resolve to it.
    static func productionDirectory() -> URL {
        // `.first` with a fallback rather than `[0]`: the lookup effectively always resolves on stock
        // macOS, but a force-index would crash the app at launch (this runs during `bootstrap()`) if it
        // ever returned empty in an unusual container. A non-ideal-but-valid directory keeps the app alive.
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return library.appendingPathComponent("Logs/QuotaBar", isDirectory: true)
    }

    /// True when this process is a test bundle. `swift test` resolves `.userDomainMask` to the *real*
    /// home directory, so without this the suite appends to the user's actual production log.
    ///
    /// Detection has to be indirect, and each candidate was verified against a real `swift test` run:
    /// - `Bundle.main` is the xctest **runner** binary (`.../Xcode.app/.../usr/bin`), not the test
    ///   bundle, so `Bundle.main.bundlePath.hasSuffix(".xctest")` is always false.
    /// - Modern XCTest does not set `XCTestConfigurationFilePath`; it is nil under `swift test`.
    /// - `XCTestCase` being loadable is what actually holds, for both XCTest classes and swift-testing
    ///   suites. Cheap, so it is checked before the bundle scan, which is the expensive fallback.
    static var isRunningUnderTest: Bool {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return true }
        if NSClassFromString("XCTestCase") != nil { return true }
        return Bundle.allBundles.contains { $0.bundlePath.hasSuffix(".xctest") }
    }

    static func defaultDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment[directoryEnvironmentKey],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        // A test run must not write to `~/Library/Logs/QuotaBar`.
        //
        // `LogFile.shared` is a lazily-initialised `static let`, so the first log line a test emits
        // would otherwise open the real production file and append to it for the rest of the run. That
        // log is not private scratch space: the app advertises this exact path at startup and in
        // Settings, and users are told to send it with bug reports. So `swift test` used to interleave
        // fixtures ("migrated settings to schema v1", fake providers like `stub`/`devin`, and even a
        // `QuotaBarTests.SettingsMigratorTests...` error description) into the file a maintainer reads
        // when diagnosing a real report — and push it through the same 10 MB rotation budget.
        //
        // Per-uid subdirectory so concurrent test processes on one machine cannot collide, and so
        // parallel runs do not write through each other's handles.
        if isRunningUnderTest {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("QuotaBarTests-\(getuid())/Logs", isDirectory: true)
        }
        return productionDirectory()
    }

    /// Create the directory and file, seed the in-memory size from disk, and perform the launch-time
    /// trim (rotate once if an already-oversize file is left over from a long-dead session). Idempotent.
    func open() {
        lock.lock()
        defer { lock.unlock() }
        guard !opened else { return }
        opened = true
        do {
            try openLocked()
        } catch {
            failLocked("open failed: \(error.localizedDescription)")
        }
    }

    /// Append one already-formatted line (a newline is added). Rotates first if the line would push the
    /// file past the cap. No-op once the sink is disabled.
    func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        guard !disabled else { return }
        if !opened {
            opened = true
            do {
                try openLocked()
            } catch {
                failLocked("open failed: \(error.localizedDescription)")
                return
            }
        }
        guard handle != nil else { return }

        let data = Data("\(line)\n".utf8)
        if size + data.count > maxBytes {
            do {
                try rotateLocked()
            } catch {
                failLocked("rotate failed: \(error.localizedDescription)")
                return
            }
        }
        // Re-fetch after a possible rotation, which swaps the handle out.
        guard let liveHandle = handle else { return }
        do {
            try liveHandle.write(contentsOf: data)
            size += data.count
        } catch {
            failLocked("write failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Locked internals (caller holds `lock`)

    private func openLocked() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        self.handle = handle
        self.size = (attributes?[.size] as? Int) ?? 0
        // Launch-time trim: a leftover oversize file is rotated once before the first write.
        if self.size > maxBytes {
            try rotateLocked()
        } else {
            try handle.seekToEnd()
        }
    }

    private func rotateLocked() throws {
        try handle?.close()
        handle = nil
        if FileManager.default.fileExists(atPath: archiveURL.path) {
            try FileManager.default.removeItem(at: archiveURL)
        }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.moveItem(at: fileURL, to: archiveURL)
        }
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        handle = try FileHandle(forWritingTo: fileURL)
        size = 0
    }

    private func failLocked(_ message: String) {
        fallbackLogger.error("File log sink disabled: \(message, privacy: .public)")
        try? handle?.close()
        handle = nil
        disabled = true
    }
}
