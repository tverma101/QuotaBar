import Foundation

/// Outcome of a Cloud Code call, split so the orchestrator can tell a genuine auth failure (refresh)
/// apart from a transient outage (try the next base URL / strategy, don't refresh).
enum CloudCodeOutcome: Sendable {
    case ok(Data)
    case notFound
    case authFailed
    case forbidden
    case rateLimited
    case unavailable

    var isUnavailable: Bool {
        switch self {
        case .notFound, .unavailable: return true
        case .ok, .authFailed, .forbidden, .rateLimited: return false
        }
    }

    var isOK: Bool {
        if case .ok = self { return true }
        return false
    }
}

enum CloudCodeBatchOutcome: Sendable {
    case ok([Data], allHostsAnswered: Bool)
    case authFailed
    case forbidden
    case rateLimited
    case notFound
    case unavailable
}

/// Result of a Google OAuth token refresh, split so a dead refresh token reads as expired auth while a
/// 5xx/network failure reads as a transient outage.
enum TokenRefreshOutcome: Sendable {
    case refreshed(accessToken: String, expiresIn: Double)
    case clientConfigurationInvalid
    case authFailed
    case unavailable
}

/// All network I/O for Antigravity: the local language-server RPC (loopback HTTPS, self-signed), the
/// Google Cloud Code endpoints, and the Google OAuth token refresh.
struct AntigravityUsageClient: Sendable {
    static let lsService = "exa.language_server_pb.LanguageServerService"
    // Quota data prefers daily: production can answer "complete" with untouched pools while daily
    // carries the active counters (upstream #1641).
    static let cloudCodeURLs = [
        "https://daily-cloudcode-pa.googleapis.com",
        "https://cloudcode-pa.googleapis.com"
    ]
    // Plan and project lookups prefer production (upstream #1641).
    static let planLookupURLs = Array(cloudCodeURLs.reversed())
    static let fetchModelsPath = "/v1internal:fetchAvailableModels"
    static let loadCodeAssistPath = "/v1internal:loadCodeAssist"
    static let retrieveQuotaPath = "/v1internal:retrieveUserQuota"
    static let quotaSummaryPath = "/v1internal:retrieveUserQuotaSummary"
    static let googleOAuthURL = "https://oauth2.googleapis.com/token"
    // Google OAuth "installed application" client credentials, extracted verbatim from the Antigravity
    // app bundle — the same pair the shipped app and the legacy Tauri plugin use. For installed-app OAuth
    // clients Google does not treat the "secret" as confidential (it ships in every copy of the client),
    // so committing it here is an intentional, accepted trade-off, not a leaked private key. It's required
    // for the refresh-token grant — without it we can't refresh the keychain token when the app is closed.
    static let googleClientID = "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com"
    static let googleClientSecret = "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"
    static let lsMetadata = ["ideName": "antigravity", "extensionName": "antigravity", "ideVersion": "unknown", "locale": "en"]

    /// The Antigravity client's own User-Agent shape. Google marks other callers `UNSUPPORTED_CLIENT`
    /// and drops `paidTier`; the hub identity exposes the separate Argon weekly quota (upstream #1676).
    static let clientUserAgent: String = {
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "amd64"
        #endif
        return "antigravity/hub/2.24.0 (aidev_client; os_type=darwin; arch=\(arch))"
    }()

    /// Loopback session that trusts the LS's self-signed cert; remote calls use full validation.
    var lsHTTP: HTTPClient
    var http: HTTPClient

    init(
        lsHTTP: HTTPClient = URLSessionHTTPClient(allowsInsecureLoopback: true),
        http: HTTPClient = URLSessionHTTPClient()
    ) {
        self.lsHTTP = lsHTTP
        self.http = http
    }

