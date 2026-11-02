import Foundation

/// Allowlisted server numbers for headless checks. Never retains credentials, identities, models,
/// purchase holders, or the original response body. Present only after a live quota read.
struct FreebuffQuotaObservation: Encodable, Sendable {
    var combinedFreebucks: Double?
    var dailyLimitFreebucks: Double?
    var dailySpentFreebucks: Double?
    var dailyRemainingFreebucks: Double?
    var walletFreebucks: Double?

    init(response: HTTPResponse) {
        let root = ProviderParse.jsonObject(response.body)
        let bucks = root?["freebucks"] as? [String: Any]
        let daily = bucks?["daily"] as? [String: Any]
        let wallet = bucks?["wallet"] as? [String: Any]
        combinedFreebucks = ProviderParse.number(bucks?["balance"])
        dailyLimitFreebucks = ProviderParse.number(daily?["limit"])
        dailySpentFreebucks = ProviderParse.number(daily?["spent"])
        dailyRemainingFreebucks = ProviderParse.number(daily?["remaining"])
        walletFreebucks = ProviderParse.number(wallet?["balance"])
    }
}
