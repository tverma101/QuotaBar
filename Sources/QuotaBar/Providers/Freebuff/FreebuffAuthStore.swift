import Foundation

struct FreebuffAuth: Hashable, Sendable {
    var token: String
}

enum FreebuffAuthError: Error, LocalizedError, Equatable {
    case notLoggedIn
    case invalidConfigDirectory
    case invalidCredentials
    case credentialsUnreadable
    case credentialPermissionRequired
    case tokenInvalid

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "Sign in to Freebuff with its CLI, then refresh QuotaBar."
        case .invalidConfigDirectory:
            return "Freebuff's FREEBUFF_CONFIG_DIR must be an absolute path."
        case .invalidCredentials:
            return "Freebuff's credentials file is invalid. Sign in again with the Freebuff CLI."
        case .credentialsUnreadable:
            return "QuotaBar couldn't read Freebuff's local credentials. Check file or Keychain access."
        case .credentialPermissionRequired:
            return "macOS needs permission to read Freebuff's Keychain item. Choose Always Allow when prompted."
        case .tokenInvalid:
            return "The Freebuff login has expired. Sign in again with the Freebuff CLI."
        }
    }
}

/// Reads the Freebuff CLI's existing `default` profile. Current Freebuff versions keep the token in
/// Keychain (`freebuff-cli`, account = credentials file path) and leave a pointer in credentials.json;
/// older versions may still keep `authToken` in that file. `CODEBUFF_API_KEY` is the CLI's own
/// environment fallback. QuotaBar never launches the CLI or runs a session-admission request.
struct FreebuffAuthStore: Sendable {
    static let keychainService = "freebuff-cli"
    static let credentialsFileName = "credentials.json"

    var files: TextFileAccessing
    var keychain: KeychainAccessing
    var environment: EnvironmentReading
    var homeDirectory: @Sendable () -> URL

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        keychain: KeychainAccessing = SecurityKeychainAccessor(),
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser }
    ) {
        self.files = files
        self.keychain = keychain
        self.environment = environment
        self.homeDirectory = homeDirectory
    }

    func credentialsFilePath() throws -> String {
        let directory: String
        if let configured = environment.value(for: "FREEBUFF_CONFIG_DIR")?.nilIfEmpty {
            guard (configured as NSString).isAbsolutePath else {
                throw FreebuffAuthError.invalidConfigDirectory
            }
            directory = configured
        } else {
            let environmentName = environment.value(for: "NEXT_PUBLIC_CB_ENVIRONMENT") ?? "prod"
            let suffix = environmentName == "prod" ? "" : "-\(environmentName)"
            directory = homeDirectory()
                .appendingPathComponent(".config", isDirectory: true)
                .appendingPathComponent("manicode\(suffix)", isDirectory: true)
                .path
        }
        return URL(fileURLWithPath: directory, isDirectory: true)
            .appendingPathComponent(Self.credentialsFileName)
            .standardizedFileURL.path
    }

    func loadAuth() throws -> FreebuffAuth? {
        let path = try credentialsFilePath()
        let contents: String?
        do {
            contents = try files.readTextIfPresent(path)
        } catch {
            try ProviderCancellation.rethrowIfCancellation(error)
            AppLog.error(LogTag.auth("freebuff"), "credentials file read failed")
            throw FreebuffAuthError.credentialsUnreadable
        }

        if let contents, !contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let object = ProviderParse.jsonObject(Data(contents.utf8)) else {
                throw FreebuffAuthError.invalidCredentials
            }
            guard let profile = object["default"] as? [String: Any] else {
                return environmentToken()
            }

            let fileToken = Self.trimmed(profile["authToken"])
            if let fileToken {
                return FreebuffAuth(token: fileToken)
            }
            if profile["tokenStore"] as? String == "keychain" {
                do {
                    if let token = try keychain.readGenericPasswordForRefresh(
                        service: Self.keychainService,
                        account: path
                    )?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
                        return FreebuffAuth(token: token)
                    }
                } catch KeychainError.interactionNotAllowed {
                    if let fallback = environmentToken() { return fallback }
                    throw FreebuffAuthError.credentialPermissionRequired
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    try ProviderCancellation.rethrowIfCancellation(error)
                    if let fallback = environmentToken() { return fallback }
                    AppLog.error(LogTag.auth("freebuff"), "Keychain credential read failed")
                    throw FreebuffAuthError.credentialsUnreadable
                }
            }
        }

        return environmentToken()
    }

    func hasLocalCredentials() -> Bool {
        do {
            return try loadAuth() != nil
        } catch FreebuffAuthError.notLoggedIn {
            return false
        } catch FreebuffAuthError.credentialPermissionRequired {
            // The profile explicitly points to this Keychain item; the silent read proved that the
            // item exists but requires user interaction. The provider is still locally configured.
            return true
        } catch FreebuffAuthError.credentialsUnreadable, FreebuffAuthError.invalidCredentials {
            // Keep a present but broken profile enabled so the provider can show its typed repair
            // message instead of making a local installation look absent.
            return (try? credentialsFilePath()).map(files.exists) ?? false
        } catch FreebuffAuthError.invalidConfigDirectory {
            // A configured but invalid path is still an explicit Freebuff setup. Keep the provider
            // visible so refresh can show the actionable absolute-path error.
            return true
        } catch {
            return false
        }
    }

    private func environmentToken() -> FreebuffAuth? {
        guard let token = Self.trimmed(environment.value(for: "CODEBUFF_API_KEY")) else { return nil }
        return FreebuffAuth(token: token)
    }

    private static func trimmed(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        return value.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}
