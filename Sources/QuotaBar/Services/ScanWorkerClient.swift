import Foundation

struct ScanWorkerFoldError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

private struct ScanWorkerSchemaError: LocalizedError {
    var errorDescription: String? { "scan worker response schema mismatch" }
}

/// Spawns the app's own executable as a short-lived scan-worker child (see `ScanWorkerCommand`)
/// for a provider's fold-only refresh, so the JSONL parse churn settles into the child's heap —
/// which dies with the process — instead of the menu-bar app's.
///
/// Every failure mode is benign and falls back to the caller's in-process scan: missing
/// executable (tests, `swift run` without an app bundle), spawn errors, and undecodable payloads
/// all return `nil` from `foldOnlySnapshot`, and the child's own per-provider error responses come
/// back as error snapshots the store already knows how to surface. `QUOTABAR_DISABLE_SCAN_WORKER=1`
/// turns the worker off entirely.
@MainActor
final class ScanWorkerClient {
    static let shared = ScanWorkerClient()

    private let runner: any ProcessRunning
    /// Slightly below the provider refresh deadline so the client can still report a timeout
    /// snapshot before the store's own deadline machinery fires.
    private let timeout: TimeInterval
    /// Test hook: overrides the bundle-derived worker executable (nil = derive from the bundle).
    private let executableURLOverride: URL?
    private var lastSpawnFailureLogAt: Date?

    init(
        runner: any ProcessRunning = SystemProcessRunner(),
        timeout: TimeInterval = 110,
        executableURLOverride: URL? = nil
    ) {
        self.runner = runner
        self.timeout = timeout
        self.executableURLOverride = executableURLOverride
    }

    /// The child runs only when this process is the installed app bundle: the worker entry point
    /// lives in the signed app executable (for its Keychain identity), and tests plus bare
    /// `swift run` binaries have no such bundle to spawn.
    private var workerExecutableURL: URL? {
        guard ProcessInfo.processInfo.environment["QUOTABAR_IN_SCAN_WORKER"] == nil else { return nil }
        guard ProcessInfo.processInfo.environment["QUOTABAR_DISABLE_SCAN_WORKER"] == nil else { return nil }
        if let executableURLOverride { return executableURLOverride }
        guard Bundle.main.bundleURL.pathExtension == "app",
              let executableURL = Bundle.main.executableURL
        else { return nil }
        return executableURL
    }

    var isAvailable: Bool { workerExecutableURL != nil }

    /// Run the provider's fold-only refresh in a child. Returns the child's snapshot on success,
    /// an error snapshot when the child reported a refresh failure (the caller surfaces it like
    /// any failed refresh — no rescan), or the fallback snapshot's result when the worker is
    /// unavailable or failed benignly.
    func foldOnlySnapshot(
        provider: Provider,
        inProcessFallback: @MainActor () async -> ProviderSnapshot
    ) async -> ProviderSnapshot {
        guard let executableURL = workerExecutableURL, !Task.isCancelled else {
            return await inProcessFallback()
        }
        let scope = ProviderRefreshContext.scope
        let paced = ProviderRefreshContext.accountingCPUThrottleEnabled
        let scopeArgument: String
        switch scope {
        case .localAccounting: scopeArgument = "local-accounting"
        case .panelAccounting: scopeArgument = "panel-accounting"
        default:
            // Only fold-only scopes delegate; meter and full scopes keep their in-process paths.
            return await inProcessFallback()
        }
        let arguments = [
            "--scan-worker",
            "--providers", provider.id,
            "--scope", scopeArgument,
        ] + (paced ? ["--paced"] : [])
        do {
            // The runner blocks its calling thread for the child's whole lifetime; keep that wait
            // off the main actor (see `loadOffMainActor`).
            let result = try await loadOffMainActor { [runner, timeout] in
                try runner.run(
                    executable: executableURL.path,
                    arguments: arguments,
                    // Merged over the inherited environment by the runner; the flag makes the
                    // child's own fold paths run their scanners in-process.
                    environment: ["QUOTABAR_IN_SCAN_WORKER": "1"],
                    timeout: timeout
                )
            }
            guard result.succeeded, !result.stdout.isEmpty else {
                let message = result.stderr.split(separator: "\n").last
                    .map(String.init) ?? "scan worker exited with status \(result.exitCode)"
                AppLog.warn(.refresh, "scan worker failed for \(provider.id): \(message)")
                return ProviderSnapshot.error(
                    provider: provider,
                    error: ScanWorkerFoldError(message: message),
                    clearsPriorMenuBarQuotaState: false
                )
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let response = try decoder.decode(ScanWorkerCommand.Response.self, from: Data(result.stdout.utf8))
            guard response.schema == ScanWorkerCommand.schemaName else {
                throw ScanWorkerSchemaError()
            }
            if let identityKey = response.identityKeys[provider.id] {
                ProviderRefreshContext.cacheIdentityResult?.set(identityKey)
            }
            if let error = response.errors[provider.id] {
                // Fold-only failures never clear quota state: the store's merge recovers the meters
                // from the prior snapshot, exactly like an in-process fold failure.
                return ProviderSnapshot.error(
                    provider: provider,
                    error: ScanWorkerFoldError(message: error),
                    clearsPriorMenuBarQuotaState: false
                )
            }
            if let snapshot = response.snapshots[provider.id] {
                if snapshot.errorCategory == .cancelled {
                    // The child asked to skip (e.g. an account inventory it cannot resolve). The
                    // in-process path re-checks the same conditions, so a rare divergence costs one
                    // heavy pass instead of stalling the provider's history.
                    AppLog.info(.refresh, "scan worker skipped \(provider.id); folding in-process")
                    return await inProcessFallback()
                }
                return snapshot
            }
            AppLog.warn(.refresh, "scan worker returned no snapshot for \(provider.id)")
            return await inProcessFallback()
        } catch ProcessRunnerError.timedOut {
            AppLog.warn(.refresh, "scan worker timed out for \(provider.id) after \(Int(timeout))s")
            return ProviderSnapshot.error(
                provider: provider,
                error: ScanWorkerFoldError(message: "Refresh timed out after \(Int(timeout))s"),
                clearsPriorMenuBarQuotaState: false
            )
        } catch {
            guard !Task.isCancelled else { return await inProcessFallback() }
            logSpawnFailureOnce(providerID: provider.id, message: error.localizedDescription)
            return await inProcessFallback()
        }
    }

    /// Spawn failures are environmental (missing binary, exec failure); log them once per session
    /// rather than once per fold pass, and let the in-process path keep the app working.
    private func logSpawnFailureOnce(providerID: String, message: String) {
        let now = Date()
        if let lastSpawnFailureLogAt, now.timeIntervalSince(lastSpawnFailureLogAt) < 300 { return }
        lastSpawnFailureLogAt = now
        AppLog.warn(.refresh, "scan worker unavailable for \(providerID); folding in-process: \(message)")
    }
}
