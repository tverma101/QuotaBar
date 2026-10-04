import XCTest
@testable import QuotaBar

/// CodexRouter meters *every* routed turn, including the ones it hands to OpenCode. Those turns never
/// reach `opencode*.db` (a free Zen model can bypass the OpenCode server entirely) and the Codex card now
/// defers them, so without an OpenCode-side fold they are counted nowhere: a router configured for
/// `opencode-free/space-bunny-free` logged thousands of turns that no card reported at all.
final class RouterLedgerProviderRoutingTests: XCTestCase {
    /// A timestamp a few minutes ago, so an event is always inside the scan window no matter when the
    /// suite runs.
    private static let recentISO = OpenUsageISO8601.string(from: Date().addingTimeInterval(-600))

    /// The shipped ledger wraps the timestamp (`{"meteringVersion":…,"at":"…"}`); the fast-path day
    /// check must find it there too, not only at the start of the line.
    func testWrappedLedgerLinesAreFolded() throws {
        let path = try ledger(
            [("opencode-free", "opencode-free/space-bunny-free", 5_000, 3_000, 900)],
            prefix: #"{"meteringVersion":1,"#
        )
        let folded = rows(path)
        XCTAssertEqual(folded.count, 1)
        XCTAssertEqual(try XCTUnwrap(folded.first).model, "space-bunny-free")
    }

    /// Rows outside the window are excluded by the `since` filter on the cached rows — not by a fast
    /// pre-filter. The earlier test claimed a day-prefix check that no longer exists, which is exactly the
    /// kind of false guarantee this suite exists to prevent.
    func testRowsOutsideTheWindowAreExcluded() throws {
        let stamp = OpenUsageISO8601.string(from: Date().addingTimeInterval(-60 * 86_400))
        let line = #"{"meteringVersion":1,"at":""# + stamp + #"","model":"opencode-free/space-bunny-free","provider":"opencode-free","status":200,"inputTokens":100,"cachedInputTokens":0,"outputTokens":10}"#
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qb-router-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("usage-events.jsonl")
        try (line + "\n").write(to: path, atomically: true, encoding: .utf8)
        XCTAssertTrue(rows(path.path).isEmpty)
    }

