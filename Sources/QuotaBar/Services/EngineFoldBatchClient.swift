import Foundation

struct EngineFoldBatchError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

/// Delegates one accounting pass's fold-only providers to the Rust engine in a single batch.
/// Production providers are already thin Rust wrappers, so a missing member or whole-batch failure
/// simply falls back to the provider's ordinary in-process engine refresh; no Swift scan worker is
/// involved in the production path.
@MainActor
final class EngineFoldBatchClient {
    typealias BatchExecutor = @MainActor (
        _ items: [RustEngine.BatchItem],
        _ scope: ProviderRefreshContext.Scope,
        _ paced: Bool
    ) async throws -> RustEngine.BatchResponse

    static let shared = EngineFoldBatchClient()

    /// Generous wall-clock cap for one batch. The engine reports per-member failures instead of
    /// making the app re-fold every finished sibling; benchmarked real-account batches are normally
    /// around a tenth of a second, so this ceiling exists only to bound a pathological source.
    nonisolated private static let batchFoldTimeout: TimeInterval = 300

    private let executeBatch: BatchExecutor

    init(batchExecutor: BatchExecutor? = nil) {
        self.executeBatch = batchExecutor ?? { items, scope, paced in
            try await RustEngine.refreshBatch(
                items: items,
                scope: scope,
                isManual: ProviderRefreshContext.isManual,
                skipModelCatalogRefresh: true,
                perProviderTimeoutSeconds: Self.batchFoldTimeout,
                batchBudgetSeconds: Self.batchFoldTimeout,
                paced: paced
            )
        }
    }

    /// The outcome of one engine batch. Members absent from both maps deliberately fall back to
    /// their provider runtime; cancellation is represented that way as well so a newer pass can win.
    struct FoldBatchResult {
        var snapshots: [String: ProviderSnapshot] = [:]
        var identityKeys: [String: String] = [:]
    }

    func fetchFoldSnapshots(
        providers: [String: Provider],
        engineConfigs: [String: EngineProviderConfig] = [:],
        paced: Bool
    ) async -> FoldBatchResult {
        var result = FoldBatchResult()
        guard !Task.isCancelled, !providers.isEmpty else { return result }
        let scope = ProviderRefreshContext.scope
        guard scope == .localAccounting || scope == .panelAccounting else { return result }

        let items = providers.keys.sorted().map { id in
            RustEngine.BatchItem(
                providerID: id,
                config: engineConfigs[id]?.values,
                defaultIdentityKey: nil
            )
        }
        do {
            let response = try await executeBatch(items, scope, paced)
            for (providerID, identityKey) in response.identityKeys where providers[providerID] != nil {
                result.identityKeys[providerID] = identityKey
            }
            for (providerID, message) in response.errors {
                guard let provider = providers[providerID] else { continue }
                result.snapshots[providerID] = ProviderSnapshot.error(
                    provider: provider,
                    error: EngineFoldBatchError(message: message),
                    clearsPriorMenuBarQuotaState: false
                )
            }
            for (providerID, snapshot) in response.snapshots where result.snapshots[providerID] == nil {
                guard providers[providerID] != nil else { continue }
                if snapshot.errorCategory == .cancelled {
                    AppLog.info(.refresh, "engine batch skipped \(providerID); folding through the provider runtime")
                    continue
                }
                result.snapshots[providerID] = snapshot
            }
            if result.snapshots.isEmpty && result.identityKeys.isEmpty {
                AppLog.warn(.refresh, "engine batch returned no fold snapshots; folding through provider runtimes")
            }
            return result
        } catch {
            guard !Task.isCancelled else { return FoldBatchResult() }
            AppLog.warn(.refresh, "engine batch failed; folding through provider runtimes: \(error.localizedDescription)")
            return FoldBatchResult()
        }
    }
}
