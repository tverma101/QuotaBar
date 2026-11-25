import Foundation
import CQuotabarCore

/// Bridge to the quotabar-core provider backend (`Rust/quotabar-core/src/backend/`).
///
/// One C entry point carries a UTF-8 JSON request and returns a UTF-8 JSON envelope:
/// `{"ok":true,"result":...}` or `{"ok":false,"error":{"kind":...,"message":...}}`. The envelope is
/// deliberately generic so provider data-plane work can move behind it provider by provider without
/// changing the UI or the `ProviderRuntime` contract.
enum RustBackend {
    /// A typed failure reported by the backend. `kind` is stable machine vocabulary.
    struct BackendError: Error, Equatable {
        let kind: String
        let message: String
    }

    enum BridgeError: Error, LocalizedError, Equatable {
        /// The library returned no response at all (null handle). Callers may fall back to Swift.
        case unavailable
        case invalidRequest(String)
        case malformedResponse(String)

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "The Rust backend returned no response."
            case .invalidRequest(let detail):
                return "The Rust backend request could not be encoded: \(detail)"
            case .malformedResponse(let detail):
                return "The Rust backend response was not valid JSON: \(detail)"
            }
        }
    }

    static let abiVersion: UInt32 = qb_backend_abi_version()

    /// Run one backend operation and return its `result` as JSON data for typed decoding.
    static func call(op: String, params: [String: Any]) throws -> Data {
        try callRaw(try encodeRequest(op: op, params: params))
    }

    /// Run one backend operation and return its `result` object unre-encoded. A payload that is
    /// already a large JSON string (a database read) would otherwise be escaped, parsed, and
    /// re-escaped again on the way to the caller; reading the field directly skips two full passes
    /// over the payload.
    static func callResultObject(op: String, params: [String: Any]) throws -> [String: Any] {
        try decodeResultObject(try callRawEnvelope(try encodeRequest(op: op, params: params)))
    }

    /// Run one backend operation with a fixed-stride binary payload (fold entry records).
    static func call(op: String, params: [String: Any], payload: Data) throws -> Data {
        try callRaw(try encodeRequest(op: op, params: params), payload: payload)
    }

    private static func encodeRequest(op: String, params: [String: Any]) throws -> Data {
        let request: [String: Any] = ["op": op, "params": params]
        guard JSONSerialization.isValidJSONObject(request),
              let data = try? JSONSerialization.data(withJSONObject: request) else {
            throw BridgeError.invalidRequest(op)
        }
        return data
    }

    /// Run one backend operation with an already-encoded request.
    static func callRaw(_ request: Data) throws -> Data {
        try callRaw(request, payload: Data())
    }

    /// Run one backend operation with an already-encoded request and payload.
    static func callRaw(_ request: Data, payload: Data) throws -> Data {
        let result = try decodeEnvelope(try callRawEnvelope(request, payload: payload))
        return try JSONSerialization.data(withJSONObject: result)
    }

    /// Dispatch one request and return the envelope bytes the library wrote.
    private static func callRawEnvelope(_ request: Data, payload: Data = Data()) throws -> Data {
        let response: Data? = request.withUnsafeBytes { requestBuffer in
            payload.withUnsafeBytes { payloadBuffer in
                guard let raw = qb_backend_call_with_payload(
                    requestBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    requestBuffer.count,
                    payloadBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    payloadBuffer.count
                ) else {
                    return nil
                }
            defer { qb_backend_result_destroy(raw) }

            var length = 0
            guard let bytes = qb_backend_result_data(raw, &length) else { return nil }
            return Data(bytes: bytes, count: length)
            }
        }
        guard let response else { throw BridgeError.unavailable }
        return response
    }

    /// The envelope's `result` value, decoded once. Callers that read a single field out of a large
    /// payload use this directly instead of round-tripping it back through `JSONSerialization`.
    private static func decodeEnvelope(_ response: Data) throws -> Any {
        guard let envelope = (try? JSONSerialization.jsonObject(with: response)) as? [String: Any] else {
            throw BridgeError.malformedResponse(String(decoding: response, as: UTF8.self))
        }
        if envelope["ok"] as? Bool == true, let result = envelope["result"] {
            return result
        }
        let error = envelope["error"] as? [String: Any]
        throw BackendError(
            kind: error?["kind"] as? String ?? "unknown",
            message: error?["message"] as? String ?? "The backend reported an unspecified failure."
        )
    }

    private static func decodeResultObject(_ response: Data) throws -> [String: Any] {
        guard let result = try decodeEnvelope(response) as? [String: Any] else {
            throw BridgeError.malformedResponse("the backend result is not an object")
        }
        return result
    }
}
