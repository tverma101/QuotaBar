import Foundation
import SwiftUI

/// The outcome of a reset-credit claim, as the resets popover renders it — the consume endpoint's four
/// `code` values collapsed to what the user needs to know (`reset` and `already_redeemed` are both
/// "claimed": the latter is the idempotency key doing its job on a retry), plus a transport/HTTP
/// `.failed`.
enum ResetClaimOutcome: Equatable, Sendable {
    case success
    case nothingToReset
    case noCredit
    case credentialAccess
    case cancelled
    case failed
}

/// Claims a Codex rate-limit reset credit — the app's only provider-API write, so it is deliberately
/// narrow: one credit per call, always by explicit credit id, guarded by the caller's idempotency key.
/// The protocol was reverse-engineered from the open-source Codex CLI and verified live once; see
/// docs/research/codex-reset-credit-claim.md.
///
/// The claim re-fetches the credit list at claim time and matches the target credit by its expiry
/// instant (the identity the popover timeline carries), rather than trusting a cached id: the list is a
/// safe GET, the id is guaranteed fresh, and a credit that raced away (claimed from the CLI or web in
/// the meantime) simply fails to match → `.noCredit`, exactly the truth. A successful claim awaits a
/// forced Codex refresh before returning, so by the time the popover shows its result banner the
/// Session/Weekly meters and the credit count already tell the post-reset story.
@MainActor
final class CodexResetClaimService {
    typealias Credentials = (accessToken: String, accountID: String?)

    private struct CredentialCandidateLoad {
        let candidates: [Credentials]
        let credentialAccessFailed: Bool
        let wasCancelled: Bool

        init(
            candidates: [Credentials],
            credentialAccessFailed: Bool,
            wasCancelled: Bool = false
        ) {
            self.candidates = candidates
            self.credentialAccessFailed = credentialAccessFailed
            self.wasCancelled = wasCancelled
        }
    }

    private enum ConsumeResult {
        case outcome(ResetClaimOutcome)
        case authenticationRejected
        case cancelled
    }

    private let usageClient: CodexUsageClient
    private let credentialCandidates: () async -> CredentialCandidateLoad
    private let keychainCandidates: () async -> CredentialCandidateLoad
    private let refreshAfterClaim: () async -> Void
    /// The credit id each idempotency key was matched to, kept for the key's retries: if a consume
    /// succeeded but its response was lost, the credit is gone from a re-fetched list — a fresh match
    /// would misread the retry as "no longer available" instead of replaying the POST and letting the
    /// server answer `already_redeemed`. Session-lived, keyed by the popover's per-credit UUIDs.
    private var matchedCreditIDs: [String: String] = [:]

    /// Test seam: injected credential candidates and refresh hook, the same `usageClient` the requests
    /// go through. Candidates are tried in order until one authenticates (see `claim`).
    init(
        usageClient: CodexUsageClient,
        credentialCandidates: @escaping () async -> [Credentials],
        refreshAfterClaim: @escaping () async -> Void = {}
    ) {
        self.usageClient = usageClient
        self.credentialCandidates = {
            CredentialCandidateLoad(
                candidates: await credentialCandidates(),
                credentialAccessFailed: false
            )
        }
        self.keychainCandidates = {
            CredentialCandidateLoad(candidates: [], credentialAccessFailed: false)
        }
        self.refreshAfterClaim = refreshAfterClaim
    }

    private init(
        usageClient: CodexUsageClient,
        credentialCandidateLoader: @escaping () async -> CredentialCandidateLoad,
        keychainCandidateLoader: @escaping () async -> CredentialCandidateLoad,
        refreshAfterClaim: @escaping () async -> Void
    ) {
        self.usageClient = usageClient
        self.credentialCandidates = credentialCandidateLoader
        self.keychainCandidates = keychainCandidateLoader
        self.refreshAfterClaim = refreshAfterClaim
    }