    private func ledger(_ rows: [(String, String, Int, Int, Int)], prefix: String = "") throws -> String {
        let lines = rows.map { provider, model, input, cached, output in
            """
            \(prefix.isEmpty ? "{" : prefix)"at":"\(Self.recentISO)","model":"\(model)","provider":"\(provider)","status":200,"inputTokens":\(input),"cachedInputTokens":\(cached),"outputTokens":\(output),"totalTokens":\(input + output)}
            """
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qb-router-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("usage-events.jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: path, atomically: true, encoding: .utf8)
        return path.path
    }

    private func rows(_ path: String) -> [OpenCodeUsageScanner.ClaudeGatewayRow] {
        OpenCodeUsageScanner.routerGatewayRows(atPath: path, since: Date().addingTimeInterval(-86_400))
    }

    func testOpenCodeServedTurnsAreFolded() throws {
        let path = try ledger([("opencode-free", "opencode-free/space-bunny-free", 5_000, 3_000, 900)])
        let folded = rows(path)
        XCTAssertEqual(folded.count, 1)
        XCTAssertEqual(folded[0].model, "space-bunny-free", "the row names the model, not the serving account")
        XCTAssertEqual(folded[0].input, 2_000, "cached is carved out of the inclusive input count")
        XCTAssertEqual(folded[0].cacheRead, 3_000)
        XCTAssertEqual(folded[0].output, 900)
    }

    /// The OpenCode card partitions provider-stamped router rows from legacy native gateway slugs.
    /// `anthropic/opencode_go/...` also appears in Codex/Claude session logs, so the router fold leaves
    /// that spelling to the native fold instead of counting the same turn twice.
    /// The router ledger owns every OpenCode-served turn, the legacy `anthropic/opencode_go/…` slug
    /// included. Dropping that slug here used to rely on the native session-log fold always having it,
    /// which is false whenever the log is absent, rotated away, or lives in a home this scan does not open
    /// — those turns then disappeared from every card. Exactly-once is now enforced one layer up: the
    /// scanner reconciles the two sources per (day, model) and lets the router win the pairs it covers
    /// (`OpenCodeUsageScanner.dayModelKey`).
    func testRouterOwnsEveryOpenCodeServedRowIncludingTheLegacyHostedSlug() throws {
        let path = try ledger([
            ("opencode-go", "anthropic/opencode_go/deepseek-v4-flash", 100, 0, 10),
            ("opencode-go", "deepseek-v4-flash", 100, 0, 10),
            ("opencode", "deepseek-v4-flash", 100, 0, 10),
            ("opencode-free", "opencode-free/space-bunny-free", 100, 0, 10),
            ("openai", "gpt-6-luna", 100, 0, 10),
            ("anthropic", "claude-opus-4-7", 100, 0, 10)
        ])
        let folded = rows(path)
        XCTAssertEqual(folded.count, 4, "every OpenCode-served row belongs on the router fold")
        XCTAssertEqual(Set(folded.map(\.model)), ["deepseek-v4-flash", "space-bunny-free"])
        XCTAssertEqual(
            folded.filter(\.burnsGoQuota).count, 2,
            "the legacy opencode-go slug burns the Go caps just like the bare slug does"
        )
    }

    /// A router-only turn (no matching session log) is still counted, which is the case the old
    /// slug exclusion lost.
    func testLegacyHostedSlugFoldsWithoutAnyNativeSource() throws {
        let path = try ledger([
            ("opencode-go", "anthropic/opencode_go/deepseek-v4-flash", 5_000, 900, 300)
        ])
        let folded = rows(path)
        XCTAssertEqual(folded.count, 1)
        XCTAssertEqual(folded[0].model, "deepseek-v4-flash")
        XCTAssertEqual(folded[0].input, 4_100)
        XCTAssertEqual(folded[0].cacheRead, 900)
        XCTAssertTrue(folded[0].burnsGoQuota)
    }

    /// Both sources must land on the same merge key for a given turn, otherwise the reconciliation in
    /// `scan` treats one turn as two.
    func testRouterAndNativeRowsShareOneDayModelMergeKey() {
        let day = "2026-10-04"
        let router = OpenCodeUsageScanner.ClaudeGatewayRow(
            date: Date(), input: 10, output: 2, cacheWrite: 0, cacheRead: 0,
            model: "deepseek-v4-flash", burnsGoQuota: true, isInProgress: false
        )
        let native = OpenCodeUsageScanner.ClaudeGatewayRow(
            date: Date(), input: 10, output: 2, cacheWrite: 0, cacheRead: 0,
            model: "deepseek-v4-flash", burnsGoQuota: true, isInProgress: false
        )
        XCTAssertEqual(
            OpenCodeUsageScanner.dayModelKey(day: day, model: router.model),
            OpenCodeUsageScanner.dayModelKey(day: day, model: native.model)
        )
        XCTAssertNotEqual(
            OpenCodeUsageScanner.dayModelKey(day: day, model: router.model),
            OpenCodeUsageScanner.dayModelKey(day: "2026-10-05", model: native.model),
            "different days must not collapse into one key"
        )
    }

    func testLegacyAnthropicGatewaySlugIsStillOwnedByTheNativeCodexFold() {
        let event = CodexLogUsageScanner.Event(
            timestamp: Date().addingTimeInterval(-600),
            model: "anthropic/opencode_go/deepseek-v4-flash",
            input: 100,
            cached: 40,
            output: 10,
            reasoning: 0,
            total: 110
        )
        let folded = OpenCodeUsageScanner.codexGatewayRows(from: [event])
        XCTAssertEqual(folded.count, 1)
        XCTAssertEqual(folded[0].model, "deepseek-v4-flash")
        XCTAssertEqual(folded[0].input, 60)
        XCTAssertEqual(folded[0].cacheRead, 40)
        XCTAssertTrue(folded[0].burnsGoQuota)
    }

    /// Only the Go subscription's cap meters are consumed by `opencode-go`; Zen and free tiers are billed
    /// outside them, so charging them would push a Session/Weekly meter past 100%.
    func testOnlyTheGoSubscriptionBurnsCapQuota() throws {
        let path = try ledger([
            ("opencode-go", "m", 100, 0, 10),
            ("opencode-free", "f", 100, 0, 10),
            ("opencode", "z", 100, 0, 10)
        ])
        XCTAssertEqual(rows(path).filter(\.burnsGoQuota).count, 1)
    }

    /// A failed request must not be folded as usage.
    func testFailedRequestsAreNotFolded() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qb-router-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("usage-events.jsonl")
        try """
        {"at":"\(Self.recentISO)","model":"opencode-free/space-bunny-free","provider":"opencode-free","status":500,"inputTokens":100,"outputTokens":10}
        """ .write(to: path, atomically: true, encoding: .utf8)
        XCTAssertTrue(rows(path.path).isEmpty)
    }

    /// `status: 0` is how the router records a canceled/incomplete turn; 4xx/5xx are failed requests.
    /// None is measured usage and none belongs in a spend tile.
    func testCanceledFailedAndNonSuccessStatusesAreNotFolded() throws {
        let stamp = OpenUsageISO8601.string(from: Date().addingTimeInterval(-600))
        let statuses = [0, 199, 300, 400, 429, 500, 502]
        let path = try writeLedger(statuses.map { status in
            #"{"at":"\#(stamp)","model":"opencode-free/space-bunny-free","provider":"opencode-free","status":\#(status),"inputTokens":100,"cachedInputTokens":0,"outputTokens":10}"#
        })
        XCTAssertTrue(rows(path).isEmpty)
    }

    /// The router's `estimatedInputTokens` exists only when upstream reported `inputTokens: 0`. It is a
    /// router-authored approximation for context-window bookkeeping, not a measured provider count, so
    /// QuotaBar must not fold it into the token tiles alongside real usage.
    func testEstimatedInputTokensAreNotCountedAsMeasuredUsage() throws {
        let stamp = OpenUsageISO8601.string(from: Date().addingTimeInterval(-600))
        let text = #"{"at":"\#(stamp)","model":"opencode-free/space-bunny-free","provider":"opencode-free","status":200,"inputTokens":0,"cachedInputTokens":0,"outputTokens":25,"totalTokens":25,"estimatedInputTokens":999999}"#
        let row = try XCTUnwrap(OpenCodeUsageScanner.routerGatewayRow(from: Data(text.utf8)))
        XCTAssertEqual(row.input, 0)
        XCTAssertEqual(row.output, 25)
        XCTAssertEqual(row.tokens, 25, "the estimate must not inflate the measured total")
    }

    /// Chunk boundaries must not corrupt or drop rows: the ledger is read in 1MB chunks and a partial
    /// final line carries over.
    func testRowsSurviveChunkBoundaries() throws {
        let many = (0..<5_000).map { index in
            ("opencode-free", "opencode-free/space-bunny-free", 100 + index, 0, 10)
        }
        let path = try ledger(many)
        XCTAssertEqual(rows(path).count, 5_000, "every line must be read exactly once")
    }

    /// The Codex card defers these turns, so the helper it uses must agree with the one the fold uses.
    func testProviderClassificationIsShared() throws {
        for provider in ["opencode-go", "opencode", "opencode-free", "opencode-zen", "OpenCode-Go"] {
            XCTAssertTrue(CodexRouterUsageScanner.isOpenCodeProvider(provider), provider)
        }
        for provider in ["openai", "anthropic", "gemini", "", "not-opencode"] {
            XCTAssertFalse(CodexRouterUsageScanner.isOpenCodeProvider(provider), provider)
        }
    }

    func testBareModelNameStripsTheServingAccount() {
        XCTAssertEqual(OpenCodeUsageScanner.bareRouterModelName("opencode-free/space-bunny-free"), "space-bunny-free")
        XCTAssertEqual(OpenCodeUsageScanner.bareRouterModelName("opencode-zen-messages/union-alpha"), "union-alpha")
        XCTAssertEqual(OpenCodeUsageScanner.bareRouterModelName("gpt-6-luna"), "gpt-6-luna")
    }

    func testZenNamespaceSlugKeepsMeasuredTokensAndGoQuotaClassification() throws {
        let stamp = OpenUsageISO8601.string(from: Date().addingTimeInterval(-600))
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qb-router-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("usage-events.jsonl").path
        let text = #"{"at":"\#(stamp)","model":"opencode-zen-messages/union-alpha","provider":"opencode-go","status":200,"inputTokens":406,"cachedInputTokens":6,"outputTokens":10,"totalTokens":416}"#
        try (text + "\n").write(toFile: path, atomically: true, encoding: .utf8)

        let folded = rows(path)
        XCTAssertEqual(folded.count, 1)
        XCTAssertEqual(folded[0].model, "union-alpha")
        XCTAssertEqual(folded[0].input, 400)
        XCTAssertEqual(folded[0].cacheRead, 6)
        XCTAssertEqual(folded[0].tokens, 416)
        XCTAssertTrue(folded[0].burnsGoQuota)
    }
}


// MARK: - Truncated lines

extension RouterLedgerProviderRoutingTests {
    /// Large ledgers are compacted to day/model buckets. The first pass reads the file once; a warm pass
    /// must be a no-op; an append must parse only the new bytes and add the delta exactly once.
    func testLargeLedgerCompactsThenWarmAndAppendStayIncremental() throws {
        let stamp = OpenUsageISO8601.string(from: Date().addingTimeInterval(-600))
        let path = try writeLedger((0..<8_192).map { index in
            line(
                provider: "opencode-free",
                model: "opencode-free/space-bunny-free",
                input: 1_000 + index,
                cached: 600,
                output: 10,
                stamp: stamp
            )
        })
        defer { OpenCodeUsageScanner.routerLedgerClearCacheForTesting(path: path) }

        let cold = rows(path)
        XCTAssertEqual(cold.count, 1, "all same-day rows compact to one model bucket")
        XCTAssertEqual(cold[0].model, "space-bunny-free")
        XCTAssertTrue(cold[0].isAggregated, "a bucket is not a single request")
        let coldTokens = cold.reduce(0) { $0 + $1.tokens }
        let expected = (0..<8_192).reduce(0) { $0 + (1_000 + $1) + 10 }
        XCTAssertEqual(coldTokens, expected)

        let coldStats = try XCTUnwrap(OpenCodeUsageScanner.routerLedgerReadStatisticsForTesting(path: path))
        XCTAssertEqual(coldStats.fullParses, 1)
        XCTAssertEqual(coldStats.tailParses, 0)

        let warm = rows(path)
        let warmStats = try XCTUnwrap(OpenCodeUsageScanner.routerLedgerReadStatisticsForTesting(path: path))
        XCTAssertEqual(warm.map(\.tokens), cold.map(\.tokens), "an unchanged ledger must not replay")
        XCTAssertEqual(warmStats.fullParses, coldStats.fullParses)
        XCTAssertEqual(warmStats.tailParses, coldStats.tailParses)
        XCTAssertEqual(warmStats.bytesRead, coldStats.bytesRead, "an unchanged ledger must not read bytes")

        let appended = line(
            provider: "opencode-free",
            model: "opencode-free/space-bunny-free",
            input: 111,
            cached: 11,
            output: 7,
            stamp: stamp
        )
        try appendBytes(appended + "\n", to: path)
        let afterAppend = rows(path)
        XCTAssertEqual(afterAppend.count, 1)
        XCTAssertEqual(afterAppend[0].tokens, coldTokens + 111 + 7)

        let appendStats = try XCTUnwrap(OpenCodeUsageScanner.routerLedgerReadStatisticsForTesting(path: path))
        XCTAssertEqual(appendStats.fullParses, 1, "append must not rebuild the ledger")
        XCTAssertEqual(appendStats.tailParses, 1)
        XCTAssertLessThan(appendStats.bytesRead - coldStats.bytesRead, 1_024)

        let unchanged = rows(path)
        let unchangedStats = try XCTUnwrap(OpenCodeUsageScanner.routerLedgerReadStatisticsForTesting(path: path))
        XCTAssertEqual(unchanged.map(\.tokens), afterAppend.map(\.tokens))
        XCTAssertEqual(unchangedStats.fullParses, appendStats.fullParses)
        XCTAssertEqual(unchangedStats.tailParses, appendStats.tailParses)
        XCTAssertEqual(unchangedStats.bytesRead, appendStats.bytesRead)
    }

