import XCTest
@testable import QuotaBar

final class CopilotAuthStoreTests: XCTestCase {
    func testUnreadablePresentEditorConfigThrowsCredentialsUnreadable() {
        let store = CopilotAuthStore(
            files: UnreadableFiles(present: [CopilotAuthStore.editorAppsPath]),
            keychain: FakeKeychain()
        )

        XCTAssertThrowsError(try store.loadToken()) { error in
            XCTAssertEqual(error as? CopilotAuthError, .credentialsUnreadable)
        }
    }

    func testUnreadablePresentGitHubCLIConfigThrowsCredentialsUnreadable() {
        let key = KeychainItemKey(service: CopilotAuthStore.ghKeychainService)
        KeychainPermissionGate.shared.reset(key)
        defer { KeychainPermissionGate.shared.reset(key) }
        let keychain = CountingCopilotKeychain("go-keyring-base64:" + Data("other_account".utf8).base64EncodedString())
        let store = CopilotAuthStore(
            files: UnreadableFiles(present: [CopilotAuthStore.ghHostsPath]),
            keychain: keychain
        )

        XCTAssertThrowsError(try store.loadToken()) { error in
            XCTAssertEqual(error as? CopilotAuthError, .credentialsUnreadable)
        }
        XCTAssertEqual(keychain.readCount, 0, "without a readable username, a service-only lookup could select another GitHub account")
    }

