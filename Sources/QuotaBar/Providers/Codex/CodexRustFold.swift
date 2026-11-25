import Foundation

/// Rust-backed Codex rollout fold (`codex.fold`).
///
/// One call per changed session file, matching the scanner's per-inode aggregate: `visit` buffers
/// the events of the current file, and `fileCompleted` folds that buffer. The Swift
/// `CodexLogUsageScanner.aggregate` remains the parity oracle and the fallback on an internal
/// backend failure.
///
/// Pricing arrives as one snapshot handle per `ModelPricing` plus the alias-resolved canonical name
/// for every distinct `pricingModel` (and the rate model a `-fast` alias derives). Rust owns the
/// catalogue lookup, the Codex multipliers, and the long-context lanes. The inline mode still sends
/// fully resolved rates, for the fallback path and the measured comparison.
enum CodexRustFold {
    static let eventStride = 64

    /// Per-scan state that survives across files: the pricing table is cached by `pricingModel`,
    /// because the same handful of models repeats in every rollout file.
    struct FoldContext {
        var since: Date
        var pricing: ModelPricing
        var boundaries: RustFoldSupport.DayBoundaries
        /// Non-nil when this fold can let Rust resolve `pricingModel` names.
        var handle: UInt64?

        init(
            since: Date,
            pricing: ModelPricing,
            now: Date,
            mode: RustFoldPricingMode = .backend
        ) {
            self.since = since
            self.pricing = pricing
            self.boundaries = RustFoldSupport.DayBoundaries.build(since: since, now: now)
            self.handle = mode == .backend ? pricing.backendPricingHandle() : nil
        }

        /// `{canonical, rateModel, baseRates, resolvedRates}` for one emitted pricing slug.
        mutating func pricingEntry(for pricingModel: String) -> [String: Any] {
            let canonical = pricing.canonicalName(for: pricingModel) ?? pricingModel
            let isFastAlias = canonical.hasSuffix("-fast")
            let rateModel = isFastAlias
                ? String(canonical.dropLast("-fast".count))
                : canonical
            let baseRates = pricing.resolve(model: rateModel)
            let resolvedRates = baseRates ?? pricing.resolve(model: pricingModel)

            func encode(_ rates: ModelRates?) -> Any {
                guard let rates else { return NSNull() }
                return RustFoldSupport.encodeRates(rates) ?? NSNull()
            }

            return [
                "canonical": canonical,
                "rateModel": rateModel,
                "baseRates": encode(baseRates),
                "resolvedRates": encode(resolvedRates),
            ]
        }

        /// The alias-rule results Rust needs to mirror `resolve` for each name it will look up:
        /// every distinct pricing slug, plus the base slug a `-fast` canonical derives.
        func canonicalNames(for pricingModels: [String]) -> [String: String] {
            var names: [String: String] = [:]
            for pricingModel in pricingModels {
                let canonical = pricing.canonicalName(for: pricingModel) ?? pricingModel
                if canonical != pricingModel, names[pricingModel] == nil {
                    names[pricingModel] = canonical
                }
                let rateModel = canonical.hasSuffix("-fast")
                    ? String(canonical.dropLast("-fast".count))
                    : canonical
                if rateModel != pricingModel, names[rateModel] == nil,
                   let resolved = pricing.canonicalName(for: rateModel) {
                    names[rateModel] = resolved
                }
            }
            return names
        }
    }

    /// Fold one file's events. Nil means the backend declined; the caller folds with Swift.
    static func fold(
        events: [CodexLogUsageScanner.Event],
        context: inout FoldContext
    ) -> LogUsageScan? {
        guard !events.isEmpty else { return nil }

        var modelIndices: [String: Int] = [:]
        var models: [String] = []
        var serviceTierIndices: [String: Int] = [:]
        var serviceTiers: [String] = []
        var pricingJSON: [String: Any] = [:]
        var pricingModels: [String] = []
        var pricingModelSeen: Set<String> = []

        for event in events {
            if modelIndices[event.model] == nil {
                modelIndices[event.model] = models.count
                models.append(event.model)
            }
            if let pricingModel = event.pricingModel, modelIndices[pricingModel] == nil {
                modelIndices[pricingModel] = models.count
                models.append(pricingModel)
            }
            if let serviceTier = event.serviceTier, serviceTierIndices[serviceTier] == nil {
                serviceTierIndices[serviceTier] = serviceTiers.count
                serviceTiers.append(serviceTier)
            }
            let resolvedPricingModel = event.pricingModel
                ?? trimmedModel(event.model)
            if pricingModelSeen.insert(resolvedPricingModel).inserted {
                pricingModels.append(resolvedPricingModel)
            }
            if context.handle == nil, pricingJSON[resolvedPricingModel] == nil {
                pricingJSON[resolvedPricingModel] = context.pricingEntry(for: resolvedPricingModel)
            }
        }

        var payload = Data(count: events.count * eventStride)
        payload.withUnsafeMutableBytes { buffer in
            for (index, event) in events.enumerated() {
                let base = index * eventStride
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

                store64(event.timestamp.timeIntervalSince1970.bitPattern, at: 0)
                store64(UInt64(max(0, event.input)), at: 8)
                store64(UInt64(max(0, event.cached)), at: 16)
                store64(UInt64(max(0, event.output)), at: 24)
                store64(UInt64(max(0, event.reasoning)), at: 32)
                store64(UInt64(max(0, event.total)), at: 40)
                store32(Int32(modelIndices[event.model] ?? 0), at: 48)
                store32(event.pricingModel.flatMap { modelIndices[$0] }.map(Int32.init) ?? -1, at: 52)
                store32(event.serviceTier.flatMap { serviceTierIndices[$0] }.map(Int32.init) ?? -1, at: 56)
                var flags: UInt8 = 0
                if event.hasCompleteCostBreakdown { flags |= 0b1 }
                if event.isFast { flags |= 0b10 }
                buffer.storeBytes(of: flags, toByteOffset: base + 60, as: UInt8.self)
            }
        }

        var params: [String: Any] = [
            "since": context.since.timeIntervalSince1970,
            "dayBoundaries": context.boundaries.jsonObject,
            "models": models,
            "serviceTiers": serviceTiers,
        ]
        if let handle = context.handle {
            params["pricingHandle"] = handle
            params["canonicalNames"] = context.canonicalNames(for: pricingModels)
        } else {
            params["pricing"] = pricingJSON
        }
        guard JSONSerialization.isValidJSONObject(params) else { return nil }

        do {
            let result = try RustBackend.call(op: "codex.fold", params: params, payload: payload)
            let envelope = try JSONDecoder().decode(RustFoldSupport.FoldEnvelope.self, from: result)
            context.pricing.reportBackendRecheckModels(envelope.recheckModels)
            #if DEBUG
            RustFoldSupport.noteCompletedFold()
            if context.handle != nil { RustFoldSupport.noteBackendPricedFold() }
            #endif
            return RustFoldSupport.normalize(envelope.scan)
        } catch {
            AppLog.warn(LogTag.plugin("codex"), "rust fold failed (\(error)); using Swift reference fold")
            return nil
        }
    }

    private static func trimmedModel(_ model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? ModelUsageEntry.unattributedModelName : trimmed
    }
}
