import Foundation

/// A one-shot backend report using the app's mapper, widget resolver, layout, and tray builder.
/// No AppKit views, status item, panel, server, telemetry startup, or background refresh loop.
@MainActor
enum UsageDiagnostics {
    struct Finding: Encodable {
        var providerID: String
        var severity: String
        var message: String
    }

    struct Report: Encodable {
        var schema = "quotabar.diagnostics.v1"
        var generatedAt: Date
        var providers: [String: Entry]
        var findings: [Finding]
        var menuBar: [TrayGroup]
    }

    struct Entry: Encodable {
        var snapshot: ProviderSnapshot?
        var quotaAgeSeconds: Double?
        var historyAgeSeconds: Double?
        var stale: Bool
        var widgets: [Widget]
        var freebuffSource: FreebuffQuotaObservation?
    }

    struct Widget: Encodable {
        var id: String
        var title: String
        var metricLabel: String
        var hasData: Bool
        var headline: String
        var used: Double?
        var limit: Double?
        var resetsAt: Date?
        var activeSessionExpiries: [Date]
        var activeSessions: [FreebuffActiveSession]?
        var pinned: Bool
        var enabled: Bool
    }

    struct TrayGroup: Encodable {
        var providerID: String
        var values: [String]
    }

    static func make(providerIDs: [String], snapshots: [String: ProviderSnapshot], errors: [String: String],
                     registry: WidgetRegistry, runtimes: [any ProviderRuntime], defaults: UserDefaults,
                     now: Date = Date()) -> Report {
        let selected = Set(providerIDs)
        let layout = LayoutStore(registry: registry, defaults: defaults, isProviderEnabled: { selected.contains($0) })
        let store = WidgetDataStore(registry: registry, providers: [], defaults: defaults)
        store.snapshots = snapshots
        let enabledMetrics = Set(layout.placed.map(\.descriptorID))
        var entries: [String: Entry] = [:]
        var findings: [Finding] = []
        func finding(_ id: String, _ severity: String, _ message: String) {
            findings.append(Finding(providerID: id, severity: severity, message: message))
        }
        for id in providerIDs {
            let snapshot = snapshots[id]
            let quotaAge = snapshot.map { max(0, now.timeIntervalSince($0.quotaRefreshedAt ?? $0.refreshedAt)) }
            let historyAge = snapshot.flatMap { snapshot in
                snapshot.usageHistory.map { _ in max(0, now.timeIntervalSince(snapshot.historyRefreshedAt ?? snapshot.refreshedAt)) }
            }
            let stale = quotaAge.map { $0 >= RefreshSetting.interval } ?? true
            if let error = errors[id] { finding(id, "error", error) }
            if snapshot == nil { finding(id, "error", "No saved or refreshed snapshot is available.") }
            if snapshot != nil, stale { finding(id, "warning", "Live quota data is stale.") }
            if let historyAge, historyAge >= RefreshSetting.interval { finding(id, "warning", "Usage history is stale.") }
            if let warning = snapshot?.warning { finding(id, "warning", warning) }
            if let warning = snapshot?.historyWarning { finding(id, "warning", warning) }
            if let snapshot {
                for line in snapshot.lines where line.isError {
                    if case .badge(_, let text, _, _) = line, errors[id] == nil { finding(id, "error", text) }
                }
                var labels: Set<String> = []
                for line in snapshot.lines {
                    if !labels.insert(line.label).inserted { finding(id, "error", "Duplicate metric: \(line.label)") }
                    switch line {
                    case .progress(let label, let used, let limit, _, _, _, _, _):
                        if !used.isFinite || !limit.isFinite || used < 0 || limit < 0 {
                            finding(id, "error", "Invalid numeric meter: \(label)")
                        }
                    case .values(let label, let values, _, _, _, _):
                        if values.contains(where: { !$0.number.isFinite || $0.number < 0 }) {
                            finding(id, "error", "Invalid numeric value: \(label)")
                        }
                    default: break
                    }
                }
            }
            let source = (runtimes.first { $0.provider.id == id } as? FreebuffProvider)?.quotaObservation
            if let wallet = source?.walletFreebucks,
               case .values(_, let values, _, _, _, _) = snapshot?.line(label: "Hours Balance"),
               values.first?.number != floor(wallet / 5 + 1e-9) {
                finding(id, "error", "Hours Balance does not match the wallet; daily hours must be separate.")
            }
            if let source, let total = source.combinedFreebucks, let daily = source.dailyRemainingFreebucks,
               let wallet = source.walletFreebucks, abs(total - daily - wallet) > 1e-6 {
                finding(id, "warning", "Freebuff's reported total differs from its daily remainder plus wallet.")
            }
            let widgets = registry.descriptors(for: id).map { descriptor in
                let value = store.data(for: descriptor)
                return Widget(id: descriptor.id, title: descriptor.title, metricLabel: descriptor.metricLabel,
                              hasData: value.hasData, headline: value.headline,
                              used: value.hasData && value.limit != nil ? value.used : nil,
                              limit: value.hasData ? value.limit : nil,
                              resetsAt: value.resetsAt,
                              activeSessionExpiries: value.traySessionExpiriesAt.filter { $0 > now }.sorted(),
                              activeSessions: value.activeSessions.isEmpty ? nil : value.activeSessions.filter { $0.expiresAt > now }.sorted { $0.expiresAt < $1.expiresAt },
                              pinned: layout.pinnedMetricIDs.contains(descriptor.id),
                              enabled: enabledMetrics.contains(descriptor.id))
            }
            entries[id] = Entry(snapshot: snapshot, quotaAgeSeconds: quotaAge, historyAgeSeconds: historyAge,
                                stale: stale, widgets: widgets, freebuffSource: source)
        }
        let tray = MenuBarContentBuilder.build(groups: layout.pinnedGroups,
                                               hiddenProviderIDs: layout.hiddenMenuBarProviderIDs,
                                               now: now, data: store.data(for:))
        return Report(generatedAt: now, providers: entries, findings: findings,
                      menuBar: tray.groups.map { TrayGroup(providerID: $0.providerID, values: $0.metrics.map(\.value)) })
    }

    static func encode(_ report: Report) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var value = encoder.singleValueContainer()
            try value.encode(OpenUsageISO8601.string(from: date))
        }
        return try encoder.encode(report)
    }
}
