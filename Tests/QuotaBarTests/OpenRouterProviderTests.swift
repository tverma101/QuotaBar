import XCTest
@testable import QuotaBar

final class OpenRouterAuthStoreTests: XCTestCase {
    func testLoadsConfigFormatsBeforeEnvironmentAndSkipsBlankValues() {
        let primary = OpenRouterAuthStore.configPaths[0]
        let alternate = OpenRouterAuthStore.configPaths[1]
        let cases: [(name: String, files: [String: String], environment: [String: String], expected: String)] = [
            ("saved override", [primary: #"{"apiKey":"sk-or-file"}"#], ["OPENROUTER_API_KEY": "sk-or-env"], "sk-or-file"),
            ("environment fallback", [:], ["OPENROUTER_API_KEY": "sk-or-env"], "sk-or-env"),
            ("legacy JSON key", [primary: #"{"api_key":"sk-or-json"}"#], [:], "sk-or-json"),
            ("trimmed plain text", [alternate: "  sk-or-plain\n"], [:], "sk-or-plain"),
            ("blank config", [primary: "   "], ["OPENROUTER_API_KEY": "sk-or-env"], "sk-or-env")
        ]

        for entry in cases {
            let store = OpenRouterAuthStore(files: FakeFiles(entry.files), environment: FakeEnvironment(entry.environment))
            XCTAssertEqual(store.loadAPIKey()?.apiKey, entry.expected, entry.name)
        }
    }

    func testReturnsNilWhenNoKeyAnywhere() {
        let store = OpenRouterAuthStore(files: FakeFiles(), environment: FakeEnvironment())
        XCTAssertNil(store.loadAPIKey())
    }

    // MARK: - In-app save / delete / status (Customize → OpenRouter → API Key)

    func testSaveAPIKeyWritesTrimmedJSONConfigFile() throws {
        let files = FakeFiles()
        let store = OpenRouterAuthStore(files: files, environment: FakeEnvironment())

        try store.saveAPIKey("  sk-or-new  ")

        // Sorted-keys JSON, trimmed key — the exact bytes the auth store round-trips.
        XCTAssertEqual(files.files[OpenRouterAuthStore.configPaths[0]], #"{"apiKey":"sk-or-new"}"#)
        XCTAssertEqual(store.loadAPIKey()?.apiKey, "sk-or-new")
    }

    func testSaveAPIKeyRejectsEmptyKey() {
        let files = FakeFiles()
        let store = OpenRouterAuthStore(files: files, environment: FakeEnvironment())

        XCTAssertThrowsError(try store.saveAPIKey("   ")) { error in
            XCTAssertEqual(error as? OpenRouterAuthError, .missingKey)
        }
        XCTAssertNil(files.files[OpenRouterAuthStore.configPaths[0]])
    }

    func testSavedKeyOverridesEnvironment() throws {
        // Saving writes the config file, which the auth store checks before the env var — so the
        // saved key wins and the status reports overrideActive.
        let files = FakeFiles()
        let store = OpenRouterAuthStore(files: files, environment: FakeEnvironment(["OPENROUTER_API_KEY": "sk-or-env"]))

        try store.saveAPIKey("sk-or-saved")

        XCTAssertEqual(store.loadAPIKey()?.apiKey, "sk-or-saved")
        XCTAssertEqual(store.keyStatus(), .overrideActive)
    }

    func testKeyStatusReportsAllFourStates() {
        let envKey = ["OPENROUTER_API_KEY": "sk-or-env"]
        let file = [OpenRouterAuthStore.configPaths[0]: #"{"apiKey":"sk-or-file"}"#]

        XCTAssertEqual(OpenRouterAuthStore(files: FakeFiles(), environment: FakeEnvironment()).keyStatus(), .notSet)
        XCTAssertEqual(OpenRouterAuthStore(files: FakeFiles(), environment: FakeEnvironment(envKey)).keyStatus(), .fromEnvironment)
        XCTAssertEqual(OpenRouterAuthStore(files: FakeFiles(file), environment: FakeEnvironment()).keyStatus(), .saved)
        XCTAssertEqual(OpenRouterAuthStore(files: FakeFiles(file), environment: FakeEnvironment(envKey)).keyStatus(), .overrideActive)
        XCTAssertEqual(OpenRouterAuthStore(files: FakeFiles(file),
                                            environment: FakeEnvironment(["OPENROUTER_API_KEY": "sk-or-file"])).keyStatus(),
                       .overrideActive)
    }

    func testUnreadableSavedKeyStatusShowsRepairAndPreservesEnvironmentFallback() throws {
        let path = OpenRouterAuthStore.configPaths[0]
        let unreadableStore = OpenRouterAuthStore(
            files: UnreadableFiles(present: [path]),
            environment: FakeEnvironment()
        )
        let unreadableStatus = unreadableStore.keyStatus()

        XCTAssertEqual(unreadableStatus, .savedUnreadable)
        XCTAssertEqual(unreadableStatus.indicator, .needsAttention)
        XCTAssertEqual(unreadableStatus.editorMode, .savedUnreadable)

        let environmentStore = OpenRouterAuthStore(
            files: UnreadableFiles(present: [path]),
            environment: FakeEnvironment(["OPENROUTER_API_KEY": "sk-or-env"])
        )
        let environmentStatus = environmentStore.keyStatus()

        XCTAssertEqual(environmentStatus, .environmentFallback)
        XCTAssertEqual(environmentStatus.indicator, .needsAttention)
        XCTAssertEqual(environmentStatus.editorMode, .environmentFallback)
        XCTAssertEqual(try environmentStore.loadAPIKeyForRefresh()?.apiKey, "sk-or-env")
    }

    func testCurrentAPIKeyReturnsEffectiveKey() {
        let store = OpenRouterAuthStore(
            files: FakeFiles([OpenRouterAuthStore.configPaths[0]: #"{"apiKey":"sk-or-file"}"#]),
            environment: FakeEnvironment(["OPENROUTER_API_KEY": "sk-or-env"])
        )
        XCTAssertEqual(store.currentAPIKey(), "sk-or-file")
    }

    func testDeleteClearsPrimaryAndAlternatePathsWithEnvironmentFallback() throws {
        let cases: [(paths: [Int], environment: [String: String])] = [
            ([0], ["OPENROUTER_API_KEY": "sk-or-env"]),
            ([0], [:]),
            ([0, 1], [:]),
            ([1], [:])
        ]

        for entry in cases {
            let contents = Dictionary(uniqueKeysWithValues: entry.paths.map {
                (OpenRouterAuthStore.configPaths[$0], $0 == 0 ? #"{"apiKey":"sk-or-primary"}"# : "sk-or-alt")
            })
            let files = FakeFiles(contents)
            let store = OpenRouterAuthStore(files: files, environment: FakeEnvironment(entry.environment))

            try store.deleteAPIKey()

            for path in OpenRouterAuthStore.configPaths { XCTAssertNil(files.files[path], path) }
            XCTAssertEqual(store.loadAPIKey()?.apiKey, entry.environment["OPENROUTER_API_KEY"])
            XCTAssertEqual(store.keyStatus(), entry.environment.isEmpty ? .notSet : .fromEnvironment)
        }
    }

    func testDeleteAPIKeyIsNoOpWhenFileMissing() throws {
        // Removing a key that isn't there is the desired end state, not an error.
        let store = OpenRouterAuthStore(files: FakeFiles(), environment: FakeEnvironment())
        XCTAssertNoThrow(try store.deleteAPIKey())
        XCTAssertEqual(store.keyStatus(), .notSet)
    }

}

final class OpenRouterUsageMapperTests: XCTestCase {
    func testCreditsLinesGiveMeterAndBalance() throws {
        let lines = OpenRouterUsageMapper.creditsLines(from: ["total_credits": 277.47, "total_usage": 178.20])

        let credits = try XCTUnwrap(progress(lines, "Credits"))
        XCTAssertEqual(credits.used, 178.20, accuracy: 0.001)
        XCTAssertEqual(credits.limit, 277.47, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(dollars(lines, "Balance")), 99.27, accuracy: 0.001)
    }

    func testCreditsLinesEmptyWithoutUsableTotal() {
        XCTAssertTrue(OpenRouterUsageMapper.creditsLines(from: ["foo": "bar"]).isEmpty)
    }

    func testCreditsLinesDoNotInventZeroBalanceWhenPurchasedTotalIsMissing() {
        let lines = OpenRouterUsageMapper.creditsLines(from: ["total_usage": 2.5])

        XCTAssertTrue(lines.isEmpty)
    }

    func testNoCreditsMeterWhenNothingPurchased() {
        let lines = OpenRouterUsageMapper.creditsLines(from: ["total_credits": 0, "total_usage": 0])

        XCTAssertNil(progress(lines, "Credits"))
        // Balance is still shown as a real, measured zero — not "No data".
        XCTAssertEqual(dollars(lines, "Balance"), 0)
    }

    func testKeyMetricsGivePlanPeriodSpendAndCap() throws {
        let mapped = OpenRouterUsageMapper.keyMetrics(from: [
            "is_free_tier": false,
            "usage_daily": 0,
            "usage_weekly": 1.25,
            "usage_monthly": 4.5,
            "usage": 2,
            "limit": 5,
            "limit_remaining": 3
        ])

        XCTAssertEqual(mapped.plan, "Pay as you go")
        // A real, measured zero is shown — not collapsed to "No data".
        XCTAssertEqual(dollars(mapped.lines, "Today"), 0)
        XCTAssertEqual(dollars(mapped.lines, "This Week"), 1.25)
        XCTAssertEqual(dollars(mapped.lines, "This Month"), 4.5)
        let keyLimit = try XCTUnwrap(progress(mapped.lines, "Key Limit"))
        XCTAssertEqual(keyLimit.used, 2)
        XCTAssertEqual(keyLimit.limit, 5)
    }

    func testKeyLimitUsesCurrentWindowNotLifetimeUsage() throws {
        // After a daily/weekly/monthly reset, lifetime `usage` still includes prior windows.
        // `limit_remaining` is the current window, so used is limit - remaining — not lifetime.
        let mapped = OpenRouterUsageMapper.keyMetrics(from: [
            "usage": 12,
            "limit": 5,
            "limit_remaining": 3
        ])

        let keyLimit = try XCTUnwrap(progress(mapped.lines, "Key Limit"))
        XCTAssertEqual(keyLimit.used, 2)
        XCTAssertEqual(keyLimit.limit, 5)
    }

    func testKeyMetricsOmitCapWhenUnset() {
        let mapped = OpenRouterUsageMapper.keyMetrics(from: ["is_free_tier": true, "limit": NSNull()])

        XCTAssertEqual(mapped.plan, "Free tier")
        XCTAssertNil(progress(mapped.lines, "Key Limit"))
    }

    func testKeyLimitIsOmittedWhenTheRemainingAmountIsMissing() throws {
        // `limit_remaining` is the only evidence of how much of the cap is left. Treating a missing
        // field as zero published the cap as 100 % spent — a wrong number dressed as a measurement.
        DiagnosticGate.clearFailure(OpenRouterUsageMapper.missingLimitRemainingDiagnosticKey)
        let logs = try captureLogs {
            OpenRouterUsageMapper.keyMetrics(from: ["is_free_tier": false, "usage": 2, "limit": 5])
        }

        XCTAssertNil(progress(logs.lines, "Key Limit"), "a missing remaining amount is not a measured zero")
        XCTAssertTrue(logs.text.contains("limit"), "the missing field must leave a diagnostic: \(logs.text)")
    }

    func testKeyLimitIsOmittedWhenTheRemainingAmountIsNotNumeric() throws {
        DiagnosticGate.clearFailure(OpenRouterUsageMapper.missingLimitRemainingDiagnosticKey)
        let logs = try captureLogs {
            OpenRouterUsageMapper.keyMetrics(from: ["limit": 5, "limit_remaining": "many"])
        }

        XCTAssertNil(progress(logs.lines, "Key Limit"))
        XCTAssertFalse(logs.text.isEmpty, "an unparsable remaining amount must leave a diagnostic")
    }

    private func captureLogs(
        _ operation: () -> (plan: String?, lines: [MetricLine])
    ) throws -> (lines: [MetricLine], text: String) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsageTests.OpenRouter.\(UUID().uuidString)", isDirectory: true)
        let sink = LogFile(directory: directory, fileName: "OpenUsage.log")
        sink.open()
        let originalSink = AppLog.sink
        AppLog.sink = sink
        AppLog.reloadLevel(.warn)
        defer {
            AppLog.sink = originalSink
            AppLog.reloadLevel()
            try? FileManager.default.removeItem(at: directory)
        }

        let mapped = operation()
        let text = try String(contentsOf: sink.fileURL, encoding: .utf8)
        return (mapped.lines, text)
    }

    private func progress(_ lines: [MetricLine], _ label: String) -> (used: Double, limit: Double)? {
        guard case .progress(_, let used, let limit, _, _, _, _, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return (used, limit)
    }

    private func dollars(_ lines: [MetricLine], _ label: String) -> Double? {
        guard case .values(_, let values, _, _, _, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return values.first(where: { $0.kind == .dollars })?.number
    }
}

@MainActor
final class OpenRouterProviderTests: XCTestCase {
    func testCreditsCancellationStopsBeforeKeyEndpoint() async {
        let http = RoutingHTTPClient { _ in throw CancellationError() }
        let provider = OpenRouterProvider(
            authStore: makeAuthStore(key: "sk-or-test"),
            usageClient: OpenRouterUsageClient(http: http)
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .cancelled)
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(http.requests[0].url.absoluteString, OpenRouterUsageClient.creditsURL)
    }

    func testRefreshMapsBothEndpoints() async throws {
        let provider = OpenRouterProvider(
            authStore: makeAuthStore(key: "sk-or-test"),
            usageClient: OpenRouterUsageClient(http: RoutingHTTPClient { request in
                if request.url.absoluteString == OpenRouterUsageClient.creditsURL {
                    XCTAssertEqual(request.headers["Authorization"], "Bearer sk-or-test")
                    return jsonResponse(["data": ["total_credits": 100, "total_usage": 40]])
                }
                return jsonResponse(["data": ["is_free_tier": false, "usage_daily": 0.5]])
            }),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.plan, "Pay as you go")
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNotNil(snapshot.line(label: "Credits"))
        XCTAssertNotNil(snapshot.line(label: "Balance"))
        XCTAssertNotNil(snapshot.line(label: "Today"))
    }

    func testRefreshSurvivesKeyEndpointFailure() async {
        let provider = OpenRouterProvider(
            authStore: makeAuthStore(key: "sk-or-test"),
            usageClient: OpenRouterUsageClient(http: RoutingHTTPClient { request in
                if request.url.absoluteString == OpenRouterUsageClient.creditsURL {
                    return jsonResponse(["data": ["total_credits": 100, "total_usage": 40]])
                }
                throw OpenRouterUsageError.connectionFailed
            })
        )

        let snapshot = await provider.refresh()

        XCTAssertFalse(snapshot.lines.contains { $0.isError })
        XCTAssertNotNil(snapshot.line(label: "Balance"))
    }

    func testRefreshShowsKeyDataWhenCreditsForbidden() async {
        // If `/credits` is gated (403) but `/key` succeeds, still show the spend rows rather than erroring.
        let provider = OpenRouterProvider(
            authStore: makeAuthStore(key: "sk-or-test"),
            usageClient: OpenRouterUsageClient(http: RoutingHTTPClient { request in
                if request.url.absoluteString == OpenRouterUsageClient.creditsURL {
                    return HTTPResponse(statusCode: 403, headers: [:], body: Data("{}".utf8))
                }
                return jsonResponse(["data": ["is_free_tier": false, "usage_daily": 0.5, "usage_weekly": 2]])
            })
        )

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertFalse(snapshot.lines.contains { $0.isError })
        XCTAssertNotNil(snapshot.line(label: "Today"))
        XCTAssertNil(snapshot.line(label: "Balance"))
    }

    func testRefreshWithoutKeyReportsNotLoggedIn() async {
        let provider = OpenRouterProvider(
            authStore: OpenRouterAuthStore(files: FakeFiles(), environment: FakeEnvironment()),
            usageClient: OpenRouterUsageClient(http: RoutingHTTPClient { _ in
                XCTFail("should not hit the network without a key")
                return jsonResponse([:])
            })
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.lines.first?.label, "Error")
        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
    }

    func testUnreadableSavedKeyRemainsDetectedAndSurfacesCredentialAccess() async {
        let path = OpenRouterAuthStore.configPaths[0]
        let provider = OpenRouterProvider(
            authStore: OpenRouterAuthStore(
                files: UnreadableFiles(present: [path]),
                environment: FakeEnvironment()
            ),
            usageClient: OpenRouterUsageClient(http: RoutingHTTPClient { _ in
                XCTFail("should not hit the network without a readable key")
                return jsonResponse([:])
            })
        )

        let detected = await provider.hasLocalCredentials()
        let snapshot = await provider.refresh()

        XCTAssertTrue(detected)
        XCTAssertEqual(snapshot.errorCategory, .credentialAccess)
    }

    func testRefreshOnAuthFailureReportsInvalidKey() async {
        // Both endpoints reject the key — nothing usable comes back, so it's a hard auth failure.
        let provider = OpenRouterProvider(
            authStore: makeAuthStore(key: "sk-or-bad"),
            usageClient: OpenRouterUsageClient(http: RoutingHTTPClient { _ in
                HTTPResponse(statusCode: 401, headers: [:], body: Data("{}".utf8))
            })
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .authInvalid)
    }

    func testRefreshDoesNotReportInvalidKeyWhenOnlyCreditsForbidden() async {
        // `/credits` 403 (gated for this key type) but `/key` 200 — the key is valid, just gated for
        // credits. With no usable lines, the error must NOT be "invalid key" (it's not the key's fault).
        let provider = OpenRouterProvider(
            authStore: makeAuthStore(key: "sk-or-test"),
            usageClient: OpenRouterUsageClient(http: RoutingHTTPClient { request in
                if request.url.absoluteString == OpenRouterUsageClient.creditsURL {
                    return HTTPResponse(statusCode: 403, headers: [:], body: Data("{}".utf8))
                }
                // `/key` returns 200 but with no usable fields → no metric lines.
                return jsonResponse(["data": [:]])
            })
        )

        let snapshot = await provider.refresh()

        XCTAssertNotEqual(snapshot.errorCategory, .authInvalid)
    }

    func testProviderAPIKeyManagingDelegatesToAuthStore() throws {
        let files = FakeFiles()
        let provider = OpenRouterProvider(
            authStore: OpenRouterAuthStore(files: files, environment: FakeEnvironment(["OPENROUTER_API_KEY": "sk-or-env"])),
            usageClient: OpenRouterUsageClient(http: RoutingHTTPClient { _ in jsonResponse([:]) })
        )

        XCTAssertEqual(provider.apiKeyStatus, .fromEnvironment)
        XCTAssertEqual(provider.currentAPIKey(), "sk-or-env")

        try provider.saveAPIKey("sk-or-saved")
        XCTAssertEqual(provider.apiKeyStatus, .overrideActive)
        XCTAssertEqual(provider.currentAPIKey(), "sk-or-saved")

        try provider.deleteAPIKey()
        XCTAssertEqual(provider.apiKeyStatus, .fromEnvironment)
    }

    func testUnreadableSavedKeyFallsBackToEnvironmentForRefresh() throws {
        let store = OpenRouterAuthStore(
            files: UnreadableFiles(present: [OpenRouterAuthStore.configPaths[0]]),
            environment: FakeEnvironment(["OPENROUTER_API_KEY": "sk-or-env"])
        )

        XCTAssertEqual(try store.loadAPIKeyForRefresh()?.apiKey, "sk-or-env")
    }

    private func makeAuthStore(key: String) -> OpenRouterAuthStore {
        OpenRouterAuthStore(files: FakeFiles(), environment: FakeEnvironment(["OPENROUTER_API_KEY": key]))
    }
}

private func jsonResponse(_ object: [String: Any]) -> HTTPResponse {
    let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    return HTTPResponse(statusCode: 200, headers: [:], body: body)
}
