import Foundation

/// Single-pass parser for CodexRouter's flat JSONL event objects. Keeping field discovery in one walk
/// avoids searching the whole line once per property, which is expensive for large ledgers containing
/// optional metadata or opaque payload strings.
enum CodexRouterEventLineParser {
    /// Reuses parsed event times within one file read without retaining unbounded ledger history.
    /// Router logs often repeat a timestamp across related rows; the cap keeps high-cardinality logs
    /// from turning this optimization into another growing cache.
    struct TimestampCache: Sendable {
        private let capacity: Int
        private var dates: [String: Date] = [:]

        init(capacity: Int = 2_048) {
            precondition(capacity > 0)
            self.capacity = capacity
        }

        var cachedTimestampCount: Int { dates.count }

        mutating func date(from value: String) -> Date? {
            if let cached = dates[value] { return cached }
            guard let parsed = OpenUsageISO8601.date(from: value) else { return nil }
            if dates.count < capacity {
                dates[value] = parsed
            }
            return parsed
        }
    }

    private enum Field {
        case at
        case model
        case provider
        case status
        case inputTokens
        case cachedInputTokens
        case outputTokens
        case reasoningTokens
        case totalTokens
        case accountId
        case accountFingerprint
        case serviceTier
    }

    private struct Fields {
        var at: String?
        var model: String?
        var provider: String?
        var status: Int?
        var inputTokens: Int?
        var cachedInputTokens: Int?
        var outputTokens: Int?
        var reasoningTokens: Int?
        var totalTokens: Int?
        var accountId: String?
        var accountFingerprint: String?
        var serviceTier: String?

        mutating func set(_ field: Field, string: String) {
            switch field {
            case .at: at = string
            case .model: model = string
            case .provider: provider = string
            case .accountId: accountId = string
            case .accountFingerprint: accountFingerprint = string
            case .serviceTier: serviceTier = string
            case .status, .inputTokens, .cachedInputTokens, .outputTokens, .reasoningTokens, .totalTokens:
                break
            }
        }

        mutating func set(_ field: Field, integer: Int) {
            switch field {
            case .status: status = integer
            case .inputTokens: inputTokens = integer
            case .cachedInputTokens: cachedInputTokens = integer
            case .outputTokens: outputTokens = integer
            case .reasoningTokens: reasoningTokens = integer
            case .totalTokens: totalTokens = integer
            case .at, .model, .provider, .accountId, .accountFingerprint, .serviceTier:
                break
            }
        }
    }

    private struct StringToken {
        var content: Range<Int>
        var next: Int
        var hasEscapes: Bool
    }

    static func parse(_ line: Data.SubSequence) -> CodexRouterUsageScanner.Event? {
        var timestampCache = TimestampCache()
        return parse(line, timestampCache: &timestampCache)
    }

    static func parse(
        _ line: Data.SubSequence,
        timestampCache: inout TimestampCache
    ) -> CodexRouterUsageScanner.Event? {
        line.withUnsafeBytes { rawBytes in
            parse(rawBytes.bindMemory(to: UInt8.self), timestampCache: &timestampCache)
        }
    }

    private static func parse(
        _ bytes: UnsafeBufferPointer<UInt8>,
        timestampCache: inout TimestampCache
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
        var cursor = objectStart + 1
        while cursor < objectEnd {
            skipWhitespace(bytes, cursor: &cursor, end: objectEnd)
            if cursor == objectEnd { break }
            guard bytes[cursor] == ascii("\""),
                  let keyToken = scanString(bytes, openingQuote: cursor, end: objectEnd)
            else { return nil }
            let field = field(for: bytes, key: keyToken.content, escaped: keyToken.hasEscapes)
            cursor = keyToken.next
            skipWhitespace(bytes, cursor: &cursor, end: objectEnd)
            guard cursor < objectEnd, bytes[cursor] == ascii(":") else { return nil }
            cursor += 1
            skipWhitespace(bytes, cursor: &cursor, end: objectEnd)
            guard cursor < objectEnd else { return nil }

            let valueStart = cursor
            if let field, isStringField(field), bytes[cursor] == ascii("\"") {
                guard let token = scanString(bytes, openingQuote: cursor, end: objectEnd) else { return nil }
                if let value = decodeString(bytes, token: token, openingQuote: cursor) {
                    fields.set(field, string: value)
                }
                cursor = token.next
            } else if let field, isIntegerField(field),
                      let value = parseInteger(bytes, start: cursor, end: objectEnd) {
                fields.set(field, integer: value)
                cursor = skipValue(bytes, from: valueStart, end: objectEnd)
            } else {
                cursor = skipValue(bytes, from: valueStart, end: objectEnd)
            }

            skipWhitespace(bytes, cursor: &cursor, end: objectEnd)
            if cursor == objectEnd { break }
            guard cursor < objectEnd else { return nil }
            if bytes[cursor] == ascii(",") {
                cursor += 1
            } else {
                return nil
            }
        }

        guard cursor == objectEnd else { return nil }
        let timestampString = fields.at?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let timestampString,
              let timestamp = timestampCache.date(from: timestampString) else { return nil }

        let model = fields.model?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
            ?? ModelUsageEntry.unattributedModelName
        let provider = fields.provider?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
            ?? "unknown"
        return CodexRouterUsageScanner.Event(
            timestamp: timestamp,
            model: model,
            provider: provider,
            status: fields.status ?? 0,
            inputTokens: max(0, fields.inputTokens ?? 0),
            cachedInputTokens: max(0, fields.cachedInputTokens ?? 0),
            outputTokens: max(0, fields.outputTokens ?? 0),
            reasoningTokens: max(0, fields.reasoningTokens ?? 0),
            totalTokens: fields.totalTokens.map { max(0, $0) },
            accountId: fields.accountId?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty,
            accountFingerprint: fields.accountFingerprint?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty,
            serviceTier: fields.serviceTier?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty?
                .lowercased()
        )
    }

