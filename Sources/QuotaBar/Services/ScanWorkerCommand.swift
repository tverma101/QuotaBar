import Foundation

/// Runs inside the signed app executable (same entry pattern as `HeadlessDiagnosticCommand`),
/// before SwiftUI/AppKit starts, so the parent menu-bar app can delegate the heavy local
/// accounting folds to a short-lived child process. The child process's parse working set — the
/// JSONSerialization churn that interleaves fragmentation into the app's heap — dies with the
/// process instead of settling into the menu-bar app's footprint.
///
/// The child runs the requested providers' fold-only refresh (`.panelAccounting`: no live quota
/// APIs, local corpora only), flushes pending cache writes, and emits the refreshed snapshots as
/// JSON on stdout. `--return-only` skips the child's own snapshot store: the calling store already
/// owns the refresh order, so only the parent publishes provider snapshots for delegated folds.
/// Shared scan/parse caches remain safe to write — cross-process safety there is carried by the
/// existing flock layers (`PersistentStoreLock`, `JSONLScanCacheWriter`).
///
/// The parent sets `QUOTABAR_IN_SCAN_WORKER=1` in the child's environment; the providers' fold
/// paths consult it and run their scanners in-process here rather than spawning another child.
public enum ScanWorkerCommand {
    static let schemaName = "quotabar.scan-worker.v1"

    struct Options: Equatable {
        struct InvalidArguments: LocalizedError {
            var errorDescription: String? {
                "Usage: QuotaBar --scan-worker --providers <id[,id...]> [--scope local-accounting|panel-accounting] [--paced] [--return-only] [--per-provider-timeout <s>] [--batch-budget <s>]"
            }
        }
        var providerIDs: [String] = []
        var scope: ProviderRefreshContext.Scope = .panelAccounting
        var paced = false
        var returnOnly = false
        /// Cap on one provider's fold inside a multi-provider batch. Below the child process's own
        /// wall timeout so one slow fold returns an error entry instead of the parent killing the
        /// child and losing every sibling's completed snapshot.
        var perProviderTimeout: TimeInterval?
        /// Total wall budget for a batch fold. When the loop runs out, unattempted providers are
        /// simply absent from the response — the caller then folds them in-process instead of
        /// reporting a failure for work that never ran.
        var batchBudget: TimeInterval?

        static func parse(_ arguments: [String]) throws -> Options {
            var options = Options()
            var index = 0
            while index < arguments.count {
                let argument = arguments[index]
                switch argument {
                case "--scan-worker":
                    break
                case "--paced":
                    options.paced = true
                case "--return-only":
                    options.returnOnly = true
                case "--per-provider-timeout":
                    index += 1
                    guard index < arguments.count,
                          let seconds = TimeInterval(arguments[index]), seconds > 0
                    else { throw InvalidArguments() }
                    options.perProviderTimeout = seconds
                case "--batch-budget":
                    index += 1
                    guard index < arguments.count,
                          let seconds = TimeInterval(arguments[index]), seconds > 0
                    else { throw InvalidArguments() }
                    options.batchBudget = seconds
                case "--providers":
                    index += 1
                    guard index < arguments.count else { throw InvalidArguments() }
                    let ids = arguments[index].split(separator: ",").map { $0.lowercased() }
                    guard !ids.isEmpty else { throw InvalidArguments() }
                    options.providerIDs = ids
                case "--scope":
                    index += 1
                    guard index < arguments.count else { throw InvalidArguments() }
                    switch arguments[index] {
                    case "local-accounting": options.scope = .localAccounting
                    case "panel-accounting": options.scope = .panelAccounting
                    default: throw InvalidArguments()
                    }
                default:
                    throw InvalidArguments()
                }
                index += 1
            }
            guard !options.providerIDs.isEmpty else { throw InvalidArguments() }
            return options
        }
    }

    /// The one-shot result for the requested providers. Snapshot payloads are the same Codable
    /// format the snapshot cache persists, so no boundary type needs a second encoding.
    struct Response: Codable {
        var schema: String
        var snapshots: [String: ProviderSnapshot]
        var errors: [String: String]
        var identityKeys: [String: String]
    }

