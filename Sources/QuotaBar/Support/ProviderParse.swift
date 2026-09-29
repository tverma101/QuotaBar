import Foundation

/// Shared, behavior-free parsing chores used by more than one provider. Consolidated here so a new
/// provider reuses the same JSON/number/percent handling instead of copying it.
enum ProviderParse {
    /// Decode a top-level JSON object from raw response data. An empty body is a silent `nil` (the
    /// common no-content case callers tolerate); a non-empty body that fails to parse is logged at
    /// the boundary so a malformed external-API response (HTML error page, truncated/garbled JSON)
    /// leaves a diagnostic instead of vanishing into an indistinguishable `nil`. A valid-but-non-object
    /// payload (e.g. a JSON array) returns `nil` without a log — it parsed fine, it just isn't an object.
    static func jsonObject(_ data: Data) -> [String: Any]? {
        guard !data.isEmpty else { return nil }
        do {
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            AppLog.warn(.http, "response body is not valid JSON (\(data.count) bytes): \(error.localizedDescription)")
            return nil
        }
    }

    /// Permissive numeric read: accepts JSON numbers and numeric strings, rejecting booleans and
    /// non-finite values. `JSONSerialization` bridges booleans through `NSNumber`, so the Core
    /// Foundation type check is required to keep `true`/`false` from becoming `1`/`0`.
    static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let doubleValue = number.doubleValue
            return doubleValue.isFinite ? doubleValue : nil
        }
        if let string = value as? String {
            let doubleValue = Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
            return doubleValue?.isFinite == true ? doubleValue : nil
        }
        return nil
    }

    /// Bounded integer read for counts parsed out of provider payloads.
    ///
    /// `number` deliberately only rejects non-finite values, so it happily returns `1e30` — and every
    /// `Int(someDouble)` on that traps with a fatal error, not a nil. A single malformed token count in
    /// a session log therefore killed the whole menu-bar process (SIGTRAP) mid-refresh, which is the worst
    /// possible failure for a background app: the payload is untrusted, and the cost of being wrong is
    /// an unrecoverable crash rather than a wrong number.
    ///
    /// Clamps into `lower...upper` instead. A count that large is not representable, so saturating to the
    /// bound keeps the day total finite and lets the row render; a token count is never meaningfully
    /// negative, hence the default floor of zero.
    static func int(
        _ value: Any?,
        default fallback: Int = 0,
        lower: Int = 0,
        upper: Int = .max
    ) -> Int {
        guard let double = number(value) else { return fallback }
        return intFromClampedDouble(double, lower: lower, upper: upper)
    }

    /// `Int(exactly:)`-style conversion that saturates rather than trapping. Compares against
    /// `Double(lowerBound)`/`Double(upperBound)`, and handles the `Double(Int.max)` rounding trap: that
    /// value rounds *up* to 2^63, so a naive `<=` guard lets exactly 2^63 through and the conversion then
    /// traps. Comparing in the clamped domain first is what makes the boundary safe.
    static func intFromClampedDouble(
        _ double: Double,
        lower: Int = 0,
        upper: Int = .max
    ) -> Int {
        if double.isNaN { return lower }
        if double <= Double(lower) { return lower }
        if double >= Double(upper) { return upper }
        // Inside the representable range, so the conversion is exact. `rounded(.down)` mirrors how a
        // count is read: 3.9 tokens is three tokens, and a negative slip cannot round away from zero.
        return Int(double.rounded(.down))
    }

    /// Saturating addition. `Int` overflow is a trap, and token arithmetic sums attacker-controlled
    /// counts: a line with `input_tokens` at `Int.max` plus any output overflowed and killed the process.
    static func addingSaturating(_ lhs: Int, _ rhs: Int, cap: Int = .max) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? cap : sum
    }

    /// Permissive boolean read for `JSONSerialization` output: accepts real `Bool`s, numeric `NSNumber`s
    /// (nonzero → true, via `boolValue`), and the strings "true"/"1"/"false"/"0" (case-insensitive).
    /// Returns `nil` for anything else, so an absent or unrecognized field stays distinguishable from an
    /// explicit false. `Bool` is tried before `NSNumber` so a JSON `0`/`1` bridges the same way either path.
    static func bool(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String {
            switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1": return true
            case "false", "0": return false
            default: return nil
            }
        }
        return nil
    }

    /// Clamp a percentage into 0...100, treating non-finite input as 0.
    static func clampPercent(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 100)
    }

    /// Convert integer cents to dollars: snap to whole cents, then scale. Inputs are already integer
    /// cents from the providers' APIs; rounding guards against float drift before the divide.
    static func centsToDollars(_ cents: Double) -> Double {
        cents.rounded() / 100
    }

    /// Decode `T` from JSON text, falling back to a hex-encoded JSON blob — some providers store their
    /// credentials/auth file as hex (optionally `0x`-prefixed) rather than plain JSON.
    static func decodeJSONWithHexFallback<T: Decodable>(_ text: String, as type: T.Type) -> T? {
        if let decoded = decodeJSON(text, as: type) { return decoded }

        var hex = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("0x") || hex.hasPrefix("0X") {
            hex = String(hex.dropFirst(2))
        }
        guard !hex.isEmpty, hex.count.isMultiple(of: 2), hex.allSatisfy(\.isHexDigit) else {
            return nil
        }

        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        guard let decoded = String(bytes: bytes, encoding: .utf8) else { return nil }
        return decodeJSON(decoded, as: type)
    }

    private static func decodeJSON<T: Decodable>(_ text: String, as type: T.Type) -> T? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// Decode a JWT's payload (the middle dot-separated segment) as a JSON object. Base64url is
    /// translated to standard base64 and padded before decoding.
    static func jwtPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while !payload.count.isMultiple(of: 4) {
            payload.append("=")
        }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return json
    }

    /// Unwrap a `go-keyring-base64:`-prefixed value — how Go tools (`gh`, `agy`) store secrets in the
    /// macOS Keychain — returning the decoded string. A value without the prefix is returned trimmed
    /// as-is; an empty result is `nil`. Shared by every provider that reads a go-keyring-stored token.
    static func unwrapGoKeyring(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "go-keyring-base64:"
        if text.hasPrefix(prefix) {
            let encoded = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = Data(base64Encoded: encoded),
                  let decoded = String(data: data, encoding: .utf8)
            else {
                return nil
            }
            text = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.nilIfEmpty
    }
}

