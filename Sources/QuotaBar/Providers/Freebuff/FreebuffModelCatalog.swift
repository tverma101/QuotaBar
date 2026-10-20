import Foundation

/// Keeps only public model identities, never expiring handles or login credentials. The existing
/// pricing store supplies OpenRouter rates; this catalogue only resolves Freebuff's opaque keys.
actor FreebuffModelCatalog {
    struct Entry: Codable, Sendable {
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
        if let cache, now.timeIntervalSince(cache.fetchedAt) < 3600 { return }
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
    }

    /// Exact normalized names only; preserve every version/variant word. Ambiguous routes remain
    /// unpriced. No fuzzy rate lookup or opaque-key-to-model guessing.
    static func openRouterRoute(for model: String, entries: [String: Entry], pricing: ModelPricing) -> String? {
        if pricing.openRouter.entries[model] != nil { return model }
        return openRouterRoutes(entries: entries, pricing: pricing)[model]
    }

    static func openRouterRoutes(entries: [String: Entry], pricing: ModelPricing) -> [String: String] {
        let index = Dictionary(grouping: pricing.openRouter.entries.keys.filter { $0.contains("/") }) {
            normalized(String($0.split(separator: "/").last ?? Substring($0)))
        }
        return entries.compactMapValues { entry in
            guard let matches = index[normalized(entry.displayName)], matches.count == 1 else { return nil }
            return matches.first
        }
    }

    private static func normalized(_ name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: #"\bv(?=\d)"#, with: "", options: .regularExpression)
            .filter { $0.isLetter || $0.isNumber }
    }
}
