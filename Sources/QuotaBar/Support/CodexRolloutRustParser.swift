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

    struct Checkpoint {
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

        /// Lines the engine skipped as damaged (mirrors `FileParser.damagedLineCount`).
        var damagedLineCount: Int {
            Int(qb_codex_parser_damaged_count(parser))
        }

        /// Move out the events emitted so far. Valid to call once, after the last line.
        /// Returns nil when the result fails its bounds checks — the caller then re-parses the
        /// file with the Swift implementation. Silently returning an empty array would attribute
        /// zero usage to the file, so a broken result is always an explicit nil.
        func finish() -> [Event]? {
            guard let raw = qb_codex_parser_take_events(parser) else { return nil }
            defer { qb_codex_take_events_destroy(raw) }
            let count = Int(qb_codex_take_events_count(raw))
            guard count > 0 else { return [] }
            guard let entries = qb_codex_take_events_entries(raw) else { return nil }
            var stringsPointer: UnsafePointer<UInt8>?
            var stringsLength: UInt32 = 0
            stringsPointer = qb_codex_take_events_strings(raw, &stringsLength)

            func string(at offset: UInt32, length: UInt32) -> String? {
                guard offset != QB_NIL_STRING_OFFSET else { return nil }
                guard let stringsPointer else { return nil }
                guard UInt64(offset) + UInt64(length) <= UInt64(stringsLength) else { return nil }
                return String(
                    decoding: UnsafeBufferPointer(
                        start: stringsPointer.advanced(by: Int(offset)),
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
    }
}
