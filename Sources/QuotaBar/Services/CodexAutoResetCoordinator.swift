import Foundation
import Observation

/// One server-identified Codex rate-limit reset credit. Never identify a credit by expiry alone:
/// several credits can share an expiry, so the identifier is the only safe redemption target.
struct CodexResetCredit: Hashable, Sendable {
    let id: String
    let expiresAt: Date
    /// True only for the same credit/request after an earlier consume may have been sent.
    /// A replay can confirm `already_redeemed` even when the credit vanished from the list.
    var isRetry: Bool = false
}

/// Account-isolated scheduler for *opt-in* redemption of expiring Codex reset credits.
/// Each account gets its own worker and its own idempotency records; it never spends an
/// unexpired credit early, nor attempts to redeem after its expiry.
@MainActor
@Observable
final class CodexAutoResetCoordinator {
    static let enabledKey = "codexAutoRedeemExpiringResets"
    static let leadTime: TimeInterval = 60
    private static let patrolInterval: TimeInterval = 300
    private static let retryInterval: TimeInterval = 15
    private static let maximumAttempts = 3
    private static let storageKey = "codexAutoRedeemAttempts.v3"

    struct Account {
        var availableCredits: @MainActor () async -> [CodexResetCredit]?
        var claim: @MainActor (CodexResetCredit, String, @escaping @MainActor () -> Bool) async -> ResetClaimOutcome
    }

    private enum Result: String, Codable {
        case pending, success, noCredit, nothingToReset, exhausted
        var isTerminal: Bool { self != .pending }
    }

    private struct Attempt: Codable {
        var requestID: String
        var attempts: Int
        var lastAttemptAt: Date?
        var result: Result
        var expiry: Date
        var creditID: String
        var accountID: String
    }

    private let accounts: [String: Account]
    /// The number of verified Codex accounts eligible for this global opt-in.
    var monitoredAccountCount: Int { accounts.count }
    private let defaults: UserDefaults
    private let now: () -> Date
    /// User-facing status for accounts that could not check/redeem an expiring credit.
    private(set) var lastErrorByAccount: [String: String] = [:]
    @ObservationIgnored private var attempts: [String: Attempt]
    @ObservationIgnored private var lastKnownCredits: [String: [CodexResetCredit]] = [:]
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private var workers: [String: Task<Void, Never>] = [:]

    init(accounts: [String: Account], defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.accounts = accounts
        self.defaults = defaults
        self.now = now
        if let saved = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([String: Attempt].self, from: saved) {
            attempts = decoded
        } else {
            attempts = [:]
        }
        let cutoff = now().addingTimeInterval(-86_400)
        attempts = attempts.filter { $0.value.expiry >= cutoff }
    }

    convenience init(services: [String: CodexResetClaimService], defaults: UserDefaults = .standard) {
        self.init(accounts: services.mapValues { service in
            Account(
                availableCredits: { await service.availableCredits() },
                claim: { credit, requestID, isEnabled in
                    await service.claimAuto(credit: credit, redeemRequestID: requestID, canRedeem: isEnabled)
                }
            )
        }, defaults: defaults)
    }

    func start() {
        guard workers.isEmpty else { return }
        for accountID in accounts.keys {
            workers[accountID] = Task { [weak self] in
                while !Task.isCancelled {
                    let delay: TimeInterval
                    do {
                        guard let owner = self else { return }
                        delay = await owner.runOnce(for: accountID)
                    }
                    if Task.isCancelled { return }
                    do { try await Task.sleep(for: .seconds(max(1, delay))) }
                    catch { return }
                }
            }
        }
    }

    func stop() {
        workers.values.forEach { $0.cancel() }
        workers.removeAll()
    }

    /// The Settings toggle calls this so enabling auto-reset starts an immediate live check,
    /// rather than waiting out the previous account's five-minute idle sleep.
    func restart() {
        stop()
        start()
    }

    deinit { workers.values.forEach { $0.cancel() } }

