import XCTest
@testable import QuotaBar

/// Integration coverage for the experimental TPS Tracker card: a hermetic Claude + Codex fixture
/// home, the real scanners, and the provider's scope plumbing. Also pins the owner-confirmed
/// placement defaults (fresh-install on, On Demand breakdown rows, no menu-bar pins).
@MainActor
final class TPSTrackerProviderTests: XCTestCase {
    private func claudeFixture(output: Int = 100, now: Date) throws -> URL {
        let stamps = (0..<6).map { now.addingTimeInterval(TimeInterval($0 * 5 - 120)) }
        let lines = stamps.enumerated().map { index, stamp in
            ClaudeLogFixture.usageLine(
                timestamp: OpenUsageISO8601.string(from: stamp),
                input: 10,
                output: output,
                messageID: "msg_\(index)",
                requestID: "req_\(index)"
            )
        }
        return try ClaudeLogFixture.makeUserHome(
            claudeFiles: ["workspace/session.jsonl": lines.joined(separator: "\n")]
        )
    }

    private func grokFixture(output: Int = 100, now: Date) throws -> URL {
        let stamps = (0..<6).map { now.addingTimeInterval(TimeInterval($0 * 5 - 120)) }
        let lines = stamps.enumerated().map { index, stamp in
            GrokLogFixture.completedTurn(
                timestamp: OpenUsageISO8601.string(from: stamp),
                model: "grok-4.6-build",
                input: 10,
                output: output,
                eventID: "grok-turn-\(index)"
            )
        }
        return try GrokLogFixture.makeHome(
            files: ["session-1/updates.jsonl": lines.joined(separator: "\n")]
        )
    }

    private func museFixture(output: Int = 100, now: Date) throws -> URL {
        let stamps = (0..<6).map { now.addingTimeInterval(TimeInterval($0 * 5 - 120)) }
        let lines = stamps.map { stamp -> String in
            let micros = Int(stamp.timeIntervalSince1970 * 1_000_000)
            let record = "{\"quantity\": {\"reported\": true, \"unit\": \"tokens\", \"input_tokens\": 10, \"output_tokens\": \(output), \"cached_tokens\": 0, \"reasoning_tokens\": 0, \"model\": \"muse-spark-1.2-contributor\"}}"
            return "{\"payload\": {\"event\": {\"kind\": \"goal_usage_attribution\", \"record\": \(record)}}, \"recorded_at\": \(micros)}"
        }
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("openusage-muse-\(UUID().uuidString)", isDirectory: true)
        let sessions = home.appendingPathComponent(".local/share/muse/sessions/session-1", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try lines.joined(separator: "\n")
            .write(to: sessions.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)
        return home
    }

    private func zaiFixture(now: Date) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("openusage-zai-tps-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("db.sqlite").path
        func sqlite(_ sql: String) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
            process.arguments = [path, sql]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
        }
        try sqlite("""
        CREATE TABLE model_usage (
            id TEXT PRIMARY KEY,
            logical_request_id TEXT NOT NULL DEFAULT '',
            attempt_index INTEGER NOT NULL DEFAULT 0,
            session_id TEXT NOT NULL DEFAULT 's',
            query_source TEXT NOT NULL DEFAULT 'chat',
            provider_id TEXT NOT NULL DEFAULT 'account:zai-test',
            model_id TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'completed',
            started_at INTEGER NOT NULL,
            first_token_at INTEGER,
            completed_at INTEGER,
            output_tokens INTEGER NOT NULL DEFAULT 0,
            input_tokens INTEGER NOT NULL DEFAULT 0,
            reasoning_tokens INTEGER NOT NULL DEFAULT 0,
            cache_creation_input_tokens INTEGER NOT NULL DEFAULT 0,
            cache_read_input_tokens INTEGER NOT NULL DEFAULT 0,
            computed_total_tokens INTEGER NOT NULL DEFAULT 0,
            retryable INTEGER NOT NULL DEFAULT 0,
            cancelled_by_user INTEGER NOT NULL DEFAULT 0,
            context_exceeded INTEGER NOT NULL DEFAULT 0
        );
        """)
        var sql = "INSERT INTO model_usage (id, model_id, status, started_at, first_token_at, completed_at, output_tokens) VALUES "
        var rows: [String] = []
        let base = Int64(now.timeIntervalSince1970 * 1000)
        // Six direct stream rows: 100 output over 5s of stream time each.
        for i in 0..<6 {
            let start = base - 120_000 + Int64(i) * 5_000
            rows.append("('a\(i)','glm-5-flash','completed',\(start),\(start),\(start + 5_000),100)")
        }
        // Three rows without a stream window (pair rule): 5s apart, 100 output each.
        for i in 0..<3 {
            let start = base - 300_000 + Int64(i) * 5_000
            rows.append("('b\(i)','glm-4.7','completed',\(start),NULL,NULL,100)")
        }
        // A cancelled row and an ancient row: both ignored.
        rows.append("('c0','glm-5-flash','cancelled',\(base - 1_000),\(base - 900),\(base + 900),100)")
        rows.append("('a9','glm-5-flash','completed',\(base - 40 * 86_400_000),NULL,NULL,100)")
        try sqlite(sql + rows.joined(separator: ","))
        return path
    }

