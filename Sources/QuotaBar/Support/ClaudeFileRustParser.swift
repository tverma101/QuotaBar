import Foundation
import CQuotabarCore

/// Bridge to the quotabar-core Rust whole-file Claude session parser (`qb_claude_parse_file` in
/// `Rust/quotabar-core/src/lib.rs`, see docs/rust-core.md).
///
/// `parseFile` moves the `JSONLFileReader` + per-line pass into Rust for production session
/// `.jsonl` files so a cold scan never materializes Foundation objects. The tri-state contract
/// matches `GrokRustParser.FileOutcome`: `fallback` (or a nil result, which reads as fallback)
/// means the caller re-runs its own Swift implementation — never a different answer.
enum ClaudeFileRustParser {
    typealias Entry = ClaudeLogUsageScanner.Entry

    /// Whole-file outcome for `ClaudeLogUsageScanner.parseFile(at:)`.
    enum FileOutcome {
        /// Parsed end to end; `malformed` is the file-level OR of each line's
        /// `malformedTokenCounts` (always false today — a malformed file reports `.failed`
        /// instead — but propagated so the caller applies the same nil rule the Swift path does).
        case success([Entry], malformed: Bool)
        /// Unreadable, cancelled, oversized-line, or a malformed usage row — the Swift
        /// `parseFile(at:)` returns nil for exactly these.
        case failed
        /// A legal line shape the Rust parser declines — run the Swift reference parser.
        case fallback
    }

    static func parseFile(at url: URL) -> FileOutcome {
        let bytes = Array(url.path.utf8)
        let outcome: FileOutcome = bytes.withUnsafeBufferPointer { buffer in
            let cancel: qb_cancel_callback = { _ in
                Task.isCancelled ? 1 : 0
            }
            guard let raw = qb_claude_parse_file(
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
            defer { qb_claude_file_result_destroy(raw) }

            switch qb_claude_file_result_status(raw) {
            case QB_FILE_OK:
                return decodeEntries(
                    count: Int(qb_claude_file_result_entry_count(raw)),
                    pointer: qb_claude_file_result_entries(raw),
                    strings: { qb_claude_file_result_strings(raw, $0) }
                ).map { FileOutcome.success($0, malformed: qb_claude_file_result_malformed(raw) != 0) }
                    ?? .fallback
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
        pointer: UnsafePointer<QbClaudeUsageEntry>?,
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
            let messageID = string(at: ffi.message_id_offset, length: ffi.message_id_length)
            let requestID = string(at: ffi.request_id_offset, length: ffi.request_id_length)
            let model = string(at: ffi.model_offset, length: ffi.model_length)
            // Offsets must either be the nil sentinel or land inside the blob; anything else
            // means the archive and header disagree — fail loudly into fallback.
            if messageID == nil && ffi.message_id_offset != QB_NIL_STRING_OFFSET { return nil }
            if requestID == nil && ffi.request_id_offset != QB_NIL_STRING_OFFSET { return nil }
            if model == nil && ffi.model_offset != QB_NIL_STRING_OFFSET { return nil }
            entries.append(Entry(
                timestamp: Date(timeIntervalSince1970: ffi.timestamp),
                tokens: TokenBreakdown(
                    input: Int(ffi.input_tokens),
                    cacheWrite5m: Int(ffi.cache_write_5m),
                    cacheWrite1h: Int(ffi.cache_write_1h),
                    cacheRead: Int(ffi.cache_read),
                    output: Int(ffi.output_tokens),
                    isFast: ffi.is_fast != 0
                ),
                messageID: messageID,
                requestID: requestID,
                isSidechain: ffi.is_sidechain != 0,
                hasSpeed: ffi.has_speed != 0,
                costUSD: ffi.has_cost_usd != 0 ? ffi.cost_usd : nil,
                model: model
            ))
        }
        return entries
    }
}
