import Foundation

enum UsageHistoryAggregator {
    /// Combines only providers explicitly declared machine-local. Account-wide histories such as
    /// Cursor are left out even if a malformed or future file contains them.
    static func merged(
        localSnapshots: [String: ProviderSnapshot],
        peerDocuments: [UsageHistoryDocument],
        descriptors: [String: UsageHistoryDescriptor],
        providerIdentityKeys: [String: String] = [:],
        now: Date = Date()
    ) -> [String: ProviderUsageHistory] {
        var inputs: [String: [ProviderUsageHistory]] = [:]
        let peerDocuments = UsageHistoryDocument.newestByDevice(peerDocuments)
        let localClaudeCards = Set(descriptors.keys.filter {
            ProviderAccountID.family(of: $0) == "claude"
        }).union(providerIdentityKeys.keys.filter {
            ProviderAccountID.family(of: $0) == "claude"
        })
        for (providerID, descriptor) in descriptors where descriptor.scope == .machineLocal {
            if let local = localSnapshots[providerID]?.usageHistory {
                inputs[providerID, default: []].append(local)
            }
            for document in peerDocuments {
                let peer: ProviderUsageHistory?
                if ProviderAccountID.family(of: providerID) == "claude" {
                    peer = claudeHistory(
                        in: document,
                        providerID: providerID,
                        identity: providerIdentityKeys[providerID],
                        allowsUnattributedHistory: localClaudeCards.count <= 1
                    )
                } else {
                    peer = document.providers[providerID]
                }
                if let peer {
                    inputs[providerID, default: []].append(peer)
                }
            }
        }
        let includedDays = UsageHistoryWindow.lifetimeDayKeys(through: now)
        let detailedDays = UsageHistoryWindow.dayKeys(through: now)
        var result: [String: ProviderUsageHistory] = [:]
        for (providerID, histories) in inputs {
            let normalizedHistories = histories.map {
                historyWithConservativeLegacyEstimateProvenance($0, providerID: providerID)
            }
            result[providerID] = merge(
                normalizedHistories,
                includedDays: includedDays,
                detailedDays: detailedDays
            )
        }
        return result
    }

    /// Older OpenCode snapshots and peer documents can contain locally priced gateway dollars
    /// without per-day estimate metadata. Mark every day with a recorded amount as estimated until
    /// the source publishes a fresh explicit set. This is conservative and intentionally treats
    /// provenance as unknown rather than claiming those legacy amounts were provider-reported.
    private static func historyWithConservativeLegacyEstimateProvenance(
        _ history: ProviderUsageHistory,
        providerID: String
    ) -> ProviderUsageHistory {
        guard providerID == "opencode", history.estimatedCostDays == nil else { return history }
        var migrated = history
        migrated.estimatedCostDays = Set(history.series.daily.compactMap { day in
            day.costUSD == nil ? nil : day.date
        })
        return migrated
    }

    private static func claudeHistory(
        in document: UsageHistoryDocument,
        providerID: String,
        identity: String?,
        allowsUnattributedHistory: Bool
    ) -> ProviderUsageHistory? {
        if let identities = document.identities,
           identities.keys.contains(where: { ProviderAccountID.family(of: $0) == "claude" })
        {
            guard let identity,
                  let matchingID = identities.first(where: {
                      ProviderAccountID.family(of: $0.key) == "claude"
                          && $0.value.caseInsensitiveCompare(identity) == .orderedSame
                  })?.key
            else { return nil }
            return document.providers[matchingID]
        }

        guard document.schema == UsageHistoryDocument.currentSchema,
              allowsUnattributedHistory
        else { return nil }
        return document.providers["claude"]
    }

