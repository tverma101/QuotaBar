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

    /// The account data is authoritative only when every window reports `ok` with a usable percent —
    /// a partial or non-`ok` response must not mix account percentages with local fallbacks in one card.
    var isAvailable: Bool {
        [rolling, weekly, monthly].allSatisfy { window in
            window.status == "ok" && window.percent != nil
        }
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

        if response.statusCode == 401 || response.statusCode == 403 {
            throw OpenCodeUsageError.accountAPIUnauthorized
        }
        guard (200..<300).contains(response.statusCode) else {
            throw OpenCodeUsageError.accountAPIRequestFailed(response.statusCode)
        }

        guard let object = ProviderParse.jsonObject(response.body),
              let usage = object["usage"] as? [String: Any] else {
            throw OpenCodeUsageError.accountAPIUnavailable(detail: "unexpected response shape")
        }
        return Self.parse(usage)
    }

    /// Tolerant parse: each window's `status` (string), `percent` (number), and `resetsAt` (ISO 8601)
    /// are read independently, and a missing window parses as an empty one — so one odd or absent
    /// field can't hide the others. The provider gates on `isAvailable`, which requires every window
    /// to be `ok` with a percent, so a partial payload simply falls back to local logs.
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
