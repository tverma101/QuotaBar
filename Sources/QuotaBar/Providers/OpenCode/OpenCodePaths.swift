import Foundation

/// Where OpenCode keeps its local data on this machine, shared by the auth store (reads `auth.json`)
/// and the usage scanner (reads the SQLite logs). Resolution mirrors OpenCode itself: an explicit
/// `OPENCODE_DATA_DIR` wins, then `$XDG_DATA_HOME/opencode`, then the default `~/.local/share/opencode`.
enum OpenCodePaths {
    static func dataDirectory(environment: EnvironmentReading, homeDirectory: URL) -> String {
        if let override = environment.value(for: "OPENCODE_DATA_DIR")?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            return expandHome(override).trimmingTrailingSlashes
        }
        if let xdg = environment.value(for: "XDG_DATA_HOME")?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            return expandHome(xdg).trimmingTrailingSlashes + "/opencode"
        }
        return homeDirectory.appendingPathComponent(".local/share/opencode").path
    }

    static func authFilePath(dataDirectory: String) -> String {
        dataDirectory.trimmingTrailingSlashes + "/auth.json"
    }

    /// T3 Code provider instances whose driver is `opencode` can run their own private OpenCode
    /// trees — `numes`, `experiential`, `agentrouter-opencode`, `nous-portal` on this machine — that
    /// never appear in the shared OpenCode data directory. Their data directories follow the same
    /// layout (`<tree>/data/opencode/opencode*.db`), so discover them from T3 Code's userdata and
    /// fold them in as additional OpenCode sources. A missing/unreadable T3 Code settings file is
    /// the normal "no T3 Code" case and yields `[]`; a present-and-broken private tree does not
    /// affect the shared instance's rows.
    static func t3CodePrivateDataDirectories(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [String] {
        let settingsURL = homeDirectory
            .appendingPathComponent(".t3/userdata/settings.json", isDirectory: false)
        guard let data = try? Data(contentsOf: settingsURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let instances = object["providerInstances"] as? [String: Any] else { return [] }
        var found: [String] = []
        for (_, raw) in instances {
            guard let instance = raw as? [String: Any],
                  (instance["driver"] as? String) == "opencode",
                  let config = instance["config"] as? [String: Any],
                  let binaryPath = config["binaryPath"] as? String,
                  !binaryPath.isEmpty else { continue }
            // The wrapper exec'd by T3 Code lives at <root>/bin/opencode and points its data dir at
            // <root>/data — do the same computation from the registered binary.
            let root = URL(fileURLWithPath: expandHome(binaryPath))
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let dataRoot = root.appendingPathComponent("data", isDirectory: true)
                .appendingPathComponent("opencode", isDirectory: true)
                .path
            if FileManager.default.fileExists(atPath: dataRoot, isDirectory: nil) {
                found.append(dataRoot)
            }
        }
        return found.sorted()
    }

    /// The providerIDs every T3 Code private OpenCode instance declares for itself. Each private
    /// tree serves exactly its own provider (`numes`, `agentrouter-t3`, `experiential`,
    /// `nous-portal` on this machine); the shared tree serves the Go subscription and Zen
    /// pay-as-you-go. Used by the fold to accept the private rows' provider ids.
    static func t3CodePrivateDeclaredProviderIDs(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Set<String> {
        let settingsURL = homeDirectory
            .appendingPathComponent(".t3/userdata/settings.json", isDirectory: false)
        guard let data = try? Data(contentsOf: settingsURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let instances = object["providerInstances"] as? [String: Any] else { return [] }
        var found = Set<String>()
        for (_, raw) in instances {
            guard let instance = raw as? [String: Any],
                  (instance["driver"] as? String) == "opencode",
                  let config = instance["config"] as? [String: Any],
                  let binaryPath = config["binaryPath"] as? String,
                  !binaryPath.isEmpty else { continue }
            let root = URL(fileURLWithPath: expandHome(binaryPath))
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let configURL = root
                .appendingPathComponent("config", isDirectory: true)
                .appendingPathComponent("opencode", isDirectory: true)
                .appendingPathComponent("opencode.json", isDirectory: false)
            guard let configData = try? Data(contentsOf: configURL),
                  let configObject = try? JSONSerialization.jsonObject(with: configData) as? [String: Any],
                  let providers = configObject["providers"] as? [String: Any] else { continue }
            for providerID in providers.keys {
                found.insert(providerID)
            }
        }
        return found
    }

    /// Every `opencode*.db` file in the data dir. OpenCode partitions its database by release channel —
    /// `opencode.db` for stable (latest/beta/prod) and `opencode-<channel>.db` for others (e.g.
    /// `opencode-next.db` for the `next`/preview line). Globbing all of them (rather than hardcoding
    /// `opencode.db`) means a user on the `next` channel is still tracked. The `.db` suffix excludes the
    /// `-wal`/`-shm` sidecars. Path-sorted for deterministic iteration.
    ///
    /// A missing directory is the normal "never used OpenCode" case and returns `[]`; a directory that
    /// exists but can't be enumerated (permissions, I/O) rethrows so the caller can't mistake broken
    /// access for absence.
    static func databaseFiles(in dataDirectory: String) throws -> [String] {
        let dir = expandHome(dataDirectory)
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: dir)
        } catch {
            guard FileManager.default.fileExists(atPath: dir) else { return [] }
            throw error
        }
        return names
            .filter { $0.hasPrefix("opencode") && $0.hasSuffix(".db") }
            .sorted()
            .map { dir.trimmingTrailingSlashes + "/" + $0 }
    }
}
