import Foundation
import CQuotabarCore

/// Bridge to the quotabar-core Rust implementation of the CodexRouter ledger-line parser
/// (`CodexRouterEventLineParser` in Swift; see docs/rust-core.md).
///
/// This is a per-line fast path, not a replacement: when the Rust scanner cannot prove it would
/// reach the same answer — non-ASCII bytes, escaped strings, a timestamp outside the canonical
/// UTC shapes, or any structural failure — it returns NULL and the caller re-runs the Swift
/// parser, which remains the reference implementation and the runtime fallback. Aggregation,
/// classification and every downstream decision stay in Swift; this type only reproduces
/// `CodexRouterEventLineParser.parseResult` one line at a time.
enum CodexRouterLineRustParser {
    typealias LineResult = CodexRouterEventLineParser.LineResult

    /// Same contract as `CodexRouterEventLineParser.parseResult`, with the Rust scanner first.
    ///
    /// Rust-parsed lines do not populate `timestampCache`: the cache exists to avoid repeated
    /// Foundation ISO-8601 parses, and the Rust path parses the canonical shape directly. Output is
    /// identical either way; only the cache's hit statistics differ.
    static func parseResult(
        _ line: Data.SubSequence,
        timestampCache: inout CodexRouterEventLineParser.TimestampCache
    ) -> LineResult {
        if let parsed = parseWithRust(line) { return parsed }
        return CodexRouterEventLineParser.parseResult(line, timestampCache: &timestampCache)
    }

    /// The Rust scanner's own answer, or nil when it delegated to Swift. Exposed so parity tests
    /// can prove which lines the fast path actually covers.
    static func parseWithRust(_ line: Data.SubSequence) -> LineResult? {
        let raw = line.withUnsafeBytes { buffer -> UnsafeMutableRawPointer? in
            qb_router_parse_line(
                buffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                buffer.count
            )
        }
        guard let raw else { return nil }
        defer { qb_router_line_destroy(raw) }

        switch Int32(qb_router_line_kind(raw)) {
        case QB_ROUTER_KIND_IRRELEVANT: return .irrelevant
        case QB_ROUTER_KIND_EVENT, QB_ROUTER_KIND_MALFORMED_EVENT: break
        default:
            AppLog.warn(.refresh, "router line parser returned an unknown result kind")
            return nil
        }
        guard let entry = qb_router_line_entry(raw) else {
            AppLog.warn(.refresh, "router line parser dropped its payload")
            return nil
        }

        var blobLength: UInt32 = 0
        let blob = qb_router_line_strings(raw, &blobLength)
        func string(offset: UInt32, length: UInt32) -> String? {
            guard offset != QB_NIL_STRING_OFFSET else { return nil }
            guard let blob,
                  UInt64(offset) + UInt64(length) <= UInt64(blobLength)
            else { return nil }
            return String(
                decoding: UnsafeBufferPointer(start: blob.advanced(by: Int(offset)), count: Int(length)),
                as: UTF8.self
            )
        }

        guard let model = string(offset: entry.pointee.model_offset, length: entry.pointee.model_length),
              let provider = string(offset: entry.pointee.provider_offset, length: entry.pointee.provider_length)
        else {
            AppLog.warn(.refresh, "router line parser returned an out-of-bounds string")
            return nil
        }

        let totalTokens = entry.pointee.total_tokens == Int64.min ? nil : Int(entry.pointee.total_tokens)
        let event = CodexRouterUsageScanner.Event(
            timestamp: Date(timeIntervalSince1970: entry.pointee.timestamp),
            model: model,
            provider: provider,
            status: Int(entry.pointee.status),
            hasValidStatusField: entry.pointee.has_valid_status_field != 0,
            hasValidTimestampField: entry.pointee.has_valid_timestamp_field != 0,
            hasValidModelField: entry.pointee.has_valid_model_field != 0,
            hasUniqueStatusField: entry.pointee.has_unique_status_field != 0,
            hasUniqueProviderField: entry.pointee.has_unique_provider_field != 0,
            hasUniqueModelField: entry.pointee.has_unique_model_field != 0,
            hasUniqueAccountIdentityFields: entry.pointee.has_unique_account_identity_fields != 0,
            hasValidNumericCountFields: entry.pointee.has_valid_numeric_count_fields != 0,
            hasUniqueRecognizedFields: entry.pointee.has_unique_recognized_fields != 0,
            inputTokens: Int(entry.pointee.input_tokens),
            cachedInputTokens: Int(entry.pointee.cached_input_tokens),
            outputTokens: Int(entry.pointee.output_tokens),
            reasoningTokens: Int(entry.pointee.reasoning_tokens),
            totalTokens: totalTokens,
            hasInputTokensField: entry.pointee.has_input_tokens_field != 0,
            hasOutputTokensField: entry.pointee.has_output_tokens_field != 0,
            hasValidCachedInputTokensField: entry.pointee.has_valid_cached_input_tokens_field != 0,
            hasValidTotalTokensField: entry.pointee.has_valid_total_tokens_field != 0,
            hasValidEstimatedInputTokensField: entry.pointee.has_valid_estimated_input_tokens_field != 0,
            hasEstimatedInputTokens: entry.pointee.has_estimated_input_tokens != 0,
            hasValidAccountIdentityFields: entry.pointee.has_valid_account_identity_fields != 0,
            hasValidProviderField: entry.pointee.has_valid_provider_field != 0,
            hasValidServiceTierField: entry.pointee.has_valid_service_tier_field != 0,
            accountId: string(offset: entry.pointee.account_id_offset,
                              length: entry.pointee.account_id_length),
            accountFingerprint: string(offset: entry.pointee.account_fingerprint_offset,
                                       length: entry.pointee.account_fingerprint_length),
            serviceTier: string(offset: entry.pointee.service_tier_offset,
                                length: entry.pointee.service_tier_length),
            tokenCountSaturated: entry.pointee.token_count_saturated != 0 ? true : nil
        )
        return Int32(qb_router_line_kind(raw)) == QB_ROUTER_KIND_EVENT
            ? .event(event)
            : .malformedEvent(event)
    }
}
