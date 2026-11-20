import Foundation
import CQuotabarCore

/// Bridge to the quotabar-core Rust Pi session parser (`Rust/quotabar-core/src/pi.rs`,
/// see docs/rust-core.md).
///
/// Two surfaces, same contract as the Claude/Codex/Grok bridges: `parseLine` mirrors
/// `PiUsageScanner.parseLine` for the lenient `Data`-based path; `parseFile` moves the whole
/// `JSONLFileReader` + per-line pass into Rust for production session files so a cold
/// scan never materializes Foundation objects. A nil/`fallback` result means the caller re-runs
/// its own Swift implementation — never a different answer.
enum PiRustParser {
    typealias Entry = PiUsageScanner.Entry

    /// Tri-state mirror of `PiUsageScanner.parseLine`.
    enum LineOutcome {
        /// Pi emits at most one entry per line; the array shape stays consistent with the
        /// other providers' bridges so the decode path can be shared later.
        case entries([Entry])
        case irrelevant
        case malformed
    }

    /// Whole-file outcome for `PiUsageScanner.parseFile(at:)`.
    enum FileOutcome {
        case success([Entry])
        /// Unreadable, cancelled, oversized-line, or a malformed usage record — the Swift
        /// `parseFile(at:)` returns nil for exactly these.
        case failed
        /// A legal line shape the Rust parser declines — run the Swift reference parser.
        case fallback
    }

    static func parseLine(_ data: Data) -> LineOutcome? {
        data.withUnsafeBytes { buffer in
            let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self)
            guard let raw = qb_pi_parse_line(base, buffer.count) else {
                // Null is the library's "fall back to Swift" signal, never an error.
                return nil
            }
            defer { qb_pi_line_result_destroy(raw) }

            guard let entries = decodeEntries(
                count: Int(qb_pi_line_result_entry_count(raw)),
                pointer: qb_pi_line_result_entries(raw),
                strings: { qb_pi_line_result_strings(raw, $0) }
            ) else { return nil }

            if qb_pi_line_result_malformed(raw) != 0 { return .malformed }
            if qb_pi_line_result_irrelevant(raw) != 0 { return .irrelevant }
            return .entries(entries)
        }
    }

    static func parseFile(at url: URL) -> FileOutcome {
        let bytes = Array(url.path.utf8)
        let outcome: FileOutcome = bytes.withUnsafeBufferPointer { buffer in
            let cancel: qb_cancel_callback = { _ in
                Task.isCancelled ? 1 : 0
            }
            guard let raw = qb_pi_parse_file(
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
            defer { qb_pi_file_result_destroy(raw) }

            switch qb_pi_file_result_status(raw) {
            case QB_FILE_OK:
                return decodeEntries(
                    count: Int(qb_pi_file_result_entry_count(raw)),
                    pointer: qb_pi_file_result_entries(raw),
                    strings: { qb_pi_file_result_strings(raw, $0) }
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
        pointer: UnsafePointer<QbPiEntry>?,
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
            let id = string(at: ffi.id_offset, length: ffi.id_length)
            // A nil id is fine (sentinel); a non-sentinel offset that failed the bounds
            // check means the archive/header disagree — fail loudly into fallback.
            if id == nil && ffi.id_offset != QB_NIL_STRING_OFFSET { return nil }
            guard let cardID = string(at: ffi.card_id_offset, length: ffi.card_id_length),
                  let model = string(at: ffi.model_offset, length: ffi.model_length)
            else { return nil }
            entries.append(Entry(
                id: id,
                timestamp: Date(timeIntervalSince1970: ffi.timestamp),
                cardID: cardID,
                model: model,
                carriedCost: ffi.has_carried_cost != 0 ? ffi.carried_cost : nil,
                tokens: TokenBreakdown(
                    input: Int(ffi.input_tokens),
                    cacheWrite5m: Int(ffi.cache_write_5m),
                    cacheWrite1h: Int(ffi.cache_write_1h),
                    cacheRead: Int(ffi.cache_read),
                    output: Int(ffi.output_tokens)
                ),
                reportedTotalTokens: Int(ffi.reported_total_tokens)
            ))
        }
        return entries
    }
}
