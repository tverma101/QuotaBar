import XCTest
@testable import QuotaBar

@MainActor
final class GrokProviderTests: XCTestCase {
    func testPlanLabelIsReadOnceAndSurvivesAFailedRefresh() async {
        let clock = MutableClock(OpenUsageISO8601.date(from: "2026-02-02T01:00:00.000Z")!)
        let files = FakeFiles([
            GrokAuthStore.authPath: """
            {
              "https://auth.x.ai::client": {
                "key": "valid-token",
                "oidc_client_id": "client-id",
                "expires_at": "2026-06-01T00:00:00.000Z"
              }
            }
            """
        ])
        let settings = RequestCounter()
        let httpClient = RecordingHTTPClient { request in
            if request.url == GrokUsageClient.creditsConfigURL {
                return HTTPResponse(statusCode: 200, headers: [:], body: GrokCreditsFixtures.capturedResponseBody)
            }
            if request.url == GrokUsageClient.settingsURL {
                settings.value += 1
                if settings.failing {
                    return HTTPResponse(statusCode: 500, headers: [:], body: Data())
                }
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"subscription_tier_display":"SuperGrok Heavy"}"#.utf8))
            }
            return HTTPResponse(statusCode: 404, headers: [:], body: Data())
        }
        let provider = GrokProvider(
            authStore: GrokAuthStore(files: files, now: { clock.value }),
            usageClient: GrokUsageClient(httpClient: httpClient),
            logUsageScanner: noLogScanner(),
            now: { clock.value },
            pricing: { TestPricing.bundled }
        )

        let first = await provider.refresh()
        XCTAssertEqual(first.plan, "SuperGrok Heavy")

        let second = await provider.refresh()
        XCTAssertEqual(second.plan, "SuperGrok Heavy")
        XCTAssertEqual(settings.value, 1, "the plan label must not be re-read on every refresh")

