import Foundation

enum GenerationSpeedSource: String, CaseIterable, Identifiable, Sendable {
    case zcode = "ZCode"
    case antigravity = "Antigravity"

    var id: Self { self }
    var timing: String {
        switch self {
        case .zcode: "First token to completion"
        case .antigravity: "Response creation to end of generation"
        }
    }
}

enum GenerationSpeedWindow: String, CaseIterable, Identifiable, Sendable {
    case today = "Today"
    case yesterday = "Yesterday"
    case week = "7 Days"
    case fortnight = "14 Days"

    var id: Self { self }
    func start(now: Date, calendar: Calendar) -> Date {
        let earlierDays = switch self {
        case .today: 0
        case .yesterday: 1
        case .week: 6
        case .fortnight: 13
        }
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: -earlierDays, to: today) ?? today
    }
}

struct GenerationSpeedSample: Sendable {
    let finishedAt: Date
    let seconds: Double
    let outputTokens: Int64
    let model: String?
}

struct GenerationSpeedTotals: Equatable, Sendable {
    private(set) var tokens: Double = 0
    private(set) var seconds: Double = 0
    private(set) var samples: Int = 0

    mutating func add(_ added: Self) {
        tokens += added.tokens
        seconds += added.seconds
        samples += added.samples
    }

    mutating func add(_ sample: GenerationSpeedSample) {
        tokens += Double(sample.outputTokens)
        seconds += sample.seconds
        samples += 1
    }

    func rate(minimumSamples: Int) -> Double? {
        guard samples >= minimumSamples, seconds > 0 else { return nil }
        let rate = tokens / seconds
        return rate.isFinite ? rate : nil
    }
}

struct GenerationSpeedReport: Sendable {
    struct Model: Identifiable, Sendable {
        let id: String
        let totals: GenerationSpeedTotals
    }

    struct Row: Identifiable, Sendable {
        let id: GenerationSpeedSource
        let totals: GenerationSpeedTotals
        let models: [Model]
    }

    private let now: Date
    private let calendar: Calendar
    private var buckets: [GenerationSpeedSource: [Date: [String: GenerationSpeedTotals]]] = [:]
    private(set) var unavailable: Set<GenerationSpeedSource> = []
    private(set) var unsupported: Set<GenerationSpeedSource> = []

    init(now: Date, calendar: Calendar) {
        self.now = now
        self.calendar = calendar
    }

    mutating func markUnavailable(_ source: GenerationSpeedSource) { unavailable.insert(source) }
    mutating func markUnsupported(_ source: GenerationSpeedSource) { unsupported.insert(source) }

    mutating func add(_ sample: GenerationSpeedSample, source: GenerationSpeedSource) {
        guard (0.2...300).contains(sample.seconds), sample.outputTokens > 0,
              sample.finishedAt >= GenerationSpeedWindow.fortnight.start(now: now, calendar: calendar),
              sample.finishedAt <= now else { return }
        let day = calendar.startOfDay(for: sample.finishedAt)
        let model = sample.model?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Unattributed"
        buckets[source, default: [:]][day, default: [:]][model, default: GenerationSpeedTotals()].add(sample)
    }

    func rows(window: GenerationSpeedWindow) -> [Row] {
        let start = window.start(now: now, calendar: calendar)
        let end = window == .yesterday ? calendar.startOfDay(for: now) : nil
        return GenerationSpeedSource.allCases.compactMap { source in
            guard let days = buckets[source] else { return nil }
            var models: [String: GenerationSpeedTotals] = [:]
            for (date, day) in days.sorted(by: { $0.key < $1.key }) where date >= start && (end.map { date < $0 } ?? true) {
                for (name, total) in day { models[name, default: GenerationSpeedTotals()].add(total) }
            }
            guard !models.isEmpty else { return nil }
            var sorted: [Model] = []
            sorted.reserveCapacity(models.count)
            for (name, totals) in models { sorted.append(Model(id: name, totals: totals)) }
            sorted.sort {
                $0.totals.samples == $1.totals.samples ? $0.id < $1.id : $0.totals.samples > $1.totals.samples
            }
            var total = GenerationSpeedTotals()
            for model in sorted { total.add(model.totals) }
            return Row(id: source, totals: total, models: sorted)
        }
    }
}
