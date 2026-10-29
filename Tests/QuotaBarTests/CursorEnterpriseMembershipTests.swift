import XCTest
@testable import QuotaBar

/// Enterprise / team seat handling: identity-safe membership sourcing, the Enterprise badge, and
/// Extra Usage merged from the usage summary without discarding the live pool meters.
final class CursorEnterpriseMembershipTests: XCTestCase {
    // MARK: - Identity-safe membership sourcing

    func testSQLiteEnterpriseMembershipIsCarriedOnTheAuthState() throws {
        let token = makeCursorJWT(sub: "google-oauth2|enterprise-user")
        let store = CursorAuthStore(
            sqlite: KeyValueSQLite(values: [
                CursorAuthStore.accessTokenKey: token,
                CursorAuthStore.membershipTypeKey: "Enterprise"
            ]),
            keychain: FakeKeychain()
        )

        let state = try store.loadAuthState()

        XCTAssertEqual(state?.source, .sqlite)
        XCTAssertEqual(state?.membershipType, "enterprise")
    }

    func testKeychainOnlySessionCarriesNoMembership() throws {
        let token = makeCursorJWT(sub: "auth0|keychain-user")
        let store = CursorAuthStore(
            sqlite: KeyValueSQLite(),
            keychain: ServiceKeychain(values: [
                CursorAuthStore.keychainAccessTokenService: token,
                CursorAuthStore.keychainRefreshTokenService: "keychain-refresh"
            ])
        )

        let state = try store.loadAuthState()

        XCTAssertEqual(state?.source, .keychain)
        XCTAssertNil(state?.membershipType)
    }

    func testFreeSQLiteMembershipIsNotCarriedOntoADifferentKeychainSubject() throws {
        let sqliteToken = makeCursorJWT(sub: "google-oauth2|sqlite-user")
        let keychainToken = makeCursorJWT(sub: "auth0|keychain-user")
        let store = CursorAuthStore(
            sqlite: KeyValueSQLite(values: [
                CursorAuthStore.accessTokenKey: sqliteToken,
                CursorAuthStore.refreshTokenKey: "sqlite-refresh",
                CursorAuthStore.membershipTypeKey: "free"
            ]),
            keychain: ServiceKeychain(values: [
                CursorAuthStore.keychainAccessTokenService: keychainToken,
                CursorAuthStore.keychainRefreshTokenService: "keychain-refresh"
            ])
        )

        let state = try store.loadAuthState()

        XCTAssertEqual(state?.source, .keychain)
        XCTAssertNil(state?.membershipType)
    }

    // MARK: - Plan resolution

    func testOrgMembershipOverridesAProPlanBadge() {
        XCTAssertEqual(
            CursorUsageMapper.resolvedPlanLabel(planInfoName: "Pro", membershipType: "enterprise"),
            "Enterprise"
        )
        XCTAssertEqual(
            CursorUsageMapper.resolvedPlanLabel(planInfoName: "pro plan", membershipType: "team"),
            "Team"
        )
        XCTAssertEqual(
            CursorUsageMapper.resolvedPlanLabel(planInfoName: "Ultra", membershipType: "team"),
            "Ultra"
        )
        XCTAssertEqual(
            CursorUsageMapper.resolvedPlanLabel(planInfoName: nil, membershipType: "enterprise"),
            "Enterprise"
        )
        XCTAssertEqual(
            CursorUsageMapper.resolvedPlanLabel(planInfoName: "Pro", membershipType: "pro"),
            "Pro"
        )
    }

    func testPersonalMembershipNeverFillsTheFallbackRoutingPlan() {
        XCTAssertNil(CursorUsageMapper.routingPlanName(planInfoName: nil, membershipType: "pro"))
        XCTAssertNil(CursorUsageMapper.routingPlanName(planInfoName: nil, membershipType: "free"))
        XCTAssertNil(CursorUsageMapper.routingPlanName(planInfoName: "  ", membershipType: "pro"))
        XCTAssertEqual(
            CursorUsageMapper.routingPlanName(planInfoName: nil, membershipType: "enterprise"),
            "enterprise"
        )
        XCTAssertEqual(
            CursorUsageMapper.routingPlanName(planInfoName: "Pro", membershipType: "pro"),
            "Pro"
        )
    }

