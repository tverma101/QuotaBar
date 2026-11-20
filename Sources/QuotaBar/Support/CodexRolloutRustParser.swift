import Foundation
import CQuotabarCore

/// Bridge to the quotabar-core Rust implementation of the Codex rollout line parser
/// (`CodexLogUsageScanner.FileParser` in Swift, ported in stage 2; see docs/rust-core.md).
///
/// Unlike the stateless Claude bridge, this parser is stateful across the lines of one file
/// (running model, fast-tier flags, child-session replay gate). `consume(_:)` returns `false`
/// when the line carries a timestamp this library cannot emulate — Foundation could — and the
/// caller must abandon this parser and re-parse the whole file with the Swift implementation;
/// the two engines never produce a mixed result.
enum CodexRolloutRustParser {
    typealias Event = CodexLogUsageScanner.Event

    enum ReplayGateKind: UInt8 {
        case none = 0
        case untilStartedAt = 1
        case untilSelfTimed = 2
    }

    struct Checkpoint: Equatable {
        var hasPreviousTotals = false
        var previousInput: Int64 = 0
        var previousCached: Int64 = 0
        var previousOutput: Int64 = 0
        var previousReasoning: Int64 = 0
        var previousTotal: Int64 = 0
        var previousHasReportedTotal = false
        var previousIsValid = false
        var previousHasCompleteCostBreakdown = false
        var sawSessionMeta = false
        var currentTierIsFast = false
        var currentServiceTierIsValid = false
        var replayGateKind: ReplayGateKind = .none
        var replayGateStartedAt: Double = 0
        var currentModel: String?
        var serviceTier: String?
    }

    /// Whole-file outcome for `CodexLogUsageScanner.fullParseAndCheckpoint` (`qb_codex_parse_file`).
    enum FileOutcome {
        /// Parsed end to end; `read` is the `JSONLFileReader.ReadResult` equivalent the Rust
        /// scan produced so `finishFullParse` checkpoints it unchanged.
        case success(events: [Event], checkpoint: Checkpoint, read: JSONLFileReader.ReadResult)
        /// Unreadable, cancelled, oversized-line, or malformed usage (`malformed` records which
        /// one for diagnostics — `hasMalformedUsage`); the Swift path returns nil for all of them.
        case failed(malformed: Bool)
        /// A legal line shape the Rust parser declines — run the Swift reference parser.
        case fallback
    }

    /// Parse one rollout file end to end, mirroring `attemptRustFullParse`'s read + feed + status
    /// order. `.jsonl.zst` archives are compressed — raw bytes are not JSONL — so they go through
    /// the decompressor path in Swift instead of ever reaching this API.
    static func parseFile(at url: URL, emitSince: Date?) -> FileOutcome {
        if url.pathExtension == "zst" || url.lastPathComponent.hasSuffix(".jsonl.zst") {
            return .fallback
        }
        let bytes = Array(url.path.utf8)
        let outcome: FileOutcome = bytes.withUnsafeBufferPointer { buffer in
            let cancel: qb_cancel_callback = { _ in
                Task.isCancelled ? 1 : 0
            }
            guard let raw = qb_codex_parse_file(
                buffer.baseAddress,
                buffer.count,
                emitSince != nil ? 1 : 0,
                emitSince?.timeIntervalSince1970 ?? 0,
                0,
                UInt64.max,
                cancel,
                nil
            ) else {
                // Null is the library's "fall back to Swift" signal, never an error.
                return .fallback
            }
            defer { qb_codex_file_result_destroy(raw) }

            switch qb_codex_file_result_status(raw) {
            case QB_FILE_OK:
                guard let events = decodeEvents(
                    count: Int(qb_codex_file_result_event_count(raw)),
                    pointer: qb_codex_file_result_events(raw),
                    stringsPointer: { qb_codex_file_result_strings(raw, $0) }
                ), let checkpoint = decodeCheckpoint(raw),
                   let read = decodeReadResult(raw)
                else { return .fallback }
                return .success(events: events, checkpoint: checkpoint, read: read)
            case QB_FILE_FAILED:
                return .failed(malformed: qb_codex_file_result_has_malformed_usage(raw) != 0)
            default:
                return .fallback
            }
        }
        return outcome
    }

