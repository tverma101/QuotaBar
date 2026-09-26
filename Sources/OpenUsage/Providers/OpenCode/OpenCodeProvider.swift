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
    /// The `/zen/go/v1/usage` account endpoint rejected the `opencode-go` key (401/403) — stale or
    /// revoked. The card keeps working off local logs, but the account meters are unavailable.
    case accountAPIUnauthorized
    /// The account endpoint answered with an unexpected HTTP status. `statusCode` feeds telemetry; the
    /// card falls back to local logs.
    case accountAPIRequestFailed(Int)
    /// The account endpoint answered but its payload couldn't be used (network failure, malformed or
    /// partial JSON, non-`ok` windows). `detail` is for the log file only. The card falls back to local
    /// logs rather than rendering partial meters.
    case accountAPIUnavailable(detail: String)

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "OpenCode not detected. Log in with OpenCode Go or use OpenCode locally first."
        case .credentialsUnreadable:
            return "Couldn't read OpenCode's auth.json. Check its file permissions or log into OpenCode Go again."
        case .databaseUnreadable:
            return "Couldn't read OpenCode's local database. Quit OpenCode and refresh, or check the data directory's permissions."
        case .accountAPIUnauthorized:
            return "OpenCode Go rejected the saved key. Log into OpenCode Go again; showing local usage meanwhile."
        case .accountAPIRequestFailed:
            return "OpenCode's usage service had an error. Showing local usage meanwhile."
        case .accountAPIUnavailable:
            return "Couldn't reach OpenCode's usage service. Showing local usage meanwhile."
        }
    }
}

/// Tracks OpenCode-hosted usage (the Go subscription + the Zen pay-as-you-go gateway). The Go plan caps
/// come from OpenCode's account-wide `/zen/go/v1/usage` API (authoritative — every machine and client)
/// and fall back to the local SQLite logs when the API is unreachable; the spend tiles + usage trend are
/// always read from the local logs. See `OpenCodeUsageScanner` and `OpenCodeGoUsageClient`.
@MainActor
final class OpenCodeProvider: ProviderRuntime {
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

    /// Names the local source on hover (the dollars can only undercount true account usage — this
    /// machine only). No "(estimated)": OpenCode records its own per-message cost, so the values are
    /// measured, not imputed.
    private let sourceNote = "From your OpenCode logs"

    /// Edge-triggers the auth-read-failure log so a persistently unreadable `auth.json` warns once per
    /// run, not once per 5-minute refresh.
    private var loggedAuthReadFailure = false

    /// Edge-triggers the account-API failure log the same way — a long offline stretch must not spam
    /// the log every refresh.
    private var loggedAccountAPIFailure = false

    /// Edge-triggers the app-saved-keys read failure the same way (corrupt store file).
    private var loggedStoredKeysFailure = false

    init(
        authStore: OpenCodeAuthStore = OpenCodeAuthStore(),
        usageScanner: OpenCodeUsageScanner = OpenCodeUsageScanner(
            claudeRoots: { OpenCodeUsageScanner.discoverClaudeRoots() },
            codexHomes: { CodexLogUsageScanner.discoverCodexHomes() },
            hermesStateDBPath: { (try? HermesUsageScanner.defaultDatabasePaths())?.first },
            museRoots: { [OpenCodeUsageScanner.museSessionsRoot()] }
        ),
        usageClient: OpenCodeGoUsageClient = OpenCodeGoUsageClient(),
        pricing: @escaping @Sendable () async -> ModelPricing = { await ModelPricingStore.shared.current() },
        now: @escaping @Sendable () -> Date = Date.init,
        goKeyStore: OpenCodeGoKeyStore = OpenCodeGoKeyStore(),
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
    }

