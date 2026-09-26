import Foundation
import Observation

/// The local, machine-readable state returned by `kaggle-glm53-control status`.
/// This is deliberately separate from provider usage snapshots: Kaggle TPU time is an allocation,
/// while the token/cost fields are an API-equivalent comparison rather than a bill.
struct KaggleComputeSnapshot: Equatable, Sendable {
    enum State: String, Equatable, Sendable {
        case unconfigured
        case stopped
        case starting
        case running
        case stopping
        case error
    }

    var state: State = .unconfigured
    var model = "glm-5.3-flash"
    var kernelState = "UNKNOWN"
    var endpointReady = false
    var startedAt: Date?
    var elapsedSeconds = 0
    var allocationLimitSeconds = 0
    var remainingSeconds = 0
    var requests = 0
    var inputTokens = 0
    var outputTokens = 0
    var cachedInputTokens = 0
    var estimatedAPICostUSD = 0.0
    var errorMessage: String?

    init() {}

    init(jsonData: Data) {
        guard
            let object = try? JSONSerialization.jsonObject(with: jsonData),
            let dictionary = object as? [String: Any]
        else {
            self.init(json: [
                "ok": false,
                "error": "The Kaggle bridge returned invalid status data."
            ])
            return
        }
        self.init(json: dictionary)
    }

