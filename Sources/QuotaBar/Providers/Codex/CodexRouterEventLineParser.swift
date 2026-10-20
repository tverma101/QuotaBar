import Foundation

/// Single-pass parser for CodexRouter's flat JSONL event objects. Keeping field discovery in one walk
/// avoids searching the whole line once per property, which is expensive for large ledgers containing
/// optional metadata or opaque payload strings.
enum CodexRouterEventLineParser {
    enum LineResult {
        case event(CodexRouterUsageScanner.Event)
        /// The JSON object and timestamp parsed successfully, so callers that need to decide whether
        /// the damaged row belongs to a disabled account can inspect its validated ownership fields.
        case malformedEvent(CodexRouterUsageScanner.Event)
        case irrelevant
        case malformed
    }

    /// Reuses short repeated event times without retaining unbounded ledger history or oversized keys.
    struct TimestampCache: Sendable {
        private let capacity: Int
        private var dates: [String: Date] = [:]
        private(set) var cacheHitCount = 0

        init(capacity: Int = 2_048) {
            precondition(capacity > 0)
            self.capacity = capacity
        }

        var cachedTimestampCount: Int { dates.count }

        mutating func date(from value: String, cacheable: Bool) -> Date? {
            if cacheable, let cached = dates[value] {
                cacheHitCount += 1
                return cached
            }
            guard let parsed = OpenUsageISO8601.date(from: value) else { return nil }
            if cacheable, dates.count < capacity {
                dates[value] = parsed
            }
            return parsed
        }
    }

    private static let timestampCacheableByteLimit = 64

    private enum Field: Hashable {
        case at
        case model
        case provider
        case status
        case inputTokens
        case cachedInputTokens
        case outputTokens
        case reasoningTokens
        case totalTokens
        case estimatedInputTokens
        case accountId
        case accountFingerprint
        case serviceTier
    }

    private struct Fields {
        var at: String?
        var model: String?
        var modelValid = true
        var provider: String?
        var providerValid = true
        var status: Int?
        var statusSeen = false
        var statusValid = false
        var inputTokens: Int?
        var cachedInputTokens: Int?
        var outputTokens: Int?
        var reasoningTokens: Int?
        var totalTokens: Int?
        var estimatedInputTokens: Int?
        var tokenCountSaturated = false
        var cachedInputTokensSeen = false
        var cachedInputTokensValid = false
        var totalTokensSeen = false
        var totalTokensValid = false
        var estimatedInputTokensSeen = false
        var estimatedInputTokensValid = false
        var accountId: String?
        var accountFingerprint: String?
        var accountIdValid = true
        var accountFingerprintValid = true
        var serviceTier: String?
        var serviceTierValid = true
        var seenFields: Set<Field> = []
        var duplicateFields: Set<Field> = []
        var recognizedFieldsUnique = true
        var numericCountFieldValidity: [Field: Bool] = [:]

        var accountIdentityFieldsValid: Bool { accountIdValid && accountFingerprintValid }
        var numericCountFieldsValid: Bool { numericCountFieldValidity.values.allSatisfy { $0 } }
        var statusFieldUnique: Bool { !duplicateFields.contains(.status) }
        var providerFieldUnique: Bool { !duplicateFields.contains(.provider) }
        var modelFieldUnique: Bool { !duplicateFields.contains(.model) }
        var accountIdentityFieldsUnique: Bool {
            !duplicateFields.contains(.accountId) && !duplicateFields.contains(.accountFingerprint)
        }

        mutating func set(_ field: Field, string: String) {
            switch field {
            case .at: at = string
            case .model:
                model = string
                modelValid = true
            case .provider:
                provider = string.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                providerValid = provider != nil
            case .accountId:
                accountId = string
                accountIdValid = true
            case .accountFingerprint:
                accountFingerprint = string
                accountFingerprintValid = true
            case .serviceTier:
                let tier = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                serviceTier = tier.nilIfEmpty
                serviceTierValid = CodexRouterEventLineParser.knownServiceTiers.contains(tier)
            case .status, .inputTokens, .cachedInputTokens, .outputTokens, .reasoningTokens, .totalTokens,
                 .estimatedInputTokens:
                break
            }
        }

