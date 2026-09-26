import AppKit
import Foundation
import Observation

/// Runs the official Codex browser-login flow for an additional account.
///
/// QuotaBar owns the isolated `CODEX_HOME` directory, but Codex owns OAuth, the browser callback,
/// token storage, and refresh semantics. The app never creates a token, opens a fake auth page, or
/// asks the user to copy credentials. The login process is launched directly so a registration is a
/// normal Codex sign-in instead of a temporary Terminal script.
@MainActor
@Observable
final class CodexAccountRegistrationService {
    enum State: Equatable {
        case idle
        case signingIn
        case signedIn(label: String?)
        case failed(String)

        var isSigningIn: Bool {
            if case .signingIn = self { return true }
            return false
        }
    }

    struct LoginLaunchSpec: Equatable, Sendable {
        let executable: String
        let arguments: [String]
        let environment: [String: String]
    }

    enum RegistrationError: Error, LocalizedError, Equatable {
        case alreadyRunning
        case alreadyRegistered
        case couldNotCreateHome(String)
        case couldNotStartCodex(String)
        case existingHomeMissingAuth
        case existingHomeNoAccount
        case loginFailed
        case loginProducedNoAccount

        var errorDescription: String? {
            switch self {
            case .alreadyRunning:
                return "A Codex sign-in is already in progress."
            case .alreadyRegistered:
                return "That Codex home is already registered."
            case .couldNotCreateHome:
                return "QuotaBar couldn't create a private Codex account home."
            case .couldNotStartCodex:
                return "QuotaBar couldn't start the Codex CLI. Install Codex or make the `codex` command available, then try again."
            case .existingHomeMissingAuth:
                return "That folder has no auth.json. Sign in with CODEX_HOME set to this folder, then add it again."
            case .existingHomeNoAccount:
                return "That Codex home is not authenticated with an identifiable account. Sign in with Codex, then add it again."
            case .loginFailed:
                return "Codex sign-in did not complete. No account was added."
            case .loginProducedNoAccount:
                return "Codex sign-in finished, but Codex did not provide an identifiable ChatGPT account. No account was added."
            }
        }
    }

    private static let managedRootName = "Codex Accounts"
    private static let managedHomePrefix = "Account-"
    private static let processExecutable = "/usr/bin/env"

    let accounts: CodexAccountRegistrationStore
    /// Called after a newly authenticated home is persisted so the app can rebuild its launch-time
    /// provider catalog and show the account in the same session.
    var onAccountRegistered: (@MainActor () -> Void)?
    private let fileManager: FileManager
    private let applicationSupportDirectory: URL
    private(set) var state: State = .idle

    private var loginProcess: Process?
    private var pendingHome: URL?
    private var outputCapture: LoginOutputCapture?

    init(
        accounts: CodexAccountRegistrationStore,
        fileManager: FileManager = .default,
        applicationSupportDirectory: URL? = nil
    ) {
        self.accounts = accounts
        self.fileManager = fileManager
        self.applicationSupportDirectory = applicationSupportDirectory
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent(
                "Library/Application Support", isDirectory: true
            )
    }

    /// Starts Codex's normal browser OAuth login with a private, isolated home.
    /// The home is persisted only after Codex finishes and its auth metadata names an account. A
    /// failed attempt leaves the exact home on disk but does not register it, so a later
    /// retry cannot accidentally reuse or overwrite a prior account.
    func beginLogin() throws {
        guard loginProcess == nil else { throw RegistrationError.alreadyRunning }

        let home = try makeUnusedHome()
        let spec = Self.loginLaunchSpec(
            homePath: home.path,
            path: Self.effectivePath()
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: spec.executable)
        process.arguments = spec.arguments
        process.environment = ProcessInfo.processInfo.environment.merging(spec.environment) { _, new in new }
        process.currentDirectoryURL = home

        let stdout = Pipe()
        let stderr = Pipe()
        let capture = LoginOutputCapture()
        capture.drain(stdout.fileHandleForReading)
        capture.drain(stderr.fileHandleForReading)
        process.standardOutput = stdout
        process.standardError = stderr
        // Browser OAuth does not need interactive stdin. Closing it also prevents a hidden GUI-launched
        // process from waiting forever for a prompt that the user cannot see.
        process.standardInput = FileHandle.nullDevice

        process.terminationHandler = { [weak self] process in
            let exitCode = process.terminationStatus
            Task { @MainActor [weak self] in
                self?.completeLogin(exitCode: exitCode)
            }
        }

        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            throw RegistrationError.couldNotStartCodex(error.localizedDescription)
        }

