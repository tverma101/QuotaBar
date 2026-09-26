import Foundation

/// The on-disk locations Orca owns for managed Codex accounts and its runtime session mirror.
///
/// This is deliberately path-based as well as marker-based. An QuotaBar process can inherit a
/// stale `CODEX_HOME` without inheriting `ORCA_CODEX_HOME` (for example through a persisted shell
/// snapshot or a launch service), so checking only the marker leaves the exact crossover we are
/// trying to prevent.
enum OrcaCodexHomeBoundary {
    private static let managedPathMarkers = [
        ["Library", "Application Support", "orca", "codex-accounts"],
        ["Library", "Application Support", "orca", "codex-runtime-home"],
    ]

    private static func normalizedPaths(_ rawPath: String) -> [String] {
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return [] }

        let expanded: String
        if path == "~" {
            expanded = FileManager.default.homeDirectoryForCurrentUser.path
        } else if path.hasPrefix("~/") {
            expanded = FileManager.default.homeDirectoryForCurrentUser.path + String(path.dropFirst())
        } else {
            expanded = path
        }

        let urls = [
            URL(fileURLWithPath: expanded).standardizedFileURL,
            URL(fileURLWithPath: expanded).resolvingSymlinksInPath().standardizedFileURL,
        ]
        return Array(Set(urls.map(\.path)))
    }

    private static func containsManagedMarker(_ path: String) -> Bool {
        let components = URL(fileURLWithPath: path).pathComponents
        return managedPathMarkers.contains { marker in
            guard components.count >= marker.count else { return false }
            for start in 0...(components.count - marker.count) {
                if Array(components[start..<(start + marker.count)]) == marker {
                    return true
                }
            }
            return false
        }
    }

    private static func isInside(_ path: String, root: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }

    static func isManaged(_ rawPath: String, orcaUserDataPath: String? = nil) -> Bool {
        let candidates = normalizedPaths(rawPath)
        guard !candidates.isEmpty else { return false }
        if candidates.contains(where: containsManagedMarker) {
            return true
        }

        guard let orcaUserDataPath else { return false }
        let managedRoots = normalizedPaths(orcaUserDataPath)
            .flatMap { base in
                [
                    base + "/codex-accounts",
                    base + "/codex-runtime-home",
                ]
            }
            .flatMap(normalizedPaths)
        return candidates.contains { candidate in
            managedRoots.contains { root in isInside(candidate, root: root) }
        }
    }
}

/// The menu-bar app and one-shot CLI must not treat an Orca-injected `CODEX_HOME` as their own
/// default home. Explicit QuotaBar registrations are handled separately by the account assembly
/// and are never inferred from the overlay marker or accepted as an implicit default.
struct QuotaBarEnvironmentReader: EnvironmentReading {
    let base: EnvironmentReading

    init(base: EnvironmentReading = ProcessEnvironmentReader()) {
        self.base = base
    }

    func value(for name: String) -> String? {
        let orcaUserDataPath = base.value(for: "ORCA_USER_DATA_PATH")?.nilIfEmpty
        switch name {
        case "CODEX_HOME":
            guard let candidate = base.value(for: name)?.nilIfEmpty else {
                return nil
            }
            if base.value(for: "ORCA_CODEX_HOME")?.nilIfEmpty != nil
                || OrcaCodexHomeBoundary.isManaged(candidate, orcaUserDataPath: orcaUserDataPath)
            {
                return nil
            }
            return candidate
        case "OPENUSAGE_CODEX_HOMES":
            // This is an explicit QuotaBar override, but it can still be inherited from an Orca
            // shell or launch service. Keep non-Orca entries usable while dropping managed homes;
            // a path under Orca must be registered through the account flow before it can become a
            // scoped card. Otherwise one leaked list can silently merge Orca rollouts into the
            // default accounting card.
            guard let raw = base.value(for: name)?.nilIfEmpty else { return nil }
            let homes = raw
                .split(whereSeparator: { $0 == "," || $0 == "\n" })
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .filter { !OrcaCodexHomeBoundary.isManaged($0, orcaUserDataPath: orcaUserDataPath) }
            guard !homes.isEmpty else { return nil }
            return homes.joined(separator: ",")
        default:
            return base.value(for: name)
        }
    }
}

/// A narrow environment overlay used by account-scoped provider runtimes. Unspecified keys still
/// resolve through the process/login-shell reader; only the provider home is pinned per account.
struct OverrideEnvironmentReader: EnvironmentReading {
    let base: EnvironmentReading
    let overrides: [String: String]

    init(
        _ overrides: [String: String],
        base: EnvironmentReading = ProcessEnvironmentReader()
    ) {
        self.base = base
        self.overrides = overrides
    }

    func value(for name: String) -> String? {
        overrides[name] ?? base.value(for: name)
    }
}
