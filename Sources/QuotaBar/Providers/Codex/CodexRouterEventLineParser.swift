import Foundation

/// Single-pass parser for CodexRouter's flat JSONL event objects. Keeping field discovery in one walk
/// avoids searching the whole line once per property, which is expensive for large ledgers containing
/// optional metadata or opaque payload strings.
enum CodexRouterEventLineParser {
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

        mutating func clear(_ field: Field) {
            switch field {
            case .at: at = nil
            case .model: model = nil
            case .provider: provider = nil
            case .status: status = nil
            case .inputTokens: inputTokens = nil
            case .cachedInputTokens: cachedInputTokens = nil
            case .outputTokens: outputTokens = nil
            case .reasoningTokens: reasoningTokens = nil
            case .totalTokens: totalTokens = nil
            case .accountId: accountId = nil
            case .accountFingerprint: accountFingerprint = nil
            case .serviceTier: serviceTier = nil
            }
        }
    }

    private typealias StringToken = JSONLineStructure.StringToken

    private struct ParsedInteger {
        var value: Int
        var next: Int
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
                cursor = parsed.next
            } else {
                guard let next = skipValue(bytes, from: valueStart, end: objectEnd) else { return nil }
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
              let timestamp = timestampCache.date(from: timestampString, cacheable: cacheableTimestamp) else { return nil }

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
        if needsFloatingPointConversion {
            guard let text = String(bytes: bytes[start..<numberEnd], encoding: .utf8),
                  let number = Double(text), !number.isNaN else { return nil }
            if number.isInfinite {
                value = negative ? -ceiling : ceiling
            } else {
                value = Int(max(-Double(ceiling), min(Double(ceiling), number.rounded(.down))))
            }
        } else {
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
        }
        return ParsedInteger(value: value, next: numberEnd)
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
