import Foundation

/// Where Hermes keeps its session database on this machine. Resolution mirrors Hermes itself: an
/// explicit `HERMES_HOME` wins, otherwise the default `~/.hermes` (see `hermes_constants.get_hermes_home()`
/// in the Hermes Agent docs, developer-guide/session-storage.md).
enum HermesPaths {
    static func homeDirectory(environment: EnvironmentReading, homeDirectory: URL) -> URL {
        if let override = environment.value(for: "HERMES_HOME")?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            return expandHome(override, userHome: homeDirectory)
        }
        return homeDirectory.appendingPathComponent(".hermes", isDirectory: true)
    }

    /// The SQLite database that persists Hermes sessions, token counters, and billing metadata.
    static func stateDBPath(environment: EnvironmentReading, homeDirectory: URL) -> String {
        HermesPaths.homeDirectory(environment: environment, homeDirectory: homeDirectory)
            .appendingPathComponent("state.db").path
    }

    private static func expandHome(_ path: String, userHome: URL) -> URL {
        guard path.hasPrefix("~/") else { return URL(fileURLWithPath: path) }
        return userHome.appendingPathComponent(String(path.dropFirst(2)))
    }
}
