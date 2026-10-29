import XCTest
@testable import QuotaBar

/// The Go endpoint accepts only the opencode-go credential. App-saved Go keys provide the explicit
/// multi-account path; exact duplicate credentials collapse while different credentials stay separate
/// even when their current windows happen to match.
@MainActor
final class OpenCodeMultiKeyTests: XCTestCase {

    /// Hermetic app-saved-key store: a fake path, so tests never read the real go-keys file
    /// (which lives in Application Support and is written by the running app).
    private func goKeyStoreStub() -> OpenCodeGoKeyStore {
        OpenCodeGoKeyStore(files: FakeFiles(), filePath: { "/oc/go-keys.json" })
    }
    private let authJSON = #"{"opencode-go":{"type":"api","key":"sk-go"},"opencode":{"type":"api","key":"sk-zen"}}"#
    private let goFirstAuthJSON = #"{"opencode":{"type":"api","key":"sk-zen"},"opencode-go":{"type":"api","key":"sk-go"}}"#

    private func authStore(files: TextFileAccessing) -> OpenCodeAuthStore {
        OpenCodeAuthStore(
            files: files,
            environment: FakeEnvironment(["OPENCODE_DATA_DIR": "/oc"]),
            homeDirectory: { URL(fileURLWithPath: "/nonexistent") }
        )
    }