    /// Production wiring: shares the Codex provider's auth store and usage client, so credential
    /// selection can't drift from `refresh()`. File candidates are tried first; Keychain is read only
    /// when there is no usable file candidate or the API rejects every file candidate. No token refresh
    /// here: the claim runs seconds after a successful usage
    /// fetch (which rotates tokens back to disk), so a candidate that still fails auth is genuinely
    /// dead and the next one is the right move.
    convenience init(
        authStore: CodexAuthStore,
        usageClient: CodexUsageClient,
        allowsKeychainFallback: Bool = true,
        refreshAfterClaim: @escaping () async -> Void
    ) {
        self.init(
            usageClient: usageClient,
            credentialCandidateLoader: {
                var candidates: [CodexAuthState] = []
                var credentialAccessFailed = false
                do {
                    candidates = try await loadOffMainActor { [authStore] in
                        try authStore.loadAuthCandidates()
                    }
                    DiagnosticGate.clearFailure("auth.codex.reset-claim.files")
                } catch is CancellationError {
                    return CredentialCandidateLoad(
                        candidates: [], credentialAccessFailed: false, wasCancelled: true
                    )
                } catch {
                    credentialAccessFailed = true
                    DiagnosticGate.logOnce(for: "auth.codex.reset-claim.files") {
                        AppLog.error(
                            LogTag.auth("codex"),
                            "reset claim could not read auth files: \(error.localizedDescription)"
                        )
                    }
                }
                if Task.isCancelled {
                    return CredentialCandidateLoad(
                        candidates: [], credentialAccessFailed: false, wasCancelled: true
                    )
                }
                let usableCandidates: [Credentials] = candidates.compactMap { candidate in
                    guard candidate.hasUsableAccessToken, let token = candidate.auth.tokens?.accessToken else {
                        return nil
                    }
                    return (accessToken: token, accountID: candidate.auth.tokens?.accountID)
                }
                return CredentialCandidateLoad(
                    candidates: usableCandidates,
                    credentialAccessFailed: credentialAccessFailed
                )
            },
            keychainCandidateLoader: {
                guard allowsKeychainFallback else {
                    return CredentialCandidateLoad(candidates: [], credentialAccessFailed: false)
                }
                guard !Task.isCancelled else {
                    return CredentialCandidateLoad(
                        candidates: [], credentialAccessFailed: false, wasCancelled: true
                    )
                }
                do {
                    let candidate = try await loadOffMainActor({ [authStore] in
                        try authStore.loadKeychainAuth()
                    })
                    DiagnosticGate.clearFailure("auth.codex.reset-claim.keychain")
                    guard let candidate, candidate.hasUsableAccessToken,
                       let token = candidate.auth.tokens?.accessToken
                    else {
                        return CredentialCandidateLoad(candidates: [], credentialAccessFailed: false)
                    }
                    return CredentialCandidateLoad(
                        candidates: [(accessToken: token, accountID: candidate.auth.tokens?.accountID)],
                        credentialAccessFailed: false
                    )
                } catch is CancellationError {
                    return CredentialCandidateLoad(
                        candidates: [], credentialAccessFailed: false, wasCancelled: true
                    )
                } catch {
                    DiagnosticGate.logOnce(for: "auth.codex.reset-claim.keychain") {
                        AppLog.error(
                            LogTag.auth("codex"),
                            "reset claim could not read Keychain credentials: \(error.localizedDescription)"
                        )
                    }
                    return CredentialCandidateLoad(candidates: [], credentialAccessFailed: true)
                }
            },
            refreshAfterClaim: refreshAfterClaim
        )
    }

