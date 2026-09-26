import Foundation

/// Typed failures for the Hermes provider, so telemetry groups them by a stable category.
enum HermesUsageError: Error, LocalizedError, Equatable {
    /// No Hermes database on this machine at all.
    case notDetected
    /// The database exists but could not be read this refresh (locked, corrupt, permissions).
    case databaseUnreadable(detail: String)

    var errorDescription: String? {
        switch self {
        case .notDetected:
            return "Hermes not detected. Use Hermes (CLI or desktop) once, then refresh."
        case .databaseUnreadable:
            return "Couldn't read Hermes' state database. Quit Hermes and refresh, or check ~/.hermes permissions."
        }
    }
}

/// Probes for Hermes' local session database — the credential equivalent for a local-usage provider:
/// the presence of `~/.hermes/state.db` (or `$HERMES_HOME/state.db`) is what makes the provider
/// relevant on this machine. Local-only, never the network.
struct HermesAuthStore: Sendable {
    var files: TextFileAccessing
    var environment: EnvironmentReading
    var homeDirectory: @Sendable () -> URL

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser }
    ) {
        self.files = files
        self.environment = environment
        self.homeDirectory = homeDirectory
    }

    var databasePath: String {
        HermesPaths.stateDBPath(environment: environment, homeDirectory: homeDirectory())
    }

    /// True when Hermes' state database exists on disk. Absence is the normal "Hermes not installed or
    /// never used" case; an unreadable-but-present database still counts as a footprint so `refresh()`
    /// can surface the actionable error.
    func hasDatabase() -> Bool {
        files.exists(databasePath)
    }
}