        mutating func set(_ field: Field, integer: Int) {
            switch field {
            case .status:
                status = integer
                statusSeen = true
                // The router emits an explicit zero for a canceled/failed transport attempt.
                // It is a valid unsuccessful record, not a malformed successful measurement.
                statusValid = integer == 0 || (100..<600).contains(integer)
            case .inputTokens:
                inputTokens = integer
                numericCountFieldValidity[field] = integer >= 0
            case .cachedInputTokens:
                cachedInputTokens = integer
                cachedInputTokensValid = integer >= 0
                numericCountFieldValidity[field] = integer >= 0
            case .outputTokens:
                outputTokens = integer
                numericCountFieldValidity[field] = integer >= 0
            case .reasoningTokens:
                reasoningTokens = integer
                numericCountFieldValidity[field] = integer >= 0
            case .totalTokens:
                totalTokens = integer
                totalTokensValid = integer >= 0
                numericCountFieldValidity[field] = integer >= 0
            case .estimatedInputTokens:
                estimatedInputTokens = integer
                estimatedInputTokensValid = integer >= 0
                numericCountFieldValidity[field] = integer >= 0
            case .at, .model, .accountId, .accountFingerprint:
                break
            case .provider:
                break
            case .serviceTier:
                break
            }
        }

        mutating func clear(_ field: Field) {
            switch field {
            case .at: at = nil
            case .model:
                model = nil
                modelValid = false
            case .provider:
                provider = nil
                providerValid = false
            case .status:
                status = nil
                statusSeen = true
                statusValid = false
            case .inputTokens:
                inputTokens = nil
                numericCountFieldValidity[field] = false
            case .cachedInputTokens:
                cachedInputTokens = nil
                cachedInputTokensSeen = true
                cachedInputTokensValid = false
                numericCountFieldValidity[field] = false
            case .outputTokens:
                outputTokens = nil
                numericCountFieldValidity[field] = false
            case .reasoningTokens:
                reasoningTokens = nil
                numericCountFieldValidity[field] = false
            case .totalTokens:
                totalTokens = nil
                totalTokensSeen = true
                totalTokensValid = false
                numericCountFieldValidity[field] = false
            case .estimatedInputTokens:
                estimatedInputTokens = nil
                estimatedInputTokensSeen = true
                estimatedInputTokensValid = false
                numericCountFieldValidity[field] = false
            case .accountId:
                accountId = nil
                accountIdValid = false
            case .accountFingerprint:
                accountFingerprint = nil
                accountFingerprintValid = false
            case .serviceTier:
                serviceTier = nil
                serviceTierValid = false
            }
        }

        mutating func setNull(_ field: Field) {
            switch field {
            case .accountId:
                // Optional identity fields may be explicitly null in legacy router rows.
                accountIdValid = true
            case .accountFingerprint:
                accountFingerprintValid = true
            case .serviceTier:
                serviceTierValid = false
            case .provider:
                providerValid = false
            case .model:
                modelValid = false
            default:
                break
            }
        }
    }

    private typealias StringToken = JSONLineStructure.StringToken

    private static let knownServiceTiers: Set<String> = [
        "auto", "default", "standard", "priority", "fast", "flex", "batch", "ultrafast"
    ]

    private struct ParsedInteger {
        var value: Int
        var next: Int
        var isExactInteger: Bool
        var isWithinBounds: Bool
        var isSaturated: Bool
    }

    static func parse(_ line: Data.SubSequence) -> CodexRouterUsageScanner.Event? {
        var timestampCache = TimestampCache()
        return parse(line, timestampCache: &timestampCache)
    }

