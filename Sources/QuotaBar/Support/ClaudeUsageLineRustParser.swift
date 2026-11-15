import Foundation
import CQuotabarCore

/// Bridge to the quotabar-core Rust implementation of the Claude usage-line parser
/// (`Rust/quotabar-core`, see docs/rust-core.md).
///
/// The Rust parser is a faithful port of the reference Swift implementation in
/// `ClaudeLogUsageScanner`. It declines (returns nil) for the shapes it does not handle — a
/// timestamp string outside the canonical UTC shapes, a line with more entries than fit the
/// fixed per-line array, or any internal failure — and the caller falls back to the Swift path,
/// so results are never silently degraded.
enum ClaudeUsageLineRustParser {
    struct Parse {
        var entries: [ClaudeLogUsageScanner.Entry]
        var malformed: Bool
    }

    static func parse(_ data: Data) -> Parse? {
        data.withUnsafeBytes { buffer in
            let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self)
            guard let raw = qb_claude_parse_usage_line(base, buffer.count) else {
                // Null is the library's "fall back to Swift" signal, never an error.
                return nil
            }
            defer { qb_claude_result_destroy(raw) }

            let malformed = qb_claude_result_malformed(raw) != 0
            let entryCount = Int(qb_claude_result_entry_count(raw))
            guard entryCount > 0 else {
                return Parse(entries: [], malformed: malformed)
            }
            guard let entriesPointer = qb_claude_result_entries(raw) else { return nil }

            var stringsPointer: UnsafePointer<UInt8>?
            var stringsLength: UInt32 = 0
            if entryCount > 0 {
                stringsLength = 0
                stringsPointer = qb_claude_result_strings(raw, &stringsLength)
            }

            var entries: [ClaudeLogUsageScanner.Entry] = []
            entries.reserveCapacity(entryCount)
            for index in 0..<entryCount {
                let ffi = entriesPointer[index]
                let messageID = string(at: ffi.message_id_offset, length: ffi.message_id_length,
                                       base: stringsPointer, blobLength: stringsLength)
                let requestID = string(at: ffi.request_id_offset, length: ffi.request_id_length,
                                       base: stringsPointer, blobLength: stringsLength)
                let model = string(at: ffi.model_offset, length: ffi.model_length,
                                   base: stringsPointer, blobLength: stringsLength)
                // Offsets must either be the nil sentinel or land inside the blob; anything
                // else means the archive and header disagree, so fail loudly into fallback.
                if messageID == nil && ffi.message_id_offset != QB_NIL_STRING_OFFSET { return nil }
                if requestID == nil && ffi.request_id_offset != QB_NIL_STRING_OFFSET { return nil }
                if model == nil && ffi.model_offset != QB_NIL_STRING_OFFSET { return nil }

                entries.append(ClaudeLogUsageScanner.Entry(
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
            return Parse(entries: entries, malformed: malformed)
        }
    }

    /// Copy one string out of the result blob. Returns nil when the range is outside the blob.
    private static func string(
        at offset: UInt32,
        length: UInt32,
        base: UnsafePointer<UInt8>?,
        blobLength: UInt32
    ) -> String? {
        guard offset != QB_NIL_STRING_OFFSET else { return nil }
        guard let base else { return nil }
        let end = UInt64(offset) + UInt64(length)
        guard end <= UInt64(blobLength) else { return nil }
        return String(
            decoding: UnsafeBufferPointer(
                start: base.advanced(by: Int(offset)),
                count: Int(length)
            ),
            as: UTF8.self
        )
    }
}
