import XCTest
@testable import QuotaBar

final class CodexAuthStoreTests: XCTestCase {
    override func setUp() {
        super.setUp()
        KeychainPermissionGate.shared.resetAll()
    }

    override func tearDown() {
        KeychainPermissionGate.shared.resetAll()
        super.tearDown()
    }

    func testParsesHexEncodedAuthPayload() {
        let raw = #"{"tokens":{"access_token":"token"},"last_refresh":"2026-01-01T00:00:00.000Z"}"#
        let hex = raw.utf8.map { String(format: "%02x", $0) }.joined()

        let auth = CodexAuthStore.parseAuth(hex)

        XCTAssertEqual(auth?.tokens?.accessToken, "token")
    }

    func testRefreshDecisionUsesTokenExpiryThenLastRefresh() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = CodexAuthStore(now: { now })
        let nineDaysAgo = OpenUsageISO8601.string(from: now.addingTimeInterval(-9 * 24 * 60 * 60))
        let cases: [(name: String, token: String, lastRefresh: String?, expected: Bool)] = [
            ("valid JWT", jwt(exp: now.addingTimeInterval(3600)), nil, false),
            ("JWT near expiry", jwt(exp: now.addingTimeInterval(60)), nil, true),
            ("stale refresh without JWT expiry", "token", nineDaysAgo, true),
            ("new login without expiry or refresh", "token", nil, false)
        ]

