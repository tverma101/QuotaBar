import Foundation

/// Self-serve Devin Desktop and CLI extra-usage rates from https://docs.devin.ai/desktop/models.
/// The records are timestamped, so historical calls keep the rates in effect when they ran.
enum DevinNativePricing: String {
    case swe2 = "swe-2"
    case flash = "swe-2-flash"
    case swe21 = "swe-2-1"
    case ultrafast = "swe-2-1-ultrafast"

    private static let efforts: Set<Substring> = ["low", "medium", "high", "xhigh", "max"]

    init?(model: String) {
        let key = PricingCatalog.normalizedKey(
            model.lowercased().replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "")
        )
        if let exact = Self(rawValue: key) {
            self = exact
            return
        }
        guard let dash = key.lastIndex(of: "-"), Self.efforts.contains(key[key.index(after: dash)...]),
              let model = Self(rawValue: String(key[..<dash])) else { return nil }
        self = model
    }

    var canonicalName: String {
        switch self {
        case .swe2, .flash: rawValue
        case .swe21: "swe-2.1"
        case .ultrafast: "swe-2.1-ultrafast"
        }
    }

    func estimate(tokens: TokenBreakdown, at timestamp: Date) -> Double? {
        switch self {
        case .swe2:
            guard timestamp >= Self.swe2DocumentedRates else { return nil }
            if timestamp < Self.swe2Promo { return 0 }
            let price = timestamp < Self.swe2List ? Self.promo : Self.swe2Regular
            return price.estimate(tokens)
        case .flash:
            guard timestamp >= Self.flashLaunch else { return nil }
            if timestamp < Self.flashList { return 0 }
            return Self.flashRegular.estimate(tokens)
        case .swe21:
            guard timestamp >= Self.swe21Launch else { return nil }
            if timestamp < Self.swe21Promo { return 0 }
            let price = timestamp < Self.swe21List ? Self.promo : Self.swe21Regular
            return price.estimate(tokens)
        case .ultrafast:
            guard timestamp >= Self.swe21Launch else { return nil }
            return Self.ultrafastRegular.estimate(tokens)
        }
    }

    private struct Price {
        let input: Double
        let output: Double
        let cacheRead: Double
        var cacheWrite: Double? = nil

        func estimate(_ tokens: TokenBreakdown) -> Double? {
            // Keep measured tokens if the published rates don't cover one of their buckets.
            if cacheWrite == nil, tokens.cacheWrite5m > 0 || tokens.cacheWrite1h > 0 { return nil }
            return ModelRates(
                inputPerMillion: input,
                outputPerMillion: output,
                cacheWritePerMillion: cacheWrite ?? 0,
                cacheReadPerMillion: cacheRead,
                cacheWrite1hPerMillion: cacheWrite
            ).costDollars(for: tokens, applyLongContextRates: false)
        }
    }

    private static let promo = Price(input: 0.50, output: 2.50, cacheRead: 0.05)
    private static let swe2Regular = Price(input: 3, output: 15, cacheRead: 0.30)
    private static let flashRegular = Price(input: 0.10, output: 0.50, cacheRead: 0.01, cacheWrite: 0.125)
    private static let swe21Regular = Price(input: 2, output: 10, cacheRead: 0.20)
    private static let ultrafastRegular = Price(input: 5, output: 25, cacheRead: 0.50)

    // The Desktop and CLI date-only boundaries are Pacific midnight (08:00 UTC on these dates).
    private static let swe2DocumentedRates = OpenUsageISO8601.date(from: "2026-11-09T08:00:00Z")!
    private static let swe2Promo = OpenUsageISO8601.date(from: "2026-12-01T08:00:00Z")!
    private static let swe2List = OpenUsageISO8601.date(from: "2027-01-01T08:00:00Z")!
    private static let flashLaunch = OpenUsageISO8601.date(from: "2026-11-04T08:00:00Z")!
    private static let flashList = OpenUsageISO8601.date(from: "2026-12-04T18:00:00Z")!
    private static let swe21Launch = OpenUsageISO8601.date(from: "2026-11-24T08:00:00Z")!
    private static let swe21Promo = OpenUsageISO8601.date(from: "2026-12-09T08:00:00Z")!
    private static let swe21List = OpenUsageISO8601.date(from: "2027-01-31T08:00:00Z")!
}