    func testUnreadableEditorAppsFileFallsThroughToReadableEditorHostsFile() throws {
        let store = CopilotAuthStore(
            files: PartiallyUnreadableFiles(
                files: [CopilotAuthStore.editorHostsPath: #"{ "github.com": { "oauth_token": "gho_hosts" } }"#],
                unreadable: [CopilotAuthStore.editorAppsPath]
            ),
            keychain: FakeKeychain()
        )

        XCTAssertEqual(try store.loadToken()?.value, "gho_hosts")
    }

    func testMalformedEditorAppsFallsThroughToReadableHostsBeforeKeychain() throws {
        let store = CopilotAuthStore(
            files: FakeFiles([
                CopilotAuthStore.editorAppsPath: #"{"#,
                CopilotAuthStore.editorHostsPath: #"{ "github.com": { "oauth_token": "gho_hosts" } }"#
            ]),
            keychain: FakeKeychain("go-keyring-base64:" + Data("gho_keychain".utf8).base64EncodedString())
        )

        XCTAssertEqual(try store.loadToken()?.value, "gho_hosts")
    }

    func testMalformedEditorOAuthTokenFallsThroughToReadableGitHubCLIConfig() throws {
        let store = CopilotAuthStore(
            files: FakeFiles([
                CopilotAuthStore.editorAppsPath: #"{ "github.com": { "oauth_token": 7 } }"#,
                CopilotAuthStore.ghHostsPath: "github.com:\n    oauth_token: gho_cli\n"
            ]),
            keychain: FakeKeychain()
        )

        XCTAssertEqual(try store.loadToken()?.value, "gho_cli")
    }

    func testNonStringEditorOAuthTokenWithoutAlternateThrowsInvalidCredentials() {
        let store = CopilotAuthStore(
            files: FakeFiles([
                CopilotAuthStore.editorAppsPath: #"{ "github.com": { "oauth_token": 7 } }"#
            ]),
            keychain: FakeKeychain()
        )

        XCTAssertThrowsError(try store.loadToken()) { error in
            XCTAssertEqual(error as? CopilotAuthError, .invalidCredentials)
        }
    }

    func testMalformedEditorAppsOrHostsWithoutAlternateThrowsInvalidCredentials() {
        for malformedPath in [CopilotAuthStore.editorAppsPath, CopilotAuthStore.editorHostsPath] {
            let store = CopilotAuthStore(
                files: FakeFiles([malformedPath: #"{"#]),
                keychain: FakeKeychain()
            )

            XCTAssertThrowsError(try store.loadToken(), "expected invalid credentials for \(malformedPath)") { error in
                XCTAssertEqual(error as? CopilotAuthError, .invalidCredentials)
            }
        }
    }

    func testKeychainCancellationStaysCancellationAndDoesNotLogCredentialFailure() throws {
        let key = KeychainItemKey(service: CopilotAuthStore.ghKeychainService)
        KeychainPermissionGate.shared.reset(key)
        defer { KeychainPermissionGate.shared.reset(key) }
        let store = CopilotAuthStore(files: FakeFiles(), keychain: CancellationKeychain())

        let (error, logs) = try captureCopilotAuthStoreLogs {
            _ = try store.loadToken()
        }

        XCTAssertTrue(error is CancellationError)
        XCTAssertFalse(logs.contains("gh keychain credential read failed"), logs)
        XCTAssertFalse(logs.contains("[ERROR] [auth:copilot]"), logs)
    }

    func testRepeatedKeychainPermissionFailureUsesOneSilentRead() throws {
        let username = "tejas"
        let key = KeychainItemKey(service: CopilotAuthStore.ghKeychainService, account: username)
        KeychainPermissionGate.shared.reset(key)
        defer { KeychainPermissionGate.shared.reset(key) }
        let files = FakeFiles([CopilotAuthStore.ghHostsPath: "github.com:\n  user: \(username)\n"])
        let keychain = InteractionRequiredCopilotKeychain()
        let store = CopilotAuthStore(files: files, keychain: keychain)

        let (error, logs) = try captureCopilotAuthStoreLogs {
            for _ in 0..<4 {
                do {
                    _ = try store.loadToken()
                    XCTFail("expected the blocked Keychain item to remain an actionable auth error")
                } catch CopilotAuthError.credentialPermissionRequired {
                    // A later automatic refresh should not ask Security to repeat this refusal.
                }
            }
        }

        XCTAssertNil(error)
        XCTAssertEqual(keychain.calls, [false])
        XCTAssertFalse(logs.contains("gh keychain credential read failed"), logs)
        XCTAssertFalse(logs.contains("[ERROR] [auth:copilot]"), logs)
    }

    func testUnreadableEditorConfigFallsThroughToReadableGitHubCLIConfig() throws {
        let store = CopilotAuthStore(
            files: PartiallyUnreadableFiles(
                files: [CopilotAuthStore.ghHostsPath: "github.com:\n    oauth_token: gho_cli\n"],
                unreadable: [CopilotAuthStore.editorAppsPath]
            ),
            keychain: FakeKeychain()
        )

        XCTAssertEqual(try store.loadToken()?.value, "gho_cli")
    }

    func testUnreadableEditorConfigFallsThroughToReadableGitHubCLIKeychain() throws {
        let wrapped = "go-keyring-base64:" + Data("gho_keychain".utf8).base64EncodedString()
        let store = CopilotAuthStore(
            files: UnreadableFiles(present: [CopilotAuthStore.editorAppsPath]),
            keychain: FakeKeychain(wrapped)
        )

        XCTAssertEqual(try store.loadToken()?.value, "gho_keychain")
    }

    func testEditorConfigWinsOverKeychain() throws {
        let store = CopilotAuthStore(
            files: FakeFiles([
                CopilotAuthStore.editorAppsPath: #"{ "github.com": { "oauth_token": "gho_editor" } }"#
            ]),
            keychain: FakeKeychain("go-keyring-base64:" + Data("gho_keychain".utf8).base64EncodedString())
        )

        // Editor config wins over the keychain: the editor token is returned, not the keychain one.
        XCTAssertEqual(try store.loadToken()?.value, "gho_editor")
    }

    func testReturnsNilWhenNoCredentials() throws {
        let store = CopilotAuthStore(files: FakeFiles(), keychain: FakeKeychain())
        XCTAssertNil(try store.loadToken())
    }

    func testEditorConfigIgnoresNonGithubDotComHost() throws {
        // An Enterprise-only editor config must not yield a token for api.github.com; the chain should
        // fall through to the gh keychain (which here holds the real github.com token).
        let store = CopilotAuthStore(
            files: FakeFiles([
                CopilotAuthStore.editorAppsPath: #"{ "ghe.corp.example:Iv1.x": { "oauth_token": "gho_enterprise" } }"#
            ]),
            keychain: FakeKeychain("go-keyring-base64:" + Data("gho_dotcom".utf8).base64EncodedString())
        )

        let token = try store.loadToken()

        XCTAssertEqual(token?.value, "gho_dotcom")
    }

    func testEditorConfigPicksGithubDotComAmongHosts() throws {
        let store = CopilotAuthStore(
            files: FakeFiles([
                CopilotAuthStore.editorAppsPath: #"{ "ghe.corp.example:Iv1.x": { "oauth_token": "gho_ent" }, "github.com:Iv1.y": { "oauth_token": "gho_dotcom" } }"#
            ]),
            keychain: FakeKeychain()
        )

        XCTAssertEqual(try store.loadToken()?.value, "gho_dotcom")
    }

    func testYamlUserIsScopedToGithubAndIgnoresNestedUsersMap() throws {
        let hosts = """
        ghe.corp.example:
            user: enterprise
        github.com:
            users:
                octocat:
            user: octocat
        """
        XCTAssertEqual(CopilotAuthStore.yamlValue(hosts, key: "user"), "octocat")
    }

    func testGhConfigPrefersGithubDotComTokenOverEnterprise() throws {
        let store = CopilotAuthStore(
            files: FakeFiles([
                CopilotAuthStore.ghHostsPath: """
                ghe.corp.example:
                    oauth_token: gho_enterprise
                github.com:
                    oauth_token: gho_dotcom
                """
            ]),
            keychain: FakeKeychain()
        )

        XCTAssertEqual(try store.loadToken()?.value, "gho_dotcom")
    }
}

final class CopilotUsageMapperTests: XCTestCase {
    func testMapsPaidCreditsAndChatAsPercentUsed() throws {
        let mapped = try CopilotUsageMapper.map(body: makePaidBody())

        XCTAssertEqual(mapped.plan, "Pro")
        XCTAssertEqual(progress(mapped.lines, "Credits")?.used, 59)
        XCTAssertEqual(progress(mapped.lines, "Chat")?.used, 5)
        XCTAssertNotNil(progress(mapped.lines, "Credits")?.resetsAt)
        XCTAssertEqual(progress(mapped.lines, "Credits")?.periodDurationMs, CopilotUsageMapper.periodMs)
        XCTAssertNil(mapped.lines.first(where: { $0.label == "Extra Usage" }))
    }

    func testSuppressesUnlimitedAndSentinelBuckets() throws {
        // Paid plans report chat/completions as unlimited — both the explicit flag and the `-1`
        // entitlement/remaining sentinel — which carry no real meter and must be suppressed, leaving
        // just Credits.
        var body = makePaidBody()
        var quota = body["quota_snapshots"] as! [String: Any]
        quota["chat"] = ["unlimited": true, "entitlement": 0, "remaining": 0, "quota_id": "chat"]
        quota["completions"] = ["entitlement": -1, "remaining": -1, "quota_id": "completions"]
        body["quota_snapshots"] = quota

        let mapped = try CopilotUsageMapper.map(body: body)

        XCTAssertNil(progress(mapped.lines, "Chat"))
        XCTAssertNil(progress(mapped.lines, "Completions"))
        XCTAssertEqual(progress(mapped.lines, "Credits")?.used, 59)
    }

    func testPermittedExtraUsagePreservesPositiveAndZeroCounts() throws {
        for overage in [36, 0] {
            var body = makePaidBody()
            var quota = body["quota_snapshots"] as! [String: Any]
            var premium = quota["premium_interactions"] as! [String: Any]
            premium["overage_permitted"] = true
            premium["overage_count"] = overage
            quota["premium_interactions"] = premium
            body["quota_snapshots"] = quota

            let mapped = try CopilotUsageMapper.map(body: body)

            XCTAssertEqual(countValue(mapped.lines, "Extra Usage"), Double(overage))
            XCTAssertFalse(mapped.isOrgManagedSeat)
        }
    }

    func testIgnoresLegacyLimitedQuotasWhenSnapshotsPresent() throws {
        // A paid response with Credits present and chat/completions unlimited (-1) must NOT fall back to
        // the legacy limited_user_quotas path, even if the payload still carries it — doing so would show
        // free-tier Chat/Completions meters on a paid account alongside Credits.
        var body = makePaidBody()
        var quota = body["quota_snapshots"] as! [String: Any]
        quota["chat"] = ["entitlement": -1, "remaining": -1, "quota_id": "chat"]
        quota["completions"] = ["entitlement": -1, "remaining": -1, "quota_id": "completions"]
        body["quota_snapshots"] = quota
        body["limited_user_quotas"] = ["chat": 100, "completions": 1000]
        body["monthly_quotas"] = ["chat": 500, "completions": 4000]

        let mapped = try CopilotUsageMapper.map(body: body)

        XCTAssertNotNil(progress(mapped.lines, "Credits"))
        XCTAssertNil(progress(mapped.lines, "Chat"))
        XCTAssertNil(progress(mapped.lines, "Completions"))
    }

    func testSuppressesZeroEntitlementPlaceholder() throws {
        let body: [String: Any] = [
            "copilot_plan": "business",
            "quota_snapshots": [
                "premium_interactions": ["entitlement": 0, "remaining": 0, "percent_remaining": 100, "quota_id": "premium"],
                "chat": ["entitlement": 1000, "remaining": 800, "percent_remaining": 80, "quota_id": "chat"]
            ]
        ]

        let mapped = try CopilotUsageMapper.map(body: body)

        XCTAssertNil(progress(mapped.lines, "Credits"))
        XCTAssertEqual(progress(mapped.lines, "Chat")?.used, 20)
    }

    func testMapsLiveFreeAccountSnapshots() throws {
        // The exact shape a free `individual` account returns today: real chat/completions counts in
        // `quota_snapshots`, a zero-entitlement premium bucket, and `token_based_billing` on every bucket.
        // Credits + Extra Usage suppress (no allotment / overage off); Chat + Completions render.
        let body: [String: Any] = [
            "copilot_plan": "individual",
            "access_type_sku": "free_limited_copilot",
            "token_based_billing": true,
            "quota_reset_date": "2099-07-01",
            "quota_snapshots": [
                "chat": ["entitlement": 200, "remaining": 182, "percent_remaining": 91.0, "overage_permitted": false, "token_based_billing": true],
                "completions": ["entitlement": 2000, "remaining": 1989, "percent_remaining": 99.4, "overage_permitted": false, "token_based_billing": true],
                "premium_interactions": ["entitlement": 0, "remaining": 0, "percent_remaining": 0.0, "overage_permitted": false, "token_based_billing": true]
            ]
        ]

        let mapped = try CopilotUsageMapper.map(body: body)

        XCTAssertEqual(mapped.plan, "Individual")
        XCTAssertNil(progress(mapped.lines, "Credits"))
        XCTAssertNil(mapped.lines.first(where: { $0.label == "Extra Usage" }))
        XCTAssertEqual(progress(mapped.lines, "Chat")?.used ?? -1, 9, accuracy: 0.0001)
        XCTAssertEqual(progress(mapped.lines, "Completions")?.used ?? -1, 0.6, accuracy: 0.0001)
    }

    func testMapsFreeTierLimitedQuotas() throws {
        let body: [String: Any] = [
            "copilot_plan": "individual",
            "limited_user_quotas": ["chat": 250, "completions": 2000],
            "monthly_quotas": ["chat": 500, "completions": 4000],
            "limited_user_reset_date": "2099-02-15"
        ]

        let mapped = try CopilotUsageMapper.map(body: body)

        XCTAssertEqual(mapped.plan, "Individual")
        XCTAssertEqual(progress(mapped.lines, "Chat")?.used, 50)
        XCTAssertEqual(progress(mapped.lines, "Completions")?.used, 50)
        XCTAssertNotNil(progress(mapped.lines, "Chat")?.resetsAt)
    }

    func testUnusedOrgManagedSeatPreservesPlanWithoutMeters() throws {
        for creditsUsed in [nil, 0] as [Int?] {
            var premium: [String: Any] = ["entitlement": 0, "remaining": 0]
            if let creditsUsed { premium["credits_used"] = creditsUsed }
            let body: [String: Any] = [
                "copilot_plan": "business",
                "token_based_billing": true,
                "quota_snapshots": ["premium_interactions": premium]
            ]

            let mapped = try CopilotUsageMapper.map(body: body)

            XCTAssertEqual(mapped.plan, "Business")
            XCTAssertTrue(mapped.lines.isEmpty)
            XCTAssertTrue(mapped.isOrgManagedSeat)
        }
    }

    func testPlaceholderOveragePermittedDoesNotEmitExtraUsageOrBlockOrgFlag() throws {
        // Regression for issue #839's second report: the org-managed placeholder carries
        // `overage_permitted: true` on a zero-entitlement premium bucket. That must not render a
        // meaningless "Extra Usage: 0" row — and must still flag the seat as org-managed so the
        // provider runs the org-billing lookup.
        let mapped = try CopilotUsageMapper.map(body: makeBusinessPlaceholderBody())

        XCTAssertTrue(mapped.lines.isEmpty)
        XCTAssertTrue(mapped.isOrgManagedSeat)
    }

    func testShowsPersonalCreditsUsedOnOrgManagedPlaceholder() throws {
        // The exact shape reported in issue #1094: org-managed seat, zero entitlement, but
        // `premium_interactions.credits_used` carries the user's own real per-seat consumption.
        let mapped = try CopilotUsageMapper.map(body: makeBusinessPlaceholderBodyWithPersonalCredits(2111))

        XCTAssertEqual(mapped.plan, "Business")
        XCTAssertEqual(countValue(mapped.lines, "Credits"), 2111)
        XCTAssertNil(mapped.lines.first(where: { $0.label == "Extra Usage" }))
        XCTAssertTrue(mapped.isOrgManagedSeat)
    }

    func testThrowsQuotaUnavailableWhenEmpty() throws {
        XCTAssertThrowsError(try CopilotUsageMapper.map(body: ["copilot_plan": "pro"])) { error in
            XCTAssertEqual(error as? CopilotUsageError, .quotaUnavailable)
        }
    }
}

final class CopilotOrgBillingMapperTests: XCTestCase {
    func testParsesOrgLogins() throws {
        let body: [[String: Any]] = [["login": "acme", "id": 1], ["login": "globex"], ["id": 3]]
        let response = HTTPResponse(statusCode: 200, headers: [:], body: try! JSONSerialization.data(withJSONObject: body))

        XCTAssertEqual(CopilotOrgBillingMapper.orgLogins(response), ["acme", "globex"])
    }

    func testOrgLoginsEmptyForGarbledBody() throws {
        let response = HTTPResponse(statusCode: 200, headers: [:], body: Data("<html>".utf8))
        XCTAssertEqual(CopilotOrgBillingMapper.orgLogins(response), [])
    }

    func testMapsAICreditUsageFromSummary() throws {
        // The exact shape reported in issue #839: one Copilot AI-unit item, fully covered by included
        // credits (netAmount 0).
        let lines = try XCTUnwrap(CopilotOrgBillingMapper.usageLines(body: makeOrgSummaryBody()))

        XCTAssertEqual(orgCount(lines, "Org Credits") ?? -1, 298.698546, accuracy: 0.0001)
        XCTAssertEqual(orgDollars(lines, "Org Spend"), 0)
    }

    func testSumsMultipleCreditItemsAndBilledSpend() throws {
        var body = makeOrgSummaryBody()
        body["usageItems"] = [
            ["product": "Copilot", "sku": "copilot_ai_unit", "unitType": "ai-units", "grossQuantity": 100.5, "netAmount": 1.25],
            ["product": "Copilot", "sku": "Copilot AI Credits", "unitType": "ai-credits", "grossQuantity": 50, "netAmount": 0.5]
        ]

        let lines = try XCTUnwrap(CopilotOrgBillingMapper.usageLines(body: body))

        XCTAssertEqual(orgCount(lines, "Org Credits") ?? -1, 150.5, accuracy: 0.0001)
        XCTAssertEqual(orgDollars(lines, "Org Spend") ?? -1, 1.75, accuracy: 0.0001)
    }

    func testNilWhenNoCopilotCreditItems() throws {
        // Actions minutes and Copilot seat fees (non-credit units) must not produce org meters.
        var body = makeOrgSummaryBody()
        body["usageItems"] = [
            ["product": "Actions", "sku": "actions_linux", "unitType": "minutes", "grossQuantity": 120, "netAmount": 0.96],
            ["product": "Copilot", "sku": "copilot_business_seat", "unitType": "user-months", "grossQuantity": 10, "netAmount": 190]
        ]

        XCTAssertNil(CopilotOrgBillingMapper.usageLines(body: body))
    }

    func testNilWhenSummaryHasNoUsageItems() throws {
        XCTAssertNil(CopilotOrgBillingMapper.usageLines(body: ["organization": "acme"]))
    }
}

@MainActor
final class CopilotProviderTests: XCTestCase {
    func testUnreadableEditorConfigStaysDetectedAndRefreshShowsRepairMessage() async {
        let provider = CopilotProvider(
            authStore: CopilotAuthStore(
                files: UnreadableFiles(present: [CopilotAuthStore.editorAppsPath]),
                keychain: FakeKeychain()
            ),
            usageClient: CopilotUsageClient(http: FakeHTTPClient(response: ok(makePaidBody())))
        )

        let detected = await provider.hasLocalCredentials()
        let snapshot = await provider.refresh()

        XCTAssertTrue(detected, "a present but unreadable config must not become a one-shot detection miss")
        XCTAssertEqual(snapshot.errorCategory, .credentialAccess)
        guard case .badge(_, let message, _, _) = snapshot.lines.first else {
            return XCTFail("expected the actionable credential error badge")
        }
        XCTAssertTrue(message.contains("editor or GitHub CLI config"))
    }

    func testMalformedEditorConfigStaysDetectedAndRefreshShowsInvalidCredentialError() async {
        let provider = CopilotProvider(
            authStore: CopilotAuthStore(
                files: FakeFiles([CopilotAuthStore.editorAppsPath: #"{ "github.com": { "oauth_token": 7 } }"#]),
                keychain: FakeKeychain()
            ),
            usageClient: CopilotUsageClient(http: FakeHTTPClient(response: ok(makePaidBody())))
        )

        let detected = await provider.hasLocalCredentials()
        let snapshot = await provider.refresh()

        XCTAssertTrue(detected, "malformed editor credentials must remain visible for repair")
        XCTAssertEqual(snapshot.errorCategory, .authInvalid)
        guard case .badge(_, let message, _, _) = snapshot.lines.first else {
            return XCTFail("expected the actionable invalid-credentials badge")
        }
        XCTAssertTrue(message.contains("malformed Copilot editor credentials"))
    }

    func testUnreadableGitHubCLIConfigStaysDetectedAndFailsClosedBeforeKeychainLookup() async {
        let key = KeychainItemKey(service: CopilotAuthStore.ghKeychainService)
        KeychainPermissionGate.shared.reset(key)
        defer { KeychainPermissionGate.shared.reset(key) }
        let keychain = CountingCopilotKeychain("go-keyring-base64:" + Data("other_account".utf8).base64EncodedString())
        let provider = CopilotProvider(
            authStore: CopilotAuthStore(
                files: UnreadableFiles(present: [CopilotAuthStore.ghHostsPath]),
                keychain: keychain
            ),
            usageClient: CopilotUsageClient(http: FakeHTTPClient(response: ok(makePaidBody())))
        )

        let detected = await provider.hasLocalCredentials()
        let snapshot = await provider.refresh()

        XCTAssertTrue(detected, "an unreadable configured source must remain visible for repair")
        XCTAssertEqual(snapshot.errorCategory, .credentialAccess)
        XCTAssertEqual(keychain.readCount, 0, "the service-only query must not risk selecting a different account")
    }

    func testNotLoggedInWhenNoToken() async {
        let provider = CopilotProvider(
            authStore: CopilotAuthStore(files: FakeFiles(), keychain: FakeKeychain()),
            usageClient: CopilotUsageClient(http: FakeHTTPClient(response: ok(makePaidBody())))
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
    }

    func testTokenInvalidOn401() async {
        let provider = CopilotProvider(
            authStore: editorTokenStore(),
            usageClient: CopilotUsageClient(http: FakeHTTPClient(response: HTTPResponse(statusCode: 401, headers: [:], body: Data())))
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .authExpired)
    }

    func testForbiddenOn403DoesNotTellUserToReauthenticate() async {
        let provider = CopilotProvider(
            authStore: editorTokenStore(),
            usageClient: CopilotUsageClient(http: FakeHTTPClient(response: HTTPResponse(statusCode: 403, headers: [:], body: Data())))
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .http4xx)
        XCTAssertNotEqual(snapshot.errorCategory, .authExpired)
    }

    func testMapsLinesAndSendsTokenHeaderOnSuccess() async throws {
        let http = FakeHTTPClient(response: ok(makePaidBody()))
        let provider = CopilotProvider(
            authStore: editorTokenStore(),
            usageClient: CopilotUsageClient(http: http),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.plan, "Pro")
        XCTAssertEqual(snapshot.line(label: "Credits")?.label, "Credits")
        XCTAssertEqual(http.requests.first?.headers["Authorization"], "token gho_editor")
    }

    func testOrgBillingForbiddenKeepsPlanOnlyCard() async {
        // A plain org member (not owner/billing manager) gets 403 on org billing — the expected state,
        // which must keep today's plan-only card rather than erroring the provider.
        let forbidden = HTTPResponse(statusCode: 403, headers: [:], body: Data())
        let http = routedClient([
            ("/copilot_internal/user", ok(makeBusinessPlaceholderBody())),
            ("/user/orgs", okJSON([["login": "acme"]])),
            ("/orgs/acme/settings/billing/usage/summary", forbidden)
        ])
        let defaults = freshDefaults()
        let provider = makeOrgProvider(http: http, defaults: defaults)

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.plan, "Business")
        XCTAssertTrue(snapshot.lines.isEmpty)
        XCTAssertNil(defaults.string(forKey: CopilotProvider.billingOrgDefaultsKey))
    }

    func testOrgManagedSeatWithPersonalCreditsShowsThemDespiteForbiddenOrgBilling() async {
        // A plain org member (403 on org billing, issue #1094) must still see their own credit
        // consumption from the user-scoped endpoint instead of a fully empty card.
        let forbidden = HTTPResponse(statusCode: 403, headers: [:], body: Data())
        let http = routedClient([
            ("/copilot_internal/user", ok(makeBusinessPlaceholderBodyWithPersonalCredits(2111))),
            ("/user/orgs", okJSON([["login": "acme"]])),
            ("/orgs/acme/settings/billing/usage/summary", forbidden)
        ])
        let defaults = freshDefaults()
        let provider = makeOrgProvider(http: http, defaults: defaults)

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.plan, "Business")
        XCTAssertEqual(countValue(snapshot.lines, "Credits"), 2111)
        XCTAssertNil(defaults.string(forKey: CopilotProvider.billingOrgDefaultsKey))
    }

    func testOrgManagedSeatWithPersonalCreditsAlsoKeepsOrgBillingLinesForAdmins() async {
        // An org owner/billing manager gets both: their own personal Credits count, plus the org-wide
        // Org Credits / Org Spend rows — the merge must not drop either side (issue #1094 vs #839).
        let http = routedClient([
            ("/copilot_internal/user", ok(makeBusinessPlaceholderBodyWithPersonalCredits(2111))),
            ("/user/orgs", okJSON([["login": "acme"]])),
            ("/orgs/acme/settings/billing/usage/summary", ok(makeOrgSummaryBody()))
        ])
        let defaults = freshDefaults()
        let provider = makeOrgProvider(http: http, defaults: defaults)

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.plan, "Business")
        XCTAssertEqual(countValue(snapshot.lines, "Credits"), 2111)
        XCTAssertEqual(orgCount(snapshot.lines, "Org Credits") ?? -1, 298.698546, accuracy: 0.0001)
        XCTAssertEqual(orgDollars(snapshot.lines, "Org Spend"), 0)
        XCTAssertNil(snapshot.lines.first(where: { $0.label == "Extra Usage" }))
        XCTAssertEqual(defaults.string(forKey: CopilotProvider.billingOrgDefaultsKey), "acme")
    }

    func testUsesCachedOrgWithoutReprobing() async {
        let http = routedClient([
            ("/copilot_internal/user", ok(makeBusinessPlaceholderBody())),
            ("/orgs/acme/settings/billing/usage/summary", ok(makeOrgSummaryBody()))
        ])
        let defaults = freshDefaults()
        defaults.set("acme", forKey: CopilotProvider.billingOrgDefaultsKey)
        let provider = makeOrgProvider(http: http, defaults: defaults)

        let snapshot = await provider.refresh()

        XCTAssertNotNil(orgCount(snapshot.lines, "Org Credits"))
        XCTAssertFalse(http.requests.contains { $0.url.absoluteString.contains("/user/orgs") })
    }

    func testEvictsStaleCachedOrgAndReprobes() async {
        // The cached org answers without Copilot usage (e.g. the user changed orgs) — it must be
        // forgotten and discovery re-run.
        let http = routedClient([
            ("/copilot_internal/user", ok(makeBusinessPlaceholderBody())),
            ("/orgs/oldorg/settings/billing/usage/summary", HTTPResponse(statusCode: 404, headers: [:], body: Data())),
            ("/user/orgs", okJSON([["login": "acme"]])),
            ("/orgs/acme/settings/billing/usage/summary", ok(makeOrgSummaryBody()))
        ])
        let defaults = freshDefaults()
        defaults.set("oldorg", forKey: CopilotProvider.billingOrgDefaultsKey)
        let provider = makeOrgProvider(http: http, defaults: defaults)

        let snapshot = await provider.refresh()

        XCTAssertNotNil(orgCount(snapshot.lines, "Org Credits"))
        XCTAssertEqual(defaults.string(forKey: CopilotProvider.billingOrgDefaultsKey), "acme")
    }

    func testCachedOrgAlreadyInDiscoveryListIsQueriedOnlyOnce() async {
        let http = routedClient([
            ("/copilot_internal/user", ok(makeBusinessPlaceholderBody())),
            ("/orgs/acme/settings/billing/usage/summary", HTTPResponse(statusCode: 404, headers: [:], body: Data())),
            ("/user/orgs", okJSON([["login": "acme"]]))
        ])
        let defaults = freshDefaults()
        defaults.set("acme", forKey: CopilotProvider.billingOrgDefaultsKey)
        let provider = makeOrgProvider(http: http, defaults: defaults)

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(
            http.requests.filter { $0.url.path == "/orgs/acme/settings/billing/usage/summary" }.count,
            1,
            "the cached org result must not be repeated during the same discovery pass"
        )
    }

    func testDiscoveryKeepsProbingPastAFailingOrg() async {
        // One org's billing endpoint having an outage (5xx) must not abort discovery — the next org's
        // usage should still be found and cached.
        let http = routedClient([
            ("/copilot_internal/user", ok(makeBusinessPlaceholderBody())),
            ("/user/orgs", okJSON([["login": "brokenorg"], ["login": "acme"]])),
            ("/orgs/brokenorg/settings/billing/usage/summary", HTTPResponse(statusCode: 503, headers: [:], body: Data())),
            ("/orgs/acme/settings/billing/usage/summary", ok(makeOrgSummaryBody()))
        ])
        let defaults = freshDefaults()
        let provider = makeOrgProvider(http: http, defaults: defaults)

        let snapshot = await provider.refresh()

        XCTAssertNotNil(orgCount(snapshot.lines, "Org Credits"))
        XCTAssertEqual(defaults.string(forKey: CopilotProvider.billingOrgDefaultsKey), "acme")
    }

    func testOrgDiscoveryFollowsPaginationAndFindsBillingOrgAfterPageOne() async {
        let pageOne = [["login": "member-0"] as [String: Any]]
        let pageOneBody = try! JSONSerialization.data(withJSONObject: pageOne)
        let http = RoutingHTTPClient { request in
            if request.url.absoluteString.contains("/copilot_internal/user") {
                return ok(makeBusinessPlaceholderBody())
            }
            if request.url.path == "/user/orgs" {
                if URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: {
                    $0.name == "page" && $0.value == "2"
                }) == true {
                    return okJSON([["login": "acme"]])
                }
                return HTTPResponse(
                    statusCode: 200,
                    headers: ["Link": "<https://api.github.com/user/orgs?per_page=100&page=2>; rel=\"next\""],
                    body: pageOneBody
                )
            }
            if request.url.path == "/orgs/acme/settings/billing/usage/summary" {
                return ok(makeOrgSummaryBody())
            }
            if request.url.path == "/orgs/member-0/settings/billing/usage/summary" {
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
            XCTFail("unexpected request: \(request.url)")
            return HTTPResponse(statusCode: 500, headers: [:], body: Data())
        }
        let provider = makeOrgProvider(http: http, defaults: freshDefaults())

        let snapshot = await provider.refresh()

        XCTAssertNotNil(orgCount(snapshot.lines, "Org Credits"))
        XCTAssertEqual(http.requests.filter { $0.url.path == "/user/orgs" }.count, 2)
    }

    func testLaterPageFailureStillUsesOrganizationsFromCompletedPages() async {
        let http = RoutingHTTPClient { request in
            if request.url.absoluteString.contains("/copilot_internal/user") {
                return ok(makeBusinessPlaceholderBody())
            }
            if request.url.path == "/user/orgs" {
                if URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: {
                    $0.name == "page" && $0.value == "2"
                }) == true {
                    return HTTPResponse(statusCode: 503, headers: [:], body: Data())
                }
                return HTTPResponse(
                    statusCode: 200,
                    headers: ["Link": "<https://api.github.com/user/orgs?per_page=100&page=2>; rel=\"next\""],
                    body: try! JSONSerialization.data(withJSONObject: [["login": "acme"]])
                )
            }
            if request.url.path == "/orgs/acme/settings/billing/usage/summary" {
                return ok(makeOrgSummaryBody())
            }
            XCTFail("unexpected request: \(request.url)")
            return HTTPResponse(statusCode: 500, headers: [:], body: Data())
        }
        let provider = makeOrgProvider(http: http, defaults: freshDefaults())

        let snapshot = await provider.refresh()

        XCTAssertNotNil(orgCount(snapshot.lines, "Org Credits"))
        XCTAssertEqual(http.requests.filter { $0.url.path == "/orgs/acme/settings/billing/usage/summary" }.count, 1)
    }

    func testLaterPageTransportFailureStillUsesOrganizationsFromCompletedPages() async {
        let http = RoutingHTTPClient { request in
            if request.url.absoluteString.contains("/copilot_internal/user") {
                return ok(makeBusinessPlaceholderBody())
            }
            if request.url.path == "/user/orgs" {
                if URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: {
                    $0.name == "page" && $0.value == "2"
                }) == true {
                    throw URLError(.timedOut)
                }
                return HTTPResponse(
                    statusCode: 200,
                    headers: ["Link": "<https://api.github.com/user/orgs?per_page=100&page=2>; rel=\"next\""],
                    body: try! JSONSerialization.data(withJSONObject: [["login": "acme"]])
                )
            }
            if request.url.path == "/orgs/acme/settings/billing/usage/summary" {
                return ok(makeOrgSummaryBody())
            }
            XCTFail("unexpected request: \(request.url)")
            return HTTPResponse(statusCode: 500, headers: [:], body: Data())
        }
        let provider = makeOrgProvider(http: http, defaults: freshDefaults())

        let snapshot = await provider.refresh()

        XCTAssertNotNil(orgCount(snapshot.lines, "Org Credits"))
        XCTAssertEqual(http.requests.filter { $0.url.path == "/orgs/acme/settings/billing/usage/summary" }.count, 1)
    }

    func testLaterPageTransportFailureDoesNotCacheCompletedPagesAsNoResult() async {
        let clock = Date(timeIntervalSince1970: 1_800_000_000)
        let http = RoutingHTTPClient { request in
            if request.url.absoluteString.contains("/copilot_internal/user") {
                return ok(makeBusinessPlaceholderBody())
            }
            if request.url.path == "/user/orgs" {
                if URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: {
                    $0.name == "page" && $0.value == "2"
                }) == true {
                    throw URLError(.timedOut)
                }
                return HTTPResponse(
                    statusCode: 200,
                    headers: ["Link": "<https://api.github.com/user/orgs?per_page=100&page=2>; rel=\"next\""],
                    body: try! JSONSerialization.data(withJSONObject: [["login": "acme"]])
                )
            }
            if request.url.path == "/orgs/acme/settings/billing/usage/summary" {
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
            XCTFail("unexpected request: \(request.url)")
            return HTTPResponse(statusCode: 500, headers: [:], body: Data())
        }
        let defaults = freshDefaults()
        let provider = CopilotProvider(
            authStore: editorTokenStore(),
            usageClient: CopilotUsageClient(http: http),
            orgBillingClient: CopilotOrgBillingClient(http: http),
            defaults: defaults,
            now: { clock }
        )

        _ = await provider.refresh()

        XCTAssertNil(defaults.object(forKey: CopilotProvider.billingOrgProbeRetryAfterKey),
                     "an incomplete membership scan must not be cached as a complete no-result scan")
        _ = await provider.refresh()
        XCTAssertEqual(http.requests.filter { $0.url.path == "/user/orgs" }.count, 4,
                       "a later refresh retries the incomplete membership scan")
    }

    func testOrgBillingRateLimitHonorsRetryAfterAndManualRefreshKeepsServerDeadline() async {
        let clock = Date(timeIntervalSince1970: 1_800_000_000)
        let http = RoutingHTTPClient { request in
            if request.url.absoluteString.contains("/copilot_internal/user") {
                return ok(makeBusinessPlaceholderBody())
            }
            if request.url.path == "/user/orgs" {
                return okJSON([["login": "acme"], ["login": "second-org"]])
            }
            if request.url.path == "/orgs/acme/settings/billing/usage/summary" {
                return HTTPResponse(statusCode: 403, headers: ["Retry-After": "120"], body: Data())
            }
            XCTFail("rate-limited discovery must stop before later orgs: \(request.url)")
            return HTTPResponse(statusCode: 500, headers: [:], body: Data())
        }
        let defaults = freshDefaults()
        let provider = CopilotProvider(
            authStore: editorTokenStore(),
            usageClient: CopilotUsageClient(http: http),
            orgBillingClient: CopilotOrgBillingClient(http: http),
            defaults: defaults,
            now: { clock }
        )

        _ = await provider.refresh()
        XCTAssertEqual(
            defaults.object(forKey: CopilotProvider.billingOrgRateLimitRetryAfterKey) as? Date,
            clock.addingTimeInterval(120)
        )
        _ = await provider.refresh()
        XCTAssertEqual(http.requests.filter { $0.url.path == "/user/orgs" }.count, 1,
                       "scheduled refreshes honor the server's Retry-After")

        _ = await withManualRefresh { await provider.refresh() }
        XCTAssertEqual(http.requests.filter { $0.url.path == "/user/orgs" }.count, 1,
                       "a manual refresh still honors a server-directed rate-limit deadline")
        XCTAssertEqual(http.requests.filter { $0.url.path == "/orgs/acme/settings/billing/usage/summary" }.count, 1)
    }

    func testNoResultCooldownCanBeBypassedByManualRefresh() async {
        let clock = Date(timeIntervalSince1970: 1_800_000_000)
        let http = routedClient([
            ("/copilot_internal/user", ok(makeBusinessPlaceholderBody())),
            ("/user/orgs", okJSON([["login": "acme"]])),
            ("/orgs/acme/settings/billing/usage/summary", HTTPResponse(statusCode: 404, headers: [:], body: Data()))
        ])
        let provider = CopilotProvider(
            authStore: editorTokenStore(),
            usageClient: CopilotUsageClient(http: http),
            orgBillingClient: CopilotOrgBillingClient(http: http),
            defaults: freshDefaults(),
            now: { clock }
        )

        _ = await provider.refresh()
        _ = await provider.refresh()
        XCTAssertEqual(http.requests.filter { $0.url.path == "/user/orgs" }.count, 1,
                       "scheduled refreshes pause after a completed no-result scan")

        _ = await withManualRefresh { await provider.refresh() }
        XCTAssertEqual(http.requests.filter { $0.url.path == "/user/orgs" }.count, 2,
                       "an explicit Refresh retries an ordinary no-result scan")
    }

    func testPartialPageRateLimitStopsFurtherRequestsAndHonorsDeadline() async {
        let clock = Date(timeIntervalSince1970: 1_800_000_000)
        let http = RoutingHTTPClient { request in
            if request.url.absoluteString.contains("/copilot_internal/user") {
                return ok(makeBusinessPlaceholderBody())
            }
            if request.url.path == "/user/orgs" {
                if URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: {
                    $0.name == "page" && $0.value == "2"
                }) == true {
                    return HTTPResponse(statusCode: 429, headers: ["Retry-After": "120"], body: Data())
                }
                return HTTPResponse(
                    statusCode: 200,
                    headers: ["Link": "<https://api.github.com/user/orgs?per_page=100&page=2>; rel=\"next\""],
                    body: try! JSONSerialization.data(withJSONObject: [["login": "acme"]])
                )
            }
            XCTFail("unexpected request: \(request.url)")
            return HTTPResponse(statusCode: 500, headers: [:], body: Data())
        }
        let defaults = freshDefaults()
        let provider = CopilotProvider(
            authStore: editorTokenStore(),
            usageClient: CopilotUsageClient(http: http),
            orgBillingClient: CopilotOrgBillingClient(http: http),
            defaults: defaults,
            now: { clock }
        )

        _ = await provider.refresh()
        XCTAssertEqual(http.requests.filter { $0.url.path == "/orgs/acme/settings/billing/usage/summary" }.count, 0,
                       "a rate-limit response stops the rest of this refresh")
        XCTAssertEqual(
            defaults.object(forKey: CopilotProvider.billingOrgRateLimitRetryAfterKey) as? Date,
            clock.addingTimeInterval(120),
            "the server's deadline is retained"
        )

        _ = await provider.refresh()
        XCTAssertEqual(http.requests.filter { $0.url.path == "/user/orgs" }.count, 2,
                       "the second refresh skips pagination while the server deadline is active")
    }

