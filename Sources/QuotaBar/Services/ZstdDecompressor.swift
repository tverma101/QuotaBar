import CQuotabarCore
import Foundation

/// Decodes Codex session archives using the shared Rust reader. Limits and cancellation apply to
/// each decoded chunk before it can grow the output buffer.
struct ZstdDecompressor: Sendable {
    static let shared = ZstdDecompressor()
    var maximumBytes = 256 * 1024 * 1024
    var timeout: TimeInterval = 60

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

    func decompressPrefix(path: String, maxBytes: Int) -> Data? {
        guard maxBytes > 0 else { return nil }
        return try? read(path: path, limit: maxBytes, prefixOnly: true)
    }

    func decompress(path: String) throws -> Data {
        try read(path: path, limit: maximumBytes, prefixOnly: false)
    }

    private func read(path: String, limit: Int, prefixOnly: Bool) throws -> Data {
        try Task.checkCancellation()
        let deadline = ContinuousClock.now + .seconds(timeout)
        var state = Output(limit: limit, prefixOnly: prefixOnly, deadline: deadline)
        let error = withUnsafeMutablePointer(to: &state) { output in
            path.withCString { path in
                qb_zstd_read(path, output) { context, bytes, size in
                    guard let context, let bytes else { return 0 }
                    let output = context.assumingMemoryBound(to: Output.self)
                    return output.pointee.append(bytes, count: size) ? 1 : 0
                }
            }
        }
        defer { qb_engine_string_free(error) }
        try Task.checkCancellation()
        if ContinuousClock.now >= deadline { throw ZstdError.timedOut(path: path) }
        if let error {
            throw ZstdError.decompressionFailed(path: path, detail: String(cString: error))
        }
        if state.exceeded { throw ZstdError.outputTooLarge(path: path, limit: limit) }
        return state.data
    }

    private struct Output {
        let limit: Int
        let prefixOnly: Bool
        let deadline: ContinuousClock.Instant
        var data = Data()
        var exceeded = false

        mutating func append(_ bytes: UnsafePointer<UInt8>, count: Int) -> Bool {
            guard !Task.isCancelled, ContinuousClock.now < deadline else { return false }
            let remaining = max(0, limit - data.count)
            if count > remaining, !prefixOnly {
                exceeded = true
                return false
            }
            data.append(bytes, count: min(count, remaining))
            return !prefixOnly || data.count < limit
        }
    }
}
