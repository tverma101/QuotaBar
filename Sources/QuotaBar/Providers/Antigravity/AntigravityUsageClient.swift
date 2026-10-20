import Foundation

/// Outcome of a Cloud Code call, split so the orchestrator can tell a genuine auth failure (refresh)
/// apart from a transient outage (try the next base URL / strategy, don't refresh).
enum CloudCodeOutcome: Sendable {
    case ok(Data)
    case notFound
    case authFailed
    case forbidden
    case unavailable

    var isUnavailable: Bool {
        switch self {
        case .notFound, .unavailable: return true
        case .ok, .authFailed, .forbidden: return false
        }
    }
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
    static let cloudCodeURLs = [
        "https://daily-cloudcode-pa.googleapis.com",
        "https://cloudcode-pa.googleapis.com"
    ]
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
    /// authentication; a 403 is a permission denial and must not trigger OAuth refresh. Both
    /// short-circuit because the same request would fail on the other base. Other non-2xx / transport
    /// errors fall through to the next base and finally `.unavailable`.
    func cloudCode(path: String, token: String, userAgent: String, body: [String: String]) async throws -> CloudCodeOutcome {
        let payload = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
        var sawNotFound = false
        var sawOtherFailure = false
        for base in Self.cloudCodeURLs {
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
            if response.statusCode == 401 { return .authFailed }
            if response.statusCode == 403 { return .forbidden }
            if (200..<300).contains(response.statusCode) { return .ok(response.body) }
            if response.statusCode == 404 {
                sawNotFound = true
            } else {
                sawOtherFailure = true
            }
        }
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
