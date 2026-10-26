import Foundation

extension CursorUsageMapper {
    /// Membership values that identify an org-billed Cursor seat.
    static let orgMembershipTypes: Set<String> = ["enterprise", "team"]

    /// Plan name for request/Enterprise fallback routing. Org membership may promote the route,
    /// but personal memberships must not fill an empty GetPlanInfo result and disable the
    /// unknown-plan REST fallback.
    static func routingPlanName(planInfoName: String?, membershipType: String?) -> String? {
        let membership = normalizedMembership(membershipType)
        if let membership, orgMembershipTypes.contains(membership) {
            return membership
        }
        return planInfoName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    /// Badge / display plan. Prefer org billing membership over GetPlanInfo when it still says Pro.
    static func resolvedPlanName(planInfoName: String?, membershipType: String?) -> String? {
        let membership = normalizedMembership(membershipType)
        let planInfo = planInfoName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        if let membership, orgMembershipTypes.contains(membership),
           planInfo == nil || ["pro", "pro plan"].contains(planInfo?.lowercased() ?? "") {
            return membership
        }
        return planInfo ?? membership
    }

    static func resolvedPlanLabel(planInfoName: String?, membershipType: String?) -> String? {
        planLabel(resolvedPlanName(planInfoName: planInfoName, membershipType: membershipType))
    }

    /// Prefer local org membership when present; otherwise take a live org membership from
    /// usage-summary over a stale local personal membership.
    static func preferredMembership(local: String?, summary: String?) -> String? {
        let localMembership = normalizedMembership(local)
        let summaryMembership = normalizedMembership(summary)
        if let localMembership, orgMembershipTypes.contains(localMembership) {
            return localMembership
        }
        if let summaryMembership, orgMembershipTypes.contains(summaryMembership) {
            return summaryMembership
        }
        return localMembership ?? summaryMembership
    }

    private static func normalizedMembership(_ value: String?) -> String? {
        value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .nilIfEmpty
    }

}
