import Foundation

/// Runs inside the signed app executable, before SwiftUI/AppKit starts, so its existing Keychain
/// identity can be used silently without launching the menu-bar app or changing Keychain grants.
public enum HeadlessDiagnosticCommand {
    public static func run(arguments: [String], defaultsDomain: String) async -> Int32 {
        do {
            let options = try DiagnosticOptions.parse(arguments)
            let defaults = try settingsDefaults(domain: defaultsDomain)
            let result = try await UsageReader(userDefaults: defaults, settingsDomainName: defaultsDomain)
                .read(providerID: options.providerID, force: options.force, diagnostic: true)
            FileHandle.standardOutput.write(result.data)
            FileHandle.standardOutput.write(Data("\n".utf8))
            return result.warnings.isEmpty ? 0 : 4
        } catch {
            FileHandle.standardError.write(Data("quotabar: \(error.localizedDescription)\n".utf8))
            if error is DiagnosticOptions.InvalidArguments { return 2 }
            if case UsageReaderError.unknownProvider = error { return 2 }
            return 4
        }
    }

    static func settingsDefaults(domain: String, bundleIdentifier: String? = Bundle.main.bundleIdentifier) throws -> UserDefaults {
        // Foundation rejects a suite named after the process's own bundle. A helper needs a suite;
        // the signed app binary already owns this domain and must use its standard defaults.
        if domain == bundleIdentifier { return .standard }
        guard let defaults = UserDefaults(suiteName: domain) else {
            throw UsageReaderError.refreshFailed("Could not open QuotaBar's settings domain.")
        }
        return defaults
    }
}

struct DiagnosticOptions: Equatable {
    struct InvalidArguments: LocalizedError {
        var errorDescription: String? { "Usage: QuotaBar --diagnose [provider] [--force]" }
    }
    var providerID: String?
    var force = false

    static func parse(_ arguments: [String]) throws -> Self {
        var options = Self()
        for argument in arguments {
            switch argument {
            case "--diagnose": break
            case "--force": options.force = true
            default:
                guard !argument.hasPrefix("-"), options.providerID == nil else {
                    throw InvalidArguments()
                }
                options.providerID = argument.lowercased()
            }
        }
        return options
    }
}