    static func parse(
        _ line: Data.SubSequence,
        timestampCache: inout TimestampCache
    ) -> CodexRouterUsageScanner.Event? {
        var malformedEvent: CodexRouterUsageScanner.Event?
        return line.withUnsafeBytes { rawBytes in
            parse(
                rawBytes.bindMemory(to: UInt8.self),
                timestampCache: &timestampCache,
                malformedEvent: &malformedEvent
            )
        }
    }

    /// Preserve the distinction between an unrelated valid object and a damaged event row. A ledger
    /// checkpoint must never advance over a malformed candidate row because the next scan would then
    /// publish a smaller aggregate permanently.
    static func parseResult(
        _ line: Data.SubSequence,
        timestampCache: inout TimestampCache
    ) -> LineResult {
        var malformedEvent: CodexRouterUsageScanner.Event?
        let event = line.withUnsafeBytes { rawBytes in
            parse(
                rawBytes.bindMemory(to: UInt8.self),
                timestampCache: &timestampCache,
                malformedEvent: &malformedEvent
            )
        }
        if let event {
            if event.hasValidStatusField, event.hasUniqueStatusField,
               !CodexRouterUsageScanner.isSuccessfulStatus(event.status) {
                return .irrelevant
            }
            return event.hasValidStatusField && event.hasValidAccountIdentityFields
                && event.hasValidModelField && event.hasValidNumericCountFields && event.hasUniqueRecognizedFields
                && event.hasValidProviderField != false
                ? .event(event)
                : .malformedEvent(event)
        }
        if let malformedEvent {
            if malformedEvent.hasValidStatusField, malformedEvent.hasUniqueStatusField,
               !CodexRouterUsageScanner.isSuccessfulStatus(malformedEvent.status) {
                return .irrelevant
            }
            return .malformedEvent(malformedEvent)
        }
        guard !line.isEmpty else { return .irrelevant }
        let bytes = Data(line)
        guard !bytes.allSatisfy(isWhitespace) else { return .irrelevant }
        guard let object = try? JSONSerialization.jsonObject(with: bytes, options: [.fragmentsAllowed]),
              let fields = object as? [String: Any]
        else { return .malformed }
        let eventFields: Set<String> = [
            "at", "model", "provider", "status", "inputTokens", "cachedInputTokens",
            "outputTokens", "reasoningTokens", "totalTokens", "estimatedInputTokens",
            "accountId", "accountFingerprint", "serviceTier"
        ]
        return fields.keys.contains(where: eventFields.contains) ? .malformed : .irrelevant
    }

    /// A final file fragment is a record only when it has its closing object delimiter. Otherwise it
    /// may still be in the middle of an append and must remain buffered for the next scan.
    static func looksLikeCompleteObject(_ line: Data.SubSequence) -> Bool {
        var end = line.endIndex
        while end > line.startIndex {
            let previous = line.index(before: end)
            guard isWhitespace(line[previous]) else { return line[previous] == ascii("}") }
            end = previous
        }
        return false
    }

