import Foundation

struct FreebuffUsageClient: Sendable {
    enum Operation: Equatable, Sendable {
        case session
        case modelCatalog
        case history(path: String, cursor: String?)
    }

    typealias Transport = @Sendable (Operation, FreebuffAuth) async throws -> HTTPResponse
    private let transport: Transport?
    var hasTransport: Bool { transport != nil }
    let supportsHostedDetail: Bool

    init(transport: Transport? = nil, supportsHostedDetail: Bool = true) {
        self.transport = transport
        self.supportsHostedDetail = transport != nil && supportsHostedDetail
    }

    func fetchSession(auth: FreebuffAuth) async throws -> HTTPResponse {
        try await fetch(.session, auth: auth)
    }

    func fetchModelCatalog(auth: FreebuffAuth) async throws -> HTTPResponse {
        guard supportsHostedDetail else { throw FreebuffUsageError.liveAccessUnavailable }
        return try await fetch(.modelCatalog, auth: auth)
    }

    func fetchHistory(path: String, cursor: String?, auth: FreebuffAuth) async throws -> HTTPResponse {
        guard supportsHostedDetail else { throw FreebuffUsageError.liveAccessUnavailable }
        return try await fetch(.history(path: path, cursor: cursor), auth: auth)
    }

    private func fetch(_ operation: Operation, auth: FreebuffAuth) async throws -> HTTPResponse {
        guard let transport else { throw FreebuffUsageError.liveAccessUnavailable }
        do {
            return try await transport(operation, auth)
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
    case liveAccessUnavailable

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
        case .liveAccessUnavailable:
            return "Live Freebuff quotas and session timers are unavailable. QuotaBar shows saved measurements only."
        }
    }
}