    private func writeLedger(_ lines: [String]) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qb-router-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("usage-events.jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: path, atomically: true, encoding: .utf8)
        return path.path
    }

    private func line(provider: String, model: String, input: Int, cached: Int, output: Int, stamp: String) -> String {
        #"{"meteringVersion":1,"at":""# + stamp
            + #"","model":""# + model + #"","provider":""# + provider
            + #"","status":200,"inputTokens":\#(input),"cachedInputTokens":\#(cached),"outputTokens":\#(output)}"#
    }

    /// A line cut short by a writer caught mid-append must be **skipped**, never parsed as a short row.
    ///
    /// The byte scanner defaults absent fields to 0, so a truncated line used to become a wrong row:
    /// `..."inputTokens":1000` charged 1000 uncached input instead of 100 input + 900 cache-read — a ~10x
    /// overstatement, with output tokens silently dropped. `JSONLFileReader` gets this structurally; the
    /// hand-rolled reader has to check it.
    func testATruncatedLineIsSkippedRatherThanParsedAsAShortRow() throws {
        let stamp = OpenUsageISO8601.string(from: Date())
        let whole = line(provider: "opencode-free", model: "opencode-free/space-bunny-free",
                         input: 100, cached: 90, output: 50, stamp: stamp)
        let truncated = String(whole.prefix(whole.count - 30))

        XCTAssertNotNil(OpenCodeUsageScanner.routerGatewayRow(from: Data(whole.utf8)), "sanity")
        XCTAssertNil(
            OpenCodeUsageScanner.routerGatewayRow(from: Data(truncated.utf8)),
            "a cut line must be skipped, not turned into a partial row"
        )

        let path = try writeLedger([whole, truncated])
        XCTAssertEqual(rows(path).count, 1, "only the whole line becomes a row")
    }