    /// Call a language-server RPC method. Returns nil on a transport failure (port not the live one).
    func callLS(scheme: String, port: Int, csrf: String, method: String) async throws -> HTTPResponse? {
        try Task.checkCancellation()
        guard let url = URL(string: "\(scheme)://127.0.0.1:\(port)/\(Self.lsService)/\(method)") else { return nil }
        let body = try? JSONSerialization.data(withJSONObject: ["metadata": Self.lsMetadata])
        let request = HTTPRequest(
            method: "POST",
            url: url,
            headers: [
                "Content-Type": "application/json",
                "Connect-Protocol-Version": "1",
                "x-codeium-csrf-token": csrf
            ],
            body: body,
            timeout: 10
        )
        do {
            let response = try await lsHTTP.send(request)
            try Task.checkCancellation()
            return response
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try ProviderCancellation.rethrowIfCancellation(error)
            return nil
        }
    }

    /// POST a Cloud Code endpoint, trying each base URL in turn. A 401 is evidence of invalid/expired
    /// authentication; a 403 is a permission denial and must not trigger OAuth refresh. A refusal only
    /// counts once every host that answered refused — a successful body from any host still wins.
    /// Other non-2xx / transport errors fall through to the next base and finally `.unavailable`.
    func cloudCode(
        path: String,
        token: String,
        userAgent: String = Self.clientUserAgent,
        body: [String: String],
        urls: [String] = Self.cloudCodeURLs
    ) async throws -> CloudCodeOutcome {
        switch try await cloudCodeResponses(path: path, token: token, userAgent: userAgent, body: body, urls: urls, collectSummaries: false) {
        case .ok(let bodies, _): return .ok(bodies[0])
        case .authFailed: return .authFailed
        case .forbidden: return .forbidden
        case .rateLimited: return .rateLimited
        case .notFound: return .notFound
        case .unavailable: return .unavailable
        }
    }

    /// A host can omit an entire quota pool. Consult the other host only when the first usable body
    /// cannot supply all shared meters; a failed supplemental host never discards measured limits.
    func cloudCodeSummaries(token: String) async throws -> CloudCodeBatchOutcome {
        try await cloudCodeResponses(path: Self.quotaSummaryPath, token: token, userAgent: Self.clientUserAgent, body: [:], urls: Self.cloudCodeURLs, collectSummaries: true)
    }

    /// GitHub-style rate limits arrive as a 403 carrying `x-ratelimit-remaining: 0` or `retry-after`,
    /// and Google's quota denials surface as a 403 whose error names the quota. Neither is a permission
    /// denial or a dead token, so they must never trigger OAuth refresh (upstream #1529).
    static func isRateLimited(_ response: HTTPResponse) -> Bool {
        if response.statusCode == 429 { return true }
        guard response.statusCode == 403 else { return false }
        if response.header("x-ratelimit-remaining") == "0" || response.header("retry-after") != nil { return true }
        guard let text = String(data: response.body, encoding: .utf8) else { return false }
        return text.contains("RESOURCE_EXHAUSTED")
            || text.contains("rateLimitExceeded")
            || text.contains("userRateLimitExceeded")
            || text.contains("quotaExceeded")
    }

