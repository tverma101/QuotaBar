import Foundation

/// Calls GitHub's public REST billing endpoints to find the organization that provides an org-managed
/// Copilot seat and read its month-to-date usage. Used only when `/copilot_internal/user` reports a
/// token-based-billing seat with no per-seat quota (Copilot Business/Enterprise managed by an org) —
/// the usage then lives in *organization* billing, which the user-scoped endpoint never carries.
///
/// Reading an org's billing requires the caller to be an org owner or billing manager; a plain member
/// gets 403. That's an expected state, handled by the provider, not an error here.
struct CopilotOrgBillingClient: Sendable {
    static let userOrgsURL = "https://api.github.com/user/orgs?per_page=100"

    static func isRateLimitResponse(_ response: HTTPResponse) -> Bool {
        isRateLimitResponse(
            statusCode: response.statusCode,
            retryAfter: response.header("retry-after"),
            rateLimitRemaining: response.header("x-ratelimit-remaining"),
            body: response.body
        )
    }

    static func isRateLimitResponse(
        statusCode: Int,
        retryAfter: String?,
        rateLimitRemaining: String?,
        body: Data? = nil
    ) -> Bool {
        let remaining = rateLimitRemaining?.trimmingCharacters(in: .whitespacesAndNewlines)
        if statusCode == 429 || (statusCode == 200 && remaining == "0") { return true }
        guard statusCode == 403 else { return false }
        if retryAfter != nil || remaining == "0" { return true }
        return body.map(containsSecondaryRateLimitMessage) ?? false
    }

    private static func containsSecondaryRateLimitMessage(_ body: Data) -> Bool {
        let message: String
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let responseMessage = object["message"] as? String {
            message = responseMessage
        } else {
            message = String(decoding: body, as: UTF8.self)
        }
        let normalized = message.lowercased()
        return normalized.contains("secondary rate limit")
            || normalized.contains("rate limit exceeded")
            || normalized.contains("rate-limit exceeded")
            || normalized.contains("abuse detection")
    }

    static func usageSummaryURL(org: String) -> URL? {
        // Org slugs are alphanumeric-plus-hyphen, but encode defensively before splicing into the path.
        guard let encoded = org.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return nil
        }
        return URL(string: "https://api.github.com/orgs/\(encoded)/settings/billing/usage/summary")
    }

    var http: any HTTPClient

    init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    /// Every organization the token's user belongs to. GitHub caps pages at 100 and returns the next
    /// page in `Link`; the billing org may be past the first page for users with many memberships.
    func fetchUserOrgs(token: String) async throws -> HTTPResponse {
        guard let initialURL = URL(string: Self.userOrgsURL) else {
            throw CopilotUsageError.invalidResponse
        }
        var nextURL: URL? = initialURL
        var visitedURLs = Set<String>()
        var organizations: [[String: Any]] = []
        var finalResponse: HTTPResponse?

        for _ in 0..<100 {
            guard let url = nextURL,
                  visitedURLs.insert(url.absoluteString).inserted
            else { throw CopilotUsageError.invalidResponse }
            try Task.checkCancellation()
            let response: HTTPResponse
            do {
                response = try await send(url: url, token: token)
            } catch {
                try ProviderCancellation.rethrowIfCancellation(error)
                guard !organizations.isEmpty,
                      let partialBody = try? JSONSerialization.data(withJSONObject: organizations)
                else { throw error }
                return HTTPResponse(
                    statusCode: 200,
                    headers: ["X-QuotaBar-Partial-Status": "transport"],
                    body: partialBody
                )
            }
            try Task.checkCancellation()
            guard response.statusCode == 200 else {
                guard !organizations.isEmpty,
                      let partialBody = try? JSONSerialization.data(withJSONObject: organizations)
                else { return response }
                // Keep completed pages usable if a later page is throttled or temporarily unavailable.
                // The private status marker lets the caller log the incomplete scan and cool down on
                // rate limits while still probing the orgs already returned by GitHub.
                var headers = ["X-QuotaBar-Partial-Status": String(response.statusCode)]
                if let retryAfter = response.header("retry-after") {
                    headers["Retry-After"] = retryAfter
                }
                if let reset = response.header("x-ratelimit-reset") {
                    headers["X-RateLimit-Reset"] = reset
                }
                if let remaining = response.header("x-ratelimit-remaining") {
                    headers["X-RateLimit-Remaining"] = remaining
                }
                if Self.isRateLimitResponse(response) {
                    headers["X-QuotaBar-Partial-Rate-Limit"] = "true"
                }
                return HTTPResponse(statusCode: 200, headers: headers, body: partialBody)
            }
            guard let page = try? JSONSerialization.jsonObject(with: response.body) as? [[String: Any]] else {
                throw CopilotUsageError.invalidResponse
            }
            organizations.append(contentsOf: page)
            if Self.isRateLimitResponse(response) {
                guard let partialBody = try? JSONSerialization.data(withJSONObject: organizations) else {
                    throw CopilotUsageError.invalidResponse
                }
                var headers = [
                    "X-QuotaBar-Partial-Status": "200",
                    "X-QuotaBar-Partial-Rate-Limit": "true"
                ]
                if let reset = response.header("x-ratelimit-reset") {
                    headers["X-RateLimit-Reset"] = reset
                }
                if let remaining = response.header("x-ratelimit-remaining") {
                    headers["X-RateLimit-Remaining"] = remaining
                }
                if let retryAfter = response.header("retry-after") {
                    headers["Retry-After"] = retryAfter
                }
                return HTTPResponse(statusCode: 200, headers: headers, body: partialBody)
            }
            finalResponse = response
            nextURL = try Self.nextPageURL(from: response.header("link"), currentURL: url)
            if nextURL == nil { break }
        }

        guard nextURL == nil, let finalResponse,
              let body = try? JSONSerialization.data(withJSONObject: organizations)
        else { throw CopilotUsageError.invalidResponse }
        return HTTPResponse(statusCode: 200, headers: finalResponse.headers, body: body)
    }

    /// Month-to-date billing usage summary for one organization.
    func fetchUsageSummary(org: String, token: String) async throws -> HTTPResponse {
        guard let url = Self.usageSummaryURL(org: org) else {
            throw CopilotUsageError.invalidResponse
        }
        return try await send(url: url, token: token)
    }

    private func send(url: URL, token: String) async throws -> HTTPResponse {
        try await http.send(HTTPRequest(
            method: "GET",
            url: url,
            headers: [
                "Authorization": "token \(token)",
                "Accept": "application/vnd.github+json",
                "User-Agent": "QuotaBar",
                "X-GitHub-Api-Version": "2022-11-28"
            ],
            timeout: 15
        ))
    }

    private static func nextPageURL(from header: String?, currentURL: URL) throws -> URL? {
        guard let header else { return nil }
        for rawLink in header.split(separator: ",") {
            let parts = rawLink.split(separator: ";", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let relation = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard relation == "rel=\"next\"" || relation == "rel=next" else { continue }
            let rawURL = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard rawURL.first == "<", rawURL.last == ">",
                  let link = URL(string: String(rawURL.dropFirst().dropLast()), relativeTo: currentURL)?.absoluteURL,
                  link.scheme?.lowercased() == "https",
                  link.host?.lowercased() == "api.github.com",
                  link.path == "/user/orgs",
                  link.user == nil,
                  link.password == nil,
                  link.port == nil || link.port == 443
            else { throw CopilotUsageError.invalidResponse }
            return link
        }
        return nil
    }
}
