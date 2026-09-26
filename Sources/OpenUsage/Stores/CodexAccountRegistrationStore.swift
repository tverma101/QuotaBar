import Foundation
import Observation

/// Persists the additional Codex homes that the user explicitly registered in OpenUsage.
///
/// The store contains paths only. Authentication remains owned by the Codex CLI and its `auth.json`
/// file, so OpenUsage never handles a password, token, or browser callback. Homes created by the
/// built-in sign-in flow are registered only after Codex reports identifiable account metadata;
/// homes authenticated outside OpenUsage can be registered explicitly from Settings.
@MainActor
@Observable
final class CodexAccountRegistrationStore {
    static let storageKey = "openusage.codexRegisteredHomes.v1"

    private let defaults: UserDefaults
    private let homeDirectory: URL
    private(set) var registeredHomes: [String]

    init(
        defaults: UserDefaults = .standard,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.defaults = defaults
        self.homeDirectory = homeDirectory
        let saved = defaults.stringArray(forKey: Self.storageKey) ?? []
        self.registeredHomes = Self.normalizedUniqueHomes(saved, homeDirectory: homeDirectory)
        if self.registeredHomes != saved {
            persist()
        }
    }

    /// Add one explicit Codex home. Returns `false` when the path is empty or already registered.
    @discardableResult
    func register(home: String) -> Bool {
        guard let normalized = Self.normalizedHome(home, homeDirectory: homeDirectory),
              !registeredHomes.contains(normalized)
        else { return false }
        registeredHomes.append(normalized)
        persist()
        AppLog.info(.config, "registered Codex home (\(displayPath(normalized)))")
        return true
    }

    /// Remove the OpenUsage registration only. The Codex home and its credentials remain untouched.
    func remove(home: String) {
        guard let normalized = Self.normalizedHome(home, homeDirectory: homeDirectory),
              let index = registeredHomes.firstIndex(of: normalized)
        else { return }
        registeredHomes.remove(at: index)
        persist()
        AppLog.info(.config, "unregistered Codex home (\(displayPath(normalized)))")
    }

    /// Reset removes OpenUsage's path registrations without deleting any Codex data.
    func reset() {
        guard !registeredHomes.isEmpty else { return }
        registeredHomes.removeAll()
        persist()
        AppLog.info(.config, "cleared registered Codex homes")
    }

    /// One canonical spelling used by both persisted registrations and environment configuration.
    /// Existing symlinks resolve to their real directory so `/path`, `/path/`, and a symlink to the
    /// same home cannot register duplicate sources. Nonexistent paths stay absolute and standardized;
    /// this is important for a newly-created home before its first login.
    static func normalizedHome(_ raw: String, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let expanded: String
        if trimmed == "~" {
            expanded = homeDirectory.path
        } else if trimmed.hasPrefix("~/") {
            expanded = homeDirectory.path + String(trimmed.dropFirst())
        } else {
            expanded = trimmed
        }

        guard expanded.hasPrefix("/") else {
            return expanded.trimmingTrailingSlashes.nilIfEmpty
        }
        return URL(fileURLWithPath: expanded)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
            .trimmingTrailingSlashes
            .nilIfEmpty
    }

    private static func normalizedUniqueHomes(_ homes: [String], homeDirectory: URL) -> [String] {
        var seen = Set<String>()
        return homes.compactMap { normalizedHome($0, homeDirectory: homeDirectory) }
            .filter { seen.insert($0).inserted }
    }

    private func persist() {
        defaults.set(registeredHomes, forKey: Self.storageKey)
    }

    private func displayPath(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}