    private static func merge(
        _ histories: [ProviderUsageHistory],
        includedDays: Set<String>,
        detailedDays: Set<String>
    ) -> ProviderUsageHistory {
        var days: [String: (
            tokens: Int,
            cost: Double?,
            sawCost: Bool,
            costOverflowed: Bool,
            costIsComplete: Bool,
            hasUnexplainedIncompleteCost: Bool?,
            hasKnownIncompleteCostCause: Bool,
            hasUnclassifiedIncompleteCost: Bool,
            tokenCountSaturated: Bool
        )] = [:]
        var apiEstimates: [String: Double] = [:]
        var apiEstimateOverflowedDays: Set<String> = []
        var apiEstimateIncompleteDays: Set<String> = []
        var estimatedCostDays: Set<String> = []
        var partialDays: Set<String> = []
        var models: [String: [String: ModelAccumulator]] = [:]
        var unknown: [String: Set<String>] = [:]

        for history in histories {
            for day in history.series.daily where includedDays.contains(day.date) {
                var value = days[day.date] ?? (0, nil, false, false, true, nil, false, false, false)
                if day.totalTokens > 0 && value.tokens > Int.max - day.totalTokens {
                    value.tokenCountSaturated = true
                }
                value.tokens = ProviderParse.addingSaturating(value.tokens, day.totalTokens)
                value.tokenCountSaturated = value.tokenCountSaturated || day.tokenCountSaturated
                if day.totalTokens > 0 && (!day.costIsComplete || day.costUSD == nil) {
                    value.costIsComplete = false
                    if day.hasUnexplainedIncompleteCost == nil {
                        let hasNamedUnknown = history.unknownModelsByDay[day.date]?.isEmpty == false
                        let isActiveSessionDay = history.partialDays?.contains(day.date) == true
                        if hasNamedUnknown || isActiveSessionDay {
                            value.hasKnownIncompleteCostCause = true
                        } else {
                            value.hasUnclassifiedIncompleteCost = true
                        }
                    }
                }
                if let hasUnexplained = day.hasUnexplainedIncompleteCost {
                    if hasUnexplained {
                        value.hasUnexplainedIncompleteCost = true
                    } else if value.hasUnexplainedIncompleteCost != true {
                        value.hasUnexplainedIncompleteCost = false
                        value.hasKnownIncompleteCostCause = true
                    }
                }
                if let cost = day.costUSD {
                    value.sawCost = true
                    if !value.costOverflowed {
                        if let total = Self.addingFiniteCost(value.cost, cost) {
                            value.cost = total
                        } else {
                            value.costOverflowed = true
                            value.costIsComplete = false
                            value.hasKnownIncompleteCostCause = true
                        }
                    }
                }
                days[day.date] = value
            }
            for (day, estimate) in history.apiEstimateByDay ?? [:] where includedDays.contains(day) {
                guard !apiEstimateOverflowedDays.contains(day) else {
                    apiEstimateIncompleteDays.insert(day)
                    continue
                }
                if let total = Self.addingFiniteCost(apiEstimates[day], estimate) {
                    apiEstimates[day] = total
                } else {
                    apiEstimates.removeValue(forKey: day)
                    apiEstimateOverflowedDays.insert(day)
                    apiEstimateIncompleteDays.insert(day)
                }
            }
            apiEstimateIncompleteDays.formUnion(
                (history.apiEstimateIncompleteDays ?? Set(history.unknownModelsByDay.keys))
                    .filter(includedDays.contains)
            )
            estimatedCostDays.formUnion((history.estimatedCostDays ?? []).filter(includedDays.contains))
            partialDays.formUnion((history.partialDays ?? []).filter(includedDays.contains))
            for day in history.modelUsage?.daily ?? [] where detailedDays.contains(day.date) {
                for model in day.models {
                    models[day.date, default: [:]][model.model.lowercased(), default: ModelAccumulator()]
                        .add(model)
                }
            }
            for (day, names) in history.unknownModelsByDay where detailedDays.contains(day) {
                unknown[day, default: []].formUnion(names)
            }
        }

        for (day, names) in unknown where !names.isEmpty {
            guard var value = days[day] else { continue }
            value.costIsComplete = false
            days[day] = value
        }

        let series = DailyUsageSeries(daily: days.map { date, value in
            DailyUsageEntry(
                date: date,
                totalTokens: value.tokens,
                // Keep known priced dollars even when another row on the same day is unpriced.
                // `costIsComplete` carries that distinction to the UI so the subtotal is labeled Partial.
                // An explicit false cause means a finite subtotal remains safe to show; an unknown
                // legacy cause still remains nil so the dashboard can conservatively hide it.
                costUSD: value.sawCost ? value.cost : nil,
                costIsComplete: value.costIsComplete,
                hasUnexplainedIncompleteCost: value.hasUnexplainedIncompleteCost == true
                    || value.hasUnclassifiedIncompleteCost
                    ? true
                    : (value.hasKnownIncompleteCostCause ? false : value.hasUnexplainedIncompleteCost),
                tokenCountSaturated: value.tokenCountSaturated
            )
        }.sorted { $0.date > $1.date })

        let modelDays = models.map { date, byName in
            DailyModelUsageEntry(
                date: date,
                models: byName.values.map(\.entry).sorted { $0.model.localizedStandardCompare($1.model) == .orderedAscending }
            )
        }.sorted { $0.date > $1.date }

        return ProviderUsageHistory(
            series: series,
            modelUsage: modelDays.isEmpty ? nil : ModelUsageSeries(daily: modelDays),
            unknownModelsByDay: unknown,
            apiEstimateByDay: apiEstimates.isEmpty ? nil : apiEstimates,
            apiEstimateIncompleteDays: apiEstimateIncompleteDays,
            partialDays: partialDays.isEmpty ? nil : partialDays,
            estimatedCostDays: histories.allSatisfy { $0.estimatedCostDays != nil }
                ? estimatedCostDays
                : (estimatedCostDays.isEmpty ? nil : estimatedCostDays)
        )
    }