        // Once the label is due again, a failed request keeps the last good one.
        settings.failing = true
        clock.value = clock.value.addingTimeInterval(GrokProvider.planCacheInterval + 60)
        let third = await provider.refresh()
        XCTAssertEqual(third.plan, "SuperGrok Heavy", "a failed plan request must not drop the label")
        XCTAssertEqual(settings.value, 2)
    }

    func testRefreshFormEncodesReservedCharactersInRequestBody() async throws {
        let httpClient = RecordingHTTPClient { _ in
            HTTPResponse(statusCode: 200, headers: [:], body: Data())
        }
        let client = GrokUsageClient(httpClient: httpClient)

        _ = try await client.refreshToken("refresh token&=+/?%", clientID: "client id&=+/?%")

        let request = try XCTUnwrap(httpClient.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.headers["Content-Type"], "application/x-www-form-urlencoded")
        XCTAssertEqual(
            String(data: try XCTUnwrap(request.body), encoding: .utf8),
            "grant_type=refresh_token&client_id=client%20id%26%3D%2B%2F%3F%25" +
                "&refresh_token=refresh%20token%26%3D%2B%2F%3F%25"
        )
    }

    func testRefreshesExpiredTokenPersistsAuthAndFetchesUsage() async {
        let now = OpenUsageISO8601.date(from: "2026-02-02T00:00:00.000Z")!
        let files = ThreadRecordingGrokFiles([
            GrokAuthStore.authPath: """
            {
              "https://auth.x.ai::client": {
                "key": "expired-token",
                "refresh_token": "refresh-token",
                "oidc_client_id": "client-id",
                "expires_at": "2026-01-01T00:00:00.000Z",
                "custom_field": "keep-me"
              }
            }
            """
        ])
        let httpClient = RecordingHTTPClient { request in
            if request.url == GrokUsageClient.refreshURL {
                XCTAssertEqual(request.method, "POST")
                XCTAssertEqual(String(data: request.body ?? Data(), encoding: .utf8), "grant_type=refresh_token&client_id=client-id&refresh_token=refresh-token")
                return HTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(#"{"access_token":"new-token","refresh_token":"new-refresh","expires_in":3600}"#.utf8)
                )
            }
            if request.url == GrokUsageClient.creditsConfigURL {
                XCTAssertEqual(request.headers["Authorization"], "Bearer new-token")
                XCTAssertEqual(request.headers["X-XAI-Token-Auth"], GrokUsageClient.tokenAuthHeader)
                return HTTPResponse(statusCode: 200, headers: [:], body: GrokCreditsFixtures.capturedResponseBody)
            }
            if request.url == GrokUsageClient.settingsURL {
                XCTAssertEqual(request.headers["Authorization"], "Bearer new-token")
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"subscription_tier_display":"SuperGrok Heavy"}"#.utf8))
            }
            return HTTPResponse(statusCode: 404, headers: [:], body: Data())
        }
        let provider = GrokProvider(
            authStore: GrokAuthStore(files: files, now: { now }),
            usageClient: GrokUsageClient(httpClient: httpClient),
            logUsageScanner: noLogScanner(),
            now: { now },
            pricing: { TestPricing.bundled }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.plan, "SuperGrok Heavy")
        XCTAssertEqual(progress(snapshot.lines, "Weekly limit")?.used, 99)
        XCTAssertEqual(badge(snapshot.lines, "Pay as you go")?.text, "Disabled")

        let saved = GrokAuthStore.parseAuth(files.text(at: GrokAuthStore.authPath) ?? "")
        let entry = saved?["https://auth.x.ai::client"]
        XCTAssertEqual(entry?.key, "new-token")
        XCTAssertEqual(entry?.refreshToken, "new-refresh")
        XCTAssertEqual(entry?.expiresAt, "2026-02-02T01:00:00.000Z")
        let savedObject = GrokAuthStore.parseJSONObject(files.text(at: GrokAuthStore.authPath) ?? "")
        let rawEntry = savedObject?["https://auth.x.ai::client"] as? [String: Any]
        XCTAssertEqual(rawEntry?["custom_field"] as? String, "keep-me")
        XCTAssertEqual(
            files.accesses.count,
            3,
            "credential load, save merge read, and rotated-token write should all go through the file seam"
        )
        XCTAssertTrue(
            files.accesses.allSatisfy { !$0.wasOnMainThread },
            "credential loading and rotated-token persistence must not run on the UI actor"
        )
    }

    func testRetriesCreditsOnceAfterAuthError() async {
        let now = OpenUsageISO8601.date(from: "2026-02-02T00:00:00.000Z")!
        let files = FakeFiles([
            GrokAuthStore.authPath: """
            {
              "https://auth.x.ai::client": {
                "key": "old-token",
                "refresh_token": "refresh-token",
                "expires_at": "2026-06-01T00:00:00.000Z"
              }
            }
            """
        ])
        var creditsCalls = 0
        let httpClient = RecordingHTTPClient { request in
            if request.url == GrokUsageClient.creditsConfigURL {
                creditsCalls += 1
                if creditsCalls == 1 {
                    return HTTPResponse(statusCode: 401, headers: [:], body: Data())
                }
                return HTTPResponse(statusCode: 200, headers: [:], body: GrokCreditsFixtures.capturedResponseBody)
            }
            if request.url == GrokUsageClient.refreshURL {
                return HTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(#"{"access_token":"new-token","refresh_token":"new-refresh","expires_in":3600}"#.utf8)
                )
            }
            if request.url == GrokUsageClient.settingsURL {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"subscription_tier_display":"SuperGrok Heavy"}"#.utf8))
            }
            return HTTPResponse(statusCode: 404, headers: [:], body: Data())
        }
        let provider = GrokProvider(
            authStore: GrokAuthStore(files: files, now: { now }),
            usageClient: GrokUsageClient(httpClient: httpClient),
            logUsageScanner: noLogScanner(),
            now: { now },
            pricing: { TestPricing.bundled }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.plan, "SuperGrok Heavy")
        let creditsAuths = httpClient.requests
            .filter { $0.url == GrokUsageClient.creditsConfigURL }
            .map { $0.headers["Authorization"] }
        XCTAssertEqual(creditsAuths, ["Bearer old-token", "Bearer new-token"])
        XCTAssertEqual(progress(snapshot.lines, "Weekly limit")?.used, 99)
    }

    func testAuthRejectionWithRefreshTransportFailureRemainsNetworkError() async {
        let httpClient = RecordingHTTPClient { request in
            if request.url == GrokUsageClient.creditsConfigURL {
                return HTTPResponse(statusCode: 401, headers: [:], body: Data())
            }
            if request.url == GrokUsageClient.refreshURL {
                throw URLError(.timedOut)
            }
            return HTTPResponse(statusCode: 404, headers: [:], body: Data())
        }

        let snapshot = await makeProvider(httpClient: httpClient).refresh()

        XCTAssertEqual(snapshot.errorCategory, .network)
        XCTAssertEqual(badge(snapshot.lines, "Error")?.text, GrokUsageError.connectionFailed.localizedDescription)
        XCTAssertEqual(httpClient.requests.filter { $0.url == GrokUsageClient.creditsConfigURL }.count, 1)
        XCTAssertEqual(httpClient.requests.filter { $0.url == GrokUsageClient.refreshURL }.count, 1)
    }

    func testAuthRejectionWithRefreshServerErrorRemainsRetryableHTTPError() async {
        let httpClient = RecordingHTTPClient { request in
            if request.url == GrokUsageClient.creditsConfigURL {
                return HTTPResponse(statusCode: 401, headers: [:], body: Data())
            }
            if request.url == GrokUsageClient.refreshURL {
                return HTTPResponse(statusCode: 503, headers: [:], body: Data())
            }
            return HTTPResponse(statusCode: 404, headers: [:], body: Data())
        }

        let snapshot = await makeProvider(httpClient: httpClient).refresh()

        XCTAssertEqual(snapshot.errorCategory, .http5xx)
        XCTAssertEqual(badge(snapshot.lines, "Error")?.text, GrokUsageError.requestFailed(503).localizedDescription)
        XCTAssertEqual(httpClient.requests.filter { $0.url == GrokUsageClient.creditsConfigURL }.count, 1)
        XCTAssertEqual(httpClient.requests.filter { $0.url == GrokUsageClient.refreshURL }.count, 1)
    }

    func testProactiveRefreshCancellationDoesNotUseTheOldToken() async {
        let now = TestLocalInstant.date(2026, 6, 18, 12)
        let files = FakeFiles([
            GrokAuthStore.authPath: #"{"https://auth.x.ai::client":{"key":"old-token","refresh_token":"refresh-token","expires_at":"2026-06-18T12:02:00.000Z"}}"#
        ])
        let httpClient = RecordingHTTPClient { request in
            if request.url == GrokUsageClient.refreshURL { throw URLError(.cancelled) }
            return HTTPResponse(statusCode: 200, headers: [:], body: GrokCreditsFixtures.capturedResponseBody)
        }
        let provider = GrokProvider(
            authStore: GrokAuthStore(files: files, now: { now }),
            usageClient: GrokUsageClient(httpClient: httpClient),
            logUsageScanner: noLogScanner(),
            now: { now },
            pricing: { TestPricing.bundled }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .cancelled)
        XCTAssertEqual(httpClient.requests.map(\.url), [GrokUsageClient.refreshURL])
    }

    func testCancellationWhilePersistingRotatedTokenStopsBeforeUsage() async {
        let now = TestLocalInstant.date(2026, 6, 18, 12)
        for phase in [GrokCancellationFiles.Phase.saveRead, .write] {
            let files = GrokCancellationFiles(
                initialText: #"{"https://auth.x.ai::client":{"key":"expired-token","refresh_token":"refresh-token","expires_at":"2026-06-18T11:00:00.000Z"}}"#,
                cancellationPhase: phase
            )
            let httpClient = RecordingHTTPClient { request in
                if request.url == GrokUsageClient.refreshURL {
                    return HTTPResponse(
                        statusCode: 200,
                        headers: [:],
                        body: Data(#"{"access_token":"new-token","refresh_token":"new-refresh","expires_in":3600}"#.utf8)
                    )
                }
                return HTTPResponse(statusCode: 200, headers: [:], body: GrokCreditsFixtures.capturedResponseBody)
            }
            let provider = GrokProvider(
                authStore: GrokAuthStore(files: files, now: { now }),
                usageClient: GrokUsageClient(httpClient: httpClient),
                logUsageScanner: noLogScanner(),
                now: { now },
                pricing: { TestPricing.bundled }
            )

            let snapshot = await provider.refresh()

            XCTAssertEqual(snapshot.errorCategory, .cancelled, "cancellation during \(phase) must not be reclassified")
            XCTAssertEqual(httpClient.requests.map(\.url), [GrokUsageClient.refreshURL], "cancellation during \(phase) must stop before credits")
        }
    }

    func testLateRefreshDoesNotRecreateDeletedOrOverwriteSwitchedGrokLogin() async {
        let now = TestLocalInstant.date(2026, 6, 18, 12)
        let path = GrokAuthStore.authPath
        let initialText = #"{"https://auth.x.ai::client":{"key":"expired-token","refresh_token":"old-refresh-token","expires_at":"2000-01-01T00:00:00.000Z"}}"#
        let switchedText = #"{"https://auth.x.ai::client":{"key":"new-account-token","refresh_token":"new-refresh-token","expires_at":"2099-01-01T00:00:00.000Z"}}"#

        for replacement in [Optional<String>.none, Optional(switchedText)] {
            let files = FakeFiles([path: initialText])
            let gate = GrokRefreshResponseGate()
            let http = RoutingHTTPClient { request in
                guard request.url == GrokUsageClient.refreshURL else {
                    XCTFail("a late refresh must not issue usage requests with the old account: \(request.url)")
                    return HTTPResponse(statusCode: 500, headers: [:], body: Data())
                }
                await gate.pause()
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"access_token":"late-access-token","refresh_token":"late-refresh-token","expires_in":3600}"#.utf8))
            }
            let provider = GrokProvider(
                authStore: GrokAuthStore(files: files, now: { now }),
                usageClient: GrokUsageClient(httpClient: http),
                logUsageScanner: noLogScanner(),
                now: { now },
                pricing: { TestPricing.bundled }
            )
            let refresh = Task { await provider.refresh() }

            await gate.waitUntilPaused()
            if let replacement {
                files.files[path] = replacement
            } else {
                files.files.removeValue(forKey: path)
            }
            await gate.open()

            let snapshot = await refresh.value
            XCTAssertEqual(snapshot.errorCategory, .authExpired)
            XCTAssertEqual(http.requests.map(\.url), [GrokUsageClient.refreshURL])
            XCTAssertEqual(files.files[path], replacement, "the late refresh must preserve logout or the replacement account")
        }
    }

    func testSuccessfulGrokRotationPersistsIfRefreshTaskIsCanceledBeforeUsageResumes() async {
        let now = TestLocalInstant.date(2026, 6, 18, 12)
        let files = FakeFiles([
            GrokAuthStore.authPath: #"{"https://auth.x.ai::client":{"key":"expired-token","refresh_token":"old-refresh","expires_at":"2000-01-01T00:00:00.000Z"}}"#
        ])
        let gate = GrokRefreshResponseGate()
        let http = RoutingHTTPClient { request in
            guard request.url == GrokUsageClient.refreshURL else {
                XCTFail("a canceled pass must stop before usage: \(request.url)")
                return HTTPResponse(statusCode: 500, headers: [:], body: Data())
            }
            await gate.pause()
            return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"access_token":"late-access","refresh_token":"late-refresh","expires_in":3600}"#.utf8))
        }
        let provider = GrokProvider(
            authStore: GrokAuthStore(files: files, now: { now }),
            usageClient: GrokUsageClient(httpClient: http),
            logUsageScanner: noLogScanner(),
            now: { now },
            pricing: { TestPricing.bundled }
        )
        let refresh = Task { await provider.refresh() }

        await gate.waitUntilPaused()
        refresh.cancel()
        await gate.open()

        let snapshot = await refresh.value
        XCTAssertEqual(snapshot.errorCategory, .cancelled)
        XCTAssertEqual(http.requests.map(\.url), [GrokUsageClient.refreshURL])
        let entry = GrokAuthStore.parseAuth(files.files[GrokAuthStore.authPath] ?? "")?[
            "https://auth.x.ai::client"
        ]
        XCTAssertEqual(entry?.key, "late-access")
        XCTAssertEqual(entry?.refreshToken, "late-refresh")
    }

    func testWeeklyMeterAndPayAsYouGoComeFromCreditsConfig() async {
        let httpClient = RecordingHTTPClient { request in
            if request.url == GrokUsageClient.creditsConfigURL {
                // The same plain GET the Grok CLI makes, with the standard auth headers.
                XCTAssertEqual(request.method, "GET")
                XCTAssertNil(request.body)
                XCTAssertEqual(request.headers["Authorization"], "Bearer token")
                XCTAssertEqual(request.headers["X-XAI-Token-Auth"], GrokUsageClient.tokenAuthHeader)
                XCTAssertEqual(request.headers["User-Agent"], "QuotaBar")
                return HTTPResponse(statusCode: 200, headers: [:], body: GrokCreditsFixtures.capturedResponseBody)
            }
            return Self.defaultRoutes(request)
        }
        let provider = makeProvider(httpClient: httpClient)

        let snapshot = await provider.refresh()

        XCTAssertEqual(progress(snapshot.lines, "Weekly limit")?.used, 99)
        XCTAssertEqual(progress(snapshot.lines, "Weekly limit")?.limit, 100)
        XCTAssertEqual(progress(snapshot.lines, "Weekly limit")?.resetsAt?.timeIntervalSince1970 ?? 0,
                       GrokCreditsFixtures.capturedPeriodEnd.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(badge(snapshot.lines, "Pay as you go")?.text, "Disabled")
        XCTAssertNil(snapshot.warning)
    }

    func testCreditsTransportAndSchemaFailuresFailTheProvider() async {
        let cases = [(503, ""), (200, #"{"config":{}}"#)]

        for (status, body) in cases {
            let httpClient = RecordingHTTPClient { request in
                if request.url == GrokUsageClient.creditsConfigURL {
                    return HTTPResponse(statusCode: status, headers: [:], body: Data(body.utf8))
                }
                return Self.defaultRoutes(request)
            }

            let snapshot = await makeProvider(httpClient: httpClient).refresh()

            XCTAssertNotNil(snapshot.errorCategory)
            XCTAssertNil(progress(snapshot.lines, "Weekly limit"))
        }
    }

    func testNonWeeklyPeriodShowsNoWeeklyLineAndNoWarning() async {
        // A not-yet-migrated (monthly-period) account is a valid state, not a failure: the Weekly
        // tile reads "No data" without the amber triangle, and the badge still renders.
        let httpClient = RecordingHTTPClient { request in
            if request.url == GrokUsageClient.creditsConfigURL {
                return HTTPResponse(statusCode: 200, headers: [:],
                                    body: GrokCreditsFixtures.responseBody(periodType: "USAGE_PERIOD_TYPE_MONTHLY"))
            }
            return Self.defaultRoutes(request)
        }
        let provider = makeProvider(httpClient: httpClient)

        let snapshot = await provider.refresh()

        XCTAssertNil(progress(snapshot.lines, "Weekly limit"))
        XCTAssertEqual(badge(snapshot.lines, "Pay as you go")?.text, "Disabled")
        XCTAssertNil(snapshot.warning)
        XCTAssertNil(snapshot.errorCategory)
    }

    func testRefreshAppendsLocalSpendTilesFromSessions() async throws {
        let now = TestLocalInstant.date(2026, 6, 18, 12)
        let home = try GrokLogFixture.makeHome(files: [
            "project/today/updates.jsonl": GrokLogFixture.completedTurn(
                timestamp: TestLocalInstant.iso(2026, 6, 18, 10),
                model: "grok-4.6-build",
                input: 1_000_000,
                costUsdTicks: 10_000_000_000
            ),
            "project/yesterday/updates.jsonl": GrokLogFixture.completedTurn(
                timestamp: TestLocalInstant.iso(2026, 6, 17, 10),
                model: "grok-4.5-build",
                input: 0,
                output: 1_000_000,
                costUsdTicks: 150_000_000_000
            )
        ])
        defer { try? FileManager.default.removeItem(at: home) }
        let scanner = GrokLogFixture.scanner(home: home)
        let provider = makeProvider(httpClient: RecordingHTTPClient(handler: Self.defaultRoutes), scanner: scanner, now: now)

        let snapshot = await provider.refresh()

        // Existing credit lines stay; the three spend tiles use Grok's recorded session costs.
        XCTAssertEqual(progress(snapshot.lines, "Weekly limit")?.used, 99)
        XCTAssertEqual(values(snapshot.lines, "Today"),
                       [MetricValue(number: 1.0, kind: .dollars, estimated: true), MetricValue(number: 1_000_000, kind: .count, label: "tokens")])
        XCTAssertEqual(values(snapshot.lines, "Yesterday"),
                       [MetricValue(number: 15.0, kind: .dollars, estimated: true), MetricValue(number: 1_000_000, kind: .count, label: "tokens")])
        XCTAssertEqual(values(snapshot.lines, "Last 30 Days"),
                       [MetricValue(number: 16.0, kind: .dollars, estimated: true), MetricValue(number: 2_000_000, kind: .count, label: "tokens")])

        guard case .chart(_, let points, let note) = snapshot.lines.first(where: { $0.label == "Usage Trend" }) else {
            return XCTFail("expected a Usage Trend chart line")
        }
        XCTAssertEqual(note, "From your Grok logs (estimated)")
        XCTAssertEqual(points.count, UsageHistoryWindow.totalDays)
        XCTAssertEqual(points.last?.value, 1_000_000)
        XCTAssertEqual(points[UsageHistoryWindow.totalDays - 2].value, 1_000_000)
    }

    func testPeriodWithoutUsageLeavesTileUnbacked() async throws {
        // Regression for the reported "Today 0" bug: a session has yesterday's usage, but no
        // turn completed today. An idle today is "No data" (no backing line), never a fabricated
        // "$0.00 · 0 tokens" that contradicts a live session. "No data" is also what a missing/unreadable
        // session produces — the two cases collapse to the same honest read.
        let now = TestLocalInstant.date(2026, 6, 18, 12)
        let home = try GrokLogFixture.makeHome(files: [
            "project/session/updates.jsonl": GrokLogFixture.completedTurn(
                timestamp: TestLocalInstant.iso(2026, 6, 17, 10),
                model: "grok-4.5-build",
                input: 0,
                output: 1_000_000,
                costUsdTicks: 150_000_000_000
            )
        ])
        defer { try? FileManager.default.removeItem(at: home) }
        let scanner = GrokLogFixture.scanner(home: home)
        let provider = makeProvider(httpClient: RecordingHTTPClient(handler: Self.defaultRoutes), scanner: scanner, now: now)

        let snapshot = await provider.refresh()

        // No usage today → "No data" (no Today line). Yesterday and the 30-day total still render.
        XCTAssertNil(values(snapshot.lines, "Today"))
        XCTAssertNotNil(values(snapshot.lines, "Yesterday"))
        XCTAssertNotNil(values(snapshot.lines, "Last 30 Days"))
    }

    func testRefreshWithoutSessionsAppendsNoUsageTrend() async {
        let provider = makeProvider(httpClient: RecordingHTTPClient(handler: Self.defaultRoutes))

        let snapshot = await provider.refresh()
        XCTAssertNil(snapshot.lines.first(where: { $0.label == "Usage Trend" }), "no sessions means no trend chart")
    }

    func testUnreadableAuthFileStaysDetectedAndRefreshShowsRepairMessage() async {
        let provider = GrokProvider(
            authStore: GrokAuthStore(files: UnreadableFiles(present: [GrokAuthStore.authPath])),
            usageClient: GrokUsageClient(httpClient: RecordingHTTPClient(handler: Self.defaultRoutes)),
            logUsageScanner: noLogScanner()
        )

        let detected = await provider.hasLocalCredentials()
        let snapshot = await provider.refresh()

        XCTAssertTrue(detected, "a present but unreadable auth file must remain visible to one-shot detection")
        XCTAssertEqual(snapshot.errorCategory, .credentialAccess)
        XCTAssertEqual(badge(snapshot.lines, "Error")?.text, GrokCredentialsUnreadableError().localizedDescription)
    }

    func testMalformedAuthFileStaysDetectedAndRefreshReportsInvalidAuth() async {
        let provider = GrokProvider(
            authStore: GrokAuthStore(files: FakeFiles([GrokAuthStore.authPath: "not json"])),
            usageClient: GrokUsageClient(httpClient: RecordingHTTPClient(handler: Self.defaultRoutes)),
            logUsageScanner: noLogScanner()
        )

        let detected = await provider.hasLocalCredentials()
        let snapshot = await provider.refresh()

        XCTAssertTrue(detected, "a present malformed auth file must remain visible to one-shot detection")
        XCTAssertEqual(snapshot.errorCategory, .authInvalid)
        XCTAssertEqual(badge(snapshot.lines, "Error")?.text, GrokAuthError.invalidAuth.localizedDescription)
    }

    /// The stock happy-path routes: the captured weekly credits config and the plan name.
    private static func defaultRoutes(_ request: HTTPRequest) -> HTTPResponse {
        if request.url == GrokUsageClient.creditsConfigURL {
            return HTTPResponse(statusCode: 200, headers: [:], body: GrokCreditsFixtures.capturedResponseBody)
        }
        if request.url == GrokUsageClient.settingsURL {
            return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"subscription_tier_display":"SuperGrok Heavy"}"#.utf8))
        }
        return HTTPResponse(statusCode: 404, headers: [:], body: Data())
    }

    private func makeProvider(
        httpClient: RecordingHTTPClient,
        scanner: GrokLogUsageScanner? = nil,
        now: Date = TestLocalInstant.date(2026, 6, 18, 12)
    ) -> GrokProvider {
        let files = FakeFiles([
            GrokAuthStore.authPath: #"{"https://auth.x.ai::client":{"key":"token","refresh_token":"refresh","expires_at":"2026-07-01T00:00:00.000Z"}}"#
        ])
        return GrokProvider(
            authStore: GrokAuthStore(files: files, now: { now }),
            usageClient: GrokUsageClient(httpClient: httpClient),
            logUsageScanner: scanner ?? noLogScanner(),
            now: { now },
            pricing: { TestPricing.bundled }
        )
    }

    private func noLogScanner() -> GrokLogUsageScanner {
        GrokLogFixture.scanner(home: nil)
    }

    private func values(_ lines: [MetricLine], _ label: String) -> [MetricValue]? {
        guard case .values(_, let values, _, _, _, _) = lines.first(where: { $0.label == label }) else { return nil }
        return values
    }
}

private actor GrokRefreshResponseGate {
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

@MainActor
final class GrokWidgetDataStoreTests: XCTestCase {
    func testResolvesBadgeSnapshotIntoWidgetText() async {
        let provider = Provider(id: "grok", displayName: "Grok", icon: .providerMark("grok"))
        let descriptor = WidgetDescriptor(
            id: "grok.payAsYouGo",
            providerID: provider.id,
            metricLabel: "Pay as you go",
            sample: WidgetData(title: "Pay as you go", icon: provider.icon, kind: .count, used: 0, limit: nil)
        )
        let runtime = TestProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.badge(label: "Pay as you go", text: "2500 cap", colorHex: "#22c55e")]
            )
        )
        let store = WidgetDataStore(registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]), providers: [runtime])

        await store.refreshAll()

        XCTAssertEqual(store.data(for: descriptor).valueText, "2500 cap")
    }
}