    final class Handle {
        private let parser: UnsafeMutableRawPointer

        init?(emitSince: Date?) {
            let ptr = qb_codex_parser_create(
                emitSince != nil ? 1 : 0,
                emitSince?.timeIntervalSince1970 ?? 0
            )
            guard let ptr else { return nil }
            self.parser = ptr
        }

        deinit {
            qb_codex_parser_destroy(parser)
        }

        /// Consume one line. Returns false when the whole file must be re-parsed by Swift.
        func consume(_ line: Data.SubSequence) -> Bool {
            line.withUnsafeBytes { buffer in
                let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self)
                return qb_codex_parser_feed_line(parser, base, buffer.count) == QB_CODEX_FEED_OK
            }
        }

        /// Snapshot the parser's state for the in-memory append cache. Returns nil when the
        /// result fails its bounds checks; the caller then re-parses the file with Swift.
        func checkpoint() -> Checkpoint? {
            guard let raw = qb_codex_parser_checkpoint(parser) else { return nil }
            defer { qb_codex_checkpoint_destroy(raw) }

            func optionalString(offset: UInt32, length: UInt32) -> String? {
                guard offset != QB_NIL_STRING_OFFSET else { return nil as String? }
                var lengthOut: UInt32 = 0
                guard let blob = qb_codex_checkpoint_strings(raw, &lengthOut) else { return nil }
                guard UInt64(offset) + UInt64(length) <= UInt64(lengthOut) else { return nil }
                return String(
                    decoding: UnsafeBufferPointer(
                        start: blob.advanced(by: Int(offset)),
                        count: Int(length)
                    ),
                    as: UTF8.self
                )
            }

            var state = Checkpoint()
            state.hasPreviousTotals = qb_codex_checkpoint_has_previous_totals(raw) != 0
            state.previousInput = qb_codex_checkpoint_previous_input(raw)
            state.previousCached = qb_codex_checkpoint_previous_cached(raw)
            state.previousOutput = qb_codex_checkpoint_previous_output(raw)
            state.previousReasoning = qb_codex_checkpoint_previous_reasoning(raw)
            state.previousTotal = qb_codex_checkpoint_previous_total(raw)
            state.previousHasReportedTotal = qb_codex_checkpoint_previous_has_reported_total(raw) != 0
            state.previousIsValid = qb_codex_checkpoint_previous_is_valid(raw) != 0
            state.previousHasCompleteCostBreakdown = qb_codex_checkpoint_previous_has_complete_cost_breakdown(raw) != 0
            state.sawSessionMeta = qb_codex_checkpoint_saw_session_meta(raw) != 0
            state.currentTierIsFast = qb_codex_checkpoint_current_tier_is_fast(raw) != 0
            state.currentServiceTierIsValid = qb_codex_checkpoint_current_service_tier_is_valid(raw) != 0
            state.replayGateKind = ReplayGateKind(rawValue: qb_codex_checkpoint_replay_gate_kind(raw)) ?? .none
            state.replayGateStartedAt = qb_codex_checkpoint_replay_gate_started_at(raw)
            // A nil field with a non-nil sentinel is fine; nil-with-nil-sentinel means absent.
            let currentModelOffset = qb_codex_checkpoint_current_model_offset(raw)
            let currentModelLength = qb_codex_checkpoint_current_model_length(raw)
            if currentModelOffset == QB_NIL_STRING_OFFSET {
                state.currentModel = nil
            } else {
                guard let value = optionalString(offset: currentModelOffset, length: currentModelLength) else { return nil }
                state.currentModel = value
            }
            let serviceTierOffset = qb_codex_checkpoint_service_tier_offset(raw)
            let serviceTierLength = qb_codex_checkpoint_service_tier_length(raw)
            if serviceTierOffset == QB_NIL_STRING_OFFSET {
                state.serviceTier = nil
            } else {
                guard let value = optionalString(offset: serviceTierOffset, length: serviceTierLength) else { return nil }
                state.serviceTier = value
            }
            return state
        }

