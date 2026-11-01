import Foundation

/// Decodes the generation-accounting fields in Antigravity's undocumented conversation protobufs.
/// Based on FelixIsaac's original implementation in openusage#1058 and the follow-up in #1120.
enum AntigravityProtoDecoder {
    static let maximumTokenCount = 1_000_000_000_000_000

    enum WireValue {
        case varint(UInt64)
        case bytes([UInt8])
        case fixed
    }

    struct GenerationEvent: Equatable, Sendable {
        static let unknownModel = "Unknown Antigravity Model"

        var model: String
        var inputTokens: Int
        var outputTokens: Int
        var cacheReadTokens: Int
        var timestampSeconds: Int64
    }

    enum GenerationEventDecodeResult: Equatable, Sendable {
        case event(GenerationEvent)
        case invalidTokenCount(timestampSeconds: Int64?)
        case malformedUsage(timestampSeconds: Int64?)
        case undatedUsage
        case ignored
    }

    private struct TokenCounts {
        var systemPrompt: UInt64 = 0
        var input: UInt64 = 0
        var output: UInt64 = 0
        var cacheRead: UInt64 = 0
    }

    static func decodeVarint(_ bytes: [UInt8], at offset: Int = 0) -> (value: UInt64, nextOffset: Int)? {
        guard offset >= 0, offset < bytes.count else { return nil }

        var value: UInt64 = 0
        for byteIndex in 0..<10 {
            let position = offset + byteIndex
            guard position < bytes.count else { return nil }

            let byte = bytes[position]
            let payload = UInt64(byte & 0x7f)
            guard byteIndex < 9 || payload <= 1 else { return nil }

            value |= payload << (byteIndex * 7)
            if byte & 0x80 == 0 {
                return (value, position + 1)
            }
        }
        return nil
    }

    private static func field(_ requested: UInt32, in bytes: [UInt8]) -> WireValue? {
        var offset = 0

        while offset < bytes.count {
            guard let tag = decodeVarint(bytes, at: offset),
                  let number = UInt32(exactly: tag.value >> 3), number != 0
            else { return nil }

            switch tag.value & 0x7 {
            case 0:
                guard let value = decodeVarint(bytes, at: tag.nextOffset) else { return nil }
                if number == requested { return .varint(value.value) }
                offset = value.nextOffset

            case 2:
                guard let length = decodeVarint(bytes, at: tag.nextOffset),
                      length.value <= UInt64(bytes.count - length.nextOffset),
                      let count = Int(exactly: length.value)
                else { return nil }

                let end = length.nextOffset + count
                if number == requested { return .bytes(Array(bytes[length.nextOffset..<end])) }
                offset = end

            case 1, 5:
                let width = tag.value & 0x7 == 1 ? 8 : 4
                guard bytes.count - tag.nextOffset >= width else { return nil }
                offset = tag.nextOffset + width

            default:
                return nil
            }
        }
        return nil
    }

    static func bytesField(_ number: UInt32, in bytes: [UInt8]) -> [UInt8]? {
        guard case .bytes(let value) = field(number, in: bytes) else { return nil }
        return value
    }

    static func varintField(_ number: UInt32, in bytes: [UInt8]) -> UInt64? {
        guard case .varint(let value) = field(number, in: bytes) else { return nil }
        return value
    }

