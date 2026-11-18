import Foundation

/// One corpus's measured token-generation rate, folded from consecutive usage reports in the
/// local session logs. `outputTokens / seconds` over the qualifying intervals is a token-weighted
/// mean: heavy generations dominate the estimate, idle gaps and tool-call waits are excluded.
struct TokensPerSecondCorpus: Equatable, Sendable {
    var outputTokens: Double = 0
    var seconds: Double = 0
    var intervals: Int = 0

    /// Estimated tokens per second. `nil` when this pass has no qualifying paired reports;
    /// panel consumers read `tokensPerSecond == nil` as “no data yet”.
    var tokensPerSecond: Double? {
        guard intervals >= TokensPerSecond.minimumIntervals, seconds > 0 else { return nil }
        let rate = outputTokens / seconds
        return rate.isFinite && rate > 0 ? rate : nil
    }

    mutating func add(outputTokens: Int, seconds: Double) {
        self.outputTokens += Double(outputTokens)
        self.seconds += seconds
        self.intervals += 1
    }
}

/// Per-model view of the same qualifying intervals — the panel's model TPS list. `rate` is `nil`
/// with fewer than `TokensPerSecond.minimumModelIntervals` paired reports in the window, so a barely
/// seen model never dresses up one or two data points as a rate.
struct TokensPerSecondModelShare: Equatable, Sendable {
    var model: String
    var outputTokens: Double
    var seconds: Double
    var intervals: Int

    var rate: Double? {
        guard intervals >= TokensPerSecond.minimumModelIntervals, seconds > 0 else { return nil }
        let value = outputTokens / seconds
        return value.isFinite && value > 0 ? value : nil
    }
}

/// The cross-corpus estimate the TPS panel renders: one entry per participating provider (Claude,
/// Codex, Grok, Muse, Pi today), each with a per-model breakdown over the same qualifying intervals.
/// The `combined` figure is the token-weighted sum across every corpus.
struct TokensPerSecondEstimate: Equatable, Sendable {
    /// Every provider's corpus, keyed by provider id. Only providers with any qualifying interval in
    /// the window carry one — an absent key means "no data", not zero.
    var corpora: [String: TokensPerSecondCorpus]
    /// Each provider's per-model buckets, keyed by provider id.
    var models: [String: [TokensPerSecondModelShare]]
    /// The same fold bucketed by calendar day, so the lens can switch between Today, 7 Days and the
    /// full 14-day window without re-reading a single log file.
    var windows: [TokensPerSecondWindow: TokensPerSecondWindowView] = [:]

    /// One window's view of the fold — identical shape to the headline estimate.
    struct TokensPerSecondWindowView: Equatable, Sendable {
        var corpora: [String: TokensPerSecondCorpus]
        var models: [String: [TokensPerSecondModelShare]]

        var combined: TokensPerSecondCorpus {
            var total = TokensPerSecondCorpus()
            for corpus in corpora.values {
                total.outputTokens += corpus.outputTokens
                total.seconds += corpus.seconds
                total.intervals += corpus.intervals
            }
            return total
        }

        var combinedModels: [TokensPerSecondModelShare] {
            TokensPerSecondEstimate.merge(models.values.flatMap { $0 })
        }
    }

    /// Combined per-model view across every corpus, ranked by tokens (descending).
    var combinedModels: [TokensPerSecondModelShare] {
        TokensPerSecondEstimate.merge(models.values.flatMap { $0 })
    }

    /// Canonical corpus order the lens renders (also the values-line emission order).
    static let providerOrder: [String] = ["claude", "codex", "grok", "muse", "pi", "zai", "antigravity"]

    var combined: TokensPerSecondCorpus {
        var total = TokensPerSecondCorpus()
        for corpus in corpora.values {
            total.outputTokens += corpus.outputTokens
            total.seconds += corpus.seconds
            total.intervals += corpus.intervals
        }
        return total
    }

