import Foundation
import CQuotabarCore

/// Bridge to the quotabar-core Rust Grok session parser (`Rust/quotabar-core/src/grok.rs`,
/// see docs/rust-core.md).
///
/// Two surfaces, same contract as the Claude/Codex bridges: `parseLine` mirrors
/// `ClaudeUsageLineRustParser` for the lenient `Data`-based path; `parseFile` moves the whole
/// `JSONLFileReader` + per-line pass into Rust for production `updates.jsonl` files so a cold
/// scan never materializes Foundation objects. A nil/`fallback` result means the caller re-runs
/// its own Swift implementation — never a different answer.
enum GrokRustParser {
    typealias Entry = GrokLogUsageScanner.Entry

    /// Tri-state mirror of `GrokLogUsageScanner.parseLine`.
    enum LineOutcome {
        case entries([Entry])
        case irrelevant
        case malformed
    }

    /// Whole-file outcome for `GrokLogUsageScanner.parseFile(at:)`.
    enum FileOutcome {
        case success([Entry])
        /// Unreadable, cancelled, oversized-line, or a malformed completed turn — the Swift
        /// `parseFile(at:)` returns nil for exactly these.
        case failed
        /// A legal line shape the Rust parser declines — run the Swift reference parser.
        case fallback
    }

    static func parseLine(_ data: Data) -> LineOutcome? {
        data.withUnsafeBytes { buffer in
            let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self)
            guard let raw = qb_grok_parse_line(base, buffer.count) else {
                // Null is the library's "fall back to Swift" signal, never an error.
                return nil
            }
            defer { qb_grok_line_result_destroy(raw) }

            guard let entries = decodeEntries(
                count: Int(qb_grok_line_result_entry_count(raw)),
                pointer: qb_grok_line_result_entries(raw),
                strings: { qb_grok_line_result_strings(raw, $0) }
            ) else { return nil }

            if qb_grok_line_result_malformed(raw) != 0 { return .malformed }
            if qb_grok_line_result_irrelevant(raw) != 0 { return .irrelevant }
            return .entries(entries)
        }
    }

    static func parseFile(at url: URL) -> FileOutcome {
        let bytes = Array(url.path.utf8)
        let outcome: FileOutcome = bytes.withUnsafeBufferPointer { buffer in
            let cancel: qb_cancel_callback = { _ in
                Task.isCancelled ? 1 : 0
            }
            guard let raw = qb_grok_parse_file(
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
            defer { qb_grok_file_result_destroy(raw) }

            switch qb_grok_file_result_status(raw) {
            case QB_FILE_OK:
                return decodeEntries(
                    count: Int(qb_grok_file_result_entry_count(raw)),
                    pointer: qb_grok_file_result_entries(raw),
                    strings: { qb_grok_file_result_strings(raw, $0) }
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
        pointer: UnsafePointer<QbGrokEntry>?,
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
            let eventID = string(at: ffi.event_id_offset, length: ffi.event_id_length)
            // A nil eventID is fine (sentinel); a non-sentinel offset that failed the bounds
            // check means the archive/header disagree — fail loudly into fallback.
            if eventID == nil && ffi.event_id_offset != QB_NIL_STRING_OFFSET { return nil }
            guard let model = string(at: ffi.model_offset, length: ffi.model_length) else {
                return nil
            }
            entries.append(Entry(
                eventID: eventID,
                timestamp: Date(timeIntervalSince1970: ffi.timestamp),
                model: model,
                tokens: TokenBreakdown(
                    input: Int(ffi.input_tokens),
                    cacheWrite5m: Int(ffi.cache_write_5m),
                    cacheRead: Int(ffi.cache_read),
                    output: Int(ffi.output_tokens)
                ),
                carriedCost: ffi.has_carried_cost != 0 ? ffi.carried_cost : nil
            ))
        }
        return entries
    }
}