    var widgetDescriptors: [WidgetDescriptor] {
        // Go plan caps as percent meters (Session/Weekly above the fold, Monthly on demand) — fed by
        // the account-wide API when it answers, by local `opencode-go` spend otherwise; the spend tiles
        // + trend below sum combined OpenCode-hosted (Go + Zen) spend.
        [
            .percent(id: "opencode.session", provider: provider, title: "Session", sessionStartSignal: .zeroUsage)
                .exportingLimit("session", unit: "percent", estimated: true),
            .percent(id: "opencode.weekly", provider: provider, title: "Weekly")
                .exportingLimit("weekly", unit: "percent", estimated: true),
            .percent(id: "opencode.monthly", provider: provider, title: "Monthly")
                .exportingLimit("monthly", unit: "percent", estimated: true),
            .usageTrend(provider: provider)
                .exportingHistory(
                    scope: .machineLocal,
                    estimatedCost: false,
                    sourceNote: sourceNote
                )
        ] + WidgetDescriptor.spendTiles(provider: provider)
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
            if (try? goKeyStore.loadKeys())?.isEmpty == false { return true }
            return usageScanner.hasHostedUsage()
        }
    }

    func refresh() async -> ProviderSnapshot {
        // One clock for the whole refresh, so the scan cutoff, tiles, trend, and snapshot timestamp
        // can't straddle a midnight boundary.
        let refreshedAt = now()

        // An unreadable auth.json must not kill a refresh that can still read the database (a Zen user
        // stays live), but it stays distinguishable from "not logged in" when nothing else loads.
        var apiKeys: [(name: String, key: String, id: String, source: OpenCodeGoKeySource)] = []
        var authReadError: OpenCodeUsageError?
        do {
            let fileKeys = try await loadOffMainActor { [authStore] in try authStore.apiKeys() }
            loggedAuthReadFailure = false
            apiKeys = fileKeys.map { (name: $0.name, key: $0.key, id: $0.name, source: .authFile) }
        } catch let error as OpenCodeUsageError {
            authReadError = error
            if case .credentialsUnreadable(let detail) = error, !loggedAuthReadFailure {
                loggedAuthReadFailure = true
                AppLog.warn(LogTag.plugin("opencode"), "auth.json unreadable: \(detail)")
            }
        } catch {
            authReadError = .credentialsUnreadable(detail: error.localizedDescription)
        }
        // App-saved keys are independent of auth.json's health: a broken auth.json must not hide
        // keys the user stored in settings.
        if let storedKeys = try? await loadOffMainActor({ [goKeyStore] in try goKeyStore.loadKeys() }) {
            apiKeys += storedKeys.map {
                (name: $0.label, key: $0.key, id: $0.id.uuidString, source: .appSaved)
            }
        } else if !loggedStoredKeysFailure {
            loggedStoredKeysFailure = true
            AppLog.warn(LogTag.plugin("opencode"), "app-saved OpenCode Go keys unreadable; using auth.json keys only")
        }
        let hasGoKey = !apiKeys.isEmpty

        // History-skip note: OpenCode's Session/Weekly meters can fall back to `goWindows` derived
        // from the same local scan that builds spend history, so there is no clean quota-vs-history
        // split. Unpinned OpenCode cards are simply omitted from `.menuBar` passes by
        // `MenuBarRefreshFilter` instead.
        let modelPricing = await pricing()
        let scan: OpenCodeUsageScan?
        do {
            scan = try await usageScanner.scan(now: refreshedAt, hasGoKey: hasGoKey, pricing: modelPricing)
        } catch {
            return ProviderSnapshot.error(provider: provider, error: error)
        }

        // Account-wide Go meters are fetched only with Go credentials. The API does not return a
        // stable account id, so the exact credential is the only honest identity boundary. Duplicate
        // copies of the same key (auth.json plus an app-saved copy) collapse; different keys remain
        // separate even when their current window values happen to match.
        var accountUsages: [(name: String, keyID: String, credentialID: String, usage: OpenCodeGoAccountUsage)] = []
        if !apiKeys.isEmpty {
            for entry in apiKeys {
                do {
                    accountUsages.append((
                        entry.name,
                        entry.id,
                        Self.credentialID(for: entry.key),
                        try await usageClient.fetchUsage(key: entry.key)
                    ))
                    loggedAccountAPIFailure = false
                } catch {
                    if !loggedAccountAPIFailure {
                        loggedAccountAPIFailure = true
                        AppLog.warn(LogTag.plugin("opencode"), "account usage API unavailable (\(entry.name)): \(error.localizedDescription)")
                    }
                }
            }
        }
        // Deduplicate exact-key answers while remembering which key resolved to which account, so a
        // pinned selection can narrow the card to one account's meters.
        var accountIndexByKeyID: [String: Int] = [:]
        var keyNameByKeyID: [String: String] = [:]
        var distinctAccounts: [(name: String, credentialID: String, usage: OpenCodeGoAccountUsage)] = []
        for entry in accountUsages where entry.usage.isAvailable {
            keyNameByKeyID[entry.keyID] = entry.name
            if let idx = distinctAccounts.firstIndex(where: { $0.credentialID == entry.credentialID }) {
                accountIndexByKeyID[entry.keyID] = idx
            } else {
                accountIndexByKeyID[entry.keyID] = distinctAccounts.count
                distinctAccounts.append((entry.name, entry.credentialID, entry.usage))
            }
        }
        let accountMeters: [MetricLine]
        if distinctAccounts.count == 1 {
            accountMeters = OpenCodeUsageMapper.accountMeterLines(distinctAccounts[0].usage)
        } else if let selectedID = activeKeyID(),
                  let idx = accountIndexByKeyID[selectedID],
                  let selectedName = keyNameByKeyID[selectedID] {
            // A pinned key: swap the card to its account only, labeled so the view stays unambiguous.
            accountMeters = OpenCodeUsageMapper.accountMeterLines(distinctAccounts[idx].usage, labelSuffix: selectedName)
        } else {
            // No selection (or it doesn't match a fetched key): every distinct account as separate rows.
            accountMeters = distinctAccounts.flatMap { entry in
                OpenCodeUsageMapper.accountMeterLines(entry.usage, labelSuffix: entry.name)
            }
        }
        let hasAccountUsage = !distinctAccounts.isEmpty

        guard let scan else {
            // No OpenCode database on disk at all.
            if hasGoKey {
                // Freshly logged into Go, before the first local message: the key alone establishes the
                // plan, so the meters show (account-wide values when the API answers, the published
                // caps at 0% otherwise) rather than a bare "No usage data".
                let windows = OpenCodeGoWindowMath.compute(costs: [], anchorMs: nil, now: refreshedAt)
                let meters = hasAccountUsage ? accountMeters : OpenCodeUsageMapper.meterLines(windows)
                return ProviderSnapshot.make(
                    provider: provider, plan: "Go",
                    lines: meters, refreshedAt: refreshedAt
                )
            }
            return ProviderSnapshot.error(
                provider: provider, error: authReadError ?? OpenCodeUsageError.notLoggedIn
            )
        }

        var lines: [MetricLine] = []
        if hasAccountUsage {
            // Authoritative account-wide percentages — the meters' primary source.
            lines.append(contentsOf: accountMeters)
        } else if let windows = scan.goWindows {
            // API unreachable or not usable: local-observed spend against the published caps.
            lines.append(contentsOf: OpenCodeUsageMapper.meterLines(windows))
        }
        SpendTileMapper.appendTokenUsage(
            scan.logScan.series, to: &lines, now: refreshedAt,
            estimated: scan.includesEstimatedCost,
            unknownModelsByDay: scan.logScan.unknownModelsByDay,
            modelUsage: scan.logScan.modelUsage,
            modelSourceNote: sourceNote,
            partialDays: scan.partialDays
        )
        SpendTileMapper.appendUsageTrend(scan.logScan.series, to: &lines, now: refreshedAt, note: sourceNote,
                                         partialDays: scan.partialDays)
        MetricLine.appendNoDataIfNeeded(&lines)

        // `goWindows` is present only on a current Go signal (key or recent spend), never a stale anchor,
        // so it's the honest source for the plan badge too.
        let plan: String? = (hasAccountUsage || scan.goWindows != nil) ? "Go" : nil
        return ProviderSnapshot.make(
            provider: provider,
            plan: plan,
            lines: lines,
            refreshedAt: refreshedAt,
            usageHistory: ProviderUsageHistory(
                series: scan.logScan.series,
                modelUsage: scan.logScan.modelUsage,
                unknownModelsByDay: scan.logScan.unknownModelsByDay
            )
        )
    }

    private static func credentialID(for key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - GoKeyManaging (settings: multiple keys + active-key swap)

extension OpenCodeProvider: GoKeyManaging {
    /// Every key the card can use, in fetch order. The settings section renders this list and
    /// drives `selectGoKey` — the same merge `refresh()` performs, in one readable helper.
    private func allGoKeys() throws -> [(name: String, key: String, id: String, source: OpenCodeGoKeySource)] {
        let fileKeys: [(name: String, key: String, id: String, source: OpenCodeGoKeySource)] = try authStore.apiKeys().map {
            (name: $0.name, key: $0.key, id: $0.name, source: .authFile)
        }
        let storedKeys: [(name: String, key: String, id: String, source: OpenCodeGoKeySource)] = try goKeyStore.loadKeys().map {
            (name: $0.label, key: $0.key, id: $0.id.uuidString, source: .appSaved)
        }
        return fileKeys + storedKeys
    }

    func goKeyEntries() -> [OpenCodeGoKeyEntry] {
        let selection = activeKeyID()
        guard let keys = try? allGoKeys() else {
            AppLog.warn(LogTag.plugin("opencode"), "Go keys unreadable; settings list empty")
            return []
        }
        return keys.map { entry in
            OpenCodeGoKeyEntry(
                id: entry.id,
                label: entry.name,
                maskedKey: Self.mask(entry.key),
                source: entry.source,
                isActive: entry.id == selection
            )
        }
    }

    @discardableResult
    func saveGoKey(label: String, key: String) throws -> OpenCodeGoKey {
        try goKeyStore.addKey(label: label, key: key)
    }

    func removeGoKey(id: UUID) throws {
        try goKeyStore.removeKey(id: id)
        // Dropping the pinned key must not leave a stale selection behind — refresh would fall
        // back to "all accounts", but the settings list should reflect reality immediately.
        if OpenCodeGoKeyStore.activeSelection() == id.uuidString {
            OpenCodeGoKeyStore.setActiveSelection(nil)
        }
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
