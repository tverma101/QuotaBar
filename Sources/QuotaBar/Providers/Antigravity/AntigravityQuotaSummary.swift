import Foundation

extension AntigravityUsageMapper {
    static func hasAllSharedQuotaMeters(_ data: Data, sourceID: String) -> Bool {
        guard let result = parseQuotaSummaryResult(data, sourceID: sourceID) else { return false }
        let labels = Set(result.lines.map(\.label))
        return summaryBuckets.allSatisfy { labels.contains($0.label) }
    }

    /// Keep the first usable value for a meter across hosts. Duplicates within one body still use the
    /// conservative parser policy. Only wholly readable responses can clear old omitted limits.
    static func parseQuotaSummariesResult(_ bodies: [Data], allHostsAnswered: Bool) -> QuotaSummaryResult? {
        let results = bodies.enumerated().compactMap { index, body in
            parseQuotaSummaryResult(body, sourceID: "cloud-code-\(index)")
        }
        guard !results.isEmpty else { return nil }
        var firstByLabel: [String: MetricLine] = [:]
        for result in results {
            for line in result.lines where firstByLabel[line.label] == nil { firstByLabel[line.label] = line }
        }
        let ordered = [AntigravityMetric.sessionLabel, AntigravityMetric.weeklyLabel,
                       AntigravityMetric.argonWeeklyLabel, AntigravityMetric.claudeLabel,
                       AntigravityMetric.claudeWeeklyLabel]
        return QuotaSummaryResult(
            lines: ordered.compactMap { firstByLabel[$0] },
            isComplete: allHostsAnswered && results.count == bodies.count && results.allSatisfy(\.isComplete)
        )
    }

    static let argonGroupName = "Gemini 4 Argon"

    /// An absent or explicitly disabled quota is authoritative. Ambiguous shapes retain last-good
    /// meters through the summary's existing completeness policy, rather than inventing a quota.
    static func argonWeeklyResult(_ groups: [QuotaSummaryGroup]) -> (line: MetricLine?, isComplete: Bool) {
        let groups = groups.filter { $0.displayName == argonGroupName }
        guard !groups.isEmpty else { return (nil, true) }
        guard groups.allSatisfy(\.hasBuckets) else { return (nil, false) }
        let buckets = groups.flatMap { $0.buckets ?? [] }
        guard !buckets.isEmpty else { return (nil, true) }
        let weekly = buckets.filter { $0.window == "weekly" }
        guard weekly.count == 1, let bucket = weekly.first,
              let id = bucket.bucketId?.nilIfEmpty,
              !summaryBuckets.contains(where: { $0.bucketID == id }),
              !bucket.hasInvalidDisabledFlag else { return (nil, false) }
        guard bucket.disabled != true else { return (nil, true) }
        guard let fraction = bucket.remainingFraction, fraction.isFinite else { return (nil, false) }
        return (
            line(pool: AntigravityMetric.argonWeeklyLabel, fraction: fraction,
                 resetTime: bucket.resetTime.flatMap { OpenUsageISO8601.date(from: $0) },
                 periodMs: MetricPeriod.weekMs),
            buckets.allSatisfy { $0.window == "weekly" || $0.window == "5h" }
        )
    }

    static func isArgonModel(label: String, modelID: String?) -> Bool {
        if modelID == "MODEL_PLACEHOLDER_M421" { return true }
        return [normalizeLabel(label), modelID ?? ""].contains { value in
            let normalized = value.lowercased().replacingOccurrences(of: " ", with: "-")
            return normalized == "gemini-4-argon" || normalized.hasPrefix("gemini-4-argon-")
        }
    }
}

/// `RetrieveUserQuotaSummary`, both envelopes: the LS wraps the payload in `{"response": {...}}`,
/// the remote Cloud Code endpoint returns it bare. Every field is optional — third-party parsers have
/// already regressed by assuming absent fields (defaulting a missing `remainingFraction` to "full").
struct QuotaSummaryEnvelope: Decodable {
    let response: QuotaSummaryRoot?
    let groups: [QuotaSummaryGroup]?
}

struct QuotaSummaryRoot: Decodable {
    let groups: [QuotaSummaryGroup]?
}

struct QuotaSummaryGroup: Decodable {
    let displayName: String?
    let buckets: [QuotaSummaryBucket]?

    /// Missing and explicit-null are schema gaps; an explicit empty array is an authoritative answer.
    let hasBuckets: Bool

    private enum CodingKeys: String, CodingKey {
        case displayName, buckets
    }

    init(from decoder: Decoder) throws {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        displayName = (try? container?.decodeIfPresent(String.self, forKey: .displayName)) ?? nil
        guard let container,
              container.contains(.buckets),
              (try? container.decodeNil(forKey: .buckets)) != true,
              let decodedBuckets = try? container.decode([QuotaSummaryBucket].self, forKey: .buckets)
        else {
            buckets = nil
            hasBuckets = false
            return
        }
        buckets = decodedBuckets
        hasBuckets = true
    }
}

/// A bucket that never fails its containing array: a malformed element (not an object, or a field of
/// the wrong type) decodes to nil fields instead of throwing the whole summary into the legacy
/// fallback. The mapper then drops the unusable bucket with a warning and keeps the rest.
struct QuotaSummaryBucket: Decodable {
    let bucketId: String?
    let remainingFraction: Double?
    let resetTime: String?
    let window: String?
    let disabled: Bool?
    let hasInvalidDisabledFlag: Bool

    private enum CodingKeys: String, CodingKey { case bucketId, remainingFraction, resetTime, window, disabled }

    init(from decoder: Decoder) {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        bucketId = container.flatMap { (try? $0.decodeIfPresent(String.self, forKey: .bucketId)) ?? nil }
        remainingFraction = container.flatMap { (try? $0.decodeIfPresent(Double.self, forKey: .remainingFraction)) ?? nil }
        resetTime = container.flatMap { (try? $0.decodeIfPresent(String.self, forKey: .resetTime)) ?? nil }
        window = container.flatMap { (try? $0.decodeIfPresent(String.self, forKey: .window)) ?? nil }
        do {
            disabled = try container?.decodeIfPresent(Bool.self, forKey: .disabled)
            hasInvalidDisabledFlag = false
        } catch {
            disabled = nil
            hasInvalidDisabledFlag = true
        }
    }
}

