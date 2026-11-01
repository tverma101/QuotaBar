import Foundation

/// Allocation-free structural validation for JSONL values that callers do not need to decode.
/// Keeping unknown metadata on this path avoids materializing a Foundation object tree per event.
enum JSONLineStructure {
    struct StringToken {
        var content: Range<Int>
        var next: Int
        var hasEscapes: Bool
    }

    static func scanString(
        _ bytes: UnsafeBufferPointer<UInt8>,
        openingQuote: Int,
        end: Int
    ) -> StringToken? {
        guard openingQuote < end, bytes[openingQuote] == ascii("\"") else { return nil }
        var cursor = openingQuote + 1
        var hasEscapes = false
        while cursor < end {
            let byte = bytes[cursor]
            if byte == ascii("\"") {
                return StringToken(content: (openingQuote + 1)..<cursor, next: cursor + 1, hasEscapes: hasEscapes)
            }
            if byte == ascii("\\") {
                hasEscapes = true
                cursor += 1
                guard cursor < end else { return nil }
                switch bytes[cursor] {
                case ascii("\""), ascii("\\"), ascii("/"), ascii("b"), ascii("f"), ascii("n"), ascii("r"), ascii("t"):
                    cursor += 1
                case ascii("u"):
                    guard cursor + 4 < end else { return nil }
                    for index in (cursor + 1)...(cursor + 4) where !isHexDigit(bytes[index]) { return nil }
                    cursor += 5
                default:
                    return nil
                }
                continue
            }
            guard byte >= 0x20 else { return nil }
            if byte < 0x80 {
                cursor += 1
                continue
            }
            guard let width = validUTF8Width(bytes, at: cursor, end: end) else { return nil }
            cursor += width
        }
        return nil
    }

    /// Returns the first byte after one complete JSON value. Nesting is bounded to reject pathological
    /// metadata without consuming unbounded stack; event objects are otherwise accepted by JSON rules.
    static func skipValue(
        _ bytes: UnsafeBufferPointer<UInt8>,
        from start: Int,
        end: Int
    ) -> Int? {
        var cursor = start
        skipWhitespace(bytes, cursor: &cursor, end: end)
        guard parseValue(bytes, cursor: &cursor, end: end, depth: 0) else { return nil }
        return cursor
    }

    static func skipWhitespace(
        _ bytes: UnsafeBufferPointer<UInt8>,
        cursor: inout Int,
        end: Int
    ) {
        while cursor < end, isWhitespace(bytes[cursor]) { cursor += 1 }
    }

    static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    static func ascii(_ character: Character) -> UInt8 {
        character.asciiValue!
    }

    private static func parseValue(
        _ bytes: UnsafeBufferPointer<UInt8>,
        cursor: inout Int,
        end: Int,
        depth: Int
    ) -> Bool {
        guard cursor < end, depth <= 128 else { return false }
        switch bytes[cursor] {
        case ascii("\""):
            guard let token = scanString(bytes, openingQuote: cursor, end: end) else { return false }
            cursor = token.next
            return true
        case ascii("{"):
            cursor += 1
            skipWhitespace(bytes, cursor: &cursor, end: end)
            if cursor < end, bytes[cursor] == ascii("}") {
                cursor += 1
                return true
            }
            while cursor < end {
                guard bytes[cursor] == ascii("\""),
                      let key = scanString(bytes, openingQuote: cursor, end: end) else { return false }
                cursor = key.next
                skipWhitespace(bytes, cursor: &cursor, end: end)
                guard cursor < end, bytes[cursor] == ascii(":") else { return false }
                cursor += 1
                skipWhitespace(bytes, cursor: &cursor, end: end)
                guard parseValue(bytes, cursor: &cursor, end: end, depth: depth + 1) else { return false }
                skipWhitespace(bytes, cursor: &cursor, end: end)
                guard cursor < end else { return false }
                if bytes[cursor] == ascii("}") {
                    cursor += 1
                    return true
                }
                guard bytes[cursor] == ascii(",") else { return false }
                cursor += 1
                skipWhitespace(bytes, cursor: &cursor, end: end)
                guard cursor < end, bytes[cursor] != ascii("}") else { return false }
            }
            return false
        case ascii("["):
            cursor += 1
            skipWhitespace(bytes, cursor: &cursor, end: end)
            if cursor < end, bytes[cursor] == ascii("]") {
                cursor += 1
                return true
            }
            while cursor < end {
                guard parseValue(bytes, cursor: &cursor, end: end, depth: depth + 1) else { return false }
                skipWhitespace(bytes, cursor: &cursor, end: end)
                guard cursor < end else { return false }
                if bytes[cursor] == ascii("]") {
                    cursor += 1
                    return true
                }
                guard bytes[cursor] == ascii(",") else { return false }
                cursor += 1
                skipWhitespace(bytes, cursor: &cursor, end: end)
                guard cursor < end, bytes[cursor] != ascii("]") else { return false }
            }
            return false
        case ascii("t"):
            return consumeLiteral(bytes, cursor: &cursor, end: end, literal: "true")
        case ascii("f"):
            return consumeLiteral(bytes, cursor: &cursor, end: end, literal: "false")
        case ascii("n"):
            return consumeLiteral(bytes, cursor: &cursor, end: end, literal: "null")
        default:
            return skipNumber(bytes, cursor: &cursor, end: end)
        }
    }

