import Foundation
import CQuotabarCore

/// Bridge to the quotabar-core Rust Antigravity protobuf decoder
/// (`Rust/quotabar-core/src/antigravity.rs`, see docs/rust-core.md).
///
/// The Rust decoder is a faithful port of `AntigravityProtoDecoder` plus the
/// `AntigravityDbUsageScanner.bytes(fromHex:)` hex decode: same wire walk, same reject cases,
/// same token-count ceiling. A NULL FFI result becomes `.fallback` — never a different
/// answer — and covers the two inputs the port cannot emulate: hex containing non-ASCII
/// bytes (Swift windows the string by `Character`, not by byte) and identifier strings whose
/// canonical equivalence cannot be decided without Unicode normalization.
enum AntigravityRustDecoder {
    /// Mirror of the per-row decode, carrying the same verdict the Swift
    /// `decodeGenerationEvent` returns.
    enum GenerationOutcome {
        case decoded(AntigravityProtoDecoder.GenerationEventDecodeResult)
        /// The generation hex is undecodable — identical to `bytes(fromHex:)` returning nil:
        /// the row takes the caller's oversized/unreadable path, never the decoder.
        case unreadableBlob
        /// Run the Swift reference decode for this row.
        case fallback
    }

    /// Mirror of `AntigravityProtoDecoder.generationStepIdentity(from:)`.
    enum IdentityOutcome {
        case present(AntigravityProtoDecoder.StepIdentity)
        case absent
        case fallback
    }

    /// Mirror of `AntigravityProtoDecoder.stepIdentityAndTimestamp(from:)`.
    enum StepMetadataOutcome {
        case present(AntigravityProtoDecoder.StepIdentity, timestamp: Int64)
        case absent
        case fallback
    }

    static func decodeGeneration(
        fromHex hex: String,
        stepHex: String?,
        matchedStepTimestamp: Int64?
    ) -> GenerationOutcome {
        withUTF8(hex) { hexPointer, hexLength in
            withOptionalUTF8(stepHex) { stepPointer, stepLength in
                guard let raw = qb_antigravity_decode_generation(
                    hexPointer,
                    hexLength,
                    stepPointer,
                    stepLength,
                    matchedStepTimestamp ?? 0,
                    matchedStepTimestamp == nil ? 0 : 1
                ) else {
                    // Null is the library's "fall back to Swift" signal, never an error.
                    return .fallback
                }
                defer { qb_antigravity_generation_destroy(raw) }
                return generationOutcome(raw)
            }
        }
    }

    static func decodeGeneration(
        fromBytes blob: [UInt8],
        stepHex: String?,
        matchedStepTimestamp: Int64?
    ) -> GenerationOutcome {
        blob.withUnsafeBufferPointer { buffer in
            withOptionalUTF8(stepHex) { stepPointer, stepLength in
                guard let raw = qb_antigravity_decode_generation_blob(
                    buffer.baseAddress,
                    buffer.count,
                    stepPointer,
                    stepLength,
                    matchedStepTimestamp ?? 0,
                    matchedStepTimestamp == nil ? 0 : 1
                ) else {
                    return .fallback
                }
                defer { qb_antigravity_generation_destroy(raw) }
                return generationOutcome(raw)
            }
        }
    }

    static func generationStepIdentity(fromHex hex: String) -> IdentityOutcome {
        withUTF8(hex) { pointer, length in
            guard let raw = qb_antigravity_generation_step_identity(pointer, length) else {
                return .fallback
            }
            defer { qb_antigravity_identity_destroy(raw) }
            return identityOutcome(raw)
        }
    }

    static func generationStepIdentity(fromBytes blob: [UInt8]) -> IdentityOutcome {
        blob.withUnsafeBufferPointer { buffer in
            guard let raw = qb_antigravity_generation_step_identity_blob(
                buffer.baseAddress,
                buffer.count
            ) else {
                return .fallback
            }
            defer { qb_antigravity_identity_destroy(raw) }
            return identityOutcome(raw)
        }
    }

    static func stepMetadataIdentityAndTimestamp(fromHex hex: String) -> StepMetadataOutcome {
        withUTF8(hex) { pointer, length in
            guard let raw = qb_antigravity_step_metadata_identity(pointer, length) else {
                return .fallback
            }
            defer { qb_antigravity_identity_destroy(raw) }
            switch qb_antigravity_identity_status(raw) {
            case QB_ANTIGRAVITY_IDENTITY_ABSENT:
                return .absent
            case QB_ANTIGRAVITY_IDENTITY_PRESENT:
                guard let ffi = qb_antigravity_identity(raw) else { return .fallback }
                guard ffi.pointee.has_timestamp != 0 else { return .fallback }
                guard let identity = stepIdentity(ffi.pointee, result: raw) else { return .fallback }
                return .present(identity, timestamp: ffi.pointee.timestamp_seconds)
            default:
                return .fallback
            }
        }
    }