    private static func parse(
        _ bytes: UnsafeBufferPointer<UInt8>,
        timestampCache: inout TimestampCache,
        malformedEvent: inout CodexRouterUsageScanner.Event?
    ) -> CodexRouterUsageScanner.Event? {
        var objectStart = 0
        while objectStart < bytes.count, isWhitespace(bytes[objectStart]) {
            objectStart += 1
        }
        guard objectStart + 1 < bytes.count, bytes[objectStart] == ascii("{") else { return nil }
        var objectEnd = bytes.count
        while objectEnd > 1, isWhitespace(bytes[objectEnd - 1]) {
            objectEnd -= 1
        }
        guard objectEnd > 1, bytes[objectEnd - 1] == ascii("}") else { return nil }
        objectEnd -= 1

        var fields = Fields()
        var cacheableTimestamp = false
        var cursor = objectStart + 1
        while cursor < objectEnd {
            skipWhitespace(bytes, cursor: &cursor, end: objectEnd)
            if cursor == objectEnd { break }
            guard bytes[cursor] == ascii("\""),
                  let keyToken = scanString(bytes, openingQuote: cursor, end: objectEnd)
            else { return nil }
            let field = field(for: bytes, token: keyToken, openingQuote: cursor)
            cursor = keyToken.next
            skipWhitespace(bytes, cursor: &cursor, end: objectEnd)
            guard cursor < objectEnd, bytes[cursor] == ascii(":") else { return nil }
            cursor += 1
            skipWhitespace(bytes, cursor: &cursor, end: objectEnd)
            guard cursor < objectEnd else { return nil }

            let valueStart = cursor
            if let field {
                if !fields.seenFields.insert(field).inserted {
                    fields.recognizedFieldsUnique = false
                    fields.duplicateFields.insert(field)
                }
                fields.clear(field)
                if case .at = field {
                    cacheableTimestamp = false
                }
            }
            if let field, isStringField(field), bytes[cursor] == ascii("\"") {
                guard let token = scanString(bytes, openingQuote: cursor, end: objectEnd) else { return nil }
                guard let value = decodeString(bytes, token: token, openingQuote: cursor) else { return nil }
                fields.set(field, string: value)
                if case .at = field {
                    cacheableTimestamp = token.content.count <= timestampCacheableByteLimit
                }
                cursor = token.next
            } else if let field, isIntegerField(field), isNumberStart(bytes[cursor]) {
                guard let parsed = parseInteger(bytes, start: cursor, end: objectEnd) else { return nil }
                fields.set(field, integer: parsed.value)
                if case .status = field, !parsed.isExactInteger {
                    fields.statusValid = false
                }
                if Self.isTokenCountField(field) {
                    if parsed.isSaturated, parsed.value >= 0 {
                        // estimatedInputTokens only describes router-side cost coverage. It never
                        // contributes to measured usage, so a clamped estimate cannot make an exact
                        // input/output/total count look like a lower bound.
                        if Self.isMeasuredTokenCountField(field) {
                            fields.tokenCountSaturated = true
                        }
                    } else if !parsed.isExactInteger || !parsed.isWithinBounds {
                        fields.numericCountFieldValidity[field] = false
                    }
                }
                cursor = parsed.next
            } else {
                guard let next = skipValue(bytes, from: valueStart, end: objectEnd) else { return nil }
                if let field, isNullLiteral(bytes, from: valueStart, to: next) {
                    fields.setNull(field)
                }
                cursor = next
            }

            skipWhitespace(bytes, cursor: &cursor, end: objectEnd)
            if cursor == objectEnd { break }
            guard cursor < objectEnd else { return nil }
            if bytes[cursor] == ascii(",") {
                cursor += 1
                skipWhitespace(bytes, cursor: &cursor, end: objectEnd)
                guard cursor < objectEnd else { return nil }
            } else {
                return nil
            }
        }

        guard cursor == objectEnd else { return nil }
        let timestampString = fields.at?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let timestampString,
              let timestamp = timestampCache.date(from: timestampString, cacheable: cacheableTimestamp)
        else {
            malformedEvent = makeEvent(
                from: fields,
                timestamp: .distantPast,
                hasValidTimestampField: false
            )
            return nil
        }
        return makeEvent(from: fields, timestamp: timestamp, hasValidTimestampField: true)
    }

