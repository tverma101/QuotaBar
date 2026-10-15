import XCTest
@testable import QuotaBar

final class CursorAuthStoreTests: XCTestCase {
    func testPrefersKeychainWhenSQLiteLooksFreeAndSubjectsDiffer() throws {
        let sqliteToken = makeCursorJWT(sub: "google-oauth2|sqlite-user")
        let keychainToken = makeCursorJWT(sub: "auth0|keychain-user")
        let sqlite = KeyValueSQLite(values: [
            CursorAuthStore.accessTokenKey: sqliteToken,
            CursorAuthStore.refreshTokenKey: "sqlite-refresh",
            CursorAuthStore.membershipTypeKey: "free"
        ])
        let keychain = ServiceKeychain(values: [
            CursorAuthStore.keychainAccessTokenService: keychainToken,
            CursorAuthStore.keychainRefreshTokenService: "keychain-refresh"
        ])
        let store = CursorAuthStore(sqlite: sqlite, keychain: keychain)

        let state = try store.loadAuthState()

        XCTAssertEqual(state?.source, .keychain)
        XCTAssertEqual(state?.accessToken, keychainToken)
        XCTAssertEqual(state?.refreshToken, "keychain-refresh")
    }

    func testPersistsSQLiteAccessToken() throws {
        let sqlite = KeyValueSQLite(values: [CursorAuthStore.accessTokenKey: "old-token"])
        let store = CursorAuthStore(sqlite: sqlite, keychain: FakeKeychain())
        let original = CursorAuthState(accessToken: "old-token", refreshToken: nil, source: .sqlite)

        try store.saveAccessToken("fresh-token", replacing: original)

        XCTAssertEqual(sqlite.writtenValues[CursorAuthStore.accessTokenKey], "fresh-token")
    }

    func testReadsQuotaBarRotatedCurrentUserKeychainTokenBeforeLegacyEntry() throws {
        let currentUserToken = makeCursorJWT(sub: "auth0|rotated-user")
        let legacyToken = makeCursorJWT(sub: "auth0|legacy-user")
        let keychain = ServiceKeychain(
            values: [CursorAuthStore.keychainAccessTokenService: legacyToken],
            currentUserValues: [CursorAuthStore.keychainAccessTokenService: currentUserToken]
        )
        let store = CursorAuthStore(sqlite: KeyValueSQLite(), keychain: keychain)

        let state = try store.loadAuthState()

        XCTAssertEqual(state?.source, .keychain)
        XCTAssertEqual(state?.accessToken, currentUserToken)
    }

    func testPersistsRotatedKeychainTokenUnderCurrentUserAccount() throws {
        let keychain = ServiceKeychain(currentUserValues: [
            CursorAuthStore.keychainAccessTokenService: "old-token",
            CursorAuthStore.keychainRefreshTokenService: "refresh-token"
        ])
        let store = CursorAuthStore(sqlite: KeyValueSQLite(), keychain: keychain)
        let original = CursorAuthState(accessToken: "old-token", refreshToken: "refresh-token", source: .keychain)

        try store.saveAccessToken("fresh-token", replacing: original)

        XCTAssertEqual(keychain.currentUserValues[CursorAuthStore.keychainAccessTokenService], "fresh-token")
    }

    func testSaveRefusesWhenEffectiveCursorSourceSwitchesToKeychain() throws {
        let sqlite = KeyValueSQLite(values: [
            CursorAuthStore.accessTokenKey: makeCursorJWT(sub: "google-oauth2|sqlite-user", exp: 0),
            CursorAuthStore.refreshTokenKey: "sqlite-refresh",
            CursorAuthStore.membershipTypeKey: "free"
        ])
        let keychain = ServiceKeychain()
        let store = CursorAuthStore(sqlite: sqlite, keychain: keychain)
        let original = try XCTUnwrap(store.loadAuthState())
        XCTAssertEqual(original.source, .sqlite)

        keychain.currentUserValues[CursorAuthStore.keychainAccessTokenService] = makeCursorJWT(
            sub: "auth0|keychain-user",
            exp: 0
        )
        keychain.currentUserValues[CursorAuthStore.keychainRefreshTokenService] = "keychain-refresh"

        XCTAssertThrowsError(try store.saveAccessToken("late-token", replacing: original)) { error in
            XCTAssertEqual(error as? CursorAuthError, .sessionExpired)
        }
        XCTAssertTrue(sqlite.writtenValues.isEmpty, "a changed preferred source must not receive the stale token")
    }