    /// Return every occurrence of a field while validating the complete containing message. This is
    /// used for singular usage messages: duplicates are rejected so partial accounting is never
    /// published after silently ignoring one protobuf occurrence.
    private static func matchingFields(_ requested: UInt32, in bytes: [UInt8]) -> [WireValue]? {
        var values: [WireValue] = []
        var offset = 0
        while offset < bytes.count {
            guard let tag = decodeVarint(bytes, at: offset),
                  let number = UInt32(exactly: tag.value >> 3), number != 0
            else { return nil }
            switch tag.value & 0x7 {
            case 0:
                guard let value = decodeVarint(bytes, at: tag.nextOffset) else { return nil }
                if number == requested { values.append(.varint(value.value)) }
                offset = value.nextOffset
            case 2:
                guard let length = decodeVarint(bytes, at: tag.nextOffset),
                      length.value <= UInt64(bytes.count - length.nextOffset),
                      let count = Int(exactly: length.value)
                else { return nil }
                let end = length.nextOffset + count
                if number == requested {
                    values.append(.bytes(Array(bytes[length.nextOffset..<end])))
                }
                offset = end
            case 1, 5:
                let width = tag.value & 0x7 == 1 ? 8 : 4
                guard bytes.count - tag.nextOffset >= width else { return nil }
                if number == requested { values.append(.fixed) }
                offset = tag.nextOffset + width
            default:
                return nil
            }
        }
        return values
    }

    /// Antigravity's newer conversation format stores wall-clock time in steps.metadata field 1,
    /// which is a google.protobuf.Timestamp message.
    private static func timestampSeconds(in message: [UInt8]) -> Int64? {
        guard let fields = matchingFields(1, in: message),
              fields.count == 1,
              case .varint(let seconds) = fields[0],
              let timestampSeconds = Int64(exactly: seconds), timestampSeconds > 0
        else { return nil }
        return timestampSeconds
    }

    static func timestamp(fromStepMetadata stepMetadata: [UInt8]) -> Int64? {
        guard let fields = matchingFields(1, in: stepMetadata),
              fields.count == 1,
              case .bytes(let timestamp) = fields[0]
        else { return nil }
        return timestampSeconds(in: timestamp)
    }

    private enum IdentifierEvidence {
        case absent
        case value(String)
        case invalid
    }

    struct StepIdentity: Hashable, Sendable {
        let uuid: String?
        let botID: String?
    }

    private static func stepIdentity(_ uuid: IdentifierEvidence, _ bot: IdentifierEvidence) -> StepIdentity? {
        func value(_ evidence: IdentifierEvidence) -> String? {
            if case .value(let value) = evidence { return value }
            return nil
        }
        if case .invalid = uuid { return nil }
        if case .invalid = bot { return nil }
        let identity = StepIdentity(uuid: value(uuid), botID: value(bot))
        return identity.uuid == nil && identity.botID == nil ? nil : identity
    }

    static func generationStepIdentity(from generation: [UInt8]) -> StepIdentity? {
        guard let wrappers = matchingFields(1, in: generation), wrappers.count == 1,
              case .bytes(let wrapped) = wrappers[0],
              let usages = matchingFields(4, in: wrapped), usages.count == 1,
              case .bytes(let usage) = usages[0] else { return nil }
        return stepIdentity(identifierEvidence(4, in: generation), identifierEvidence(7, in: usage))
    }

    static func stepIdentityAndTimestamp(from metadata: [UInt8]) -> (StepIdentity, Int64)? {
        guard let identity = stepIdentity(
            identifierEvidence(12, in: metadata),
            nestedIdentifierEvidence(containerField: 9, identifierField: 7, in: metadata)
        ), let timestamp = timestamp(fromStepMetadata: metadata) else { return nil }
        return (identity, timestamp)
    }

    /// Step rows are indexed separately from generation records in newer Antigravity databases.
    /// Reject timestamps when identifiers visibly disagree or appear on only one side. Older
    /// generations omit these auxiliary IDs on both sides, so keep the legacy indexed timestamp
    /// behavior when neither side supplies one.
    private static func correlatedStepTimestamp(
        generation: [UInt8],
        wrapped: [UInt8],
        stepMetadata: [UInt8]
    ) -> Int64? {
        guard identifiersAreCompatible(
                identifierEvidence(4, in: generation),
                identifierEvidence(12, in: stepMetadata)
              ),
              let usageFields = matchingFields(4, in: wrapped),
              usageFields.count == 1,
              case .bytes(let usage) = usageFields[0],
              identifiersAreCompatible(
                identifierEvidence(7, in: usage),
                nestedIdentifierEvidence(containerField: 9, identifierField: 7, in: stepMetadata)
              )
        else { return nil }

        return timestamp(fromStepMetadata: stepMetadata)
    }

