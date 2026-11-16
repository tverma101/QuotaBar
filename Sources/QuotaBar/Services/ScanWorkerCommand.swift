import Foundation

/// Runs inside the signed app executable (same entry pattern as `HeadlessDiagnosticCommand`),
/// before SwiftUI/AppKit starts, so the parent menu-bar app can delegate the heavy local
/// accounting folds to a short-lived child process. The child process's parse working set — the
/// JSONSerialization churn that interleaves fragmentation into the app's heap — dies with the
/// process instead of settling into the menu-bar app's footprint.
///
/// The child runs the requested providers' fold-only refresh (`.panelAccounting`: no live quota
/// APIs, local corpora only) against the same shared disk caches the app uses, flushes pending
/// cache writes, and emits the refreshed snapshots as JSON on stdout. Cross-process safety is
/// carried by the existing flock layers (`PersistentStoreLock`, `JSONLScanCacheWriter`) and the
/// snapshot cache's refresh-order fencing.
///
/// The parent sets `QUOTABAR_IN_SCAN_WORKER=1` in the child's environment; the providers' fold
/// paths consult it and run their scanners in-process here rather than spawning another child.
public enum ScanWorkerCommand {
    static let schemaName = "quotabar.scan-worker.v1"

    struct Options: Equatable {
        struct InvalidArguments: LocalizedError {
            var errorDescription: String? {
                "Usage: QuotaBar --scan-worker --providers <id[,id...]> [--scope local-accounting|panel-accounting] [--paced]"
            }
        }
        var providerIDs: [String] = []
        var scope: ProviderRefreshContext.Scope = .panelAccounting
        var paced = false

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
            // A one-shot process has no run loop to outlive the scan caches' debounced writes;
            // drain them before the results (and their cache inputs) are reported.
            await PersistentJSONLScanCaches.flushPendingWrites()
            let response = Response(
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
}
