import XCTest
@testable import QuotaBar

/// End-to-end provider behavior: detection via the Go auth key or local usage, and a refresh that yields
/// the Go meters + combined spend tiles + trend, plus the not-logged-in path.
@MainActor
final class OpenCodeProviderTests: XCTestCase {

    /// Hermetic app-saved-key store: a fake path, so tests never read the real go-keys file
    /// (which lives in Application Support and is written by the running app).
    private func goKeyStoreStub() -> OpenCodeGoKeyStore {
        OpenCodeGoKeyStore(files: FakeFiles(), filePath: { "/oc/go-keys.json" })
    }
    private func d(_ iso: String) -> Date { OpenUsageISO8601.date(from: iso)! }
    private func epochMs(_ iso: String) -> Int { Int(d(iso).timeIntervalSince1970 * 1000) }
    private func row(_ iso: String, _ cost: String, _ tokens: Int, _ model: String, _ provider: String) -> String {
        "[\(epochMs(iso)),\(cost),\(tokens),\"\(model)\",\"\(provider)\"]"
    }
    private let authJSON = #"{"opencode-go":{"type":"api","key":"sk-test"}}"#

    private func authStore(files: TextFileAccessing) -> OpenCodeAuthStore {
        OpenCodeAuthStore(
            files: files,
            environment: FakeEnvironment(["OPENCODE_DATA_DIR": "/oc"]),
            homeDirectory: { URL(fileURLWithPath: "/nonexistent") }
        )
    }

    /// An account-usage client pinned to a canned response, so a test with a Go key never touches the
    /// network. The live-shaped payload mirrors the real `/zen/go/v1/usage` answer.
    private func usageClient(
        statusCode: Int = 200,
        body: Data = OpenCodeGoUsageClientTests.livePayloadFixture
    ) -> (client: OpenCodeGoUsageClient, http: FakeHTTPClient) {
        let http = FakeHTTPClient(response: HTTPResponse(statusCode: statusCode, headers: [:], body: body))
        return (OpenCodeGoUsageClient(http: http), http)
    }

    private func provider(
        authStore: OpenCodeAuthStore,
        usageScanner: OpenCodeUsageScanner,
        usageClient: OpenCodeGoUsageClient,
        now: @escaping @Sendable () -> Date = { TestLocalInstant.date(2026, 7, 12, 12) }
    ) -> OpenCodeProvider {
        OpenCodeProvider(authStore: authStore, usageScanner: usageScanner, usageClient: usageClient, now: now, goKeyStore: goKeyStoreStub(), activeKeyID: { nil })
    }

    func testHasLocalCredentialsViaGoAuthKey() async {
        let provider = OpenCodeProvider(
            authStore: authStore(files: FakeFiles(["/oc/auth.json": authJSON])),
            usageScanner: OpenCodeUsageScanner(sqlite: StubSQLite(), databasePaths: { [] }),
            goKeyStore: goKeyStoreStub(), activeKeyID: { nil }
        )
        let has = await provider.hasLocalCredentials()
        XCTAssertTrue(has)
    }

    func testGoKeySettingsFileAccessRunsOffMainActor() async throws {
        let files = ThreadRecordingOpenCodeFiles([
            "/oc/auth.json": authJSON,
            "/oc/go-keys.json": "[]"
        ])
        let provider = OpenCodeProvider(
            authStore: authStore(files: files),
            usageScanner: OpenCodeUsageScanner(sqlite: StubSQLite(), databasePaths: { [] }),
            goKeyStore: OpenCodeGoKeyStore(files: files, filePath: { "/oc/go-keys.json" }),
            activeKeyID: { nil }
        )

        let entries = await provider.goKeyEntries()
        let saved = try await provider.saveGoKey(label: "Work", key: "sk-local")
        try await provider.removeGoKey(id: saved.id)

        XCTAssertEqual(entries.map(\.label), ["opencode-go"])
        XCTAssertTrue(
            files.accesses.allSatisfy { !$0.wasOnMainThread },
            "settings reads and saved-key file mutations should run outside the UI actor"
        )
        XCTAssertTrue(files.accesses.contains { $0.path == "/oc/auth.json" })
        XCTAssertTrue(files.accesses.contains { $0.path == "/oc/go-keys.json" })
    }

    func testHasLocalCredentialsViaLocalUsage() async {
        let db = "[" + row(TestLocalInstant.iso(2026, 7, 12, 10, 0, 0), "1.0", 500, "gpt-5.5", "opencode") + "]"
        let provider = OpenCodeProvider(
            authStore: authStore(files: FakeFiles()),
            usageScanner: OpenCodeUsageScanner(
                sqlite: StubSQLite(data: ["/oc/opencode.db": db]),
                databasePaths: { ["/oc/opencode.db"] }
            ),
            goKeyStore: goKeyStoreStub(), activeKeyID: { nil }
        )
        let has = await provider.hasLocalCredentials()
        XCTAssertTrue(has)
    }

