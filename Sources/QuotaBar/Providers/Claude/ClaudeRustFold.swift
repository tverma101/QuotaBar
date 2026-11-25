import Foundation

/// Rust-backed Claude accounting fold (`claude.fold`).
///
/// Moves the two passes that touch every retained log entry — global replay dedupe and the priced
/// per-day roll-up — behind the backend. The Swift implementation
/// (`ClaudeLogUsageScanner.dedup` + `aggregate`) stays in place as the parity oracle and as the
/// fallback when the backend reports an internal failure, so a bad backend can never publish a
/// different answer.
///
/// Entries travel as fixed-stride records, not JSON: the scanner already holds decoded `Entry`
/// values, and re-encoding the whole history as JSON would cost more than the fold saves. Pricing
/// arrives as one snapshot handle per `ModelPricing` plus the alias-resolved canonical name for each
/// distinct slug; Rust owns catalogue lookup and rate assembly. The inline mode still sends the
/// fully resolved rate table, for the fallback path and the measured comparison.
enum ClaudeRustFold {
    static let entryStride = 72

    /// Fold `entries` through Rust. Nil means the backend declined this fold; callers must use the
    /// Swift oracle for the same entries.
    static func fold(
        entries: [ClaudeLogUsageScanner.Entry],
        since: Date,
        pricing: ModelPricing,
        now: Date = Date(),
        dayBoundaries: RustFoldSupport.DayBoundaries? = nil,
        mode: RustFoldPricingMode = .backend
    ) -> LogUsageScan? {
        guard !entries.isEmpty else { return nil }
        let backendHandle = mode == .backend ? pricing.backendPricingHandle() : nil

        // Distinct strings become one pool each; entries carry indices so the payload stays fixed
        // stride and the JSON envelope stays small.
        var modelIndices: [String: Int] = [:]
        var models: [String] = []
        var messageIndices: [String: Int] = [:]
        var messageIDs: [String] = []
        var requestIndices: [String: Int] = [:]
        var requestIDs: [String] = []
        var pricingJSON: [String: Any] = [:]

        for entry in entries {
            if let model = entry.model, modelIndices[model] == nil {
                modelIndices[model] = models.count
                models.append(model)
            }
            if let messageID = entry.messageID, messageIndices[messageID] == nil {
                messageIndices[messageID] = messageIDs.count
                messageIDs.append(messageID)
            }
            if let requestID = entry.requestID, requestIndices[requestID] == nil {
                requestIndices[requestID] = requestIDs.count
                requestIDs.append(requestID)
            }
            // The inline path prices the trimmed slug. Resolving each distinct model once also
            // preserves the discovery hook: `resolve` is memoized, so the Swift oracle reports the
            // same set. The backend path sends canonical names instead and reports what Rust saw.
            guard backendHandle == nil else { continue }
            if let trimmed = entry.model?.trimmingCharacters(in: .whitespacesAndNewlines),
               !trimmed.isEmpty,
               pricingJSON[trimmed] == nil {
                if let rates = pricing.resolve(model: trimmed),
                   let encoded = RustFoldSupport.encodeRates(rates) {
                    pricingJSON[trimmed] = encoded
                } else {
                    pricingJSON[trimmed] = NSNull()
                }
            }
        }

        var canonicalNames: [String: String] = [:]
        if backendHandle != nil {
            for model in models {
                let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, canonicalNames[trimmed] == nil,
                      let canonical = pricing.canonicalName(for: trimmed)
                else { continue }
                canonicalNames[trimmed] = canonical
            }
        }

        var payload = Data(count: entries.count * entryStride)
        payload.withUnsafeMutableBytes { buffer in
            for (index, entry) in entries.enumerated() {
                let base = index * entryStride
                func store64(_ bits: UInt64, at offset: Int) {
                    buffer.storeBytes(of: bits.littleEndian, toByteOffset: base + offset, as: UInt64.self)
                }
                func store32(_ value: Int32, at offset: Int) {
                    buffer.storeBytes(
                        of: UInt32(bitPattern: value).littleEndian,
                        toByteOffset: base + offset,
                        as: UInt32.self
                    )
                }

                store64(entry.timestamp.timeIntervalSince1970.bitPattern, at: 0)
                store64(UInt64(max(0, entry.tokens.input)), at: 8)
                store64(UInt64(max(0, entry.tokens.cacheWrite5m)), at: 16)
                store64(UInt64(max(0, entry.tokens.cacheWrite1h)), at: 24)
                store64(UInt64(max(0, entry.tokens.cacheRead)), at: 32)
                store64(UInt64(max(0, entry.tokens.output)), at: 40)
                store64(entry.costUSD?.bitPattern ?? Double.nan.bitPattern, at: 48)
                store32(entry.messageID.flatMap { messageIndices[$0] }.map(Int32.init) ?? -1, at: 56)
                store32(entry.requestID.flatMap { requestIndices[$0] }.map(Int32.init) ?? -1, at: 60)
                store32(entry.model.flatMap { modelIndices[$0] }.map(Int32.init) ?? -1, at: 64)
                var flags: UInt8 = 0
                if entry.isSidechain { flags |= 0b1 }
                if entry.hasSpeed { flags |= 0b10 }
                if entry.tokens.isFast { flags |= 0b100 }
                buffer.storeBytes(of: flags, toByteOffset: base + 68, as: UInt8.self)
            }
        }

        let boundaries = dayBoundaries ?? RustFoldSupport.DayBoundaries.build(since: since, now: now)
        var params: [String: Any] = [
            "since": since.timeIntervalSince1970,
            "dayBoundaries": boundaries.jsonObject,
            "models": models,
            "messageIds": messageIDs,
            "requestIds": requestIDs,
        ]
        if let backendHandle {
            params["pricingHandle"] = backendHandle
            params["canonicalNames"] = canonicalNames
        } else {
            params["pricing"] = pricingJSON
        }
        guard JSONSerialization.isValidJSONObject(params) else { return nil }

        do {
            let result = try RustBackend.call(op: "claude.fold", params: params, payload: payload)
            let envelope = try JSONDecoder().decode(RustFoldSupport.FoldEnvelope.self, from: result)
            pricing.reportBackendRecheckModels(envelope.recheckModels)
            #if DEBUG
            RustFoldSupport.noteCompletedFold()
            if backendHandle != nil { RustFoldSupport.noteBackendPricedFold() }
            #endif
            return RustFoldSupport.normalize(envelope.scan)
        } catch {
            AppLog.warn(LogTag.plugin("claude"), "rust fold failed (\(error)); using Swift reference fold")
            return nil
        }
    }
}
