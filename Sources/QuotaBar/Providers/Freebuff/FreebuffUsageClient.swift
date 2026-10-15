import Foundation

struct FreebuffUsageClient: Sendable {
    static let sessionURL = "https://codebuff.com/api/v1/freebuff/session"

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
        guard let url = URL(string: Self.sessionURL) else {
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
                ],
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
        }
    }
}