    private func piFixture(output: Int = 100, now: Date) throws -> URL {
        let stamps = (0..<6).map { now.addingTimeInterval(TimeInterval($0 * 5 - 120)) }
        let lines = stamps.enumerated().map { index, stamp in
            "{\"type\":\"message\",\"id\":\"pi-m-\(index)\",\"timestamp\":\"\(OpenUsageISO8601.string(from: stamp))\",\"message\":{\"role\":\"assistant\",\"provider\":\"openai-codex\",\"model\":\"gpt-5.2\",\"usage\":{\"input\":10,\"output\":\(output),\"cacheRead\":0,\"cacheWrite\":0,\"cacheWrite1h\":0,\"totalTokens\":\(10 + output)}}}"
        }
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("openusage-pi-\(UUID().uuidString)", isDirectory: true)
        let sessions = home.appendingPathComponent(".pi/agent/sessions/work", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try lines.joined(separator: "\n")
            .write(to: sessions.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)
        return home
    }

    private func codexFixture(output: Int = 100, now: Date) throws -> URL {
        let stamps = (0..<6).map { now.addingTimeInterval(TimeInterval($0 * 5 - 120)) }
        let lines = stamps.enumerated().map { index, stamp in
            CodexLogFixture.tokenCount(
                timestamp: OpenUsageISO8601.string(from: stamp),
                last: CodexLogFixture.usage(input: 10, output: output),
                totals: CodexLogFixture.usage(input: 10 * (index + 1), output: output * (index + 1))
            )
        }
        return try CodexLogFixture.makeHome(
            files: ["sessions/2026/11/16/rollout-tps-test.jsonl": lines.joined(separator: "\n")]
        )
    }

    private func provider(
        claudeHome: URL,
        codexHome: URL,
        zaiDatabasePath: @escaping @Sendable () -> String? = { nil },
        now: @escaping @Sendable () -> Date
    ) -> TPSTrackerProvider {
        let claude = ClaudeLogUsageScanner(
            environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": claudeHome.appendingPathComponent(".claude").path]),
            homeDirectory: { FileManager.default.temporaryDirectory.appendingPathComponent("openusage-no-claude-home") },
            incrementalScanner: IncrementalJSONLScanner<ClaudeLogUsageScanner.Entry>()
        )
        let codex = CodexLogUsageScanner(
            environment: FakeEnvironment(["CODEX_HOME": codexHome.path]),
            homeDirectory: { FileManager.default.temporaryDirectory.appendingPathComponent("openusage-no-codex-home") },
            incrementalScanner: IncrementalJSONLScanner<CodexLogUsageScanner.Event>()
        )
        let grok = GrokLogUsageScanner(
            environment: FakeEnvironment([:]),
            homeDirectory: { FileManager.default.temporaryDirectory.appendingPathComponent("openusage-no-grok-home") },
            incrementalScanner: IncrementalJSONLScanner<GrokLogUsageScanner.Entry>()
        )
        let muse = MuseUsageScanner(
            homeDirectory: { FileManager.default.temporaryDirectory.appendingPathComponent("openusage-no-muse-home") },
            incrementalScanner: IncrementalJSONLScanner<MuseUsageScanner.Entry>()
        )
        let pi = PiUsageScanner(
            environment: FakeEnvironment([:]),
            homeDirectory: { FileManager.default.temporaryDirectory.appendingPathComponent("openusage-no-pi-home") },
            incrementalScanner: IncrementalJSONLScanner<PiUsageScanner.Entry>()
        )
        return TPSTrackerProvider(
            scanner: TokensPerSecondScanner(
                claude: claude,
                codex: codex,
                grok: grok,
                muse: muse,
                pi: pi,
                museSessionsRoot: {
                    FileManager.default.temporaryDirectory
                        .appendingPathComponent("openusage-no-muse-home")
                },
                zaiDatabasePath: zaiDatabasePath,
                antigravityHome: {
                    FileManager.default.temporaryDirectory
                        .appendingPathComponent("openusage-no-antigravity-home")
                }
            ),
            now: now
        )
    }

    private func fullyWiredProvider(
        claudeHome: URL,
        codexHome: URL,
        grokHome: URL,
        museHome: URL,
        piHome: URL,
        zaiDatabasePath: @escaping @Sendable () -> String? = { nil },
        now: @escaping @Sendable () -> Date
    ) -> TPSTrackerProvider {
        let claude = ClaudeLogUsageScanner(
            environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": claudeHome.appendingPathComponent(".claude").path]),
            homeDirectory: { FileManager.default.temporaryDirectory.appendingPathComponent("openusage-no-claude-home") },
            incrementalScanner: IncrementalJSONLScanner<ClaudeLogUsageScanner.Entry>()
        )
        let codex = CodexLogUsageScanner(
            environment: FakeEnvironment(["CODEX_HOME": codexHome.path]),
            homeDirectory: { FileManager.default.temporaryDirectory.appendingPathComponent("openusage-no-codex-home") },
            incrementalScanner: IncrementalJSONLScanner<CodexLogUsageScanner.Event>()
        )
        let grok = GrokLogUsageScanner(
            environment: FakeEnvironment(["GROK_HOME": grokHome.path]),
            homeDirectory: { FileManager.default.temporaryDirectory.appendingPathComponent("openusage-no-grok-home") },
            incrementalScanner: IncrementalJSONLScanner<GrokLogUsageScanner.Entry>()
        )
        let muse = MuseUsageScanner(
            homeDirectory: { museHome },
            incrementalScanner: IncrementalJSONLScanner<MuseUsageScanner.Entry>()
        )
        let pi = PiUsageScanner(
            environment: FakeEnvironment([:]),
            homeDirectory: { piHome },
            incrementalScanner: IncrementalJSONLScanner<PiUsageScanner.Entry>()
        )
        return TPSTrackerProvider(
            scanner: TokensPerSecondScanner(
                claude: claude,
                codex: codex,
                grok: grok,
                muse: muse,
                pi: pi,
                museSessionsRoot: { museHome.appendingPathComponent(".local/share/muse/sessions") },
                zaiDatabasePath: zaiDatabasePath,
                antigravityHome: {
                    FileManager.default.temporaryDirectory
                        .appendingPathComponent("openusage-no-antigravity-home")
                }
            ),
            now: now
        )
    }

    func testFullRefreshEmitsAllThreeRows() async throws {
        let now = Date()
        let claudeHome = try claudeFixture(now: now)
        let codexHome = try codexFixture(now: now)
        defer {
            try? FileManager.default.removeItem(at: claudeHome)
            try? FileManager.default.removeItem(at: codexHome)
        }
        let provider = provider(claudeHome: claudeHome, codexHome: codexHome, now: { now })

        let snapshot = await provider.refresh()
        let values = Dictionary(uniqueKeysWithValues: snapshot.lines.compactMap { line -> (String, [MetricValue])? in
            guard case .values(let label, let values, _, _, _, _) = line else { return nil }
            return (label, values)
        })
        XCTAssertEqual(Set(values.keys), ["Est. TPS", "Claude", "Codex"])
        for (label, rate) in [("Est. TPS", 20.0), ("Claude", 20.0), ("Codex", 20.0)] {
            let row = try XCTUnwrap(values[label])
            XCTAssertEqual(try XCTUnwrap(row.first).kind, .count)
            XCTAssertEqual(try XCTUnwrap(row.first).label, "tok/s")
            XCTAssertEqual(try XCTUnwrap(row.first).number, rate, accuracy: 1e-9, label)
        }
    }

    func testEveryProviderWithLocalLogsFoldsIn() async throws {
        let now = Date()
        let claudeHome = try claudeFixture(now: now)
        let codexHome = try codexFixture(now: now)
        let grokHome = try grokFixture(now: now)
        let museHome = try museFixture(now: now)
        let piHome = try piFixture(now: now)
        defer {
            for home in [claudeHome, codexHome, grokHome, museHome, piHome] {
                try? FileManager.default.removeItem(at: home)
            }
        }
        let provider = fullyWiredProvider(
            claudeHome: claudeHome,
            codexHome: codexHome,
            grokHome: grokHome,
            museHome: museHome,
            piHome: piHome,
            now: { now }
        )

        let snapshot = await provider.refresh()
        let values = Dictionary(uniqueKeysWithValues: snapshot.lines.compactMap { line -> (String, [MetricValue])? in
            guard case .values(let label, let values, _, _, _, _) = line else { return nil }
            return (label, values)
        })
        XCTAssertEqual(
            Set(values.keys),
            ["Est. TPS", "Claude", "Codex", "Grok", "Muse", "Pi"],
            "every corpus with fixture logs must emit a row"
        )
        for label in ["Claude", "Codex", "Grok", "Muse", "Pi"] {
            let row = try XCTUnwrap(values[label])
            XCTAssertEqual(try XCTUnwrap(row.first).number, 20, accuracy: 1e-9, label)
        }
        // Est. TPS is the token-weighted combined rate across all five corpora.
        let overall = try XCTUnwrap(values["Est. TPS"]?.first)
        XCTAssertEqual(overall.number, 20, accuracy: 1e-9)
    }

    func testZAIStreamRowsFoldIntoTheLens() async throws {
        let now = Date()
        let claudeHome = try claudeFixture(now: now)
        let codexHome = try codexFixture(now: now)
        let grokHome = try grokFixture(now: now)
        let museHome = try museFixture(now: now)
        let piHome = try piFixture(now: now)
        let zaiPath = try zaiFixture(now: now)
        defer {
            for home in [claudeHome, codexHome, grokHome, museHome, piHome] {
                try? FileManager.default.removeItem(at: home)
            }
            try? FileManager.default.removeItem(atPath: (zaiPath as NSString).deletingLastPathComponent)
        }
        let provider = fullyWiredProvider(
            claudeHome: claudeHome,
            codexHome: codexHome,
            grokHome: grokHome,
            museHome: museHome,
            piHome: piHome,
            zaiDatabasePath: { zaiPath },
            now: { now }
        )

        let snapshot = await provider.refresh()
        let values = Dictionary(uniqueKeysWithValues: snapshot.lines.compactMap { line -> (String, [MetricValue])? in
            guard case .values(let label, let values, _, _, _, _) = line else { return nil }
            return (label, values)
        })
        XCTAssertEqual(
            Set(values.keys),
            ["Est. TPS", "Claude", "Codex", "Grok", "Muse", "Pi", "Z.ai"],
            "ZCode stream rows fold into the lens alongside the other corpora"
        )
        let zai = try XCTUnwrap(values["Z.ai"])
        XCTAssertEqual(try XCTUnwrap(zai.first).number, 20, accuracy: 1e-9, "mixed direct and pair rows share the same math")

        let zaiBreakdown = snapshot.lines.first(where: { $0.label == "Z.ai" }).flatMap { line -> ModelUsageBreakdown? in
            guard case .values(_, _, _, _, _, let breakdown) = line else { return nil }
            return breakdown
        }
        XCTAssertEqual(zaiBreakdown?.models.map(\.model).sorted(), ["glm-4.7", "glm-5-flash"])
        let flash = try XCTUnwrap(zaiBreakdown?.models.first(where: { $0.model == "glm-5-flash" }))
        XCTAssertEqual(flash.tokensPerSecond ?? 0, 20, accuracy: 1e-9)
    }

    func testMetersOnlyScopeSkipsLocalFold() async throws {
        let now = Date()
        let claudeHome = try claudeFixture(now: now)
        let codexHome = try codexFixture(now: now)
        defer {
            try? FileManager.default.removeItem(at: claudeHome)
            try? FileManager.default.removeItem(at: codexHome)
        }
        let provider = provider(claudeHome: claudeHome, codexHome: codexHome, now: { now })

        let snapshot = await ProviderRefreshContext.$scope.withValue(.panelMeters) {
            await provider.refresh()
        }
        XCTAssertTrue(snapshot.lines.isEmpty, "meters-only passes must not parse local corpora")
    }

    func testMissingSourcesYieldNoDataRows() async throws {
        let now = Date()
        let claudeHome = try ClaudeLogFixture.makeUserHome(claudeFiles: [:])
        let codexHome = try CodexLogFixture.makeHome(files: [:])
        defer {
            try? FileManager.default.removeItem(at: claudeHome)
            try? FileManager.default.removeItem(at: codexHome)
        }
        let provider = provider(claudeHome: claudeHome, codexHome: codexHome, now: { now })

        let snapshot = await provider.refresh()
        for line in snapshot.lines {
            guard case .values(_, let values, _, _, _, _) = line else {
                return XCTFail("expected .values rows")
            }
            XCTAssertTrue(values.isEmpty, line.label)
        }
    }

    func testHasLocalCredentialsMirrorsLocalLogRoots() async {
        let empty = TPSTrackerProvider(
            scanner: TokensPerSecondScanner(
                claude: ClaudeLogUsageScanner(
                    environment: FakeEnvironment([:]),
                    homeDirectory: { FileManager.default.temporaryDirectory.appendingPathComponent("openusage-no-claude-home") },
                    incrementalScanner: IncrementalJSONLScanner<ClaudeLogUsageScanner.Entry>()
                ),
                codex: CodexLogUsageScanner(
                    environment: FakeEnvironment([:]),
                    homeDirectory: { FileManager.default.temporaryDirectory.appendingPathComponent("openusage-no-codex-home") },
                    incrementalScanner: IncrementalJSONLScanner<CodexLogUsageScanner.Event>()
                )
            ),
            logRoots: { [FileManager.default.temporaryDirectory.appendingPathComponent("openusage-empty-claude")] }
        )
        let missing = await empty.hasLocalCredentials()
        XCTAssertFalse(missing)

        let withClaude = TPSTrackerProvider(logRoots: {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("openusage-tps-probe-\(UUID().uuidString)/projects")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return [dir]
        })
        let found = await withClaude.hasLocalCredentials()
        XCTAssertTrue(found)
    }

    func testOwnerConfirmedTPSDefaultsAreDataOnly() throws {
        let provider = TPSTrackerProvider()
        let ids = provider.widgetDescriptors.map(\.id)
        XCTAssertEqual(ids, ["tps.overall", "tps.claude", "tps.codex", "tps.grok", "tps.muse", "tps.pi", "tps.zai", "tps.antigravity"])
        // The TPS provider is a data source for the Total Spend panel — its rows ship off by
        // default everywhere; no dashboard placement, pin, or On Demand membership exists.
        let layoutSets = [
            DefaultLayout.metricIDs,
            DefaultLayout.expandedMetricIDs,
            DefaultLayout.pinnedMetricIDs,
            DefaultLayout.migrationBaselineMetricIDs
        ]
        for ids in layoutSets {
            XCTAssertTrue(Set(ids).isDisjoint(with: ["tps.overall", "tps.claude", "tps.codex"]))
        }
        XCTAssertTrue(ProviderEnablementPersistence.initiallyEnabledProviderIDs.contains("tps"))
        XCTAssertTrue(ProviderCatalog.make().contains { $0.provider.id == "tps" })
    }

    func testHistoryExportAdmitsCardToPanelAccounting() {
        let provider = TPSTrackerProvider()
        let history = provider.widgetDescriptors
            .compactMap { $0.historyResource }
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.scope, .machineLocal)
    }
}