    func testOrgListRemainingZeroStopsSummariesUntilReset() async {
        let clock = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = clock.addingTimeInterval(120)
        let http = RoutingHTTPClient { request in
            if request.url.absoluteString.contains("/copilot_internal/user") {
                return ok(makeBusinessPlaceholderBody())
            }
            if request.url.path == "/user/orgs" {
                return HTTPResponse(
                    statusCode: 200,
                    headers: [
                        "Link": "<https://api.github.com/user/orgs?per_page=100&page=2>; rel=\"next\"",
                        "X-RateLimit-Remaining": "0",
                        "X-RateLimit-Reset": String(Int(reset.timeIntervalSince1970))
                    ],
                    body: try! JSONSerialization.data(withJSONObject: [["login": "acme"]])
                )
            }
            XCTFail("no further request is allowed after the remaining count reaches zero: \(request.url)")
            return HTTPResponse(statusCode: 500, headers: [:], body: Data())
        }
        let defaults = freshDefaults()
        let provider = CopilotProvider(
            authStore: editorTokenStore(),
            usageClient: CopilotUsageClient(http: http),
            orgBillingClient: CopilotOrgBillingClient(http: http),
            defaults: defaults,
            now: { clock }
        )

        _ = await provider.refresh()
        XCTAssertEqual(
            defaults.object(forKey: CopilotProvider.billingOrgRateLimitRetryAfterKey) as? Date,
            reset
        )
        XCTAssertEqual(http.requests.filter { $0.url.path == "/user/orgs" }.count, 1)

        _ = await provider.refresh()
        XCTAssertEqual(http.requests.filter { $0.url.path == "/user/orgs" }.count, 1)
    }

