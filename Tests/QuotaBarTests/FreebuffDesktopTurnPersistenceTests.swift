import XCTest
@testable import QuotaBar

final class FreebuffDesktopTurnPersistenceTests: XCTestCase {
    private var scratch: URL!
    private let path = "/tmp/quota-bar-test/projects/desktop-v2.db"

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("freebuff-turn-persistence-\(UUID().uuidString)", isDirectory: true)
        FreebuffDesktopTurnPersistence.directoryOverride = scratch
    }

    override func tearDown() {
        FreebuffDesktopTurnPersistence.directoryOverride = nil
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
        super.tearDown()
    }

    private func record(
        revision: [FreebuffDesktopUsageScanner.Revision],
        rows: [FreebuffDesktopUsageScanner.DerivedTurn] = []
    ) -> FreebuffDesktopTurnPersistence.Record {
        FreebuffDesktopTurnPersistence.Record(
            schema: FreebuffDesktopTurnPersistence.schema,
            revision: revision,
            rows: rows,
            unreadableRows: 0
        )
    }

    private func revision(path: String, modified: Date) -> FreebuffDesktopUsageScanner.Revision {
        FreebuffDesktopUsageScanner.Revision(path: path, size: 1024, modified: modified, changed: modified)
    }

    func testRoundTripsDerivedTurns() throws {
        let modified = TestLocalInstant.date(2026, 11, 10, 9)
        let liveRevision = [revision(path: path, modified: modified)]
        let rows = [
            FreebuffDesktopUsageScanner.DerivedTurn(
                id: "cloud:run-1",
                timestampMs: modified.timeIntervalSince1970 * 1000,
                usage: .counts(
                    input: .value(1200), output: .value(340), cached: .value(200),
                    reasoning: .absent, reportedTotal: .invalid
                ),
                savedModel: "m-normal",
                fromReceipt: true,
                partial: false
            ),
            FreebuffDesktopUsageScanner.DerivedTurn(
                id: "local-2",
                timestampMs: modified.timeIntervalSince1970 * 1000,
                usage: nil,
                savedModel: nil,
                fromReceipt: false,
                partial: true
            ),
        ]
        FreebuffDesktopTurnPersistence.write(record(revision: liveRevision, rows: rows), path: path)

        let loaded = FreebuffDesktopTurnPersistence.read(path: path, revision: liveRevision)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.rows.count, 2)
        XCTAssertEqual(loaded?.unreadableRows, 0)
        // The `.invalid` reported-total count and the usage-less turn survive the round trip.
        guard case .counts(_, _, _, _, let reportedTotal) = loaded?.rows[0].usage else {
            return XCTFail("first turn lost its usage counts")
        }
        XCTAssertEqual(reportedTotal, .invalid)
    }

    func testRejectsRecordWhoseRevisionNoLongerMatches() throws {
        let modified = TestLocalInstant.date(2026, 11, 10, 9)
        let written = [revision(path: path, modified: modified)]
        FreebuffDesktopTurnPersistence.write(record(revision: written), path: path)

        let rewritten = [revision(path: path, modified: modified.addingTimeInterval(5))]
        XCTAssertNil(FreebuffDesktopTurnPersistence.read(path: path, revision: rewritten))
        // The exact revision still reads back.
        XCTAssertNotNil(FreebuffDesktopTurnPersistence.read(path: path, revision: written))
    }

    func testIgnoresRecordsWithOtherSchemaVersions() throws {
        let revision = [revision(path: path, modified: TestLocalInstant.date(2026, 11, 10, 9))]
        let url = FreebuffDesktopTurnPersistence.fileURL(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        var stale = record(revision: revision)
        stale.schema = FreebuffDesktopTurnPersistence.schema + 99
        try encoder.encode(stale).write(to: url, options: .atomic)

        XCTAssertNil(FreebuffDesktopTurnPersistence.read(path: path, revision: revision))
    }
}
