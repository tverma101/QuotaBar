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

    struct Options: Equatable, Sendable {
        struct InvalidArguments: LocalizedError {
            var errorDescription: String? {
                "Usage: QuotaBar --scan-worker --providers <id[,id...]> [--scope local-accounting|panel-accounting] [--paced] [--return-only]"
            }
        }
        var providerIDs: [String] = []
        var scope: ProviderRefreshContext.Scope = .panelAccounting
        var paced = false
        var returnOnly = false

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
                forceEnabledFamilies: requestedFamilies,
                // This one-shot child folds only the requested cards: their identity probes
                // resolve now, and any other provider's credential read stays deferred instead
                // of being paid by every spawn.
                identityKeyProviderIDs: Set(options.providerIDs)
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
                    defaultIdentityKey: { await assembly.providerIdentityKey(for: $0) }
                )
            } else {
                let cache = ProviderSnapshotCache(userDefaults: defaults, allowsPersistedFreshness: true)
                // Assembly deferred every per-provider identity probe: resolve only the cards this
                // child was asked to fold so a narrow batch pays only its own credential reads.
                var providerIdentityKeys = assembly.providerIdentityKeys
                for providerID in options.providerIDs {
                    providerIdentityKeys[providerID] = await assembly.providerIdentityKey(for: providerID)
                }
                let dataStore = WidgetDataStore(
                    registry: assembly.registry,
                    providers: assembly.providers,
                    cache: cache,
                    defaults: defaults,
                    isProviderEnabled: { id in
                        requestedFamilies.contains(ProviderAccountID.family(of: id))
                    },
                    providerIdentityKeys: providerIdentityKeys
                )
                // Fold-only scope: local corpora recompute, no live quota APIs. Closed-panel background
                // passes run paced (7.5% of one core); panel-open accounting runs unpaced to make its
                // provider deadline, mirroring the scheduler's pacing choice in the app. The model
                // catalog is likewise the app's job — a one-shot child would discard any feed
                // refresh it fetched, so it only reads what is already on disk.
                await ProviderRefreshContext.$scope.withValue(options.scope) {
                    await ProviderRefreshContext.$accountingCPUThrottleEnabled.withValue(options.paced) {
                        await ProviderRefreshContext.$skipModelCatalogRefresh.withValue(true) {
                            for providerID in options.providerIDs {
                                _ = await dataStore.refresh(
                                    providerID: providerID,
                                    force: true,
                                    bypassSnapshotCache: true
                                )
                            }
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
                        if let key = providerIdentityKeys[id] { partial[id] = key }
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
        await collectUnpublishedSnapshots(
            options: options,
            providers: providers,
            defaultIdentityKey: { defaultIdentityKeys[$0] }
        )
    }

    /// `defaultIdentityKey` resolves a provider's launch identity on demand: the fold usually
    /// reports its own observed identity first, so the credential probe behind the default is
    /// paid only when a provider finished without reporting one.
    @MainActor
    static func collectUnpublishedSnapshots(
        options: Options,
        providers: [ProviderRuntime],
        defaultIdentityKey: (String) async -> String?
    ) async -> Response {
        let byID = Dictionary(uniqueKeysWithValues: providers.map { ($0.provider.id, $0) })
        var response = Response(schema: schemaName, snapshots: [:], errors: [:], identityKeys: [:])
        let orderedProviders = options.providerIDs.compactMap { byID[$0] }
        func isHeavy(_ provider: ProviderRuntime) -> Bool {
            WidgetDataStore.heavyLocalLogProviders.contains(ProviderAccountID.family(of: provider.provider.id))
                || WidgetDataStore.heavyLocalLogProviders.contains(provider.provider.id)
        }
        let light = orderedProviders.filter { !isHeavy($0) }
        let heavy = orderedProviders.filter { isHeavy($0) }
        func record(_ result: (String, ProviderSnapshot?, String?)) async {
            let (id, snapshot, identity) = result
            if let snapshot {
                response.snapshots[id] = snapshot
                if let identity {
                    response.identityKeys[id] = identity
                } else {
                    response.identityKeys[id] = await defaultIdentityKey(id)
                }
            } else {
                response.errors[id] = "Accounting refresh timed out"
            }
        }

        await withTaskGroup(of: (String, ProviderSnapshot?, String?).self) { group in
            for provider in light {
                let work = FoldWork(provider: provider)
                group.addTask { await work.run(options: options) }
            }
            for await result in group { await record(result) }
        }
        for provider in heavy {
            guard !Task.isCancelled else { break }
            await record(await fold(provider, options: options))
        }
        return response
    }

    @MainActor
    private final class FoldWork {
        let provider: ProviderRuntime

        init(provider: ProviderRuntime) {
            self.provider = provider
        }

        func run(options: Options) async -> (String, ProviderSnapshot?, String?) {
            await ScanWorkerCommand.fold(provider, options: options)
        }
    }

    @MainActor
    private static func fold(
        _ provider: ProviderRuntime, options: Options
    ) async -> (String, ProviderSnapshot?, String?) {
        let identity = ProviderCacheIdentityResult()
        let snapshot = await ProviderRefreshContext.$scope.withValue(options.scope) {
            await ProviderRefreshContext.$accountingCPUThrottleEnabled.withValue(options.paced) {
                await ProviderRefreshContext.$cacheIdentityResult.withValue(identity) {
                    // A one-shot child discards whatever feed it refreshes; the app owns catalog
                    // freshness, so the fold reads only what is already on disk.
                    await ProviderRefreshContext.$skipModelCatalogRefresh.withValue(true) {
                        await ProviderRefreshDeadline.snapshot(
                            from: provider, timeout: WidgetDataStore.defaultProviderRefreshTimeout
                        )
                    }
                }
            }
        }
        return (provider.provider.id, snapshot, identity.value)
    }
}
