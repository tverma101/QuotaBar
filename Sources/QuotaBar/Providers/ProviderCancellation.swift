import Foundation

/// Normalizes Swift task cancellation and URLSession's cancellation error at provider boundaries.
/// Providers must preserve either signal so a superseded refresh cannot continue to another
/// credential source or authenticated endpoint.
enum ProviderCancellation {
    nonisolated static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError
            || (error as? URLError)?.code == .cancelled
            || Task<Never, Never>.isCancelled
    }

    nonisolated static func rethrowIfCancellation(_ error: any Error) throws {
        guard isCancellation(error) else { return }
        throw CancellationError()
    }
}