private final class RecordingHTTPClient: HTTPClient, @unchecked Sendable {
    var requests: [HTTPRequest] = []
    private let handler: (HTTPRequest) throws -> HTTPResponse

    init(handler: @escaping (HTTPRequest) throws -> HTTPResponse) {
        self.handler = handler
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        return try handler(request)
    }
}

/// A clock a test can move forward.
private final class MutableClock: @unchecked Sendable {
    var value: Date

    init(_ value: Date) {
        self.value = value
    }
}

/// A request counter a test can also make fail.
private final class RequestCounter: @unchecked Sendable {
    var value = 0
    var failing = false
}

private final class ThreadRecordingGrokFiles: TextFileAccessing, @unchecked Sendable {
    struct Access {
        let path: String
        let wasOnMainThread: Bool
    }

    private let lock = NSLock()
    private var contents: [String: String]
    private var recordedAccesses: [Access] = []

    var accesses: [Access] {
        lock.lock()
        defer { lock.unlock() }
        return recordedAccesses
    }

    init(_ contents: [String: String]) {
        self.contents = contents
    }

    func text(at path: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return contents[path]
    }

    func exists(_ path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return contents[path] != nil
    }

    func readTextIfPresent(_ path: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        recordedAccesses.append(Access(path: path, wasOnMainThread: Thread.isMainThread))
        return contents[path]
    }