    @MainActor
    public static func run(arguments: [String], defaultsDomain: String) async -> Int32 {
        do {
            let options = try Options.parse(arguments)
            let defaults = try HeadlessDiagnosticCommand.settingsDefaults(domain: defaultsDomain)
            let requestedFamilies = Set(options.providerIDs.map { ProviderAccountID.family(of: $0) })
            let assembly = try await HeadlessProviderAssembly.assemble(
                defaults: defaults,
                settingsDomainName: defaultsDomain,
                forceEnabledFamilies: requestedFamilies
            )
            let knownIDs = Set(assembly.registry.providers.map(\.id))
            for providerID in options.providerIDs where !knownIDs.contains(providerID) {
                FileHandle.standardError.write(Data("quotabar: unknown provider: \(providerID)\n".utf8))
                return 2
            }
            let response: Response
            if options.returnOnly {
                response = await Self.collectUnpublishedSnapshots(
                    options: options,
                    providers: assembly.providers,
                    defaultIdentityKeys: assembly.providerIdentityKeys
                )
            } else {
                let cache = ProviderSnapshotCache(userDefaults: defaults, allowsPersistedFreshness: true)
                let dataStore = WidgetDataStore(
                    registry: assembly.registry,
                    providers: assembly.providers,
                    cache: cache,
                    defaults: defaults,
                    isProviderEnabled: { id in
                        requestedFamilies.contains(ProviderAccountID.family(of: id))
                    },
                    providerIdentityKeys: assembly.providerIdentityKeys
                )
                // Fold-only scope: local corpora recompute, no live quota APIs. Closed-panel background
                // passes run paced (7.5% of one core); panel-open accounting runs unpaced to make its
                // provider deadline, mirroring the scheduler's pacing choice in the app.
                await ProviderRefreshContext.$scope.withValue(options.scope) {
                    await ProviderRefreshContext.$accountingCPUThrottleEnabled.withValue(options.paced) {
                        for providerID in options.providerIDs {
                            _ = await dataStore.refresh(
                                providerID: providerID,
                                force: true,
                                bypassSnapshotCache: true
                            )
                        }
                    }
                }
                response = Response(
                    schema: schemaName,
                    snapshots: options.providerIDs.reduce(into: [:]) { partial, id in
                        if let snapshot = dataStore.snapshots[id] { partial[id] = snapshot }
                    },
                    errors: options.providerIDs.reduce(into: [:]) { partial, id in
                        if let error = dataStore.providerErrors[id] { partial[id] = error }
                    },
                    identityKeys: options.providerIDs.reduce(into: [:]) { partial, id in
                        if let key = assembly.providerIdentityKeys[id] { partial[id] = key }
                    }
                )
            }
            // A one-shot process has no run loop to outlive the scan caches' debounced writes;
            // drain them before the results (and their cache inputs) are reported.
            await PersistentJSONLScanCaches.flushPendingWrites()
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(response)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
            return 0
        } catch {
            FileHandle.standardError.write(Data("quotabar: \(error.localizedDescription)\n".utf8))
            if error is Options.InvalidArguments { return 2 }
            return 4
        }
    }

    /// The calling store already owns the refresh order. Do not open a second snapshot transaction
    /// in its child: that newer write would fence off the result the parent is waiting for.
    @MainActor
    static func collectUnpublishedSnapshots(
        options: Options,
        providers: [ProviderRuntime],
        defaultIdentityKeys: [String: String]
    ) async -> Response {
        let byID = Dictionary(uniqueKeysWithValues: providers.map { ($0.provider.id, $0) })
        var response = Response(schema: schemaName, snapshots: [:], errors: [:], identityKeys: [:])
        let batchStart = Date()
        for id in options.providerIDs {
            guard let provider = byID[id], !Task.isCancelled else { continue }
            // A batch child dies at the parent's process timeout; providers still waiting when the
            // budget is spent are omitted entirely so the caller retries them rather than
            // surfacing an error for folds that never started.
            let remaining = options.batchBudget.map { $0 - Date().timeIntervalSince(batchStart) }
            if let remaining, remaining < 5 { break }
            let identity = ProviderCacheIdentityResult()
            let timeout = min(
                options.perProviderTimeout ?? WidgetDataStore.defaultProviderRefreshTimeout,
                remaining ?? .greatestFiniteMagnitude
            )
            let snapshot = await ProviderRefreshContext.$scope.withValue(options.scope) {
                await ProviderRefreshContext.$accountingCPUThrottleEnabled.withValue(options.paced) {
                    // A scan-worker is a short-lived child its parent blocks on — the background
                    // 7.5% pace just stretches the same CPU seconds ~3x longer. Use the
                    // interactive allowance so the fold finishes while the caller still waits.
                    await ProviderRefreshContext.$accountingCPUInteractiveBudgetEnabled.withValue(options.paced) {
                        await ProviderRefreshContext.$cacheIdentityResult.withValue(identity) {
                            await ProviderRefreshDeadline.snapshot(from: provider, timeout: timeout)
                        }
                    }
                }
            }
            if let snapshot {
                response.snapshots[id] = snapshot
                response.identityKeys[id] = identity.value ?? defaultIdentityKeys[id]
            } else {
                response.errors[id] = "Accounting refresh timed out"
            }
        }
        return response
    }
}
