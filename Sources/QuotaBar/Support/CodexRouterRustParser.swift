import Foundation
import CQuotabarCore

/// Bridge to the quotabar-core Rust CodexRouter event-line parser
/// (`Rust/quotabar-core/src/codex_router.rs`, see docs/rust-core.md).
///
/// Two surfaces, same contract as the Grok bridge: `parseLine`/`parseLineDetail` mirror the
/// per-line `CodexRouterEventLineParser` verdicts; `parseFile` moves the whole
/// `JSONLFileReader` + per-line pass into Rust for production ledger files. A nil/`fallback`
/// result means the caller re-runs its own Swift implementation — never a different answer,
/// and the two engines never mix within one file.
enum CodexRouterRustParser {
    typealias Event = CodexRouterUsageScanner.Event

    /// Quad-state mirror of `CodexRouterEventLineParser.LineResult`.
    enum LineOutcome {
        case event(Event)
        case malformedEvent(Event)
        case irrelevant
        case malformed
    }

    /// The verdict plus the event the parser produced when there is one: `.irrelevant` can
    /// still carry an event (a valid non-2xx row is skipped but not lost — `parse` returns
    /// it), which `LineResult.irrelevant` itself cannot express.
    struct LineDetail {
        var outcome: LineOutcome
        var event: Event?
    }

    /// Whole-file outcome for the `fullParseAndCheckpoint`-style pass. The `ReadResult`
    /// lets the caller checkpoint the same carry + oversized state the streaming read
    /// would have produced.
    enum FileOutcome {
        case success([Event], JSONLFileReader.ReadResult)
        /// Unreadable, cancelled, oversized-line, or any malformed line — the Swift whole-file
        /// path returns nil for exactly these.
        case failed
        /// A legal line shape the Rust parser declines — run the Swift whole-file parser.
        case fallback
    }

    static func parseLine(_ line: Data.SubSequence) -> LineOutcome? {
        parseLineDetail(line)?.outcome
    }

