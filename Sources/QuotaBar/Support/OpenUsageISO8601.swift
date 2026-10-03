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
            return fractionalFormatter.date(from: value)
        }
        if hasCanonicalUTCShape(value, fractional: false) {
            return plainFormatter.date(from: value)
        }
        let normalized = normalizeTimestamp(value)
        return formatter(fractionalSeconds: true).date(from: normalized) ??
        formatter(fractionalSeconds: false).date(from: normalized)
    }

    /// CodexRouter and several local ledgers emit this exact shape for every event. Accept it without
    /// regex normalization; malformed dates are still rejected by ISO8601DateFormatter below.
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