    // MARK: - Result mapping

    private static func generationOutcome(_ raw: UnsafeRawPointer) -> GenerationOutcome {
        switch qb_antigravity_generation_status(raw) {
        case QB_ANTIGRAVITY_UNREADABLE_HEX:
            return .unreadableBlob
        case QB_ANTIGRAVITY_IGNORED:
            return .decoded(.ignored)
        case QB_ANTIGRAVITY_UNDATED_USAGE:
            return .decoded(.undatedUsage)
        case QB_ANTIGRAVITY_INVALID_TOKEN_COUNT:
            return .decoded(.invalidTokenCount(timestampSeconds: timestampPayload(raw)))
        case QB_ANTIGRAVITY_MALFORMED_USAGE:
            return .decoded(.malformedUsage(timestampSeconds: timestampPayload(raw)))
        case QB_ANTIGRAVITY_EVENT:
            guard let ffi = qb_antigravity_generation_event(raw) else { return .fallback }
            var stringsLength: UInt32 = 0
            let stringsPointer = qb_antigravity_generation_strings(raw, &stringsLength)
            // The model is never nil in a decoded event — a bounds miss means the archive and
            // header disagree, so fail loudly into fallback.
            guard let model = string(
                at: ffi.pointee.model_offset,
                length: ffi.pointee.model_length,
                base: stringsPointer,
                blobLength: stringsLength
            ) else { return .fallback }
            return .decoded(.event(AntigravityProtoDecoder.GenerationEvent(
                model: model,
                inputTokens: Int(ffi.pointee.input_tokens),
                outputTokens: Int(ffi.pointee.output_tokens),
                cacheReadTokens: Int(ffi.pointee.cache_read_tokens),
                timestampSeconds: ffi.pointee.timestamp_seconds
            )))
        default:
            return .fallback
        }
    }

    private static func timestampPayload(_ raw: UnsafeRawPointer) -> Int64? {
        qb_antigravity_generation_has_timestamp(raw) != 0
            ? qb_antigravity_generation_timestamp(raw)
            : nil
    }

    private static func identityOutcome(_ raw: UnsafeRawPointer) -> IdentityOutcome {
        switch qb_antigravity_identity_status(raw) {
        case QB_ANTIGRAVITY_IDENTITY_ABSENT:
            return .absent
        case QB_ANTIGRAVITY_IDENTITY_PRESENT:
            guard let ffi = qb_antigravity_identity(raw),
                  let identity = stepIdentity(ffi.pointee, result: raw)
            else { return .fallback }
            return .present(identity)
        default:
            return .fallback
        }
    }

    private static func stepIdentity(
        _ ffi: QbAntigravityStepIdentity,
        result raw: UnsafeRawPointer
    ) -> AntigravityProtoDecoder.StepIdentity? {
        var stringsLength: UInt32 = 0
        let stringsPointer = qb_antigravity_identity_strings(raw, &stringsLength)
        let uuid = string(
            at: ffi.uuid_offset,
            length: ffi.uuid_length,
            base: stringsPointer,
            blobLength: stringsLength
        )
        let botID = string(
            at: ffi.bot_id_offset,
            length: ffi.bot_id_length,
            base: stringsPointer,
            blobLength: stringsLength
        )
        // Offsets must either be the nil sentinel or land inside the blob; anything else means
        // the archive and header disagree — fail loudly into fallback.
        if uuid == nil && ffi.uuid_offset != QB_NIL_STRING_OFFSET { return nil }
        if botID == nil && ffi.bot_id_offset != QB_NIL_STRING_OFFSET { return nil }
        return AntigravityProtoDecoder.StepIdentity(uuid: uuid, botID: botID)
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

    // MARK: - UTF-8 plumbing

    /// Pass the string's UTF-8 view to `body` without copying when the storage is already
    /// contiguous (the JSON-decoded row strings are). An empty string still yields a non-NULL
    /// pointer so the Rust side can tell "present but empty" from "absent".
    private static func withUTF8<R>(
        _ string: String,
        _ body: (UnsafePointer<UInt8>?, Int) -> R
    ) -> R {
        let fallbackBase = UnsafePointer<UInt8>(bitPattern: 1)
        if let result = string.utf8.withContiguousStorageIfAvailable({ buffer in
            body(buffer.baseAddress ?? fallbackBase, buffer.count)
        }) {
            return result
        }
        return Array(string.utf8).withUnsafeBufferPointer { buffer in
            body(buffer.baseAddress ?? fallbackBase, buffer.count)
        }
    }

    private static func withOptionalUTF8<R>(
        _ string: String?,
        _ body: (UnsafePointer<UInt8>?, Int) -> R
    ) -> R {
        guard let string else { return body(nil, 0) }
        return withUTF8(string, body)
    }
}