    private static func field(
        for bytes: UnsafeBufferPointer<UInt8>,
        key: Range<Int>,
        escaped: Bool
    ) -> Field? {
        guard !escaped else { return nil }
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
        default: break
        }
        return nil
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
        case .status, .inputTokens, .cachedInputTokens, .outputTokens, .reasoningTokens, .totalTokens: return false
        }
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
        var cursor = openingQuote + 1
        var escaped = false
        var hasEscapes = false
        while cursor < end {
            let byte = bytes[cursor]
            if escaped {
                escaped = false
            } else if byte == ascii("\\") {
                escaped = true
                hasEscapes = true
            } else if byte == ascii("\"") {
                return StringToken(content: (openingQuote + 1)..<cursor, next: cursor + 1, hasEscapes: hasEscapes)
            }
            cursor += 1
        }
        return nil
    }

    private static func decodeString(
        _ bytes: UnsafeBufferPointer<UInt8>,
        token: StringToken,
        openingQuote: Int
    ) -> String? {
        guard token.hasEscapes else {
            return String(decoding: bytes[token.content], as: UTF8.self)
        }
        let quoted = Data(bytes[openingQuote..<token.next])
        let wrapped = Data([ascii("[")]) + quoted + Data([ascii("]")])
        return ((try? JSONSerialization.jsonObject(with: wrapped)) as? [String])?.first
    }

    private static func parseInteger(
        _ bytes: UnsafeBufferPointer<UInt8>,
        start: Int,
        end: Int
    ) -> Int? {
        var cursor = start
        var negative = false
        if cursor < end, bytes[cursor] == ascii("-") {
            negative = true
            cursor += 1
        }
        let ceiling = 1_000_000_000_000_000
        var value = 0
        var saturated = false
        var sawDigit = false
        while cursor < end {
            let byte = bytes[cursor]
            guard byte >= ascii("0"), byte <= ascii("9") else { break }
            sawDigit = true
            if !saturated {
                let digit = Int(byte - ascii("0"))
                if value > (ceiling - digit) / 10 {
                    value = ceiling
                    saturated = true
                } else {
                    value = value * 10 + digit
                }
            }
            cursor += 1
        }
        guard sawDigit else { return nil }
        return negative ? -value : value
    }

    /// Finds the next top-level delimiter while ignoring commas/braces inside strings and nested values.
    private static func skipValue(
        _ bytes: UnsafeBufferPointer<UInt8>,
        from start: Int,
        end: Int
    ) -> Int {
        var cursor = start
        var objectDepth = 0
        var arrayDepth = 0
        var inString = false
        var escaped = false
        while cursor < end {
            let byte = bytes[cursor]
            if inString {
                if escaped {
                    escaped = false
                } else if byte == ascii("\\") {
                    escaped = true
                } else if byte == ascii("\"") {
                    inString = false
                }
            } else {
                switch byte {
                case ascii("\""):
                    inString = true
                case ascii("{"):
                    objectDepth += 1
                case ascii("}"):
                    if objectDepth == 0 && arrayDepth == 0 { return cursor }
                    objectDepth -= 1
                case ascii("["):
                    arrayDepth += 1
                case ascii("]"):
                    arrayDepth -= 1
                case ascii(",") where objectDepth == 0 && arrayDepth == 0:
                    return cursor
                default:
                    break
                }
            }
            cursor += 1
        }
        return cursor
    }

    private static func skipWhitespace(
        _ bytes: UnsafeBufferPointer<UInt8>,
        cursor: inout Int,
        end: Int
    ) {
        while cursor < end, isWhitespace(bytes[cursor]) {
            cursor += 1
        }
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    private static func ascii(_ character: Character) -> UInt8 {
        character.asciiValue!
    }
}
