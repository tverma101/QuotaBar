import Foundation

/// Keeps only public model identities, never expiring handles or login credentials. The existing
/// pricing store supplies OpenRouter rates; this catalogue only resolves Freebuff's opaque keys.
actor FreebuffModelCatalog {
    struct Entry: Codable, Equatable, Sendable {
        var key: String
        var displayName: String
        var legacyDigests: [String]?
    }
    private struct Cache: Codable {
        var fetchedAt: Date
        var entries: [Entry]
    }
    private let cacheURL: URL?
    private var cache: Cache?
    /// When the last catalogue request was made, successful or not.
    private var lastAttemptAt: Date?
    /// Why the last attempt failed, so the backoff can keep reporting it.
    private var lastFailure: FreebuffUsageError?

    /// How long a fetched catalogue stays fresh.
    static let refreshInterval: TimeInterval = 3600
    /// The minimum gap between attempts. A failing endpoint backs off to the same cadence as a
    /// working one instead of being re-requested on every refresh tick.
    static let retryInterval: TimeInterval = 3600

    init(cacheURL: URL? = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/QuotaBar/freebuff-model-identities.json")) {
        self.cacheURL = cacheURL
        if let cacheURL, let data = try? Data(contentsOf: cacheURL) {
            do { cache = try JSONDecoder().decode(Cache.self, from: data) }
            catch { AppLog.warn(LogTag.auth("freebuff"), "saved model identities could not be decoded") }
        }
    }

    func current() -> [String: Entry] {
        Dictionary((cache?.entries ?? []).map { ($0.key, $0) }, uniquingKeysWith: { _, last in last })
    }

    func refresh(auth: FreebuffAuth, client: FreebuffUsageClient, now: Date) async throws {
        if let cache, now.timeIntervalSince(cache.fetchedAt) < Self.refreshInterval { return }
        // A failed attempt backs off like a successful one. Without this the catalogue was
        // re-requested on every refresh tick for as long as the endpoint stayed broken.
        if let lastAttemptAt, now.timeIntervalSince(lastAttemptAt) < Self.retryInterval {
            if let lastFailure { throw lastFailure }
            return
        }
        lastAttemptAt = now
        do {
            let response = try await client.fetchModelCatalog(auth: auth)
            guard (200..<300).contains(response.statusCode) else {
                throw FreebuffUsageError.requestFailed(response.statusCode)
            }
            struct Wire: Decodable { var `protocol`: Int; var rows: [Entry] }
            let wire = try JSONDecoder().decode(Wire.self, from: response.body)
            guard wire.protocol == 1, !wire.rows.isEmpty,
                  wire.rows.allSatisfy({ !$0.key.isEmpty && !$0.displayName.isEmpty }),
                  Set(wire.rows.map(\.key)).count == wire.rows.count else {
                throw FreebuffUsageError.invalidResponse
            }
            let replacement = Cache(fetchedAt: now, entries: wire.rows)
            if let cacheURL {
                try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(replacement).write(to: cacheURL, options: .atomic)
            }
            cache = replacement
            lastFailure = nil
        } catch is CancellationError {
            // A cancelled refresh is not a failed endpoint; the next one may try again right away.
            lastAttemptAt = nil
            throw CancellationError()
        } catch {
            lastFailure = (error as? FreebuffUsageError) ?? .invalidResponse
            throw error
        }
    }

    /// Exact normalized names and explicit supplement aliases only; preserve every version/variant
    /// word. Ambiguous routes remain unpriced. No fuzzy lookup or opaque-key-to-model guessing.
    static func pricingRoute(for model: String, entries: [String: Entry], pricing: ModelPricing) -> String? {
        if pricing.openRouter.entries[model] != nil || pricing.supplement.pricing[model] != nil {
            return model
        }
        return pricingRoutes(entries: entries, pricing: pricing)[model]
    }

    static func pricingRoutes(entries: [String: Entry], pricing: ModelPricing) -> [String: String] {
        let index = Dictionary(grouping: pricing.openRouter.entries.keys.filter { $0.contains("/") }) {
            normalized(String($0.split(separator: "/").last ?? Substring($0)))
        }
        var routes: [String: String] = entries.compactMapValues { entry -> String? in
            if let matches = index[normalized(entry.displayName)], matches.count == 1 {
                return matches.first
            }
            // Freebuff removed its Flash Fast serving mode: the catalogue still lists the old key,
            // but hosted receipts only ever carry the plain Flash slug, so the base model serves
            // that usage. Collapse the removed mode onto its base name so it prices as the model
            // that actually served it, never at the retired Fast-tier estimate rates.
            if let base = removedModeBaseName(entry.displayName),
               let matches = index[normalized(base)], matches.count == 1 {
                return matches.first
            }
            return nil
        }
        // OpenRouter has no separate DeepSeek Flash Fast route. A verified model-specific alias
        // may point to a curated public route rate instead; only consider it after exact OpenRouter
        // matching, so the public route keeps precedence and unrelated variants stay unpriced.
        for (model, entry) in entries where routes[model] == nil {
            // A removed Fast mode resolves through its base model's alias, keeping the retired
            // Fast-tier canonical unreachable from catalogue names.
            let name = removedModeBaseName(entry.displayName) ?? entry.displayName
            guard let canonical = pricing.supplement.canonicalName(for: name),
                  pricing.supplement.pricing[canonical] != nil else { continue }
            routes[model] = canonical
        }
        return routes
    }

    /// The base model name when a display name carries Freebuff's removed "Fast" serving mode, or
    /// nil for every other name. Mode words sit behind a trailing snapshot date
    /// (`DeepSeek V4.1 Flash Fast 10/17`), so the date is stripped first — the same date-then-mode
    /// order `groupName` uses. Slow remains a real, separately-served mode and is never stripped.
    static func removedModeBaseName(_ displayName: String) -> String? {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let dateStripped = trimmed.replacingOccurrences(
            of: #"\s+\d{1,2}/\d{1,2}$"#,
            with: "", options: [.regularExpression, .caseInsensitive]
        )
        guard dateStripped.range(of: #"\s+Fast$"#, options: [.regularExpression, .caseInsensitive]) != nil
        else { return nil }
        let base = dateStripped.replacingOccurrences(
            of: #"\s+Fast$"#,
            with: "", options: [.regularExpression, .caseInsensitive]
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return base.isEmpty ? nil : base
    }

    private static func normalized(_ name: String) -> String {
        // Freebuff labels the same Haiku route once with an extra "100k context" descriptor. It is
        // a context annotation, not a distinct route; per-request context tiers cannot be applied to
        // its aggregated turn receipts, so route it to the exact base model entry.
        let routeName = name.replacingOccurrences(
            of: #"\s*(?:[·•]\s*)?100k\s+context$"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        return routeName.lowercased()
            .replacingOccurrences(of: #"\bv(?=\d)"#, with: "", options: .regularExpression)
            .filter { $0.isLetter || $0.isNumber }
    }
}
