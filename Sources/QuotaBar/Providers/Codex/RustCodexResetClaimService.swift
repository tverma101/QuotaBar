import Foundation

/// Production Codex reset-credit runtime. Credential selection, keychain fallback, the credit-list
/// GET, the idempotent consume POST, matching, and response parsing all live in the Rust engine
/// (`Rust/quotabar-engine/src/providers/codex/reset_claim.rs`). This type keeps only the
/// user-visible orchestration: when a successful/no-credit claim should reconcile the dashboard,
/// and the outcome the popover renders.
///
/// `CodexResetClaimReferenceService` remains the Swift test oracle.
@MainActor
final class CodexResetClaimService {
    private let providerID: String
    private let config: EngineProviderConfig
    /// The launch-time verified account for this card. Automatic retries bind the persisted
    /// idempotency request to this identity, so a stale credit id can never spend another account.
    private let verifiedAccountIdentity: String?
    private let refreshAfterClaim: () async -> Void
    private let now: () -> Date

    init(
        providerID: String,
        engineConfig: [String: Any],
        verifiedAccountIdentity: String? = nil,
        refreshAfterClaim: @escaping () async -> Void,
        now: @escaping () -> Date = Date.init
    ) {
        self.providerID = providerID
        self.config = EngineProviderConfig(engineConfig)
        self.verifiedAccountIdentity = verifiedAccountIdentity
        self.refreshAfterClaim = refreshAfterClaim
        self.now = now
    }

    /// Reads the live account's available reset credits. A rejected credential set is refreshed
    /// once through the normal provider path and retried, matching the old Swift behavior.
    func availableCredits() async -> [CodexResetCredit]? {
        guard let first = await fetchCredits() else { return nil }
        if !first.authRejected {
            return credits(from: first)
        }
        await refreshAfterClaim()
        guard !Task.isCancelled else { return nil }
        guard let second = await fetchCredits(), !second.authRejected else { return nil }
        return credits(from: second)
    }

    /// Claims the credit expiring at `expiry`. Every failure is collapsed to the popover outcome;
    /// the engine has already logged the underlying credentials/HTTP detail.
    func claim(creditExpiringAt expiry: Date, redeemRequestID: String) async -> ResetClaimOutcome {
        guard let reply = await RustEngine.codexResetClaim(
            providerID: providerID,
            config: config,
            expiry: expiry,
            redeemRequestID: redeemRequestID,
            isManual: true
        ) else {
            return Task.isCancelled ? .cancelled : .failed
        }
        return await finish(reply)
    }

    /// Revalidates the server credit and user consent, then claims it. The engine re-checks the
    /// expiry/lead window; `canRedeem` is checked before the call and before the post-claim refresh.
    func claimAuto(
        credit: CodexResetCredit,
        redeemRequestID: String,
        canRedeem: @escaping @MainActor () -> Bool
    ) async -> ResetClaimOutcome {
        guard canRedeem() else { return .cancelled }
        guard now() < credit.expiresAt else { return .noCredit }
        guard now() >= credit.expiresAt.addingTimeInterval(-CodexAutoResetCoordinator.leadTime) else {
            return .cancelled
        }
        guard let reply = await RustEngine.codexResetClaim(
            providerID: providerID,
            config: config,
            expiry: credit.expiresAt,
            redeemRequestID: redeemRequestID,
            creditID: credit.id,
            ownerIdentity: verifiedAccountIdentity,
            isRetry: credit.isRetry,
            automatic: true,
            isManual: false
        ) else {
            return Task.isCancelled ? .cancelled : .failed
        }
        return await finish(reply, canRedeem: canRedeem)
    }

    private func fetchCredits() async -> RustEngine.CodexResetCreditsReply? {
        await RustEngine.codexResetCredits(providerID: providerID, config: config)
    }

    private func credits(from reply: RustEngine.CodexResetCreditsReply) -> [CodexResetCredit] {
        reply.credits.map { CodexResetCredit(id: $0.id, expiresAt: $0.expiresAt) }
    }

    private func finish(
        _ reply: RustEngine.CodexResetClaimReply,
        canRedeem: (@MainActor () -> Bool)? = nil
    ) async -> ResetClaimOutcome {
        let outcome: ResetClaimOutcome
        switch reply.outcome {
        case "success": outcome = .success
        case "nothingToReset": outcome = .nothingToReset
        case "noCredit": outcome = .noCredit
        case "credentialAccess": outcome = .credentialAccess
        case "cancelled": outcome = .cancelled
        default: outcome = .failed
        }
        guard outcome != .failed, outcome != .cancelled else { return outcome }
        if canRedeem?() == false { return .cancelled }
        await refreshAfterClaim()
        return outcome
    }
}