    func testHasLocalCredentialsFalseWhenAbsent() async {
        let provider = OpenCodeProvider(
            authStore: authStore(files: FakeFiles()),
            usageScanner: OpenCodeUsageScanner(
                sqlite: StubSQLite(data: ["/oc/opencode.db": "[]"]),
                databasePaths: { ["/oc/opencode.db"] }
            ),
            goKeyStore: goKeyStoreStub(), activeKeyID: { nil }
        )
        let has = await provider.hasLocalCredentials()
        XCTAssertFalse(has)
    }

    func testRefreshProducesMetersTilesAndTrend() async {
        let now = d(TestLocalInstant.iso(2026, 7, 12, 12, 0, 0))
        let db = "[" + [
            row(TestLocalInstant.iso(2026, 7, 12, 11, 0, 0), "2.0", 1000, "glm-5.2", "opencode-go"),
            row(TestLocalInstant.iso(2026, 7, 12, 10, 0, 0), "1.0", 500, "gpt-5.5", "opencode")
        ].joined(separator: ",") + "]"
        let (client, _) = usageClient()
        let provider = OpenCodeProvider(
            authStore: authStore(files: FakeFiles(["/oc/auth.json": authJSON])),
            usageScanner: OpenCodeUsageScanner(
                sqlite: StubSQLite(data: ["/oc/opencode.db": db]),
                databasePaths: { ["/oc/opencode.db"] }
            ),
            usageClient: client,
            now: { now },
            goKeyStore: goKeyStoreStub(), activeKeyID: { nil }
        )
        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.plan, "Go")
        XCTAssertNil(snapshot.errorCategory)
        guard case let .progress(_, sessionUsed, sessionLimit, sessionFormat, _, _, _, _)? = snapshot.line(label: "Session") else {
            return XCTFail("expected a Session meter")
        }
        // The account API answers: the meters show its authoritative percentages, not local spend.
        XCTAssertEqual(sessionUsed, 4)
        XCTAssertEqual(sessionLimit, 100)
        XCTAssertEqual(sessionFormat, .percent)
        XCTAssertNotNil(snapshot.line(label: "Weekly"))
        XCTAssertNotNil(snapshot.line(label: "Monthly"))
        XCTAssertNotNil(snapshot.line(label: "Usage Trend"))
        XCTAssertNotNil(snapshot.line(label: "Today"))
    }

    func testRefreshNotLoggedInWhenNoKeyAndNoDatabase() async {
        let now = d(TestLocalInstant.iso(2026, 7, 12, 12, 0, 0))
        let provider = OpenCodeProvider(
            authStore: authStore(files: FakeFiles()),
            usageScanner: OpenCodeUsageScanner(sqlite: StubSQLite(), databasePaths: { [] }),
            now: { now },
            goKeyStore: goKeyStoreStub(), activeKeyID: { nil }
        )
        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
    }

    func testKeyAloneDoesNotShowGoPlanWhenAccountRequestIsUnauthorized() async {
        // A saved key is only a credential candidate. It must not establish a Go plan when the account
        // endpoint rejects it and there is no local usage to fall back to.
        let now = d(TestLocalInstant.iso(2026, 7, 12, 12, 0, 0))
        let (client, _) = usageClient(statusCode: 401)
        let provider = OpenCodeProvider(
            authStore: authStore(files: FakeFiles(["/oc/auth.json": authJSON])),
            usageScanner: OpenCodeUsageScanner(sqlite: StubSQLite(), databasePaths: { [] }),
            usageClient: client,
            now: { now },
            goKeyStore: goKeyStoreStub(), activeKeyID: { nil }
        )
        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.errorCategory, .authExpired)
        XCTAssertNil(snapshot.plan)
        XCTAssertNil(snapshot.line(label: "Session"))
        XCTAssertNil(snapshot.line(label: "Weekly"))
        XCTAssertNil(snapshot.line(label: "Monthly"))
        XCTAssertNil(snapshot.warning)
    }

    func testAccountMetersUsedWhenAPIAnswers() async {
        // Account API answers AND the local DB has rows: meters come from the account (authoritative),
        // the spend tiles + trend still come from the local scan.
        let now = d(TestLocalInstant.iso(2026, 7, 12, 12, 0, 0))
        let db = "[" + row(TestLocalInstant.iso(2026, 7, 12, 11, 0, 0), "2.0", 1000, "glm-5.2", "opencode-go") + "]"
        let (client, _) = usageClient()
        let provider = OpenCodeProvider(
            authStore: authStore(files: FakeFiles(["/oc/auth.json": authJSON])),
            usageScanner: OpenCodeUsageScanner(
                sqlite: StubSQLite(data: ["/oc/opencode.db": db]),
                databasePaths: { ["/oc/opencode.db"] }
            ),
            usageClient: client,
            now: { now },
            goKeyStore: goKeyStoreStub(), activeKeyID: { nil }
        )
        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.plan, "Go")
        XCTAssertNil(snapshot.errorCategory)
        guard case .progress(_, let sessionUsed, _, let format, _, _, _, _)? = snapshot.line(label: "Session") else {
            return XCTFail("expected a Session meter")
        }
        XCTAssertEqual(sessionUsed, 4) // account rolling percent, not 2.0/12 local
        XCTAssertEqual(format, .percent)
        guard case .progress(_, let weeklyUsed, _, _, _, _, _, _)? = snapshot.line(label: "Weekly") else {
            return XCTFail("expected a Weekly meter")
        }
        XCTAssertEqual(weeklyUsed, 25)
        XCTAssertNotNil(snapshot.line(label: "Today")) // local spend tile still present
    }

    func testAPIUnavailableHidesGoCapsButKeepsLocalSpend() async {
        // Local history is not proof of an active Go entitlement, even during an API outage.
        let now = d(TestLocalInstant.iso(2026, 7, 12, 12, 0, 0))
        let db = "[" + row(TestLocalInstant.iso(2026, 7, 12, 11, 0, 0), "2.0", 1000, "glm-5.2", "opencode-go") + "]"
        let (client, http) = usageClient(statusCode: 503)
        let provider = OpenCodeProvider(
            authStore: authStore(files: FakeFiles(["/oc/auth.json": authJSON])),
            usageScanner: OpenCodeUsageScanner(
                sqlite: StubSQLite(data: ["/oc/opencode.db": db]),
                databasePaths: { ["/oc/opencode.db"] }
            ),
            usageClient: client,
            now: { now },
            goKeyStore: goKeyStoreStub(), activeKeyID: { nil }
        )
        let snapshot = await provider.refresh()
        XCTAssertNil(snapshot.plan)
        XCTAssertNotNil(snapshot.warning)
        XCTAssertEqual(snapshot.clearsPriorMenuBarQuotaState, true)
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertNil(snapshot.line(label: "Session"))
        XCTAssertNil(snapshot.line(label: "Weekly"))
        XCTAssertNil(snapshot.line(label: "Monthly"))
        XCTAssertNotNil(snapshot.line(label: "Today"), "local spend remains visible during an API outage")
    }

    func testPartialAccountPayloadDoesNotPresentGoCapMetersAsVerified() async {
        // A malformed 200 is not proof of an active Go entitlement, so only spend history remains.
        let now = d(TestLocalInstant.iso(2026, 7, 12, 12, 0, 0))
        let db = "[" + row(TestLocalInstant.iso(2026, 7, 12, 11, 0, 0), "3.0", 1000, "glm-5.2", "opencode-go") + "]"
        let partial = Data(#"{"usage":{"rolling":{"status":"ok","percent":4,"resetsAt":TestLocalInstant.iso(2026, 8, 12, 3, 53, 0)},"weekly":{"status":"ok","percent":25,"resetsAt":TestLocalInstant.iso(2026, 8, 17, 0, 0, 0)}}}"#.utf8)
        let (client, _) = usageClient(body: partial)
        let provider = OpenCodeProvider(
            authStore: authStore(files: FakeFiles(["/oc/auth.json": authJSON])),
            usageScanner: OpenCodeUsageScanner(
                sqlite: StubSQLite(data: ["/oc/opencode.db": db]),
                databasePaths: { ["/oc/opencode.db"] }
            ),
            usageClient: client,
            now: { now },
            goKeyStore: goKeyStoreStub(), activeKeyID: { nil }
        )
        let snapshot = await provider.refresh()
        XCTAssertNil(snapshot.plan)
        XCTAssertNil(snapshot.line(label: "Session"))
        XCTAssertNotNil(snapshot.line(label: "Today"))
        XCTAssertNotNil(snapshot.warning)
    }

    func testNoAPIWithoutGoKey() async {
        // A Zen-only account with old local opencode-go rows still has no current Go account to meter.
        // The account endpoint must not be called, and history must not fabricate plan caps.
        let now = d(TestLocalInstant.iso(2026, 7, 12, 12, 0, 0))
        let db = "[" + [
            row(TestLocalInstant.iso(2026, 7, 12, 11, 0, 0), "2.0", 1_000, "glm-5.2", "opencode-go"),
            row(TestLocalInstant.iso(2026, 7, 12, 10, 0, 0), "1.0", 500, "gpt-5.5", "opencode")
        ].joined(separator: ",") + "]"
        let (client, http) = usageClient()
        let provider = OpenCodeProvider(
            authStore: authStore(files: FakeFiles()),
            usageScanner: OpenCodeUsageScanner(
                sqlite: StubSQLite(data: ["/oc/opencode.db": db]),
                databasePaths: { ["/oc/opencode.db"] }
            ),
            usageClient: client,
            now: { now },
            goKeyStore: goKeyStoreStub(), activeKeyID: { nil }
        )
        let snapshot = await provider.refresh()
        XCTAssertNil(snapshot.plan)
        XCTAssertTrue(http.requests.isEmpty)
        XCTAssertNil(snapshot.line(label: "Session"))
        XCTAssertNil(snapshot.line(label: "Weekly"))
        XCTAssertNil(snapshot.line(label: "Monthly"))
        XCTAssertNotNil(snapshot.line(label: "Today"))
        XCTAssertEqual(snapshot.clearsPriorMenuBarQuotaState, true)
    }

    func testAccountMetersShowWithoutLocalDatabase() async {
        // Go key + working account API + no local database: account meters still render (the tiles
        // can't — there's no local data to read — but the plan and meters are account-wide facts).
        let now = d(TestLocalInstant.iso(2026, 7, 12, 12, 0, 0))
        let (client, _) = usageClient()
        let provider = OpenCodeProvider(
            authStore: authStore(files: FakeFiles(["/oc/auth.json": authJSON])),
            usageScanner: OpenCodeUsageScanner(sqlite: StubSQLite(), databasePaths: { [] }),
            usageClient: client,
            now: { now },
            goKeyStore: goKeyStoreStub(), activeKeyID: { nil }
        )
        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.plan, "Go")
        XCTAssertNil(snapshot.errorCategory)
        guard case .progress(_, let sessionUsed, _, let format, _, _, _, _)? = snapshot.line(label: "Session") else {
            return XCTFail("expected a Session meter")
        }
        XCTAssertEqual(sessionUsed, 4)
        XCTAssertEqual(format, .percent)
    }

    func testCancelledGoAccountRequestStopsBeforeTryingAnotherKey() async {
        let files = FakeFiles([
            "/oc/auth.json": authJSON,
            "/oc/go-keys.json": #"[{"id":"00000000-0000-0000-0000-000000000001","label":"Second","key":"sk-second"}]"#
        ])
        let http = RoutingHTTPClient { _ in
            throw URLError(.cancelled)
        }
        let provider = OpenCodeProvider(
            authStore: authStore(files: files),
            usageScanner: OpenCodeUsageScanner(sqlite: StubSQLite(), databasePaths: { [] }),
            usageClient: OpenCodeGoUsageClient(http: http),
            goKeyStore: OpenCodeGoKeyStore(files: files, filePath: { "/oc/go-keys.json" }),
            activeKeyID: { nil }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .cancelled)
        XCTAssertEqual(http.requests.count, 1, "cancellation must stop before trying the saved second key")
    }

    func testEntitlementErrorSuppressesLocalGoCapFallback() async {
        let now = d(TestLocalInstant.iso(2026, 7, 12, 12, 0, 0))
        let db = "[" + row(TestLocalInstant.iso(2026, 7, 12, 11, 0, 0), "2.0", 1000, "glm-5.2", "opencode-go") + "]"
        let entitlementError = Data(#"{"type":"error","error":{"type":"EntitlementError","message":"OpenCode Go subscription required."}}"#.utf8)
        let (client, _) = usageClient(statusCode: 403, body: entitlementError)
        let provider = OpenCodeProvider(
            authStore: authStore(files: FakeFiles(["/oc/auth.json": authJSON])),
            usageScanner: OpenCodeUsageScanner(
                sqlite: StubSQLite(data: ["/oc/opencode.db": db]),
                databasePaths: { ["/oc/opencode.db"] }
            ),
            usageClient: client,
            now: { now },
            goKeyStore: goKeyStoreStub(), activeKeyID: { nil }
        )

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.plan)
        XCTAssertNil(snapshot.line(label: "Session"))
        XCTAssertNil(snapshot.line(label: "Weekly"))
        XCTAssertNil(snapshot.line(label: "Monthly"))
        XCTAssertNotNil(snapshot.line(label: "Today"))
        XCTAssertEqual(
            snapshot.warning,
            "OpenCode couldn't confirm a Go subscription for this key. Check your account or try again."
        )

        let previous = ProviderSnapshot(
            providerID: "opencode",
            displayName: "OpenCode",
            plan: "Go",
            lines: [
                .progress(label: "Session", used: 3, limit: 100, format: .percent),
                .progress(label: "Weekly", used: 20, limit: 100, format: .percent),
                .progress(label: "Monthly", used: 70, limit: 100, format: .percent),
                .values(label: "Today", values: [MetricValue(number: 42, kind: .count, label: "tokens")]),
            ],
            refreshedAt: now
        )
        let merged = snapshot.mergingMenuBarUpdate(over: previous)
        XCTAssertNil(merged.plan)
        XCTAssertNil(merged.line(label: "Session"))
        XCTAssertNil(merged.line(label: "Weekly"))
        XCTAssertNil(merged.line(label: "Monthly"))
        XCTAssertEqual(merged.line(label: "Today"), snapshot.line(label: "Today"))
    }

    func testUnrecognizedClientErrorSuppressesLocalGoCapFallback() async {
        let now = d(TestLocalInstant.iso(2026, 7, 12, 12, 0, 0))
        let db = "[" + row(TestLocalInstant.iso(2026, 7, 12, 11, 0, 0), "2.0", 1000, "glm-5.2", "opencode-go") + "]"
        let (client, _) = usageClient(statusCode: 402)
        let provider = OpenCodeProvider(
            authStore: authStore(files: FakeFiles(["/oc/auth.json": authJSON])),
            usageScanner: OpenCodeUsageScanner(
                sqlite: StubSQLite(data: ["/oc/opencode.db": db]),
                databasePaths: { ["/oc/opencode.db"] }
            ),
            usageClient: client,
            now: { now },
            goKeyStore: goKeyStoreStub(), activeKeyID: { nil }
        )

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.plan)
        XCTAssertNil(snapshot.line(label: "Session"))
        XCTAssertNil(snapshot.line(label: "Weekly"))
        XCTAssertNil(snapshot.line(label: "Monthly"))
        XCTAssertNotNil(snapshot.line(label: "Today"))
        XCTAssertNotNil(snapshot.warning)
    }

    func testRefreshErrorsWhenAllDatabasesUnreadable() async {
        // A valid Go key with a locked/corrupt database must surface a read error, not $0 meters.
        // The scan fails before the account API is consulted, so no request is made.
        let now = d(TestLocalInstant.iso(2026, 7, 12, 12, 0, 0))
        let (client, http) = usageClient()
        let provider = OpenCodeProvider(
            authStore: authStore(files: FakeFiles(["/oc/auth.json": authJSON])),
            usageScanner: OpenCodeUsageScanner(
                sqlite: StubSQLite(failing: ["/oc/opencode.db"]),
                databasePaths: { ["/oc/opencode.db"] }
            ),
            usageClient: client,
            now: { now },
            goKeyStore: goKeyStoreStub(), activeKeyID: { nil }
        )
        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.errorCategory, .credentialAccess)
        XCTAssertNil(snapshot.line(label: "Session"))
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testRefreshSurfacesUnreadableAuthFileInsteadOfNotLoggedIn() async {
        // auth.json exists but can't be read, and there's no database: broken storage, not logout.
        let now = d(TestLocalInstant.iso(2026, 7, 12, 12, 0, 0))
        let provider = OpenCodeProvider(
            authStore: authStore(files: UnreadableFiles(present: ["/oc/auth.json"])),
            usageScanner: OpenCodeUsageScanner(sqlite: StubSQLite(), databasePaths: { [] }),
            now: { now },
            goKeyStore: goKeyStoreStub(), activeKeyID: { nil }
        )
        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.errorCategory, .credentialAccess)
    }

    func testHasLocalCredentialsTrueWhenAuthFileUnreadable() async {
        // An unreadable auth.json is itself an OpenCode footprint — enable the provider so refresh()
        // can show the actionable error rather than staying invisible.
        let provider = OpenCodeProvider(
            authStore: authStore(files: UnreadableFiles(present: ["/oc/auth.json"])),
            usageScanner: OpenCodeUsageScanner(sqlite: StubSQLite(), databasePaths: { [] }),
            goKeyStore: goKeyStoreStub(), activeKeyID: { nil }
        )
        let has = await provider.hasLocalCredentials()
        XCTAssertTrue(has)
    }

    func testUnreadableSavedGoKeysRemainDetectedAndSurfaceCredentialAccess() async {
        // An app-saved Go-key file is a provider footprint even when its permissions prevent reading it.
        let provider = OpenCodeProvider(
            authStore: authStore(files: FakeFiles()),
            usageScanner: OpenCodeUsageScanner(sqlite: StubSQLite(), databasePaths: { [] }),
            usageClient: usageClient().client,
            goKeyStore: OpenCodeGoKeyStore(
                files: UnreadableFiles(present: ["/oc/go-keys.json"]),
                filePath: { "/oc/go-keys.json" }
            ),
            activeKeyID: { nil }
        )

        let detected = await provider.hasLocalCredentials()
        let snapshot = await provider.refresh()

        XCTAssertTrue(detected)
        XCTAssertEqual(snapshot.errorCategory, .credentialAccess)
    }

    func testSpendTilesAreNotMarkedEstimated() async {
        // OpenCode records its own per-message cost — the tiles must not carry the local-estimate ⓘ.
        let now = d(TestLocalInstant.iso(2026, 7, 12, 12, 0, 0))
        let db = "[" + row(TestLocalInstant.iso(2026, 7, 12, 10, 0, 0), "1.0", 500, "gpt-5.5", "opencode") + "]"
        let provider = OpenCodeProvider(
            authStore: authStore(files: FakeFiles()),
            usageScanner: OpenCodeUsageScanner(
                sqlite: StubSQLite(data: ["/oc/opencode.db": db]),
                databasePaths: { ["/oc/opencode.db"] }
            ),
            now: { now },
            goKeyStore: goKeyStoreStub(), activeKeyID: { nil }
        )
        let snapshot = await provider.refresh()
        guard case .values(_, let values, _, _, _, _)? = snapshot.line(label: "Today") else {
            return XCTFail("expected a Today tile")
        }
        XCTAssertFalse(values.contains(where: \.estimated))
    }

    func testStaleGoHistoryDoesNotShowGoPlanOrMeters() async {
        // Zen-only recent usage + an old opencode-go anchor + no Go key: no "Go" badge, no cap meters,
        // but the Zen spend still shows in the tiles.
        let now = d(TestLocalInstant.iso(2026, 7, 12, 12, 0, 0))
        let db = "[" + row(TestLocalInstant.iso(2026, 7, 12, 10, 0, 0), "1.0", 500, "gpt-5.5", "opencode") + "]"
        let provider = OpenCodeProvider(
            authStore: authStore(files: FakeFiles()),
            usageScanner: OpenCodeUsageScanner(
                sqlite: StubSQLite(data: ["/oc/opencode.db": db], anchor: "1700000000000"),
                databasePaths: { ["/oc/opencode.db"] }
            ),
            now: { now },
            goKeyStore: goKeyStoreStub(), activeKeyID: { nil }
        )
        let snapshot = await provider.refresh()
        XCTAssertNil(snapshot.plan)
        XCTAssertNil(snapshot.line(label: "Session"))
        XCTAssertNotNil(snapshot.line(label: "Today"))
    }

    // MARK: - Panel scopes (two-phase panel-open pass)

    /// Phase 1 (`.panelMeters`): the Go account meters only — the fast path that lands the card's
    /// meters in seconds. No 18s local scan, so no tiles/trend and no history; the store's merge
    /// recovers those from the prior snapshot.
    func testPanelMetersScopeFetchesAccountMetersWithoutLocalScan() async {
        let (client, _) = usageClient()
        let provider = OpenCodeProvider(
            authStore: authStore(files: FakeFiles(["/oc/auth.json": authJSON])),
            usageScanner: OpenCodeUsageScanner(sqlite: StubSQLite(), databasePaths: { [] }),
            usageClient: client,
            goKeyStore: goKeyStoreStub(), activeKeyID: { nil }
        )
        let snapshot = await ProviderRefreshContext.$scope.withValue(.panelMeters) {
            await provider.refresh()
        }
        XCTAssertEqual(snapshot.plan, "Go")
        XCTAssertNotNil(snapshot.line(label: "Session"))
        XCTAssertNotNil(snapshot.line(label: "Weekly"))
        XCTAssertNil(snapshot.line(label: "Today"), "meters-only pass skips the local scan")
        XCTAssertNil(snapshot.line(label: "Usage Trend"))
        XCTAssertNil(snapshot.usageHistory)
    }

    /// Phase 2 (`.panelAccounting`): the local fold runs and history/refreshes, but the account API
    /// must NOT be re-read (phase 1 just answered it) and the local window fallback must not emit
    /// meters — a fresh local-window meter line would clobber the meters phase 1 fetched and
    /// re-bless recovered-meter staleness as current.
    func testPanelAccountingScopeFoldsHistoryWithoutAccountAPIOrWindowMeters() async {
        let now = d(TestLocalInstant.iso(2026, 7, 12, 12, 0, 0))
        let db = "[" + row(TestLocalInstant.iso(2026, 7, 12, 10, 0, 0), "1.0", 500, "gpt-5.5", "opencode") + "]"
        let (client, http) = usageClient()
        let provider = OpenCodeProvider(
            authStore: authStore(files: FakeFiles(["/oc/auth.json": authJSON])),
            usageScanner: OpenCodeUsageScanner(
                sqlite: StubSQLite(data: ["/oc/opencode.db": db], anchor: "1700000000000"),
                databasePaths: { ["/oc/opencode.db"] }
            ),
            usageClient: client,
            now: { now },
            goKeyStore: goKeyStoreStub(), activeKeyID: { nil }
        )
        let snapshot = await ProviderRefreshContext.$scope.withValue(.panelAccounting) {
            await provider.refresh()
        }
        XCTAssertTrue(http.requests.isEmpty, "fold-only scope must not re-read the account API")
        XCTAssertNil(snapshot.line(label: "Session"), "no fresh meter lines in a fold-only pass")
        XCTAssertNil(snapshot.line(label: "Weekly"))
        XCTAssertNil(snapshot.line(label: "Monthly"))
        XCTAssertNotNil(snapshot.line(label: "Today"), "the local fold still computes spend tiles")
        XCTAssertNotNil(snapshot.usageHistory)
        XCTAssertNil(snapshot.plan, "meters-only scope's plan is recovered by the store's merge")
    }

    /// Phase 2's local scan can fail even though phase 1 just recovered the live Go meters. A
    /// fold-only pass never calls the account endpoint, so a scan failure is no evidence that those
    /// meters are stale — claiming otherwise deleted freshly recovered quota rows.
    func testPanelAccountingScanFailureKeepsTheMetersPhaseFetched() async {
        let now = d(TestLocalInstant.iso(2026, 7, 12, 12, 0, 0))
        let (client, http) = usageClient()
        let provider = OpenCodeProvider(
            authStore: authStore(files: FakeFiles(["/oc/auth.json": authJSON])),
            usageScanner: OpenCodeUsageScanner(
                sqlite: StubSQLite(failing: ["/oc/opencode.db"]),
                databasePaths: { ["/oc/opencode.db"] }
            ),
            usageClient: client,
            now: { now },
            goKeyStore: goKeyStoreStub(), activeKeyID: { nil }
        )
        let snapshot = await ProviderRefreshContext.$scope.withValue(.panelAccounting) {
            await provider.refresh()
        }
        XCTAssertTrue(http.requests.isEmpty, "fold-only scope must not re-read the account API")
        XCTAssertNotNil(snapshot.errorCategory, "the local history failure still surfaces")
        XCTAssertNotEqual(
            snapshot.clearsPriorMenuBarQuotaState, true,
            "a fold-only scan failure must not invalidate the meters the meters phase just fetched"
        )
    }

    /// Local `opencode-go` rows show historical use but do not prove a current Go subscription.
    /// With no Go credential, even the quota-only path must hide the published caps and clear a
    /// previously cached plan/meter set while preserving spend history.
    func testPanelMetersHideGoCapsWithoutCredentialAndClearCachedPlan() async {
        let now = d(TestLocalInstant.iso(2026, 7, 12, 12, 0, 0))
        let db = "[" + row(TestLocalInstant.iso(2026, 7, 12, 10, 0, 0), "1.0", 500, "gpt-5.5", "opencode-go") + "]"
        let provider = OpenCodeProvider(
            authStore: authStore(files: FakeFiles()),
            usageScanner: OpenCodeUsageScanner(
                sqlite: StubSQLite(data: ["/oc/opencode.db": db], anchor: "1700000000000"),
                databasePaths: { ["/oc/opencode.db"] }
            ),
            now: { now },
            goKeyStore: goKeyStoreStub(), activeKeyID: { nil }
        )
        let snapshot = await ProviderRefreshContext.$scope.withValue(.panelMeters) {
            await provider.refresh()
        }
        XCTAssertNil(snapshot.line(label: "Session"), "local logs cannot establish an active Go cap")
        XCTAssertNil(snapshot.line(label: "Weekly"))
        XCTAssertNil(snapshot.line(label: "Monthly"))
        XCTAssertNil(snapshot.plan)
        XCTAssertEqual(snapshot.clearsPriorMenuBarQuotaState, true)
        XCTAssertNil(snapshot.line(label: "Today"), "meters-only pass carries no tiles")

        let previous = ProviderSnapshot(
            providerID: "opencode",
            displayName: "OpenCode",
            plan: "Go",
            lines: [
                .progress(label: "Session", used: 0, limit: 100, format: .percent),
                .progress(label: "Weekly", used: 0, limit: 100, format: .percent),
                .progress(label: "Monthly", used: 0, limit: 100, format: .percent),
                .values(label: "Today", values: [MetricValue(number: 1, kind: .dollars, label: "cost")])
            ],
            refreshedAt: now
        )
        let merged = snapshot.mergingMenuBarUpdate(over: previous)
        XCTAssertNil(merged.plan, "a stale plan badge must not survive removal of all Go credentials")
        XCTAssertNil(merged.line(label: "Session"))
        XCTAssertNil(merged.line(label: "Weekly"))
        XCTAssertNil(merged.line(label: "Monthly"))
        XCTAssertNotNil(merged.line(label: "Today"), "meter clearing must keep historical spend tiles")
    }

    /// No credentials and no OpenCode data directory is the not-logged-in state — the meters-only
    /// path must say so instead of painting a bare "No usage data" success (old full-scope parity).
    func testPanelMetersNotLoggedInWithoutKeysOrData() async {
        let provider = OpenCodeProvider(
            authStore: authStore(files: FakeFiles()),
            usageScanner: OpenCodeUsageScanner(sqlite: StubSQLite(), databasePaths: { [] }),
            goKeyStore: goKeyStoreStub(), activeKeyID: { nil }
        )
        let snapshot = await ProviderRefreshContext.$scope.withValue(.panelMeters) {
            await provider.refresh()
        }
        XCTAssertNotNil(snapshot.errorCategory, "expected the not-logged-in error snapshot")
        XCTAssertEqual(snapshot.clearsPriorMenuBarQuotaState, true)
    }

    func testFullRefreshWithoutGoKeyOrDataClearsPreviousQuotaState() async {
        let provider = OpenCodeProvider(
            authStore: authStore(files: FakeFiles()),
            usageScanner: OpenCodeUsageScanner(sqlite: StubSQLite(), databasePaths: { [] }),
            goKeyStore: goKeyStoreStub(), activeKeyID: { nil }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
        XCTAssertEqual(snapshot.clearsPriorMenuBarQuotaState, true)
    }

    func testUnreadableLocalDatabaseClearsPreviouslyCachedGoQuota() async {
        let provider = OpenCodeProvider(
            authStore: authStore(files: FakeFiles()),
            usageScanner: OpenCodeUsageScanner(
                sqlite: StubSQLite(),
                databasePaths: { throw OpenCodeUsageError.databaseUnreadable }
            ),
            goKeyStore: goKeyStoreStub(), activeKeyID: { nil }
        )
        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .credentialAccess)
        XCTAssertEqual(snapshot.clearsPriorMenuBarQuotaState, true)
        let previous = ProviderSnapshot(
            providerID: "opencode", displayName: "OpenCode", plan: "Go",
            lines: [
                .progress(label: "Session", used: 5, limit: 100, format: .percent),
                .values(label: "Today", values: [MetricValue(number: 2, kind: .dollars, label: "cost")])
            ],
            refreshedAt: Date()
        )
        let merged = snapshot.mergingMenuBarUpdate(over: previous)
        XCTAssertNil(merged.plan)
        XCTAssertNil(merged.line(label: "Session"))
        XCTAssertNotNil(merged.line(label: "Today"))
    }

    func testPanelMetersDatabaseErrorClearsPreviouslyCachedGoQuota() async {
        let provider = OpenCodeProvider(
            authStore: authStore(files: FakeFiles()),
            usageScanner: OpenCodeUsageScanner(
                sqlite: StubSQLite(),
                databasePaths: { throw OpenCodeUsageError.databaseUnreadable }
            ),
            goKeyStore: goKeyStoreStub(), activeKeyID: { nil }
        )
        let snapshot = await ProviderRefreshContext.$scope.withValue(.panelMeters) {
            await provider.refresh()
        }

        XCTAssertEqual(snapshot.errorCategory, .credentialAccess)
        XCTAssertEqual(snapshot.clearsPriorMenuBarQuotaState, true)
    }

    /// Fold-only pass with Go credentials but no local database: the meters-only phase already
    /// answered the meters; a mergeable success snapshot (not an error) keeps the card working and
    /// avoids the failure backoff for a provider whose only problem is "no local DB".
    func testPanelAccountingNoDatabaseReturnsMergeableSnapshot() async {
        let (client, http) = usageClient()
        let provider = OpenCodeProvider(
            authStore: authStore(files: FakeFiles(["/oc/auth.json": authJSON])),
            usageScanner: OpenCodeUsageScanner(sqlite: StubSQLite(), databasePaths: { [] }),
            usageClient: client,
            goKeyStore: goKeyStoreStub(), activeKeyID: { nil }
        )
        let snapshot = await ProviderRefreshContext.$scope.withValue(.panelAccounting) {
            await provider.refresh()
        }
        XCTAssertNil(snapshot.errorCategory, "no local DB is not a fold-pass failure")
        XCTAssertTrue(http.requests.isEmpty, "fold-only scope must not re-read the account API")
    }
}

private final class StubSQLite: SQLiteAccessing, @unchecked Sendable {
    var data: [String: String]
    var anchor: String?
    var failing: Set<String>
    init(data: [String: String] = [:], anchor: String? = nil, failing: Set<String> = []) {
        self.data = data
        self.anchor = anchor
        self.failing = failing
    }

    func queryValue(path: String, sql: String) throws -> String? {
        if failing.contains(path) { throw SQLiteError.queryFailed("boom") }
        if sql.contains("json_group_array") { return data[path] }
        if sql.contains("MIN(time_created)") { return anchor }
        if sql.contains("SELECT 1") {
            let payload = data[path]
            return (payload != nil && payload != "[]" && !(payload ?? "").isEmpty) ? "1" : nil
        }
        return nil
    }

    func execute(path: String, sql: String) throws {}
}

private final class ThreadRecordingOpenCodeFiles: TextFileAccessing, @unchecked Sendable {
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