    func testCursorRotationPersistsAfterNewManualActionStartsWhenSourceMatches() async throws {
        let accessKey = KeychainItemKey(
            service: CursorAuthStore.keychainAccessTokenService,
            account: currentUserKeychainAccount()
        )
        let refreshKey = KeychainItemKey(
            service: CursorAuthStore.keychainRefreshTokenService,
            account: currentUserKeychainAccount()
        )
        KeychainPermissionGate.shared.reset(accessKey)
        KeychainPermissionGate.shared.reset(refreshKey)
        defer {
            KeychainPermissionGate.shared.reset(accessKey)
            KeychainPermissionGate.shared.reset(refreshKey)
        }
        let sqlite = KeyValueSQLite(values: [
            CursorAuthStore.accessTokenKey: makeCursorJWT(sub: "sqlite-user", exp: 0),
            CursorAuthStore.refreshTokenKey: "old-refresh"
        ])
        let store = CursorAuthStore(sqlite: sqlite, keychain: ServiceKeychain())
        let original = try XCTUnwrap(store.loadAuthState())
        let olderActionID = KeychainPermissionGate.shared.beginManualAction()
        let saveStarted = DispatchSemaphore(value: 0)
        let releaseSave = DispatchSemaphore(value: 0)
        defer { releaseSave.signal() }
        let save = Task.detached {
            try await ProviderRefreshContext.$isManual.withValue(true) {
                try await ProviderRefreshContext.$manualActionID.withValue(olderActionID) {
                    saveStarted.signal()
                    _ = releaseSave.wait(timeout: .now() + 5)
                    try store.saveAccessToken("rotated-access", replacing: original)
                }
            }
        }

        XCTAssertEqual(saveStarted.wait(timeout: .now() + 2), .success)
        _ = KeychainPermissionGate.shared.beginManualAction()
        releaseSave.signal()
        try await save.value

        XCTAssertEqual(sqlite.writtenValues[CursorAuthStore.accessTokenKey], "rotated-access")
    }