    static func parseLineDetail(_ line: Data.SubSequence) -> LineDetail? {
        line.withUnsafeBytes { buffer in
            let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self)
            guard let raw = qb_codex_router_parse_line(base, buffer.count) else {
                // Null is the library's "fall back to Swift" signal, never an error.
                return nil
            }
            defer { qb_codex_router_line_result_destroy(raw) }

            guard let events = decodeEvents(
                count: Int(qb_codex_router_line_result_entry_count(raw)),
                pointer: qb_codex_router_line_result_entries(raw),
                strings: { qb_codex_router_line_result_strings(raw, $0) }
            ) else { return nil }

            switch qb_codex_router_line_result_verdict(raw) {
            case QB_ROUTER_LINE_EVENT:
                guard events.count == 1 else { return nil }
                return LineDetail(outcome: .event(events[0]), event: events[0])
            case QB_ROUTER_LINE_MALFORMED_EVENT:
                guard events.count == 1 else { return nil }
                return LineDetail(outcome: .malformedEvent(events[0]), event: events[0])
            case QB_ROUTER_LINE_IRRELEVANT:
                return LineDetail(outcome: .irrelevant, event: events.first)
            case QB_ROUTER_LINE_MALFORMED:
                return LineDetail(outcome: .malformed, event: nil)
            default:
                return nil
            }
        }
    }

    static func parseFile(at url: URL) -> FileOutcome {
        let bytes = Array(url.path.utf8)
        return bytes.withUnsafeBufferPointer { buffer in
            let cancel: qb_cancel_callback = { _ in
                Task.isCancelled ? 1 : 0
            }
            guard let raw = qb_codex_router_parse_file(
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
            defer { qb_codex_router_file_result_destroy(raw) }

            switch qb_codex_router_file_result_status(raw) {
            case QB_FILE_OK:
                guard let events = decodeEvents(
                    count: Int(qb_codex_router_file_result_entry_count(raw)),
                    pointer: qb_codex_router_file_result_entries(raw),
                    strings: { qb_codex_router_file_result_strings(raw, $0) }
                ), let read = decodeReadResult(raw) else { return .fallback }
                return .success(events, read)
            case QB_FILE_FAILED:
                return .failed
            default:
                return .fallback
            }
        }
    }

    /// Decode the FFI event array with bounds-checked string offsets. Any out-of-range or
    /// invalid tag is treated as an archive/header disagreement — the result is nil, so the
    /// caller falls back to Swift rather than trusting a partially decoded payload.
    private static func decodeEvents(
        count: Int,
        pointer: UnsafePointer<QbCodexRouterEvent>?,
        strings: (UnsafeMutablePointer<UInt32>?) -> UnsafePointer<UInt8>?
    ) -> [Event]? {
        guard count > 0 else { return [] }
        guard let pointer else { return nil }
        var stringsLength: UInt32 = 0
        let stringsPointer = strings(&stringsLength)

        /// Required strings (model/provider): nil means the blob is inconsistent → fail.
        func string(at offset: UInt32, length: UInt32) -> String? {
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

        /// Optional strings: the sentinel means absent; a non-sentinel range that fails the
        /// bounds check is a corrupt payload → nil result, not a nil string.
        func optionalString(at offset: UInt32, length: UInt32) -> String?? {
            if offset == QB_NIL_STRING_OFFSET { return .some(nil) }
            guard let value = string(at: offset, length: length) else { return .none }
            return .some(value)
        }

        /// Tri-state optional-Bool tags: 0 nil, 1 false, 2 true — anything else is corrupt.
        func tri(_ tag: UInt8) -> Bool?? {
            switch tag {
            case 0: return .some(nil)
            case 1: return .some(false)
            case 2: return .some(true)
            default: return .none
            }
        }

        var events: [Event] = []
        events.reserveCapacity(count)
        for index in 0..<count {
            let ffi = pointer[index]
            guard let model = string(at: ffi.model_offset, length: ffi.model_length),
                  let provider = string(at: ffi.provider_offset, length: ffi.provider_length),
                  let serviceTier = optionalString(at: ffi.service_tier_offset, length: ffi.service_tier_length),
                  let accountId = optionalString(at: ffi.account_id_offset, length: ffi.account_id_length),
                  let accountFingerprint = optionalString(
                      at: ffi.account_fingerprint_offset, length: ffi.account_fingerprint_length),
                  let hasEstimated = tri(ffi.has_estimated_input_tokens),
                  let validProvider = tri(ffi.has_valid_provider_field),
                  let validTier = tri(ffi.has_valid_service_tier_field),
                  let saturated = tri(ffi.token_count_saturated)
            else { return nil }
            events.append(Event(
                timestamp: Date(timeIntervalSince1970: ffi.timestamp),
                model: model,
                provider: provider,
                status: Int(ffi.status),
                hasValidStatusField: ffi.has_valid_status_field != 0,
                hasValidTimestampField: ffi.has_valid_timestamp_field != 0,
                hasValidModelField: ffi.has_valid_model_field != 0,
                hasUniqueStatusField: ffi.has_unique_status_field != 0,
                hasUniqueProviderField: ffi.has_unique_provider_field != 0,
                hasUniqueModelField: ffi.has_unique_model_field != 0,
                hasUniqueAccountIdentityFields: ffi.has_unique_account_identity_fields != 0,
                hasValidNumericCountFields: ffi.has_valid_numeric_count_fields != 0,
                hasUniqueRecognizedFields: ffi.has_unique_recognized_fields != 0,
                inputTokens: Int(ffi.input_tokens),
                cachedInputTokens: Int(ffi.cached_input_tokens),
                outputTokens: Int(ffi.output_tokens),
                reasoningTokens: Int(ffi.reasoning_tokens),
                totalTokens: ffi.has_total_tokens != 0 ? Int(ffi.total_tokens) : nil,
                hasInputTokensField: ffi.has_input_tokens_field != 0,
                hasOutputTokensField: ffi.has_output_tokens_field != 0,
                hasValidCachedInputTokensField: ffi.has_valid_cached_input_tokens_field != 0,
                hasValidTotalTokensField: ffi.has_valid_total_tokens_field != 0,
                hasValidEstimatedInputTokensField: ffi.has_valid_estimated_input_tokens_field != 0,
                hasEstimatedInputTokens: hasEstimated,
                hasValidAccountIdentityFields: ffi.has_valid_account_identity_fields != 0,
                hasValidProviderField: validProvider,
                hasValidServiceTierField: validTier,
                accountId: accountId,
                accountFingerprint: accountFingerprint,
                serviceTier: serviceTier,
                tokenCountSaturated: saturated
            ))
        }
        return events
    }

    /// Rebuild the `JSONLFileReader.ReadResult` equivalent from a `qb_codex_router_parse_file`
    /// result so `fullParseAndCheckpoint` stores the same carry + oversized metadata the
    /// streaming read would have produced. A `.success` status already guarantees a complete
    /// read, so `succeeded` is always true.
    private static func decodeReadResult(_ raw: UnsafeMutableRawPointer) -> JSONLFileReader.ReadResult? {
        var partialLength: UInt32 = 0
        let partialPointer = qb_codex_router_file_result_partial_line(raw, &partialLength)
        let finalPartial: Data
        if let partialPointer {
            finalPartial = Data(bytes: partialPointer, count: Int(partialLength))
        } else {
            // A nil pointer must mean an empty fragment; a nonzero length is a broken layout.
            guard partialLength == 0 else { return nil }
            finalPartial = Data()
        }
        var statistics = JSONLFileReader.Statistics()
        statistics.bytesRead = Int(qb_codex_router_file_result_bytes_read(raw))
        statistics.oversizedLinesSkipped = Int(qb_codex_router_file_result_oversized_lines(raw))
        return JSONLFileReader.ReadResult(
            succeeded: true,
            statistics: statistics,
            finalPartial: finalPartial,
            isDiscardingOversizedLine: qb_codex_router_file_result_is_discarding_oversized_line(raw) != 0
        )
    }
}