    func testOrgSummaryRemainingZeroWithoutUsageStopsLaterOrgs() async {
        let clock = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = clock.addingTimeInterval(120)
        let http = RoutingHTTPClient { request in
            if request.url.absoluteString.contains("/copilot_internal/user") {
                return ok(makeBusinessPlaceholderBody())
            }
            if request.url.path == "/user/orgs" {
                return okJSON([["login": "first-org"], ["login": "second-org"]])
            }
            if request.url.path == "/orgs/first-org/settings/billing/usage/summary" {
                return HTTPResponse(
                    statusCode: 200,
                    headers: [
                        "X-RateLimit-Remaining": "0",
                        "X-RateLimit-Reset": String(Int(reset.timeIntervalSince1970))
                    ],
                    body: try! JSONSerialization.data(withJSONObject: ["usageItems": []])
                )
            }
            XCTFail("the exhausted response must stop before another org summary: \(request.url)")
            return HTTPResponse(statusCode: 500, headers: [:], body: Data())
        }
        let defaults = freshDefaults()
        let provider = CopilotProvider(
            authStore: editorTokenStore(),
            usageClient: CopilotUsageClient(http: http),
            orgBillingClient: CopilotOrgBillingClient(http: http),
            defaults: defaults,
            now: { clock }
        )

        _ = await provider.refresh()

        XCTAssertEqual(
            defaults.object(forKey: CopilotProvider.billingOrgRateLimitRetryAfterKey) as? Date,
            reset
        )
        XCTAssertEqual(http.requests.filter { $0.url.path.contains("/settings/billing/usage/summary") }.count, 1)
    }