    func testBlockedKeychainRemedySurvivesExpiredSQLiteTokenWithoutRefreshToken() throws {
        let permissionKey = KeychainItemKey(
            service: CursorAuthStore.keychainAccessTokenService,
            account: currentUserKeychainAccount()
        )
        KeychainPermissionGate.shared.reset(permissionKey)
        defer { KeychainPermissionGate.shared.reset(permissionKey) }
        let keychain = CursorInteractionRequiredKeychain()
        let store = CursorAuthStore(
            sqlite: KeyValueSQLite(values: [
                CursorAuthStore.accessTokenKey: makeCursorJWT(sub: "sqlite-user", exp: 0)
            ]),
            keychain: keychain,
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        XCTAssertThrowsError(try store.loadAuthState()) { error in
            XCTAssertEqual(error as? CursorAuthError, .credentialPermissionRequired)
        }
        XCTAssertEqual(keychain.calls, [false], "the permission remedy comes from a silent probe only")
    }

    func testUnreadableStateDatabaseIsNotTreatedAsMissingAuth() throws {
        let store = CursorAuthStore(sqlite: UnreadableCursorSQLite(), keychain: ServiceKeychain())

        XCTAssertThrowsError(try store.loadAuthState()) { error in
            XCTAssertEqual(error as? CursorAuthError, .credentialsUnreadable)
        }
    }

    func testUnreadableStateDatabaseCanFallBackToKeychainAuth() throws {
        let token = makeCursorJWT(sub: "auth0|keychain-user")
        let store = CursorAuthStore(
            sqlite: UnreadableCursorSQLite(),
            keychain: ServiceKeychain(currentUserValues: [CursorAuthStore.keychainAccessTokenService: token])
        )

        let state = try XCTUnwrap(store.loadAuthState())

        XCTAssertEqual(state.source, .keychain)
        XCTAssertEqual(state.accessToken, token)
    }

    func testMissingStateDatabaseAndKeychainStillMeansNoAuth() throws {
        let store = CursorAuthStore(sqlite: KeyValueSQLite(), keychain: ServiceKeychain())

        XCTAssertNil(try store.loadAuthState())
    }

    func testBlockedFallbackKeychainIsNotRereadOrReloggedWhenSQLiteAuthWorks() throws {
        let service = CursorAuthStore.keychainAccessTokenService
        let key = KeychainItemKey(service: service, account: currentUserKeychainAccount())
        KeychainPermissionGate.shared.resetAll()
        defer { KeychainPermissionGate.shared.resetAll() }
        let keychain = CursorInteractionRequiredKeychain()
        let store = CursorAuthStore(
            sqlite: KeyValueSQLite(values: [CursorAuthStore.accessTokenKey: makeCursorJWT(sub: "sqlite-user")]),
            keychain: keychain
        )

        let (_, logs) = try captureCursorAuthStoreLogs {
            for _ in 0..<4 {
                XCTAssertEqual(try store.loadAuthState()?.source, .sqlite)
            }
        }

        XCTAssertEqual(keychain.calls, [false], "a remembered Keychain refusal must not be queried again")
        XCTAssertFalse(logs.contains("keychain credential unavailable; using the Cursor database"), logs)
        XCTAssertFalse(logs.contains("[INFO] [auth:cursor]"), logs)
        XCTAssertTrue(KeychainPermissionGate.shared.isBlocked(key))
    }
}

private final class CursorInteractionRequiredKeychain: KeychainAccessing, @unchecked Sendable {
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
    func readGenericPasswordForCurrentUser(service: String) throws -> String? { try read(allowInteraction: true) }
    func readGenericPasswordForCurrentUser(service: String, allowInteraction: Bool) throws -> String? {
        try read(allowInteraction: allowInteraction)
    }
    func writeGenericPassword(service: String, value: String) throws {}
}

private func captureCursorAuthStoreLogs(
    _ operation: () throws -> Void
) throws -> (error: Error?, logs: String) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("OpenUsageTests.CursorAuthStore.\(UUID().uuidString)", isDirectory: true)
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

final class CursorUsageMapperTests: XCTestCase {
    func testMapsGrokBotWeeklyUsageAndItsOwnResetWindow() throws {
        let line = try XCTUnwrap(CursorUsageMapper.mapGrokBotUsage([
            "usagePercent": 37.5,
            "currentPeriodStart": "2026-08-20T00:00:00Z",
            "nextResetTimestampUtc": "2026-08-27T00:00:00Z",
            "hasNonZeroIncludedLimit": true
        ]))

        let usage = try XCTUnwrap(progress([line], "Grok Bot usage"))
        XCTAssertEqual(usage.used, 37.5)
        XCTAssertEqual(usage.limit, 100)
        XCTAssertEqual(usage.resetsAt, OpenUsageISO8601.date(from: "2026-08-27T00:00:00Z"))
        XCTAssertEqual(usage.periodDurationMs, MetricPeriod.weekMs)
    }

    func testGrokBotUsageAllowsZeroAndClampsOverages() throws {
        let zero = try XCTUnwrap(CursorUsageMapper.mapGrokBotUsage(["usagePercent": 0]))
        let overage = try XCTUnwrap(CursorUsageMapper.mapGrokBotUsage(["usagePercent": 125]))

        XCTAssertEqual(progress([zero], "Grok Bot usage")?.used, 0)
        XCTAssertEqual(progress([zero], "Grok Bot usage")?.periodDurationMs, MetricPeriod.weekMs)
        XCTAssertEqual(progress([overage], "Grok Bot usage")?.used, 100)
    }

    func testGrokBotUsageRejectsPooledAndInvalidPersonalMeters() throws {
        XCTAssertNil(CursorUsageMapper.mapGrokBotUsage([
            "usagePercent": 42,
            "usesPooledEnterpriseAllowance": true
        ]))
        XCTAssertNil(CursorUsageMapper.mapGrokBotUsage([
            "usagePercent": 0,
            "hasNonZeroIncludedLimit": false
        ]))
        XCTAssertNil(CursorUsageMapper.mapGrokBotUsage([
            "usagePercent": 0,
            "includedLimitZero": true
        ]))
        XCTAssertNil(CursorUsageMapper.mapGrokBotUsage(["usagePercent": true]))
        XCTAssertNil(CursorUsageMapper.mapGrokBotUsage(["usagePercent": -1]))
        XCTAssertNil(CursorUsageMapper.mapGrokBotUsage(["hasNonZeroIncludedLimit": true]))
    }

