import CQuotabarCore
import Foundation

/// The Rust backend (`Rust/quotabar-engine`), reached through the C ABI in `Rust/quotabar-core`.
///
/// Requests and replies are JSON (see `Rust/quotabar-engine/src/engine.rs`). Every call runs on an
/// engine-owned thread, so a slow network or disk read never blocks a Swift concurrency thread, and a
/// cancelled Swift task cancels its engine request.
enum RustEngine {
    enum EngineError: Error, LocalizedError {
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .failed(let message): return message
            }
        }
    }

    /// Install the host callbacks and hand the engine this process's home and data directories.
    /// Idempotent; every entry point calls it.
    static func prepare() {
        _ = installation
    }

    private static let installation: Void = {
        let callbacks = QbHostCallbacks(
            context: nil,
            log: { _, level, tag, tagLength, message, messageLength in
                guard let tag, let message else { return }
                AppLog.engine(
                    severity: Int(level),
                    tag: String(decoding: UnsafeBufferPointer(start: tag, count: tagLength), as: UTF8.self),
                    message: String(decoding: UnsafeBufferPointer(start: message, count: messageLength), as: UTF8.self)
                )
            },
            host_call: { _, request, length in
                guard let request else { return nil }
                let reply = RustEngineHost.handle(Data(UnsafeBufferPointer(start: request, count: length)))
                return reply.flatMap { strdup($0) }
            },
            log_level: UInt32(AppLog.currentSeverity)
        )
        qb_engine_install_host(callbacks)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let appData = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QuotaBar", isDirectory: true).path
        let reply = callSync(["method": "configure", "params": ["home": home, "appData": appData]])
        if case .failure(let error) = reply {
            AppLog.error(LogTag.refresh, "engine configure failed: \(error.localizedDescription)")
        }
    }()

    private static let requestCounter = RequestCounter()

    // MARK: - Calls

    /// Refresh one provider in the engine. Engine failures become a visible error snapshot and an
    /// error log line, never a silent empty card.
    static func refresh(provider: Provider) async -> ProviderSnapshot {
        prepare()
        let requestID = requestCounter.next()
        let params: [String: Any] = [
            "providerId": provider.id,
            "scope": ProviderRefreshContext.scope.engineName,
            "isManual": ProviderRefreshContext.isManual,
            "requestId": requestID
        ]
        let reply = await withTaskCancellationHandler {
            await call(["method": "refresh", "params": params])
        } onCancel: {
            _ = qb_engine_cancel(requestID)
        }
        if Task.isCancelled { return cancelledRefreshSnapshot(provider: provider) }
        switch reply {
        case .success(let data):
            do {
                return try decoder.decode(OkReply<ProviderSnapshot>.self, from: data).ok
            } catch {
                AppLog.error(LogTag.plugin(provider.id), "engine snapshot could not be decoded: \(error)")
                return ProviderSnapshot.error(
                    provider: provider,
                    message: "QuotaBar couldn't read \(provider.displayName)'s usage. Try again later.",
                    category: .decoding
                )
            }
        case .failure(let error):
            AppLog.error(LogTag.plugin(provider.id), "engine refresh failed: \(error.localizedDescription)")
            return ProviderSnapshot.error(
                provider: provider,
                message: "QuotaBar couldn't refresh \(provider.displayName). Try again later.",
                category: .other
            )
        }
    }

    /// The engine's silent local-only setup probe.
    static func hasLocalCredentials(providerID: String) async -> Bool {
        prepare()
        switch await call(["method": "hasLocalCredentials", "params": ["providerId": providerID]]) {
        case .success(let data):
            do {
                return try decoder.decode(OkReply<Bool>.self, from: data).ok
            } catch {
                AppLog.error(LogTag.plugin(providerID), "engine credential probe could not be decoded: \(error)")
                return false
            }
        case .failure(let error):
            AppLog.error(LogTag.plugin(providerID), "engine credential probe failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Transport

    private struct OkReply<Value: Decodable>: Decodable {
        let ok: Value
    }

    private struct ErrorReply: Decodable {
        let error: String
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()

    /// The raw `{"ok": ...}` reply, or the engine's `{"error": ...}` as a failure.
    static func call(_ request: [String: Any]) async -> Result<Data, EngineError> {
        guard let body = try? JSONSerialization.data(withJSONObject: request) else {
            return .failure(.failed("request could not be encoded"))
        }
        let text = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            let box = Unmanaged.passRetained(ReplyBox(continuation)).toOpaque()
            body.withUnsafeBytes { raw in
                qb_engine_call_async(raw.bindMemory(to: UInt8.self).baseAddress, raw.count, box) { context, reply in
                    guard let context else { return }
                    let box = Unmanaged<ReplyBox>.fromOpaque(context).takeRetainedValue()
                    let text = reply.map { String(cString: $0) } ?? #"{"error":"empty engine reply"}"#
                    qb_engine_string_free(reply)
                    box.continuation.resume(returning: text)
                }
            }
        }
        return interpret(Data(text.utf8))
    }

    private static func callSync(_ request: [String: Any]) -> Result<Data, EngineError> {
        guard let body = try? JSONSerialization.data(withJSONObject: request) else {
            return .failure(.failed("request could not be encoded"))
        }
        let text = body.withUnsafeBytes { raw -> String in
            let reply = qb_engine_call(raw.bindMemory(to: UInt8.self).baseAddress, raw.count)
            defer { qb_engine_string_free(reply) }
            return reply.map { String(cString: $0) } ?? #"{"error":"empty engine reply"}"#
        }
        return interpret(Data(text.utf8))
    }

    private static func interpret(_ data: Data) -> Result<Data, EngineError> {
        if let failure = try? decoder.decode(ErrorReply.self, from: data) {
            return .failure(.failed(failure.error))
        }
        return .success(data)
    }

    private final class ReplyBox: @unchecked Sendable {
        let continuation: CheckedContinuation<String, Never>
        init(_ continuation: CheckedContinuation<String, Never>) { self.continuation = continuation }
    }

    private final class RequestCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt64 = 0
        func next() -> UInt64 {
            lock.lock()
            defer { lock.unlock() }
            value &+= 1
            return value
        }
    }
}

extension ProviderRefreshContext.Scope {
    /// The engine's spelling of this scope (`Rust/quotabar-engine/src/context.rs`).
    var engineName: String {
        switch self {
        case .menuBar: "menuBar"
        case .panelMeters: "panelMeters"
        case .localAccounting: "localAccounting"
        case .panelAccounting: "panelAccounting"
        case .full: "full"
        }
    }
}

/// Answers the engine's host requests (`QbHostCallCallback`). Runs on engine threads.
enum RustEngineHost {
    private static let environment = ProcessEnvironmentReader()

    /// The JSON reply text, or `nil` for a request this host does not handle (the engine then
    /// treats the service as unavailable and logs it).
    static func handle(_ request: Data) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: request)) as? [String: Any],
              let method = object["method"] as? String
        else {
            AppLog.error(LogTag.refresh, "engine host request could not be decoded")
            return nil
        }
        let params = object["params"] as? [String: Any] ?? [:]
        switch method {
        case "env":
            guard let name = params["name"] as? String else { return "null" }
            return jsonText(environment.value(for: name))
        default:
            AppLog.error(LogTag.refresh, "engine asked for unsupported host service \(method)")
            return nil
        }
    }

    private static func jsonText(_ value: String?) -> String {
        guard let value,
              let data = try? JSONSerialization.data(withJSONObject: [value]),
              let text = String(data: data, encoding: .utf8)
        else { return "null" }
        // Strip the array brackets: JSONSerialization only encodes top-level collections.
        return String(text.dropFirst().dropLast())
    }
}