    private static func makeEvent(
        from fields: Fields,
        timestamp: Date,
        hasValidTimestampField: Bool
    ) -> CodexRouterUsageScanner.Event {
        let model = fields.model?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
            ?? ModelUsageEntry.unattributedModelName
        let provider = fields.provider?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
            ?? "unknown"
        let inputTokens = max(0, fields.inputTokens ?? 0)
        let cachedInputTokens = max(0, fields.cachedInputTokens ?? 0)
        let outputTokens = max(0, fields.outputTokens ?? 0)
        let reasoningTokens = max(0, fields.reasoningTokens ?? 0)
        let totalTokens: Int?
        if let reportedTotal = fields.totalTokens, reportedTotal >= 0 {
            totalTokens = reportedTotal
        } else {
            totalTokens = nil
        }
        let hasInputTokensField = fields.inputTokens.map { $0 >= 0 } ?? false
        let hasOutputTokensField = fields.outputTokens.map { $0 >= 0 } ?? false
        let hasEstimatedInputTokens = fields.estimatedInputTokens.map { $0 > 0 } ?? false
        let accountId = fields.accountId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        let accountFingerprint = fields.accountFingerprint?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        let serviceTier = fields.serviceTier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty?
            .lowercased()
        return CodexRouterUsageScanner.Event(
            timestamp: timestamp,
            model: model,
            provider: provider,
            status: fields.status ?? 0,
            hasValidStatusField: fields.statusSeen && fields.statusValid,
            hasValidTimestampField: hasValidTimestampField,
            hasValidModelField: fields.modelValid,
            hasUniqueStatusField: fields.statusFieldUnique,
            hasUniqueProviderField: fields.providerFieldUnique,
            hasUniqueModelField: fields.modelFieldUnique,
            hasUniqueAccountIdentityFields: fields.accountIdentityFieldsUnique,
            hasValidNumericCountFields: fields.numericCountFieldsValid,
            hasUniqueRecognizedFields: fields.recognizedFieldsUnique,
            inputTokens: inputTokens,
            cachedInputTokens: cachedInputTokens,
            outputTokens: outputTokens,
            reasoningTokens: reasoningTokens,
            totalTokens: totalTokens,
            hasInputTokensField: hasInputTokensField,
            hasOutputTokensField: hasOutputTokensField,
            hasValidCachedInputTokensField: !fields.cachedInputTokensSeen || fields.cachedInputTokensValid,
            hasValidTotalTokensField: !fields.totalTokensSeen || fields.totalTokensValid,
            hasValidEstimatedInputTokensField: !fields.estimatedInputTokensSeen || fields.estimatedInputTokensValid,
            hasEstimatedInputTokens: hasEstimatedInputTokens,
            hasValidAccountIdentityFields: fields.accountIdentityFieldsValid,
            hasValidProviderField: fields.providerValid,
            hasValidServiceTierField: fields.serviceTierValid,
            accountId: accountId,
            accountFingerprint: accountFingerprint,
            serviceTier: serviceTier,
            tokenCountSaturated: fields.tokenCountSaturated ? true : nil
        )
    }

    private static func field(
        for bytes: UnsafeBufferPointer<UInt8>,
        token: StringToken,
        openingQuote: Int
    ) -> Field? {
        if token.hasEscapes {
            guard let key = decodeString(bytes, token: token, openingQuote: openingQuote) else { return nil }
            return field(named: key)
        }
        return field(for: bytes, key: token.content)
    }

    private static func field(for bytes: UnsafeBufferPointer<UInt8>, key: Range<Int>) -> Field? {
        switch key.count {
        case 2 where matches(bytes, key, "at"): return .at
        case 5 where matches(bytes, key, "model"): return .model
        case 6 where matches(bytes, key, "status"): return .status
        case 8 where matches(bytes, key, "provider"): return .provider
        case 9 where matches(bytes, key, "accountId"): return .accountId
        case 11:
            if matches(bytes, key, "inputTokens") { return .inputTokens }
            if matches(bytes, key, "totalTokens") { return .totalTokens }
            if matches(bytes, key, "serviceTier") { return .serviceTier }
        case 12 where matches(bytes, key, "outputTokens"): return .outputTokens
        case 15 where matches(bytes, key, "reasoningTokens"): return .reasoningTokens
        case 17 where matches(bytes, key, "cachedInputTokens"): return .cachedInputTokens
        case 18 where matches(bytes, key, "accountFingerprint"): return .accountFingerprint
        case 20 where matches(bytes, key, "estimatedInputTokens"): return .estimatedInputTokens
        default: break
        }
        return nil
    }