    func testMapsCreditsUsageBreakdownAndOnDemand() throws {
        let mapped = try CursorUsageMapper.mapUsage(
            usage: [
                "enabled": true,
                "billingCycleStart": 1_770_000_000_000,
                "billingCycleEnd": 1_772_592_000_000,
                "planUsage": [
                    "limit": 40_000,
                    "remaining": 32_000,
                    "totalPercentUsed": 20,
                    "autoPercentUsed": 12.5,
                    "apiPercentUsed": 7.5
                ],
                "spendLimitUsage": [
                    "individualLimit": 5_000,
                    "individualRemaining": 1_000
                ]
            ],
            planName: "pro plan",
            creditGrants: [
                "hasCreditGrants": true,
                "totalCents": "1000000",
                "usedCents": "264729"
            ],
            stripeBalanceCents: 991_544
        )

        XCTAssertEqual(mapped.plan, "Pro Plan")
        XCTAssertEqual(try XCTUnwrap(dollarValue(mapped.lines, "Credits")), 17268.15, accuracy: 0.001)
        XCTAssertEqual(progress(mapped.lines, "Total usage")?.used, 20)
        XCTAssertEqual(progress(mapped.lines, "Cursor Models")?.used, 12.5)
        XCTAssertEqual(progress(mapped.lines, "Other Models")?.used, 7.5)
        XCTAssertEqual(progress(mapped.lines, "On-demand")?.used, 40)
    }

    func testBoundedOnDemandDoesNotLetZeroSpendMaskPositiveUsage() throws {
        let mapped = try CursorUsageMapper.mapUsage(
            usage: [
                "enabled": true,
                "billingCycleStart": 1_770_000_000_000,
                "billingCycleEnd": 1_772_592_000_000,
                "planUsage": [
                    "limit": 40_000,
                    "totalPercentUsed": 20
                ],
                "spendLimitUsage": [
                    "individualLimit": 5_000,
                    "individualRemaining": 4_500,
                    "individualUsed": 0,
                    "totalSpend": 1_200
                ]
            ],
            planName: "Ultra",
            creditGrants: nil,
            stripeBalanceCents: 0
        )

        XCTAssertEqual(progress(mapped.lines, "On-demand")?.used, 12)
    }

    func testMapsSpendOnlyOnDemandAsUnboundedUsage() throws {
        let mapped = try CursorUsageMapper.mapUsage(
            usage: [
                "enabled": true,
                "billingCycleStart": 1_781_438_541_000,
                "billingCycleEnd": 1_784_030_541_000,
                "planUsage": [
                    "limit": 40_000,
                    "totalPercentUsed": 26.346,
                    "totalSpend": 52_692
                ],
                "spendLimitUsage": [
                    "individualUsed": 16_474,
                    "limitType": "user",
                    "totalSpend": 16_474
                ]
            ],
            planName: "Ultra",
            creditGrants: nil,
            stripeBalanceCents: 790_964
        )

        XCTAssertNil(progress(mapped.lines, "On-demand"))
        XCTAssertEqual(try XCTUnwrap(dollarValue(mapped.lines, "On-demand")), 164.74, accuracy: 0.001)
    }

    func testMapsRequestBasedFallback() throws {
        let mapped = try CursorUsageMapper.mapRequestBasedUsage(
            [
                "gpt-4": [
                    "numRequests": 39,
                    "maxRequestUsage": 500
                ],
                "startOfMonth": "2026-02-09T17:36:37.000Z"
            ],
            planName: "Team",
            unavailableMessage: "unavailable"
        )

        XCTAssertEqual(mapped.plan, "Team")
        XCTAssertEqual(progress(mapped.lines, "Requests")?.used, 39)
        XCTAssertEqual(progress(mapped.lines, "Requests")?.limit, 500)
        XCTAssertEqual(progress(mapped.lines, "Requests")?.periodDurationMs, CursorUsageMapper.billingPeriodMs)
    }

    func testTeamAccountEmitsDollarTotalUsageAndNoOrphanedBonusSpendLine() throws {
        // Team accounts report Total usage as a dollar meter and may carry a `bonusSpend` field. No
        // widget descriptor matches a "Bonus spend" label, so emitting one produced a line that could
        // never render. Regression: the mapper must not emit that orphaned line even when bonusSpend > 0.
        let mapped = try CursorUsageMapper.mapUsage(
            usage: [
                "enabled": true,
                "billingCycleStart": 1_770_000_000_000,
                "billingCycleEnd": 1_772_592_000_000,
                "planUsage": [
                    "limit": 40_000,
                    "totalSpend": 10_000,
                    "bonusSpend": 2_500
                ]
            ],
            planName: "Team",
            creditGrants: nil,
            stripeBalanceCents: 0
        )

        XCTAssertEqual(mapped.plan, "Team")
        let total = try XCTUnwrap(progress(mapped.lines, "Total usage"))
        XCTAssertEqual(total.used, 100, accuracy: 0.001)    // $100.00 spent (totalSpend, cents → dollars)
        XCTAssertEqual(total.limit, 400, accuracy: 0.001)   // of a $400.00 limit
        XCTAssertFalse(mapped.lines.contains { $0.label == "Bonus spend" })
    }