    func testOrgSummaryRemainingZeroPreservesUsageAndCooldown() async {
        let clock = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = clock.addingTimeInterval(120)
        let http = RoutingHTTPClient { request in
            if request.url.absoluteString.contains("/copilot_internal/user") {
                return ok(makeBusinessPlaceholderBody())
            }
            if request.url.path == "/user/orgs" {
                return okJSON([["login": "acme"]])
            }
            if request.url.path == "/orgs/acme/settings/billing/usage/summary" {
                return HTTPResponse(
                    statusCode: 200,
                    headers: [
                        "X-RateLimit-Remaining": "0",
                        "X-RateLimit-Reset": String(Int(reset.timeIntervalSince1970))
                    ],
                    body: try! JSONSerialization.data(withJSONObject: makeOrgSummaryBody())
                )
            }
            XCTFail("the cached org must be paused until reset: \(request.url)")
            return HTTPResponse(statusCode: 500, headers: [:], body: Data())
        }
        let defaults = freshDefaults()
        let provider = CopilotProvider(
            authStore: editorTokenStore(),
            usageClient: CopilotUsageClient(http: http),
            orgBillingClient: CopilotOrgBillingClient(http: http),
            defaults: defaults,
            now: { clock }
        )

        let snapshot = await provider.refresh()
        XCTAssertNotNil(orgCount(snapshot.lines, "Org Credits"), "the successful summary remains usable")
        XCTAssertEqual(
            defaults.object(forKey: CopilotProvider.billingOrgRateLimitRetryAfterKey) as? Date,
            reset
        )

        _ = await provider.refresh()
        XCTAssertEqual(http.requests.filter { $0.url.path == "/orgs/acme/settings/billing/usage/summary" }.count, 1)
    }

