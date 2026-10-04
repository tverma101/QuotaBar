import Foundation

/// Shared ISO-8601 date parsing/formatting used by multiple providers and the local API. Normalizes
/// the various timestamp shapes providers return (space-separated, " UTC" suffix, variable fractional
/// digits) before parsing.
enum OpenUsageISO8601 {
    // Timestamp normalization runs once per parsed usage row. Keep these immutable patterns compiled
    // across refreshes instead of asking String.range(of:options:.regularExpression) to compile them
    // again for every event.
    private static let spaceSeparatedTimestampRegex = try! NSRegularExpression(
        pattern: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}"#
    )
    private static let zonedISOTimestampRegex = try! NSRegularExpression(
        pattern: #"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(\.\d+)?(Z|[+-]\d{2}:\d{2})$"#
    )
    private static let utcISOTimestampRegex = try! NSRegularExpression(
        pattern: #"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(\.\d+)?$"#
    )
    private static let fractionalTimestampRegex = try! NSRegularExpression(
        pattern: #"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(\.\d+)?(Z|[+-]\d{2}:\d{2})?$"#
    )

    static func string(from date: Date) -> String {
        formatter(fractionalSeconds: true).string(from: date)
    }

    static func date(from value: String) -> Date? {
        if hasCanonicalUTCShape(value, fractional: true) {
            return parseCanonicalUTC(value, fractional: true)
        }
        if hasCanonicalUTCShape(value, fractional: false) {
            return parseCanonicalUTC(value, fractional: false)
        }
        let normalized = normalizeTimestamp(value)
        return formatter(fractionalSeconds: true).date(from: normalized) ??
        formatter(fractionalSeconds: false).date(from: normalized)
    }

    /// CodexRouter and several local ledgers emit this exact shape for every event. Accept it without
    /// regex normalization, then validate the Gregorian calendar fields in the direct parser below.
    private static func hasCanonicalUTCShape(_ value: String, fractional: Bool) -> Bool {
        value.utf8.withContiguousStorageIfAvailable { bytes in
            let expectedCount = fractional ? 24 : 20
            guard bytes.count == expectedCount,
                  bytes[4] == 45, bytes[7] == 45, bytes[10] == 84,
                  bytes[13] == 58, bytes[16] == 58,
                  bytes[expectedCount - 1] == 90
            else { return false }

            for index in 0..<(expectedCount - 1) {
                if index == 4 || index == 7 || index == 10 || index == 13 || index == 16 ||
                    (fractional && index == 19) {
                    continue
                }
                guard (48...57).contains(bytes[index]) else { return false }
            }
            if fractional {
                guard bytes[19] == 46,
                      (20...22).allSatisfy({ (48...57).contains(bytes[$0]) })
                else { return false }
            }
            return true
        } ?? false
    }

    /// Avoids the ISO8601DateFormatter cost for the exact UTC shapes emitted by CodexRouter and
    /// JavaScript's `Date.toISOString()`. Unusual but well-shaped values fall back to Foundation.
    private static func parseCanonicalUTC(_ value: String, fractional: Bool) -> Date? {
        value.utf8.withContiguousStorageIfAvailable { bytes -> Date? in
            func number(_ range: Range<Int>) -> Int {
                range.reduce(into: 0) { result, index in
                    result = result * 10 + Int(bytes[index] - 48)
                }
            }

            let year = number(0..<4)
            let month = number(5..<7)
            let day = number(8..<10)
            let hour = number(11..<13)
            let minute = number(14..<16)
            let second = number(17..<19)
            guard year > 0, (1...12).contains(month), hour < 24,
                  minute < 60, second < 60
            else { return nil }

            let isLeapYear = year.isMultiple(of: 4) && (!year.isMultiple(of: 100) || year.isMultiple(of: 400))
            let maximumDay: Int
            switch month {
            case 2: maximumDay = isLeapYear ? 29 : 28
            case 4, 6, 9, 11: maximumDay = 30
            default: maximumDay = 31
            }
            guard (1...maximumDay).contains(day) else { return nil }

            // Proleptic Gregorian days since 1970-01-01 (Howard Hinnant's civil-date transform).
            let adjustedYear = year - (month <= 2 ? 1 : 0)
            let era = adjustedYear / 400
            let yearOfEra = adjustedYear - era * 400
            let adjustedMonth = month + (month > 2 ? -3 : 9)
            let dayOfYear = (153 * adjustedMonth + 2) / 5 + day - 1
            let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
            let daysSinceEpoch = era * 146_097 + dayOfEra - 719_468
            let wholeSeconds = daysSinceEpoch * 86_400 + hour * 3_600 + minute * 60 + second
            let milliseconds = fractional ? number(20..<23) : 0
            return Date(timeIntervalSince1970: Double(wholeSeconds) + Double(milliseconds) / 1_000)
        } ?? nil
    }

    /// Aligns with the JavaScript plugin `ctx.util.toIso` string normalization (Claude `resets_at`, etc.).
    private static func normalizeTimestamp(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return s }

        if s.contains(" "),
           let range = regexRange(spaceSeparatedTimestampRegex, in: s) {
            s.replaceSubrange(range, with: s[range].replacingOccurrences(of: " ", with: "T"))
        }
        if s.hasSuffix(" UTC") {
            s = String(s.dropLast(4)) + "Z"
        }

        if let match = regexRange(zonedISOTimestampRegex, in: s) {
            let matched = String(s[match])
            return normalizeFractionalISO(matched, assumeUTC: false)
        }
        if let match = regexRange(utcISOTimestampRegex, in: s) {
            let matched = String(s[match])
            return normalizeFractionalISO(matched, assumeUTC: true)
        }

        return s
    }

    private static func normalizeFractionalISO(_ value: String, assumeUTC: Bool) -> String {
        guard let match = fractionalTimestampRegex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              match.numberOfRanges >= 2,
              let headRange = Range(match.range(at: 1), in: value)
        else {
            return assumeUTC && !value.hasSuffix("Z") ? value + "Z" : value
        }

        let head = String(value[headRange])
        var frac = ""
        if match.numberOfRanges > 2, match.range(at: 2).location != NSNotFound,
           let fracRange = Range(match.range(at: 2), in: value) {
            var digits = String(value[fracRange]).dropFirst()
            if digits.count > 3 {
                digits = digits.prefix(3)
            }
            while digits.count < 3 {
                digits.append("0")
            }
            frac = ".\(digits)"
        }

        var tz = "Z"
        if !assumeUTC, match.numberOfRanges > 3, match.range(at: 3).location != NSNotFound,
           let tzRange = Range(match.range(at: 3), in: value) {
            tz = String(value[tzRange])
        }

        return head + frac + tz
    }

    private static func regexRange(_ regex: NSRegularExpression, in value: String) -> Range<String.Index>? {
        guard let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else {
            return nil
        }
        return Range(match.range, in: value)
    }

    // ISO8601DateFormatter is expensive to construct and is hit on every snapshot decode and local-API
    // encode, so the two fixed configurations are built once. `ISO8601DateFormatter` is thread-safe for
    // parsing/formatting, and parsing here runs on the main-actor refresh path; `nonisolated(unsafe)`
    // shares the immutable instances without per-call allocation.
    private nonisolated(unsafe) static let fractionalFormatter = makeFormatter(fractionalSeconds: true)
    private nonisolated(unsafe) static let plainFormatter = makeFormatter(fractionalSeconds: false)

    private static func formatter(fractionalSeconds: Bool) -> ISO8601DateFormatter {
        fractionalSeconds ? fractionalFormatter : plainFormatter
    }

    private static func makeFormatter(fractionalSeconds: Bool) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = fractionalSeconds
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter
    }
}