    func testTeamBooleanTotalSpendFallsBackToLimitMinusRemaining() throws {
        let mapped = try CursorUsageMapper.mapUsage(
            usage: [
                "enabled": true,
                "planUsage": [
                    "limit": 40_000,
                    "remaining": 32_000,
                    "totalSpend": true
                ]
            ],
            planName: "Team",
            creditGrants: nil,
            stripeBalanceCents: 0
        )

        let total = try XCTUnwrap(progress(mapped.lines, "Total usage"))
        XCTAssertEqual(total.used, 80, accuracy: 0.001)
        XCTAssertEqual(total.limit, 400, accuracy: 0.001)
    }
}

@MainActor
final class CursorProviderTests: XCTestCase {
    func testModelCategoryDescriptorsMatchDashboardAndKeepStableIdentifiers() throws {
        let descriptors = CursorProvider().widgetDescriptors
        XCTAssertEqual(Array(descriptors.prefix(4).map(\.id)), [
            "cursor.usage", "cursor.auto", "cursor.api", "cursor.grokBot"
        ])

        let totalUsage = try XCTUnwrap(descriptors.first { $0.id == "cursor.usage" })
        XCTAssertEqual(totalUsage.title, "Total Usage")

        let grokBot = try XCTUnwrap(descriptors.first { $0.id == "cursor.grokBot" })
        XCTAssertEqual(grokBot.title, "Grok Bot")
        XCTAssertEqual(grokBot.limitResources.map(\.key), ["grokBot"])

        let cursorModels = try XCTUnwrap(descriptors.first { $0.id == "cursor.auto" })
        XCTAssertEqual(cursorModels.title, "Cursor Models")
        XCTAssertEqual(cursorModels.metricLabel, "Cursor Models")
        XCTAssertEqual(cursorModels.limitResources.map(\.key), ["autoUsage"])

        let otherModels = try XCTUnwrap(descriptors.first { $0.id == "cursor.api" })
        XCTAssertEqual(otherModels.title, "Other Models")
        XCTAssertEqual(otherModels.metricLabel, "Other Models")
        XCTAssertEqual(otherModels.limitResources.map(\.key), ["apiUsage"])
    }