    /// Claims the credit expiring at `expiry`. Never throws — every failure mode is logged loudly and
    /// collapsed to an outcome the popover can render.
    func claim(creditExpiringAt expiry: Date, redeemRequestID: String) async -> ResetClaimOutcome {
        let credentialLoad = await credentialCandidates()
        guard !credentialLoad.wasCancelled, !Task.isCancelled else { return .cancelled }
        var candidates = credentialLoad.candidates
        var credentialAccessFailed = credentialLoad.credentialAccessFailed
        var keychainLoadAttempted = false
        var loadedKeychainCandidates: [Credentials] = []
        if candidates.isEmpty {
            keychainLoadAttempted = true
            let keychainLoad = await keychainCandidates()
            guard !keychainLoad.wasCancelled, !Task.isCancelled else { return .cancelled }
            credentialAccessFailed = credentialAccessFailed || keychainLoad.credentialAccessFailed
            loadedKeychainCandidates = keychainLoad.candidates
            candidates.append(contentsOf: loadedKeychainCandidates)
        }
        guard !candidates.isEmpty else {
            if credentialAccessFailed {
                DiagnosticGate.logOnce(for: "auth.codex.reset-claim.no-credential-access") {
                    AppLog.error(
                        LogTag.plugin("codex"),
                        "reset claim: no usable Codex credentials because credential access failed"
                    )
                }
                return .credentialAccess
            }
            DiagnosticGate.logOnce(for: "auth.codex.reset-claim.no-usable-credentials") {
                AppLog.error(LogTag.plugin("codex"), "reset claim: no usable Codex credentials")
            }
            return .failed
        }
        DiagnosticGate.clearFailure("auth.codex.reset-claim.no-credential-access")
        DiagnosticGate.clearFailure("auth.codex.reset-claim.no-usable-credentials")

        // A retry of an idempotency key that already matched replays the exact same (key, credit) pair
        // instead of re-matching: after a consume whose response was lost, the credit is no longer in
        // the list, and only the replay lets the server's `already_redeemed` prove the claim landed.
        let creditID: String
        var preferredCandidates = candidates
        if let replayID = matchedCreditIDs[redeemRequestID] {
            creditID = replayID
        } else {
            let initialMatchCandidates = credentialLoad.candidates.isEmpty
                ? loadedKeychainCandidates
                : credentialLoad.candidates
            var match = await matchCredit(expiringAt: expiry, candidates: initialMatchCandidates)
            if case .authenticationRejected = match, !keychainLoadAttempted {
                keychainLoadAttempted = true
                let keychainLoad = await keychainCandidates()
                guard !keychainLoad.wasCancelled, !Task.isCancelled else { return .cancelled }
                credentialAccessFailed = credentialAccessFailed || keychainLoad.credentialAccessFailed
                loadedKeychainCandidates = keychainLoad.candidates
                if !loadedKeychainCandidates.isEmpty {
                    for fallback in loadedKeychainCandidates where !candidates.contains(where: {
                        $0.accessToken == fallback.accessToken && $0.accountID == fallback.accountID
                    }) {
                        candidates.append(fallback)
                    }
                    match = await matchCredit(expiringAt: expiry, candidates: loadedKeychainCandidates)
                } else if credentialAccessFailed {
                    return .credentialAccess
                }
            }
            switch match {
            case .matched(let id, let authenticated):
                creditID = id
                matchedCreditIDs[redeemRequestID] = id
                // Lead with the credential that just authenticated the list fetch. Deduplicate by the
                // full (token, account) pair — ChatGPT-Account-Id changes what a token is authorized
                // for, so a same-token candidate with a different account is a distinct fallback.
                preferredCandidates = [authenticated] + candidates.filter {
                    $0.accessToken != authenticated.accessToken || $0.accountID != authenticated.accountID
                }
            case .noCredit:
                // Not an error: the credit was claimed elsewhere (CLI/web) or expired since the popover
                // rendered. The refresh reconciles the timeline with reality.
                AppLog.warn(LogTag.plugin("codex"), "reset claim: no available credit matches the picked expiry")
                await refreshAfterClaim()
                return .noCredit
            case .failed:
                return .failed
            case .authenticationRejected:
                return credentialAccessFailed ? .credentialAccess : .failed
            case .cancelled:
                return .cancelled
            }
        }

        // A late list response must never authorize a new consume POST after the user canceled.
        guard !Task.isCancelled else { return .cancelled }
        let consumeResult = await consume(
            creditID: creditID, redeemRequestID: redeemRequestID, candidates: preferredCandidates
        )
        var outcome: ResetClaimOutcome
        switch consumeResult {
        case .outcome(let value):
            outcome = value
        case .cancelled:
            return .cancelled
        case .authenticationRejected where !keychainLoadAttempted:
            keychainLoadAttempted = true
            let keychainLoad = await keychainCandidates()
            guard !keychainLoad.wasCancelled, !Task.isCancelled else { return .cancelled }
            if keychainLoad.candidates.isEmpty {
                outcome = keychainLoad.credentialAccessFailed ? .credentialAccess : .failed
            } else {
                switch await consume(
                    creditID: creditID,
                    redeemRequestID: redeemRequestID,
                    candidates: keychainLoad.candidates
                ) {
                case .outcome(let value): outcome = value
                case .authenticationRejected: outcome = .failed
                case .cancelled: return .cancelled
                }
            }
        case .authenticationRejected:
            outcome = .failed
        }
        guard outcome != .cancelled else { return .cancelled }
        if outcome != .failed {
            // The world changed (or turned out different from the snapshot): refresh before returning,
            // so the result banner appears over already-reconciled meters and credit count.
            await refreshAfterClaim()
        }
        return outcome
    }

    /// POSTs the consume, falling back across credential candidates on an auth rejection (401/403).
    /// Safe to repeat: every attempt carries the same idempotency key, so at most one credit is ever
    /// spent no matter how many candidates are tried.
    private func consume(
        creditID: String, redeemRequestID: String, candidates: [Credentials]
    ) async -> ConsumeResult {
        var lastRejection: Int?
        for credentials in candidates {
            guard !Task.isCancelled else { return .cancelled }
            let response: HTTPResponse
            do {
                response = try await usageClient.consumeResetCredit(
                    accessToken: credentials.accessToken,
                    accountID: credentials.accountID,
                    creditID: creditID,
                    redeemRequestID: redeemRequestID
                )
            } catch {
                if ProviderCancellation.isCancellation(error) { return .cancelled }
                AppLog.error(LogTag.plugin("codex"), "reset claim: consume request failed: \(error.localizedDescription)")
                return .outcome(.failed)
            }
            guard !Task.isCancelled else { return .cancelled }
            if response.statusCode == 401 || response.statusCode == 403 {
                lastRejection = response.statusCode
                continue
            }
            let outcome = Self.outcome(fromConsume: response)
            if outcome == .failed {
                AppLog.error(
                    LogTag.plugin("codex"),
                    "reset claim: consume failed (\(response.statusCode)): "
                        + LogRedaction.bodyPreview(String(decoding: response.body, as: UTF8.self), limit: 300)
                )
            }
            return .outcome(outcome)
        }
        AppLog.error(LogTag.plugin("codex"), "reset claim: consume rejected for every credential (last: \(lastRejection.map(String.init) ?? "none"))")
        return .authenticationRejected
    }