        for entry in cases {
            let auth = CodexAuth(tokens: CodexTokens(accessToken: entry.token), lastRefresh: entry.lastRefresh)
            XCTAssertEqual(store.needsRefresh(auth), entry.expected, entry.name)
        }
    }

    /// Builds a real JWT-shaped token: `base64url(header).base64url({"exp":<epoch>}).sig`.
    private func jwt(exp date: Date) -> String {
        func b64url(_ string: String) -> String {
            Data(string.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let header = b64url(#"{"alg":"RS256","typ":"JWT"}"#)
        let payload = b64url(#"{"exp":\#(Int(date.timeIntervalSince1970))}"#)
        return "\(header).\(payload).sig"
    }

    func testUsesCodexHomeAuthPathBeforeDefaultPaths() throws {
        let files = FakeFiles([
            "/tmp/codex-home/auth.json": #"{"tokens":{"access_token":"token"}}"#
        ])
        let store = CodexAuthStore(
            environment: FakeEnvironment(["CODEX_HOME": "/tmp/codex-home"]),
            files: files,
            keychain: FakeKeychain()
        )

        let candidates = try store.loadAuthCandidates()

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.auth.tokens?.accessToken, "token")
    }

    func testExpectedIdentityDropsOtherAccountAndRejectsSavingIt() throws {
        let files = FakeFiles([
            "/tmp/codex-home/auth.json": #"{"tokens":{"access_token":"token-b","account_id":"account-b"}}"#
        ])
        let store = CodexAuthStore(
            environment: FakeEnvironment(["CODEX_HOME": "/tmp/codex-home"]),
            files: files,
            keychain: FakeKeychain(),
            expectedIdentityKey: "account-a"
        )

        XCTAssertTrue(try store.loadAuthCandidates().isEmpty)
        let wrong = CodexAuthState(
            auth: CodexAuth(
                tokens: CodexTokens(accessToken: "token-b", accountID: "account-b")
            ),
            source: .file(path: "/tmp/codex-home/auth.json")
        )
        XCTAssertThrowsError(try store.save(wrong)) { error in
            XCTAssertEqual(error as? CodexAuthError, .tokenConflict)
        }
    }

    func testKeychainLookupUsesTheCodexHomeDerivedAccount() throws {
        let home = "/tmp/codex-home"
        let account = CodexAuthStore.keychainAccount(forCodexHome: home)
        XCTAssertEqual(account, "cli|c790889e29f35b54", "matches the Codex CLI's SHA-256 home key")
        let keychain = AccountScopedKeychain(values: [account: #"{"tokens":{"access_token":"home-token"}}"#])
        let store = CodexAuthStore(
            environment: FakeEnvironment(["CODEX_HOME": home]),
            files: FakeFiles(),
            keychain: keychain
        )

        let state = try XCTUnwrap(try store.loadKeychainAuth())

        XCTAssertEqual(keychain.readAccounts, [account])
        XCTAssertEqual(state.auth.tokens?.accessToken, "home-token")
        XCTAssertEqual(state.source, .keychain(account: account))
    }

    func testCancelledKeychainReadRemainsCancellationError() {
        let keychain = CancelledCodexKeychain()
        let store = CodexAuthStore(
            environment: FakeEnvironment(["CODEX_HOME": "/tmp/codex-home"]),
            files: FakeFiles(),
            keychain: keychain
        )

        XCTAssertThrowsError(try store.loadKeychainAuth()) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(keychain.readCount, 1, "a cancelled read should stop candidate fallback")
    }

    func testCodexKeychainHomeKeyCanonicalizesExistingSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let realHome = root.appendingPathComponent("real-home", isDirectory: true)
        let linkedHome = root.appendingPathComponent("linked-home", isDirectory: true)
        try FileManager.default.createDirectory(at: realHome, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkedHome, withDestinationURL: realHome)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertEqual(
            CodexAuthStore.keychainAccount(forCodexHome: realHome.path),
            CodexAuthStore.keychainAccount(forCodexHome: linkedHome.path)
        )
    }

    func testKeychainRefreshWritesBackToTheExactCodexHomeAccount() throws {
        let home = "/tmp/codex-home"
        let account = CodexAuthStore.keychainAccount(forCodexHome: home)
        let keychain = AccountScopedKeychain(values: [account: #"{"tokens":{"access_token":"old-token"}}"#])
        let store = CodexAuthStore(
            environment: FakeEnvironment(["CODEX_HOME": home]),
            files: FakeFiles(),
            keychain: keychain
        )
        var state = try XCTUnwrap(try store.loadKeychainAuth())
        state.auth.tokens?.accessToken = "rotated-token"

        try store.save(state)

        XCTAssertEqual(keychain.writtenAccounts, [account])
        XCTAssertEqual(
            CodexAuthStore.parseAuth(try XCTUnwrap(keychain.values[account]))?.tokens?.accessToken,
            "rotated-token"
        )
    }

    func testSuccessfulCodexKeychainRotationPersistsAfterNewManualActionStarts() async throws {
        let home = "/tmp/codex-home"
        let account = CodexAuthStore.keychainAccount(forCodexHome: home)
        let originalJSON = #"{"tokens":{"access_token":"old-access","refresh_token":"old-refresh"}}"#
        let keychain = AccountScopedKeychain(values: [account: originalJSON])
        let store = CodexAuthStore(
            environment: FakeEnvironment(["CODEX_HOME": home]),
            files: FakeFiles(),
            keychain: keychain
        )
        let original = try XCTUnwrap(try store.loadKeychainAuth())
        var rotated = original
        rotated.auth.tokens?.accessToken = "rotated-access"
        rotated.auth.tokens?.refreshToken = "rotated-refresh"
        let persistedState = rotated

        let olderActionID = KeychainPermissionGate.shared.beginManualAction()
        let saveStarted = DispatchSemaphore(value: 0)
        let releaseSave = DispatchSemaphore(value: 0)
        defer { releaseSave.signal() }
        let save = Task.detached {
            try await ProviderRefreshContext.$isManual.withValue(true) {
                try await ProviderRefreshContext.$manualActionID.withValue(olderActionID) {
                    saveStarted.signal()
                    _ = releaseSave.wait(timeout: .now() + 5)
                    try store.save(persistedState, replacing: original)
                }
            }
        }

        XCTAssertEqual(saveStarted.wait(timeout: .now() + 2), .success)
        _ = KeychainPermissionGate.shared.beginManualAction()
        releaseSave.signal()
        try await save.value

        let persistedJSON = try XCTUnwrap(keychain.values[account])
        let persisted = try XCTUnwrap(persistedJSON.data(using: .utf8))
        let tokens = try XCTUnwrap(try JSONDecoder().decode(CodexAuth.self, from: persisted).tokens)
        XCTAssertEqual(tokens.accessToken, "rotated-access")
        XCTAssertEqual(tokens.refreshToken, "rotated-refresh")
    }

    private final class AccountScopedKeychain: KeychainAccessing, @unchecked Sendable {
        var values: [String: String]
        private(set) var readAccounts: [String] = []
        private(set) var writtenAccounts: [String] = []

        init(values: [String: String]) {
            self.values = values
        }

        func readGenericPassword(service: String) throws -> String? { nil }

        func readGenericPassword(service: String, account: String, allowInteraction: Bool) throws -> String? {
            readAccounts.append(account)
            return values[account]
        }

        func writeGenericPassword(service: String, value: String) throws {}

        func writeGenericPassword(service: String, account: String, value: String) throws {
            writtenAccounts.append(account)
            values[account] = value
        }
    }

    func testAccountIDAndIDTokenMismatchFailsClosed() throws {
        let idToken = identityJWT(accountID: "account-b")
        let auth = "{\"tokens\":{\"access_token\":\"token-a\",\"account_id\":\"account-a\",\"id_token\":\"\(idToken)\"}}"
        let store = CodexAuthStore(
            environment: FakeEnvironment(["CODEX_HOME": "/tmp/codex-home"]),
            files: FakeFiles([
                "/tmp/codex-home/auth.json": auth,
            ]),
            keychain: FakeKeychain(),
            expectedIdentityKey: "account-a"
        )

        XCTAssertTrue(try store.loadAuthCandidates().isEmpty)
    }

    @MainActor
    func testUnreadablePresentAuthFileKeepsCodexDetectedAndSurfacesCredentialAccess() async {
        let files = UnreadableCodexAuthFile(path: "/tmp/codex-home/auth.json")
        let provider = CodexProvider(
            authStore: CodexAuthStore(
                environment: FakeEnvironment(["CODEX_HOME": "/tmp/codex-home"]),
                files: files,
                keychain: FakeKeychain()
            ),
            usageClient: CodexUsageClient(http: FakeHTTPClient(
                response: HTTPResponse(statusCode: 200, headers: [:], body: Data())
            ))
        )

        let hasCredentials = await provider.hasLocalCredentials()
        XCTAssertTrue(hasCredentials)
        let snapshot = await provider.refresh()
        XCTAssertTrue(snapshot.warning?.contains(CodexAuthError.credentialsUnreadable.localizedDescription) == true)
    }

    private func identityJWT(accountID: String) -> String {
        func base64URL(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let header = Data(#"{"alg":"none"}"#.utf8)
        let payload = Data("{\"https://api.openai.com/auth\":{\"chatgpt_account_id\":\"\(accountID)\"}}".utf8)
        return "\(base64URL(header)).\(base64URL(payload)).sig"
    }
}

private struct UnreadableCodexAuthFile: TextFileAccessing {
    let path: String

    func exists(_ path: String) -> Bool { path == self.path }
    func readText(_ path: String) throws -> String { throw CocoaError(.fileReadNoPermission) }
    func readTextIfPresent(_ path: String) throws -> String? {
        guard exists(path) else { return nil }
        throw CocoaError(.fileReadNoPermission)
    }
    func writeText(_ path: String, _ text: String) throws {}
    func remove(_ path: String) throws {}
}

private actor CodexRefreshResponseGate {
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

private final class CancelledCodexKeychain: KeychainAccessing, @unchecked Sendable {
    private(set) var readCount = 0

    func readGenericPassword(service: String) throws -> String? { throw CancellationError() }

    func readGenericPassword(service: String, account: String, allowInteraction: Bool) throws -> String? {
        readCount += 1
        throw CancellationError()
    }

    func writeGenericPassword(service: String, value: String) throws {}
    func writeGenericPassword(service: String, account: String, value: String) throws {}
}

final class CodexUsageMapperTests: XCTestCase {
    func testFreshSessionWindowPreservesOnePercentAndDefaultsMissingPeriod() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let resetAfterSeconds = CodexUsageMapper.sessionPeriodMs / 1000
        let body = Data("""
        {
          "rate_limit": {
            "primary_window": {
              "used_percent": 1,
              "reset_after_seconds": \(resetAfterSeconds),
              "reset_at": \(Int(now.timeIntervalSince1970) + resetAfterSeconds)
            }
          }
        }
        """.utf8)
        let response = HTTPResponse(statusCode: 200, headers: [:], body: body)

        let mapped = try CodexUsageMapper.mapUsageResponse(response, now: now)

        XCTAssertEqual(progress(mapped.lines, "Session")?.used, 1)
        XCTAssertEqual(progress(mapped.lines, "Session")?.periodDurationMs, CodexUsageMapper.sessionPeriodMs)
    }

    func testMapsLimitWindowSecondsFromAPI() throws {
        let body = Data("""
        {
          "rate_limit": {
            "primary_window": {
              "reset_after_seconds": 60,
              "used_percent": 1,
              "limit_window_seconds": 18000
            }
          }
        }
        """.utf8)
        let response = HTTPResponse(statusCode: 200, headers: [:], body: body)
        let mapped = try CodexUsageMapper.mapUsageResponse(
            response,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        XCTAssertEqual(progress(mapped.lines, "Session")?.periodDurationMs, 18_000_000)
    }

    func testMapsWeeklyOnlyPrimaryWindowByDuration() throws {
        let body = Data("""
        {
          "rate_limit": {
            "primary_window": {
              "used_percent": 5,
              "limit_window_seconds": 604800,
              "reset_after_seconds": 60
            },
            "secondary_window": null
          }
        }
        """.utf8)
        let mapped = try CodexUsageMapper.mapUsageResponse(
            HTTPResponse(statusCode: 200, headers: [:], body: body),
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertNil(progress(mapped.lines, "Session"))
        XCTAssertEqual(progress(mapped.lines, "Weekly")?.used, 5)
        XCTAssertEqual(progress(mapped.lines, "Weekly")?.periodDurationMs, CodexUsageMapper.weeklyPeriodMs)
    }

    func testUnknownWindowDurationKeepsPositionalFallback() throws {
        let body = Data("""
        {
          "rate_limit": {
            "primary_window": { "used_percent": 11, "limit_window_seconds": 86400 },
            "secondary_window": { "used_percent": 22, "limit_window_seconds": 2592000 }
          }
        }
        """.utf8)
        let mapped = try CodexUsageMapper.mapUsageResponse(
            HTTPResponse(statusCode: 200, headers: [:], body: body)
        )

        XCTAssertEqual(progress(mapped.lines, "Session")?.used, 11)
        XCTAssertEqual(progress(mapped.lines, "Weekly")?.used, 22)
    }

    func testMapsWindowsCreditsAndPlan() throws {
        let body = Data("""
        {
          "plan_type": "prolite",
          "rate_limit": {
            "primary_window": { "reset_after_seconds": 60, "used_percent": 10 },
            "secondary_window": { "reset_after_seconds": 120, "used_percent": 20 }
          },
          "credits": { "balance": "100" }
        }
        """.utf8)
        let response = HTTPResponse(
            statusCode: 200,
            headers: [
                "x-codex-primary-used-percent": "25",
                "x-codex-secondary-used-percent": "50"
            ],
            body: body
        )

        let mapped = try CodexUsageMapper.mapUsageResponse(
            response,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertEqual(mapped.plan, "Pro 5x")
        XCTAssertEqual(progress(mapped.lines, "Session")?.used, 10)
        XCTAssertEqual(progress(mapped.lines, "Weekly")?.used, 20)
        // Credits lead with the dollar value (4¢/credit), then the raw count — no inverted fake cap.
        XCTAssertNil(progress(mapped.lines, "Credits"))
        XCTAssertEqual(values(mapped.lines, "Credits"),
                       [MetricValue(number: 4.0, kind: .dollars), MetricValue(number: 100, kind: .count, label: "credits")])
        XCTAssertNotNil(progress(mapped.lines, "Session")?.resetsAt)
        XCTAssertEqual(progress(mapped.lines, "Session")?.periodDurationMs, CodexUsageMapper.sessionPeriodMs)
    }

    func testHeadersFillMissingWindows() throws {
        let body = Data("""
        {
          "rate_limit": {}
        }
        """.utf8)
        let response = HTTPResponse(
            statusCode: 200,
            headers: [
                "x-codex-primary-used-percent": "25",
                "x-codex-secondary-used-percent": "50"
            ],
            body: body
        )

        let mapped = try CodexUsageMapper.mapUsageResponse(
            response,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertEqual(progress(mapped.lines, "Session")?.used, 25)
        XCTAssertEqual(progress(mapped.lines, "Weekly")?.used, 50)
    }

    func testSessionWindowBeatsStaleHeader() throws {
        let body = Data("""
        {
          "rate_limit": {
            "primary_window": { "reset_after_seconds": 60, "used_percent": 0 },
            "secondary_window": { "reset_after_seconds": 120, "used_percent": 7 }
          }
        }
        """.utf8)
        let response = HTTPResponse(
            statusCode: 200,
            headers: [
                "x-codex-primary-used-percent": "99",
                "x-codex-secondary-used-percent": "99"
            ],
            body: body
        )

        let mapped = try CodexUsageMapper.mapUsageResponse(
            response,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertEqual(progress(mapped.lines, "Session")?.used, 0)
        XCTAssertEqual(progress(mapped.lines, "Weekly")?.used, 7)
    }

    func testSurfacesSparkLinesFromAdditionalRateLimits() throws {
        // The usage body carries model-specific limits in `additional_rate_limits`; the Spark entry's
        // primary/secondary windows become the Spark (5-hour) and Spark Weekly meters. Regression for
        // issue #796 — the Swift edition dropped these when it didn't port the JS plugin's parsing.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let nowSec = Int(now.timeIntervalSince1970)
        let body = Data("""
        {
          "rate_limit": {
            "primary_window": { "used_percent": 5, "reset_after_seconds": 60 },
            "secondary_window": { "used_percent": 10, "reset_after_seconds": 120 }
          },
          "additional_rate_limits": [
            {
              "limit_name": "GPT-5.3-Codex-Spark",
              "metered_feature": "codex_bengalfox",
              "rate_limit": {
                "primary_window": {
                  "used_percent": 25,
                  "limit_window_seconds": 18000,
                  "reset_after_seconds": 3600,
                  "reset_at": \(nowSec + 3600)
                },
                "secondary_window": {
                  "used_percent": 40,
                  "limit_window_seconds": 604800,
                  "reset_after_seconds": 86400,
                  "reset_at": \(nowSec + 86400)
                }
              }
            }
          ]
        }
        """.utf8)
        let response = HTTPResponse(statusCode: 200, headers: [:], body: body)

        let mapped = try CodexUsageMapper.mapUsageResponse(response, now: now)

        XCTAssertEqual(progress(mapped.lines, "Spark")?.used, 25)
        XCTAssertEqual(progress(mapped.lines, "Spark")?.periodDurationMs, 18_000_000)
        XCTAssertEqual(progress(mapped.lines, "Spark")?.resetsAt,
                       Date(timeIntervalSince1970: TimeInterval(nowSec + 3600)))
        XCTAssertEqual(progress(mapped.lines, "Spark Weekly")?.used, 40)
        XCTAssertEqual(progress(mapped.lines, "Spark Weekly")?.periodDurationMs, 604_800_000)
        // The core Session/Weekly windows are unaffected by the new parsing.
        XCTAssertEqual(progress(mapped.lines, "Session")?.used, 5)
        XCTAssertEqual(progress(mapped.lines, "Weekly")?.used, 10)
    }

    func testMapsWeeklyOnlySparkPrimaryWindowByDuration() throws {
        let body = Data("""
        {
          "additional_rate_limits": [{
            "limit_name": "GPT-5.3-Codex-Spark",
            "rate_limit": {
              "primary_window": {
                "used_percent": 7,
                "limit_window_seconds": 604800,
                "reset_after_seconds": 60
              },
              "secondary_window": null
            }
          }]
        }
        """.utf8)
        let mapped = try CodexUsageMapper.mapUsageResponse(
            HTTPResponse(statusCode: 200, headers: [:], body: body),
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertNil(progress(mapped.lines, "Spark"))
        XCTAssertEqual(progress(mapped.lines, "Spark Weekly")?.used, 7)
        XCTAssertEqual(progress(mapped.lines, "Spark Weekly")?.periodDurationMs, CodexUsageMapper.weeklyPeriodMs)
    }

    func testMatchesSparkByMeteredFeatureWhenLimitNameLacksSpark() throws {
        // `limit_name` wording can shift; matching `metered_feature` too keeps the row resolving.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let body = Data("""
        {
          "additional_rate_limits": [
            {
              "limit_name": "Research Preview",
              "metered_feature": "codex_spark_preview",
              "rate_limit": { "primary_window": { "used_percent": 12, "reset_after_seconds": 60 } }
            }
          ]
        }
        """.utf8)
        let response = HTTPResponse(statusCode: 200, headers: [:], body: body)

        let mapped = try CodexUsageMapper.mapUsageResponse(response, now: now)

        XCTAssertEqual(progress(mapped.lines, "Spark")?.used, 12)
    }

    func testIgnoresNonSparkAndMalformedAdditionalRateLimits() throws {
        // Non-Spark model limits have no descriptors, so they aren't surfaced; a null/non-dictionary
        // element is skipped without discarding its siblings; a Spark entry missing `rate_limit` yields
        // no lines. None of this should ever throw.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let body = Data("""
        {
          "additional_rate_limits": [
            null,
            { "limit_name": "Some Other Model", "rate_limit": { "primary_window": { "used_percent": 50, "reset_after_seconds": 60 } } },
            { "limit_name": "GPT-5.3-Codex-Spark" }
          ]
        }
        """.utf8)
        let response = HTTPResponse(statusCode: 200, headers: [:], body: body)

        let mapped = try CodexUsageMapper.mapUsageResponse(response, now: now)

        XCTAssertNil(progress(mapped.lines, "Spark"))
        XCTAssertNil(progress(mapped.lines, "Spark Weekly"))
        XCTAssertNil(progress(mapped.lines, "Some Other Model"))
    }

    // Regression: dollar amounts must group thousands (e.g. "$1,200.00") consistently with the
    // headline, which formats through `Formatters.currency`. Credit lines previously used a bare
    // `$%.2f` that dropped the separator.
    func testCreditValuesRenderGroupedThousands() {
        var data = WidgetData(title: "Extra Usage", icon: .providerMark("codex"), kind: .dollars, used: 0, limit: nil)
        data.values = CodexUsageMapper.creditValues(remaining: 30000)
        // The row abbreviates ("$1.2K · 30K credits"); the hover tooltip keeps every digit.
        XCTAssertEqual(data.unboundedDetail, "$1.2K · 30K credits")
        XCTAssertEqual(data.unboundedTooltip, "$1,200.00 · 30,000 credits")
    }

    func testShowsRateLimitResetsBeforeCredits() throws {
        let body = Data("""
        {
          "rate_limit_reset_credits": { "available_count": 1 },
          "credits": { "balance": 100 }
        }
        """.utf8)
        let response = HTTPResponse(statusCode: 200, headers: [:], body: body)

        let mapped = try CodexUsageMapper.mapUsageResponse(
            response,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertEqual(values(mapped.lines, "Rate Limit Resets"),
                       [MetricValue(number: 1, kind: .count, label: "available")])

        XCTAssertEqual(mapped.lines.map(\.label), ["Rate Limit Resets", "Credits"])
    }

    func testShowsZeroRateLimitResets() throws {
        let body = Data(#"{ "rate_limit_reset_credits": { "available_count": 0 } }"#.utf8)
        let response = HTTPResponse(statusCode: 200, headers: [:], body: body)

        let mapped = try CodexUsageMapper.mapUsageResponse(
            response,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertEqual(values(mapped.lines, "Rate Limit Resets"),
                       [MetricValue(number: 0, kind: .count, label: "available")])
    }

    func testDedicatedEndpointSortsAvailableExpiriesWithExplicitOrMissingStatus() throws {
        let usage = HTTPResponse(statusCode: 200, headers: [:], body: Data("{}".utf8))
        let expectedExpiries = [
            OpenUsageISO8601.date(from: "2026-02-20T17:30:00.000Z")!,
            OpenUsageISO8601.date(from: "2026-02-20T19:00:00.000Z")!
        ]

        for status in ["available", nil] as [String?] {
            let statusField = status.map { "\"status\":\"\($0)\"," } ?? ""
            let resetCredits = HTTPResponse(statusCode: 200, headers: [:], body: Data("""
            {"available_count":2,"credits":[
              {\(statusField)"expires_at":"2026-02-20T19:00:00.000Z"},
              {\(statusField)"expires_at":"2026-02-20T17:30:00.000Z"},
              {"status":"consumed","expires_at":"2026-02-20T16:10:00.000Z"}
            ]}
            """.utf8))
            let mapped = try CodexUsageMapper.mapUsageResponse(
                usage,
                resetCredits: resetCredits,
                now: OpenUsageISO8601.date(from: "2026-02-20T16:00:00.000Z")!
            )

            guard case .values(_, let values, _, let expiriesAt, _, _) = mapped.lines.first else {
                return XCTFail("expected reset credits for status \(status ?? "omitted")")
            }
            XCTAssertEqual(values, [MetricValue(number: 2, kind: .count, label: "available")])
            XCTAssertEqual(expiriesAt, expectedExpiries, status ?? "omitted")
        }
    }

    func testInvalidDedicatedResponsesFallBackToUsageBodyCount() throws {
        let usage = HTTPResponse(statusCode: 200, headers: [:],
                                 body: Data(#"{ "rate_limit_reset_credits": { "available_count": 3 } }"#.utf8))
        let cases: [(name: String, response: HTTPResponse?)] = [
            ("missing", nil),
            ("null count", HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"available_count":null}"#.utf8))),
            ("server failure", HTTPResponse(statusCode: 500, headers: [:], body: Data("<html>oops</html>".utf8)))
        ]

        for entry in cases {
            let mapped = try CodexUsageMapper.mapUsageResponse(
                usage, resetCredits: entry.response, now: Date(timeIntervalSince1970: 1_800_000_000)
            )
            guard case .values(_, let values, _, let expiriesAt, _, _) = mapped.lines.first else {
                return XCTFail("expected reset credits when dedicated response is \(entry.name)")
            }
            XCTAssertEqual(values, [MetricValue(number: 3, kind: .count, label: "available")], entry.name)
            XCTAssertTrue(expiriesAt.isEmpty, entry.name)
        }
    }

    func testOmitsRateLimitResetsWhenCountMalformed() throws {
        let body = Data(#"{ "rate_limit_reset_credits": { "available_count": null } }"#.utf8)
        let response = HTTPResponse(statusCode: 200, headers: [:], body: body)

        let mapped = try CodexUsageMapper.mapUsageResponse(
            response,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertNil(values(mapped.lines, "Rate Limit Resets"))
    }

    private func progress(_ lines: [MetricLine], _ label: String) -> (used: Double, limit: Double, resetsAt: Date?, periodDurationMs: Int?)? {
        guard case .progress(_, let used, let limit, _, let resetsAt, let periodDurationMs, _, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return (used, limit, resetsAt, periodDurationMs)
    }

    private func values(_ lines: [MetricLine], _ label: String) -> [MetricValue]? {
        guard case .values(_, let values, _, _, _, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return values
    }

}

@MainActor
final class CodexProviderTests: XCTestCase {
    // Note on the `TestLocalInstant` fixtures below: these tests pair a clock with log events hours
    // earlier and assert the spend lands in the "Today" tile. Anchored to UTC instants, that pairing is
    // only self-consistent when the suite runs on UTC — at UTC+9 the 16:00Z clock is 01:00 on the *next*
    // local day while the 14:00Z events are still on the previous one, so "Today" is empty and the tile
    // assertion fails. The helpers make the hours local, which holds for every offset.

    func testNoUsageDataBadgeIsDroppedWhenLocalLogsHaveSpend() async throws {
        let now = TestLocalInstant.date(2026, 2, 20, 12)
        // The live usage API returns nothing mappable (empty body -> no metric lines)...
        let httpClient = FakeHTTPClient(response: HTTPResponse(statusCode: 200, headers: [:], body: Data("{}".utf8)))
        let home = try CodexLogFixture.makeHome(files: [
            "sessions/rollout-1.jsonl": [
                CodexLogFixture.turnContext(timestamp: TestLocalInstant.iso(2026, 2, 20, 10), model: "gpt-5.2"),
                CodexLogFixture.tokenCount(
                    timestamp: TestLocalInstant.iso(2026, 2, 20, 10, 1),
                    last: CodexLogFixture.usage(input: 100, output: 50)
                )
            ].joined(separator: "\n")
        ])
        let provider = CodexProvider(
            authStore: CodexAuthStore(
                environment: FakeEnvironment(["CODEX_HOME": "/tmp/codex-home"]),
                files: FakeFiles(["/tmp/codex-home/auth.json": #"{"tokens":{"access_token":"token"}}"#]),
                keychain: FakeKeychain()
            ),
            usageClient: CodexUsageClient(http: httpClient),
            logUsageScanner: CodexLogFixture.scanner(home: home),
            proxyUsageScanner: CodexProxyUsageScanner(databasePaths: { [] }),
            routerUsageScanner: CodexRouterUsageScanner(ledgerPaths: { [] }, identityAliases: { [:] }),
            initialAccountIdentityKey: "codex-fixture-account",
            allowsUnattributedPiUsage: false,
            now: { now },
            pricing: {
                // 150 tokens -> $0.25 at these fixture rates: (100 x 1000 + 50 x 3000) / 1M.
                ModelPricing(
                    supplement: PricingSupplement(),
                    primary: PricingCatalog(entries: ["gpt-5.2": ModelRates(
                        inputPerMillion: 1000, outputPerMillion: 3000,
                        cacheWritePerMillion: 1000, cacheReadPerMillion: 100
                    )]),
                    secondary: PricingCatalog(entries: [:])
                )
            }
        )

        let snapshot = await provider.refresh()

        // ...but local scanned spend exists, so the snapshot shows the spend lines and NOT the
        // "No usage data" badge. Regression: the mapper used to append the badge *before* the spend
        // lines, leaving a contradictory badge-plus-spend snapshot.
        XCTAssertEqual(values(snapshot.lines, "Today"),
                       [MetricValue(number: 0.25, kind: .dollars, estimated: true),
                        MetricValue(number: 150, kind: .count, label: "tokens")])
        XCTAssertFalse(snapshot.lines.contains { line in
            if case .badge(_, let value, _, _) = line { return value == "No usage data" }
            return false
        })
    }

    func testResetCreditsCancellationStopsProviderRefresh() async {
        let http = RoutingHTTPClient { request in
            if request.url == CodexUsageClient.usageURL {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data("{}".utf8))
            }
            if request.url == CodexUsageClient.resetCreditsURL {
                throw URLError(.cancelled)
            }
            XCTFail("unexpected Codex endpoint after cancellation: \(request.url)")
            return HTTPResponse(statusCode: 200, headers: [:], body: Data())
        }
        let provider = CodexProvider(
            authStore: CodexAuthStore(
                environment: FakeEnvironment(["CODEX_HOME": "/tmp/codex-home"]),
                files: FakeFiles(["/tmp/codex-home/auth.json": #"{"tokens":{"access_token":"token"}}"#]),
                keychain: FakeKeychain()
            ),
            usageClient: CodexUsageClient(http: http),
            logUsageScanner: CodexLogFixture.scanner(home: nil),
            proxyUsageScanner: CodexProxyUsageScanner(databasePaths: { [] }),
            routerUsageScanner: CodexRouterUsageScanner(ledgerPaths: { [] }, identityAliases: { [:] }),
            allowsUnattributedPiUsage: false
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .cancelled)
        XCTAssertEqual(http.requests.map(\.url), [CodexUsageClient.usageURL, CodexUsageClient.resetCreditsURL])
    }

    func testLateSuccessfulRefreshPersistsRotatedRefreshTokenBeforeReturningCancelled() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let path = "/tmp/codex-home/auth.json"
        let files = FakeFiles([
            path: """
            {"tokens":{"access_token":"old-access","refresh_token":"old-refresh"},"last_refresh":"\(OpenUsageISO8601.string(from: now.addingTimeInterval(-9 * 24 * 60 * 60)))"}
            """
        ])
        let gate = CodexRefreshResponseGate()
        let http = RoutingHTTPClient { request in
            guard request.url == CodexUsageClient.refreshURL else {
                XCTFail("quota requests must not follow a canceled token refresh: \(request.url)")
                return HTTPResponse(statusCode: 500, headers: [:], body: Data())
            }
            await gate.pause()
            return HTTPResponse(
                statusCode: 200,
                headers: [:],
                body: Data(#"{"access_token":"new-access","refresh_token":"new-refresh"}"#.utf8)
            )
        }
        let provider = CodexProvider(
            authStore: CodexAuthStore(
                environment: FakeEnvironment(["CODEX_HOME": "/tmp/codex-home"]),
                files: files,
                keychain: FakeKeychain(),
                now: { now }
            ),
            usageClient: CodexUsageClient(http: http),
            logUsageScanner: CodexLogFixture.scanner(home: nil),
            now: { now }
        )
        let refresh = Task { await provider.refresh() }

        await gate.waitUntilPaused()
        refresh.cancel()
        await gate.open()

        let snapshot = await refresh.value
        XCTAssertEqual(snapshot.errorCategory, .cancelled)
        XCTAssertEqual(http.requests.map(\.url), [CodexUsageClient.refreshURL])
        let saved = try XCTUnwrap(files.files[path]?.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        let tokens = try XCTUnwrap(object["tokens"] as? [String: Any])
        XCTAssertEqual(tokens["refresh_token"] as? String, "new-refresh")
    }

    func testLateRefreshDoesNotRecreateDeletedOrOverwriteSwitchedCodexLogin() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let path = "/tmp/codex-home/auth.json"
        let oldText = #"{"tokens":{"access_token":"old-access","refresh_token":"old-refresh"},"last_refresh":"2026-01-01T00:00:00.000Z"}"#
        let switchedText = #"{"tokens":{"access_token":"new-account-access","refresh_token":"new-account-refresh","account_id":"account-new"},"last_refresh":"2026-10-14T00:00:00.000Z"}"#
        let replacements: [String?] = [nil, switchedText]

        for replacement in replacements {
            let files = FakeFiles([path: oldText])
            let gate = CodexRefreshResponseGate()
            let http = RoutingHTTPClient { request in
                guard request.url == CodexUsageClient.refreshURL else {
                    XCTFail("a late refresh must not issue usage requests with the old account: \(request.url)")
                    return HTTPResponse(statusCode: 500, headers: [:], body: Data())
                }
                await gate.pause()
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"access_token":"late-access","refresh_token":"late-refresh"}"#.utf8))
            }
            let provider = CodexProvider(
                authStore: CodexAuthStore(
                    environment: FakeEnvironment(["CODEX_HOME": "/tmp/codex-home"]),
                    files: files,
                    keychain: FakeKeychain(),
                    now: { now }
                ),
                usageClient: CodexUsageClient(http: http),
                logUsageScanner: CodexLogFixture.scanner(home: nil),
                now: { now }
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
            // The live source changed under the refresh, so the provider keeps its last-good meters
            // and surfaces a warning rather than an auth error: nothing proves this device's
            // credential is invalid, only that the one in flight no longer matches the file.
            XCTAssertNil(snapshot.errorCategory)
            XCTAssertEqual(snapshot.warning?.hasPrefix("Live Codex limits unavailable:"), true)
            // The refresh response must never reach the usage API, and the file the user changed
            // must survive: logout stays logged out and an account switch keeps its own tokens.
            XCTAssertEqual(http.requests.map(\.url), [CodexUsageClient.refreshURL])
            XCTAssertEqual(files.files[path], replacement, "the late refresh must preserve logout or the replacement account")
        }
    }

    func testLocalHistoryReplacesStaleSnapshotWhenLiveQuotaAuthFails() async throws {
        let now = TestLocalInstant.date(2026, 2, 20, 12)
        let httpClient = FakeHTTPClient(response: HTTPResponse(
            statusCode: 401,
            headers: [:],
            body: Data(#"{"error":{"code":"refresh_token_invalidated"}}"#.utf8)
        ))
        let home = try CodexLogFixture.makeHome(files: [
            "sessions/rollout-1.jsonl": [
                CodexLogFixture.turnContext(timestamp: TestLocalInstant.iso(2026, 2, 20, 10), model: "gpt-5.2"),
                CodexLogFixture.tokenCount(
                    timestamp: TestLocalInstant.iso(2026, 2, 20, 10, 1),
                    last: CodexLogFixture.usage(input: 100, output: 50)
                )
            ].joined(separator: "\n")
        ])
        let provider = CodexProvider(
            authStore: CodexAuthStore(
                environment: FakeEnvironment(["CODEX_HOME": "/tmp/codex-home"]),
                files: FakeFiles([
                    "/tmp/codex-home/auth.json": #"{"tokens":{"access_token":"token","refresh_token":"refresh"}}"#
                ]),
                keychain: FakeKeychain()
            ),
            usageClient: CodexUsageClient(http: httpClient),
            logUsageScanner: CodexLogFixture.scanner(home: home),
            proxyUsageScanner: CodexProxyUsageScanner(databasePaths: { [] }),
            routerUsageScanner: CodexRouterUsageScanner(ledgerPaths: { [] }, identityAliases: { [:] }),
            initialAccountIdentityKey: "codex-fixture-account",
            allowsUnattributedPiUsage: false,
            now: { now },
            pricing: {
                ModelPricing(
                    supplement: PricingSupplement(),
                    primary: PricingCatalog(entries: ["gpt-5.2": ModelRates(
                        inputPerMillion: 1000, outputPerMillion: 3000,
                        cacheWritePerMillion: 1000, cacheReadPerMillion: 100
                    )]),
                    secondary: PricingCatalog(entries: [:])
                )
            }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(values(snapshot.lines, "Today"), [
            MetricValue(number: 0.25, kind: .dollars, estimated: true),
            MetricValue(number: 150, kind: .count, label: "tokens")
        ])
        XCTAssertTrue(snapshot.warning?.contains("Live Codex limits unavailable") == true)
        XCTAssertFalse(snapshot.lines.contains { line in
            if case .badge(_, let value, _, _) = line { return value == "No usage data" }
            return false
        })
    }

    func testLocalAccountingScopeFoldsLocallyWithoutQuotaAPICalls() async throws {
        let now = TestLocalInstant.date(2026, 2, 20, 12)
        // Any request at all would be the burn the closed-panel wake rate limit exists to prevent.
        let httpClient = FakeHTTPClient(response: HTTPResponse(statusCode: 200, headers: [:], body: Data("{}".utf8)))
        let home = try CodexLogFixture.makeHome(files: [
            "sessions/rollout-1.jsonl": [
                CodexLogFixture.turnContext(timestamp: TestLocalInstant.iso(2026, 2, 20, 10), model: "gpt-5.2"),
                CodexLogFixture.tokenCount(
                    timestamp: TestLocalInstant.iso(2026, 2, 20, 10, 1),
                    last: CodexLogFixture.usage(input: 100, output: 50)
                )
            ].joined(separator: "\n")
        ])
        let provider = CodexProvider(
            authStore: CodexAuthStore(
                environment: FakeEnvironment(["CODEX_HOME": "/tmp/codex-home"]),
                files: FakeFiles(["/tmp/codex-home/auth.json": #"{"tokens":{"access_token":"token"}}"#]),
                keychain: FakeKeychain()
            ),
            usageClient: CodexUsageClient(http: httpClient),
            logUsageScanner: CodexLogFixture.scanner(home: home),
            proxyUsageScanner: CodexProxyUsageScanner(databasePaths: { [] }),
            routerUsageScanner: CodexRouterUsageScanner(ledgerPaths: { [] }, identityAliases: { [:] }),
            initialAccountIdentityKey: "codex-fixture-account",
            allowsUnattributedPiUsage: false,
            now: { now },
            pricing: {
                ModelPricing(
                    supplement: PricingSupplement(),
                    primary: PricingCatalog(entries: ["gpt-5.2": ModelRates(
                        inputPerMillion: 1000, outputPerMillion: 3000,
                        cacheWritePerMillion: 1000, cacheReadPerMillion: 100
                    )]),
                    secondary: PricingCatalog(entries: [:])
                )
            }
        )

        let snapshot = await ProviderRefreshContext.$scope.withValue(.localAccounting) {
            await provider.refresh()
        }

        // Fresh local accounting (spend tiles) with no live quota meters and no network.
        XCTAssertEqual(values(snapshot.lines, "Today"),
                       [MetricValue(number: 0.25, kind: .dollars, estimated: true),
                        MetricValue(number: 150, kind: .count, label: "tokens")])
        XCTAssertNil(snapshot.plan)
        XCTAssertNil(snapshot.warning)
        XCTAssertTrue(httpClient.requests.isEmpty, "localAccounting scope must not re-read live quota APIs")
    }

    func testLocalAccountingReusesPriorNativeScanWhenAvailable() async throws {
        let now = TestLocalInstant.date(2026, 2, 20, 12)
        let httpClient = FakeHTTPClient(response: HTTPResponse(statusCode: 200, headers: [:], body: Data("{}".utf8)))
        let home = try CodexLogFixture.makeHome(files: [
            "sessions/rollout-1.jsonl": [
                CodexLogFixture.turnContext(timestamp: TestLocalInstant.iso(2026, 2, 20, 10), model: "gpt-5.2"),
                CodexLogFixture.tokenCount(
                    timestamp: TestLocalInstant.iso(2026, 2, 20, 10, 1),
                    last: CodexLogFixture.usage(input: 100, output: 50)
                )
            ].joined(separator: "\n")
        ])
        defer { try? FileManager.default.removeItem(at: home) }

        let provider = CodexProvider(
            authStore: CodexAuthStore(
                environment: FakeEnvironment(["CODEX_HOME": "/tmp/codex-home"]),
                files: FakeFiles(["/tmp/codex-home/auth.json": #"{"tokens":{"access_token":"token"}}"#]),
                keychain: FakeKeychain()
            ),
            usageClient: CodexUsageClient(http: httpClient),
            logUsageScanner: CodexLogFixture.scanner(home: home),
            proxyUsageScanner: CodexProxyUsageScanner(databasePaths: { [] }),
            routerUsageScanner: CodexRouterUsageScanner(ledgerPaths: { [] }, identityAliases: { [:] }),
            initialAccountIdentityKey: "codex-fixture-account",
            allowsUnattributedPiUsage: false,
            now: { now },
            pricing: {
                ModelPricing(
                    supplement: PricingSupplement(),
                    primary: PricingCatalog(entries: ["gpt-5.2": ModelRates(
                        inputPerMillion: 1000, outputPerMillion: 3000,
                        cacheWritePerMillion: 1000, cacheReadPerMillion: 100
                    )]),
                    secondary: PricingCatalog(entries: [:])
                )
            }
        )

        // First pass in .full scope runs all scans.
        let first = await ProviderRefreshContext.$scope.withValue(.full) {
            await provider.refresh()
        }
        XCTAssertEqual(values(first.lines, "Today"),
                       [MetricValue(number: 0.25, kind: .dollars, estimated: true),
                        MetricValue(number: 150, kind: .count, label: "tokens")])

        // Remove the home directory so that any re-scanning of native sessions would find nothing.
        try? FileManager.default.removeItem(at: home)

        // Second pass in .localAccounting scope reuses cached native scan.
        let second = await ProviderRefreshContext.$scope.withValue(.localAccounting) {
            await provider.refresh()
        }
        XCTAssertEqual(values(second.lines, "Today"),
                       [MetricValue(number: 0.25, kind: .dollars, estimated: true),
                        MetricValue(number: 150, kind: .count, label: "tokens")],
                       "localAccounting must reuse prior native scan without re-walking disk")
    }

    func testIncompletePiDiscoveryDoesNotPublishCodexOnlyHistory() async throws {
        let now = TestLocalInstant.date(2026, 2, 20, 12)
        let codexHome = try CodexLogFixture.makeHome(files: [
            "sessions/rollout-1.jsonl": [
                CodexLogFixture.turnContext(timestamp: TestLocalInstant.iso(2026, 2, 20, 10), model: "gpt-5.2"),
                CodexLogFixture.tokenCount(
                    timestamp: TestLocalInstant.iso(2026, 2, 20, 10, 1),
                    last: CodexLogFixture.usage(input: 100, output: 50)
                )
            ].joined(separator: "\n")
        ])
        defer { try? FileManager.default.removeItem(at: codexHome) }

        let piHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-pi-incomplete-\(UUID().uuidString)", isDirectory: true)
        let piSessions = piHome.appendingPathComponent(".pi/agent/sessions")
        try FileManager.default.createDirectory(
            at: piSessions.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("not a directory".utf8).write(to: piSessions)
        defer { try? FileManager.default.removeItem(at: piHome) }

        let http = RoutingHTTPClient { _ in
            XCTFail("local accounting must not make network requests")
            return HTTPResponse(statusCode: 500, headers: [:], body: Data())
        }
        let piScanner = PiUsageScanner(
            environment: FakeEnvironment([:]),
            homeDirectory: { piHome },
            incrementalScanner: IncrementalJSONLScanner<PiUsageScanner.Entry>()
        )
        let provider = CodexProvider(
            authStore: CodexAuthStore(
                environment: FakeEnvironment(["CODEX_HOME": "/tmp/codex-home"]),
                files: FakeFiles(["/tmp/codex-home/auth.json": #"{"tokens":{"access_token":"token"}}"#]),
                keychain: FakeKeychain()
            ),
            usageClient: CodexUsageClient(http: http),
            logUsageScanner: CodexLogFixture.scanner(home: codexHome),
            proxyUsageScanner: CodexProxyUsageScanner(databasePaths: { [] }),
            routerUsageScanner: CodexRouterUsageScanner(ledgerPaths: { [] }, identityAliases: { [:] }),
            piUsageScanner: piScanner,
            now: { now },
            pricing: { .empty }
        )

        let snapshot = await ProviderRefreshContext.$scope.withValue(.localAccounting) {
            await provider.refresh()
        }

        XCTAssertNil(snapshot.usageHistory, "the native-only subset cannot replace combined history")
        XCTAssertFalse(snapshot.lines.contains { ["Today", "Yesterday", "Last 30 Days", "Usage Trend"].contains($0.label) })
        XCTAssertTrue(http.requests.isEmpty)
    }

    private func values(_ lines: [MetricLine], _ label: String) -> [MetricValue]? {
        guard case .values(_, let values, _, _, _, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return values
    }
}

final class CodexUsageClientRefreshTests: XCTestCase {
    func testRefreshFormEncodesReservedCharactersInRequestBody() async throws {
        let http = FakeHTTPClient(response: HTTPResponse(
            statusCode: 200,
            headers: [:],
            body: Data(#"{"access_token":"new-token"}"#.utf8)
        ))
        let client = CodexUsageClient(http: http)

        _ = try await client.refreshToken("refresh token&=+/?%")

        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.headers["Content-Type"], "application/x-www-form-urlencoded")
        XCTAssertEqual(
            String(data: try XCTUnwrap(request.body), encoding: .utf8),
            "grant_type=refresh_token&client_id=app_EMoamEEZ73f0CkXaXp7hrann" +
                "&refresh_token=refresh%20token%26%3D%2B%2F%3F%25"
        )
    }

    func testRefreshReportsRequestFailuresForUnrecognizedAndServerErrors() async {
        for (status, body) in [(400, "<html>Bad Gateway</html>"), (503, "")] {
            let http = FakeHTTPClient(response: HTTPResponse(statusCode: status, headers: [:], body: Data(body.utf8)))
            do {
                _ = try await CodexUsageClient(http: http).refreshToken("refresh")
                XCTFail("expected status \(status) to throw")
            } catch let error as CodexUsageError {
                XCTAssertEqual(error, .requestFailed(status))
            } catch {
                XCTFail("expected CodexUsageError.requestFailed, got \(error)")
            }
        }
    }

    func testRefreshStillMapsKnownOAuthCodeToSessionExpired() async {
        let body = Data(#"{"error":{"code":"refresh_token_expired"}}"#.utf8)
        let http = FakeHTTPClient(response: HTTPResponse(statusCode: 400, headers: [:], body: body))
        let client = CodexUsageClient(http: http)
        do {
            _ = try await client.refreshToken("refresh")
            XCTFail("expected refreshToken to throw")
        } catch let error as CodexAuthError {
            XCTAssertEqual(error, .sessionExpired)
        } catch {
            XCTFail("expected CodexAuthError.sessionExpired, got \(error)")
        }
    }
}