    func testUnreadableStateDatabaseKeepsProviderVisibleAndReportsCredentialAccess() async {
        let http = RoutingHTTPClient { _ in
            XCTFail("credential loading should stop before network access")
            return HTTPResponse(statusCode: 500, headers: [:], body: Data())
        }
        let provider = CursorProvider(
            authStore: CursorAuthStore(sqlite: UnreadableCursorSQLite(), keychain: ServiceKeychain()),
            usageClient: CursorUsageClient(http: http)
        )

        let detected = await provider.hasLocalCredentials()
        XCTAssertTrue(detected)
        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .credentialAccess)
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testRefreshFetchesLiveCursorUsage() async {
        let accessToken = makeCursorJWT(sub: "google-oauth2|user_abc123")
        let http = RoutingHTTPClient { request in
            let url = request.url.absoluteString
            if url.contains("GetCurrentPeriodUsage") {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data("""
                {
                  "enabled": true,
                  "billingCycleEnd": 1772592000000,
                  "planUsage": {
                    "limit": 40000,
                    "remaining": 32000,
                    "totalPercentUsed": 20,
                    "autoPercentUsed": 12.5,
                    "apiPercentUsed": 7.5
                  },
                  "spendLimitUsage": {
                    "individualLimit": 5000,
                    "individualRemaining": 1000
                  }
                }
                """.utf8))
            }
            if url.contains("GetPlanInfo") {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"planInfo":{"planName":"pro plan"}}"#.utf8))
            }
            if url.contains("GetSandUsageStatus") {
                XCTAssertEqual(request.method, "POST")
                XCTAssertEqual(request.headers["Authorization"], "Bearer \(accessToken)")
                XCTAssertEqual(request.headers["Connect-Protocol-Version"], "1")
                return HTTPResponse(statusCode: 200, headers: [:], body: Data("""
                {
                  "usagePercent": 37.5,
                  "currentPeriodStart": "2026-08-20T00:00:00Z",
                  "nextResetTimestampUtc": "2026-08-27T00:00:00Z",
                  "hasNonZeroIncludedLimit": true
                }
                """.utf8))
            }
            if url.contains("GetCreditGrantsBalance") {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"hasCreditGrants":false}"#.utf8))
            }
            if url.contains("/api/auth/stripe") {
                XCTAssertEqual(request.headers["Cookie"], "WorkosCursorSessionToken=user_abc123%3A%3A\(accessToken)")
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"customerBalance":"-50000"}"#.utf8))
            }
            return HTTPResponse(statusCode: 404, headers: [:], body: Data())
        }
        let provider = CursorProvider(
            authStore: CursorAuthStore(
                sqlite: KeyValueSQLite(values: [CursorAuthStore.accessTokenKey: accessToken]),
                keychain: FakeKeychain()
            ),
            usageClient: CursorUsageClient(http: http),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.plan, "Pro Plan")
        XCTAssertEqual(dollarValue(snapshot.lines, "Credits") ?? -1, 500)
        XCTAssertEqual(progress(snapshot.lines, "Total usage")?.used, 20)
        XCTAssertEqual(progress(snapshot.lines, "Grok Bot usage")?.used, 37.5)
        XCTAssertEqual(
            progress(snapshot.lines, "Grok Bot usage")?.resetsAt,
            OpenUsageISO8601.date(from: "2026-08-27T00:00:00Z")
        )
        XCTAssertEqual(progress(snapshot.lines, "Cursor Models")?.used, 12.5)
        XCTAssertEqual(progress(snapshot.lines, "Other Models")?.used, 7.5)
        XCTAssertEqual(progress(snapshot.lines, "On-demand")?.used, 40)
    }

    func testRefreshTokenCancellationStopsBeforeUsageRequestWhenOldTokenExists() async {
        let http = RoutingHTTPClient { request in
            XCTAssertEqual(request.url, CursorUsageClient.refreshURL)
            throw CancellationError()
        }
        let provider = CursorProvider(
            authStore: CursorAuthStore(sqlite: KeyValueSQLite(values: [
                CursorAuthStore.accessTokenKey: makeCursorJWT(sub: "google-oauth2|user", exp: 0),
                CursorAuthStore.refreshTokenKey: "refresh-token"
            ]), keychain: FakeKeychain()),
            usageClient: CursorUsageClient(http: http)
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .cancelled)
        XCTAssertEqual(http.requests.map(\.url), [CursorUsageClient.refreshURL])
    }

    func testSuccessfulCursorRotationPersistsIfRefreshTaskIsCanceledBeforeSaveCompletes() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let oldAccess = makeCursorJWT(sub: "google-oauth2|user", exp: 0)
        let sqlite = KeyValueSQLite(values: [
            CursorAuthStore.accessTokenKey: oldAccess,
            CursorAuthStore.refreshTokenKey: "refresh-token"
        ])
        let gate = CursorRefreshResponseGate()
        let http = RoutingHTTPClient { request in
            guard request.url == CursorUsageClient.refreshURL else {
                XCTFail("a canceled refresh must stop before quota usage: \(request.url)")
                return HTTPResponse(statusCode: 500, headers: [:], body: Data())
            }
            await gate.pause()
            return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"access_token":"rotated-access"}"#.utf8))
        }
        let provider = CursorProvider(
            authStore: CursorAuthStore(sqlite: sqlite, keychain: ServiceKeychain(), now: { now }),
            usageClient: CursorUsageClient(http: http),
            now: { now }
        )
        let refresh = Task { await provider.refresh() }

        await gate.waitUntilPaused()
        refresh.cancel()
        await gate.open()

        let snapshot = await refresh.value
        XCTAssertEqual(snapshot.errorCategory, .cancelled)
        XCTAssertEqual(http.requests.map(\.url), [CursorUsageClient.refreshURL])
        XCTAssertEqual(sqlite.writtenValues[CursorAuthStore.accessTokenKey], "rotated-access")
    }

    func testLateRefreshDoesNotRecreateDeletedOrOverwriteSwitchedCursorLogin() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let oldAccessToken = makeCursorJWT(sub: "auth0|old-user", exp: 0)
        let switchedAccessToken = makeCursorJWT(sub: "auth0|new-user", exp: 0)
        let switchedState = [
            CursorAuthStore.accessTokenKey: switchedAccessToken,
            CursorAuthStore.refreshTokenKey: "new-refresh-token"
        ]

        for replacement in [Optional<[String: String]>.none, Optional(switchedState)] {
            let sqlite = KeyValueSQLite(values: [
                CursorAuthStore.accessTokenKey: oldAccessToken,
                CursorAuthStore.refreshTokenKey: "old-refresh-token"
            ])
            let gate = CursorRefreshResponseGate()
            let http = RoutingHTTPClient { request in
                guard request.url == CursorUsageClient.refreshURL else {
                    XCTFail("a late refresh must not issue usage requests with the old account: \(request.url)")
                    return HTTPResponse(statusCode: 500, headers: [:], body: Data())
                }
                await gate.pause()
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"access_token":"late-access-token"}"#.utf8))
            }
            let provider = CursorProvider(
                authStore: CursorAuthStore(sqlite: sqlite, keychain: FakeKeychain(), now: { now }),
                usageClient: CursorUsageClient(http: http),
                now: { now }
            )
            let refresh = Task { await provider.refresh() }

            await gate.waitUntilPaused()
            sqlite.values = replacement ?? [:]
            await gate.open()

            let snapshot = await refresh.value
            XCTAssertEqual(snapshot.errorCategory, .authExpired)
            XCTAssertEqual(http.requests.map(\.url), [CursorUsageClient.refreshURL])
            XCTAssertTrue(sqlite.writtenValues.isEmpty, "a deleted or switched login must not receive the late token")
            XCTAssertEqual(sqlite.values, replacement ?? [:], "the refresh must preserve logout or the replacement account")
        }
    }

    func testLateRefreshDoesNotWriteAfterCursorPreferredSourceChangesToKeychain() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let sqlite = KeyValueSQLite(values: [
            CursorAuthStore.accessTokenKey: makeCursorJWT(sub: "google-oauth2|sqlite-user", exp: 0),
            CursorAuthStore.refreshTokenKey: "sqlite-refresh",
            CursorAuthStore.membershipTypeKey: "free"
        ])
        let keychain = ServiceKeychain()
        let gate = CursorRefreshResponseGate()
        let http = RoutingHTTPClient { request in
            guard request.url == CursorUsageClient.refreshURL else {
                XCTFail("the late refresh must not issue usage requests with the old preferred source: \(request.url)")
                return HTTPResponse(statusCode: 500, headers: [:], body: Data())
            }
            await gate.pause()
            return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"access_token":"late-access-token"}"#.utf8))
        }
        let provider = CursorProvider(
            authStore: CursorAuthStore(sqlite: sqlite, keychain: keychain, now: { now }),
            usageClient: CursorUsageClient(http: http),
            now: { now }
        )
        let refresh = Task { await provider.refresh() }

        await gate.waitUntilPaused()
        keychain.currentUserValues[CursorAuthStore.keychainAccessTokenService] = makeCursorJWT(
            sub: "auth0|new-user",
            exp: 9_999_999_999
        )
        keychain.currentUserValues[CursorAuthStore.keychainRefreshTokenService] = "keychain-refresh"
        await gate.open()

        let snapshot = await refresh.value
        XCTAssertEqual(snapshot.errorCategory, .authExpired)
        XCTAssertEqual(http.requests.map(\.url), [CursorUsageClient.refreshURL])
        XCTAssertTrue(sqlite.writtenValues.isEmpty, "the stale SQLite source must not receive the late token")
    }

    func testExpiredCursorTokenIsNotUsedWhenRefreshReturnsServerError() async {
        let http = RoutingHTTPClient { request in
            if request.url == CursorUsageClient.refreshURL {
                return HTTPResponse(statusCode: 503, headers: [:], body: Data())
            }
            XCTFail("an expired access token must not be sent after refresh fails: \(request.url)")
            return HTTPResponse(statusCode: 200, headers: [:], body: Data())
        }
        let provider = CursorProvider(
            authStore: CursorAuthStore(
                sqlite: KeyValueSQLite(values: [
                    CursorAuthStore.accessTokenKey: makeCursorJWT(sub: "google-oauth2|user", exp: 0),
                    CursorAuthStore.refreshTokenKey: "refresh-token"
                ]),
                keychain: FakeKeychain(),
                now: { Date(timeIntervalSince1970: 1_800_000_000) }
            ),
            usageClient: CursorUsageClient(http: http),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .http5xx)
        XCTAssertEqual(http.requests.map(\.url), [CursorUsageClient.refreshURL])
    }

    func testPlanCancellationStopsBeforeOptionalCreditRequests() async {
        let accessToken = makeCursorJWT(sub: "google-oauth2|user")
        let http = RoutingHTTPClient { request in
            if request.url == CursorUsageClient.usageURL {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"enabled":true,"billingCycleEnd":1772592000000,"planUsage":{"limit":40000,"remaining":32000,"totalPercentUsed":20}}"#.utf8))
            }
            if request.url == CursorUsageClient.planURL {
                throw URLError(.cancelled)
            }
            XCTFail("optional Cursor endpoint must not run after cancellation: \(request.url)")
            return HTTPResponse(statusCode: 200, headers: [:], body: Data())
        }
        let provider = CursorProvider(
            authStore: CursorAuthStore(sqlite: KeyValueSQLite(values: [CursorAuthStore.accessTokenKey: accessToken]), keychain: FakeKeychain()),
            usageClient: CursorUsageClient(http: http)
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .cancelled)
        XCTAssertEqual(http.requests.map(\.url), [CursorUsageClient.usageURL, CursorUsageClient.planURL])
    }

    func testCancellationInsideFoldClockStopsBeforeAuthenticatedCSVRequest() async {
        let token = makeCursorJWT(sub: "google-oauth2|user")
        let http = RoutingHTTPClient { request in
            XCTFail("canceled fold must not start an authenticated request: \(request.url)")
            return HTTPResponse(statusCode: 200, headers: [:], body: Data())
        }
        let taskBox = CursorRefreshTaskBox()
        let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
        let provider = CursorProvider(
            authStore: CursorAuthStore(
                sqlite: KeyValueSQLite(values: [CursorAuthStore.accessTokenKey: token]),
                keychain: FakeKeychain()
            ),
            usageClient: CursorUsageClient(http: http),
            now: {
                taskBox.cancel()
                return fixedNow
            }
        )
        let refresh = Task {
            await ProviderRefreshContext.$scope.withValue(.panelAccounting) {
                await provider.refresh()
            }
        }
        taskBox.set(refresh)

        let snapshot = await refresh.value

        XCTAssertEqual(snapshot.errorCategory, .cancelled)
        XCTAssertTrue(http.requests.isEmpty)
    }
}

