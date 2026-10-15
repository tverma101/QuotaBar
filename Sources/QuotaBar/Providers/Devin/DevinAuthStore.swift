import Foundation

struct DevinAuth: Hashable, Sendable {
    var apiKey: String
    var apiServerUrl: String?
}

enum DevinAuthError: Error, LocalizedError, Equatable {
    case notLoggedIn
    case credentialsUnreadable

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "Run devin auth login or sign in to Devin and try again."
        case .credentialsUnreadable:
            return "QuotaBar couldn't read Devin's local credentials. Check access to credentials.toml and Devin's state database, then refresh again."
        }
    }
}

struct DevinAuthStore: Sendable {
    static let credentialsPath = "~/.local/share/devin/credentials.toml"
    static let stateDBPath = "~/Library/Application Support/Devin/User/globalStorage/state.vscdb"
    static let defaultAPIServerURL = "https://server.codeium.com"

    var files: TextFileAccessing
    var sqlite: SQLiteAccessing

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        sqlite: SQLiteAccessing = SQLiteCLIAccessor()
    ) {
        self.files = files
        self.sqlite = sqlite
    }

    func loadCredentialsFile() throws -> DevinAuth? {
        let text: String?
        do {
            // `nil` means the source is truly absent. A present file that cannot be read must remain
            // distinguishable so provider detection does not silently hide a configured login.
            text = try files.readTextIfPresent(Self.credentialsPath)
        } catch {
            try ProviderCancellation.rethrowIfCancellation(error)
            AppLog.error(LogTag.auth("devin"), "CLI credentials file read failed")
            throw DevinAuthError.credentialsUnreadable
        }
        guard let text,
              let apiKey = Self.readTomlString(text, key: "windsurf_api_key")
        else { return nil }

        return DevinAuth(
            apiKey: apiKey,
            apiServerUrl: Self.cleanAPIServerURL(Self.readTomlString(text, key: "api_server_url"))
        )
    }

    func loadAppAuth() throws -> DevinAuth? {
        let sql = "SELECT value FROM ItemTable WHERE key = 'windsurfAuthStatus' LIMIT 1"
        let value: String?
        do {
            // A missing database or auth row returns nil from the accessor. Query/open errors are a
            // configured but unreadable source and must not become a false logged-out result.
            value = try sqlite.queryValue(path: Self.stateDBPath, sql: sql)
        } catch {
            try ProviderCancellation.rethrowIfCancellation(error)
            AppLog.error(LogTag.auth("devin"), "app state database credential read failed")
            throw DevinAuthError.credentialsUnreadable
        }

        guard let value else { return nil }
        guard let valueData = value.data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(with: valueData),
              let auth = decoded as? [String: Any]
        else {
            AppLog.error(LogTag.auth("devin"), "app state database credential data could not be decoded")
            throw DevinAuthError.credentialsUnreadable
        }
        guard let apiKey = (auth["apiKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !apiKey.isEmpty else { return nil }

        return DevinAuth(apiKey: apiKey, apiServerUrl: nil)
    }

    func effectiveAPIServerURL(_ auth: DevinAuth) -> String {
        auth.apiServerUrl ?? Self.defaultAPIServerURL
    }

    static func cleanAPIServerURL(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.hasPrefix("https://")
        else {
            return nil
        }
        let withoutTrailingSlashes = trimmed.trimmingTrailingSlashes
        return withoutTrailingSlashes.isEmpty ? nil : withoutTrailingSlashes
    }

    static func readTomlString(_ text: String, key: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespacesAndNewlines) == key
            else {
                continue
            }

            var value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }

            if value.first == "\"" || value.first == "'" {
                return readQuotedTomlString(value)
            }

            if let comment = value.firstIndex(of: "#") {
                value = value[..<comment].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return value.isEmpty ? nil : String(value)
        }
        return nil
    }

    private static func readQuotedTomlString(_ value: String) -> String? {
        guard let quote = value.first else { return nil }
        var output = ""
        var previous: Character?
        for character in value.dropFirst() {
            if character == quote, previous != "\\" {
                let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            output.append(character)
            previous = character
        }
        return nil
    }
}