    /// Performs exactly one account's live GET and (when due) at most one targeted POST.
    /// Returns a bounded next-check delay so large account counts do not cause a poll storm.
    @discardableResult
    func runOnce(for accountID: String) async -> TimeInterval {
        // Settings changes wake workers through `restart()`. When off, don't wake every
        // five seconds forever (and don't touch the network).
        guard defaults.bool(forKey: Self.enabledKey) else { return 3_600 }
        guard let account = accounts[accountID] else { return Self.patrolInterval }
        guard let credits = await account.availableCredits() else {
            let close = lastKnownCredits[accountID]?.contains {
                $0.expiresAt > now() && $0.expiresAt.timeIntervalSince(now()) <= 300
            } ?? false
            lastErrorByAccount[accountID] = "Could not check reset credits"
            AppLog.warn(LogTag.plugin("codex"), "auto reset: credit lookup unavailable for \(accountID)")
            return close ? 10 : Self.patrolInterval
        }
        lastKnownCredits[accountID] = credits
        // Clear stale lookup failures after a successful read. Redemption failures stay
        // visible until a successful claim or explicit user intervention.
        if lastErrorByAccount[accountID] == "Could not check reset credits" {
            lastErrorByAccount[accountID] = nil
        }
        guard !Task.isCancelled, defaults.bool(forKey: Self.enabledKey) else { return 5 }

        let current = now()
        // In the lost-response case the server may already have removed the credit from GET.
        // Keep the original UUID + exact credit ID eligible for a bounded idempotent replay.
        let outstanding = attempts.values.compactMap { record -> CodexResetCredit? in
            guard record.accountID == accountID, record.result == .pending,
                  record.attempts > 0, record.expiry > current else { return nil }
            return CodexResetCredit(id: record.creditID, expiresAt: record.expiry, isRetry: true)
        }
        // Live listed credits take precedence when the same credit is still present.
        let liveIDs = Set(credits.map(\.id))
        let candidates = credits + outstanding.filter { !liveIDs.contains($0.id) }
        // Choose the earliest *actionable* credit, not just the earliest expiry. If one credit
        // failed and is cooling down for 15 s, a different due-now credit must not starve.
        let eligible = candidates.filter { candidate in
            Self.secondsUntilTrigger(expiresAt: candidate.expiresAt, now: current) != nil
                && attempts[Self.key(accountID: accountID, creditID: candidate.id)]?.result.isTerminal != true
        }
        func readyAt(_ credit: CodexResetCredit) -> Date {
            let trigger = credit.expiresAt.addingTimeInterval(-Self.leadTime)
            guard let prior = attempts[Self.key(accountID: accountID, creditID: credit.id)]?.lastAttemptAt else {
                return trigger
            }
            return max(trigger, prior.addingTimeInterval(Self.retryInterval))
        }
        guard let credit = eligible.min(by: {
            let a = readyAt($0), b = readyAt($1)
            return a == b ? $0.id < $1.id : a < b
        }) else { return Self.patrolInterval }
        let delay = readyAt(credit).timeIntervalSince(now())
        if delay > 0 { return min(Self.patrolInterval, delay) }

        let key = Self.key(accountID: accountID, creditID: credit.id)
        // Actor reentrancy: another caller can arrive while the first POST is suspended.
        // Claim ownership before the first await and release it on every return path.
        guard inFlight.insert(key).inserted else { return 1 }
        defer { inFlight.remove(key) }
        var record = attempts[key] ?? Attempt(
            requestID: UUID().uuidString, attempts: 0, lastAttemptAt: nil,
            result: .pending, expiry: credit.expiresAt,
            creditID: credit.id, accountID: accountID
        )
        guard !record.result.isTerminal else { return Self.patrolInterval }
        if let lastAttempt = record.lastAttemptAt {
            let wait = Self.retryInterval - now().timeIntervalSince(lastAttempt)
            if wait > 0 { return min(max(1, wait), max(1, credit.expiresAt.timeIntervalSince(now()))) }
        }
        if record.attempts >= Self.maximumAttempts {
            record.result = .exhausted
            attempts[key] = record
            _ = persist()
            lastErrorByAccount[accountID] = "Reset redemption retries exhausted"
            AppLog.error(LogTag.plugin("codex"), "auto reset: claim retries exhausted for \(accountID)")
            return 1
        }
        guard !Task.isCancelled, defaults.bool(forKey: Self.enabledKey), now() < credit.expiresAt else {
            return 5
        }

        // Record the exact (account, credit, request UUID) *before* issuing the irreversible POST.
        record.attempts += 1
        record.lastAttemptAt = now()
        attempts[key] = record
        guard persist() else {
            lastErrorByAccount[accountID] = "Could not save reset request state"
            AppLog.error(LogTag.plugin("codex"), "auto reset: state persistence failed; refusing POST")
            return 10
        }
        // First attempt performs a fresh GET and matches the explicit ID before POST.
        // Later retries preserve the same UUID and may replay without a matching credit in
        // the list; the backend's idempotency ledger is authoritative for lost responses.
        let claimedCredit = CodexResetCredit(
            id: credit.id, expiresAt: credit.expiresAt, isRetry: record.attempts > 1
        )
        let outcome = await account.claim(claimedCredit, record.requestID) { [defaults] in
            defaults.bool(forKey: Self.enabledKey) && !Task.isCancelled
        }
        switch outcome {
        case .success:
            record.result = .success
            lastErrorByAccount[accountID] = nil
        case .noCredit:
            record.result = .noCredit
            lastErrorByAccount[accountID] = nil
        case .nothingToReset:
            record.result = .nothingToReset
            lastErrorByAccount[accountID] = nil
        case .failed:
            if record.attempts >= Self.maximumAttempts { record.result = .exhausted }
            lastErrorByAccount[accountID] = "Could not redeem expiring reset"
            AppLog.error(LogTag.plugin("codex"), "auto reset: claim failed for \(accountID)")
        }
        attempts[key] = record
        _ = persist()
        return record.result == .pending ? Self.retryInterval : 1
    }

    /// Positive means wait; zero means the target time has arrived; nil means already expired.
    static func secondsUntilTrigger(expiresAt: Date, now: Date) -> TimeInterval? {
        let remaining = expiresAt.timeIntervalSince(now)
        guard remaining > 0 else { return nil }
        return max(0, remaining - leadTime)
    }

    private static func key(accountID: String, creditID: String) -> String {
        // Length-delimited keys avoid aliasing ("a|bc", "a|b|c") across accounts/credits.
        "\(accountID.utf8.count):\(accountID)\(creditID)"
    }

    @discardableResult
    private func persist() -> Bool {
        do {
            let data = try JSONEncoder().encode(attempts)
            defaults.set(data, forKey: Self.storageKey)
            // This is an irreversible provider API write, not a preference update. Refuse
            // the POST unless the idempotency key could be flushed to persistent defaults.
            return defaults.synchronize() && defaults.data(forKey: Self.storageKey) == data
        } catch {
            AppLog.error(LogTag.plugin("codex"), "auto reset: could not serialize redemption state")
            return false
        }
    }
}
