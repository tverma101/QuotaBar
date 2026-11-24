import XCTest
@testable import QuotaBar

/// Host-preference and merge behavior of the Cloud Code quota-summary read, adapted to the fork's
/// two-host client (daily first, production second). Quota reads keep daily-first; the plan and
/// project lookup prefers production (covered in `AntigravityProviderTests`).
final class AntigravityUsageClientTests: XCTestCase {
    private static let dailyHost = "daily-cloudcode-pa.googleapis.com"
    private static let productionHost = "cloudcode-pa.googleapis.com"

    private static func bucket(_ id: String, fraction: Double? = nil, reset: String? = nil) -> String {
        var fields = [#""bucketId":"\#(id)""#]
        if let fraction { fields.append(#""remainingFraction":\#(fraction)"#) }
        if let reset { fields.append(#""resetTime":"\#(reset)""#) }
        return "{\(fields.joined(separator: ","))}"
    }

    private static func summary(_ buckets: [String]) -> String {
        #"{"groups":[{"displayName":"fake","buckets":[\#(buckets.joined(separator: ","))]}]}"#
    }

    private static let dailySummary = summary([
        bucket("gemini-5h", fraction: 0.99965, reset: "2027-03-02T14:00:00Z"),
        bucket("gemini-weekly", fraction: 0.9742, reset: "2027-03-08T09:00:00Z"),
        bucket("3p-5h", fraction: 0.5, reset: "2027-03-02T15:00:00Z"),
        bucket("3p-weekly", fraction: 0.4, reset: "2027-03-08T09:00:00Z")
    ])

    private static let productionSummary = summary([
        bucket("gemini-5h", fraction: 1, reset: "2027-03-02T19:00:00Z"),
        bucket("gemini-weekly", fraction: 1, reset: "2027-03-09T00:00:00Z"),
        bucket("3p-5h", fraction: 0.9, reset: "2027-03-02T19:00:00Z"),
        bucket("3p-weekly", fraction: 0.8, reset: "2027-03-09T00:00:00Z")
    ])

    private static func ok(_ body: String) -> HTTPResponse {
        HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
    }

    private func client(daily: HTTPResponse?, production: HTTPResponse?) -> (AntigravityUsageClient, RoutingHTTPClient) {
        let http = RoutingHTTPClient { request in
            switch request.url.host {
            case Self.dailyHost:
                guard let daily else { throw URLError(.cannotFindHost) }
                return daily
            case Self.productionHost:
                guard let production else { throw URLError(.cannotFindHost) }
                return production
            default:
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
        }
        return (AntigravityUsageClient(http: http), http)
    }

    private func quotaHosts(_ http: RoutingHTTPClient) -> [String] {
        http.requests.filter { $0.url.path == AntigravityUsageClient.quotaSummaryPath }.compactMap(\.url.host)
    }

    private func used(_ line: MetricLine?) -> Double? {
        guard case .progress(_, let used, _, _, _, _, _, _)? = line else { return nil }
        return used
    }

    private func resetsAt(_ line: MetricLine?) -> Date? {
        guard case .progress(_, _, _, _, let resetsAt, _, _, _)? = line else { return nil }
        return resetsAt
    }

    func testACompleteDailySummaryAnswersWithoutAskingProduction() async throws {
        let (client, http) = client(daily: Self.ok(Self.dailySummary), production: Self.ok(Self.productionSummary))

        let result = try await client.cloudCodeSummaries(token: "access")

        guard case .ok(let bodies, let answered) = result else { return XCTFail("expected a summary") }
        XCTAssertTrue(answered)
        XCTAssertEqual(bodies, [Data(Self.dailySummary.utf8)])
        XCTAssertEqual(quotaHosts(http), [Self.dailyHost])
        let lines = try XCTUnwrap(AntigravityUsageMapper.parseQuotaSummariesResult(bodies, allHostsAnswered: answered)).lines
        let session = try XCTUnwrap(lines.first { $0.label == AntigravityMetric.sessionLabel })
        XCTAssertEqual(used(session) ?? -1, 0.035, accuracy: 0.001)
        XCTAssertEqual(resetsAt(session), OpenUsageISO8601.date(from: "2027-03-02T14:00:00Z"))
    }

    func testDailyWinsPerBucketAndProductionFillsOmissions() async throws {
        let daily = Self.summary([
            Self.bucket("3p-5h", fraction: 0.6, reset: "2027-03-02T10:00:00Z")
        ])
        let (client, http) = client(daily: Self.ok(daily), production: Self.ok(Self.productionSummary))

        let result = try await client.cloudCodeSummaries(token: "access")
        guard case .ok(let bodies, let answered) = result else { return XCTFail("expected a summary") }
        XCTAssertTrue(answered)
        XCTAssertEqual(quotaHosts(http), [Self.dailyHost, Self.productionHost])
        let lines = try XCTUnwrap(AntigravityUsageMapper.parseQuotaSummariesResult(bodies, allHostsAnswered: answered)).lines

        for label in [AntigravityMetric.sessionLabel, AntigravityMetric.weeklyLabel] {
            let line = try XCTUnwrap(lines.first { $0.label == label })
            XCTAssertEqual(used(line) ?? -1, 0, accuracy: 0.0001, "\(label) comes from production")
        }
        let claude = try XCTUnwrap(lines.first { $0.label == AntigravityMetric.claudeLabel })
        XCTAssertEqual(used(claude) ?? -1, 40, accuracy: 0.001)
        XCTAssertEqual(resetsAt(claude), OpenUsageISO8601.date(from: "2027-03-02T10:00:00Z"))
        let claudeWeekly = try XCTUnwrap(lines.first { $0.label == AntigravityMetric.claudeWeeklyLabel })
        XCTAssertEqual(used(claudeWeekly) ?? -1, 20, accuracy: 0.001)
    }

    func testAnUnusableDailyFractionFillsFromProduction() async throws {
        let daily = Self.summary([
            Self.bucket("gemini-5h"),
            Self.bucket("3p-5h", fraction: 0.5, reset: "2027-03-02T10:00:00Z")
        ])
        let (client, _) = client(daily: Self.ok(daily), production: Self.ok(Self.productionSummary))

        let result = try await client.cloudCodeSummaries(token: "access")
        guard case .ok(let bodies, _) = result else { return XCTFail("expected a summary") }
        let lines = try XCTUnwrap(AntigravityUsageMapper.parseQuotaSummariesResult(bodies, allHostsAnswered: true)).lines

        let session = try XCTUnwrap(lines.first { $0.label == AntigravityMetric.sessionLabel })
        XCTAssertEqual(used(session) ?? -1, 0, accuracy: 0.0001)
        XCTAssertEqual(resetsAt(session), OpenUsageISO8601.date(from: "2027-03-02T19:00:00Z"))
    }

    func testDailyServerErrorAndTransportErrorFallBackToProduction() async throws {
        for daily in [HTTPResponse(statusCode: 503, headers: [:], body: Data("{}".utf8)), nil] {
            let (client, http) = client(daily: daily, production: Self.ok(Self.productionSummary))

            let result = try await client.cloudCodeSummaries(token: "access")

            XCTAssertEqual(quotaHosts(http), [Self.dailyHost, Self.productionHost])
            guard case .ok(let bodies, let answered) = result else { return XCTFail("expected a summary") }
            XCTAssertTrue(answered)
            XCTAssertEqual(bodies, [Data(Self.productionSummary.utf8)])
        }
    }

    func testDailyUnauthorizedStillSucceedsOnProduction() async throws {
        let (client, _) = client(
            daily: HTTPResponse(statusCode: 401, headers: [:], body: Data(#"{"error":{"code":401}}"#.utf8)),
            production: Self.ok(Self.productionSummary)
        )

        let result = try await client.cloudCodeSummaries(token: "access")

        guard case .ok(let bodies, let answered) = result else { return XCTFail("expected a summary") }
        XCTAssertTrue(answered)
        XCTAssertEqual(bodies, [Data(Self.productionSummary.utf8)])
    }

    func testDailyUnauthorizedWithPartialProductionKeepsTheFreshnessStampUnset() async throws {
        let partial = Self.summary([
            Self.bucket("gemini-5h", fraction: 0.5, reset: "2027-03-02T10:00:00Z")
        ])
        let (client, _) = client(
            daily: HTTPResponse(statusCode: 401, headers: [:], body: Data()),
            production: Self.ok(partial)
        )

        let result = try await client.cloudCodeSummaries(token: "access")

        guard case .ok(let bodies, let answered) = result else { return XCTFail("expected a summary") }
        XCTAssertFalse(answered, "a refused host must withhold the freshness stamp when nothing was complete")
        let merged = try XCTUnwrap(AntigravityUsageMapper.parseQuotaSummariesResult(bodies, allHostsAnswered: answered))
        XCTAssertFalse(merged.isComplete)
        XCTAssertEqual(merged.lines.map(\.label), [AntigravityMetric.sessionLabel])
    }

    func testBothBasesUnauthorizedReadsAsAuthFailure() async throws {
        let (client, http) = client(
            daily: HTTPResponse(statusCode: 401, headers: [:], body: Data()),
            production: HTTPResponse(statusCode: 401, headers: [:], body: Data())
        )

        let result = try await client.cloudCodeSummaries(token: "access")

        guard case .authFailed = result else { return XCTFail("expected authFailed, got \(result)") }
        XCTAssertEqual(http.requests.count, 2)
    }
}