        var hasMalformedUsage: Bool {
            qb_codex_parser_malformed(parser) != 0
        }

        /// Move out the events emitted so far. Valid to call once, after the last line.
        /// Returns nil when the result fails its bounds checks — the caller then re-parses the
        /// file with the Swift implementation. Silently returning an empty array would attribute
        /// zero usage to the file, so a broken result is always an explicit nil.
        func finish() -> [Event]? {
            guard let raw = qb_codex_parser_take_events(parser) else { return nil }
            defer { qb_codex_take_events_destroy(raw) }
            return CodexRolloutRustParser.decodeEvents(
                count: Int(qb_codex_take_events_count(raw)),
                pointer: qb_codex_take_events_entries(raw),
                stringsPointer: { qb_codex_take_events_strings(raw, $0) }
            )
        }
    }

    /// Decode the event array shared by `qb_codex_take_events_*` and `qb_codex_file_result_*`
    /// results. Returns nil on a broken layout — never an empty array — so a corrupt result can
    /// never masquerade as a file that simply emitted no usage.
    private static func decodeEvents(
        count: Int,
        pointer: UnsafePointer<QbCodexEvent>?,
        stringsPointer: (UnsafeMutablePointer<UInt32>?) -> UnsafePointer<UInt8>?
    ) -> [Event]? {
        guard count > 0 else { return [] }
        guard let entries = pointer else { return nil }
        var stringsLength: UInt32 = 0
        let stringsBlob = stringsPointer(&stringsLength)

        func string(at offset: UInt32, length: UInt32) -> String? {
            guard offset != QB_NIL_STRING_OFFSET else { return nil }
            guard let stringsBlob else { return nil }
            guard UInt64(offset) + UInt64(length) <= UInt64(stringsLength) else { return nil }
            return String(
                decoding: UnsafeBufferPointer(
                    start: stringsBlob.advanced(by: Int(offset)),
                    count: Int(length)
                ),
                as: UTF8.self
            )
        }

        var events: [Event] = []
        events.reserveCapacity(count)
        for index in 0..<count {
            let ffi = entries[index]
            // `model` is never absent in this FFI contract; treat an out-of-range blob
            // range as a broken archive/header pairing and fail loudly.
            guard let model = string(at: ffi.model_offset, length: ffi.model_length) else {
                return nil
            }
            events.append(Event(
                timestamp: Date(timeIntervalSince1970: ffi.timestamp),
                model: model,
                pricingModel: string(at: ffi.pricing_model_offset, length: ffi.pricing_model_length),
                input: Int(ffi.input_tokens),
                cached: Int(ffi.cached_tokens),
                output: Int(ffi.output_tokens),
                reasoning: Int(ffi.reasoning_tokens),
                total: Int(ffi.total_tokens),
                hasCompleteCostBreakdown: ffi.has_complete_cost_breakdown != 0,
                isFast: ffi.is_fast != 0,
                serviceTier: string(at: ffi.service_tier_offset, length: ffi.service_tier_length)
            ))
        }
        return events
    }

    /// Decode the checkpoint projection inside a `qb_codex_parse_file` result — the same fields
    /// `Handle.checkpoint()` reads from `qb_codex_parser_checkpoint`. Nil on a broken layout.
    private static func decodeCheckpoint(_ raw: UnsafeMutableRawPointer) -> Checkpoint? {
        var stringsLength: UInt32 = 0
        let stringsBlob = qb_codex_file_result_strings(raw, &stringsLength)

        func optionalString(offset: UInt32, length: UInt32) -> String? {
            guard let stringsBlob else { return nil }
            guard UInt64(offset) + UInt64(length) <= UInt64(stringsLength) else { return nil }
            return String(
                decoding: UnsafeBufferPointer(
                    start: stringsBlob.advanced(by: Int(offset)),
                    count: Int(length)
                ),
                as: UTF8.self
            )
        }

        var state = Checkpoint()
        state.hasPreviousTotals = qb_codex_file_result_has_previous_totals(raw) != 0
        state.previousInput = qb_codex_file_result_previous_input(raw)
        state.previousCached = qb_codex_file_result_previous_cached(raw)
        state.previousOutput = qb_codex_file_result_previous_output(raw)
        state.previousReasoning = qb_codex_file_result_previous_reasoning(raw)
        state.previousTotal = qb_codex_file_result_previous_total(raw)
        state.previousHasReportedTotal = qb_codex_file_result_previous_has_reported_total(raw) != 0
        state.previousIsValid = qb_codex_file_result_previous_is_valid(raw) != 0
        state.previousHasCompleteCostBreakdown = qb_codex_file_result_previous_has_complete_cost_breakdown(raw) != 0
        state.sawSessionMeta = qb_codex_file_result_saw_session_meta(raw) != 0
        state.currentTierIsFast = qb_codex_file_result_current_tier_is_fast(raw) != 0
        state.currentServiceTierIsValid = qb_codex_file_result_current_service_tier_is_valid(raw) != 0
        state.replayGateKind = ReplayGateKind(rawValue: qb_codex_file_result_replay_gate_kind(raw)) ?? .none
        state.replayGateStartedAt = qb_codex_file_result_replay_gate_started_at(raw)
        // A nil field with a non-nil sentinel is fine; nil-with-nil-sentinel means absent.
        let currentModelOffset = qb_codex_file_result_current_model_offset(raw)
        let currentModelLength = qb_codex_file_result_current_model_length(raw)
        if currentModelOffset == QB_NIL_STRING_OFFSET {
            state.currentModel = nil
        } else {
            guard let value = optionalString(offset: currentModelOffset, length: currentModelLength) else { return nil }
            state.currentModel = value
        }
        let serviceTierOffset = qb_codex_file_result_service_tier_offset(raw)
        let serviceTierLength = qb_codex_file_result_service_tier_length(raw)
        if serviceTierOffset == QB_NIL_STRING_OFFSET {
            state.serviceTier = nil
        } else {
            guard let value = optionalString(offset: serviceTierOffset, length: serviceTierLength) else { return nil }
            state.serviceTier = value
        }
        return state
    }

    /// Rebuild the `JSONLFileReader.ReadResult` equivalent from a `qb_codex_parse_file` result so
    /// `finishFullParse` checkpoints the same metadata the streaming read would have produced.
    /// A `.success` status already guarantees a complete read, so `succeeded` is always true.
    private static func decodeReadResult(_ raw: UnsafeMutableRawPointer) -> JSONLFileReader.ReadResult? {
        var partialLength: UInt32 = 0
        let partialPointer = qb_codex_file_result_partial_line(raw, &partialLength)
        let finalPartial: Data
        if let partialPointer {
            finalPartial = Data(bytes: partialPointer, count: Int(partialLength))
        } else {
            // A nil pointer must mean an empty fragment; a nonzero length is a broken layout.
            guard partialLength == 0 else { return nil }
            finalPartial = Data()
        }
        var statistics = JSONLFileReader.Statistics()
        statistics.bytesRead = Int(qb_codex_file_result_bytes_read(raw))
        statistics.oversizedLinesSkipped = Int(qb_codex_file_result_oversized_lines(raw))
        return JSONLFileReader.ReadResult(
            succeeded: true,
            statistics: statistics,
            finalPartial: finalPartial,
            isDiscardingOversizedLine: qb_codex_file_result_is_discarding_oversized_line(raw) != 0
        )
    }
}