    private static func addingFiniteCost(_ current: Double?, _ addition: Double) -> Double? {
        guard addition.isFinite, addition >= 0 else { return nil }
        let total = (current ?? 0) + addition
        return total.isFinite ? total : nil
    }

    private struct ModelAccumulator {
        var displayName = ""
        var tokens = 0
        var tokenCountSaturated = false
        var cost: Double?
        var sawCost = false
        var costOverflowed = false
        var costIsComplete = true
        var variants: [String: VariantAccumulator] = [:]

        mutating func add(_ model: ModelUsageEntry) {
            if displayName.isEmpty { displayName = model.model }
            if model.totalTokens > 0 && tokens > Int.max - model.totalTokens { tokenCountSaturated = true }
            tokens = ProviderParse.addingSaturating(tokens, model.totalTokens)
            tokenCountSaturated = tokenCountSaturated || model.tokenCountSaturated == true
            if let value = model.costUSD {
                sawCost = true
                if !costOverflowed {
                    if let total = UsageHistoryAggregator.addingFiniteCost(cost, value) {
                        cost = total
                    } else {
                        costOverflowed = true
                        costIsComplete = false
                    }
                }
            }
            if model.hasIncompleteCost {
                costIsComplete = false
            }
            for variant in model.variants ?? [] {
                variants[variant.model.lowercased(), default: VariantAccumulator(name: variant.model)]
                    .add(variant)
            }
        }

        var entry: ModelUsageEntry {
            let mergedVariants = variants.values.map(\.entry)
                .sorted { $0.model.localizedStandardCompare($1.model) == .orderedAscending }
            return ModelUsageEntry(
                model: displayName,
                totalTokens: tokens,
                costUSD: sawCost ? cost : nil,
                variants: mergedVariants.isEmpty ? nil : mergedVariants,
                costIsComplete: costIsComplete ? nil : false,
                tokenCountSaturated: tokenCountSaturated ? true : nil
            )
        }
    }

    private struct VariantAccumulator {
        var name: String
        var tokens = 0
        var tokenCountSaturated = false
        var cost: Double?
        var sawCost = false
        var costOverflowed = false
        var costIsComplete = true

        mutating func add(_ variant: ModelUsageVariant) {
            if variant.totalTokens > 0 && tokens > Int.max - variant.totalTokens { tokenCountSaturated = true }
            tokens = ProviderParse.addingSaturating(tokens, variant.totalTokens)
            tokenCountSaturated = tokenCountSaturated || variant.tokenCountSaturated == true
            if let value = variant.costUSD {
                sawCost = true
                if !costOverflowed {
                    if let total = UsageHistoryAggregator.addingFiniteCost(cost, value) {
                        cost = total
                    } else {
                        costOverflowed = true
                        costIsComplete = false
                    }
                }
            }
            if variant.hasIncompleteCost {
                costIsComplete = false
            }
        }

        var entry: ModelUsageVariant {
            ModelUsageVariant(model: name, totalTokens: tokens, costUSD: sawCost ? cost : nil,
                              costIsComplete: costIsComplete ? nil : false,
                              tokenCountSaturated: tokenCountSaturated ? true : nil)
        }
    }
}

enum UsageHistorySnapshotRenderer {
    private static let historyLabels: Set<String> = ["Today", "Yesterday", "Last 30 Days", "Usage Trend"]

    static func render(
        local snapshot: ProviderSnapshot,
        history: ProviderUsageHistory,
        descriptor: UsageHistoryDescriptor,
        now: Date = Date(),
        combined: Bool = true
    ) -> ProviderSnapshot {
        var result = snapshot
        result.usageHistory = history
        result.lines.removeAll { historyLabels.contains($0.label) }
        let sourceNote = combined ? "Across your Macs · \(descriptor.sourceNote)" : descriptor.sourceNote
        let legacyOpenCodeEstimate = result.providerID == "opencode" && history.estimatedCostDays == nil
        SpendTileMapper.appendTokenUsage(
            history.series,
            to: &result.lines,
            now: now,
            estimated: descriptor.estimatedCost || legacyOpenCodeEstimate,
            unknownModelsByDay: history.unknownModelsByDay,
            modelUsage: history.modelUsage,
            modelSourceNote: sourceNote,
            partialDays: history.partialDays ?? [],
            apiEstimateByDay: history.apiEstimateByDay,
            estimatedCostDays: history.estimatedCostDays
        )
        SpendTileMapper.appendUsageTrend(
            history.series,
            to: &result.lines,
            now: now,
            note: sourceNote,
            partialDays: history.partialDays ?? [],
            partialNote: result.providerID == "antigravity"
                ? "incomplete Antigravity history is shown as a lower bound" : nil
        )
        return result
    }
}
