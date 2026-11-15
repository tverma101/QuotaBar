import XCTest
@testable import QuotaBar

/// Regression coverage for the P0 trap class: provider payloads are untrusted, and a direct
/// `Int(_:)` on a large numeric field — or an unbounded reset instant that later reaches duration
/// formatting — terminates the menu-bar process with SIGTRAP instead of surfacing a clean error.
///
/// Each test feeds a value that previously trapped (`1e300` / a 2099-style far-future instant
/// expressed as an epoch) and asserts the mapper either sanitizes it or reports no data. A test
/// process that traps fails loudly, so simply reaching the assertions is the regression signal.
final class MalformedPayloadTrapTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Codex

    func testCodexHugeWindowAndResetValuesDoNotTrap() throws {
        let body = Data("""
        {
          "rate_limit": {
            "primary_window": { "used_percent": 12, "limit_window_seconds": 1e300, "reset_at": 1e300 },
            "secondary_window": { "used_percent": 34, "limit_window_seconds": 604800, "reset_after_seconds": 1e300 }
          }
        }
        """.utf8)

        let mapped = try CodexUsageMapper.mapUsageResponse(
            HTTPResponse(statusCode: 200, headers: [:], body: body),
            now: now
        )

        // The implausible window no longer classifies by duration, so the primary slot keeps the
        // documented session cadence; the huge reset instant is dropped rather than trusted.
        let session = progress(mapped.lines, "Session")
        XCTAssertEqual(session?.used, 12)
        XCTAssertEqual(session?.periodDurationMs, CodexUsageMapper.sessionPeriodMs)
        XCTAssertNil(session?.resetsAt)

        let weekly = progress(mapped.lines, "Weekly")
        XCTAssertEqual(weekly?.used, 34)
        XCTAssertNil(weekly?.resetsAt)
    }

    func testCodexHugeCreditBalanceSaturates() {
        let values = CodexUsageMapper.creditValues(remaining: 1e300)
        let dollars = values.first { $0.kind == .dollars }
        let credits = values.first { $0.kind == .count }
        XCTAssertEqual(credits?.number, 1_000_000_000)
        XCTAssertEqual(dollars?.number, 40_000_000)
        XCTAssertTrue(dollars?.number.isFinite == true)
    }

    func testCodexHugeResetCreditCountAndExpiryAreSanitized() {
        let usage = Data(#"{"rate_limit":{}}"#.utf8)
        let resetCredits = HTTPResponse(
            statusCode: 200,
            headers: [:],
            body: Data(#"{"available_count":1e300,"credits":[{"status":"available","expires_at":1e300}]}"#.utf8)
        )

        let resets = CodexUsageMapper.readResetCredits(
            body: [:] as [String: Any],
            resetCredits: resetCredits,
            now: now
        )
        XCTAssertEqual(resets?.count, 1_000_000)
        XCTAssertEqual(resets?.expiries, [])

        // The same hostile payload through the public mapper must still produce a usable snapshot.
        let mapped = try? CodexUsageMapper.mapUsageResponse(
            HTTPResponse(statusCode: 200, headers: [:], body: usage),
            resetCredits: resetCredits,
            now: now
        )
        XCTAssertNotNil(mapped)
    }

    // MARK: - Claude

    func testClaudeHugeResetInstantsAreDropped() throws {
        let body = Data("""
        {
          "five_hour": { "utilization": 10, "resets_at": 1e300 },
          "seven_day": { "utilization": 20, "resets_at": "2099-01-01T00:00:00.000Z" },
          "limits": [
            { "kind": "weekly_scoped", "percent": 7, "resets_at": 1e300,
              "scope": { "model": { "display_name": "Fable" } } }
          ]
        }
        """.utf8)

        let mapped = try ClaudeUsageMapper.mapUsageResponse(
            HTTPResponse(statusCode: 200, headers: [:], body: body),
            credentials: ClaudeOAuth(subscriptionType: "max"),
            now: now
        )

        XCTAssertEqual(progress(mapped.lines, "Session")?.used, 10)
        // `1e300` seconds is outside the sanity bound; the instant is dropped, not trusted.
        XCTAssertNil(progress(mapped.lines, "Session")?.resetsAt)
        // A legitimately parsed far date stays accepted: the bound guards representability, not
        // whether a plan's window "looks" near.
        XCTAssertNotNil(progress(mapped.lines, "Weekly")?.resetsAt)
        XCTAssertNil(progress(mapped.lines, "Fable")?.resetsAt)
    }

    // MARK: - Cursor

    func testCursorHugeBillingCycleDoesNotTrap() throws {
        let mapped = try CursorUsageMapper.mapUsage(
            usage: [
                "enabled": true,
                "billingCycleStart": 1e300,
                "billingCycleEnd": 1e300,
                "planUsage": [
                    "limit": 40_000,
                    "totalPercentUsed": 20,
                    "autoPercentUsed": 12.5,
                    "apiPercentUsed": 7.5
                ]
            ],
            planName: "pro plan",
            creditGrants: nil,
            stripeBalanceCents: 0
        )

        let total = progress(mapped.lines, "Total usage")
        XCTAssertEqual(total?.used, 20)
        XCTAssertEqual(total?.periodDurationMs, CursorUsageMapper.billingPeriodMs)
        XCTAssertNil(total?.resetsAt)
    }

    // MARK: - OpenCode

    func testOpenCodeHugePercentIsRejectedAsInvalidResponse() async {
        let payload = Data("""
        {"usage":{
          "rolling":{"status":"ok","percent":1e300,"resetsAt":"2026-08-12T03:53:00.876Z"},
          "weekly":{"status":"ok","percent":25,"resetsAt":"2026-08-17T00:00:00.876Z"},
          "monthly":{"status":"ok","percent":78,"resetsAt":"2026-08-31T01:28:22.876Z"}
        }}
        """.utf8)
        let client = OpenCodeGoUsageClient(http: FakeHTTPClient(
            response: HTTPResponse(statusCode: 200, headers: [:], body: payload)
        ))

        do {
            _ = try await client.fetchUsage(key: "sk-test")
            XCTFail("a percent outside 0...100 must not be accepted")
        } catch let error as OpenCodeUsageError {
            XCTAssertEqual(error, .accountAPIInvalidResponse)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - UI model

    func testHugeResetCreditCountSaturatesInsteadOfTrapping() {
        var data = WidgetData(
            title: "Rate Limit Resets",
            icon: .providerMark("codex"),
            kind: .count,
            used: 0
        )
        data.values = [MetricValue(number: 1e300, kind: .count, label: "available")]
        data.selection = .all
        XCTAssertEqual(data.resetCreditCount, 1_000_000)
    }

    func testMenuBarPercentWithHugeSampleDoesNotTrap() {
        var data = WidgetData(
            title: "Session",
            icon: .providerMark("codex"),
            kind: .percent,
            used: 1e300
        )
        data.limit = 100
        XCTAssertEqual(data.menuBarValue, "100%")
    }

    // MARK: - Claude rate-limit header

    func testClaudeHugeRetryAfterIsCappedInsteadOfTrappingTheCooldownConversion() {
        // `Int.max` seconds is a valid `Int` (and a plausible corrupted/millisecond header), but adding
        // it to the current time pushed the cooldown conversion past `Int.max` on the next refresh.
        let numeric = HTTPResponse(
            statusCode: 429,
            headers: ["retry-after": "9223372036854775807"],
            body: Data()
        )
        XCTAssertEqual(
            ClaudeUsageMapper.parseRetryAfterSeconds(numeric, now: now),
            ClaudeUsageMapper.maximumRetryAfterSeconds
        )

        let farFutureDate = HTTPResponse(
            statusCode: 429,
            headers: ["retry-after": "Fri, 31 Dec 9999 23:59:59 GMT"],
            body: Data()
        )
        XCTAssertEqual(
            ClaudeUsageMapper.parseRetryAfterSeconds(farFutureDate, now: now),
            ClaudeUsageMapper.maximumRetryAfterSeconds
        )

        // Ordinary values pass through unchanged.
        XCTAssertEqual(
            ClaudeUsageMapper.parseRetryAfterSeconds(
                HTTPResponse(statusCode: 429, headers: ["Retry-After": "42"], body: Data()),
                now: now
            ),
            42
        )
    }

    // MARK: - OpenCode windows

    func testOpenCodeCorruptMonthAnchorFallsBackWithoutTrapping() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let windows = OpenCodeGoWindowMath.compute(costs: [], anchorMs: 1e300, now: now)
        // Falls back to the UTC calendar month rather than feeding the huge value into Int month math.
        XCTAssertNotNil(windows.monthlyResetsAt)
        let period = try? XCTUnwrap(windows.monthlyPeriodMs)
        XCTAssertTrue((28 * 24 * 60 * 60 * 1000...31 * 24 * 60 * 60 * 1000).contains(period ?? 0))
    }

    // MARK: - Shared formatting boundary

    func testCompactDurationRefusesNonRepresentableIntervals() {
        // Reached by any surface that formats a reset countdown, including dates restored from a
        // persisted snapshot or iCloud — not only fresh provider payloads.
        XCTAssertNil(Formatters.compactDuration(1e300))
        XCTAssertNil(Formatters.compactDuration(.greatestFiniteMagnitude))
        XCTAssertNil(Formatters.compactDuration(.infinity))
        XCTAssertEqual(Formatters.compactDuration(3_600), "1h")
        XCTAssertNil(
            Formatters.deadlineLabel("Resets", at: Date(timeIntervalSinceNow: 1e300), mode: .relative)
        )
    }

    // MARK: - Helpers

    private func progress(
        _ lines: [MetricLine],
        _ label: String
    ) -> (used: Double, limit: Double, resetsAt: Date?, periodDurationMs: Int?)? {
        guard case .progress(_, let used, let limit, _, let resetsAt, let periodDurationMs, _, _) =
                lines.first(where: { $0.label == label })
        else { return nil }
        return (used, limit, resetsAt, periodDurationMs)
    }
}
