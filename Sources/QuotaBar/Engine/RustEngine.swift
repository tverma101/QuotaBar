import CQuotabarCore
import Foundation

/// The Rust backend (`Rust/quotabar-engine`), reached through the C ABI in `Rust/quotabar-core`.
///
/// Requests and replies are JSON (see `Rust/quotabar-engine/src/engine/`). Asynchronous calls run on
/// an engine-owned thread, so a slow network or disk read never blocks a Swift concurrency thread,
/// and a cancelled Swift task cancels its engine request.

/// The JSON object handed to the engine for one provider call. `JSONSerialization` is the only
/// consumer, so the unchecked `Sendable` conformance is limited to immutable configuration built on
/// the main actor before the engine call.
struct EngineProviderConfig: @unchecked Sendable {
    let values: [String: Any]

    init(_ values: [String: Any]) {
        self.values = values
    }
}

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
    static func refresh(provider: Provider, config: EngineProviderConfig? = nil) async -> ProviderSnapshot {
        prepare()
        let requestID = requestCounter.next()
        let keychain = RustEngineHost.Refresh()
        RustEngineHost.register(keychain, for: requestID)
        defer { RustEngineHost.unregister(requestID) }
        var params: [String: Any] = [
            "providerId": provider.id,
            "scope": ProviderRefreshContext.scope.engineName,
            "isManual": ProviderRefreshContext.isManual,
            "skipModelCatalogRefresh": ProviderRefreshContext.skipModelCatalogRefresh,
            "paced": ProviderRefreshContext.accountingCPUThrottleEnabled,
            "includeIdentity": true,
            "requestId": requestID
        ]
        if let config {
            params["config"] = config.values
        }
        let reply = await withTaskCancellationHandler {
            await call(["method": "refresh", "params": params])
        } onCancel: {
            keychain.cancel()
            _ = qb_engine_cancel(requestID)
        }
        if Task.isCancelled { return cancelledRefreshSnapshot(provider: provider) }
        switch reply {
        case .success(let data):
            do {
                let decoded = try decoder.decode(OkReply<RefreshOutcome>.self, from: data).ok
                if let identityKey = decoded.identityKey {
                    ProviderRefreshContext.cacheIdentityResult?.set(identityKey)
                }
                return decoded.snapshot
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
    static func hasLocalCredentials(providerID: String, config: EngineProviderConfig? = nil) async -> Bool {
        prepare()
        var params: [String: Any] = ["providerId": providerID]
        if let config { params["config"] = config.values }
        switch await call(["method": "hasLocalCredentials", "params": params]) {
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

    struct BatchItem: @unchecked Sendable {
        let providerID: String
        var config: [String: Any]? = nil
        var defaultIdentityKey: String? = nil

        func encoded() -> [String: Any] {
            var dict: [String: Any] = ["providerId": providerID]
            if let config { dict["config"] = config }
            if let defaultIdentityKey { dict["defaultIdentityKey"] = defaultIdentityKey }
            return dict
        }
    }

    struct BatchResponse: Decodable {
        let snapshots: [String: ProviderSnapshot]
        let errors: [String: String]
        let identityKeys: [String: String]
    }

    /// Run a batched local/panel refresh inside the Rust engine (replaces the out-of-process scan worker).
    static func refreshBatch(
        items: [BatchItem],
        scope: ProviderRefreshContext.Scope = .panelAccounting,
        isManual: Bool = false,
        skipModelCatalogRefresh: Bool = true,
        perProviderTimeoutSeconds: TimeInterval? = nil,
        batchBudgetSeconds: TimeInterval? = nil,
        paced: Bool = false
    ) async throws -> BatchResponse {
        prepare()
        let requestID = requestCounter.next()
        let keychain = RustEngineHost.Refresh()
        RustEngineHost.register(keychain, for: requestID)
        defer { RustEngineHost.unregister(requestID) }
        var params: [String: Any] = [
            "items": items.map { $0.encoded() },
            "scope": scope.engineName,
            "isManual": isManual,
            "skipModelCatalogRefresh": skipModelCatalogRefresh,
            "paced": paced,
            "requestId": requestID,
        ]
        if let perProviderTimeoutSeconds {
            params["perProviderTimeoutSeconds"] = perProviderTimeoutSeconds
        }
        if let batchBudgetSeconds {
            params["batchBudgetSeconds"] = batchBudgetSeconds
        }
        let reply = await withTaskCancellationHandler {
            await call(["method": "refreshBatch", "params": params])
        } onCancel: {
            keychain.cancel()
            _ = qb_engine_cancel(requestID)
        }
        let data = try reply.get()
        return try decoder.decode(OkReply<BatchResponse>.self, from: data).ok
    }

    struct CodexResetCreditReply: Decodable {
        let id: String
        let expiresAt: Date
    }

    struct CodexResetCreditsReply: Decodable {
        let credits: [CodexResetCreditReply]
        let authRejected: Bool
        let credentialAccessFailed: Bool
    }

    struct CodexResetClaimReply: Decodable {
        let outcome: String
        let creditID: String?
        let ownerIdentity: String?

        enum CodingKeys: String, CodingKey {
            case outcome
            case creditID = "creditId"
            case ownerIdentity
        }
    }

    /// The cancellable engine entry point for the reset-credit list. The engine owns credential
    /// selection, keychain fallback, HTTP, and response parsing.
    static func codexResetCredits(
        providerID: String,
        config: EngineProviderConfig?,
        isManual: Bool = false
    ) async -> CodexResetCreditsReply? {
        prepare()
        let requestID = requestCounter.next()
        let keychain = RustEngineHost.Refresh()
        RustEngineHost.register(keychain, for: requestID)
        defer { RustEngineHost.unregister(requestID) }
        var params: [String: Any] = [
            "providerId": providerID,
            "isManual": isManual,
            "requestId": requestID,
        ]
        if let config { params["config"] = config.values }
        let reply = await withTaskCancellationHandler {
            await call(["method": "codexResetCredits", "params": params])
        } onCancel: {
            keychain.cancel()
            _ = qb_engine_cancel(requestID)
        }
        guard !Task.isCancelled else { return nil }
        switch reply {
        case .success(let data):
            do {
                return try decoder.decode(OkReply<CodexResetCreditsReply?>.self, from: data).ok
            } catch {
                AppLog.error(LogTag.plugin(providerID), "reset-credit list could not be decoded: \(error)")
                return nil
            }
        case .failure(let error):
            AppLog.error(LogTag.plugin(providerID), "reset-credit list failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// The cancellable engine entry point for a reset-credit claim. Matching, credential fallback,
    /// the consume POST, idempotent replay, and outcome parsing all happen in Rust.
    static func codexResetClaim(
        providerID: String,
        config: EngineProviderConfig?,
        expiry: Date,
        redeemRequestID: String,
        creditID: String? = nil,
        ownerIdentity: String? = nil,
        isRetry: Bool = false,
        automatic: Bool = false,
        isManual: Bool
    ) async -> CodexResetClaimReply? {
        prepare()
        let requestID = requestCounter.next()
        let keychain = RustEngineHost.Refresh()
        RustEngineHost.register(keychain, for: requestID)
        defer { RustEngineHost.unregister(requestID) }
        var params: [String: Any] = [
            "providerId": providerID,
            "expiry": expiry.timeIntervalSince1970,
            "redeemRequestId": redeemRequestID,
            "isRetry": isRetry,
            "automatic": automatic,
            "isManual": isManual,
            "requestId": requestID,
        ]
        if let config { params["config"] = config.values }
        if let creditID { params["creditId"] = creditID }
        if let ownerIdentity { params["ownerIdentity"] = ownerIdentity }
        let reply = await withTaskCancellationHandler {
            await call(["method": "codexResetClaim", "params": params])
        } onCancel: {
            keychain.cancel()
            _ = qb_engine_cancel(requestID)
        }
        guard !Task.isCancelled else { return nil }
        switch reply {
        case .success(let data):
            do {
                return try decoder.decode(OkReply<CodexResetClaimReply>.self, from: data).ok
            } catch {
                AppLog.error(LogTag.plugin(providerID), "reset-claim reply could not be decoded: \(error)")
                return nil
            }
        case .failure(let error):
            AppLog.error(LogTag.plugin(providerID), "reset-claim failed: \(error.localizedDescription)")
            return nil
        }
    }

    static func unloadCaches() async {
        prepare()
        if case .failure(let error) = await call(["method": "unloadCaches", "params": [:]]) {
            AppLog.warn(LogTag.refresh, "engine unloadCaches failed: \(error.localizedDescription)")
        }
    }

    /// Release one provider's recomputable engine caches (memory-pressure path).
    static func unloadCaches(providerID: String) async {
        prepare()
        if case .failure(let error) = await call([
            "method": "unloadProviderCaches", "params": ["providerId": providerID]
        ]) {
            AppLog.warn(LogTag.refresh, "engine unloadCaches for \(providerID) failed: \(error.localizedDescription)")
        }
    }

    static func pricingStatus() async throws -> [String: Any] {
        prepare()
        let data = try await call(["method": "pricingStatus", "params": [:]]).get()
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ok = root["ok"] as? [String: Any] else {
            throw EngineError.failed("pricingStatus reply could not be decoded")
        }
        return ok
    }

    static func pricingRefresh(background: Bool = false) async throws -> [String: Any] {
        prepare()
        let data = try await call(["method": "pricingRefresh", "params": ["background": background]]).get()
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ok = root["ok"] as? [String: Any] else {
            throw EngineError.failed("pricingRefresh reply could not be decoded")
        }
        return ok
    }

    static func pricingClearCaches() async {
        prepare()
        _ = await call(["method": "pricingClearCaches", "params": [:]])
    }

    static func pricingResolve(
        model: String,
        isCursor: Bool = false,
        tokens: TokenBreakdown? = nil,
        timestamp: Date? = nil,
        applyLongContextRates: Bool = true
    ) async throws -> PricingResolveReply {
        prepare()
        var params: [String: Any] = [
            "model": model,
            "isCursor": isCursor,
            "applyLongContextRates": applyLongContextRates,
        ]
        if let tokens {
            params["tokens"] = [
                "input": tokens.input,
                "cacheWrite5m": tokens.cacheWrite5m,
                "cacheWrite1h": tokens.cacheWrite1h,
                "cacheRead": tokens.cacheRead,
                "output": tokens.output,
                "isFast": tokens.isFast,
            ]
        }
        if let timestamp {
            params["timestamp"] = timestamp.timeIntervalSince1970
        }
        let data = try await call(["method": "pricingResolve", "params": params]).get()
        return try decoder.decode(OkReply<PricingResolveReply>.self, from: data).ok
    }

    struct PricingResolveReply: Decodable {
        let canonicalName: String?
        let cursorCanonicalName: String?
        let hasExactOpenRouterRate: Bool
        let cacheToken: String
        let costUsd: Double?
    }

    private struct RefreshOutcome: Decodable {
        let snapshot: ProviderSnapshot
        let identityKey: String?
    }

    static func apiKeyStatus(providerID: String) -> APIKeyStatus {
        prepare()
        struct Reply: Decodable { let status: APIKeyStatus }
        do {
            return try callSync(
                ["method": "credentialAction", "params": ["providerId": providerID, "action": "status"]],
                as: Reply.self
            ).status
        } catch {
            AppLog.error(LogTag.auth(providerID), "credentialAction status failed: \(error.localizedDescription)")
            return .notSet
        }
    }

    static func currentAPIKey(providerID: String) -> String? {
        prepare()
        struct Reply: Decodable { let key: String? }
        do {
            return try callSync(
                ["method": "credentialAction", "params": ["providerId": providerID, "action": "current"]],
                as: Reply.self
            ).key
        } catch {
            AppLog.error(LogTag.auth(providerID), "credentialAction current failed: \(error.localizedDescription)")
            return nil
        }
    }

    static func saveAPIKey(_ key: String, providerID: String) throws {
        prepare()
        struct Reply: Decodable { let status: APIKeyStatus }
        _ = try callSync(
            ["method": "credentialAction", "params": ["providerId": providerID, "action": "save", "key": key]],
            as: Reply.self
        )
    }

    static func deleteAPIKey(providerID: String) throws {
        prepare()
        struct Reply: Decodable { let status: APIKeyStatus }
        _ = try callSync(
            ["method": "credentialAction", "params": ["providerId": providerID, "action": "delete"]],
            as: Reply.self
        )
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

    static func callSync<Value: Decodable>(_ request: [String: Any], as _: Value.Type) throws -> Value {
        try decoder.decode(OkReply<Value>.self, from: callSync(request).get()).ok
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