    func testLiveOrgMembershipWinsOverAStalePersonalLocalMembership() {
        XCTAssertEqual(CursorUsageMapper.preferredMembership(local: "pro", summary: "enterprise"), "enterprise")
        XCTAssertEqual(CursorUsageMapper.preferredMembership(local: "enterprise", summary: "team"), "enterprise")
        XCTAssertEqual(CursorUsageMapper.preferredMembership(local: "pro", summary: "pro"), "pro")
        XCTAssertNil(CursorUsageMapper.preferredMembership(local: nil, summary: nil))
    }

    // MARK: - Percent-only org totals

    func testPercentOnlyTeamPayloadStaysOnThePrimaryPath() throws {
        let usage: [String: Any] = ["enabled": true, "planUsage": ["totalPercentUsed": 20]]

        XCTAssertFalse(CursorUsageMapper.shouldUseRequestBasedFallback(
            usage: usage, planName: "Team", planInfoUnavailable: false
        ).shouldFallback)

        let mapped = try CursorUsageMapper.mapUsage(
            usage: usage, planName: "Team", creditGrants: nil, stripeBalanceCents: 0
        )
        let total = try XCTUnwrap(progress(mapped.lines, "Total usage"))
        XCTAssertEqual(total.used, 20)
        XCTAssertEqual(total.limit, 100)
        XCTAssertEqual(total.format, .percent)
    }

    func testPercentOnlyEnterprisePayloadStaysOnThePrimaryPath() throws {
        let usage: [String: Any] = ["enabled": true, "planUsage": ["totalPercentUsed": 26.5]]

        XCTAssertFalse(CursorUsageMapper.shouldUseRequestBasedFallback(
            usage: usage, planName: "Enterprise", planInfoUnavailable: false
        ).shouldFallback)

        let mapped = try CursorUsageMapper.mapUsage(
            usage: usage, planName: "Enterprise", creditGrants: nil, stripeBalanceCents: 0
        )
        let total = try XCTUnwrap(progress(mapped.lines, "Total usage"))
        XCTAssertEqual(total.used, 26.5)
        XCTAssertEqual(total.limit, 100)
        XCTAssertEqual(total.format, .percent)
    }

    func testPercentOnlyTeamShapedPayloadKeepsPrimaryModelMeters() throws {
        let usage: [String: Any] = [
            "enabled": true,
            "planUsage": ["totalPercentUsed": 26.5, "autoPercentUsed": 10, "apiPercentUsed": 30],
            "spendLimitUsage": ["limitType": "team"]
        ]
        for plan in ["Team", "Enterprise", "Pro", ""] {
            XCTAssertFalse(CursorUsageMapper.shouldUseRequestBasedFallback(
                usage: usage, planName: plan, planInfoUnavailable: true
            ).shouldFallback)
            let mapped = try CursorUsageMapper.mapUsage(usage: usage, planName: plan, creditGrants: nil, stripeBalanceCents: 0)
            XCTAssertEqual(progress(mapped.lines, "Total usage")?.used, 26.5)
            XCTAssertEqual(progress(mapped.lines, "Cursor Models")?.used, 10)
            XCTAssertEqual(progress(mapped.lines, "Other Models")?.used, 30)
        }
    }

    // MARK: - Extra Usage merge

    func testAppendMissingOnDemandKeepsTheExistingRow() throws {
        var lines: [MetricLine] = [
            .progress(label: "On-demand", used: 1, limit: 10, format: .dollars)
        ]

        CursorUsageSummaryMapper.appendMissingOnDemand(
            from: [
                "individualUsage": [
                    "onDemand": ["enabled": true, "used": 25_000, "limit": 100_000]
                ]
            ],
            to: &lines
        )

        XCTAssertEqual(lines.filter { $0.label == "On-demand" }.count, 1)
        let kept = try XCTUnwrap(progress(lines, "On-demand"))
        XCTAssertEqual(kept.used, 1)
        XCTAssertEqual(kept.limit, 10)
    }