    func testSecondaryRateLimitMessageOnOrgSummaryStopsFurtherOrgProbes() async {
        let clock = Date(timeIntervalSince1970: 1_800_000_000)
        let http = RoutingHTTPClient { request in
            if request.url.absoluteString.contains("/copilot_internal/user") {
                return ok(makeBusinessPlaceholderBody())
            }
            if request.url.path == "/user/orgs" {
                return okJSON([["login": "first-org"], ["login": "second-org"]])
            }
            if request.url.path == "/orgs/first-org/settings/billing/usage/summary" {
                return HTTPResponse(
                    statusCode: 403,
                    headers: [:],
                    body: try! JSONSerialization.data(withJSONObject: [
                        "message": "You have exceeded a secondary rate limit."
                    ])
                )
            }
            XCTFail("secondary rate limit must stop discovery before later orgs: \(request.url)")
            return HTTPResponse(statusCode: 500, headers: [:], body: Data())
        }
        let defaults = freshDefaults()
        let provider = CopilotProvider(
            authStore: editorTokenStore(),
            usageClient: CopilotUsageClient(http: http),
            orgBillingClient: CopilotOrgBillingClient(http: http),
            defaults: defaults,
            now: { clock }
        )

        _ = await provider.refresh()

        XCTAssertEqual(
            defaults.object(forKey: CopilotProvider.billingOrgRateLimitRetryAfterKey) as? Date,
            clock.addingTimeInterval(300),
            "when GitHub gives no reset or Retry-After, pause conservatively"
        )
        XCTAssertEqual(http.requests.filter { $0.url.path.contains("/settings/billing/usage/summary") }.count, 1)
    }

