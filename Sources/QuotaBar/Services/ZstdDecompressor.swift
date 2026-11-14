import Foundation
import Darwin

/// Streaming decompression of the `.jsonl.zst` archives Codex writes when it compacts finished
/// sessions. QuotaBar ships no zstd of its own — Apple's Compression framework carries no zstd —
/// so this shells out to the `zstd` CLI, which Homebrew is the supported source of. When the
/// binary is absent, absence is a normal condition: callers skip compressed rollouts.
///
/// Decompressed bytes travel raw through a pipe, never through a String, so byte fidelity is
/// exact. A hard byte cap aborts the read when the stream exceeds it — a corrupt or adversarial
/// archive must not grow the process unboundedly.
struct ZstdDecompressor: Sendable {
    /// Where a usable `zstd` may live, in priority order. Both Homebrew prefixes are covered
    /// (Apple silicon and Intel).
    static let defaultSearchPaths = [
        "/opt/homebrew/bin/zstd",
        "/usr/local/bin/zstd",
    ]

    /// Maximum decompressed bytes accepted before the child is terminated and `outputTooLarge`
    /// is thrown. Codex archives are ~1 MB today; 256 MB is far past any legitimate rollout.
    var maximumBytes = 256 * 1024 * 1024
    var timeout: TimeInterval = 60

    let zstdExecutable: String?

    init(searchPaths: [String] = ZstdDecompressor.defaultSearchPaths) {
        zstdExecutable = Self.probe(searchPaths)
    }

    /// The shared process-wide decompressor. Probing happens once, at first use.
    static let shared = ZstdDecompressor()

    private static func probe(_ paths: [String]) -> String? {
        paths.first { path in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  FileManager.default.isExecutableFile(atPath: path)
            else { return false }
            return true
        }
    }

    enum ZstdError: Error, Equatable, LocalizedError {
        case timedOut(path: String)
        case decompressionFailed(path: String, detail: String)
        case outputTooLarge(path: String, limit: Int)

        var errorDescription: String? {
            switch self {
            case .timedOut(let path):
                return "zstd timed out decompressing \(path)"
            case .decompressionFailed(let path, let detail):
                return "zstd could not decompress \(path): \(detail)"
            case .outputTooLarge(let path, let limit):
                return "zstd output for \(path) exceeded \(limit) bytes"
            }
        }
    }

    /// Read at most `maxBytes` of the decompressed stream. Used for marker peeks inside compressed
    /// rollouts: the process is terminated as soon as the cap fills, so this stays cheap even for
    /// multi-hundred-megabyte archives; the prefix (not a partial parse) is all the caller needs.
    /// Returns nil when zstd is missing or the stream fails before the cap fills.
    func decompressPrefix(path: String, maxBytes: Int) -> Data? {
        guard zstdExecutable != nil, maxBytes > 0 else { return nil }
        let prefix = ZstdDecompressor(searchPaths: Self.defaultSearchPaths)
        // The prefix path treats hitting the cap as success: we only wanted the first bytes.
        return try? prefix.decompressPrefixInternal(path: path, maxBytes: maxBytes)
    }

    /// Decompress `path` fully into memory. Returns nil (not an error) when zstd is simply not
    /// installed — compressed rollouts are then skipped, as they were before this support existed.
    func decompress(path: String) throws -> Data? {
        guard let executable = zstdExecutable else { return nil }

        let stdout = Pipe()
        let stderr = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-qdc", "--", path]
        process.standardOutput = stdout
        process.standardError = stderr
        // A minimal, clean environment: zstd honors ZSTD_* variables, and inheriting the host's
        // could silently change the decompressor's behavior.
        process.environment = ["PATH": "/usr/bin:/bin"]

        let collector = ByteCollector(limit: maximumBytes)
        let stderrCollector = ByteCollector(limit: 64 * 1024)
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            collector.drain(stdout.fileHandleForReading)
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            stderrCollector.drain(stderr.fileHandleForReading)
            group.leave()
        }

        do {
            try process.run()
        } catch {
            group.wait()
            throw ZstdError.decompressionFailed(path: path, detail: error.localizedDescription)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if collector.exceeded {
                process.terminate()
                process.waitUntilExit()
                group.wait()
                throw ZstdError.outputTooLarge(path: path, limit: maximumBytes)
            }
            if Task<Never, Never>.isCancelled || Date() > deadline {
                process.terminate()
                process.waitUntilExit()
                group.wait()
                if Task<Never, Never>.isCancelled { throw CancellationError() }
                throw ZstdError.timedOut(path: path)
            }
            usleep(2_000)
        }
        process.waitUntilExit()
        group.wait()
        // The child can also win the race and exit cleanly before the polling loop sees the cap
        // overflow; that is still above the limit.
        if collector.exceeded {
            throw ZstdError.outputTooLarge(path: path, limit: maximumBytes)
        }

        guard process.terminationStatus == 0 else {
            let detail = stderrCollector.text.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ZstdError.decompressionFailed(
                path: path,
                detail: detail.isEmpty ? "zstd exited with status \(process.terminationStatus)" : detail
            )
        }
        return collector.result
    }

    /// Like `decompress`, but stopping at the cap is the *goal*: the child dies on its own once
    /// enough bytes are buffered and the prefix is returned instead of an `outputTooLarge` error.
    fileprivate func decompressPrefixInternal(path: String, maxBytes: Int) throws -> Data? {
        guard let executable = zstdExecutable else { return nil }

        let stdout = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-qdc", "--", path]
        process.standardOutput = stdout
        process.standardError = Pipe()
        process.environment = ["PATH": "/usr/bin:/bin"]

        let collector = ByteCollector(limit: maxBytes)
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            collector.drain(stdout.fileHandleForReading)
            group.leave()
        }
        do {
            try process.run()
        } catch {
            group.wait()
            return nil
        }
        // When the cap fills, ByteCollector stops draining; terminate and return the prefix.
        while process.isRunning {
            if collector.exceeded {
                process.terminate()
                break
            }
            usleep(1_000)
        }
        process.waitUntilExit()
        group.wait()
        let prefix = collector.result
        return prefix.isEmpty ? nil : prefix
    }
}

/// Drains a handle to EOF (or to `limit` bytes) off the caller's thread. `availableData` blocks
/// until at least one byte or EOF, so the loop is quiet when the child is idle mid-frame.
private final class ByteCollector: @unchecked Sendable {
    private let limit: Int
    private let lock = NSLock()
    private var data = Data()
    private(set) var exceeded = false

    init(limit: Int) { self.limit = limit }

    var result: Data { lock.withLock { data } }

    var text: String { String(decoding: result, as: UTF8.self) }

    func drain(_ handle: FileHandle) {
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { return }
            let overflow = lock.withLock { () -> Bool in
                if data.count + chunk.count > limit {
                    // Keep the prefix up to the cap rather than discarding the chunk: callers that
                    // stop at a byte limit still get exactly `limit` bytes back.
                    let room = limit - data.count
                    if room > 0 { data.append(chunk.prefix(room)) }
                    exceeded = true
                    return true
                }
                data.append(chunk)
                return false
            }
            if overflow { return }
        }
    }

}