    func testAppendMissingOnDemandAddsTheMissingRow() throws {
        var lines: [MetricLine] = []

        CursorUsageSummaryMapper.appendMissingOnDemand(
            from: [
                "individualUsage": [
                    "onDemand": ["enabled": true, "used": 0, "limit": 25_000, "remaining": 25_000]
                ]
            ],
            to: &lines
        )

        let added = try XCTUnwrap(progress(lines, "On-demand"))
        XCTAssertEqual(added.used, 0)
        XCTAssertEqual(added.limit, 250)
    }

    // MARK: - Provider

    @MainActor
    func testPrimaryPoolPathKeepsLiveMetersAndAddsExtraUsageFromTheSummary() async throws {
        let accessToken = makeCursorJWT(sub: "google-oauth2|enterprise-user")
        let http = RoutingHTTPClient { request in
            switch request.url {
            case CursorUsageClient.usageURL:
                return HTTPResponse(statusCode: 200, headers: [:], body: Data("""
                {
                  "enabled": true,
                  "billingCycleStart": 1770000000000,
                  "billingCycleEnd": 1772592000000,
                  "planUsage": {
                    "limit": 2000,
                    "totalSpend": 1500,
                    "autoPercentUsed": 75,
                    "apiPercentUsed": 100,
                    "totalPercentUsed": 76
                  },
                  "spendLimitUsage": { "limitType": "team", "pooledLimit": 0 }
                }
                """.utf8))
            case CursorUsageClient.planURL:
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"planInfo":{"planName":"Pro"}}"#.utf8))
            case CursorUsageClient.usageSummaryURL:
                return HTTPResponse(statusCode: 200, headers: [:], body: Data("""
                {
                  "membershipType": "enterprise",
                  "individualUsage": {
                    "onDemand": { "enabled": true, "used": 12345, "limit": 200000, "remaining": 187655 }
                  }
                }
                """.utf8))
            case CursorUsageClient.creditsURL:
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{}"#.utf8))
            default:
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
        }
        let provider = CursorProvider(
            authStore: CursorAuthStore(
                sqlite: KeyValueSQLite(values: [
                    CursorAuthStore.accessTokenKey: accessToken,
                    CursorAuthStore.membershipTypeKey: "enterprise"
                ]),
                keychain: FakeKeychain()
            ),
            usageClient: CursorUsageClient(http: http),
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            pricing: { TestPricing.bundled }
        )

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.plan, "Enterprise")
        XCTAssertEqual(progress(snapshot.lines, "Cursor Models")?.used, 75)
        XCTAssertEqual(progress(snapshot.lines, "Other Models")?.used, 100)
        let onDemand = try XCTUnwrap(progress(snapshot.lines, "On-demand"))
        XCTAssertEqual(onDemand.used, 123.45, accuracy: 0.001)
        XCTAssertEqual(onDemand.limit, 2_000)
        XCTAssertTrue(http.requests.contains { $0.url == CursorUsageClient.usageSummaryURL })
    }

    @MainActor
    func testRateLimitedOptionalOrgSummaryKeepsPrimaryMetersWithoutRetry() async {
        let token = makeCursorJWT(sub: "auth0|rate-limited-org")
        let http = RoutingHTTPClient { request in
            switch request.url {
            case CursorUsageClient.usageURL:
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"enabled":true,"planUsage":{"totalPercentUsed":25,"autoPercentUsed":10,"apiPercentUsed":30}}"#.utf8))
            case CursorUsageClient.planURL:
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"planInfo":{"planName":"Pro"}}"#.utf8))
            case CursorUsageClient.usageSummaryURL:
                return HTTPResponse(statusCode: 429, headers: ["Retry-After": "600"], body: Data())
            default:
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
        }
        let provider = CursorProvider(
            authStore: CursorAuthStore(sqlite: KeyValueSQLite(values: [
                CursorAuthStore.accessTokenKey: token, CursorAuthStore.membershipTypeKey: "enterprise"
            ]), keychain: FakeKeychain()),
            usageClient: CursorUsageClient(http: http), pricing: { TestPricing.bundled }
        )
        let snapshot = await ProviderRefreshContext.$scope.withValue(.menuBar) { await provider.refresh() }
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.plan, "Enterprise")
        XCTAssertEqual(progress(snapshot.lines, "Total usage")?.used, 25)
        XCTAssertEqual(progress(snapshot.lines, "Cursor Models")?.used, 10)
        XCTAssertEqual(progress(snapshot.lines, "Other Models")?.used, 30)
        XCTAssertEqual(http.requests.filter { $0.url == CursorUsageClient.usageSummaryURL }.count, 1)
        XCTAssertNil(progress(snapshot.lines, "On-demand"))
    }

    @MainActor
    func testProviderLiveOrgMembershipWinsOverAStalePersonalLocalMembership() async throws {
        let accessToken = makeCursorJWT(sub: "google-oauth2|stale-seat")
        let http = RoutingHTTPClient { request in
            switch request.url {
            case CursorUsageClient.usageURL:
                return HTTPResponse(statusCode: 200, headers: [:], body: Data("""
                {
                  "enabled": true,
                  "planUsage": { "limit": 2000, "totalSpend": 400, "totalPercentUsed": 20 },
                  "spendLimitUsage": { "limitType": "team", "pooledLimit": 0 }
                }
                """.utf8))
            case CursorUsageClient.planURL:
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"planInfo":{"planName":"Pro"}}"#.utf8))
            case CursorUsageClient.usageSummaryURL:
                return HTTPResponse(statusCode: 200, headers: [:], body: Data("""
                {
                  "membershipType": "enterprise",
                  "individualUsage": {
                    "onDemand": { "enabled": true, "used": 500, "limit": 100000, "remaining": 99500 }
                  }
                }
                """.utf8))
            default:
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
        }
        let provider = CursorProvider(
            authStore: CursorAuthStore(
                sqlite: KeyValueSQLite(values: [
                    CursorAuthStore.accessTokenKey: accessToken,
                    CursorAuthStore.membershipTypeKey: "pro"
                ]),
                keychain: FakeKeychain()
            ),
            usageClient: CursorUsageClient(http: http),
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            pricing: { TestPricing.bundled }
        )

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.plan, "Enterprise")
        let onDemand = try XCTUnwrap(progress(snapshot.lines, "On-demand"))
        XCTAssertEqual(onDemand.used, 5, accuracy: 0.001)
        XCTAssertEqual(onDemand.limit, 1_000)
    }

    @MainActor
    func testPersonalSeatNeverLooksUpTheUsageSummary() async throws {
        let accessToken = makeCursorJWT(sub: "google-oauth2|personal-user")
        let http = RoutingHTTPClient { request in
            switch request.url {
            case CursorUsageClient.usageURL:
                return HTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(#"{"enabled":true,"billingCycleEnd":1772592000000,"planUsage":{"limit":40000,"remaining":32000,"totalPercentUsed":20}}"#.utf8)
                )
            case CursorUsageClient.planURL:
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"planInfo":{"planName":"Pro"}}"#.utf8))
            default:
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
        }
        let provider = CursorProvider(
            authStore: CursorAuthStore(
                sqlite: KeyValueSQLite(values: [CursorAuthStore.accessTokenKey: accessToken]),
                keychain: FakeKeychain()
            ),
            usageClient: CursorUsageClient(http: http),
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            pricing: { TestPricing.bundled }
        )

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.plan, "Pro")
        XCTAssertFalse(http.requests.contains { $0.url == CursorUsageClient.usageSummaryURL })
    }

    private func progress(
        _ lines: [MetricLine],
        _ label: String
    ) -> (used: Double, limit: Double, format: ProgressFormat)? {
        guard case .progress(_, let used, let limit, let format, _, _, _, _) =
            lines.first(where: { $0.label == label })
        else {
            return nil
        }
        return (used, limit, format)
    }
}