    private static func consumeLiteral(
        _ bytes: UnsafeBufferPointer<UInt8>,
        cursor: inout Int,
        end: Int,
        literal: StaticString
    ) -> Bool {
        literal.withUTF8Buffer { expected in
            guard cursor + expected.count <= end else { return false }
            for offset in 0..<expected.count where bytes[cursor + offset] != expected[offset] { return false }
            cursor += expected.count
            return true
        }
    }

    private static func skipNumber(
        _ bytes: UnsafeBufferPointer<UInt8>,
        cursor: inout Int,
        end: Int
    ) -> Bool {
        let start = cursor
        if cursor < end, bytes[cursor] == ascii("-") { cursor += 1 }
        guard cursor < end else { return false }
        if bytes[cursor] == ascii("0") {
            cursor += 1
            if cursor < end, isDigit(bytes[cursor]) { return false }
        } else {
            guard (ascii("1")...ascii("9")).contains(bytes[cursor]) else { return false }
            while cursor < end, isDigit(bytes[cursor]) { cursor += 1 }
        }
        if cursor < end, bytes[cursor] == ascii(".") {
            cursor += 1
            let fractionStart = cursor
            while cursor < end, isDigit(bytes[cursor]) { cursor += 1 }
            guard cursor > fractionStart else { return false }
        }
        if cursor < end, (bytes[cursor] == ascii("e") || bytes[cursor] == ascii("E")) {
            cursor += 1
            if cursor < end, (bytes[cursor] == ascii("+") || bytes[cursor] == ascii("-")) { cursor += 1 }
            let exponentStart = cursor
            while cursor < end, isDigit(bytes[cursor]) { cursor += 1 }
            guard cursor > exponentStart else { return false }
        }
        return cursor > start
    }

    private static func validUTF8Width(
        _ bytes: UnsafeBufferPointer<UInt8>,
        at index: Int,
        end: Int
    ) -> Int? {
        let first = bytes[index]
        func continuation(_ offset: Int, in range: ClosedRange<UInt8> = 0x80...0xBF) -> Bool {
            index + offset < end && range.contains(bytes[index + offset])
        }
        switch first {
        case 0xC2...0xDF:
            return continuation(1) ? 2 : nil
        case 0xE0:
            return continuation(1, in: 0xA0...0xBF) && continuation(2) ? 3 : nil
        case 0xE1...0xEC, 0xEE...0xEF:
            return continuation(1) && continuation(2) ? 3 : nil
        case 0xED:
            return continuation(1, in: 0x80...0x9F) && continuation(2) ? 3 : nil
        case 0xF0:
            return continuation(1, in: 0x90...0xBF) && continuation(2) && continuation(3) ? 4 : nil
        case 0xF1...0xF3:
            return continuation(1) && continuation(2) && continuation(3) ? 4 : nil
        case 0xF4:
            return continuation(1, in: 0x80...0x8F) && continuation(2) && continuation(3) ? 4 : nil
        default:
            return nil
        }
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        (ascii("0")...ascii("9")).contains(byte)
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        isDigit(byte) || (ascii("a")...ascii("f")).contains(byte) || (ascii("A")...ascii("F")).contains(byte)
    }
}