    /// Sum per model across corpora, keeping the dominant spelling and re-ranking by tokens.
    static func merge(_ shares: [TokensPerSecondModelShare]) -> [TokensPerSecondModelShare] {
        var byModel: [String: TokensPerSecondModelShare] = [:]
        for share in shares {
            var entry = byModel[share.model.lowercased()] ?? TokensPerSecondModelShare(
                model: share.model, outputTokens: 0, seconds: 0, intervals: 0
            )
            entry.outputTokens += share.outputTokens
            entry.seconds += share.seconds
            entry.intervals += share.intervals
            byModel[share.model.lowercased()] = entry
        }
        return byModel.values
            .sorted { lhs, rhs in
                if lhs.outputTokens != rhs.outputTokens { return lhs.outputTokens > rhs.outputTokens }
                return lhs.model.localizedStandardCompare(rhs.model) == .orderedAscending
            }
    }

    /// Build from accumulated per-provider accumulators. Providers with no paired reports are omitted.
    /// `now` anchors the calendar-day windows the lens switches between.
    static func from(
        _ accumulators: [String: TokensPerSecondAccumulator],
        now: Date = Date()
    ) -> TokensPerSecondEstimate {
        var corpora: [String: TokensPerSecondCorpus] = [:]
        var models: [String: [TokensPerSecondModelShare]] = [:]
        for (id, accumulator) in accumulators {
            let corpus = accumulator.corpus
            guard corpus.intervals > 0 else { continue }
            corpora[id] = corpus
            models[id] = accumulator.modelShares
        }
        var windows: [TokensPerSecondWindow: TokensPerSecondWindowView] = [:]
        for window in TokensPerSecondWindow.allCases {
            let since = window.sinceDate(now: now)
            var windowCorpora: [String: TokensPerSecondCorpus] = [:]
            var windowModels: [String: [TokensPerSecondModelShare]] = [:]
            for (id, accumulator) in accumulators {
                let corpus = accumulator.corpus(since: since)
                guard corpus.intervals > 0 else { continue }
                windowCorpora[id] = corpus
                windowModels[id] = accumulator.modelShares(since: since)
            }
            windows[window] = TokensPerSecondWindowView(corpora: windowCorpora, models: windowModels)
        }
        return TokensPerSecondEstimate(corpora: corpora, models: models, windows: windows)
    }
}

enum TokensPerSecond {
    /// Local-log window the fold covers. Long enough to survive a quiet week, short enough that the
    /// fold stays cheap on a deep session corpus.
    static let windowDays = 14
    /// Consecutive-pair intervals counted toward a corpus's headline estimate.
    static let minimumIntervals = 5
    /// Fewer paired reports than this and a model's rate reads as noise, not an estimate.
    static let minimumModelIntervals = 3
    /// Shorter than this and the pair is timer granularity, not a generation rate.
    static let minimumInterval: TimeInterval = 0.2
    /// Longer than this is a tool-call round trip or an idle gap, not model generation.
    static let maximumInterval: TimeInterval = 60
    /// A source that records its own stream duration can include much longer generations — a
    /// slow reasoning pass is still generation, not a tool gap.
    static let maximumDirectInterval: TimeInterval = 300
}

/// The lens's window switcher: the same 14-day fold, bucketed by local calendar day, viewed over
/// Today, the last 7 days, or the full window. Switching never re-reads a log file.
enum TokensPerSecondWindow: String, CaseIterable, Identifiable, Sendable {
    case today
    case sevenDays
    case fourteenDays

    var id: String { rawValue }

    /// The fold window this view covers; the full window is the fold itself.
    var days: Int {
        switch self {
        case .today: return 1
        case .sevenDays: return 7
        case .fourteenDays: return TokensPerSecond.windowDays
        }
    }

    /// Segment labels, matching the spend lens's picker scale.
    var shortLabel: String {
        switch self {
        case .today: return "Today"
        case .sevenDays: return "7 Days"
        case .fourteenDays: return "14 Days"
        }
    }

    /// The model list's window caption.
    var windowLabel: String {
        switch self {
        case .today: return "Today"
        case .sevenDays: return "Last 7 days"
        case .fourteenDays: return "Last 14 days"
        }
    }