    func testCancellationOfFirstOrgSummaryStopsOrganizationProbing() async {
        let http = RoutingHTTPClient { request in
            let url = request.url.absoluteString
            if url.contains("/copilot_internal/user") {
                return ok(makeBusinessPlaceholderBody())
            }
            if url.contains("/user/orgs") {
                return okJSON([["login": "first-org"], ["login": "second-org"]])
            }
            if url.contains("/orgs/first-org/settings/billing/usage/summary") {
                throw CancellationError()
            }
            if url.contains("/orgs/second-org/settings/billing/usage/summary") {
                XCTFail("later orgs must not be queried after cancellation")
            }
            return HTTPResponse(statusCode: 404, headers: [:], body: Data())
        }
        let provider = makeOrgProvider(http: http, defaults: freshDefaults())

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .cancelled)
        XCTAssertEqual(http.requests.count, 3)
        XCTAssertFalse(http.requests.contains { $0.url.absoluteString.contains("second-org") })
    }

    func testTransientBillingFailureKeepsCachedOrg() async {
        // A 5xx from the cached org's billing endpoint is a brief outage, not a stale org: the cache
        // must survive (no re-discovery), and the refresh degrades to the plan-only card.
        let http = routedClient([
            ("/copilot_internal/user", ok(makeBusinessPlaceholderBody())),
            ("/orgs/acme/settings/billing/usage/summary", HTTPResponse(statusCode: 503, headers: [:], body: Data()))
        ])
        let defaults = freshDefaults()
        defaults.set("acme", forKey: CopilotProvider.billingOrgDefaultsKey)
        let provider = makeOrgProvider(http: http, defaults: defaults)

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertTrue(snapshot.lines.isEmpty)
        XCTAssertEqual(defaults.string(forKey: CopilotProvider.billingOrgDefaultsKey), "acme")
        XCTAssertFalse(http.requests.contains { $0.url.absoluteString.contains("/user/orgs") })
    }

    func testPersonalPaidAccountMakesNoOrgCalls() async {
        let http = routedClient([
            ("/copilot_internal/user", ok(makePaidBody()))
        ])
        let provider = makeOrgProvider(http: http, defaults: freshDefaults())

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(http.requests.count, 1)
    }

    private func makeOrgProvider(http: RoutingHTTPClient, defaults: UserDefaults) -> CopilotProvider {
        CopilotProvider(
            authStore: editorTokenStore(),
            usageClient: CopilotUsageClient(http: http),
            orgBillingClient: CopilotOrgBillingClient(http: http),
            defaults: defaults
        )
    }

    private func freshDefaults() -> UserDefaults {
        let suiteName = "CopilotProviderTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func editorTokenStore() -> CopilotAuthStore {
        CopilotAuthStore(
            files: FakeFiles([CopilotAuthStore.editorAppsPath: #"{ "github.com": { "oauth_token": "gho_editor" } }"#]),
            keychain: FakeKeychain()
        )
    }
}

// MARK: - Helpers

/// A `RoutingHTTPClient` answering with the first response whose URL-substring key matches; unmatched
/// URLs 404.
private func routedClient(_ routes: [(substring: String, response: HTTPResponse)]) -> RoutingHTTPClient {
    RoutingHTTPClient { request in
        routes.first(where: { request.url.absoluteString.contains($0.substring) })?.response
            ?? HTTPResponse(statusCode: 404, headers: [:], body: Data())
    }
}

/// The exact `/copilot_internal/user` shape of an org-managed Copilot Business seat from issue #839:
/// plan is reported but every quota bucket is a zero-entitlement token-based-billing placeholder.
/// Crucially, the premium bucket carries `overage_permitted: true` — the field that used to sneak an
/// "Extra Usage: 0" row into the mapped lines and block the org-billing fallback.
private func makeBusinessPlaceholderBody() -> [String: Any] {
    func bucket(overagePermitted: Bool) -> [String: Any] {
        ["entitlement": 0, "remaining": 0, "unlimited": true,
         "overage_permitted": overagePermitted, "overage_count": 0]
    }
    return [
        "copilot_plan": "business",
        "token_based_billing": true,
        "quota_snapshots": [
            "chat": bucket(overagePermitted: false),
            "completions": bucket(overagePermitted: false),
            "premium_interactions": bucket(overagePermitted: true)
        ]
    ]
}

/// The org-managed placeholder body from issue #1094: same shape as `makeBusinessPlaceholderBody`, but
/// the premium bucket carries a real `credits_used` — the user's own per-seat consumption.
private func makeBusinessPlaceholderBodyWithPersonalCredits(_ creditsUsed: Double) -> [String: Any] {
    var body = makeBusinessPlaceholderBody()
    var quota = body["quota_snapshots"] as! [String: Any]
    var premium = quota["premium_interactions"] as! [String: Any]
    premium["credits_used"] = creditsUsed
    quota["premium_interactions"] = premium
    body["quota_snapshots"] = quota
    return body
}

/// The org billing usage summary from issue #839: one Copilot AI-unit item, fully covered by the
/// included credits.
private func makeOrgSummaryBody() -> [String: Any] {
    [
        "usageItems": [
            ["product": "Copilot", "sku": "copilot_ai_unit", "unitType": "ai-units",
             "grossQuantity": 298.698546, "netAmount": 0.0]
        ]
    ]
}

private func okJSON(_ array: [[String: Any]]) -> HTTPResponse {
    HTTPResponse(statusCode: 200, headers: [:], body: try! JSONSerialization.data(withJSONObject: array))
}

private func orgCount(_ lines: [MetricLine], _ label: String) -> Double? {
    value(lines, label: label, kind: .count)
}

private func orgDollars(_ lines: [MetricLine], _ label: String) -> Double? {
    value(lines, label: label, kind: .dollars)
}

private func value(_ lines: [MetricLine], label: String, kind: MetricKind) -> Double? {
    guard case .values(_, let values, _, _, _, _) = lines.first(where: { $0.label == label }) else {
        return nil
    }
    return values.first(where: { $0.kind == kind })?.number
}

private func makePaidBody() -> [String: Any] {
    [
        "copilot_plan": "pro",
        "quota_reset_date": "2099-01-15T00:00:00Z",
        "quota_snapshots": [
            "premium_interactions": ["entitlement": 300, "remaining": 123, "percent_remaining": 41, "quota_id": "premium"],
            "chat": ["entitlement": 1000, "remaining": 950, "percent_remaining": 95, "quota_id": "chat"]
        ]
    ]
}

private func ok(_ body: [String: Any]) -> HTTPResponse {
    HTTPResponse(statusCode: 200, headers: [:], body: try! JSONSerialization.data(withJSONObject: body))
}

private func progress(_ lines: [MetricLine], _ label: String) -> (used: Double, limit: Double, resetsAt: Date?, periodDurationMs: Int?)? {
    guard case .progress(_, let used, let limit, _, let resetsAt, let periodDurationMs, _, _) = lines.first(where: { $0.label == label }) else {
        return nil
    }
    return (used, limit, resetsAt, periodDurationMs)
}

private func countValue(_ lines: [MetricLine], _ label: String) -> Double? {
    guard case .values(_, let values, _, _, _, _) = lines.first(where: { $0.label == label }) else {
        return nil
    }
    return values.first?.number
}

private struct PartiallyUnreadableFiles: TextFileAccessing {
    var files: [String: String]
    var unreadable: Set<String>

    func exists(_ path: String) -> Bool {
        unreadable.contains(path) || files[path] != nil
    }

    func readText(_ path: String) throws -> String {
        if unreadable.contains(path) { throw CocoaError(.fileReadNoPermission) }
        guard let text = files[path] else { throw CocoaError(.fileReadNoSuchFile) }
        return text
    }

    func writeText(_ path: String, _ text: String) throws {}
    func remove(_ path: String) throws {}
}

private struct CancellationKeychain: KeychainAccessing {
    func readGenericPassword(service: String) throws -> String? { throw CancellationError() }
    func writeGenericPassword(service: String, value: String) throws {}
}

private final class CountingCopilotKeychain: KeychainAccessing, @unchecked Sendable {
    private let lock = NSLock()
    private var _readCount = 0
    private let value: String?

    init(_ value: String?) { self.value = value }

    var readCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _readCount
    }

    func readGenericPassword(service: String) throws -> String? {
        lock.lock(); _readCount += 1; lock.unlock()
        return value
    }

    func writeGenericPassword(service: String, value: String) throws {}
}