    private static func field(named key: String) -> Field? {
        switch key {
        case "at": return .at
        case "model": return .model
        case "provider": return .provider
        case "status": return .status
        case "inputTokens": return .inputTokens
        case "cachedInputTokens": return .cachedInputTokens
        case "outputTokens": return .outputTokens
        case "reasoningTokens": return .reasoningTokens
        case "totalTokens": return .totalTokens
        case "accountId": return .accountId
        case "accountFingerprint": return .accountFingerprint
        case "serviceTier": return .serviceTier
        case "estimatedInputTokens": return .estimatedInputTokens
        default: return nil
        }
    }

    private static func matches(
        _ bytes: UnsafeBufferPointer<UInt8>,
        _ range: Range<Int>,
        _ literal: StaticString
    ) -> Bool {
        literal.withUTF8Buffer { expected in
            guard range.count == expected.count else { return false }
            for offset in 0..<expected.count where bytes[range.lowerBound + offset] != expected[offset] {
                return false
            }
            return true
        }
    }

    private static func isStringField(_ field: Field) -> Bool {
        switch field {
        case .at, .model, .provider, .accountId, .accountFingerprint, .serviceTier: return true
        case .status, .inputTokens, .cachedInputTokens, .outputTokens, .reasoningTokens, .totalTokens,
             .estimatedInputTokens: return false
        }
    }

    private static func isTokenCountField(_ field: Field) -> Bool {
        switch field {
        case .inputTokens, .cachedInputTokens, .outputTokens, .reasoningTokens, .totalTokens,
             .estimatedInputTokens:
            return true
        case .at, .model, .provider, .status, .accountId, .accountFingerprint, .serviceTier:
            return false
        }
    }

    private static func isMeasuredTokenCountField(_ field: Field) -> Bool {
        switch field {
        case .inputTokens, .cachedInputTokens, .outputTokens, .reasoningTokens, .totalTokens:
            return true
        case .estimatedInputTokens, .at, .model, .provider, .status, .accountId, .accountFingerprint,
             .serviceTier:
            return false
        }
    }

    private static func isNullLiteral(
        _ bytes: UnsafeBufferPointer<UInt8>,
        from start: Int,
        to end: Int
    ) -> Bool {
        end - start == 4 && matches(bytes, start..<end, "null")
    }

    private static func isIntegerField(_ field: Field) -> Bool {
        !isStringField(field)
    }

    private static func scanString(
        _ bytes: UnsafeBufferPointer<UInt8>,
        openingQuote: Int,
        end: Int
    ) -> StringToken? {
        guard openingQuote < end, bytes[openingQuote] == ascii("\"") else { return nil }
        return JSONLineStructure.scanString(bytes, openingQuote: openingQuote, end: end)
    }

    private static func decodeString(
        _ bytes: UnsafeBufferPointer<UInt8>,
        token: StringToken,
        openingQuote: Int
    ) -> String? {
        guard token.hasEscapes else {
            return String(bytes: bytes[token.content], encoding: .utf8)
        }
        let quoted = Data(bytes[openingQuote..<token.next])
        let wrapped = Data([ascii("[")]) + quoted + Data([ascii("]")])
        return ((try? JSONSerialization.jsonObject(with: wrapped)) as? [String])?.first
    }

