import CryptoKit
import Foundation

/// Typed failures for the OpenCode provider, so telemetry groups them by a stable category
/// (see `ErrorCategory.swift`).
enum OpenCodeUsageError: Error, LocalizedError, Equatable {
    case notLoggedIn
    /// `auth.json` exists but could not be read or parsed — broken storage, not logout. `detail`
    /// carries the underlying cause for the log file; the user-facing description stays friendly.
    case credentialsUnreadable(detail: String)
    /// OpenCode databases exist on disk but none could be read this refresh. Failing loudly here beats
    /// rendering authoritative-looking $0 meters from an empty scan.
    case databaseUnreadable
    /// A discovered local usage source failed mid-read. Do not publish a partial replacement for the
    /// prior history; let the store keep the last-good snapshot and retry next refresh.
    case usageSourcesIncomplete
    /// The `/zen/go/v1/usage` account endpoint rejected the `opencode-go` key (401).
    case accountAPIUnauthorized
    /// The usage endpoint did not confirm a Go entitlement for this key. Keep this distinct from a
    /// bad key; because entitlement lookups can be false negatives, the UI says "couldn't confirm"
    /// and clears the active-plan claim rather than saying the subscription is inactive.
    case accountAPINoEntitlement
    /// The account endpoint returned a malformed body or an unknown window status.
    case accountAPIInvalidResponse
    /// The account endpoint answered with an unexpected HTTP status. `statusCode` feeds telemetry.
    case accountAPIRequestFailed(Int)
    /// The account endpoint answered but its payload couldn't be used (network failure, malformed or
    /// partial JSON, non-`ok` windows). `detail` is for the log file only.
    case accountAPIUnavailable(detail: String)

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "OpenCode not detected. Log in with OpenCode Go or use OpenCode locally first."
        case .credentialsUnreadable:
            return "Couldn't read OpenCode credentials. Check auth.json and QuotaBar's saved Go keys, then refresh again."
        case .databaseUnreadable:
            return "Couldn't read OpenCode's local database. Quit OpenCode and refresh, or check the data directory's permissions."
        case .usageSourcesIncomplete:
            return "Couldn't read all of OpenCode's local usage history. Check its files and refresh again."
        case .accountAPIUnauthorized:
            return "OpenCode couldn't verify this Go key. Check the key and refresh."
        case .accountAPINoEntitlement:
            return "OpenCode couldn't confirm a Go subscription for this key. Check your account or try again."
        case .accountAPIInvalidResponse:
            return "OpenCode returned Go usage data QuotaBar couldn't read. Try refreshing."
        case .accountAPIRequestFailed:
            return "OpenCode's Go usage service returned an error."
        case .accountAPIUnavailable:
            return "Couldn't reach OpenCode's Go usage service."
        }
    }
}

/// Non-secret identity metadata used to construct account-specific meter descriptors before the
/// provider catalog is published. `credentialID` is a one-way hash and is never rendered or logged.
struct OpenCodeGoAccountIdentity: Sendable, Equatable {
    let credentialID: String
    let descriptorKey: String
    let displayName: String
}

/// The local Go-key inventory discovered before the provider catalog is published. The cache key is
/// a fingerprint of sorted credential-to-descriptor mappings, including one-way credential IDs and
/// display labels. It stays stable across source-order changes and changes when a key rotates or its
/// label is reassigned. An unreadable source is represented separately from a complete empty inventory.
struct OpenCodeGoAccountInventory: Sendable, Equatable {
    static let incompleteCacheIdentityKey = "opencode-go-inventory-incomplete-v1"

    let identities: [OpenCodeGoAccountIdentity]
    let credentialIDs: [String]
    let isComplete: Bool
    let cacheIdentityKey: String