private final class InteractionRequiredCopilotKeychain: KeychainAccessing, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Bool] = []

    var calls: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    private func read(allowInteraction: Bool) throws -> String? {
        lock.lock()
        recorded.append(allowInteraction)
        lock.unlock()
        if !allowInteraction { throw KeychainError.interactionNotAllowed }
        return nil
    }

    func readGenericPassword(service: String) throws -> String? { try read(allowInteraction: true) }
    func readGenericPassword(service: String, allowInteraction: Bool) throws -> String? {
        try read(allowInteraction: allowInteraction)
    }
    func readGenericPassword(service: String, account: String) throws -> String? { try read(allowInteraction: true) }
    func readGenericPassword(service: String, account: String, allowInteraction: Bool) throws -> String? {
        try read(allowInteraction: allowInteraction)
    }
    func writeGenericPassword(service: String, value: String) throws {}
}

private func captureCopilotAuthStoreLogs(
    _ operation: () throws -> Void
) throws -> (error: Error?, logs: String) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("OpenUsageTests.CopilotCancellation.\(UUID().uuidString)", isDirectory: true)
    let sink = LogFile(directory: directory, fileName: "OpenUsage.log")
    sink.open()
    let originalSink = AppLog.sink
    AppLog.sink = sink
    AppLog.reloadLevel(.info)
    defer {
        AppLog.sink = originalSink
        AppLog.reloadLevel()
        try? FileManager.default.removeItem(at: directory)
    }

    var caught: Error?
    do { try operation() } catch { caught = error }
    return (caught, try String(contentsOf: sink.fileURL, encoding: .utf8))
}
