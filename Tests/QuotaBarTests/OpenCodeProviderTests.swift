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
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNil(snapshot.plan)
        XCTAssertNil(snapshot.line(label: "Session"))
        XCTAssertNil(snapshot.line(label: "Weekly"))
        XCTAssertNil(snapshot.line(label: "Monthly"))
        XCTAssertNotNil(snapshot.warning)
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

    func testLocalFallbackMetersWhenAPIIsUnavailable() async {
        // A transient account API error leaves local-observed spend meters available.
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
        XCTAssertEqual(http.requests.count, 1)
        guard case .progress(_, let sessionUsed, _, let format, _, _, _, _)? = snapshot.line(label: "Session") else {
            return XCTFail("expected a Session meter")
        }
        XCTAssertEqual(sessionUsed, 2.0 / OpenCodeUsageMapper.sessionCap * 100) // 2.0 of $12 local spend
        XCTAssertEqual(format, .percent)
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
        // A Zen-only user has no Go key: the account endpoint must never be called.
        let now = d(TestLocalInstant.iso(2026, 7, 12, 12, 0, 0))
        let db = "[" + row(TestLocalInstant.iso(2026, 7, 12, 10, 0, 0), "1.0", 500, "gpt-5.5", "opencode") + "]"
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
        XCTAssertNotNil(snapshot.line(label: "Today"))
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