    init(accountIdentities: [OpenCodeGoAccountIdentity], isComplete: Bool) {
        let sortedAccounts = accountIdentities.sorted {
            if $0.credentialID != $1.credentialID { return $0.credentialID < $1.credentialID }
            if $0.descriptorKey != $1.descriptorKey { return $0.descriptorKey < $1.descriptorKey }
            return $0.displayName < $1.displayName
        }
        let distinctCredentialIDs = Array(Set(accountIdentities.map(\.credentialID))).sorted()
        self.identities = accountIdentities.count > 1 ? accountIdentities : []
        self.credentialIDs = distinctCredentialIDs
        self.isComplete = isComplete
        if isComplete {
            // Length-prefix arbitrary labels so a label containing a delimiter cannot alias another
            // credential-to-descriptor mapping. Include labels and stable source IDs: an unchanged
            // key set with reassigned names must not paint one account's cached meter under another.
            let mapping = sortedAccounts.map { account in
                [account.credentialID, account.descriptorKey, account.displayName]
                    .map { "\($0.utf8.count):\($0)" }
                    .joined()
            }.joined(separator: ";")
            let material = "opencode-go-inventory-v2|\(mapping)"
            self.cacheIdentityKey = SHA256.hash(data: Data(material.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
        } else {
            self.cacheIdentityKey = Self.incompleteCacheIdentityKey
        }
    }
}

/// Tracks OpenCode-hosted usage (the Go subscription + the Zen pay-as-you-go gateway). Go plan caps
/// come only from a successful `/zen/go/v1/usage` response; local SQLite logs provide spend tiles and
/// history, never subscription caps. See `OpenCodeUsageScanner` and `OpenCodeGoUsageClient`.
@MainActor
final class OpenCodeProvider: ProviderRuntime {
    private static let authFileInventoryReadDiagnosticKey = "opencode.account-inventory.auth-file-read"
    private static let savedKeysInventoryReadDiagnosticKey = "opencode.account-inventory.saved-keys-read"

    let provider = Provider(
        id: "opencode",
        displayName: "OpenCode",
        icon: .providerMark("opencode"),
        links: [
            .init(label: "Dashboard", url: "https://opencode.ai/auth")
        ]
    )

    let authStore: OpenCodeAuthStore
    let usageScanner: OpenCodeUsageScanner
    let usageClient: OpenCodeGoUsageClient
    let goKeyStore: OpenCodeGoKeyStore
    /// Resolves the pinned account selection (a saved key's UUID or an `auth.json` entry name),
    /// or `nil` when no key is pinned — the card then shows every distinct account.
    let activeKeyID: @Sendable () -> String?
    let pricing: @Sendable () async -> ModelPricing
    let now: @Sendable () -> Date
    private let enabledGatewaySources: @MainActor () -> Set<OpenCodeUsageScanner.GatewaySource>
    private let enabledCodexHomes: @MainActor () -> [URL]?
    private let enabledCodexHomeIdentityKeys: @MainActor () -> [String: String]?
    private let enabledClaudeScanners: @MainActor () -> [ClaudeLogUsageScanner]?
    private let enabledCodexIdentityKeys: @MainActor () -> Set<String>?
    private let codexAccountIdentityKeys: @MainActor () -> [String: String]
    private let routerAccountIdentityKeys: @MainActor () -> [String: String]
    private let onGoKeysChanged: @MainActor () -> Void
    private let preloadedAccountIdentities: [OpenCodeGoAccountIdentity]?
    private let preloadedAccountInventory: OpenCodeGoAccountInventory?
    private let accountInventoryDiscoveryDeferred: Bool

    /// Names the local source on hover (the dollars can only undercount true account usage — this
    /// machine only). No "(estimated)": OpenCode records its own per-message cost, so the values are
    /// measured, not imputed.
    private let sourceNote = "From your OpenCode logs"

    /// Edge-triggers the auth-read-failure log so a persistently unreadable `auth.json` warns once per
    /// run, not once per 5-minute refresh.
    private var loggedAuthReadFailure = false

    /// Edge-triggers the account-API failure log the same way — a long offline stretch must not spam
    /// the log every refresh.

    /// Edge-triggers the app-saved-keys read failure the same way (corrupt store file).
    private var loggedStoredKeysFailure = false

    init(
        authStore: OpenCodeAuthStore = OpenCodeAuthStore(),
        usageScanner: OpenCodeUsageScanner = OpenCodeUsageScanner(
            claudeRoots: { OpenCodeUsageScanner.discoverClaudeRoots() },
            codexHomes: { CodexLogUsageScanner.discoverCodexHomes() },
            hermesStateDBPath: {
                try OpenCodeUsageScanner.configuredHermesStateDBPath(
                    environment: QuotaBarEnvironmentReader(),
                    homeDirectory: FileManager.default.homeDirectoryForCurrentUser
                )
            },
            routerLedgerPaths: {
                OpenCodeUsageScanner.configuredRouterLedgerPaths(
                    environment: QuotaBarEnvironmentReader(),
                    homeDirectory: FileManager.default.homeDirectoryForCurrentUser
                )
            },
            museRoots: { [OpenCodeUsageScanner.museSessionsRoot()] }
        ),
        usageClient: OpenCodeGoUsageClient = OpenCodeGoUsageClient(),
        pricing: @escaping @Sendable () async -> ModelPricing = { ModelPricingStore.shared.current() },
        now: @escaping @Sendable () -> Date = Date.init,
        goKeyStore: OpenCodeGoKeyStore = OpenCodeGoKeyStore(),
        enabledGatewaySources: @escaping @MainActor () -> Set<OpenCodeUsageScanner.GatewaySource> = {
            Set(OpenCodeUsageScanner.GatewaySource.allCases)
        },
        enabledCodexHomes: @escaping @MainActor () -> [URL]? = { nil },
        enabledCodexHomeIdentityKeys: @escaping @MainActor () -> [String: String]? = { nil },
        enabledClaudeScanners: @escaping @MainActor () -> [ClaudeLogUsageScanner]? = { nil },
        enabledCodexIdentityKeys: @escaping @MainActor () -> Set<String>? = { nil },
        codexAccountIdentityKeys: @escaping @MainActor () -> [String: String] = { [:] },
        routerAccountIdentityKeys: @escaping @MainActor () -> [String: String] = { [:] },
        onGoKeysChanged: @escaping @MainActor () -> Void = {},
        preloadedAccountIdentities: [OpenCodeGoAccountIdentity]? = nil,
        preloadedAccountInventory: OpenCodeGoAccountInventory? = nil,
        accountInventoryDiscoveryDeferred: Bool = false,
        activeKeyID: @escaping @Sendable () -> String? = {
            UserDefaults.standard.string(forKey: OpenCodeGoKeyStore.selectionKey)
        }
    ) {
        self.authStore = authStore
        self.usageScanner = usageScanner
        self.usageClient = usageClient
        self.pricing = pricing
        self.now = now
        self.goKeyStore = goKeyStore
        self.activeKeyID = activeKeyID
        self.enabledGatewaySources = enabledGatewaySources
        self.enabledCodexHomes = enabledCodexHomes
        self.enabledCodexHomeIdentityKeys = enabledCodexHomeIdentityKeys
        self.enabledClaudeScanners = enabledClaudeScanners
        self.enabledCodexIdentityKeys = enabledCodexIdentityKeys
        self.codexAccountIdentityKeys = codexAccountIdentityKeys
        self.routerAccountIdentityKeys = routerAccountIdentityKeys
        self.onGoKeysChanged = onGoKeysChanged
        self.preloadedAccountInventory = preloadedAccountInventory ?? preloadedAccountIdentities.map {
            OpenCodeGoAccountInventory(accountIdentities: $0, isComplete: true)
        }
        self.preloadedAccountIdentities = preloadedAccountInventory?.identities ?? preloadedAccountIdentities
        self.accountInventoryDiscoveryDeferred = accountInventoryDiscoveryDeferred
    }

    var widgetDescriptors: [WidgetDescriptor] {
        // Go plan caps as percent meters (Session/Weekly/Monthly) — only
        // from a current account-wide API response; local spend tiles + trend sum Go + Zen history.
        let baseMeters: [WidgetDescriptor] = [
            .percent(id: "opencode.session", provider: provider, title: "Session", sessionStartSignal: .zeroUsage)
                .exportingLimit("session", unit: "percent", estimated: true)
                .hidingWhenEmpty(),
            .percent(id: "opencode.weekly", provider: provider, title: "Weekly")
                .exportingLimit("weekly", unit: "percent", estimated: true)
                .hidingWhenEmpty(),
            .percent(id: "opencode.monthly", provider: provider, title: "Monthly")
                .exportingLimit("monthly", unit: "percent", estimated: true)
                .hidingWhenEmpty(),
        ]
        let accountIdentities = preloadedAccountIdentities
            ?? (accountInventoryDiscoveryDeferred ? [] : configuredAccountIdentities())
        return baseMeters + accountIdentities.flatMap { account in
            Self.accountMeterDescriptors(for: account, provider: provider)
        } + [
            .usageTrend(provider: provider)
                .exportingHistory(
                    scope: .machineLocal,
                    estimatedCost: false,
                    sourceNote: sourceNote
                )
        ] + WidgetDescriptor.spendTiles(provider: provider)
    }

    /// Direct, non-deferred provider compositions that omit a preload can derive account descriptors
    /// from the two credential files. A deferred composition must stay read-free even when it omits
    /// an explicit empty preload.
    private func configuredAccountIdentities() -> [OpenCodeGoAccountIdentity] {
        var apiKeys: [(name: String, key: String, id: String, source: OpenCodeGoKeySource)] = []
        if let fileKeys = try? authStore.apiKeys() {
            apiKeys += fileKeys.map { (name: $0.name, key: $0.key, id: $0.name, source: .authFile) }
        }
        if let storedKeys = try? goKeyStore.loadKeys() {
            apiKeys += storedKeys.map {
                (name: $0.label, key: $0.key, id: $0.id.uuidString, source: .appSaved)
            }
        }
        let identities = Self.distinctAccountIdentities(apiKeys: apiKeys)
        return identities.count > 1 ? identities : []
    }

    private func accountInventoryChanged(
        apiKeys: [(name: String, key: String, id: String, source: OpenCodeGoKeySource)],
        authReadSucceeded: Bool,
        savedKeysReadSucceeded: Bool
    ) -> Bool {
        guard !accountInventoryDiscoveryDeferred,
              let preloadedAccountInventory,
              authReadSucceeded,
              savedKeysReadSucceeded
        else { return false }
        let currentInventory = OpenCodeGoAccountInventory(
            accountIdentities: Self.distinctAccountIdentities(apiKeys: apiKeys),
            isComplete: true
        )
        return currentInventory.cacheIdentityKey != preloadedAccountInventory.cacheIdentityKey
            || currentInventory.identities != preloadedAccountInventory.identities
    }

    private func incompleteInventoryErrorSnapshot(_ error: Error) -> ProviderSnapshot {
        ProviderSnapshot.error(
            provider: provider,
            error: error,
            clearsPriorMenuBarQuotaState: true,
            invalidatesQuotaIdentity: true
        )
    }

    /// Read both small credential sources away from the main actor before the app builds its immutable
    /// widget registry. Preserve read completeness as well as descriptors: one readable key does not
    /// prove there are no keys in the unreadable source.
    static func discoverAccountInventory(
        authStore: OpenCodeAuthStore = OpenCodeAuthStore(),
        goKeyStore: OpenCodeGoKeyStore = OpenCodeGoKeyStore()
    ) async -> OpenCodeGoAccountInventory {
        async let fileRead: ([(name: String, key: String)], String?) = loadOffMainActor {
            do { return (try authStore.apiKeys(), nil) }
            catch { return ([], error.localizedDescription) }
        }
        async let savedRead: ([OpenCodeGoKey], String?) = loadOffMainActor {
            do { return (try goKeyStore.loadKeys(), nil) }
            catch { return ([], error.localizedDescription) }
        }
        let (fileResult, savedResult) = await (fileRead, savedRead)
        if let error = fileResult.1 {
            DiagnosticGate.logOnce(for: authFileInventoryReadDiagnosticKey) {
                AppLog.warn(LogTag.plugin("opencode"), "Go account descriptor discovery could not read auth.json: \(error)")
            }
        } else {
            DiagnosticGate.clearFailure(authFileInventoryReadDiagnosticKey)
        }
        if let error = savedResult.1 {
            DiagnosticGate.logOnce(for: savedKeysInventoryReadDiagnosticKey) {
                AppLog.warn(LogTag.plugin("opencode"), "Go account descriptor discovery could not read saved keys: \(error)")
            }
        } else {
            DiagnosticGate.clearFailure(savedKeysInventoryReadDiagnosticKey)
        }
        let apiKeys = fileResult.0.map {
            (name: $0.name, key: $0.key, id: $0.name, source: OpenCodeGoKeySource.authFile)
        } + savedResult.0.map {
            (name: $0.label, key: $0.key, id: $0.id.uuidString, source: OpenCodeGoKeySource.appSaved)
        }
        return OpenCodeGoAccountInventory(
            accountIdentities: distinctAccountIdentities(apiKeys: apiKeys),
            isComplete: fileResult.1 == nil && savedResult.1 == nil
        )
    }

    /// Compatibility view for callers that only need account-specific descriptors.
    static func discoverAccountIdentities(
        authStore: OpenCodeAuthStore = OpenCodeAuthStore(),
        goKeyStore: OpenCodeGoKeyStore = OpenCodeGoKeyStore()
    ) async -> [OpenCodeGoAccountIdentity] {
        await discoverAccountInventory(authStore: authStore, goKeyStore: goKeyStore).identities
    }

    private static func distinctAccountIdentities(
        apiKeys: [(name: String, key: String, id: String, source: OpenCodeGoKeySource)]
    ) -> [OpenCodeGoAccountIdentity] {
        var seenCredentials = Set<String>()
        var identities: [(credentialID: String, descriptorKey: String, displayName: String)] = []
        for entry in apiKeys {
            let credentialID = Self.credentialID(for: entry.key)
            guard seenCredentials.insert(credentialID).inserted else { continue }
            let name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
            identities.append((
                credentialID,
                Self.stableDescriptorKey(for: entry.id),
                name.isEmpty ? "Account \(identities.count + 1)" : name
            ))
        }

        let nameCounts = Dictionary(grouping: identities, by: { $0.displayName }).mapValues(\.count)
        var nameOrdinals: [String: Int] = [:]
        let preferredNames = identities.map { identity -> String in
            guard nameCounts[identity.displayName, default: 0] > 1 else { return identity.displayName }
            let ordinal = nameOrdinals[identity.displayName, default: 0] + 1
            nameOrdinals[identity.displayName] = ordinal
            return "\(identity.displayName) · \(ordinal)"
        }
        let preferredNameCounts = Dictionary(grouping: preferredNames, by: \.self).mapValues(\.count)
        let reservedNames = Set(preferredNames)
        var usedNames = Set<String>()
        return identities.enumerated().map { index, identity in
            let preferred = preferredNames[index]
            var displayName = preferred
            if preferredNameCounts[preferred, default: 0] > 1 {
                displayName = "\(preferred) · \(identity.descriptorKey.prefix(8))"
                var suffix = 2
                while reservedNames.contains(displayName) || usedNames.contains(displayName) {
                    displayName = "\(preferred) · \(identity.descriptorKey) · \(suffix)"
                    suffix += 1
                }
            }
            if usedNames.contains(displayName) {
                // A configured label can itself match a generated suffix; preserve one row per account.
                var suffix = 2
                let base = displayName
                repeat {
                    displayName = "\(base) · \(suffix)"
                    suffix += 1
                } while reservedNames.contains(displayName) || usedNames.contains(displayName)
            }
            usedNames.insert(displayName)
            return OpenCodeGoAccountIdentity(
                credentialID: identity.credentialID,
                descriptorKey: identity.descriptorKey,
                displayName: displayName
            )
        }
    }

    private static func stableDescriptorKey(for accountID: String) -> String {
        SHA256.hash(data: Data(accountID.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func accountMeterDescriptors(
        for account: OpenCodeGoAccountIdentity,
        provider: Provider
    ) -> [WidgetDescriptor] {
        let suffix = "account.\(account.descriptorKey)"
        let sessionLabel = "Session (\(account.displayName))"
        let weeklyLabel = "Weekly (\(account.displayName))"
        let monthlyLabel = "Monthly (\(account.displayName))"
        return [
            .percent(
                id: "opencode.session.\(suffix)", provider: provider, title: sessionLabel,
                metricLabel: sessionLabel, sessionStartSignal: .zeroUsage
            )
            .exportingLimit("session.\(account.descriptorKey)", unit: "percent", estimated: true)
            .hidingWhenEmpty(),
            .percent(
                id: "opencode.weekly.\(suffix)", provider: provider, title: weeklyLabel,
                metricLabel: weeklyLabel
            )
            .exportingLimit("weekly.\(account.descriptorKey)", unit: "percent", estimated: true)
            .hidingWhenEmpty(),
            .percent(
                id: "opencode.monthly.\(suffix)", provider: provider, title: monthlyLabel,
                metricLabel: monthlyLabel
            )
            .exportingLimit("monthly.\(account.descriptorKey)", unit: "percent", estimated: true)
            .hidingWhenEmpty()
        ]
    }

    func hasLocalCredentials() async -> Bool {
        // Same sources as `refresh()`: the local `opencode-go` auth key, app-saved Go keys, or any
        // hosted usage already in the local database. Local-only, off the main actor. An unreadable
        // auth.json is itself an OpenCode footprint — enable the provider so `refresh()` can surface
        // the actionable error.
        await loadOffMainActor { [authStore, goKeyStore, usageScanner] in
            do {
                if try authStore.goAPIKey() != nil { return true }
            } catch {
                return true
            }
            do {
                let keys = try goKeyStore.loadKeys()
                if !keys.isEmpty { return true }
            } catch {
                // The app-saved key file is itself an OpenCode footprint. Keep the provider enabled
                // so refresh can report the read failure instead of recording a one-shot miss.
                return true
            }
            return usageScanner.hasHostedUsage()
        }
    }

    func refresh() async -> ProviderSnapshot {
        guard !Task.isCancelled else { return cancelledRefreshSnapshot(provider: provider) }
        // One clock for the whole refresh, so the scan cutoff, tiles, trend, and snapshot timestamp
        // can't straddle a midnight boundary.
        let refreshedAt = now()

        // An unreadable auth.json must not kill a refresh that can still read the database (a Zen user
        // stays live), but it stays distinguishable from "not logged in" when nothing else loads.
        var apiKeys: [(name: String, key: String, id: String, source: OpenCodeGoKeySource)] = []
        var authReadError: OpenCodeUsageError?
        do {
            let fileKeys = try await loadOffMainActor { [authStore] in try authStore.apiKeys() }
            guard !Task.isCancelled else { return cancelledRefreshSnapshot(provider: provider) }
            loggedAuthReadFailure = false
            apiKeys = fileKeys.map { (name: $0.name, key: $0.key, id: $0.name, source: .authFile) }
        } catch let error as OpenCodeUsageError {
            if Task.isCancelled { return cancelledRefreshSnapshot(provider: provider) }
            authReadError = error
            if case .credentialsUnreadable(let detail) = error, !loggedAuthReadFailure {
                loggedAuthReadFailure = true
                AppLog.warn(LogTag.plugin("opencode"), "auth.json unreadable: \(detail)")
            }
        } catch {
            if Task.isCancelled { return cancelledRefreshSnapshot(provider: provider) }
            authReadError = .credentialsUnreadable(detail: error.localizedDescription)
        }
        // App-saved keys are independent of auth.json's health: a broken auth.json must not hide
        // keys the user stored in settings.
        let storedKeys: [OpenCodeGoKey]?
        var storedKeysReadError: OpenCodeUsageError?
        do {
            storedKeys = try await loadOffMainActor({ [goKeyStore] in try goKeyStore.loadKeys() })
        } catch let error as OpenCodeUsageError {
            storedKeys = nil
            storedKeysReadError = error
        } catch {
            storedKeys = nil
            storedKeysReadError = .credentialsUnreadable(detail: error.localizedDescription)
        }
        guard !Task.isCancelled else { return cancelledRefreshSnapshot(provider: provider) }
        if let storedKeys {
            loggedStoredKeysFailure = false
            apiKeys += storedKeys.map {
                (name: $0.label, key: $0.key, id: $0.id.uuidString, source: .appSaved)
            }
        } else if !loggedStoredKeysFailure {
            loggedStoredKeysFailure = true
            AppLog.warn(LogTag.plugin("opencode"), "app-saved OpenCode Go keys unreadable")
        }
        let incompleteAccountInventoryError = authReadError ?? storedKeysReadError
        if ProviderRefreshContext.scope.skipsLocalAccounting,
           let sourceReadError = incompleteAccountInventoryError {
            // A partial credential read cannot prove the full account inventory, even when the
            // readable source contains only one key. Withhold Go calls until both sources are read;
            // this scoped pass does no local history work, so it can fail immediately.
            return incompleteInventoryErrorSnapshot(sourceReadError)
        }
        // `auth.json` can be changed by OpenCode while QuotaBar is running. If a complete read changes
        // the account-specific descriptor inventory, rebuild the registry before publishing rows;
        // otherwise exact-label resolution would silently drop valid quota and local-limit rows.
        if accountInventoryChanged(
            apiKeys: apiKeys,
            authReadSucceeded: authReadError == nil,
            savedKeysReadSucceeded: storedKeysReadError == nil
        ) {
            AppLog.info(LogTag.plugin("opencode"), "Go account inventory changed; rebuilding provider descriptors")
            onGoKeysChanged()
            return cancelledRefreshSnapshot(provider: provider)
        }
        // Meters-only passes (menu-bar ticks, panel phase 1) need the live Go meters, not the
        // multi-corpus scan: the scan folds Claude/Codex session logs, the router ledger, Hermes,
        // and Muse on every call (15-20s on a real corpus) and would hold the strip's meters
        // hostage behind it. The data-store merge keeps prior spend tiles / history on the card
        // until a fold pass recomputes them. Quota rows are cleared whenever no current account
        // response confirms them.
        if ProviderRefreshContext.scope.skipsLocalAccounting {
            let goAccounts = await fetchGoAccountMeters(apiKeys: apiKeys)
            guard !Task.isCancelled, !goAccounts.cancelled else { return cancelledRefreshSnapshot(provider: provider) }
            if goAccounts.hasUsage {
                var lines = goAccounts.meters
                MetricLine.appendNoDataIfNeeded(&lines)
                return ProviderSnapshot.make(
                    provider: provider,
                    plan: "Go",
                    lines: lines,
                    refreshedAt: refreshedAt,
                    warning: goAccounts.displayError?.error.localizedDescription,
                    clearsPriorMenuBarQuotaState: goAccounts.clearsPriorQuotaState
                )
            }
            // No account answer. Mirror the scan path's not-logged-in handling: no credentials and
            // no OpenCode data directory is the not-logged-in state, discovered without the scan.
            if apiKeys.isEmpty {
                do {
                    guard !Task.isCancelled else { return cancelledRefreshSnapshot(provider: provider) }
                    if try usageScanner.databasePaths().isEmpty {
                        return ProviderSnapshot.error(
                            provider: provider,
                            error: authReadError ?? storedKeysReadError ?? OpenCodeUsageError.notLoggedIn,
                            clearsPriorMenuBarQuotaState: true
                        )
                    }
                } catch {
                    return ProviderSnapshot.error(
                        provider: provider,
                        error: error,
                        clearsPriorMenuBarQuotaState: goAccounts.clearsPriorQuotaState
                    )
                }
            }
            var lines: [MetricLine] = []
            MetricLine.appendNoDataIfNeeded(&lines)
            return ProviderSnapshot.make(
                provider: provider,
                plan: nil,
                lines: lines,
                refreshedAt: refreshedAt,
                warning: goAccounts.displayError?.error.localizedDescription
                    ?? (apiKeys.isEmpty ? (authReadError ?? storedKeysReadError)?.localizedDescription : nil),
                clearsPriorMenuBarQuotaState: goAccounts.clearsPriorQuotaState
            )
        }
        let modelPricing = await pricing()
        guard !Task.isCancelled else { return cancelledRefreshSnapshot(provider: provider) }
        let scan: OpenCodeUsageScan?
        do {
            let enabledSources = enabledGatewaySources()
            scan = try await usageScanner.scan(
                now: refreshedAt,
                daysBack: UsageHistoryWindow.lifetimeDays(through: refreshedAt),
                pricing: modelPricing,
                gatewaySources: enabledSources,
                enabledCodexHomes: enabledSources.contains(.codex)
                    ? (enabledCodexHomes() ?? usageScanner.codexHomes())
                    : [],
                enabledClaudeScanners: enabledSources.contains(.claude) ? enabledClaudeScanners() : [],
                enabledCodexIdentityKeys: enabledSources.contains(.codex) ? enabledCodexIdentityKeys() : [],
                codexHomeIdentityKeys: enabledSources.contains(.codex) ? enabledCodexHomeIdentityKeys() : [:],
                codexAccountIdentityKeys: enabledSources.contains(.codex) ? codexAccountIdentityKeys() : [:],
                routerAccountIdentityKeys: enabledSources.contains(.codex) ? routerAccountIdentityKeys() : [:]
            )
        } catch {
            if Task.isCancelled { return cancelledRefreshSnapshot(provider: provider) }
            if let sourceReadError = incompleteAccountInventoryError {
                return incompleteInventoryErrorSnapshot(sourceReadError)
            }
            // A fold-only pass never asked the account endpoint, so it has no evidence that the
            // meters the meters-only phase just fetched are stale. Clearing them here would wipe
            // freshly recovered quota rows because a local scan failed; the meters phase owns them.
            // A failed local fold proves quotas stale only when this pass actually had a complete
            // credential inventory and was able to ask the account endpoint. Withheld account calls
            // provide no new evidence about the last confirmed Go meters.
            let clearsPriorQuotaState = !ProviderRefreshContext.scope.suppressesLiveQuota
                && incompleteAccountInventoryError == nil
            return ProviderSnapshot.error(
                provider: provider,
                error: error,
                clearsPriorMenuBarQuotaState: clearsPriorQuotaState
            )
        }
        guard !Task.isCancelled else { return cancelledRefreshSnapshot(provider: provider) }

        if let sourceReadError = incompleteAccountInventoryError {
            // Go credentials own the account-cap request, not OpenCode's independent local history.
            // Complete the fold above, publish its history through the failed-refresh merge, and
            // invalidate caps whose current credential owner cannot be verified.
            guard let scan else {
                return incompleteInventoryErrorSnapshot(sourceReadError)
            }
            var snapshot = incompleteInventoryErrorSnapshot(sourceReadError)
            snapshot.refreshedAt = refreshedAt
            snapshot.usageHistory = ProviderUsageHistory(
                series: scan.logScan.series,
                modelUsage: scan.logScan.modelUsage,
                unknownModelsByDay: scan.logScan.unknownModelsByDay,
                apiEstimateByDay: scan.logScan.apiEstimateByDay,
                apiEstimateIncompleteDays: scan.logScan.apiEstimateIncompleteDays,
                partialDays: scan.partialDays,
                estimatedCostDays: scan.logScan.estimatedCostDays ?? []
            )
            return snapshot
        }

        // Account-wide Go meters are fetched only with Go credentials. The API does not return a
        // stable account id, so the exact credential is the only honest identity boundary. Duplicate
        // copies of the same key (auth.json plus an app-saved copy) collapse; different keys remain
        // separate even when their current window values happen to match. Fold-only passes skip the
        // fetch (the meters-only phase just answered it) and recover the meters through the merge.
        let goAccounts = await fetchGoAccountMeters(apiKeys: apiKeys)
        guard !Task.isCancelled, !goAccounts.cancelled else { return cancelledRefreshSnapshot(provider: provider) }
        let accountMeters = goAccounts.meters
        let hasAccountUsage = goAccounts.hasUsage
        let accountErrorForDisplay = goAccounts.displayError
        let clearsPriorMenuBarQuotaState = goAccounts.clearsPriorQuotaState

        guard let scan else {
            // No OpenCode database on disk at all.
            if ProviderRefreshContext.scope.suppressesLiveQuota {
                // Fold-only pass: the meters-only phase just answered the meters and this pass has
                // no fold work without a database. Return a mergeable success snapshot — the bogus
                // "three active Go windows" error here would back off a provider whose only
                // problem is "no local DB" and flip a working card to an error on every panel open.
                var lines = accountMeters
                MetricLine.appendNoDataIfNeeded(&lines)
                return ProviderSnapshot.make(
                    provider: provider,
                    plan: hasAccountUsage ? "Go" : nil,
                    lines: lines,
                    refreshedAt: refreshedAt,
                    warning: accountErrorForDisplay?.error.localizedDescription
                        ?? (apiKeys.isEmpty ? (authReadError ?? storedKeysReadError)?.localizedDescription : nil),
                    clearsPriorMenuBarQuotaState: clearsPriorMenuBarQuotaState
                )
            }
            if hasAccountUsage {
                return ProviderSnapshot.make(
                    provider: provider, plan: "Go",
                    lines: accountMeters,
                    refreshedAt: refreshedAt,
                    warning: accountErrorForDisplay?.error.localizedDescription,
                    clearsPriorMenuBarQuotaState: clearsPriorMenuBarQuotaState
                )
            }
            if let accountErrorForDisplay {
                return ProviderSnapshot.error(
                    provider: provider,
                    error: accountErrorForDisplay.error,
                    clearsPriorMenuBarQuotaState: clearsPriorMenuBarQuotaState
                )
            }
            if !apiKeys.isEmpty {
                return ProviderSnapshot.error(
                    provider: provider,
                    error: OpenCodeUsageError.accountAPIUnavailable(
                        detail: "usage response did not contain three active Go windows"
                    )
                )
            }
            return ProviderSnapshot.error(
                provider: provider,
                error: authReadError ?? storedKeysReadError ?? OpenCodeUsageError.notLoggedIn,
                clearsPriorMenuBarQuotaState: true
            )
        }

        var lines: [MetricLine] = []
        if hasAccountUsage {
            // Authoritative account-wide percentages — the meters' primary source.
            lines.append(contentsOf: accountMeters)
        }
        SpendTileMapper.appendTokenUsage(
            scan.logScan.series, to: &lines, now: refreshedAt,
            estimated: scan.includesEstimatedCost,
            unknownModelsByDay: scan.logScan.unknownModelsByDay,
            modelUsage: scan.logScan.modelUsage,
            modelSourceNote: sourceNote,
            partialDays: scan.partialDays,
            apiEstimateByDay: scan.logScan.apiEstimateByDay,
            estimatedCostDays: scan.logScan.estimatedCostDays ?? []
        )
        SpendTileMapper.appendUsageTrend(scan.logScan.series, to: &lines, now: refreshedAt, note: sourceNote,
                                         partialDays: scan.partialDays)
        MetricLine.appendNoDataIfNeeded(&lines)

        // Both the Go badge and cap meters require a successful current account response. Historical
        // local Go spend stays in spend tiles but never proves an active subscription.
        let plan: String? = hasAccountUsage ? "Go" : nil
        return ProviderSnapshot.make(
            provider: provider,
            plan: plan,
            lines: lines,
            refreshedAt: refreshedAt,
            usageHistory: ProviderUsageHistory(
                series: scan.logScan.series,
                modelUsage: scan.logScan.modelUsage,
                unknownModelsByDay: scan.logScan.unknownModelsByDay,
                apiEstimateByDay: scan.logScan.apiEstimateByDay,
                apiEstimateIncompleteDays: scan.logScan.apiEstimateIncompleteDays,
                partialDays: scan.partialDays,
                estimatedCostDays: scan.logScan.estimatedCostDays ?? []
            ),
            warning: accountErrorForDisplay?.error.localizedDescription
                ?? (apiKeys.isEmpty ? (authReadError ?? storedKeysReadError)?.localizedDescription : nil),
            clearsPriorMenuBarQuotaState: clearsPriorMenuBarQuotaState
        )
    }

    private static func credentialID(for key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func accountAPIDiagnosticKey(for credentialID: String) -> String {
        "provider.opencode.account-api.\(credentialID)"
    }

    /// One pass's Go-account meter answer: the display meters (deduplicated, selection-applied),
    /// whether any account answered, and the error/fallback classification the card composes from.
    /// Shared by the meters-only early path and the scan path so the selection rules live once.
    private struct GoAccountMeters {
        var meters: [MetricLine]
        var hasUsage: Bool
        var displayError: (name: String, keyID: String, error: OpenCodeUsageError)?
        var clearsPriorQuotaState: Bool
        var cancelled: Bool
    }

    /// Fetch every Go credential's account usage and resolve the card's meters. Fold-only passes
    /// (`suppressesLiveQuota`) skip the network entirely and return an empty answer — the store's
    /// merge recovers the meters and carries their freshness stamp.
    private func fetchGoAccountMeters(
        apiKeys: [(name: String, key: String, id: String, source: OpenCodeGoKeySource)]
    ) async -> GoAccountMeters {
        let configuredIdentities = Self.distinctAccountIdentities(apiKeys: apiKeys)
        let displayNameByCredentialID = Dictionary(
            configuredIdentities.map { ($0.credentialID, $0.displayName) },
            uniquingKeysWith: { first, _ in first }
        )
        // auth.json and the app-owned key list can contain the exact same credential. It is one
        // account, so issue one quota request and map every source entry (including a selected copy)
        // back to that result instead of letting a redundant failed request hide the successful one.
        var seenCredentialIDs = Set<String>()
        let uniqueAPIKeys = apiKeys.filter { entry in
            seenCredentialIDs.insert(Self.credentialID(for: entry.key)).inserted
        }
        var accountUsages: [(name: String, keyID: String, credentialID: String, usage: OpenCodeGoAccountUsage)] = []
        var accountAPIErrors: [(name: String, keyID: String, credentialID: String, error: OpenCodeUsageError)] = []
        var wasCancelled = false
        if !uniqueAPIKeys.isEmpty, !ProviderRefreshContext.scope.suppressesLiveQuota {
            for entry in uniqueAPIKeys {
                guard !Task.isCancelled else {
                    wasCancelled = true
                    break
                }
                do {
                    let usage = try await usageClient.fetchUsage(key: entry.key)
                    guard !Task.isCancelled else {
                        wasCancelled = true
                        break
                    }
                    accountUsages.append((
                        entry.name,
                        entry.id,
                        Self.credentialID(for: entry.key),
                        usage
                    ))
                    DiagnosticGate.clearFailure(accountAPIDiagnosticKey(for: Self.credentialID(for: entry.key)))
                } catch {
                    if ProviderCancellation.isCancellation(error) {
                        wasCancelled = true
                        break
                    }
                    let usageError = (error as? OpenCodeUsageError)
                        ?? .accountAPIUnavailable(detail: error.localizedDescription)
                    accountAPIErrors.append(
                        (
                            name: entry.name,
                            keyID: entry.id,
                            credentialID: Self.credentialID(for: entry.key),
                            error: usageError
                        )
                    )
                    let diagnosticKey = accountAPIDiagnosticKey(for: Self.credentialID(for: entry.key))
                    DiagnosticGate.logOnce(for: diagnosticKey) {
                        AppLog.warn(LogTag.plugin("opencode"), "account usage API unavailable (\(entry.name)): \(usageError.localizedDescription)")
                    }
                }
            }
        }
        // Deduplicate exact-key answers while remembering which key resolved to which account, so a
        // pinned selection can narrow the card to one account's meters.
        var accountIndexByKeyID: [String: Int] = [:]
        var distinctAccounts: [(name: String, credentialID: String, usage: OpenCodeGoAccountUsage)] = []
        for entry in accountUsages {
            if let idx = distinctAccounts.firstIndex(where: { $0.credentialID == entry.credentialID }) {
                accountIndexByKeyID[entry.keyID] = idx
            } else {
                accountIndexByKeyID[entry.keyID] = distinctAccounts.count
                distinctAccounts.append((
                    displayNameByCredentialID[entry.credentialID] ?? entry.name,
                    entry.credentialID,
                    entry.usage
                ))
            }
        }
        for entry in apiKeys {
            if let idx = distinctAccounts.firstIndex(where: {
                $0.credentialID == Self.credentialID(for: entry.key)
            }) {
                accountIndexByKeyID[entry.id] = idx
            }
        }
        let selectedKeyID = activeKeyID()
        let selectedKeyIsKnown = selectedKeyID.map { selectedID in
            apiKeys.contains { $0.id == selectedID }
        } ?? false
        let selectedKeyHasAccount = selectedKeyID.map { accountIndexByKeyID[$0] != nil } ?? false
        let meters: [MetricLine]
        if configuredIdentities.count == 1,
           distinctAccounts.count == 1,
           (!selectedKeyIsKnown || selectedKeyHasAccount) {
            // Only one configured account uses the legacy unsuffixed rows. When several accounts are
            // configured but one API call fails, keep the successful account attached to its descriptor.
            meters = OpenCodeUsageMapper.accountMeterLines(distinctAccounts[0].usage)
        } else if selectedKeyIsKnown,
           let selectedKeyID,
           let idx = accountIndexByKeyID[selectedKeyID] {
            // A pinned key: swap the card to its account only, labeled so the view stays unambiguous.
            // Duplicate copies of one credential use the same canonical account label/descriptor.
            meters = OpenCodeUsageMapper.accountMeterLines(
                distinctAccounts[idx].usage,
                labelSuffix: distinctAccounts[idx].name
            )
        } else if selectedKeyIsKnown {
            // The selected key is not one of the usable account responses. Never show a different
            // key's account-wide meter as though it belonged to the pinned account.
            meters = []
        } else {
            // No selection (or it doesn't match a fetched key): every distinct account as separate rows.
            meters = distinctAccounts.flatMap { entry in
                OpenCodeUsageMapper.accountMeterLines(entry.usage, labelSuffix: entry.name)
            }
        }
        let relevantAccountErrors: [(name: String, keyID: String, credentialID: String, error: OpenCodeUsageError)]
        if selectedKeyIsKnown,
           let selectedKeyID,
           let selectedCredentialID = apiKeys.first(where: { $0.id == selectedKeyID }).map({
               Self.credentialID(for: $0.key)
           }) {
            relevantAccountErrors = accountAPIErrors.filter { $0.credentialID == selectedCredentialID }
        } else {
            relevantAccountErrors = accountAPIErrors
        }
        let displayError = relevantAccountErrors.first.map {
            (name: $0.name, keyID: $0.keyID, error: $0.error)
        }
        let hasUsage = !meters.isEmpty
        return GoAccountMeters(
            meters: meters,
            hasUsage: hasUsage,
            displayError: displayError,
            // Only a fresh, successful account response authorizes quota rows. Clear cached caps on
            // outages, missing entitlements, partial account sets, and absent credentials.
            clearsPriorQuotaState: !ProviderRefreshContext.scope.suppressesLiveQuota
                && (!hasUsage || !relevantAccountErrors.isEmpty),
            cancelled: wasCancelled
        )
    }
}

// MARK: - GoKeyManaging (settings: multiple keys + active-key swap)

extension OpenCodeProvider: GoKeyManaging {
    /// Every key the card can use, in fetch order. The settings section renders this list and
    /// drives `selectGoKey` — the same merge `refresh()` performs, in one readable helper.
    private func allGoKeys() async throws -> [(name: String, key: String, id: String, source: OpenCodeGoKeySource)] {
        async let fileKeys: [(name: String, key: String, id: String, source: OpenCodeGoKeySource)] =
            loadOffMainActor { [authStore] in
                try authStore.apiKeys().map {
                    (name: $0.name, key: $0.key, id: $0.name, source: .authFile)
                }
            }
        async let storedKeys: [(name: String, key: String, id: String, source: OpenCodeGoKeySource)] =
            loadOffMainActor { [goKeyStore] in
                try goKeyStore.loadKeys().map {
                    (name: $0.label, key: $0.key, id: $0.id.uuidString, source: .appSaved)
                }
            }
        let (fileValues, storedValues) = try await (fileKeys, storedKeys)
        return fileValues + storedValues
    }

    func goKeyEntries() async -> [OpenCodeGoKeyEntry] {
        async let fileRead: ([(name: String, key: String)], String?) = loadOffMainActor { [authStore] in
            do { return (try authStore.apiKeys(), nil) }
            catch { return ([], error.localizedDescription) }
        }
        async let savedRead: ([OpenCodeGoKey], String?) = loadOffMainActor { [goKeyStore] in
            do { return (try goKeyStore.loadKeys(), nil) }
            catch { return ([], error.localizedDescription) }
        }
        let (fileResult, savedResult) = await (fileRead, savedRead)
        if let error = fileResult.1 {
            DiagnosticGate.logOnce(for: Self.authFileInventoryReadDiagnosticKey) {
                AppLog.warn(LogTag.plugin("opencode"), "Go keys unreadable from auth.json: \(error)")
            }
        } else {
            DiagnosticGate.clearFailure(Self.authFileInventoryReadDiagnosticKey)
        }
        if let error = savedResult.1 {
            DiagnosticGate.logOnce(for: Self.savedKeysInventoryReadDiagnosticKey) {
                AppLog.warn(LogTag.plugin("opencode"), "Go saved keys unreadable: \(error)")
            }
        } else {
            DiagnosticGate.clearFailure(Self.savedKeysInventoryReadDiagnosticKey)
        }
        guard fileResult.1 == nil, savedResult.1 == nil else {
            return []
        }
        let keys = fileResult.0.map {
            (name: $0.name, key: $0.key, id: $0.name, source: OpenCodeGoKeySource.authFile)
        } + savedResult.0.map {
            (name: $0.label, key: $0.key, id: $0.id.uuidString, source: OpenCodeGoKeySource.appSaved)
        }
        let selection = activeKeyID()
        return keys.map { entry in
            OpenCodeGoKeyEntry(
                id: entry.id,
                label: entry.name,
                maskedKey: Self.mask(entry.key),
                accountID: Self.credentialID(for: entry.key),
                source: entry.source,
                isActive: entry.id == selection
            )
        }
    }

    @discardableResult
    func saveGoKey(label: String, key: String) async throws -> OpenCodeGoKey {
        let saved = try await loadOffMainActor { [goKeyStore, label, key] in
            try goKeyStore.addKey(label: label, key: key)
        }
        onGoKeysChanged()
        return saved
    }

    func removeGoKey(id: UUID) async throws {
        try await loadOffMainActor { [goKeyStore, id] in
            try goKeyStore.removeKey(id: id)
        }
        // Dropping the pinned key must not leave a stale selection behind — refresh would fall
        // back to "all accounts", but the settings list should reflect reality immediately.
        if OpenCodeGoKeyStore.activeSelection() == id.uuidString {
            OpenCodeGoKeyStore.setActiveSelection(nil)
        }
        onGoKeysChanged()
    }

    func selectGoKey(id: String) {
        OpenCodeGoKeyStore.setActiveSelection(id)
    }

    func activeGoKeyID() -> String? {
        activeKeyID()
    }

    private static func mask(_ key: String) -> String {
        guard key.count > 8 else { return "••••••••" }
        return String(key.prefix(4)) + "…" + String(key.suffix(4))
    }
}