extension String {
    /// Percent-encode one `application/x-www-form-urlencoded` value. Only the ASCII characters
    /// RFC 3986 defines as unreserved pass through; spaces use `%20` so a literal `+` remains
    /// distinguishable from a form-space separator.
    var urlFormEncoded: String {
        var encoded = ""
        encoded.reserveCapacity(utf8.count)

        for byte in utf8 {
            switch byte {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2D, 0x2E, 0x5F, 0x7E:
                encoded.append(Character(UnicodeScalar(byte)))
            default:
                encoded.append(String(format: "%%%02X", byte))
            }
        }
        return encoded
    }

    /// `nil` when the string is empty, otherwise the string itself — for treating "" as "missing".
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }

    /// Drop any trailing slashes, for joining base URLs and paths.
    var trimmingTrailingSlashes: String {
        var copy = self
        while copy.hasSuffix("/") {
            copy.removeLast()
        }
        return copy
    }

    /// Title-case a provider plan name: split on `isSeparator`, upper-case each word's first character,
    /// and re-join with single spaces. When `lowercasingTail` is true the rest of each word is
    /// lower-cased (e.g. "PRO PLAN" → "Pro Plan"); otherwise it's preserved (e.g. "pro_plus" → "Pro Plus").
    func titleCased(separator isSeparator: (Character) -> Bool, lowercasingTail: Bool = false) -> String {
        split(whereSeparator: isSeparator)
            .map { word in
                let head = word.prefix(1).uppercased()
                let tail = lowercasingTail ? word.dropFirst().lowercased() : String(word.dropFirst())
                return head + tail
            }
            .joined(separator: " ")
    }
}