    private func cloudCodeResponses(
        path: String, token: String, userAgent: String, body: [String: String], urls: [String], collectSummaries: Bool
    ) async throws -> CloudCodeBatchOutcome {
        let payload = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
        var sawNotFound = false
        var sawOtherFailure = false
        var sawAuthFailed = false
        var sawForbidden = false
        var sawRateLimited = false
        var bodies: [Data] = []
        for base in urls {
            try Task.checkCancellation()
            guard let url = URL(string: base + path) else { continue }
            let request = HTTPRequest(
                method: "POST",
                url: url,
                headers: [
                    "Accept": "application/json",
                    "Content-Type": "application/json",
                    "Authorization": "Bearer \(token)",
                    "User-Agent": userAgent
                ],
                body: payload,
                timeout: 15
            )
            let response: HTTPResponse
            do {
                response = try await http.send(request)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try ProviderCancellation.rethrowIfCancellation(error)
                try Task.checkCancellation()
                sawOtherFailure = true
                continue
            }
            try Task.checkCancellation()
            if response.statusCode == 401 {
                if !bodies.isEmpty { return .ok(bodies, allHostsAnswered: false) }
                sawAuthFailed = true
                continue
            }
            if response.statusCode == 403 {
                if !bodies.isEmpty { return .ok(bodies, allHostsAnswered: false) }
                if Self.isRateLimited(response) { sawRateLimited = true } else { sawForbidden = true }
                continue
            }
            if response.statusCode == 429 {
                if !bodies.isEmpty { return .ok(bodies, allHostsAnswered: false) }
                sawRateLimited = true
                continue
            }
            if (200..<300).contains(response.statusCode) {
                bodies.append(response.body)
                if !collectSummaries || AntigravityUsageMapper.hasAllSharedQuotaMeters(response.body, sourceID: "cloud-code-\(bodies.count - 1)") {
                    return .ok(bodies, allHostsAnswered: true)
                }
                continue
            }
            if response.statusCode == 404 {
                sawNotFound = true
            } else {
                sawOtherFailure = true
            }
        }
        if !bodies.isEmpty {
            return .ok(bodies, allHostsAnswered: !sawNotFound && !sawOtherFailure)
        }
        // A refusal stands only once every host that answered refused; a host that never answered
        // cannot soften it (upstream #1510).
        if sawAuthFailed { return .authFailed }
        if sawForbidden { return .forbidden }
        if sawRateLimited { return .rateLimited }
        return sawNotFound && !sawOtherFailure ? .notFound : .unavailable
    }

    /// Exchange a Google refresh token for a fresh access token. Distinguishes a rejected OAuth client
    /// (`invalid_client`) from a dead refresh token (`invalid_grant`) and transient failures so the
    /// caller does not report expired sign-in when QuotaBar's client configuration was rejected.
    func refreshGoogleToken(_ refreshToken: String) async throws -> TokenRefreshOutcome {
        try Task.checkCancellation()
        guard let url = URL(string: Self.googleOAuthURL) else { return .unavailable }
        let form = [
            "client_id=\(Self.googleClientID.urlFormEncoded)",
            "client_secret=\(Self.googleClientSecret.urlFormEncoded)",
            "refresh_token=\(refreshToken.urlFormEncoded)",
            "grant_type=refresh_token"
        ].joined(separator: "&")
        let request = HTTPRequest(
            method: "POST",
            url: url,
            headers: ["Content-Type": "application/x-www-form-urlencoded"],
            body: Data(form.utf8),
            timeout: 15
        )
        let response: HTTPResponse
        do {
            response = try await http.send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try ProviderCancellation.rethrowIfCancellation(error)
            try Task.checkCancellation()
            return .unavailable
        }
        try Task.checkCancellation()
        switch response.statusCode {
        case 200..<300:
            guard let decoded = try? JSONDecoder().decode(GoogleTokenResponse.self, from: response.body),
                  let access = decoded.accessToken?.nilIfEmpty
            else {
                return .unavailable // 2xx but undecodable / empty — treat as transient
            }
            return .refreshed(accessToken: access, expiresIn: decoded.expiresIn ?? 3600)
        case 408, 429:
            return .unavailable // request timeout / rate limited — transient, not a revoked token
        case 400..<500:
            switch Self.oauthError(response.body) {
            case "invalid_client", "deleted_client", "invalid_request", "unauthorized_client", "unsupported_grant_type", "invalid_scope":
                return .clientConfigurationInvalid
            case "invalid_grant":
                return .authFailed
            default:
                // A non-transient OAuth 4xx means this authorization was rejected, even when Google
                // returned an unknown code or a non-JSON body. Keep 408/429 and 5xx in the branches
                // above/below as transient failures.
                return .authFailed
            }
        default:
            return .unavailable // 5xx and anything else — transient
        }
    }

    private static func oauthError(_ body: Data) -> String? {
        guard let value = try? JSONSerialization.jsonObject(with: body),
              let object = value as? [String: Any]
        else {
            return nil
        }
        return object["error"] as? String
    }
}

struct GoogleTokenResponse: Decodable {
    let accessToken: String?
    let expiresIn: Double?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
    }
}
