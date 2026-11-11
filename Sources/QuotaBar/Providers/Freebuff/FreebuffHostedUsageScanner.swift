import CryptoKit
import Foundation

/// Incremental reader for the history shared by Cloud and Desktop's On This Device mode.
/// Metrics are cumulative snapshots: replace a run's receipt, never sum its event rows.
actor FreebuffHostedUsageScanner {
    private struct Page<Item: Decodable>: Decodable {
        var items: [Item]
        var nextCursor: String?
        var endCursor: String?

        private enum CodingKeys: String, CodingKey { case items, nextCursor, endCursor }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            guard container.contains(.nextCursor) else { throw FreebuffUsageError.invalidResponse }
            items = try container.decode([Item].self, forKey: .items)
            nextCursor = try container.decodeIfPresent(String.self, forKey: .nextCursor)
            endCursor = try container.decodeIfPresent(String.self, forKey: .endCursor)
        }
    }
    private struct Chat: Decodable {
        var id: String
        var updatedAt: String
        var latestRun: Run?
    }
    private struct Run: Codable, Equatable, Sendable {
        var id: String
        var chatId: String
        var status: String
        var model: String?
        var agent: String?
        var createdAt: String
        var finishedAt: String?

        var isActive: Bool { ["queued", "running"].contains(status) }
        var isFreebuff: Bool { (agent == nil || agent == "codebuff") && model?.hasPrefix("byok:") != true }
    }
    private struct Event: Decodable {
        var kind: String
        var metricsJSON: String?

        private enum CodingKeys: String, CodingKey { case kind, payload }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            kind = try container.decode(String.self, forKey: .kind)
            // Non-metric payloads include conversation content; don't even decode them.
            guard kind == "metrics" else { return }
            let metrics = try container.decode(Metrics.self, forKey: .payload)
            if let usage = metrics.usage {
                let total = usage.inputTokens.addingReportingOverflow(usage.outputTokens)
                guard usage.inputTokens >= 0, usage.outputTokens >= 0, !total.overflow,
                      usage.cachedInputTokens.map({ $0 >= 0 && $0 <= usage.inputTokens }) ?? true,
                      usage.reasoningOutputTokens.map({ $0 >= 0 && $0 <= usage.outputTokens }) ?? true,
                      usage.totalTokens.map({ $0 == total.partialValue }) ?? true else {
                    throw FreebuffUsageError.invalidResponse
                }
            }
            metricsJSON = String(decoding: try JSONEncoder().encode(metrics), as: UTF8.self)
        }
    }
    private struct Metrics: Codable {
        struct Usage: Codable {
            var inputTokens: Int
            var outputTokens: Int
            var cachedInputTokens: Int?
            var reasoningOutputTokens: Int?
            var totalTokens: Int?
        }
        var usage: Usage?
        var usageIncomplete: Bool?

        /// Metrics can arrive as patches (for example a late context or interruption update).
        /// Missing fields are unknown, not instructions to erase a previously measured count.
        func merging(over previous: Metrics?) -> Metrics {
            Metrics(usage: usage ?? previous?.usage,
                    usageIncomplete: usageIncomplete ?? previous?.usageIncomplete)
        }
    }
    private struct CachedRun: Codable, Equatable, Sendable {
        var run: Run
        var cursor: String?
        var receipt: FreebuffUsageReceipt?
        /// Replay older cached streams once: those versions could discard usage on a sparse patch.
        var metricsVersion: Int?
        var retryAfter: Date?

        func needsReceiptRefresh(now: Date) -> Bool {
            metricsVersion != FreebuffHostedUsageScanner.metricsVersion || retryAfter.map { now >= $0 } == true
        }
    }
    private struct Cache: Codable, Equatable, Sendable {
        var accountKey: String
        var windowVersion: Int?
        var chats: [String: String] = [:]
        var runs: [String: CachedRun] = [:]
    }
    private struct Pending {
        var id: UUID
        var key: String
        var task: Task<Cache, Error>
    }

    private static let metricsVersion = 2
    static let incompleteReceiptRetryInterval: TimeInterval = 300
    static let maximumRuns = 10_000
    static let maximumCacheBytes = 8 * 1_024 * 1_024
    private let cacheURL: URL?
    private var cache: Cache?
    private var pending: Pending?

    init(cacheURL: URL? = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/QuotaBar/freebuff-hosted-usage-v1.json")) {
        self.cacheURL = cacheURL
        do { cache = try Self.loadCache(cacheURL) }
        catch { Self.logCacheReadFailure() }
    }

    private static func loadCache(_ url: URL?) throws -> Cache? {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard data.count <= maximumCacheBytes else { throw FreebuffUsageError.invalidResponse }
        return try autoreleasepool {
            try JSONDecoder().decode(Cache.self, from: data)
        }
    }

    private static func logCacheReadFailure() {
        AppLog.warn(LogTag.auth("freebuff"), "saved hosted token receipts could not be read; history will be fetched again")
    }

    func scan(auth: FreebuffAuth, client: FreebuffUsageClient, now: Date) async throws -> [FreebuffUsageReceipt] {
        let key = Self.accountKey(auth)
        if cache == nil {
            do { cache = try Self.loadCache(cacheURL) }
            catch { Self.logCacheReadFailure() }
        }
        let work: Pending
        if let pending, pending.key == key {
            work = pending
        } else {
            pending?.task.cancel()
            let initial = cache?.accountKey == key ? cache! : Cache(accountKey: key)
            work = Pending(id: UUID(), key: key, task: Task {
                try await Self.fetch(auth: auth, client: client, now: now, initial: initial)
            })
            pending = work
        }
        do {
            let replacement = try await withTaskCancellationHandler {
                try await work.task.value
            } onCancel: { work.task.cancel() }
            try Task.checkCancellation()
            // An older account's in-flight request must never overwrite the new account's cache.
            guard pending?.id == work.id else {
                guard cache?.accountKey == key else { throw CancellationError() }
                return Self.receipts(replacement)
            }
            if replacement != cache {
                let data = try JSONEncoder().encode(replacement)
                guard data.count <= Self.maximumCacheBytes else { throw FreebuffUsageError.invalidResponse }
                if let cacheURL {
                    try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: cacheURL, options: [.atomic, .completeFileProtectionUnlessOpen])
                }
            }
            cache = replacement
            pending = nil
            return Self.receipts(replacement)
        } catch {
            if pending?.id == work.id { pending = nil }
            throw error
        }
    }

    func cachedReceipts(auth: FreebuffAuth) throws -> [FreebuffUsageReceipt] {
        // Memory pressure drops the decoded mirror, not the persisted accounting evidence.
        // An offline/local fold must restore it before publishing totals without hosted usage.
        if cache == nil { cache = try Self.loadCache(cacheURL) }
        guard let cache, cache.accountKey == Self.accountKey(auth) else { return [] }
        return Self.receipts(cache)
    }

    func unloadCachesForMemoryPressure() {
        pending?.task.cancel()
        pending = nil
        cache = nil
    }

    private static func accountKey(_ auth: FreebuffAuth) -> String {
        SHA256.hash(data: Data(auth.token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func receipts(_ cache: Cache) -> [FreebuffUsageReceipt] {
        cache.runs.values.compactMap { cached in
            cached.receipt.map { receipt in
                var receipt = receipt
                receipt.model = cached.run.model
                return receipt
            }
        }.sorted { $0.id < $1.id }
    }

    private static func fetch(auth: FreebuffAuth, client: FreebuffUsageClient, now: Date, initial: Cache) async throws -> Cache {
        var result = initial
        // Previous versions chose the window by start time and may have skipped a long run that
        // finished recently. Recheck run lists once, retaining already measured event receipts.
        if result.windowVersion != 1 {
            result.chats = [:]
            result.windowVersion = 1
        }
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Calendar.current.startOfDay(for: now))!
        result.runs = result.runs.filter {
            $0.value.run.isActive || OpenUsageISO8601.date(from: $0.value.run.finishedAt ?? $0.value.run.createdAt).map { $0 >= cutoff } ?? false
        }
        let chats: [Chat] = try await pages(path: "chats", auth: auth, client: client)
        let chatIDs = Set(chats.map(\.id))
        result.chats = result.chats.filter { chatIDs.contains($0.key) }
        let activeChatIDs = Set(result.runs.values.filter {
            $0.run.isActive || $0.needsReceiptRefresh(now: now)
        }.map { $0.run.chatId })
        for chat in chats {
            try Task.checkCancellation()
            let active = chat.latestRun?.isActive == true || activeChatIDs.contains(chat.id)
            guard result.chats[chat.id] != chat.updatedAt || active else { continue }
            let runs: [Run] = try await pages(path: "chats/\(chat.id.urlFormEncoded)/runs", auth: auth, client: client)
            // A hidden/deleted chat or run cannot undo already measured consumption. Keep
            // accounting-only receipts until the window expires, independently of list visibility.
            for run in runs where !run.isFreebuff { result.runs.removeValue(forKey: run.id) }
            for run in runs where run.isFreebuff {
                guard let timestamp = OpenUsageISO8601.date(from: run.finishedAt ?? run.createdAt) else {
                    throw FreebuffUsageError.invalidResponse
                }
                guard run.isActive || timestamp >= cutoff else { continue }
                let previous = result.runs[run.id]
                guard previous?.run != run || run.isActive || previous?.needsReceiptRefresh(now: now) == true else { continue }
                result.runs[run.id] = try await readRun(run, previous: previous, auth: auth, client: client, now: now)
                guard result.runs.count <= maximumRuns else { throw FreebuffUsageError.invalidResponse }
            }
            result.chats[chat.id] = chat.updatedAt
        }
        return result
    }

    private static func readRun(_ run: Run, previous: CachedRun?, auth: FreebuffAuth,
                                client: FreebuffUsageClient, now: Date) async throws -> CachedRun {
        var result = previous ?? CachedRun(run: run)
        result.run = run
        if previous?.metricsVersion != metricsVersion {
            result.cursor = nil
            result.receipt = nil
        }
        var cursor = result.cursor
        var seen: Set<String> = []
        for _ in 0..<1_000 {
            try Task.checkCancellation()
            let page: Page<Event> = try await page(path: "runs/\(run.id.urlFormEncoded)/events", cursor: cursor, auth: auth, client: client)
            for event in page.items {
                guard let metrics = event.metricsJSON else { continue }
                guard let date = OpenUsageISO8601.date(from: run.finishedAt ?? run.createdAt) else {
                    throw FreebuffUsageError.invalidResponse
                }
                try autoreleasepool {
                    let patch = try JSONDecoder().decode(Metrics.self, from: Data(metrics.utf8))
                    let prior = try result.receipt.map { try JSONDecoder().decode(Metrics.self, from: Data($0.metricsJSON.utf8)) }
                    let merged = String(decoding: try JSONEncoder().encode(patch.merging(over: prior)), as: UTF8.self)
                    result.receipt = FreebuffUsageReceipt(id: "cloud:" + run.id, timestampMs: date.timeIntervalSince1970 * 1_000,
                                                         metricsJSON: merged, model: run.model)
                }
            }
            // endCursor advances across non-metric events as well, so an idle run downloads nothing twice.
            result.cursor = page.endCursor ?? page.nextCursor ?? cursor
            guard let next = page.nextCursor else {
                guard let date = OpenUsageISO8601.date(from: run.finishedAt ?? run.createdAt) else {
                    throw FreebuffUsageError.invalidResponse
                }
                // A run that supplied no metrics still has a coverage gap; never make it vanish
                // from the accounting pass or manufacture a measured zero.
                if result.receipt == nil {
                    result.receipt = FreebuffUsageReceipt(
                        id: "cloud:" + run.id, timestampMs: date.timeIntervalSince1970 * 1_000,
                        metricsJSON: "{}", model: run.model
                    )
                }
                result.receipt?.timestampMs = date.timeIntervalSince1970 * 1_000
                result.receipt?.model = run.model
                result.metricsVersion = metricsVersion
                let metrics = try JSONDecoder().decode(Metrics.self, from: Data(result.receipt!.metricsJSON.utf8))
                result.retryAfter = metrics.usage == nil || metrics.usageIncomplete == true
                    ? now.addingTimeInterval(incompleteReceiptRetryInterval) : nil
                return result
            }
            guard seen.insert(next).inserted else { throw FreebuffUsageError.invalidResponse }
            cursor = next
        }
        throw FreebuffUsageError.invalidResponse
    }

    private static func pages<Item: Decodable>(path: String, auth: FreebuffAuth, client: FreebuffUsageClient) async throws -> [Item] {
        var items: [Item] = []
        var cursor: String?
        var seen: Set<String> = []
        for _ in 0..<100 {
            let page: Page<Item> = try await page(path: path, cursor: cursor, auth: auth, client: client)
            items += page.items
            guard let next = page.nextCursor else { return items }
            guard seen.insert(next).inserted else { throw FreebuffUsageError.invalidResponse }
            cursor = next
        }
        throw FreebuffUsageError.invalidResponse
    }

    private static func page<Item: Decodable>(path: String, cursor: String?, auth: FreebuffAuth,
                                              client: FreebuffUsageClient) async throws -> Page<Item> {
        try Task.checkCancellation()
        let response = try await client.fetchHistory(path: path, cursor: cursor, auth: auth)
        if response.statusCode == 401 { throw FreebuffAuthError.tokenInvalid }
        guard (200..<300).contains(response.statusCode) else { throw FreebuffUsageError.requestFailed(response.statusCode) }
        return try JSONDecoder().decode(Page<Item>.self, from: response.body)
    }
}