    /// Values-line label suffix. The full window keeps the historical bare labels so existing
    /// snapshots and consumers read unchanged.
    var labelSuffix: String {
        switch self {
        case .today: return " (Today)"
        case .sevenDays: return " (7 Days)"
        case .fourteenDays: return ""
        }
    }

    /// Lower bound of the window, on the same calendar semantics as the fold's scan window.
    func sinceDate(now: Date) -> Date {
        switch self {
        case .today:
            return Calendar.current.startOfDay(for: now)
        case .sevenDays, .fourteenDays:
            return JSONLScanning.sinceDate(daysBack: days, now: now)
        }
    }
}

/// Stateful visitor over one corpus's usage reports in stream order. Each report contributes the
/// interval since the previous one; out-of-order pairs across file boundaries are re-based instead
/// of folded in. Per-model buckets ride the same qualifying intervals as the corpus total.
struct TokensPerSecondAccumulator: Sendable {
    private(set) var corpus = TokensPerSecondCorpus()
    private var modelCorpora: [String: TokensPerSecondCorpus] = [:]
    private var modelSpellings: [String: String] = [:]
    private var lastTimestamp: Date?
    /// Qualifying intervals with their local calendar day, so the lens can view Today / 7 Days /
    /// 14 Days without re-folding. Bounded by the fold window — only generation-paced pairs land here.
    private var intervals: [(day: Date, tokens: Int, seconds: Double, model: String?)] = []

    /// `directInterval`, when the source records stream duration itself (ZCode's `first_token_at →
    /// completed_at`), supplies the interval verbatim instead of the elapsed time since the previous
    /// report; direct generation can legitimately span longer windows than a pair-eligible gap.
    mutating func ingest(outputTokens: Int, at timestamp: Date, model: String? = nil, directInterval: TimeInterval? = nil) {
        let last = lastTimestamp
        lastTimestamp = timestamp
        let interval: Double
        if let direct = directInterval {
            guard direct >= TokensPerSecond.minimumInterval, direct <= TokensPerSecond.maximumDirectInterval else {
                return
            }
            interval = direct
        } else {
            guard outputTokens > 0, let last else { return }
            let elapsed = timestamp.timeIntervalSince(last)
            guard elapsed >= TokensPerSecond.minimumInterval,
                  elapsed <= TokensPerSecond.maximumInterval
            else { return }
            interval = elapsed
        }
        guard outputTokens > 0 else { return }
        corpus.add(outputTokens: outputTokens, seconds: interval)
        let normalized = Self.normalizedModelName(model)
        intervals.append((
            day: Calendar.current.startOfDay(for: timestamp),
            tokens: outputTokens,
            seconds: interval,
            model: normalized
        ))
        if let normalized {
            var modelCorpus = modelCorpora[normalized] ?? TokensPerSecondCorpus()
            modelCorpus.add(outputTokens: outputTokens, seconds: interval)
            modelCorpora[normalized] = modelCorpus
            if modelSpellings[normalized] == nil { modelSpellings[normalized] = model }
        }
    }

    /// The corpus restricted to intervals on or after `since` (a local calendar day boundary).
    func corpus(since: Date) -> TokensPerSecondCorpus {
        var result = TokensPerSecondCorpus()
        for interval in intervals where interval.day >= since {
            result.add(outputTokens: interval.tokens, seconds: interval.seconds)
        }
        return result
    }

    /// Per-model shares over the same sub-window, ranked exactly like the full-window shares.
    func modelShares(since: Date) -> [TokensPerSecondModelShare] {
        var byModel: [String: TokensPerSecondCorpus] = [:]
        for interval in intervals where interval.day >= since {
            guard let model = interval.model else { continue }
            var modelCorpus = byModel[model] ?? TokensPerSecondCorpus()
            modelCorpus.add(outputTokens: interval.tokens, seconds: interval.seconds)
            byModel[model] = modelCorpus
        }
        return byModel
            .map { key, corpus in
                TokensPerSecondModelShare(
                    model: modelSpellings[key] ?? key,
                    outputTokens: corpus.outputTokens,
                    seconds: corpus.seconds,
                    intervals: corpus.intervals
                )
            }
            .sorted { lhs, rhs in
                if lhs.outputTokens != rhs.outputTokens { return lhs.outputTokens > rhs.outputTokens }
                return lhs.model.localizedStandardCompare(rhs.model) == .orderedAscending
            }
    }