private final class CursorRefreshTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<ProviderSnapshot, Never>?

    func set(_ task: Task<ProviderSnapshot, Never>) {
        lock.lock()
        self.task = task
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        let task = self.task
        lock.unlock()
        task?.cancel()
    }
}

private actor CursorRefreshResponseGate {
    private var paused = false
    private var released = false
    private var pauseContinuation: CheckedContinuation<Void, Never>?
    private var enteredContinuation: CheckedContinuation<Void, Never>?

    func pause() async {
        paused = true
        enteredContinuation?.resume()
        enteredContinuation = nil
        guard !released else { return }
        await withCheckedContinuation { pauseContinuation = $0 }
    }

    func waitUntilPaused() async {
        guard !paused else { return }
        await withCheckedContinuation { enteredContinuation = $0 }
    }

    func open() {
        released = true
        pauseContinuation?.resume()
        pauseContinuation = nil
    }
}

private struct UnreadableCursorSQLite: SQLiteAccessing {
    func queryValue(path: String, sql: String) throws -> String? {
        throw SQLiteError.queryFailed("injected state database read failure")
    }

    func execute(path: String, sql: String) throws {}
}

private func progress(_ lines: [MetricLine], _ label: String) -> (used: Double, limit: Double, resetsAt: Date?, periodDurationMs: Int?)? {
    guard case .progress(_, let used, let limit, _, let resetsAt, let periodDurationMs, _, _) = lines.first(where: { $0.label == label }) else {
        return nil
    }
    return (used, limit, resetsAt, periodDurationMs)
}

private func dollarValue(_ lines: [MetricLine], _ label: String) -> Double? {
    guard case .values(_, let values, _, _, _, _) = lines.first(where: { $0.label == label }) else {
        return nil
    }
    return values.first { $0.kind == .dollars }?.number
}

// makeCursorJWT, KeyValueSQLite, and RoutingHTTPClient live in TestSupport.swift.