    func readText(_ path: String) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        recordedAccesses.append(Access(path: path, wasOnMainThread: Thread.isMainThread))
        return contents[path] ?? ""
    }

    func writeText(_ path: String, _ text: String) throws {
        lock.lock()
        defer { lock.unlock() }
        recordedAccesses.append(Access(path: path, wasOnMainThread: Thread.isMainThread))
        contents[path] = text
    }

    func remove(_ path: String) throws {
        lock.lock()
        defer { lock.unlock() }
        recordedAccesses.append(Access(path: path, wasOnMainThread: Thread.isMainThread))
        contents.removeValue(forKey: path)
    }
}

private final class GrokCancellationFiles: TextFileAccessing, @unchecked Sendable {
    enum Phase: Equatable, CustomStringConvertible {
        case saveRead
        case write

        var description: String {
            switch self {
            case .saveRead: "auth merge read"
            case .write: "auth write"
            }
        }
    }

    private let lock = NSLock()
    private let initialText: String
    private let cancellationPhase: Phase
    private var readCount = 0

    init(initialText: String, cancellationPhase: Phase) {
        self.initialText = initialText
        self.cancellationPhase = cancellationPhase
    }

    func exists(_ path: String) -> Bool { true }

    func readTextIfPresent(_ path: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        readCount += 1
        if cancellationPhase == .saveRead, readCount > 1 {
            throw CancellationError()
        }
        return initialText
    }

    func readText(_ path: String) throws -> String {
        try readTextIfPresent(path) ?? ""
    }

    func writeText(_ path: String, _ text: String) throws {
        if cancellationPhase == .write { throw CancellationError() }
    }

    func remove(_ path: String) throws {}
}

private func progress(_ lines: [MetricLine], _ label: String) -> (used: Double, limit: Double, resetsAt: Date?)? {
    guard case .progress(_, let used, let limit, _, let resetsAt, _, _, _) = lines.first(where: { $0.label == label }) else {
        return nil
    }
    return (used, limit, resetsAt)
}

private func badge(_ lines: [MetricLine], _ label: String) -> (text: String, colorHex: String?)? {
    guard case .badge(_, let text, let colorHex, _) = lines.first(where: { $0.label == label }) else {
        return nil
    }
    return (text, colorHex)
}