    /// Returns canned responses in order — one per request — so a two-key refresh sees two answers.
    private final class SequenceHTTPClient: HTTPClient, @unchecked Sendable {
        var responses: [HTTPResponse]
        var requests: [HTTPRequest] = []
        init(_ responses: [HTTPResponse]) { self.responses = responses }
        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            requests.append(request)
            if responses.count == 1 { return responses[0] }
            return responses.isEmpty ? HTTPResponse(statusCode: 500, headers: [:], body: Data()) : responses.removeFirst()
        }
    }

    private final class StubSQLite: SQLiteAccessing, @unchecked Sendable {
        var data: [String: String]
        var failingPaths: Set<String>
        init(data: [String: String] = [:], failingPaths: Set<String> = []) {
            self.data = data
            self.failingPaths = failingPaths
        }
        func queryValue(path: String, sql: String) throws -> String? {
            if failingPaths.contains(path) { throw CocoaError(.fileReadNoPermission) }
            if sql.contains("json_group_array") { return data[path] ?? "[]" }
            if sql.contains("SELECT 1") { return data[path] == nil ? nil : "1" }
            return nil
        }
        func execute(path: String, sql: String) throws {
            if failingPaths.contains(path) { throw CocoaError(.fileReadNoPermission) }
        }
    }

    private func provider(
        authJSON: String,
        http: HTTPClient,
        db: String? = nil,
        storedKeys: [OpenCodeGoKey] = [],
        activeKeyID: @escaping @Sendable () -> String? = { nil },
        now: @escaping @Sendable () -> Date = { OpenUsageISO8601.date(from: "2026-07-12T12:00:00.000Z")! }
    ) -> OpenCodeProvider {
        let dbPath = "/oc/opencode.db"
        let keyStoreFiles: [String: String]
        if storedKeys.isEmpty {
            keyStoreFiles = ["/oc/go-keys.json": "[]"]
        } else {
            let data = try! JSONEncoder().encode(storedKeys)
            keyStoreFiles = ["/oc/go-keys.json": String(data: data, encoding: .utf8)!]
        }
        return OpenCodeProvider(
            authStore: authStore(files: FakeFiles(["/oc/auth.json": authJSON])),
            usageScanner: OpenCodeUsageScanner(
                sqlite: StubSQLite(data: db.map { [dbPath: $0] } ?? [:]),
                databasePaths: { db == nil ? [] : [dbPath] }
            ),
            usageClient: OpenCodeGoUsageClient(http: http),
            now: now,
            goKeyStore: OpenCodeGoKeyStore(files: FakeFiles(keyStoreFiles), filePath: { "/oc/go-keys.json" }),
            activeKeyID: activeKeyID
        )
    }

    private static func payload(rolling: Int, weekly: Int, monthly: Int) -> Data {
        Data("""
        {"usage":{"rolling":{"status":"ok","percent":\(rolling),"resetsAt":"2026-08-12T03:53:00.000Z"},"weekly":{"status":"ok","percent":\(weekly),"resetsAt":"2026-08-17T00:00:00.000Z"},"monthly":{"status":"ok","percent":\(monthly),"resetsAt":"2026-08-31T01:28:22.000Z"}}}
        """.utf8)
    }

    // MARK: - Auth store

    func testApiKeysReturnsOnlyGoKeyRegardlessOfFileOrder() throws {
        for json in [authJSON, goFirstAuthJSON] {
            let keys = try authStore(files: FakeFiles(["/oc/auth.json": json])).apiKeys()
            XCTAssertEqual(keys.map(\.name), ["opencode-go"])
            XCTAssertEqual(keys.map(\.key), ["sk-go"])
        }
    }

    func testApiKeysSkipsNonApiAndEmptyEntries() throws {
        let mixed = #"{"opencode-go":{"type":"api","key":"sk-go"},"opencode":{"type":"api","key":""},"other":{"type":"oauth","key":"sk-x"}}"#
        let keys = try authStore(files: FakeFiles(["/oc/auth.json": mixed])).apiKeys()
        XCTAssertEqual(keys.map(\.name), ["opencode-go"])
    }

    func testApiKeysEmptyWhenAbsent() throws {
        let keys = try authStore(files: FakeFiles()).apiKeys()
        XCTAssertTrue(keys.isEmpty)
    }

    func testAccountInventoryFingerprintsSingleAndEmptyCredentialSets() async {
        let authFiles = FakeFiles([
            "/oc/auth.json": #"{"opencode-go":{"type":"api","key":"sk-first"}}"#
        ])
        let keyFiles = FakeFiles(["/oc/go-keys.json": "[]"])
        let keys = OpenCodeGoKeyStore(files: keyFiles, filePath: { "/oc/go-keys.json" })
        let auth = authStore(files: authFiles)

        let first = await OpenCodeProvider.discoverAccountInventory(authStore: auth, goKeyStore: keys)
        XCTAssertTrue(first.isComplete)
        XCTAssertEqual(first.credentialIDs.count, 1)
        XCTAssertTrue(first.identities.isEmpty, "one account keeps the established generic meter labels")

        authFiles.files["/oc/auth.json"] = #"{"opencode-go":{"type":"api","key":"sk-rotated"}}"#
        let rotated = await OpenCodeProvider.discoverAccountInventory(authStore: auth, goKeyStore: keys)
        XCTAssertNotEqual(first.cacheIdentityKey, rotated.cacheIdentityKey)

        authFiles.files["/oc/auth.json"] = "{}"
        let empty = await OpenCodeProvider.discoverAccountInventory(authStore: auth, goKeyStore: keys)
        XCTAssertTrue(empty.isComplete)
        XCTAssertTrue(empty.credentialIDs.isEmpty)
        XCTAssertNotEqual(first.cacheIdentityKey, empty.cacheIdentityKey)
        XCTAssertNotEqual(empty.cacheIdentityKey, OpenCodeGoAccountInventory.incompleteCacheIdentityKey)
    }

    func testAccountInventoryFingerprintChangesWhenLabelsAreReassigned() async {
        let firstID = UUID()
        let secondID = UUID()
        let keyFiles = FakeFiles(["/oc/go-keys.json": "[]"])
        let keyStore = OpenCodeGoKeyStore(files: keyFiles, filePath: { "/oc/go-keys.json" })
        let auth = authStore(files: FakeFiles(["/oc/auth.json": "{}"]))
        let firstKeys = [
            OpenCodeGoKey(id: firstID, label: "Work", key: "sk-first"),
            OpenCodeGoKey(id: secondID, label: "Personal", key: "sk-second")
        ]
        keyFiles.files["/oc/go-keys.json"] = String(decoding: try! JSONEncoder().encode(firstKeys), as: UTF8.self)
        let firstInventory = await OpenCodeProvider.discoverAccountInventory(authStore: auth, goKeyStore: keyStore)

        let reassignedKeys = [
            OpenCodeGoKey(id: firstID, label: "Personal", key: "sk-first"),
            OpenCodeGoKey(id: secondID, label: "Work", key: "sk-second")
        ]
        keyFiles.files["/oc/go-keys.json"] = String(decoding: try! JSONEncoder().encode(reassignedKeys), as: UTF8.self)
        let reassignedInventory = await OpenCodeProvider.discoverAccountInventory(authStore: auth, goKeyStore: keyStore)

        XCTAssertEqual(firstInventory.credentialIDs, reassignedInventory.credentialIDs)
        XCTAssertNotEqual(firstInventory.cacheIdentityKey, reassignedInventory.cacheIdentityKey)
    }

    func testIncompleteAccountInventoryIsDistinctFromCompleteEmptyInventory() async {
        let saved = OpenCodeGoKey(id: UUID(), label: "Work", key: "sk-work")
        let savedData = try! JSONEncoder().encode([saved])
        let savedStore = OpenCodeGoKeyStore(
            files: FakeFiles(["/oc/go-keys.json": String(decoding: savedData, as: UTF8.self)]),
            filePath: { "/oc/go-keys.json" }
        )
        let incomplete = await OpenCodeProvider.discoverAccountInventory(
            authStore: authStore(files: UnreadableFiles(present: ["/oc/auth.json"])),
            goKeyStore: savedStore
        )

        XCTAssertFalse(incomplete.isComplete)
        XCTAssertEqual(incomplete.cacheIdentityKey, OpenCodeGoAccountInventory.incompleteCacheIdentityKey)
        XCTAssertTrue(incomplete.identities.isEmpty, "a partial one-key read must not imply a complete single-account inventory")

        let emptyKeyStore = OpenCodeGoKeyStore(
            files: FakeFiles(["/oc/go-keys.json": "[]"]),
            filePath: { "/oc/go-keys.json" }
        )
        let empty = await OpenCodeProvider.discoverAccountInventory(
            authStore: authStore(files: FakeFiles(["/oc/auth.json": "{}"])),
            goKeyStore: emptyKeyStore
        )
        XCTAssertTrue(empty.isComplete)
        XCTAssertNotEqual(incomplete.cacheIdentityKey, empty.cacheIdentityKey)
    }

    func testPartialSingleKeyInventoryWithholdsQuotaAndStillScansLocalHistory() async {
        let saved = OpenCodeGoKey(id: UUID(), label: "Work", key: "sk-work")
        let savedData = try! JSONEncoder().encode([saved])
        let savedStore = OpenCodeGoKeyStore(
            files: FakeFiles(["/oc/go-keys.json": String(decoding: savedData, as: UTF8.self)]),
            filePath: { "/oc/go-keys.json" }
        )
        let auth = authStore(files: UnreadableFiles(present: ["/oc/auth.json"]))
        let inventory = await OpenCodeProvider.discoverAccountInventory(authStore: auth, goKeyStore: savedStore)
        XCTAssertFalse(inventory.isComplete)

        let now = OpenUsageISO8601.date(from: "2026-07-12T12:00:00.000Z")!
        let timestamp = Int(OpenUsageISO8601.date(from: "2026-07-12T11:00:00.000Z")!.timeIntervalSince1970 * 1000)
        let sqlite = StubSQLite(data: ["/oc/opencode.db": "[[\(timestamp),1,40,\"glm-5.2\",\"opencode\"]]"])
        let http = SequenceHTTPClient([])
        let runtime = OpenCodeProvider(
            authStore: auth,
            usageScanner: OpenCodeUsageScanner(sqlite: sqlite, databasePaths: { ["/oc/opencode.db"] }),
            usageClient: OpenCodeGoUsageClient(http: http),
            now: { now },
            goKeyStore: savedStore,
            preloadedAccountInventory: inventory
        )
        let registry = WidgetRegistry.from([runtime])
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cache = ProviderSnapshotCache(
            userDefaults: defaults,
            storageKey: "opencode-partial-single-key.snapshot",
            ttl: 600,
            now: { now }
        )
        var previous = ProviderSnapshot(
            providerID: "opencode",
            displayName: "OpenCode",
            plan: "Go",
            lines: [.progress(label: "Session", used: 60, limit: 100, format: .percent)],
            refreshedAt: now,
            usageHistory: ProviderUsageHistory(series: DailyUsageSeries(daily: [
                DailyUsageEntry(date: "2026-07-12", totalTokens: 100, costUSD: 1)
            ]))
        )
        previous.quotaRefreshedAt = now
        cache.store(previous, producedByIdentityKey: "previous-complete-inventory")
        let dataStore = WidgetDataStore(
            registry: registry,
            providers: [runtime],
            cache: cache,
            defaults: defaults,
            now: { now },
            providerIdentityKeys: ["opencode": inventory.cacheIdentityKey]
        )

        XCTAssertNil(dataStore.localSnapshots["opencode"]?.plan, "incomplete discovery must hide caps already cached under a prior inventory")
        XCTAssertEqual(dataStore.localSnapshots["opencode"]?.usageHistory?.series.daily.first?.totalTokens, 100)

        let outcome = await dataStore.refresh(providerID: "opencode", force: true)

        XCTAssertEqual(outcome, .failed)
        XCTAssertTrue(http.requests.isEmpty, "a partial credential inventory must not publish its surviving key")
        XCTAssertNil(dataStore.localSnapshots["opencode"]?.plan)
        XCTAssertNil(dataStore.localSnapshots["opencode"]?.line(label: "Session"))
        XCTAssertEqual(dataStore.localSnapshots["opencode"]?.usageHistory?.series.daily.first?.totalTokens, 40)
        let today = try! XCTUnwrap(registry.descriptors(for: "opencode").first { $0.metricLabel == "Today" })
        XCTAssertTrue(dataStore.data(for: today).hasData, "local spend remains available while the Go-key inventory is incomplete")
    }

    func testRuntimeCredentialReadFailureClearsCapsDuringMeterAndFoldScopes() async {
        let knownAuth = authStore(files: FakeFiles([
            "/oc/auth.json": #"{"opencode-go":{"type":"api","key":"sk-known"}}"#
        ]))
        let keyStore = OpenCodeGoKeyStore(files: FakeFiles(["/oc/go-keys.json": "[]"]), filePath: { "/oc/go-keys.json" })
        let inventory = await OpenCodeProvider.discoverAccountInventory(authStore: knownAuth, goKeyStore: keyStore)
        XCTAssertTrue(inventory.isComplete)

        let runtime = OpenCodeProvider(
            authStore: authStore(files: UnreadableFiles(present: ["/oc/auth.json"])),
            usageScanner: OpenCodeUsageScanner(
                sqlite: StubSQLite(failingPaths: ["/oc/opencode.db"]),
                databasePaths: { ["/oc/opencode.db"] }
            ),
            usageClient: OpenCodeGoUsageClient(http: SequenceHTTPClient([])),
            goKeyStore: keyStore,
            preloadedAccountInventory: inventory
        )
        let registry = WidgetRegistry.from([runtime])
        let meter = try! XCTUnwrap(registry.descriptors(for: "opencode").first { $0.metricLabel == "Session" })
        let history = ProviderUsageHistory(series: DailyUsageSeries(daily: [
            DailyUsageEntry(date: "2026-10-14", totalTokens: 200, costUSD: 2)
        ]))

        for scope in [ProviderRefreshContext.Scope.menuBar, .panelAccounting] {
            let (defaults, suiteName) = makeDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "opencode-unreadable-\(scope)", ttl: 600, now: { now })
            cache.store(ProviderSnapshot(
                providerID: "opencode",
                displayName: "OpenCode",
                plan: "Go",
                lines: [.progress(label: "Session", used: 50, limit: 100, format: .percent)],
                refreshedAt: now,
                usageHistory: history
            ), producedByIdentityKey: inventory.cacheIdentityKey)
            let dataStore = WidgetDataStore(
                registry: registry,
                providers: [runtime],
                cache: cache,
                defaults: defaults,
                now: { now },
                providerIdentityKeys: ["opencode": inventory.cacheIdentityKey]
            )
            XCTAssertEqual(dataStore.localSnapshots["opencode"]?.plan, "Go")

            let outcome = await ProviderRefreshContext.$scope.withValue(scope) {
                await dataStore.refresh(providerID: "opencode", force: true)
            }

            XCTAssertEqual(outcome, .failed)
            XCTAssertNil(dataStore.localSnapshots["opencode"]?.plan, "an unverified credential inventory must clear caps in \(scope)")
            XCTAssertNil(dataStore.localSnapshots["opencode"]?.line(label: meter.metricLabel))
            XCTAssertEqual(dataStore.localSnapshots["opencode"]?.usageHistory?.series.daily.first?.totalTokens, 200)
        }
    }

    func testSingleAccountRotationRequestsCatalogRebuildBeforeQuotaFetch() async {
        let authFiles = FakeFiles([
            "/oc/auth.json": #"{"opencode-go":{"type":"api","key":"sk-first"}}"#
        ])
        let auth = authStore(files: authFiles)
        let keyStore = OpenCodeGoKeyStore(files: FakeFiles(["/oc/go-keys.json": "[]"]), filePath: { "/oc/go-keys.json" })
        let preloaded = await OpenCodeProvider.discoverAccountInventory(authStore: auth, goKeyStore: keyStore)
        XCTAssertTrue(preloaded.identities.isEmpty)

        authFiles.files["/oc/auth.json"] = #"{"opencode-go":{"type":"api","key":"sk-rotated"}}"#
        var requestedReload = false
        let http = SequenceHTTPClient([])
        let runtime = OpenCodeProvider(
            authStore: auth,
            usageScanner: OpenCodeUsageScanner(sqlite: StubSQLite(), databasePaths: { [] }),
            usageClient: OpenCodeGoUsageClient(http: http),
            goKeyStore: keyStore,
            onGoKeysChanged: { requestedReload = true },
            preloadedAccountInventory: preloaded
        )

        let snapshot = await runtime.refresh()

        XCTAssertTrue(requestedReload)
        XCTAssertEqual(snapshot.errorCategory, .cancelled)
        XCTAssertTrue(http.requests.isEmpty, "do not request quota with a key absent from the catalog identity stamp")
    }

    // MARK: - Provider: per-key fetch + dedupe

    func testSameAccountKeysRenderOneMeterSet() async {
        // The same credential is present in auth.json and the app-saved store: one request and one
        // unsuffixed meter set, while both source entries remain selectable in Settings.
        let http = SequenceHTTPClient([
            HTTPResponse(statusCode: 200, headers: [:], body: Self.payload(rolling: 7, weekly: 26, monthly: 79)),
            HTTPResponse(statusCode: 200, headers: [:], body: Self.payload(rolling: 7, weekly: 26, monthly: 79))
        ])
        let duplicate = OpenCodeGoKey(id: UUID(), label: "Duplicate", key: "sk-go")
        let snapshot = await provider(authJSON: authJSON, http: http, storedKeys: [duplicate]).refresh()
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(http.requests.map { $0.headers["Authorization"] }, ["Bearer sk-go"])
        XCTAssertEqual(snapshot.line(label: "Session")?.label, "Session")
        XCTAssertNil(snapshot.line(label: "Session (opencode-go)"))
        guard case let .progress(_, used, _, _, _, _, _, _)? = snapshot.line(label: "Session") else {
            return XCTFail("expected a Session meter")
        }
        XCTAssertEqual(used, 7)
    }

    func testSelectedSavedCopyUsesTheSuccessfulAuthFileDuplicate() async throws {
        let saved = OpenCodeGoKey(id: UUID(), label: "Saved copy", key: "sk-go")
        let http = SequenceHTTPClient([
            HTTPResponse(statusCode: 200, headers: [:], body: Self.payload(rolling: 19, weekly: 26, monthly: 79))
        ])
        let snapshot = await provider(
            authJSON: authJSON,
            http: http,
            storedKeys: [saved],
            activeKeyID: { saved.id.uuidString }
        ).refresh()

        XCTAssertEqual(http.requests.count, 1, "exact duplicate credentials should not issue competing requests")
        let session = try XCTUnwrap(snapshot.line(label: "Session"))
        guard case let .progress(_, used, _, _, _, _, _, _) = session else {
            return XCTFail("the selected duplicate must resolve to the successful account response")
        }
        XCTAssertEqual(used, 19)
    }

    func testDistinctAccountsRenderSuffixedRows() async {
        // Different credentials answer with different windows: separate meter rows per key.
        let http = SequenceHTTPClient([
            HTTPResponse(statusCode: 200, headers: [:], body: Self.payload(rolling: 7, weekly: 26, monthly: 79)),
            HTTPResponse(statusCode: 200, headers: [:], body: Self.payload(rolling: 55, weekly: 60, monthly: 90))
        ])
        let work = OpenCodeGoKey(id: UUID(), label: "Work", key: "sk-work")
        let snapshot = await provider(authJSON: authJSON, http: http, storedKeys: [work]).refresh()
        XCTAssertEqual(snapshot.line(label: "Session (opencode-go)")?.label, "Session (opencode-go)")
        XCTAssertEqual(snapshot.line(label: "Session (Work)")?.label, "Session (Work)")
        XCTAssertNil(snapshot.line(label: "Session"))
        guard case let .progress(_, firstUsed, _, _, _, _, _, _)? = snapshot.line(label: "Session (opencode-go)"),
              case let .progress(_, secondUsed, _, _, _, _, _, _)? = snapshot.line(label: "Session (Work)") else {
            return XCTFail("expected per-key meters")
        }
        XCTAssertEqual(firstUsed, 7)
        XCTAssertEqual(secondUsed, 55)
    }

    func testMultiAccountRowsResolveThroughRegistryDataStoreAndDefaultLayout() async throws {
        let work = OpenCodeGoKey(id: UUID(), label: "Work", key: "sk-work")
        let runtime = provider(
            authJSON: authJSON,
            http: SequenceHTTPClient([
                HTTPResponse(statusCode: 200, headers: [:], body: Self.payload(rolling: 7, weekly: 26, monthly: 79)),
                HTTPResponse(statusCode: 200, headers: [:], body: Self.payload(rolling: 55, weekly: 60, monthly: 90))
            ]),
            storedKeys: [work]
        )
        let registry = WidgetRegistry.from([runtime])
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cache = ProviderSnapshotCache(
            userDefaults: defaults,
            storageKey: "opencode-multi-account.snapshot",
            ttl: 600,
            now: { Date() }
        )
        let dataStore = WidgetDataStore(registry: registry, providers: [runtime], cache: cache, defaults: defaults)
        let layout = LayoutStore(
            registry: registry,
            defaults: defaults,
            defaultMetricIDs: AppContainer.accountScopedDefaults(["opencode.session"], registry: registry)
        )

        let outcome = await dataStore.refresh(providerID: "opencode", force: true)
        XCTAssertEqual(outcome, .refreshed)
        let sessionRows = registry.descriptors(for: "opencode").filter {
            $0.metricLabel.hasPrefix("Session (")
        }
        XCTAssertEqual(sessionRows.map(\.metricLabel).sorted(), ["Session (Work)", "Session (opencode-go)"])

        let workRow = try XCTUnwrap(sessionRows.first { $0.metricLabel == "Session (Work)" })
        let defaultRow = try XCTUnwrap(sessionRows.first { $0.metricLabel == "Session (opencode-go)" })
        let workData = dataStore.data(for: workRow)
        let defaultData = dataStore.data(for: defaultRow)
        XCTAssertTrue(workData.hasData)
        XCTAssertTrue(defaultData.hasData)
        XCTAssertEqual(workData.used, 55)
        XCTAssertEqual(defaultData.used, 7)
        XCTAssertTrue(layout.placed.contains { $0.descriptorID == workRow.id })
        XCTAssertTrue(layout.placed.contains { $0.descriptorID == defaultRow.id })
        XCTAssertTrue(layout.showsRow(workRow, hasData: workData.hasData))
        XCTAssertTrue(layout.showsRow(defaultRow, hasData: defaultData.hasData))
    }

    func testSuccessfulAccountStaysAttributedWhenAnotherAccountAPIRequestFails() async throws {
        let work = OpenCodeGoKey(id: UUID(), label: "Work", key: "sk-work")
        let runtime = provider(
            authJSON: authJSON,
            http: SequenceHTTPClient([
                HTTPResponse(statusCode: 200, headers: [:], body: Self.payload(rolling: 7, weekly: 26, monthly: 79)),
                HTTPResponse(statusCode: 503, headers: [:], body: Data())
            ]),
            storedKeys: [work]
        )
        let registry = WidgetRegistry.from([runtime])
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let dataStore = WidgetDataStore(
            registry: registry,
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "opencode-partial.snapshot", ttl: 600),
            defaults: defaults
        )

        let outcome = await dataStore.refresh(providerID: "opencode", force: true)

        XCTAssertEqual(outcome, .refreshed)
        let opencodeSession = try XCTUnwrap(registry.descriptors(for: "opencode").first {
            $0.metricLabel == "Session (opencode-go)"
        })
        let workSession = try XCTUnwrap(registry.descriptors(for: "opencode").first {
            $0.metricLabel == "Session (Work)"
        })
        let genericSession = try XCTUnwrap(registry.descriptor(id: "opencode.session"))
        XCTAssertTrue(dataStore.data(for: opencodeSession).hasData)
        XCTAssertEqual(dataStore.data(for: opencodeSession).used, 7)
        XCTAssertFalse(dataStore.data(for: workSession).hasData)
        XCTAssertFalse(dataStore.data(for: genericSession).hasData)
    }

    func testDistinctAccountLabelsCannotCollideWithGeneratedSuffixes() async throws {
        let accounts = [
            OpenCodeGoKey(id: UUID(), label: "Work", key: "sk-work-a"),
            OpenCodeGoKey(id: UUID(), label: "Work", key: "sk-work-b"),
            OpenCodeGoKey(id: UUID(), label: "Work · 1", key: "sk-work-c")
        ]
        let responses = [7, 17, 27, 37].map { value in
            HTTPResponse(statusCode: 200, headers: [:], body: Self.payload(rolling: value, weekly: value + 1, monthly: value + 2))
        }
        let runtime = provider(authJSON: authJSON, http: SequenceHTTPClient(responses), storedKeys: accounts)
        let registry = WidgetRegistry.from([runtime])

        let snapshot = await runtime.refresh()

        let sessionDescriptors = registry.descriptors(for: "opencode").filter {
            $0.id.hasPrefix("opencode.session.account.")
        }
        XCTAssertEqual(sessionDescriptors.count, 4)
        XCTAssertEqual(Set(sessionDescriptors.map(\.metricLabel)).count, 4)
        XCTAssertEqual(Set(snapshot.lines.map(\.label)).count, snapshot.lines.count, "all account lines must be unique")
        let values = try sessionDescriptors.map { descriptor -> Double in
            let line = try XCTUnwrap(snapshot.line(label: descriptor.metricLabel))
            guard case let .progress(_, used, _, _, _, _, _, _) = line else {
                XCTFail("expected a progress value for \(descriptor.metricLabel)")
                return -1
            }
            return used
        }
        XCTAssertEqual(Set(values), Set([7.0, 17.0, 27.0, 37.0]))
    }

    func testGoKeySettingsOnlyOfferAllAccountsForDistinctCredentials() async {
        let duplicate = OpenCodeGoKey(id: UUID(), label: "Same Account", key: "sk-go")
        let duplicateRuntime = provider(
            authJSON: authJSON,
            http: SequenceHTTPClient([]),
            storedKeys: [duplicate]
        )
        let duplicateEntries = await duplicateRuntime.goKeyEntries()
        XCTAssertEqual(duplicateEntries.count, 2, "both editable key sources remain visible")
        XCTAssertFalse(OpenCodeGoKeyEntry.hasMultipleAccounts(duplicateEntries))

        let work = OpenCodeGoKey(id: UUID(), label: "Work", key: "sk-work")
        let multiRuntime = provider(authJSON: authJSON, http: SequenceHTTPClient([]), storedKeys: [work])
        let multiEntries = await multiRuntime.goKeyEntries()
        XCTAssertTrue(OpenCodeGoKeyEntry.hasMultipleAccounts(multiEntries))
    }

    func testPreloadedDescriptorInventoryDoesNotReadCredentialFilesOnMainActor() {
        let runtime = OpenCodeProvider(
            authStore: OpenCodeAuthStore(
                files: UnexpectedCredentialFileRead(),
                environment: FakeEnvironment(["OPENCODE_DATA_DIR": "/oc"]),
                homeDirectory: { URL(fileURLWithPath: "/nonexistent") }
            ),
            goKeyStore: OpenCodeGoKeyStore(
                files: UnexpectedCredentialFileRead(),
                filePath: { "/oc/go-keys.json" }
            ),
            preloadedAccountIdentities: [
                OpenCodeGoAccountIdentity(
                    credentialID: String(repeating: "a", count: 64),
                    descriptorKey: String(repeating: "1", count: 64),
                    displayName: "Work"
                ),
                OpenCodeGoAccountIdentity(
                    credentialID: String(repeating: "b", count: 64),
                    descriptorKey: String(repeating: "2", count: 64),
                    displayName: "Personal"
                )
            ]
        )

        let accountCaps = runtime.widgetDescriptors.filter { $0.id.contains(".account.") }

        XCTAssertEqual(accountCaps.count, 6)
        XCTAssertTrue(accountCaps.allSatisfy(\.hidesWhenEmpty))
    }

    func testRefreshRequestsCatalogRebuildWhenOpenCodeAddsAnExternalGoAccount() async {
        let authFiles = FakeFiles(["/oc/auth.json": #"{"opencode":{"type":"api","key":"sk-zen"}}"#])
        let saved = OpenCodeGoKey(id: UUID(), label: "Work", key: "sk-work")
        let savedData = try! JSONEncoder().encode([saved])
        let http = SequenceHTTPClient([])
        var catalogRebuildRequested = false
        let runtime = OpenCodeProvider(
            authStore: authStore(files: authFiles),
            usageScanner: OpenCodeUsageScanner(
                sqlite: StubSQLite(),
                databasePaths: { [] }
            ),
            usageClient: OpenCodeGoUsageClient(http: http),
            goKeyStore: OpenCodeGoKeyStore(
                files: FakeFiles(["/oc/go-keys.json": String(decoding: savedData, as: UTF8.self)]),
                filePath: { "/oc/go-keys.json" }
            ),
            onGoKeysChanged: { catalogRebuildRequested = true },
            preloadedAccountIdentities: []
        )

        // OpenCode signs into a second account externally while QuotaBar remains open.
        authFiles.files["/oc/auth.json"] = authJSON
        let snapshot = await runtime.refresh()

        XCTAssertTrue(catalogRebuildRequested)
        XCTAssertEqual(snapshot.errorCategory, .cancelled, "do not publish labels absent from the current registry")
        XCTAssertTrue(http.requests.isEmpty, "the current provider is rebuilt before issuing new-account calls")
    }

    func testIncompleteCredentialInventoryDoesNotPublishRemainingAccountAsGeneric() async {
        let saved = OpenCodeGoKey(id: UUID(), label: "Work", key: "sk-work")
        let savedData = try! JSONEncoder().encode([saved])
        let savedKeyStore = OpenCodeGoKeyStore(
            files: FakeFiles(["/oc/go-keys.json": String(decoding: savedData, as: UTF8.self)]),
            filePath: { "/oc/go-keys.json" }
        )
        let startupIdentities = await OpenCodeProvider.discoverAccountIdentities(
            authStore: authStore(files: FakeFiles(["/oc/auth.json": authJSON])),
            goKeyStore: savedKeyStore
        )
        XCTAssertEqual(startupIdentities.count, 2)

        let http = SequenceHTTPClient([])
        let usageTime = OpenUsageISO8601.date(from: "2026-07-12T11:00:00.000Z")!
        let usageMilliseconds = Int(usageTime.timeIntervalSince1970 * 1000)
        let localUsage = "[[\(usageMilliseconds),1.0,500,\"glm-5.2\",\"opencode\"]]"
        let runtime = OpenCodeProvider(
            authStore: authStore(files: UnreadableFiles(present: ["/oc/auth.json"])),
            usageScanner: OpenCodeUsageScanner(
                sqlite: StubSQLite(data: ["/oc/opencode.db": localUsage]),
                databasePaths: { ["/oc/opencode.db"] }
            ),
            usageClient: OpenCodeGoUsageClient(http: http),
            now: { OpenUsageISO8601.date(from: "2026-07-12T12:00:00.000Z")! },
            goKeyStore: savedKeyStore,
            preloadedAccountIdentities: startupIdentities
        )
        let registry = WidgetRegistry.from([runtime])
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let dataStore = WidgetDataStore(
            registry: registry,
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "opencode-incomplete-inventory.snapshot", ttl: 600),
            defaults: defaults,
            now: { OpenUsageISO8601.date(from: "2026-07-12T12:00:00.000Z")! }
        )

        let outcome = await dataStore.refresh(providerID: "opencode", force: true)

        XCTAssertEqual(outcome, WidgetDataStore.RefreshOutcome.failed)
        XCTAssertEqual(dataStore.errorCategory(for: "opencode"), ErrorCategory.credentialAccess)
        XCTAssertTrue(http.requests.isEmpty, "do not publish a surviving account under generic quota labels")
        let today: WidgetDescriptor = try! XCTUnwrap(
            registry.descriptors(for: "opencode").first { $0.metricLabel == "Today" }
        )
        XCTAssertTrue(dataStore.data(for: today).hasData, "a credential read failure must not block independent local history")
        XCTAssertEqual(dataStore.localSnapshots["opencode"]?.usageHistory?.series.daily.first?.totalTokens, 500)
        let genericSession: WidgetDescriptor = try! XCTUnwrap(registry.descriptor(id: "opencode.session"))
        XCTAssertFalse(dataStore.data(for: genericSession).hasData)
    }

    func testIncompleteInventoryAndLocalScanFailureClearUnverifiedCapsButRetainHistory() async {
        let saved = OpenCodeGoKey(id: UUID(), label: "Work", key: "sk-work")
        let savedData = try! JSONEncoder().encode([saved])
        let savedKeyStore = OpenCodeGoKeyStore(
            files: FakeFiles(["/oc/go-keys.json": String(decoding: savedData, as: UTF8.self)]),
            filePath: { "/oc/go-keys.json" }
        )
        let startupIdentities = await OpenCodeProvider.discoverAccountIdentities(
            authStore: authStore(files: FakeFiles(["/oc/auth.json": authJSON])),
            goKeyStore: savedKeyStore
        )
        XCTAssertEqual(startupIdentities.count, 2)

        let now = OpenUsageISO8601.date(from: "2026-07-12T12:00:00.000Z")!
        let http = SequenceHTTPClient([])
        let runtime = OpenCodeProvider(
            authStore: authStore(files: UnreadableFiles(present: ["/oc/auth.json"])),
            usageScanner: OpenCodeUsageScanner(
                sqlite: StubSQLite(failingPaths: ["/oc/opencode.db"]),
                databasePaths: { ["/oc/opencode.db"] }
            ),
            usageClient: OpenCodeGoUsageClient(http: http),
            now: { now },
            goKeyStore: savedKeyStore,
            preloadedAccountIdentities: startupIdentities
        )
        let registry = WidgetRegistry.from([runtime])
        let session = try! XCTUnwrap(registry.descriptors(for: "opencode").first {
            $0.metricLabel == "Session (opencode-go)"
        })
        let workSession = try! XCTUnwrap(registry.descriptors(for: "opencode").first {
            $0.metricLabel == "Session (Work)"
        })
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cache = ProviderSnapshotCache(
            userDefaults: defaults,
            storageKey: "opencode-incomplete-scan.snapshot",
            ttl: 600,
            now: { now }
        )
        cache.store(ProviderSnapshot(
            providerID: "opencode",
            displayName: "OpenCode",
            plan: "Go",
            lines: [
                .progress(label: "Session (opencode-go)", used: 17, limit: 100, format: .percent),
                .progress(label: "Session (Work)", used: 43, limit: 100, format: .percent)
            ],
            refreshedAt: now,
            usageHistory: ProviderUsageHistory(series: DailyUsageSeries(daily: [
                DailyUsageEntry(date: "2026-07-12", totalTokens: 200, costUSD: 2)
            ]))
        ), producedByIdentityKey: nil)
        let dataStore = WidgetDataStore(
            registry: registry,
            providers: [runtime],
            cache: cache,
            defaults: defaults,
            now: { now }
        )

        let outcome = await dataStore.refresh(providerID: "opencode", force: true)

        XCTAssertEqual(outcome, WidgetDataStore.RefreshOutcome.failed)
        XCTAssertNil(dataStore.localSnapshots["opencode"]?.plan)
        XCTAssertNil(dataStore.localSnapshots["opencode"]?.line(label: session.metricLabel))
        XCTAssertNil(dataStore.localSnapshots["opencode"]?.line(label: workSession.metricLabel))
        XCTAssertEqual(dataStore.localSnapshots["opencode"]?.usageHistory?.series.daily.first?.totalTokens, 200)
        XCTAssertTrue(http.requests.isEmpty, "a partial inventory cannot confirm which account owns a quota reply")
    }

    func testDifferentCredentialsWithSameWindowsRemainSeparate() async {
        let http = SequenceHTTPClient([
            HTTPResponse(statusCode: 200, headers: [:], body: Self.payload(rolling: 7, weekly: 26, monthly: 79)),
            HTTPResponse(statusCode: 200, headers: [:], body: Self.payload(rolling: 7, weekly: 26, monthly: 79))
        ])
        let work = OpenCodeGoKey(id: UUID(), label: "Work", key: "sk-work")
        let snapshot = await provider(authJSON: authJSON, http: http, storedKeys: [work]).refresh()

        XCTAssertEqual(snapshot.line(label: "Session (opencode-go)")?.label, "Session (opencode-go)")
        XCTAssertEqual(snapshot.line(label: "Session (Work)")?.label, "Session (Work)")
        XCTAssertNil(snapshot.line(label: "Session"))
    }

    func testOneKeyStillWorks() async {
        let single = #"{"opencode-go":{"type":"api","key":"sk-go"}}"#
        let http = SequenceHTTPClient([
            HTTPResponse(statusCode: 200, headers: [:], body: Self.payload(rolling: 4, weekly: 25, monthly: 78))
        ])
        let snapshot = await provider(authJSON: single, http: http).refresh()
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(snapshot.line(label: "Session")?.label, "Session")
    }

    // MARK: - App-saved keys + active selection

    func testStoredKeyFetchedWhenAuthFileHasNoKeys() async {
        // No auth.json key at all: the card runs on an app-saved key alone.
        let http = SequenceHTTPClient([
            HTTPResponse(statusCode: 200, headers: [:], body: Self.payload(rolling: 3, weekly: 20, monthly: 60))
        ])
        let stored = [OpenCodeGoKey(id: UUID(), label: "Work", key: "sk-work")]
        let snapshot = await provider(authJSON: "{}", http: http, storedKeys: stored).refresh()
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(http.requests.first?.headers["Authorization"], "Bearer sk-work")
        XCTAssertEqual(snapshot.line(label: "Session")?.label, "Session")
        guard case let .progress(_, used, _, _, _, _, _, _)? = snapshot.line(label: "Session") else {
            return XCTFail("expected a Session meter")
        }
        XCTAssertEqual(used, 3)
    }

    func testSelectionPinsCardToThatAccountOnly() async {
        // Two distinct credentials; the selection swaps the card to one of them.
        let http = SequenceHTTPClient([
            HTTPResponse(statusCode: 200, headers: [:], body: Self.payload(rolling: 7, weekly: 26, monthly: 79)),
            HTTPResponse(statusCode: 200, headers: [:], body: Self.payload(rolling: 55, weekly: 60, monthly: 90))
        ])
        let work = OpenCodeGoKey(id: UUID(), label: "Work", key: "sk-work")
        let snapshot = await provider(
            authJSON: authJSON,
            http: http,
            storedKeys: [work],
            activeKeyID: { work.id.uuidString }
        ).refresh()
        XCTAssertEqual(snapshot.line(label: "Session (Work)")?.label, "Session (Work)")
        XCTAssertNil(snapshot.line(label: "Session (opencode-go)"))
        XCTAssertNil(snapshot.line(label: "Session"))
        guard case let .progress(_, used, _, _, _, _, _, _)? = snapshot.line(label: "Session (Work)") else {
            return XCTFail("expected the pinned account's Session meter")
        }
        XCTAssertEqual(used, 55)
    }

    func testPinnedKeyTransientFailureDoesNotUseUnattributedLocalGoFallback() async {
        let now = OpenUsageISO8601.date(from: "2026-07-12T12:00:00.000Z")!
        let eventMS = Int(now.addingTimeInterval(-3_600).timeIntervalSince1970 * 1_000)
        let db = "[[\(eventMS),2.0,1000,\"glm-5.2\",\"opencode-go\"]]"
        let http = SequenceHTTPClient([
            HTTPResponse(statusCode: 200, headers: [:], body: Self.payload(rolling: 7, weekly: 26, monthly: 79)),
            HTTPResponse(statusCode: 503, headers: [:], body: Data())
        ])
        let work = OpenCodeGoKey(id: UUID(), label: "Work", key: "sk-work")

        let snapshot = await provider(
            authJSON: authJSON,
            http: http,
            db: db,
            storedKeys: [work],
            activeKeyID: { work.id.uuidString }
        ).refresh()

        XCTAssertEqual(http.requests.count, 2)
        XCTAssertNil(snapshot.plan)
        XCTAssertNil(snapshot.line(label: "Session (Work)"))
        XCTAssertNil(snapshot.line(label: "Session (opencode-go)"))
        XCTAssertNil(snapshot.line(label: "Session"))
        XCTAssertNotNil(snapshot.line(label: "Today"))
        XCTAssertNotNil(snapshot.warning)
    }

    func testSelectionByStoredKeyUUIDPinsThatAccount() async {
        let work = OpenCodeGoKey(id: UUID(), label: "Work", key: "sk-work")
        let http = SequenceHTTPClient([
            HTTPResponse(statusCode: 200, headers: [:], body: Self.payload(rolling: 7, weekly: 26, monthly: 79)),
            HTTPResponse(statusCode: 200, headers: [:], body: Self.payload(rolling: 55, weekly: 60, monthly: 90))
        ])
        let snapshot = await provider(
            authJSON: authJSON, http: http, storedKeys: [work], activeKeyID: { work.id.uuidString }
        ).refresh()
        XCTAssertEqual(snapshot.line(label: "Session (Work)")?.label, "Session (Work)")
        XCTAssertNil(snapshot.line(label: "Session (opencode-go)"))
        XCTAssertNil(snapshot.line(label: "Session"))
        guard case let .progress(_, used, _, _, _, _, _, _)? = snapshot.line(label: "Session (Work)") else {
            return XCTFail("expected the stored-key account's Session meter")
        }
        XCTAssertEqual(used, 55)
    }

    func testStaleSelectionFallsBackToAllAccounts() async {
        // A selection that matches no fetched key must not hide anything: all accounts render.
        let http = SequenceHTTPClient([
            HTTPResponse(statusCode: 200, headers: [:], body: Self.payload(rolling: 7, weekly: 26, monthly: 79)),
            HTTPResponse(statusCode: 200, headers: [:], body: Self.payload(rolling: 55, weekly: 60, monthly: 90))
        ])
        let work = OpenCodeGoKey(id: UUID(), label: "Work", key: "sk-work")
        let snapshot = await provider(
            authJSON: authJSON,
            http: http,
            storedKeys: [work],
            activeKeyID: { "stale-id" }
        ).refresh()
        XCTAssertEqual(snapshot.line(label: "Session (opencode-go)")?.label, "Session (opencode-go)")
        XCTAssertEqual(snapshot.line(label: "Session (Work)")?.label, "Session (Work)")
    }

    func testSelectionIgnoredWhenSingleAccount() async {
        // The same credential is duplicated in the app-saved store: selecting that copy still resolves
        // to the single account result and does not require a second quota request.
        let http = SequenceHTTPClient([
            HTTPResponse(statusCode: 200, headers: [:], body: Self.payload(rolling: 7, weekly: 26, monthly: 79)),
            HTTPResponse(statusCode: 200, headers: [:], body: Self.payload(rolling: 7, weekly: 26, monthly: 79))
        ])
        let duplicate = OpenCodeGoKey(id: UUID(), label: "Duplicate", key: "sk-go")
        let snapshot = await provider(
            authJSON: authJSON,
            http: http,
            storedKeys: [duplicate],
            activeKeyID: { duplicate.id.uuidString }
        ).refresh()
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(snapshot.line(label: "Session")?.label, "Session")
        XCTAssertNil(snapshot.line(label: "Session (opencode-go)"))
        XCTAssertNil(snapshot.line(label: "Session (Duplicate)"))
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "QuotaBarTests.OpenCodeMultiKey.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}

private struct UnexpectedCredentialFileRead: TextFileAccessing {
    func exists(_ path: String) -> Bool {
        XCTFail("descriptor construction should use the preloaded inventory, not read \(path)")
        return false
    }

    func readTextIfPresent(_ path: String) throws -> String? {
        XCTFail("descriptor construction should use the preloaded inventory, not read \(path)")
        return nil
    }

    func readText(_ path: String) throws -> String {
        XCTFail("descriptor construction should use the preloaded inventory, not read \(path)")
        return ""
    }

    func writeText(_ path: String, _ text: String) throws {
        XCTFail("unexpected credential file write: \(path)")
    }

    func remove(_ path: String) throws {
        XCTFail("unexpected credential file remove: \(path)")
    }
}