    init(json: [String: Any]) {
        model = json["model"] as? String ?? model
        kernelState = json["kernel_state"] as? String ?? kernelState
        endpointReady = json["endpoint_ready"] as? Bool ?? false
        startedAt = (json["started_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        elapsedSeconds = Self.int(json["elapsed_seconds"])
        allocationLimitSeconds = Self.int(json["allocation_limit_seconds"])
        remainingSeconds = Self.int(json["remaining_seconds"])
        requests = Self.int(json["requests"])
        inputTokens = Self.int(json["input_tokens"])
        outputTokens = Self.int(json["output_tokens"])
        cachedInputTokens = Self.int(json["cached_input_tokens"])
        estimatedAPICostUSD = (json["estimated_api_cost_usd"] as? NSNumber)?.doubleValue ?? 0
        errorMessage = json["error"] as? String

        if json["ok"] as? Bool == false {
            state = .error
            if errorMessage == nil { errorMessage = "The Kaggle bridge rejected the request." }
            return
        }
        switch json["state"] as? String {
        case "running": state = .running
        case "starting": state = .starting
        case "stopped": state = .stopped
        case "unconfigured": state = .unconfigured
        case "stopping": state = .stopping
        case "error": state = .error
        default: state = .error; errorMessage = errorMessage ?? "The Kaggle bridge returned an unknown state."
        }
    }

    private static func int(_ value: Any?) -> Int {
        max(0, (value as? NSNumber)?.intValue ?? 0)
    }
}

private struct KaggleCommandOutcome: Sendable {
    var result: ProcessResult?
    var errorMessage: String?
}

/// Main-actor façade for the separate GLM-5.3 TPU bridge. It never starts a notebook on its own:
/// only `turnOn()` invokes the bridge's `on` command. Status polling is read-only and is stopped when
/// the app tears down, so a menu-bar popover cannot leave an unbounded subprocess behind.
@MainActor
@Observable
final class KaggleComputeService {
    private(set) var snapshot = KaggleComputeSnapshot()
    /// True while any bridge command is in flight, including a read-only status refresh. This keeps
    /// Turn On/Turn Off from racing a status poll or issuing two Kaggle deletes.
    private(set) var isExecuting = false
    private(set) var isBusy = false

    private let runner: any ProcessRunning
    private let environment: [String: String]
    private var pollTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?

    init(
        runner: any ProcessRunning = SystemProcessRunner(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.runner = runner
        self.environment = environment
    }

    func startPolling() {
        guard pollTask == nil else { return }
        refresh()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                guard let self else { return }
                self.refresh()
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        operationTask?.cancel()
        operationTask = nil
        isExecuting = false
        isBusy = false
    }

    func refresh() {
        execute("status", busy: false)
    }

    func turnOn() {
        execute("on", busy: true)
    }

    func turnOff() {
        execute("off", busy: true)
    }

    private func execute(_ action: String, busy: Bool) {
        guard operationTask == nil else { return }
        guard let executable = Self.resolveExecutable(environment: environment) else {
            snapshot = KaggleComputeSnapshot(
                json: [
                    "ok": false,
                    "state": "error",
                    "error": "The Kaggle GLM bridge is not installed. Set KAGGLE_GLM53_CONTROL_BIN or reinstall OpenUsage."
                ]
            )
            return
        }

        isExecuting = true
        isBusy = busy
        let runner = self.runner
        let environment = commandEnvironment
        operationTask = Task { [weak self] in
            let outcome = await Task.detached(priority: .utility) {
                do {
                    return KaggleCommandOutcome(
                        result: try runner.run(
                            executable: executable,
                            arguments: [action],
                            environment: environment,
                            timeout: action == "status" ? 20 : 120
                        ),
                        errorMessage: nil
                    )
                } catch {
                    return KaggleCommandOutcome(result: nil, errorMessage: error.localizedDescription)
                }
            }.value
            guard let self, !Task.isCancelled else { return }
            self.apply(outcome, action: action)
            self.operationTask = nil
            self.isExecuting = false
            self.isBusy = false
        }
    }

    private func apply(_ outcome: KaggleCommandOutcome, action: String) {
        guard let result = outcome.result else {
            snapshot.state = .error
            snapshot.errorMessage = outcome.errorMessage ?? "The Kaggle bridge could not be started."
            return
        }
        guard result.succeeded else {
            snapshot.state = .error
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            snapshot.errorMessage = detail.isEmpty
                ? "Kaggle \(action) failed. Try again or inspect the bridge status."
                : "Kaggle \(action) failed: \(detail)"
            return
        }
        guard let data = result.stdout.data(using: .utf8) else {
            snapshot.state = .error
            snapshot.errorMessage = "The Kaggle bridge returned no status data."
            return
        }
        snapshot = KaggleComputeSnapshot(jsonData: data)
    }

    private var commandEnvironment: [String: String] {
        var values = environment
        let home = values["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        if values["KAGGLE_TPU_LAB_ROOT"]?.isEmpty != false {
            values["KAGGLE_TPU_LAB_ROOT"] = "\(home)/kaggle-tpu-lab"
        }
        if values["KAGGLE_GLM53_PYTHON"]?.isEmpty != false {
            let candidates = [
                "\(home)/Documents/Codex/2026-09-10/new-chat/work/kaggle-gpu-control/.venv/bin/python",
                "/Users/tejas/Documents/Codex/2026-09-10/new-chat/work/kaggle-gpu-control/.venv/bin/python",
                "/opt/homebrew/bin/python3",
                "/usr/local/bin/python3",
            ]
            if let python = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
                values["KAGGLE_GLM53_PYTHON"] = python
            }
        }
        let path = values["PATH"] ?? ""
        let prefix = "/opt/homebrew/bin:/usr/local/bin:\(home)/Documents/Codex/2026-09-10/new-chat/work/kaggle-gpu-control/.venv/bin"
        if path.isEmpty {
            values["PATH"] = prefix
        } else if !path.split(separator: ":").contains(where: { prefix.split(separator: ":").contains($0) }) {
            values["PATH"] = "\(prefix):\(path)"
        }
        return values
    }

    private static func resolveExecutable(environment: [String: String]) -> String? {
        let home = environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        let configured = environment["KAGGLE_GLM53_CONTROL_BIN"]
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("kaggle-glm53-control").path
        let candidates = [
            configured,
            bundled,
            "/usr/local/bin/kaggle-glm53-control",
            "/opt/homebrew/bin/kaggle-glm53-control",
            "/Users/tejas/Documents/Codex/2026-09-10/new-chat/work/kaggle-gpu-control/bin/kaggle-glm53-control",
            "\(home)/kaggle-gpu-control/bin/kaggle-glm53-control",
        ].compactMap { $0 }.map { NSString(string: $0).expandingTildeInPath }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
