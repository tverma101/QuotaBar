import Foundation

/// Experimental TPS (tokens/second) Tracker — estimates generation speed from the local logs the
/// machine already records: Claude Code (`<config>/projects/**/*.jsonl`), Codex
/// (`$CODEX_HOME/sessions/**/rollout-*.jsonl`), Grok (`$GROK_HOME/sessions/**/updates.jsonl`),
/// Muse (`~/.local/share/muse/sessions/**\/session.jsonl`) and Pi (`PI_CODING_AGENT_SESSION_DIR` /
/// `~/.pi/agent/sessions/**/*.jsonl`). No credentials, no network, nothing leaves the machine.
///
/// Method: output tokens per consecutive usage report, folded over a 14-day window. Intervals under
/// 0.2 s are timer granularity and intervals over 60 s are tool-call round trips or idle gaps — both
/// are excluded, so the reading is a token-weighted mean of generation-paced intervals. That is an
/// estimate, not a benchmark.
///
/// The provider is a data source for the Total Spend panel's TPS lens; it registers no rows by
/// default — there is no dashboard card.
@MainActor
final class TPSTrackerProvider: ProviderRuntime {
    let provider = Provider(
        id: "tps",
        displayName: "TPS Tracker",
        icon: .providerMark("tps"),
        links: []
    )

    let scanner: TokensPerSecondScanner
    let now: @Sendable () -> Date
    /// Local directories whose presence means "this machine has something to fold" for the
    /// Customize probe. The probe lists what `refresh()` reads, mirroring it without the parse.
    private let logRoots: @Sendable @MainActor () async -> [URL]

    init(
        scanner: TokensPerSecondScanner = TokensPerSecondScanner(),
        now: @escaping @Sendable () -> Date = Date.init,
        logRoots: (@Sendable @MainActor () async -> [URL])? = nil
    ) {
        self.scanner = scanner
        self.now = now
        if let logRoots {
            self.logRoots = logRoots
        } else {
            self.logRoots = {
                await loadOffMainActor {
                    let environment = ProcessEnvironmentReader()
                    let home = FileManager.default.homeDirectoryForCurrentUser
                    var roots: [URL] = []
                    if let raw = environment.value(for: "CLAUDE_CONFIG_DIR")?
                        .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
                        for part in raw.split(separator: ",") {
                            var url = URL(fileURLWithPath: expandHome(
                                String(part).trimmingCharacters(in: .whitespaces)
                            ))
                            if url.lastPathComponent == "projects" { url.deleteLastPathComponent() }
                            roots.append(url.appendingPathComponent("projects"))
                        }
                    } else {
                        let xdg = environment.value(for: "XDG_CONFIG_HOME")?.nilIfEmpty
                            .map { URL(fileURLWithPath: expandHome($0)) }
                            ?? home.appendingPathComponent(".config")
                        roots.append(xdg.appendingPathComponent("claude/projects"))
                        roots.append(home.appendingPathComponent(".claude/projects"))
                    }
                    if let raw = environment.value(for: "CODEX_HOME")?
                        .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
                        for part in raw.split(separator: ",") {
                            let url = URL(fileURLWithPath: expandHome(
                                String(part).trimmingCharacters(in: .whitespaces)
                            ))
                            roots.append(url.appendingPathComponent("sessions"))
                            roots.append(url.appendingPathComponent("archived_sessions"))
                        }
                    } else {
                        roots.append(home.appendingPathComponent(".codex/sessions"))
                        roots.append(home.appendingPathComponent(".codex/archived_sessions"))
                    }
                    if let raw = environment.value(for: "GROK_HOME")?
                        .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
                        roots.append(URL(fileURLWithPath: expandHome(raw)).appendingPathComponent("sessions"))
                    } else {
                        roots.append(home.appendingPathComponent(".grok/sessions"))
                    }
                    roots.append(MusePaths.sessionsDirectory(homeDirectory: home))
                    roots.append(PiPaths.sessionsDirectory(environment: environment, homeDirectory: home))
                    roots.append(home.appendingPathComponent(".zcode/cli/db/db.sqlite"))
                    roots.append(contentsOf: AntigravityConversationReader.conversationRoots(home: home))
                    return roots
                }
            }
        }
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            // The exported history descriptor is what admits the fold to the panel's accounting
            // phase and the batched scan worker — not a dashboard row.
            .values(id: "tps.overall", provider: provider, title: "Est. TPS", metricLabel: "Est. TPS")
                .exportingHistory(
                    scope: .machineLocal,
                    estimatedCost: false,
                    sourceNote: "From your local session logs"
                ),
            .values(id: "tps.claude", provider: provider, title: "Claude", metricLabel: "Claude"),
            .values(id: "tps.codex", provider: provider, title: "Codex", metricLabel: "Codex"),
            .values(id: "tps.grok", provider: provider, title: "Grok", metricLabel: "Grok"),
            .values(id: "tps.muse", provider: provider, title: "Muse", metricLabel: "Muse"),
            .values(id: "tps.pi", provider: provider, title: "Pi", metricLabel: "Pi"),
            .values(id: "tps.zai", provider: provider, title: "Z.ai", metricLabel: "Z.ai"),
            .values(id: "tps.antigravity", provider: provider, title: "Antigravity", metricLabel: "Antigravity")
        ]
    }

    func hasLocalCredentials() async -> Bool {
        let roots = await logRoots()
        return roots.contains(where: Self.pathExists(at:))
    }

    func refresh() async -> ProviderSnapshot {
        // Meters-only passes (menu bar, panel phase 1) skip the local fold; the store's merge
        // keeps the previous rows on the snapshot until the accounting phase refolds.
        if ProviderRefreshContext.scope.skipsLocalAccounting {
            return ProviderSnapshot.make(provider: provider, plan: nil, lines: [], refreshedAt: now())
        }
        guard let estimate = await scanner.scan(daysBack: TokensPerSecond.windowDays, now: now()) else {
            return ProviderSnapshot.error(provider: provider, error: TPSTrackerError.sourceIncomplete)
        }
        // One fold, three windows: the lens switches between Today / 7 Days / 14 Days without
        // re-reading any logs. The full window keeps the historical bare labels.
        let lines = TokensPerSecondWindow.allCases.flatMap { TokensPerSecondMapper.lines(estimate, window: $0) }
        return ProviderSnapshot.make(
            provider: provider,
            plan: nil,
            lines: lines,
            refreshedAt: now()
        )
    }

    private static func pathExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}

enum TPSTrackerError: LocalizedError, CategorizedError {
    /// A source could not be completely read or changed during the fold; showing last-good data beats
    /// publishing a partial rate.
    case sourceIncomplete

    var errorDescription: String? {
        switch self {
        case .sourceIncomplete:
            return "Couldn't finish reading the local session logs"
        }
    }

    var errorCategory: ErrorCategory {
        switch self {
        case .sourceIncomplete: return .other
        }
    }
}
