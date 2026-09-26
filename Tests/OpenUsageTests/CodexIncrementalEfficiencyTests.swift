import Foundation
import XCTest
@testable import OpenUsage

final class CodexIncrementalEfficiencyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_777_507_200)

    func testGrowingRolloutReadsOnlyAppendedBytesAndPreservesModelTierAndTotalsBaseline() async throws {
        let initial = [
            CodexLogFixture.turnContext(timestamp: "2026-04-29T08:00:00.000Z", model: "gpt-5.2"),
            CodexLogFixture.threadSettingsApplied(
                timestamp: "2026-04-29T08:00:30.000Z", serviceTier: "priority", model: "gpt-5.2"
            ),
            CodexLogFixture.tokenCount(
                timestamp: "2026-04-29T08:01:00.000Z",
                totals: CodexLogFixture.usage(input: 100, cached: 10, output: 20)
            ),
        ].joined(separator: "\n") + "\n"
        let home = try CodexLogFixture.makeHome(files: ["sessions/rollout.jsonl": initial])
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent("sessions/rollout.jsonl")
        let scanner = CodexLogFixture.scanner(home: home)

        let first = await scanner.parsedEvents(daysBack: 33, now: now, homes: [home])
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first[0].input, 100)
        XCTAssertEqual(first[0].model, "gpt-5.2")
        XCTAssertTrue(first[0].isFast)
        let firstStats = try XCTUnwrap(CodexLogUsageScanner.incrementalReadStatisticsForTesting(path: file.path))
        XCTAssertEqual(firstStats.fullParses, 1)
        XCTAssertEqual(firstStats.tailParses, 0)
        XCTAssertEqual(firstStats.bytesRead, initial.utf8.count)

        let appended = CodexLogFixture.tokenCount(
            timestamp: "2026-04-29T08:02:00.000Z",
            totals: CodexLogFixture.usage(input: 150, cached: 15, output: 30)
        ) + "\n"
        try append(appended, to: file)

        let second = await scanner.parsedEvents(daysBack: 33, now: now, homes: [home])
        XCTAssertEqual(second.count, 2)
        XCTAssertEqual(second[1].input, 50, "cumulative totals must resume from the pre-append baseline")
        XCTAssertEqual(second[1].cached, 5)
        XCTAssertEqual(second[1].output, 10)
        XCTAssertEqual(second[1].model, "gpt-5.2", "model state must survive the byte checkpoint")
        XCTAssertTrue(second[1].isFast, "service-tier state must survive the byte checkpoint")

        let secondStats = try XCTUnwrap(CodexLogUsageScanner.incrementalReadStatisticsForTesting(path: file.path))
        XCTAssertEqual(secondStats.fullParses, 1)
        XCTAssertEqual(secondStats.tailParses, 1)
        XCTAssertEqual(
            secondStats.bytesRead,
            initial.utf8.count + appended.utf8.count,
            "the second refresh must pay only for appended bytes, not reread the historical prefix"
        )
    }

    func testHalfWrittenFinalJSONIsCarriedUntilAppendCompletesIt() async throws {
        let context = CodexLogFixture.turnContext(timestamp: "2026-04-29T08:00:00.000Z", model: "gpt-5.2") + "\n"
        let token = CodexLogFixture.tokenCount(
            timestamp: "2026-04-29T08:01:00.000Z",
            last: CodexLogFixture.usage(input: 10, output: 5)
        )
        let split = token.index(token.startIndex, offsetBy: token.count / 2)
        let firstHalf = String(token[..<split])
        let secondHalf = String(token[split...]) + "\n"
        let initial = context + firstHalf
        let home = try CodexLogFixture.makeHome(files: ["sessions/partial.jsonl": initial])
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent("sessions/partial.jsonl")
        let scanner = CodexLogFixture.scanner(home: home)

        let before = await scanner.parsedEvents(daysBack: 33, now: now, homes: [home])
        XCTAssertTrue(before.isEmpty, "invalid half-written JSON must not be treated as a complete event")

        try append(secondHalf, to: file)
        let after = await scanner.parsedEvents(daysBack: 33, now: now, homes: [home])
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after[0].input, 10)
        XCTAssertEqual(after[0].model, "gpt-5.2")

        let stats = try XCTUnwrap(CodexLogUsageScanner.incrementalReadStatisticsForTesting(path: file.path))
        XCTAssertEqual(stats.fullParses, 1)
        XCTAssertEqual(stats.tailParses, 1)
        XCTAssertEqual(stats.bytesRead, initial.utf8.count + secondHalf.utf8.count)
    }

    func testChildReplayGateAndCumulativeBaselineSurviveAcrossAppend() async throws {
        let creation = "2026-04-29T08:03:00.000Z"
        let creationEpoch = Int(try XCTUnwrap(OpenUsageISO8601.date(from: creation)).timeIntervalSince1970)
        let initial = [
            CodexLogFixture.subagentSessionMeta(timestamp: creation),
            CodexLogFixture.taskStarted(timestamp: "2026-04-29T08:03:00.100Z", startedAt: creationEpoch - 900),
            CodexLogFixture.tokenCount(
                timestamp: "2026-04-29T08:03:00.200Z",
                totals: CodexLogFixture.usage(input: 1_000, output: 200)
            ),
        ].joined(separator: "\n") + "\n"
        let home = try CodexLogFixture.makeHome(files: ["sessions/child.jsonl": initial])
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent("sessions/child.jsonl")
        let scanner = CodexLogFixture.scanner(home: home)

        let replayOnly = await scanner.parsedEvents(daysBack: 33, now: now, homes: [home])
        XCTAssertTrue(replayOnly.isEmpty)

        let appended = [
            CodexLogFixture.taskStarted(
                timestamp: "2026-04-29T08:03:01.000Z", startedAt: creationEpoch + 1
            ),
            CodexLogFixture.tokenCount(
                timestamp: "2026-04-29T08:04:00.000Z",
                totals: CodexLogFixture.usage(input: 1_100, output: 220),
                model: "gpt-5.2"
            ),
        ].joined(separator: "\n") + "\n"
        try append(appended, to: file)

        let events = await scanner.parsedEvents(daysBack: 33, now: now, homes: [home])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].input, 100)
        XCTAssertEqual(events[0].output, 20)
        let stats = try XCTUnwrap(CodexLogUsageScanner.incrementalReadStatisticsForTesting(path: file.path))
        XCTAssertEqual(stats.fullParses, 1)
        XCTAssertEqual(stats.tailParses, 1)
    }

    func testReplacementOrRewriteFallsBackToFullParseInsteadOfTrustingOldCheckpoint() async throws {
        let firstText = CodexLogFixture.tokenCount(
            timestamp: "2026-04-29T08:01:00.000Z",
            last: CodexLogFixture.usage(input: 10, output: 5),
            model: "gpt-5.2"
        ) + "\n"
        let home = try CodexLogFixture.makeHome(files: ["sessions/rewrite.jsonl": firstText])
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent("sessions/rewrite.jsonl")
        let scanner = CodexLogFixture.scanner(home: home)
        let initialEvents = await scanner.parsedEvents(daysBack: 33, now: now, homes: [home])
        XCTAssertEqual(initialEvents.map(\.input), [10])

        let replacement = [
            CodexLogFixture.turnContext(timestamp: "2026-04-29T09:00:00.000Z", model: "gpt-5.2"),
            CodexLogFixture.tokenCount(
                timestamp: "2026-04-29T09:01:00.000Z",
                last: CodexLogFixture.usage(input: 77, output: 11)
            ),
        ].joined(separator: "\n") + "\n"
        try replacement.write(to: file, atomically: true, encoding: .utf8)

        let events = await scanner.parsedEvents(daysBack: 33, now: now, homes: [home])
        XCTAssertEqual(events.map(\.input), [77], "replacement contents must replace, not append to, cached events")
        let stats = try XCTUnwrap(CodexLogUsageScanner.incrementalReadStatisticsForTesting(path: file.path))
        XCTAssertEqual(stats.fullParses, 2)
        XCTAssertEqual(stats.tailParses, 0)
    }

    func testColdParseRetainsOnlyWorkingWindowEvents() async throws {
        let text = [
            CodexLogFixture.tokenCount(
                timestamp: "2025-01-01T08:00:00.000Z",
                last: CodexLogFixture.usage(input: 999, output: 1),
                model: "gpt-5.2"
            ),
            CodexLogFixture.tokenCount(
                timestamp: "2026-04-29T08:00:00.000Z",
                last: CodexLogFixture.usage(input: 25, output: 5),
                model: "gpt-5.2"
            ),
        ].joined(separator: "\n") + "\n"
        let home = try CodexLogFixture.makeHome(files: ["sessions/history.jsonl": text])
        defer { try? FileManager.default.removeItem(at: home) }
        let scanner = CodexLogFixture.scanner(home: home)

        let recent = await scanner.parsedEvents(daysBack: 33, now: now, homes: [home])
        XCTAssertEqual(recent.map(\.input), [25])
        XCTAssertEqual(
            CodexLogUsageScanner.parseFile(Data(text.utf8)).map(\.input),
            [999, 25],
            "retention belongs to the incremental cache, not the parser's compatibility semantics"
        )
    }

    func testOneHundredSmallAppendsStayLinearInBytesRead() async throws {
        let initial = [
            CodexLogFixture.turnContext(timestamp: "2026-04-29T08:00:00.000Z", model: "gpt-5.2"),
            CodexLogFixture.tokenCount(
                timestamp: "2026-04-29T08:01:00.000Z",
                last: CodexLogFixture.usage(input: 10, output: 5)
            ),
        ].joined(separator: "\n") + "\n"
        let home = try CodexLogFixture.makeHome(files: ["sessions/linear.jsonl": initial])
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent("sessions/linear.jsonl")
        let scanner = CodexLogFixture.scanner(home: home)

        var expectedBytesRead = initial.utf8.count
        let first = await scanner.parsedEvents(daysBack: 33, now: now, homes: [home])
        XCTAssertEqual(first.count, 1)

        for index in 0..<100 {
            let minute = 2 + index / 60
            let second = index % 60
            let timestamp = String(format: "2026-04-29T08:%02d:%02d.000Z", minute, second)
            let appended = CodexLogFixture.tokenCount(
                timestamp: timestamp,
                last: CodexLogFixture.usage(input: index + 1, output: 1)
            ) + "\n"
            expectedBytesRead += appended.utf8.count
            try append(appended, to: file)

            let events = await scanner.parsedEvents(daysBack: 33, now: now, homes: [home])
            XCTAssertEqual(events.count, index + 2)
        }

        let stats = try XCTUnwrap(CodexLogUsageScanner.incrementalReadStatisticsForTesting(path: file.path))
        XCTAssertEqual(stats.fullParses, 1)
        XCTAssertEqual(stats.tailParses, 100)
        XCTAssertEqual(
            stats.bytesRead,
            expectedBytesRead,
            "100 refreshes after 100 small appends must read each source byte once, not repeatedly replay history"
        )
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }
}
