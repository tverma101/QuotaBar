import Foundation

struct OpenRouterUsageClient: Sendable {
    static let creditsURL = "https://openrouter.ai/api/v1/credits"
    static let keyURL = "https://openrouter.ai/api/v1/key"
    static let keysURL = "https://openrouter.ai/api/v1/keys"
    static let keysPageSize = 100
    /// Bounds the page loop should OpenRouter ever ignore `offset`.
    static let maxKeysPages = 50

    var http: any HTTPClient

    init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    /// Account-wide credit balance and lifetime spend. Fetched independently from key metadata because
    /// OpenRouter can gate either endpoint for a particular key type.
    func fetchCredits(apiKey: String) async throws -> HTTPResponse {
        try await get(Self.creditsURL, apiKey: apiKey)
    }

    /// Best-effort key metadata: tier, optional per-key spend cap, and daily/weekly/monthly spend.
    func fetchKey(apiKey: String) async throws -> HTTPResponse {
        try await get(Self.keyURL, apiKey: apiKey)
    }

    /// One page of the account's key list. Disabled and expired keys count too: what they spent
    /// before they stopped is still this period's spend.
    func fetchKeysPage(apiKey: String, offset: Int) async throws -> HTTPResponse {
        try await get("\(Self.keysURL)?include_disabled=true&include_expired=true&offset=\(offset)", apiKey: apiKey)
    }

    private func get(_ urlString: String, apiKey: String) async throws -> HTTPResponse {
        guard let url = URL(string: urlString) else {
            throw OpenRouterUsageError.invalidResponse
        }

        return try await http.send(HTTPRequest(
            method: "GET",
            url: url,
            headers: [
                "Authorization": "Bearer \(apiKey)",
                "Accept": "application/json"
            ],
            timeout: 15
        ))
    }
}

enum OpenRouterUsageError: Error, LocalizedError, Equatable {
    case connectionFailed
    case invalidResponse
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return "Couldn't reach OpenRouter. Check your connection."
        case .invalidResponse:
            return "OpenRouter usage data unavailable. Try again later."
        case .requestFailed(let status):
            return "OpenRouter request failed (HTTP \(status))."
        }
    }
}