        pendingHome = home
        outputCapture = capture
        loginProcess = process
        state = .signingIn
        AppLog.info(.config, "started official Codex browser sign-in for an isolated home")
    }

    /// Cancels the in-flight Codex login. It does not delete the home or any files Codex wrote there.
    /// Keeping the exact home makes a partial sign-in recoverable through “Use Existing Codex Home”.
    func cancelLogin() {
        guard let loginProcess else { return }
        loginProcess.terminate()
        AppLog.info(.config, "cancelled official Codex browser sign-in")
    }

    /// Chooses a home that was already authenticated through Codex outside QuotaBar.
    static func chooseExistingHome() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Choose Codex Home"
        panel.message = "Select the CODEX_HOME directory for an account already authenticated with Codex."
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.resolvingSymlinksInPath().standardizedFileURL
    }

    /// Registers an already-authenticated home only when Codex's own auth metadata identifies it.
    /// This keeps the manual-import path subject to the same attribution rule as browser sign-in.
    func registerExistingHome(at home: URL) throws -> String? {
        let normalizedHome = home.resolvingSymlinksInPath().standardizedFileURL
        guard fileManager.fileExists(
            atPath: normalizedHome.appendingPathComponent("auth.json").path
        ) else {
            throw RegistrationError.existingHomeMissingAuth
        }

        switch accountObserver(for: normalizedHome).observeCodex(home: normalizedHome.path) {
        case .resolved(_, let label, _):
            guard accounts.register(home: normalizedHome.path) else {
                throw RegistrationError.alreadyRegistered
            }
            onAccountRegistered?()
            return label
        case .unresolved, .absent:
            throw RegistrationError.existingHomeNoAccount
        }
    }

    /// Pure command construction seam. This deliberately invokes the real Codex CLI login command;
    /// it never embeds OAuth URLs, token material, or a shell script.
    static func loginLaunchSpec(homePath: String, path: String) -> LoginLaunchSpec {
        LoginLaunchSpec(
            executable: processExecutable,
            arguments: ["codex", "login"],
            environment: [
                "CODEX_HOME": homePath,
                "PATH": path,
            ]
        )
    }

    private func completeLogin(exitCode: Int32) {
        guard let home = pendingHome else {
            loginProcess = nil
            outputCapture = nil
            state = .failed(RegistrationError.loginFailed.localizedDescription)
            return
        }

        loginProcess = nil
        pendingHome = nil
        outputCapture = nil

        // Trust Codex's own exit status only when its resulting auth file also proves which account
        // was signed in. Conversely, a valid auth file wins over a wrapper's non-zero exit so an
        // interrupted UI teardown cannot make a completed browser sign-in unusable.
        switch accountObserver(for: home).observeCodex(home: home.path) {
        case .resolved(_, let label, _):
            guard accounts.register(home: home.path) else {
                state = .failed(RegistrationError.alreadyRegistered.localizedDescription)
                return
            }
            state = .signedIn(label: label)
            AppLog.info(.config, "official Codex browser sign-in completed (exit \(exitCode))")
            onAccountRegistered?()
        case .unresolved:
            state = .failed(RegistrationError.loginProducedNoAccount.localizedDescription)
            AppLog.warn(.config, "Codex login exited \(exitCode) without identifiable account metadata")
        case .absent:
            state = .failed(
                exitCode == 127
                    ? RegistrationError.couldNotStartCodex("codex command not found").localizedDescription
                    : RegistrationError.loginFailed.localizedDescription
            )
            AppLog.warn(.config, "Codex login exited \(exitCode) without an auth file")
        }
    }

    private func accountObserver(for home: URL) -> DefaultAccountObserver {
        DefaultAccountObserver(
            environment: OverrideEnvironmentReader(["CODEX_HOME": home.path]),
            files: LocalTextFileAccessor(),
            keychain: SecurityKeychainAccessor(),
            homeDirectory: { FileManager.default.homeDirectoryForCurrentUser }
        )
    }

    private func makeUnusedHome() throws -> URL {
        let root = applicationSupportDirectory
            .appendingPathComponent("QuotaBar", isDirectory: true)
            .appendingPathComponent(Self.managedRootName, isDirectory: true)

        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            throw RegistrationError.couldNotCreateHome(error.localizedDescription)
        }

        for _ in 0..<20 {
            let home = root.appendingPathComponent(
                Self.managedHomeName(),
                isDirectory: true
            )
            guard !fileManager.fileExists(atPath: home.path) else { continue }
            do {
                try fileManager.createDirectory(at: home, withIntermediateDirectories: false)
                try fileManager.setAttributes(
                    [.posixPermissions: NSNumber(value: Int16(0o700))],
                    ofItemAtPath: home.path
                )
                return home
            } catch {
                try? fileManager.removeItem(at: home)
                throw RegistrationError.couldNotCreateHome(error.localizedDescription)
            }
        }
        throw RegistrationError.couldNotCreateHome("could not allocate an unused account directory")
    }

    static func managedHomeName(id: UUID = UUID()) -> String {
        "\(managedHomePrefix)\(id.uuidString)"
    }

    private static func effectivePath() -> String {
        let inherited = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let shellPath = LoginShellEnvironment.shared.value(for: "PATH") ?? inherited
        let common = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/bin", isDirectory: true).path,
            "/Applications/ChatGPT.app/Contents/Resources",
            "/usr/bin",
            "/bin",
        ]
        var seen = Set<String>()
        return (shellPath.split(separator: ":").map(String.init) + common)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: ":")
    }
}

/// Drains Codex's output continuously without showing a Terminal window or retaining unbounded logs.
/// The output is currently diagnostic-only; keeping a small tail makes future error reporting possible
/// without allowing a noisy CLI/plugin to grow QuotaBar's memory indefinitely.
private final class LoginOutputCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var tail = Data()
    private let limit = 16 * 1024

    func drain(_ handle: FileHandle) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            while true {
                let data = handle.readData(ofLength: 4096)
                guard !data.isEmpty else { break }
                self?.append(data)
            }
        }
    }

    private func append(_ data: Data) {
        lock.lock()
        tail.append(data)
        if tail.count > limit {
            tail.removeFirst(tail.count - limit)
        }
        lock.unlock()
    }
}
