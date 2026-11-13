import XCTest
@testable import QuotaBar

/// When the card's anchor credential is dead but the same account is live in `~/.codex/auth.json`,
/// the refresh must fall back to the CLI's credential instead of surfacing meters as dark.
@MainActor
final class CodexAuthFallbackTests: XCTestCase {
    private func codexAuth(
        accountID: String,
        accessToken: String,
        refreshToken: String? = nil
    ) -> String {
        let refresh = refreshToken.map { #","refresh_token":"\#($0)""# } ?? ""
        return #"{"tokens":{"access_token":"\#(accessToken)"\#(refresh),"account_id":"\#(accountID)"}}"#
    }

    func testAuthPathsPrimaryThenAdditionalHomesDeduped() {
        let files = FakeFiles([
            "/tmp/codex-router-home/auth.json": codexAuth(accountID: "account-a", accessToken: "router-access"),
            "/tmp/cli-home/auth.json": codexAuth(accountID: "account-a", accessToken: "cli-access"),
        ])
        let store = CodexAuthStore(
            environment: FakeEnvironment(["CODEX_HOME": "/tmp/codex-router-home"]),
            files: files,
            keychain: FakeKeychain(),
            additionalAuthHomes: ["/tmp/cli-home", "/tmp/codex-router-home", "/tmp/cli-home/"]
        )

        XCTAssertEqual(
            store.authPaths(),
            ["/tmp/codex-router-home/auth.json", "/tmp/cli-home/auth.json"],
            "fallback homes come after the anchor home, in order, deduped"
        )

        let candidates = try? store.loadAuthCandidates()
        XCTAssertEqual(
            candidates?.map { $0.auth.tokens?.accessToken },
            ["router-access", "cli-access"]
        )
    }

    func testIdentityMismatchedFallbackHomeIsInvisibleToTheCard() {
        let files = FakeFiles([
            "/tmp/codex-router-home/auth.json": codexAuth(accountID: "account-a", accessToken: "router-access"),
            // A different account's CLI session — must not leak into this card's candidates.
            "/tmp/cli-home/auth.json": codexAuth(accountID: "account-b", accessToken: "other-cli-access"),
        ])
        let store = CodexAuthStore(
            environment: FakeEnvironment(["CODEX_HOME": "/tmp/codex-router-home"]),
            files: files,
            keychain: FakeKeychain(),
            expectedIdentityKey: "account-a",
            additionalAuthHomes: ["/tmp/cli-home"]
        )

        let candidates = try? store.loadAuthCandidates()
        XCTAssertEqual(candidates?.map { $0.auth.tokens?.accessToken }, ["router-access"])
    }

    func testProviderFallsBackToCliCredentialWhenRouterSessionIsRevoked() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let files = FakeFiles([
            "/tmp/codex-router-home/auth.json": codexAuth(
                accountID: "account-a", accessToken: "router-access", refreshToken: "router-refresh"
            ),
            "/tmp/cli-home/auth.json": codexAuth(
                accountID: "account-a", accessToken: "cli-access", refreshToken: "cli-refresh"
            ),
        ])
        let http = RoutingHTTPClient { request in
            switch request.url {
            case CodexUsageClient.refreshURL:
                // The router's stored refresh grant was revoked server-side (e.g. the account
                // session was ended elsewhere). The CLI's own grant is untouched.
                return HTTPResponse(
                    statusCode: 401,
                    headers: [:],
                    body: Data(#"{"error":{"code":"refresh_token_invalidated","message":"Your session has ended. Please log in again."}}"#.utf8)
                )
            case CodexUsageClient.usageURL:
                let bearer = request.headers["Authorization"] ?? ""
                if bearer.hasSuffix("router-access") {
                    return HTTPResponse(
                        statusCode: 401,
                        headers: [:],
                        body: Data(#"{"error":{"code":"token_revoked"}}"#.utf8)
                    )
                }
                return HTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(#"{"rate_limit":{"primary_window":{"used_percent":3,"reset_after_seconds":3600}}}"#.utf8)
                )
            default:
                return HTTPResponse(statusCode: 200, headers: [:], body: Data("{}".utf8))
            }
        }
        let provider = CodexProvider(
            authStore: CodexAuthStore(
                environment: FakeEnvironment(["CODEX_HOME": "/tmp/codex-router-home"]),
                files: files,
                keychain: FakeKeychain(),
                now: { now },
                expectedIdentityKey: "account-a",
                additionalAuthHomes: ["/tmp/cli-home"]
            ),
            usageClient: CodexUsageClient(http: http),
            logUsageScanner: CodexLogFixture.scanner(home: nil),
            proxyUsageScanner: CodexProxyUsageScanner(databasePaths: { [] }),
            routerUsageScanner: CodexRouterUsageScanner(ledgerPaths: { [] }, identityAliases: { [:] }),
            allowsUnattributedPiUsage: false,
            now: { now },
            pricing: {
                ModelPricing(
                    supplement: PricingSupplement(),
                    primary: PricingCatalog(entries: [:]),
                    secondary: PricingCatalog(entries: [:])
                )
            }
        )

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.warning, "the CLI fallback must bring the live meters back; got \(snapshot.warning ?? "nil")")
        XCTAssertTrue(
            http.requests.contains { $0.url == CodexUsageClient.usageURL && ($0.headers["Authorization"] ?? "").hasSuffix("cli-access") },
            "the refresh must probe the CLI credential after the router one is revoked; got \(http.requests.map(\.url))"
        )
        // Neither credential file may be rewritten: the failed refresh persists nothing, and the
        // CLI's access token did not need a rotation inside the refresh window.
        XCTAssertTrue(files.files["/tmp/codex-router-home/auth.json"]?.contains("router-refresh") == true)
        XCTAssertEqual(
            files.files["/tmp/cli-home/auth.json"],
            codexAuth(accountID: "account-a", accessToken: "cli-access", refreshToken: "cli-refresh")
        )
    }
}
