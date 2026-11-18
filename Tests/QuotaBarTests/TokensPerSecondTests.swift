import XCTest
@testable import QuotaBar

/// Unit coverage for the pure TPS fold (estimate model, accumulator) and the metric-line mapping —
/// no filesystem, no actors.
final class TokensPerSecondTests: XCTestCase {
    private func corpus(
        _ ingests: [(Int, TimeInterval)]
    ) -> TokensPerSecondCorpus {
        var accumulator = TokensPerSecondAccumulator()
        var elapsed: TimeInterval = 0
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for (output, delta) in ingests {
            elapsed += delta
            accumulator.ingest(outputTokens: output, at: start.addingTimeInterval(elapsed), model: nil)
        }
        return accumulator.corpus
    }

    func testSingleEntryYieldsNoIntervals() {
        let accumulator = TokensPerSecondAccumulator()
        var one = TokensPerSecondAccumulator()
        one.ingest(outputTokens: 500, at: Date(timeIntervalSince1970: 1_800_000_000), model: nil)
        XCTAssertEqual(accumulator.corpus, TokensPerSecondCorpus())
        XCTAssertEqual(one.corpus.intervals, 0)
        XCTAssertNil(one.corpus.tokensPerSecond)
    }

    func testTokenWeightedMeanOverQualifyingIntervals() throws {
        // 6 entries of 100 tokens, 5 s apart → 5 qualifying intervals of 5 s each.
        let result = corpus([(100, 0), (100, 5), (100, 5), (100, 5), (100, 5), (100, 5)])
        XCTAssertEqual(result.intervals, 5)
        XCTAssertEqual(result.seconds, 25, accuracy: 1e-9)
        XCTAssertEqual(result.outputTokens, 500, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(result.tokensPerSecond), 20, accuracy: 1e-9)
    }

    func testSubIntervalAndIdleGapAreExcluded() {
        // 100-token bursts at 5 s cadence, plus one timer-granularity pair (0.05 s) and one
        // idle gap (300 s). Neither pollutes the estimate.
        let result = corpus([
            (100, 0), (100, 5), (100, 0.05), (100, 5), (100, 300), (100, 5)
        ])
        XCTAssertEqual(result.intervals, 3)
        XCTAssertEqual(result.seconds, 15, accuracy: 1e-9)
    }

    func testOutOfOrderPairIsRebasedNotFolded() {
        // Cross-file order can go backwards; the pair is dropped and the clock re-based.
        var accumulator = TokensPerSecondAccumulator()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        accumulator.ingest(outputTokens: 100, at: start, model: nil)
        accumulator.ingest(outputTokens: 100, at: start.addingTimeInterval(-30), model: nil)
        accumulator.ingest(outputTokens: 100, at: start.addingTimeInterval(10), model: nil)
        XCTAssertEqual(accumulator.corpus.intervals, 1)
        XCTAssertEqual(accumulator.corpus.seconds, 40, accuracy: 1e-9)
    }

    func testZeroOutputEntryIsSkippedButRebasesClock() {
        var accumulator = TokensPerSecondAccumulator()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        accumulator.ingest(outputTokens: 100, at: start, model: nil)
        accumulator.ingest(outputTokens: 0, at: start.addingTimeInterval(5), model: nil)
        accumulator.ingest(outputTokens: 100, at: start.addingTimeInterval(8), model: nil)
        // The 0-token report re-bases the clock: 3 s pair, not a phantom 8 s one.
        XCTAssertEqual(accumulator.corpus.intervals, 1)
        XCTAssertEqual(accumulator.corpus.seconds, 3, accuracy: 1e-9)
    }

    func testBelowMinimumIntervalsYieldsNoEstimate() {
        let result = corpus([(100, 0), (100, 5), (100, 5), (100, 5)])
        XCTAssertEqual(result.intervals, 3)
        XCTAssertNil(result.tokensPerSecond)
    }

    func testCombinedCorpusSumsBothCorpora() {
        var claude = TokensPerSecondAccumulator()
        var codex = TokensPerSecondAccumulator()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for offset in stride(from: 0, through: 25, by: 5) {
            claude.ingest(outputTokens: 100, at: start.addingTimeInterval(Double(offset)), model: nil)
        }
        for offset in stride(from: 0, through: 50, by: 10) {
            codex.ingest(outputTokens: 400, at: start.addingTimeInterval(Double(offset)), model: nil)
        }
        let estimate = TokensPerSecondEstimate(
            corpora: ["claude": claude.corpus, "codex": codex.corpus],
            models: [:]
        )
        XCTAssertEqual(estimate.combined.intervals, 10)
        XCTAssertEqual(estimate.combined.seconds, 75, accuracy: 1e-9)
        XCTAssertEqual(estimate.combined.outputTokens, 2500, accuracy: 1e-9)
    }

    func testMapperProducesTypedValuesRows() throws {
        var accumulator = TokensPerSecondAccumulator()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for offset in stride(from: 0, through: 25, by: 5) {
            accumulator.ingest(outputTokens: 120, at: start.addingTimeInterval(Double(offset)), model: "Test-Model")
        }
        let codexCorpus = TokensPerSecondCorpus()
        let estimate = TokensPerSecondEstimate(
            corpora: ["claude": accumulator.corpus, "codex": codexCorpus],
            models: ["claude": accumulator.modelShares]
        )

        let lines = TokensPerSecondMapper.lines(estimate)
        XCTAssertEqual(lines.map(\.label), ["Est. TPS", "Claude", "Codex"])

        let overall = try XCTUnwrap(valuesLine(lines, "Est. TPS"))
        XCTAssertEqual(overall.count, 2)
        XCTAssertEqual(overall[0].kind, .count)
        XCTAssertEqual(overall[0].label, "tok/s")
        XCTAssertEqual(overall[0].number, 24, accuracy: 1e-9)
        XCTAssertTrue(overall[0].estimated)
        XCTAssertEqual(overall[1].label, "tokens")
        XCTAssertEqual(overall[1].number, 600, accuracy: 1e-9)

        let claudeLine = lines.first { $0.label == "Claude" }
        guard case .values(_, let claudeValues, _, _, _, let breakdown)? = claudeLine else {
            return XCTFail("expected a .values Claude row")
        }
        XCTAssertEqual(claudeValues.first?.number ?? 0, 24, accuracy: 1e-9)
        XCTAssertEqual(breakdown?.models.first?.model, "Test-Model")
        XCTAssertEqual(breakdown?.models.first?.tokensPerSecond ?? 0, 24, accuracy: 1e-9)
        XCTAssertEqual(breakdown?.models.first?.totalTokens, 600)

        // No qualifying Codex data → no rate value, so the panel shows no Codex slice.
        let codex = try XCTUnwrap(valuesLine(lines, "Codex"))
        XCTAssertTrue(codex.isEmpty)
    }

    func testMapperEmptyEstimateYieldsOnlyTheSummaryRow() throws {
        let lines = TokensPerSecondMapper.lines(TokensPerSecondEstimate(corpora: [:], models: [:]))
        guard lines.count == 1, let only = lines.first else {
            return XCTFail("empty estimate must emit exactly the Est. TPS row, got \(lines.map(\.label))")
        }
        let values = try XCTUnwrap(valuesLine([only], "Est. TPS"))
        XCTAssertTrue(values.isEmpty)
    }

    private func valuesLine(_ lines: [MetricLine], _ label: String) throws -> [MetricValue]? {
        try lines.first(where: { $0.label == label }).map {
            guard case .values(_, let values, _, _, _, _) = $0 else {
                throw NSError(domain: "TokensPerSecondTests", code: 1)
            }
            return values
        }
    }
}
