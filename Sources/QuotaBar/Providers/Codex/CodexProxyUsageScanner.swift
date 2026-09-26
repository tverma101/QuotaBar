import CryptoKit
import Foundation

/// Reads only the metadata needed to fold FCC-routed Codex requests into the matching Codex card.
///
/// FCC stores a privacy-preserving account fingerprint on new proxy events. The account id is not
/// reversible from that value, and this scanner never reads prompt/response content or credentials.
/// Rows without an account fingerprint are deliberately ignored: historical FCC rows cannot be
/// reconstructed safely after a second Codex account is added.
actor CodexProxyUsageScanner {
    private let sqlite: SQLiteAccessing
    private let environment: EnvironmentReading
    private let homeDirectory: @Sendable () -> URL
    private let databasePaths: @Sendable () -> [String]

    init(
        sqlite: SQLiteAccessing = SQLiteCLIAccessor(),
        environment: EnvironmentReading = QuotaBarEnvironmentReader(),
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser },
        databasePaths: (@Sendable () -> [String])? = nil
    ) {
        self.sqlite = sqlite
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.databasePaths = databasePaths ?? {
            Self.defaultDatabasePaths(environment: environment, homeDirectory: homeDirectory())
        }
    }

    /// Scan FCC's local ledger for one exact Codex account. A missing account identity, missing
    /// database, old schema, or empty match returns `nil`, leaving native Codex logs untouched.
    func scan(
        accountIdentityKey: String?,
        daysBack: Int = UsageHistoryWindow.previousDays,
        now: Date = Date(),
        pricing: ModelPricing
    ) async -> LogUsageScan? {
        guard let fingerprint = Self.accountFingerprint(for: accountIdentityKey) else { return nil }
        let days = max(1, daysBack)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let since = calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today
        let sinceDay = DailyUsageAccumulator.dayKey(from: since, calendar: calendar)
        let throughDay = DailyUsageAccumulator.dayKey(from: today, calendar: calendar)

        var accumulator = DailyUsageAccumulator()
        var sawRows = false
        for path in databasePaths() {
            guard !Task.isCancelled else { return nil }
            guard let schema = try? sqlite.queryValue(path: path, sql: Self.schemaSQL),
                  Self.hasRequiredSchema(schema)
            else { continue }
            guard let payload = try? sqlite.queryValue(
                path: path,
                sql: Self.eventsSQL(
                    fingerprint: fingerprint,
                    sinceDay: sinceDay,
                    throughDay: throughDay
                )
            ) else { continue }
            for row in Self.rows(from: payload) {
                guard let day = Self.validDay(row["local_day"] as? String),
                      let model = Self.modelName(row["model"] as? String),
                      let input = Self.count(row["input_tokens"]),
                      let output = Self.count(row["output_tokens"]),
                      let cacheRead = Self.count(row["cache_read_input_tokens"]),
                      let cacheWrite = Self.count(row["cache_creation_input_tokens"])
                else { continue }
                guard let total = Self.total(input: input, cacheRead: cacheRead, cacheWrite: cacheWrite, output: output),
                      total > 0
                else { continue }

                sawRows = true
                let tokens = TokenBreakdown(
                    input: input,
                    cacheWrite5m: cacheWrite,
                    cacheRead: cacheRead,
                    output: output
                )
                guard let pricingModel = Self.pricingModelCandidates(for: model).first(where: { pricing.resolve(model: $0) != nil }),
                      let cost = pricing.estimatedCostDollars(model: pricingModel, tokens: tokens)
                else {
                    accumulator.addUnknownModel(day: day, model: model)
                    continue
                }
                accumulator.add(day: day, tokens: total, cost: cost, model: model)
            }
        }

        guard sawRows else { return nil }
        let result = accumulator.build()
        return result.series.daily.isEmpty && result.unknownModelsByDay.isEmpty ? nil : result
    }

    /// The exact compatibility contract with FCC's `account_fingerprint("openai", account_id)`.
    /// QuotaBar's account registry normalizes UUID identities to lowercase, which matches Codex's
    /// persisted account ids in practice and keeps both sides deterministic.
    static func accountFingerprint(for identityKey: String?) -> String? {
        guard let identity = identityKey?.trimmingCharacters(in: .whitespacesAndNewlines), !identity.isEmpty else {
            return nil
        }
        let digest = SHA256.hash(data: Data("openai\0\(identity)".utf8))
        return "acct_" + digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    static func defaultDatabasePaths(
        environment: EnvironmentReading,
        homeDirectory: URL
    ) -> [String] {
        let configured = [
            environment.value(for: "OPENUSAGE_CODEX_PROXY_USAGE_DB"),
            environment.value(for: "FCC_USAGE_DB")
        ].flatMap(splitPaths)
        guard configured.isEmpty else { return unique(configured) }
        return [homeDirectory.appendingPathComponent(".fcc/usage.db").path]
    }

    private static let schemaSQL = "PRAGMA table_info(usage_events);"

    private static func eventsSQL(fingerprint: String, sinceDay: String, throughDay: String) -> String {
        let escapedFingerprint = fingerprint.replacingOccurrences(of: "'", with: "''")
        let escapedSince = sinceDay.replacingOccurrences(of: "'", with: "''")
        let escapedThrough = throughDay.replacingOccurrences(of: "'", with: "''")
        return """
        SELECT json_group_array(json_object(
            'local_day', local_day,
            'model', model,
            'input_tokens', input_tokens,
            'output_tokens', output_tokens,
            'cache_read_input_tokens', cache_read_input_tokens,
            'cache_creation_input_tokens', cache_creation_input_tokens
        ))
        FROM usage_events
        WHERE provider_id = 'openai'
          AND source = 'fcc_proxy'
          AND account_fingerprint = '\(escapedFingerprint)'
          AND local_day BETWEEN '\(escapedSince)' AND '\(escapedThrough)';
        """
    }

    private static func hasRequiredSchema(_ payload: String?) -> Bool {
        guard let payload else { return false }
        let columns = Set(payload.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let fields = line.split(separator: "|", omittingEmptySubsequences: false)
            if fields.count >= 2 { return String(fields[1]) }
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        })
        return [
            "provider_id", "local_day", "model", "input_tokens", "output_tokens",
            "cache_read_input_tokens", "cache_creation_input_tokens", "source", "account_fingerprint"
        ].allSatisfy(columns.contains)
    }

    private static func rows(from payload: String) -> [[String: Any]] {
        guard let data = payload.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data),
              let rows = value as? [[String: Any]]
        else { return [] }
        return rows
    }

    private static func validDay(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              raw.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
        else { return nil }
        return raw
    }

    private static func modelName(_ raw: String?) -> String? {
        let model = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        return model?.isEmpty == false ? model : ModelUsageEntry.unattributedModelName
    }

    private static func count(_ value: Any?) -> Int? {
        guard let number = ProviderParse.number(value), number >= 0, number <= Double(Int.max) else {
            return nil
        }
        return Int(number.rounded(.down))
    }

    private static func total(input: Int, cacheRead: Int, cacheWrite: Int, output: Int) -> Int? {
        var total = 0
        for value in [input, cacheRead, cacheWrite, output] {
            let result = total.addingReportingOverflow(value)
            guard !result.overflow else { return nil }
            total = result.partialValue
        }
        return total
    }

    private static func pricingModelCandidates(for model: String) -> [String] {
        // FCC / gateway slugs are often multi-segment (`anthropic/openai/gpt-6-luna`).
        // Emit every suffix after a `/` plus the final path component so supplement pins and
        // catalog keys resolve even when an intermediate segment does not fuzzy-match.
        var candidates = [model]
        var remainder = model
        while let separator = remainder.firstIndex(of: "/") {
            remainder = String(remainder[remainder.index(after: separator)...])
            guard !remainder.isEmpty else { break }
            candidates.append(remainder)
        }
        return unique(candidates)
    }

    private static func splitPaths(_ raw: String?) -> [String] {
        guard let raw else { return [] }
        return raw.split { $0 == "," || $0 == "\n" || $0 == "\r" }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func unique(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        return paths.filter { seen.insert($0).inserted }
    }
}
