import Foundation
import CQuotabarCore

/// Bridge to the quotabar-core Rust Muse session parser (`Rust/quotabar-core/src/muse.rs`,
/// see docs/rust-core.md).
///
/// Two surfaces, same contract as the Claude/Codex/Grok bridges: `parseLine` mirrors
/// `MuseUsageScanner.parseLineResult` for the lenient `Data`-based path; `parseFile` moves the
/// whole `JSONLFileReader` + per-line pass into Rust for production `session.jsonl` files so a
/// cold scan never materializes Foundation objects. A nil/`fallback` result means the caller
/// re-runs its own Swift implementation — never a different answer.
enum MuseRustParser {
    typealias Entry = MuseUsageScanner.Entry

    /// Tri-state mirror of `MuseUsageScanner.parseLineResult`.
    enum LineOutcome {
        case entry(Entry)
        case irrelevant
        case malformed
    }

    /// Whole-file outcome for `MuseUsageScanner.parseFile(at:)`.
    enum FileOutcome {
        case success([Entry])
        /// Unreadable, cancelled, oversized-line, or a malformed attribution record — the Swift
        /// `parseFile(at:)` returns nil for exactly these.
        case failed
        /// A legal line shape the Rust parser declines — run the Swift reference parser.
        case fallback
    }

    static func parseLine(_ data: Data) -> LineOutcome? {
        data.withUnsafeBytes { buffer in
            let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self)
            guard let raw = qb_muse_parse_line(base, buffer.count) else {
                // Null is the library's "fall back to Swift" signal, never an error.
                return nil
            }
            defer { qb_muse_line_result_destroy(raw) }

            guard let entries = decodeEntries(
                count: Int(qb_muse_line_result_entry_count(raw)),
                pointer: qb_muse_line_result_entries(raw),
                strings: { qb_muse_line_result_strings(raw, $0) }
            ) else { return nil }

            if qb_muse_line_result_malformed(raw) != 0 { return .malformed }
            if qb_muse_line_result_irrelevant(raw) != 0 { return .irrelevant }
            // One attribution line yields exactly one entry; any other count means the archive
            // and header disagree — decline into fallback rather than answer differently.
            guard entries.count == 1, let entry = entries.first else { return nil }
            return .entry(entry)
        }
    }

    static func parseFile(at url: URL) -> FileOutcome {
        let bytes = Array(url.path.utf8)
        let outcome: FileOutcome = bytes.withUnsafeBufferPointer { buffer in
            let cancel: qb_cancel_callback = { _ in
                Task.isCancelled ? 1 : 0
            }
            guard let raw = qb_muse_parse_file(
                buffer.baseAddress,
                buffer.count,
                0,
                UInt64.max,
                cancel,
                nil
            ) else {
                // Null is the library's "fall back to Swift" signal, never an error.
                return .fallback
            }
            defer { qb_muse_file_result_destroy(raw) }

            switch qb_muse_file_result_status(raw) {
            case QB_FILE_OK:
                return decodeEntries(
                    count: Int(qb_muse_file_result_entry_count(raw)),
                    pointer: qb_muse_file_result_entries(raw),
                    strings: { qb_muse_file_result_strings(raw, $0) }
                ).map(FileOutcome.success) ?? .fallback
            case QB_FILE_FAILED:
                return .failed
            default:
                return .fallback
            }
        }
        return outcome
    }

    private static func decodeEntries(
        count: Int,
        pointer: UnsafePointer<QbMuseEntry>?,
        strings: (UnsafeMutablePointer<UInt32>?) -> UnsafePointer<UInt8>?
    ) -> [Entry]? {
        guard count > 0 else { return [] }
        guard let pointer else { return nil }
        var stringsLength: UInt32 = 0
        let stringsPointer = strings(&stringsLength)

        func string(at offset: UInt32, length: UInt32) -> String? {
            guard offset != QB_NIL_STRING_OFFSET else { return nil }
            guard let stringsPointer,
                  UInt64(offset) + UInt64(length) <= UInt64(stringsLength)
            else { return nil }
            return String(
                decoding: UnsafeBufferPointer(
                    start: stringsPointer.advanced(by: Int(offset)),
                    count: Int(length)
                ),
                as: UTF8.self
            )
        }

        var entries: [Entry] = []
        entries.reserveCapacity(count)
        for index in 0..<count {
            let ffi = pointer[index]
            // `model` is never nil in this format; a failed bounds check means the archive and
            // header disagree — fail loudly into fallback.
            guard let model = string(at: ffi.model_offset, length: ffi.model_length) else {
                return nil
            }
            entries.append(Entry(
                timestamp: Date(timeIntervalSince1970: ffi.timestamp),
                tokens: TokenBreakdown(
                    input: Int(ffi.input_tokens),
                    cacheWrite5m: 0,
                    cacheRead: Int(ffi.cache_read),
                    output: Int(ffi.output_tokens)
                ),
                model: model
            ))
        }
        return entries
    }
}