    private static func identifierEvidence(_ number: UInt32, in bytes: [UInt8]) -> IdentifierEvidence {
        guard let fields = matchingFields(number, in: bytes) else { return .invalid }
        guard !fields.isEmpty else { return .absent }
        guard fields.count == 1,
              case .bytes(let value) = fields[0],
              let string = String(bytes: value, encoding: .utf8),
              !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return .invalid }
        return .value(string)
    }

    private static func nestedIdentifierEvidence(
        containerField: UInt32,
        identifierField: UInt32,
        in bytes: [UInt8]
    ) -> IdentifierEvidence {
        guard let fields = matchingFields(containerField, in: bytes) else { return .invalid }
        guard !fields.isEmpty else { return .absent }
        guard fields.count == 1, case .bytes(let nested) = fields[0] else { return .invalid }
        return identifierEvidence(identifierField, in: nested)
    }

    private static func identifiersAreCompatible(
        _ generation: IdentifierEvidence,
        _ step: IdentifierEvidence
    ) -> Bool {
        switch (generation, step) {
        case (.absent, .absent): return true
        case let (.value(generation), .value(step)): return generation == step
        default: return false
        }
    }

    /// `gen_metadata.data` wraps its event in field 1: model 19, token counts 4, and timestamp 9.
    /// An absent model remains visibly unpriced instead of silently borrowing another Gemini rate.
    /// Newer Antigravity databases omit that embedded timestamp and store it in the correlated step.
    static func generationEvent(from blob: [UInt8], stepMetadata: [UInt8]? = nil) -> GenerationEvent? {
        guard case .event(let event) = decodeGenerationEvent(from: blob, stepMetadata: stepMetadata) else {
            return nil
        }
        return event
    }

    static func decodeGenerationEvent(
        from blob: [UInt8],
        stepMetadata: [UInt8]? = nil,
        matchedStepTimestamp: Int64? = nil
    ) -> GenerationEventDecodeResult {
        guard let wrappers = matchingFields(1, in: blob) else {
            return .malformedUsage(timestampSeconds: nil)
        }
        guard !wrappers.isEmpty else { return .ignored }
        guard wrappers.count == 1,
              case .bytes(let wrapped) = wrappers[0]
        else { return .malformedUsage(timestampSeconds: nil) }

        let fallbackTimestamp = matchedStepTimestamp ?? stepMetadata.flatMap {
            correlatedStepTimestamp(generation: blob, wrapped: wrapped, stepMetadata: $0)
        }

        guard let modelFields = matchingFields(19, in: wrapped) else {
            return .malformedUsage(timestampSeconds: fallbackTimestamp)
        }
        let modelBytes: [UInt8]?
        if modelFields.count == 1,
           case .bytes(let bytes) = modelFields[0]
        {
            modelBytes = bytes
        } else {
            // Ambiguous model metadata keeps the measured tokens but must never select a guessed
            // serving-model price.
            modelBytes = nil
        }
        let decodedModel = modelBytes.flatMap { String(bytes: $0, encoding: .utf8) }
        let model = decodedModel?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let timestampFields = matchingFields(9, in: wrapped), timestampFields.count <= 1 else {
            return .malformedUsage(timestampSeconds: fallbackTimestamp)
        }
        let embeddedTimestamp: Int64?
        if let timestampField = timestampFields.first {
            guard case .bytes(let timestampBytes) = timestampField else {
                return .malformedUsage(timestampSeconds: fallbackTimestamp)
            }
            guard let timestampMessages = matchingFields(4, in: timestampBytes) else {
                return .malformedUsage(timestampSeconds: fallbackTimestamp)
            }
            if timestampMessages.count == 1,
               case .bytes(let wallClock) = timestampMessages[0]
            {
                embeddedTimestamp = timestampSeconds(in: wallClock)
            } else {
                embeddedTimestamp = nil
            }
        } else {
            embeddedTimestamp = nil
        }
        let timestamp = embeddedTimestamp ?? fallbackTimestamp

        guard let usageFields = matchingFields(4, in: wrapped) else {
            return .malformedUsage(timestampSeconds: timestamp)
        }
        guard !usageFields.isEmpty else { return .ignored }
        guard usageFields.count == 1,
              case .bytes(let usage) = usageFields[0],
              let counts = tokenCounts(in: usage)
        else {
            return .malformedUsage(timestampSeconds: timestamp)
        }

        let rawSystemPrompt = counts.systemPrompt
        let rawInput = counts.input
        let rawOutput = counts.output
        let rawCacheRead = counts.cacheRead
        let ceiling = UInt64(maximumTokenCount)
        guard rawSystemPrompt <= ceiling,
              rawInput <= ceiling,
              rawOutput <= ceiling,
              rawCacheRead <= ceiling
        else {
            return .invalidTokenCount(timestampSeconds: timestamp)
        }

        let systemPromptTokens = Int(rawSystemPrompt)
        let inputTokens = Int(rawInput)
        let outputTokens = Int(rawOutput)
        let cacheReadTokens = Int(rawCacheRead)

        let billableInputTokens = systemPromptTokens.addingReportingOverflow(inputTokens)
        guard !billableInputTokens.overflow else {
            return .invalidTokenCount(timestampSeconds: timestamp)
        }
        let inputAndCache = billableInputTokens.partialValue.addingReportingOverflow(cacheReadTokens)
        let total = inputAndCache.partialValue.addingReportingOverflow(outputTokens)
        guard !inputAndCache.overflow, !total.overflow,
              billableInputTokens.partialValue <= maximumTokenCount,
              total.partialValue <= maximumTokenCount
        else {
            return .invalidTokenCount(timestampSeconds: timestamp)
        }
        guard total.partialValue > 0 else { return .ignored }

        guard let timestamp else { return .undatedUsage }

        return .event(GenerationEvent(
            model: model.flatMap { $0.isEmpty ? nil : $0 } ?? GenerationEvent.unknownModel,
            inputTokens: billableInputTokens.partialValue,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens,
            timestampSeconds: timestamp
        ))
    }

    /// Decode the whole usage message so a present counter with the wrong wire type or malformed
    /// trailing field cannot be mistaken for an absent zero-valued counter.
    private static func tokenCounts(in bytes: [UInt8]) -> TokenCounts? {
        var result = TokenCounts()
        var offset = 0

        while offset < bytes.count {
            guard let tag = decodeVarint(bytes, at: offset),
                  let number = UInt32(exactly: tag.value >> 3), number != 0
            else { return nil }
            let wireType = tag.value & 0x7
            switch wireType {
            case 0:
                guard let value = decodeVarint(bytes, at: tag.nextOffset) else { return nil }
                switch number {
                case 1: result.systemPrompt = value.value
                case 2: result.input = value.value
                case 3: result.output = value.value
                case 5: result.cacheRead = value.value
                default: break
                }
                offset = value.nextOffset
            case 2:
                guard let length = decodeVarint(bytes, at: tag.nextOffset),
                      length.value <= UInt64(bytes.count - length.nextOffset),
                      let count = Int(exactly: length.value)
                else { return nil }
                switch number {
                case 1, 2, 3, 5: return nil
                default: offset = length.nextOffset + count
                }
            case 1, 5:
                let width = wireType == 1 ? 8 : 4
                guard bytes.count - tag.nextOffset >= width else { return nil }
                switch number {
                case 1, 2, 3, 5: return nil
                default: offset = tag.nextOffset + width
                }
            default:
                return nil
            }
        }
        return result
    }
}
