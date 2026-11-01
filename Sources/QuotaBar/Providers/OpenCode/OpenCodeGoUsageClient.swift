import Foundation

/// One account-wide OpenCode Go window as reported by the official `/zen/go/v1/usage` endpoint.
/// `percent` is the account's consumed share of the plan cap (0...100, integer on the wire); `resetsAt`
/// is the window's reset instant. `status` mirrors the API ("ok" today); anything else means that window
/// is not available and the card falls back to local history.
struct OpenCodeGoAccountWindow: Sendable, Equatable {
    var status: String
    var percent: Int?
    var resetsAt: Date?

    /// A window drives the meters only when its status is one this build knows how to read AND it
    /// carries a percent. `rate-limited` is the cap-exhausted state and is exactly when the official
    /// numbers matter most — a capped account must not silently degrade to local estimates.
    var isUsable: Bool {
        (status == "ok" || status == "rate-limited") && percent != nil
    }
}

/// The three account windows (rolling 5-hour session, weekly, monthly) from
/// `GET https://opencode.ai/zen/go/v1/usage`.
struct OpenCodeGoAccountUsage: Sendable, Equatable {
    var rolling: OpenCodeGoAccountWindow
    var weekly: OpenCodeGoAccountWindow
    var monthly: OpenCodeGoAccountWindow

    /// The account data is authoritative only when every window has a recognized status and percent —
    /// a partial response must not mix account percentages with local fallbacks in one card.
    var isAvailable: Bool {
        [rolling, weekly, monthly].allSatisfy(\.isUsable)
    }

}

/// Calls OpenCode's official account-wide usage endpoint with the `opencode-go` key as the Bearer token.
///
/// The key is used only in the `Authorization` header of this request and is never persisted, logged, or
/// included in error descriptions (the shared `HTTPClient` already redacts `Authorization` from its
/// debug lines and bodies). The endpoint is authenticated with the same key OpenCode's own CLI uses, so
/// the meters describe the whole account — every machine and client — not just this Mac's local logs.
struct OpenCodeGoUsageClient: Sendable {
    static let usageURL = "https://opencode.ai/zen/go/v1/usage"
    static let userAgent = "QuotaBar/0.7.8"

    var http: any HTTPClient

    init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    func fetchUsage(key: String) async throws -> OpenCodeGoAccountUsage {
        guard let url = URL(string: Self.usageURL) else {
            throw OpenCodeUsageError.accountAPIUnavailable(detail: "invalid usage URL")
        }

        let response = try await http.send(HTTPRequest(
            method: "GET",
            url: url,
            headers: [
                "Authorization": "Bearer \(key)",
                "Accept": "application/json",
                "User-Agent": Self.userAgent
            ],
            timeout: 15
        ))

        if (200..<300).contains(response.statusCode) {
            guard let object = ProviderParse.jsonObject(response.body),
                  let usage = object["usage"] as? [String: Any] else {
                throw OpenCodeUsageError.accountAPIInvalidResponse
            }
            let parsed = Self.parse(usage)
            guard parsed.isAvailable else {
                throw OpenCodeUsageError.accountAPIInvalidResponse
            }
            return parsed
        }

        switch Self.errorType(in: response.body) {
        case "AuthError":
            throw OpenCodeUsageError.accountAPIUnauthorized
        case "EntitlementError":
            throw OpenCodeUsageError.accountAPINoEntitlement
        default:
            break
        }
        if response.statusCode == 401 {
            throw OpenCodeUsageError.accountAPIUnauthorized
        }
        if response.statusCode == 403 {
            throw OpenCodeUsageError.accountAPINoEntitlement
        }
        throw OpenCodeUsageError.accountAPIRequestFailed(response.statusCode)
    }

    /// Error type is the stable API signal, including when a fronting proxy changes HTTP status codes.
    private static func errorType(in body: Data) -> String? {
        guard let object = ProviderParse.jsonObject(body),
              let error = object["error"] as? [String: Any]
        else { return nil }
        return error["type"] as? String
    }

    /// Tolerant parse: each window's `status` (string), `percent` (number), and `resetsAt` (ISO 8601)
    /// are read independently, and a missing window parses as an empty one — so one odd or absent
    /// field can't hide the others. The provider gates on `isAvailable`, which accepts both normal
    /// and cap-exhausted windows but rejects partial or unrecognized statuses.
    private static func parse(_ usage: [String: Any]) -> OpenCodeGoAccountUsage {
        func window(_ key: String) -> OpenCodeGoAccountWindow {
            guard let raw = usage[key] as? [String: Any] else {
                return OpenCodeGoAccountWindow(status: "", percent: nil, resetsAt: nil)
            }
            let status = (raw["status"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let percent = ProviderParse.number(raw["percent"]).flatMap { Int($0.rounded()) }
            let resetsAt = (raw["resetsAt"] as? String).flatMap(OpenUsageISO8601.date(from:))
            return OpenCodeGoAccountWindow(status: status, percent: percent, resetsAt: resetsAt)
        }

        return OpenCodeGoAccountUsage(
            rolling: window("rolling"),
            weekly: window("weekly"),
            monthly: window("monthly")
        )
    }
}
