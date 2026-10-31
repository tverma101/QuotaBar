import Foundation

struct FreebuffUsageClient: Sendable {
    // The bare host redirects to www. URLSession drops Authorization across that host change,
    // making a freshly connected CLI token look expired. Call the canonical API host directly.
    static let sessionURL = "https://www.codebuff.com/api/v1/freebuff/session"
    static let modelCatalogURL = "https://www.codebuff.com/api/v1/freebuff/models"

    var http: any HTTPClient
    var timeZone: @Sendable () -> String

    init(
        http: any HTTPClient = URLSessionHTTPClient(),
        timeZone: @escaping @Sendable () -> String = { TimeZone.current.identifier }
    ) {
        self.http = http
        self.timeZone = timeZone
    }

    /// Read-only equivalent of the Freebuff CLI's GET session poll. The POST route admits a session
    /// and must never be used for usage monitoring.
    func fetchSession(auth: FreebuffAuth) async throws -> HTTPResponse {
        // Request Desktop purchase metadata without an instance or heartbeat: observation only.
        try await fetch(urlString: Self.sessionURL, auth: auth,
                        extraHeaders: ["x-freebuff-multi-session": "1"])
    }

    func fetchModelCatalog(auth: FreebuffAuth) async throws -> HTTPResponse {
        try await fetch(urlString: Self.modelCatalogURL, auth: auth,
                        extraHeaders: ["x-freebuff-catalog-protocol": "1"])
    }

    private func fetch(urlString: String, auth: FreebuffAuth, extraHeaders: [String: String] = [:]) async throws -> HTTPResponse {
        guard let url = URL(string: urlString) else {
            throw FreebuffUsageError.invalidResponse
        }
        do {
            return try await http.send(HTTPRequest(
                method: "GET",
                url: url,
                headers: [
                    "Authorization": "Bearer \(auth.token)",
                    "Accept": "application/json",
                    "x-fb-timezone": timeZone()
                ].merging(extraHeaders, uniquingKeysWith: { _, new in new }),
                timeout: 15
            ))
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw FreebuffUsageError.connectionFailed
        }
    }
}

enum FreebuffUsageError: Error, LocalizedError, Equatable {
    case connectionFailed
    case invalidResponse
    case requestFailed(Int)
    case quotaUnavailable
    case localHistoryUnreadable

    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return "Couldn't reach Freebuff. Check your connection and try again."
        case .invalidResponse:
            return "Freebuff returned unreadable usage data. Try again later."
        case .requestFailed(let status):
            return "Freebuff usage request failed (HTTP \(status))."
        case .quotaUnavailable:
            return "Freebuff usage data is not available for this account yet."
        case .localHistoryUnreadable:
            return "QuotaBar couldn't read Freebuff Desktop's measured token history. Refresh again after the current turn finishes."
        }
    }
}