    /// Per-model shares for this corpus, ranked by tokens (descending). Models backed only by
    /// zero-token or empty names never appear.
    var modelShares: [TokensPerSecondModelShare] {
        modelCorpora
            .map { key, corpus in
                TokensPerSecondModelShare(
                    model: modelSpellings[key] ?? key,
                    outputTokens: corpus.outputTokens,
                    seconds: corpus.seconds,
                    intervals: corpus.intervals
                )
            }
            .sorted { lhs, rhs in
                if lhs.outputTokens != rhs.outputTokens { return lhs.outputTokens > rhs.outputTokens }
                return lhs.model.localizedStandardCompare(rhs.model) == .orderedAscending
            }
    }

    private static func normalizedModelName(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return nil }
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Maps the estimate onto the provider-neutral metric vocabulary (`MetricLine.values`). Kept pure so
/// a test can feed a fixed estimate and assert the exact wire shape. The TPS panel reads these raw
/// lines — the provider ships no widget descriptors and no dashboard rows.
enum TokensPerSecondMapper {
    /// Values-line label per provider id; the lens reads them as its provider rows.
    static let providerLabels: [String: String] = [
        "claude": "Claude",
        "codex": "Codex",
        "grok": "Grok",
        "muse": "Muse",
        "pi": "Pi",
        "zai": "Z.ai",
        "antigravity": "Antigravity"
    ]

    static func lines(
        _ estimate: TokensPerSecondEstimate,
        window: TokensPerSecondWindow = .fourteenDays
    ) -> [MetricLine] {
        // Manually built estimates (tests, legacy snapshots) carry no window views; the headline
        // corpora are the full window.
        let view = estimate.windows[window]
            ?? TokensPerSecondEstimate.TokensPerSecondWindowView(corpora: estimate.corpora, models: estimate.models)
        var rows: [MetricLine] = [
            row(
                label: "Est. TPS" + window.labelSuffix,
                corpus: view.combined,
                models: view.combinedModels,
                totalTokens: view.combined.outputTokens
            )
        ]
        for id in TokensPerSecondEstimate.providerOrder {
            guard let corpus = view.corpora[id], let label = providerLabels[id] else { continue }
            rows.append(row(
                label: label + window.labelSuffix,
                corpus: corpus,
                models: view.models[id] ?? [],
                totalTokens: corpus.outputTokens
            ))
        }
        return rows
    }

    private static func row(
        label: String,
        corpus: TokensPerSecondCorpus,
        models: [TokensPerSecondModelShare],
        totalTokens: Double
    ) -> MetricLine {
        var values: [MetricValue] = []
        if let rate = corpus.tokensPerSecond {
            values.append(MetricValue(number: rate, kind: .count, label: "tok/s", estimated: true))
        }
        if totalTokens > 0, corpus.intervals > 0 {
            values.append(MetricValue(number: totalTokens, kind: .count, label: "tokens", estimated: true))
        }
        let breakdown = modelBreakdown(models: models, totalTokens: totalTokens)
        return .values(label: label, values: values, modelBreakdown: breakdown)
    }

    /// The panel's model breakdown: ranked by tokens, rate when the model has enough paired
    /// reports to mean it. `nil` when nothing qualifies (the panel then hides the section).
    static func modelBreakdown(
        models: [TokensPerSecondModelShare],
        totalTokens: Double
    ) -> ModelUsageBreakdown? {
        guard !models.isEmpty, totalTokens > 0 else { return nil }
        let entries = models.map {
            ModelUsageEntry(
                model: $0.model,
                totalTokens: Int(min($0.outputTokens, Double(Int.max))),
                costUSD: nil,
                tokensPerSecond: $0.rate
            )
        }
        return ModelUsageBreakdown(
            totalTokens: Int(min(totalTokens, Double(Int.max))),
            totalCostUSD: nil,
            models: entries,
            sourceNote: "Estimated from local session logs"
        )
    }
}
