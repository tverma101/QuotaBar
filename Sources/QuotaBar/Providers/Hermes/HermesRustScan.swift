import Foundation

/// Which engine performs a Hermes scan. Rust is the production engine; `.swift` keeps the original
/// SQLite-CLI implementation available as the parity oracle and as a fallback when the backend
/// declines a refresh (a null handle or an internal failure — never a different answer).
enum HermesScanEngine: Sendable, Equatable {
    case rust
    case swift
}

/// Decodes the Rust backend's Hermes scan into the app's existing `HermesUsageScan` model.
///
/// The backend performs path-independent database work only: the caller supplies the local-calendar
/// period starts and cutoffs, so `Calendar.current` stays the single authority for day boundaries.
/// Presentation (spend rows, chart labels, formatting) stays in `HermesUsageMapper`.
enum HermesRustScan {
    /// The backend declined this refresh; the caller falls back to the Swift reference scan.
    struct BridgeUnavailable: Error, CustomStringConvertible {
        let reason: String
        var description: String { reason }
    }

    static func scan(path: String, now: Date, calendar: Calendar) throws -> HermesUsageScan {
        let starts = HermesUsageScanner.periodStarts(now: now, calendar: calendar)
        let params: [String: Any] = [
            "databasePath": path,
            "periodStarts": [
                "today": starts[0].start.timeIntervalSince1970,
                "thisWeek": starts[1].start.timeIntervalSince1970,
                "thisMonth": starts[2].start.timeIntervalSince1970,
            ],
            "maximumTimestamp": JSONLScanning.maximumTimestamp(now: now).timeIntervalSince1970,
            "dailyCutoff": HermesUsageScanner.dailyCutoff(now: now, calendar: calendar)
                .timeIntervalSince1970,
        ]

        let payload: Data
        do {
            payload = try RustBackend.call(op: "hermes.scan", params: params)
        } catch let error as RustBackend.BackendError {
            switch error.kind {
            case "database_unreadable":
                throw HermesUsageError.databaseUnreadable(detail: error.message)
            default:
                // An internal or contract failure must not be presented as an unreadable database.
                // Fall back to the Swift engine so the refresh still returns the reference answer.
                throw BridgeUnavailable(reason: "\(error.kind): \(error.message)")
            }
        } catch {
            throw BridgeUnavailable(reason: error.localizedDescription)
        }

        let decoded: ScanPayload
        do {
            decoded = try JSONDecoder().decode(ScanPayload.self, from: payload)
        } catch {
            throw BridgeUnavailable(reason: "decode failed: \(error)")
        }
        return decoded.scan
    }

    // MARK: - Wire shape

    private struct ScanPayload: Decodable {
        struct Period: Decodable {
            let period: String
            let input: Int
            let output: Int
            let cacheRead: Int
            let cacheWrite: Int
            let reasoning: Int
            let apiCallCount: Int
            let costUSD: Double?
            let isPartial: Bool
        }

        struct Model: Decodable {
            let model: String
            let tokens: Int
            let costUSD: Double?
            let isPartial: Bool
        }

        struct Day: Decodable {
            let date: String
            let totalTokens: Int
            let costUSD: Double?
            let costIsComplete: Bool
        }

        let periods: [Period]
        let daily: [Day]
        let modelUsageByPeriod: [String: [Model]]
        let partialDays: [String]

        var scan: HermesUsageScan {
            HermesUsageScan(
                periods: periods.compactMap { period in
                    guard let kind = HermesPeriod(rawValue: period.period) else { return nil }
                    return HermesPeriodUsage(
                        period: kind,
                        counts: HermesTokenCounts(
                            input: period.input,
                            output: period.output,
                            cacheRead: period.cacheRead,
                            cacheWrite: period.cacheWrite,
                            reasoning: period.reasoning
                        ),
                        costUSD: period.costUSD,
                        apiCallCount: period.apiCallCount,
                        isPartial: period.isPartial
                    )
                },
                daily: DailyUsageSeries(daily: daily.map {
                    DailyUsageEntry(
                        date: $0.date,
                        totalTokens: $0.totalTokens,
                        costUSD: $0.costUSD,
                        costIsComplete: $0.costIsComplete
                    )
                }),
                modelUsageByPeriod: modelUsageByPeriod.reduce(into: [:]) { result, entry in
                    guard let kind = HermesPeriod(rawValue: entry.key) else { return }
                    // Same ordering the reference scanner applies: tokens first, then the localized
                    // standard model-name comparison (display order, so it stays at the Swift edge).
                    result[kind] = entry.value
                        .map {
                            HermesModelUsage(
                                model: $0.model,
                                tokens: $0.tokens,
                                costUSD: $0.costUSD,
                                isPartial: $0.isPartial
                            )
                        }
                        .sorted { lhs, rhs in
                            if lhs.tokens != rhs.tokens { return lhs.tokens > rhs.tokens }
                            return lhs.model.localizedStandardCompare(rhs.model) == .orderedAscending
                        }
                },
                partialDays: Set(partialDays)
            )
        }
    }
}