    private static func parseInteger(
        _ bytes: UnsafeBufferPointer<UInt8>,
        start: Int,
        end: Int
    ) -> ParsedInteger? {
        var cursor = start
        var negative = false
        if cursor < end, bytes[cursor] == ascii("-") {
            negative = true
            cursor += 1
        }

        guard cursor < end else { return nil }
        if bytes[cursor] == ascii("0") {
            cursor += 1
        } else {
            guard bytes[cursor] >= ascii("1"), bytes[cursor] <= ascii("9") else { return nil }
            while cursor < end, bytes[cursor] >= ascii("0"), bytes[cursor] <= ascii("9") {
                cursor += 1
            }
        }

        var needsFloatingPointConversion = false
        if cursor < end, bytes[cursor] == ascii(".") {
            needsFloatingPointConversion = true
            cursor += 1
            let fractionStart = cursor
            while cursor < end, bytes[cursor] >= ascii("0"), bytes[cursor] <= ascii("9") {
                cursor += 1
            }
            guard cursor > fractionStart else { return nil }
        }
        if cursor < end, (bytes[cursor] == ascii("e") || bytes[cursor] == ascii("E")) {
            needsFloatingPointConversion = true
            cursor += 1
            if cursor < end, (bytes[cursor] == ascii("+") || bytes[cursor] == ascii("-")) {
                cursor += 1
            }
            let exponentStart = cursor
            while cursor < end, bytes[cursor] >= ascii("0"), bytes[cursor] <= ascii("9") {
                cursor += 1
            }
            guard cursor > exponentStart else { return nil }
        }

        let numberEnd = cursor
        var next = cursor
        skipWhitespace(bytes, cursor: &next, end: end)
        guard next == end || bytes[next] == ascii(",") else { return nil }

        let ceiling = 1_000_000_000_000_000
        let value: Int
        let isExactInteger: Bool
        let isWithinBounds: Bool
        let isSaturated: Bool
        if needsFloatingPointConversion {
            guard let text = String(bytes: bytes[start..<numberEnd], encoding: .utf8),
                  let number = Double(text), !number.isNaN else { return nil }
            isExactInteger = number.isFinite && number.rounded(.towardZero) == number
            isWithinBounds = number.isFinite && abs(number) <= Double(ceiling)
            isSaturated = !isWithinBounds
            if number.isInfinite {
                value = negative ? -ceiling : ceiling
            } else {
                value = Int(max(-Double(ceiling), min(Double(ceiling), number.rounded(.down))))
            }
        } else {
            isExactInteger = true
            var digitsStart = start
            if negative { digitsStart += 1 }
            var magnitude = 0
            var saturated = false
            for index in digitsStart..<numberEnd {
                let digit = Int(bytes[index] - ascii("0"))
                if magnitude > (ceiling - digit) / 10 {
                    magnitude = ceiling
                    saturated = true
                } else if !saturated {
                    magnitude = magnitude * 10 + digit
                }
            }
            value = negative ? -magnitude : magnitude
            isWithinBounds = !saturated
            isSaturated = saturated
        }
        return ParsedInteger(
            value: value,
            next: numberEnd,
            isExactInteger: isExactInteger,
            isWithinBounds: isWithinBounds,
            isSaturated: isSaturated
        )
    }

    private static func isNumberStart(_ byte: UInt8) -> Bool {
        byte == ascii("-") || (byte >= ascii("0") && byte <= ascii("9"))
    }

    /// Finds the next top-level delimiter while ignoring commas/braces inside strings and nested values.
    private static func skipValue(
        _ bytes: UnsafeBufferPointer<UInt8>,
        from start: Int,
        end: Int
    ) -> Int? {
        JSONLineStructure.skipValue(bytes, from: start, end: end)
    }

    private static func skipWhitespace(
        _ bytes: UnsafeBufferPointer<UInt8>,
        cursor: inout Int,
        end: Int
    ) {
        JSONLineStructure.skipWhitespace(bytes, cursor: &cursor, end: end)
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        JSONLineStructure.isWhitespace(byte)
    }

    private static func ascii(_ character: Character) -> UInt8 {
        JSONLineStructure.ascii(character)
    }
}
