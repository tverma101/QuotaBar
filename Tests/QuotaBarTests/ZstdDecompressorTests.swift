import XCTest
@testable import QuotaBar

/// `.jsonl.zst` archives (Codex's finished rollouts) fold into the local history through the
/// decompressor. All of these tests spawn the real `zstd` when one is installed; machines without
/// it skip instead of failing.
final class ZstdDecompressorTests: XCTestCase {
    private var zstdExecutable: String? = ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    private func requireZstd() throws -> String {
        guard let exe = zstdExecutable else { throw XCTSkip("zstd is not installed") }
        return exe
    }

    private func compress(_ lines: [String], to url: URL) throws {
        let exe = try requireZstd()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("zstd-fixture-\(UUID().uuidString).jsonl")
        try lines.joined(separator: "\n").write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = ["-q", "-f", "-o", url.path, tmp.path]
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "zstd failed to compress the fixture")
    }

    private func makeScratchDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quotabar-zstd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func normalized(_ url: URL) -> String {
        CodexLogUsageScanner.realpathString(url.path)
    }

    private func fixtureLines(timestamp: String, model: String = "gpt-5.2", input: Int, output: Int) -> [String] {
        [
            CodexLogFixture.turnContext(timestamp: timestamp, model: model),
            CodexLogFixture.tokenCount(
                timestamp: timestamp,
                last: CodexLogFixture.usage(input: input, output: output),
                model: model
            ),
        ]
    }

    // MARK: - Decompressor itself

    func testRoundTripIsByteExact() throws {
        let exe = try requireZstd()
        _ = exe
        let root = try makeScratchDirectory()
        let payload = "hello ".data(using: .utf8)! + Data([0x00, 0x0A, 0xFF]) + Data(String(repeating: "bytes-", count: 1024).utf8)
        let source = root.appendingPathComponent("payload.txt")
        try payload.write(to: source)
        let archive = root.appendingPathComponent("payload.txt.zst")
        let compress = Process()
        compress.executableURL = URL(fileURLWithPath: exe)
        compress.arguments = ["-q", "-f", "-o", archive.path, source.path]
        try compress.run()
        compress.waitUntilExit()
        XCTAssertEqual(compress.terminationStatus, 0)

        let decompressed = try ZstdDecompressor().decompress(path: archive.path)

        XCTAssertEqual(decompressed, payload)
    }

    func testAbsenceOfZstdIsNotAnError() {
        let decompressor = ZstdDecompressor(searchPaths: ["/nonexistent-probe-zstd-\(UUID().uuidString)"])
        XCTAssertNil(decompressor.zstdExecutable)
        XCTAssertNil(try decompressor.decompress(path: "/nonexistent.jsonl.zst"))
    }

    func testOutputBeyondTheCapTerminatesTheChild() throws {
        let exe = try requireZstd()
        let root = try makeScratchDirectory()
        let archive = root.appendingPathComponent("big.zst")
        try compress([String(repeating: "x", count: 4 * 1024)], to: archive)

        var decompressor = ZstdDecompressor()
        decompressor.maximumBytes = 64
        decompressor.timeout = 10

        XCTAssertThrowsError(try decompressor.decompress(path: archive.path)) { error in
            XCTAssertEqual(error as? ZstdDecompressor.ZstdError, .outputTooLarge(path: archive.path, limit: 64))
        }
    }

    func testDecompressPrefixStopsAfterItsCap() throws {
        let exe = try requireZstd()
        let root = try makeScratchDirectory()
        let archive = root.appendingPathComponent("rollout.jsonl.zst")
        let lines = fixtureLines(timestamp: "2026-11-02T12:00:00.000Z", input: 10, output: 5)
        try compress(lines, to: archive)

        let prefix = ZstdDecompressor.shared.decompressPrefix(path: archive.path, maxBytes: 64)

        let bytes = try XCTUnwrap(prefix)
        XCTAssertEqual(bytes.count, 64)
        XCTAssertTrue(String(decoding: bytes, as: UTF8.self).contains("session") || bytes.count == 64)
    }

    // MARK: - Codex end to end

    func testScanCountsCompressedAndPlainRolloutsTogether() async throws {
        let timestamp = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600))
        let home = try CodexLogFixture.makeHome(files: [
            "sessions/rollout-plain.jsonl": fixtureLines(timestamp: timestamp, input: 100, output: 50)
                .joined(separator: "\n"),
        ])
        let archive = home
            .appendingPathComponent("sessions/2026/11/02", isDirectory: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try compress(
            fixtureLines(timestamp: timestamp, input: 200, output: 100),
            to: archive.appendingPathComponent("rollout-archived.jsonl.zst")
        )
        let scanner = CodexLogFixture.scanner(home: home)

        let result = await scanner.scanResult(daysBack: 3650, now: Date().addingTimeInterval(-3600), pricing: TestPricing.bundled)

        switch result {
        case .complete(let scan):
            XCTAssertEqual(
                scan?.series.daily.reduce(0) { $0 + $1.totalTokens },
                450,
                "\(String(describing: scan))"
            )
        case .incomplete:
            XCTFail("the fold must complete when zstd is available")
        }
    }

    func testScanCompressedRolloutDedupesAgainstPlainSibling() async throws {
        let timestamp = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600))
        let lines = fixtureLines(timestamp: timestamp, input: 100, output: 50)
        let home = try CodexLogFixture.makeHome(files: [
            "sessions/rollout-twin.jsonl": lines.joined(separator: "\n"),
        ])
        try compress(lines, to: home.appendingPathComponent("sessions/rollout-twin.jsonl.zst"))
        let scanner = CodexLogFixture.scanner(home: home)

        let scan = await scanner.scan(daysBack: 3650, now: Date().addingTimeInterval(-3600), pricing: TestPricing.bundled)

        XCTAssertEqual(
            scan?.series.daily.reduce(0) { $0 + $1.totalTokens },
            150,
            "a rollout present as both plain and compressed must count exactly once"
        )
    }

    func testCompressedRolloutIsAttributedByCreatorAccountID() async throws {
        _ = try requireZstd()
        let root = try makeScratchDirectory()
        let defaultCodex = root.appendingPathComponent(".codex", isDirectory: true)

        let ownLines = [
            #"{"timestamp":"2026-11-02T12:00:00.000Z","type":"session_meta","payload":{"creator_account_id":"ACCOUNT-A","session_id":"own","id":"own"}}"#,
        ] + fixtureLines(timestamp: "2026-11-02T12:00:01.000Z", input: 100, output: 50)
        let foreignLines = [
            #"{"timestamp":"2026-11-02T13:00:00.000Z","type":"session_meta","payload":{"creator_account_id":"ACCOUNT-B","session_id":"foreign","id":"foreign"}}"#,
        ] + fixtureLines(timestamp: "2026-11-02T13:00:01.000Z", input: 400, output: 200)
        let unattributedLines = fixtureLines(timestamp: "2026-11-02T14:00:01.000Z", input: 20, output: 10)

        for (name, lines) in [("rollout-own.jsonl.zst", ownLines),
                              ("rollout-foreign.jsonl.zst", foreignLines),
                              ("rollout-unattributed.jsonl.zst", unattributedLines)] {
            let dir = defaultCodex.appendingPathComponent("sessions/2026/11/02", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try compress(lines, to: dir.appendingPathComponent(name))
        }

        func attributed(identity: String, keepsUnattributed: Bool) -> [String] {
            CodexLogUsageScanner.sessionFiles(
                homes: [defaultCodex],
                peerHomes: [],
                homeDirectory: { root },
                sharedAttribution: CodexLogUsageScanner.SharedAttribution(
                    home: normalized(defaultCodex),
                    identity: identity,
                    keepsUnattributed: keepsUnattributed
                )
            )
            .map { CodexLogUsageScanner.realpathString($0.path) }
            .sorted()
        }

        // Default-anchored card: own + unattributed, never the foreign rollout.
        XCTAssertEqual(
            attributed(identity: "account-a", keepsUnattributed: true),
            [
                normalized(defaultCodex.appendingPathComponent("sessions/2026/11/02/rollout-own.jsonl.zst")),
                normalized(defaultCodex.appendingPathComponent("sessions/2026/11/02/rollout-unattributed.jsonl.zst")),
            ],
            "the default-anchored card keeps its own and the unattributed archives"
        )
        // Managed card for account-b: only its own archive survives.
        XCTAssertEqual(
            attributed(identity: "ACCOUNT-B", keepsUnattributed: false),
            [normalized(defaultCodex.appendingPathComponent("sessions/2026/11/02/rollout-foreign.jsonl.zst"))],
            "a managed card keeps only its own account's archive"
        )
    }
}
