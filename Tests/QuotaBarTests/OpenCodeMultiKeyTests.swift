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
        init(data: [String: String] = [:]) { self.data = data }
        func queryValue(path: String, sql: String) throws -> String? {
            if sql.contains("json_group_array") { return data[path] }
            if sql.contains("SELECT 1") { return data[path] == nil ? nil : "1" }
            return nil
        }
        func execute(path: String, sql: String) throws {}
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

    // MARK: - Provider: per-key fetch + dedupe

    func testSameAccountKeysRenderOneMeterSet() async {
        // The same credential is present in auth.json and the app-saved store: one meter set,
        // no suffixes, and both copies were tried.
        let http = SequenceHTTPClient([
            HTTPResponse(statusCode: 200, headers: [:], body: Self.payload(rolling: 7, weekly: 26, monthly: 79)),
            HTTPResponse(statusCode: 200, headers: [:], body: Self.payload(rolling: 7, weekly: 26, monthly: 79))
        ])
        let duplicate = OpenCodeGoKey(id: UUID(), label: "Duplicate", key: "sk-go")
        let snapshot = await provider(authJSON: authJSON, http: http, storedKeys: [duplicate]).refresh()
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(http.requests.count, 2)
        XCTAssertEqual(http.requests.map { $0.headers["Authorization"] }, ["Bearer sk-go", "Bearer sk-go"])
        XCTAssertEqual(snapshot.line(label: "Session")?.label, "Session")
        XCTAssertNil(snapshot.line(label: "Session (opencode-go)"))
        guard case let .progress(_, used, _, _, _, _, _, _)? = snapshot.line(label: "Session") else {
            return XCTFail("expected a Session meter")
        }
        XCTAssertEqual(used, 7)
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
        // The same credential is duplicated in the app-saved store: one unsuffixed set, selection or not.
        let http = SequenceHTTPClient([
            HTTPResponse(statusCode: 200, headers: [:], body: Self.payload(rolling: 7, weekly: 26, monthly: 79)),
            HTTPResponse(statusCode: 200, headers: [:], body: Self.payload(rolling: 7, weekly: 26, monthly: 79))
        ])
        let duplicate = OpenCodeGoKey(id: UUID(), label: "Duplicate", key: "sk-go")
        let snapshot = await provider(
            authJSON: authJSON,
            http: http,
            storedKeys: [duplicate],
            activeKeyID: { "opencode-go" }
        ).refresh()
        XCTAssertEqual(snapshot.line(label: "Session")?.label, "Session")
        XCTAssertNil(snapshot.line(label: "Session (opencode-go)"))
        XCTAssertNil(snapshot.line(label: "Session (Duplicate)"))
    }
}
