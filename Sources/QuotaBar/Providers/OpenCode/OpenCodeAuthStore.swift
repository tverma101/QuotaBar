import Foundation

/// Reads the OpenCode Go/Zen credential already on the machine. Local-only — never the network. The
/// `opencode-go` key is both the first-run detection signal and (for a future `/zen/go/v1/usage` API)
/// the Bearer token, so it lives behind one loader.
struct OpenCodeAuthStore: Sendable {
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

    var dataDirectory: String {
        OpenCodePaths.dataDirectory(environment: environment, homeDirectory: homeDirectory())
    }

    var authFilePath: String {
        OpenCodePaths.authFilePath(dataDirectory: dataDirectory)
    }

    /// The non-empty `opencode-go` API key from `auth.json`, or `nil` when the user has not logged into
    /// OpenCode Go. Reads only that one entry — tolerant of unrelated sibling entries (other providers, or
    /// a future non-object field like a schema marker) so one odd value can't hide a valid key. A present
    /// file that can't be read or parsed throws `credentialsUnreadable` so broken storage is never
    /// mistaken for logout; an absent file is the normal "not logged in" `nil`.
    func goAPIKey() throws -> String? {
        try apiKeys().first?.key
    }

    /// Only the `opencode-go` API credential belongs to the Go account-usage endpoint. The sibling
    /// `opencode` credential is a Zen gateway key; sending it to `/zen/go/v1/usage` produces a noisy
    /// 403 and does not establish Go-account identity. Non-api entries and empty keys are skipped; a
    /// present file that can't be read or parsed still throws.
    func apiKeys() throws -> [(name: String, key: String)] {
        let text: String?
        do {
            text = try files.readTextIfPresent(authFilePath)
        } catch {
            throw OpenCodeUsageError.credentialsUnreadable(detail: error.localizedDescription)
        }
        guard let text else { return [] }
        guard let data = text.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            throw OpenCodeUsageError.credentialsUnreadable(detail: "auth.json is not valid JSON")
        }
        let keys = object.compactMap { name, value -> (name: String, key: String)? in
            guard let entry = value as? [String: Any],
                  name.caseInsensitiveCompare("opencode-go") == .orderedSame,
                  entry["type"] as? String == "api",
                  let key = entry["key"] as? String
            else { return nil }
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return (name, trimmed)
        }
        return keys
    }
}