    private enum MatchResult {
        case matched(creditID: String, credentials: Credentials)
        case noCredit
        case cancelled
        case failed
        case authenticationRejected
    }

    /// Fresh credit list (safe GET) → the id of the credit the user picked, matched by expiry. Tries
    /// each credential candidate in order, moving on when one is rejected as unauthenticated (401/403)
    /// — the same fallback the provider's probe applies — so a stale first auth file can't strand the
    /// claim while the dashboard works off a later one.
    private func matchCredit(expiringAt expiry: Date, candidates: [Credentials]) async -> MatchResult {
        var lastFailure = "no credential candidate authenticated"
        for credentials in candidates {
            guard !Task.isCancelled else { return .cancelled }
            let list: HTTPResponse
            do {
                list = try await usageClient.fetchResetCredits(
                    accessToken: credentials.accessToken, accountID: credentials.accountID
                )
            } catch {
                if ProviderCancellation.isCancellation(error) { return .cancelled }
                AppLog.error(LogTag.plugin("codex"), "reset claim: credit list fetch failed: \(error.localizedDescription)")
                return .failed
            }
            // URLSession fakes and real transports may deliver a successful response after the task
            // was canceled. Do not turn that late GET into a consume POST.
            guard !Task.isCancelled else { return .cancelled }
            if list.statusCode == 401 || list.statusCode == 403 {
                lastFailure = "credit list fetch rejected (\(list.statusCode))"
                continue
            }
            guard (200..<300).contains(list.statusCode), let body = ProviderParse.jsonObject(list.body) else {
                AppLog.error(LogTag.plugin("codex"), "reset claim: credit list fetch failed (\(list.statusCode))")
                return .failed
            }
            guard let matched = Self.creditID(in: body, expiringAt: expiry) else { return .noCredit }
            return .matched(creditID: matched, credentials: credentials)
        }
        AppLog.error(LogTag.plugin("codex"), "reset claim: \(lastFailure)")
        return .authenticationRejected
    }

    /// The id of the still-available credit whose `expires_at` matches `expiry` (±1s — the popover's
    /// dates round-trip through the same ISO-8601 parsing as this list, so a real match is exact; the
    /// tolerance only absorbs sub-second truncation). Mirrors the mapper's status filter: a credit with
    /// no `status` counts as available, only an explicit non-"available" state is skipped.
    static func creditID(in body: [String: Any], expiringAt expiry: Date) -> String? {
        guard let credits = body["credits"] as? [[String: Any]] else { return nil }
        return credits.first { credit in
            if let status = credit["status"] as? String, status != "available" { return false }
            guard let date = parseExpiry(credit["expires_at"]) else { return false }
            return abs(date.timeIntervalSince(expiry)) < 1
        }?["id"] as? String
    }

    /// Collapses a consume response to the popover's outcome. All four protocol codes arrive as HTTP
    /// 200 — the outcome is in the body — so a non-2xx or an unrecognized code is `.failed`.
    static func outcome(fromConsume response: HTTPResponse) -> ResetClaimOutcome {
        guard (200..<300).contains(response.statusCode),
              let body = ProviderParse.jsonObject(response.body),
              let code = body["code"] as? String
        else {
            return .failed
        }
        switch code {
        case "reset", "already_redeemed":
            return .success
        case "nothing_to_reset":
            return .nothingToReset
        case "no_credit":
            return .noCredit
        default:
            return .failed
        }
    }

    private static func parseExpiry(_ value: Any?) -> Date? {
        if let string = value as? String, let date = OpenUsageISO8601.date(from: string) {
            return date
        }
        if let seconds = ProviderParse.number(value) {
            return Date(timeIntervalSince1970: seconds)
        }
        return nil
    }
}

/// Hands the claim service to the resets popover through the environment: `nil` (the default — previews,
/// share-card renders, reorder previews) renders the timeline read-only with no "Use" affordance.
private struct CodexResetClaimServiceKey: EnvironmentKey {
    static let defaultValue: CodexResetClaimService? = nil
}

extension EnvironmentValues {
    var codexResetClaim: CodexResetClaimService? {
        get { self[CodexResetClaimServiceKey.self] }
        set { self[CodexResetClaimServiceKey.self] = newValue }
    }
}