    /// The provider is trimmed once and reused, so inclusion and the Go cap-meter flag cannot disagree.
    /// An untrimmed provider used to fold a turn onto the card while excluding it from the cap meters.
    func testPaddedProviderStillBurnsTheGoCapMeters() throws {
        let stamp = OpenUsageISO8601.string(from: Date())
        let path = try writeLedger([line(provider: "  opencode-go  ", model: "m",
                                          input: 100, cached: 0, output: 10, stamp: stamp)])
        let folded = self.rows(path)
        XCTAssertEqual(folded.count, 1)
        XCTAssertTrue(folded[0].burnsGoQuota, "a padded provider must still be recognised as Go")
    }

    /// A hostile digit run saturates at the same 1e15 clamp every other parser here uses, rather than at
    /// `Int.max / 8` (1.15e18 tokens, ~$4.6e12 on one day).
    func testHostileDigitRunSaturatesAtTheFileSownClamp() throws {
        let stamp = OpenUsageISO8601.string(from: Date())
        let huge = String(repeating: "9", count: 40)
        let text = line(provider: "opencode-free", model: "opencode-free/space-bunny-free",
                        input: 1, cached: 0, output: 1, stamp: stamp)
            .replacingOccurrences(of: #""inputTokens":1"#, with: #""inputTokens":\#(huge)"#)
        let row = OpenCodeUsageScanner.routerGatewayRow(from: Data(text.utf8))
        XCTAssertEqual(row?.input, 1_000_000_000_000_000, "must saturate at the codebase's clamp")
    }

    /// The parser clamps an over-long digit run to `Int.max`, so two hostile rows in one day/model bucket
    /// ask the aggregate to add `Int.max + Int.max`. `Int` overflow is a trap, not a wrap: the process
    /// would die inside a menu-bar refresh. Both the bucket sum and the row total must saturate.
    func testTwoHostileRowsSaturateInsteadOfTrapping() throws {
        let stamp = OpenUsageISO8601.string(from: Date())
        let max = String(Int.max)
        let rows = (0..<2).map { _ in
            line(provider: "opencode-free", model: "opencode-free/space-bunny-free",
                 input: 1, cached: 0, output: 1, stamp: stamp)
                .replacingOccurrences(of: #""inputTokens":1"#, with: #""inputTokens":\#(max)"#)
        }

        // Per-row path: each row parses independently and must survive the clamp.
        let path = try writeRaw(rows.joined(separator: "\n") + "\n")
        let folded = self.rows(path)
        XCTAssertEqual(folded.count, 2, "the per-row path keeps both hostile rows")
        for row in folded {
            XCTAssertEqual(row.input, 1_000_000_000_000_000)
            XCTAssertEqual(row.tokens, 1_000_000_000_000_001)
        }

        // Compact path: the day/model bucket adds `Int.max + Int.max`, which traps without saturation.
        let aggregate = OpenCodeRouterLedgerAggregate.empty(
            path: "/tmp/qb-overflow-ledger",
            revision: AppendOnlyFileRevision(device: 1, inode: 1, size: 1)
        )
        for _ in 0..<2 {
            aggregate.addRow(OpenCodeUsageScanner.ClaudeGatewayRow(
                date: Date(), input: .max, output: 0, cacheWrite: 0, cacheRead: 0,
                model: "space-bunny-free", burnsGoQuota: false, isInProgress: false
            ))
        }
        let bucket = try XCTUnwrap(aggregate.materialize(since: .distantPast).first)
        XCTAssertEqual(bucket.input, .max, "Int.max + Int.max saturates instead of trapping")
        XCTAssertTrue(bucket.isAggregated)

        let single = try XCTUnwrap(OpenCodeUsageScanner.routerGatewayRow(from: Data(rows[0].utf8)))
        XCTAssertEqual(single.input, 1_000_000_000_000_000)
        XCTAssertEqual(
            OpenCodeUsageScanner.ClaudeGatewayRow(
                date: Date(), input: .max, output: .max, cacheWrite: .max, cacheRead: .max,
                model: "m", burnsGoQuota: false, isInProgress: false
            ).tokens,
            .max,
            "the four-component row total saturates too"
        )
    }

    /// A provider spelled with a JSON unicode escape (`\u006fpencode-free`) has no literal `opencode`
    /// substring in the raw bytes. The cheap prefilter must hand such lines to the real parser instead
    /// of dropping them on a byte-level guess.
    func testUnicodeEscapedProviderStillFolds() throws {
        let stamp = OpenUsageISO8601.string(from: Date())
        // A model with no literal marker either, so the fixture really does defeat the byte prefilter.
        let text = line(provider: "opencode-free", model: "deepseek-v4-flash",
                        input: 100, cached: 0, output: 10, stamp: stamp)
            .replacingOccurrences(of: #""provider":"opencode-free""#, with: #""provider":"\u006fpencode-go""#)
        XCTAssertFalse(
            text.lowercased().contains("opencode"),
            "the fixture must not contain a literal marker, or it proves nothing"
        )
        let row = OpenCodeUsageScanner.routerGatewayRow(from: Data(text.utf8))
        XCTAssertEqual(row?.model, "deepseek-v4-flash", "an escaped provider is still an OpenCode row")
        XCTAssertEqual(row?.input, 100)
        XCTAssertEqual(row?.tokens, 110)
        XCTAssertTrue(try XCTUnwrap(row).burnsGoQuota, "the escaped provider spelling is still Go")
    }
}


// MARK: - Append / replace lifecycle

extension RouterLedgerProviderRoutingTests {
    /// Writes raw bytes verbatim, so a test can land a writer mid-record or leave off the final newline.
    private func writeRaw(_ text: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qb-router-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("usage-events.jsonl")
        try text.write(to: path, atomically: true, encoding: .utf8)
        return path.path
    }

    private func appendBytes(_ text: String, to path: String) throws {
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    /// A ledger line padded to a byte length using `requestId`, a field the fold never reads.
    ///
    /// Padding the model instead would make the length assertion pass while quietly changing what the row
    /// means, and the model is the field these tests most need to trust. `requestId` ships in the real
    /// ledger and is ignored by `routerGatewayRow`, so varying it moves bytes and nothing else.
    ///
    /// `totalBytes` is a floor, so ask `paddedLineByteCount` for the natural minimum before
    /// choosing a size that both rows can reach.
    private func line(
        provider: String, model: String, input: Int, cached: Int, output: Int,
        stamp: String, paddedTo totalBytes: Int
    ) -> String {
        let filler = max(0, totalBytes - paddedLineByteCount(
            provider: provider, model: model, input: input, cached: cached, output: output, stamp: stamp
        ))
        let head = paddedRowHead(provider: provider, model: model, input: input, cached: cached,
                                 output: output, stamp: stamp)
        return head + String(repeating: "x", count: filler) + "\"}"
    }

    /// A row with `requestId` present but empty, up to (but not including) its closing quote and brace.
    private func paddedRowHead(
        provider: String, model: String, input: Int, cached: Int, output: Int, stamp: String
    ) -> String {
        let base = line(provider: provider, model: model, input: input, cached: cached,
                        output: output, stamp: stamp)
        // `base` is a whole object ending in `}`; re-open it with an extra key so the filler has a home.
        return String(base.dropLast()) + #","requestId":""#
    }

    /// The shortest byte length a padded row can have for these fields.
    private func paddedLineByteCount(
        provider: String, model: String, input: Int, cached: Int, output: Int, stamp: String
    ) -> Int {
        paddedRowHead(provider: provider, model: model, input: input, cached: cached,
                      output: output, stamp: stamp).utf8.count + 2   // closing quote + closing brace
    }

    // MARK: Lifecycle tests

    /// A writer caught mid-append leaves a line with no newline yet. It must not fold, must not be
    /// dropped, and must appear exactly once when the rest of the record lands.
    ///
    /// This is the c6cc756 fix's core invariant. Holding the carry in a function-local buffer made the
    /// offset claim EOF over bytes that had never been parsed, so a row completed by the next refresh
    /// was lost permanently: a silent under-count, not a crash.
    func testARowCompletedByTheNextAppendIsFoldedExactlyOnce() throws {
        let stamp = OpenUsageISO8601.string(from: Date())
        let whole = line(provider: "opencode-free", model: "opencode-free/space-bunny-free", input: 140, cached: 90, output: 50, stamp: stamp)
        let cut = whole.index(whole.startIndex, offsetBy: whole.count / 2)

        let path = try writeRaw(String(whole[..<cut]))
        XCTAssertTrue(
            rows(path).isEmpty,
            "a half-written record must not fold; the writer has not finished the line"
        )

        try appendBytes(String(whole[cut...]) + "\n", to: path)
        let completed = rows(path)
        XCTAssertEqual(completed.count, 1, "the completed record must fold on the next scan")
        XCTAssertEqual(completed[0].input, 50, "cached is carved out of the inclusive input count")
        XCTAssertEqual(completed[0].cacheRead, 90)
        XCTAssertEqual(completed[0].output, 50)

        let unchanged = rows(path)
        XCTAssertEqual(unchanged.count, 1, "an unchanged ledger must not replay the completed record")
        XCTAssertEqual(unchanged[0].tokens, completed[0].tokens)
    }

    /// The ledger is a rotating file, not a strictly growing one. A different file landing at the same
    /// path must replace the cached rows, not merge with them.
    ///
    /// A reset keyed only on `size < offset` misses this entirely: a new file of the same length leaves
    /// the offset pointing into the replacement's bytes and keeps the previous file's rows on the card,
    /// reporting a turn that never happened on this file while dropping the ones that did.
    func testReplacementOfTheSameSizeReplacesTheCachedRows() throws {
        let stamp = OpenUsageISO8601.string(from: Date())
        // Both lines carry a requestId so they can be padded to a byte-identical length; only the filler
        // moves the byte count, so the two files are genuinely the same size. Target the longer row so
        // neither side needs a negative filler.
        let target = max(
            paddedLineByteCount(provider: "opencode-free", model: "opencode-free/model-alpha", input: 100, cached: 90, output: 50, stamp: stamp),
            paddedLineByteCount(provider: "opencode-free", model: "opencode-free/model-beta", input: 300, cached: 70, output: 40, stamp: stamp)
        )
        let original = line(provider: "opencode-free", model: "opencode-free/model-alpha", input: 100, cached: 90, output: 50, stamp: stamp, paddedTo: target)
        let replacement = line(provider: "opencode-free", model: "opencode-free/model-beta", input: 300, cached: 70, output: 40, stamp: stamp, paddedTo: target)
        XCTAssertEqual(replacement.utf8.count, original.utf8.count, "this case needs equal lengths")

        let path = try writeRaw(original + "\n")
        let before = rows(path)
        XCTAssertEqual(before.count, 1)
        XCTAssertEqual(before[0].model, "model-alpha")

        try (replacement + "\n").write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)

        let after = rows(path)
        XCTAssertEqual(after.count, 1, "the replacement's rows replace the original's, they do not add to them")
        XCTAssertEqual(after[0].model, "model-beta", "no row from the replaced file may survive")
        XCTAssertEqual(after[0].input, 230, "cached is carved out of the inclusive input count")
        XCTAssertEqual(after[0].output, 40)
    }

    /// Same contract when the new file is larger, which is the case an offset-based reset handles least
    /// obviously: the old offset now sits inside the replacement, so a reader that trusts it skips the
    /// head of the new file entirely.
    func testReplacementLargerThanTheOriginalReplacesTheCachedRows() throws {
        let stamp = OpenUsageISO8601.string(from: Date())
        let original = line(provider: "opencode-go", model: "anthropic/opencode_go/old-model", input: 10, cached: 0, output: 1, stamp: stamp)
        let replacement = line(provider: "opencode-go", model: "anthropic/opencode_go/new-model-with-a-longer-name", input: 20, cached: 5, output: 2, stamp: stamp)
        XCTAssertGreaterThan(replacement.utf8.count, original.utf8.count, "this case needs a strictly larger file")

        let path = try writeRaw(original + "\n")
        let before = rows(path)
        XCTAssertEqual(before.count, 1)
        XCTAssertEqual(before[0].model, "old-model")

        try (replacement + "\n").write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)

        let after = rows(path)
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after[0].model, "new-model-with-a-longer-name", "no row from the replaced file may survive")
        XCTAssertEqual(after[0].input, 15, "cached is carved out of the inclusive input count")
        XCTAssertTrue(after[0].burnsGoQuota, "a replacement must not lose the provider classification")
    }

    /// A complete final record with no trailing newline is a finished row, not a partial one.
    ///
    /// The ledger is append-only and read live, so a record whose bytes have all landed is real usage and
    /// must count now; the writer is not obliged to add a newline before moving on. This matches
    /// `JSONLFileReader.readLines`, whose full-read default (`deliverFinalPartial: true`) already delivers
    /// the final line. It is safe here precisely because `routerGatewayRow` requires the line to start
    /// with `{` and end with `}`, which is what rejects the truncations that would otherwise become wrong
    /// rows.
    ///
    /// The follow-up append pins the no-double-count property: once delivered, a later newline plus the
    /// next record must add exactly one row.
    func testCompleteFinalRecordWithoutNewlineIsFoldedAndNotReplayed() throws {
        let stamp = OpenUsageISO8601.string(from: Date())
        let whole = line(provider: "opencode-free", model: "opencode-free/space-bunny-free", input: 200, cached: 20, output: 30, stamp: stamp)
        let path = try writeRaw(whole)   // deliberately no trailing newline

        let first = rows(path)
        XCTAssertEqual(
            first.count, 1,
            "a complete final JSON object must fold even without a trailing newline"
        )
        XCTAssertEqual(first[0].input, 180)
        XCTAssertEqual(first[0].output, 30)

        let next = line(provider: "opencode-free", model: "opencode-free/space-bunny-free", input: 60, cached: 0, output: 6, stamp: stamp)
        try appendBytes("\n" + next + "\n", to: path)

        let after = rows(path)
        XCTAssertEqual(after.count, 2, "the already-delivered record must not be folded a second time")
        XCTAssertEqual(after.map(\.input), [180, 60])
    }
}
