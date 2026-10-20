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
            return "No Freebuff login was found. Run ~/.config/manicode/freebuff login (or freebuff login if available), then refresh QuotaBar."
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

/// The credentials file was readable and valid JSON, but the profile QuotaBar reads is not in it.
/// A renamed profile or a newer CLI layout is a naming mismatch, not a missing login, so it must not
/// be reported as "no login was found" — that remedy cannot fix it.
enum FreebuffProfileError: Error, LocalizedError, Equatable {
    case missingDefaultProfile

    var errorDescription: String? {
        switch self {
        case .missingDefaultProfile:
            return "QuotaBar found Freebuff credentials, but they have no `default` profile. Sign in again with the Freebuff CLI, or point FREEBUFF_CONFIG_DIR at the config directory that holds it."
        }
    }
}

/// Declared next to the error it describes so this provider keeps its own telemetry bucket without
/// touching the shared provider-error map.
extension FreebuffProfileError: CategorizedError {
    var errorCategory: ErrorCategory {
        switch self {
        case .missingDefaultProfile: .authInvalid
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
    private static let credentialsReadDiagnosticKey = "auth.freebuff.credentials-read"
    private static let invalidCredentialsDiagnosticKey = "auth.freebuff.credentials-invalid"
    private static let missingDefaultProfileDiagnosticKey = "auth.freebuff.credentials-no-default-profile"

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
            DiagnosticGate.logOnce(for: Self.credentialsReadDiagnosticKey) {
                AppLog.error(LogTag.auth("freebuff"), "credentials file read failed")
            }
            if let fallback = environmentToken() { return fallback }
            throw FreebuffAuthError.credentialsUnreadable
        }
        DiagnosticGate.clearFailure(Self.credentialsReadDiagnosticKey)

        if let contents, !contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let object = ProviderParse.jsonObject(Data(contents.utf8)) else {
                DiagnosticGate.logOnce(for: Self.invalidCredentialsDiagnosticKey) {
                    AppLog.error(LogTag.auth("freebuff"), "credentials file contained invalid JSON")
                }
                if let fallback = environmentToken() { return fallback }
                throw FreebuffAuthError.invalidCredentials
            }
            DiagnosticGate.clearFailure(Self.invalidCredentialsDiagnosticKey)
            guard let profile = object["default"] as? [String: Any] else {
                // The file parsed but names its profile something else. Report that instead of
                // "no login was found", which sends the user back to the CLI for a login that
                // already exists.
                DiagnosticGate.logOnce(for: Self.missingDefaultProfileDiagnosticKey) {
                    AppLog.error(LogTag.auth("freebuff"), "credentials file has no `default` profile")
                }
                if let fallback = environmentToken() { return fallback }
                throw FreebuffProfileError.missingDefaultProfile
            }
            DiagnosticGate.clearFailure(Self.missingDefaultProfileDiagnosticKey)

            let fileToken = Self.trimmed(profile["authToken"])
            if let fileToken {
                return FreebuffAuth(token: fileToken)
            }
            if profile["tokenStore"] as? String == "keychain" {
                let fallback = environmentToken()
                do {
                    if let token = try keychain.readGenericPasswordForRefresh(
                        service: Self.keychainService,
                        account: path,
                        // A usable CLI environment token is already available. Still prefer the
                        // Keychain value when it can be read silently, but do not open a prompt
                        // that repeated manual refreshes would show again after fallback. A new
                        // manual action may retry an earlier blocked item silently so restored
                        // Keychain access can replace a stale environment token.
                        allowInteraction: fallback == nil ? nil : false,
                        recheckBlockedSilently: fallback != nil
                    )?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
                        return FreebuffAuth(token: token)
                    }
                } catch KeychainError.interactionNotAllowed {
                    if let fallback { return fallback }
                    throw FreebuffAuthError.credentialPermissionRequired
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    try ProviderCancellation.rethrowIfCancellation(error)
                    if let fallback { return fallback }
                    throw FreebuffAuthError.credentialsUnreadable
                }
                if let fallback { return fallback }
            }
        } else {
            DiagnosticGate.clearFailure(Self.invalidCredentialsDiagnosticKey)
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
        } catch FreebuffProfileError.missingDefaultProfile {
            // The credentials file is present and readable; it just names its profile differently.
            // That is still a configured Freebuff setup, so the card stays visible with its repair
            // message.
            return true
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
