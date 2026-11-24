import XCTest
@testable import QuotaBar

/// Persisted-aggregate file lifecycle: the `.lock` sidecar `withAggregateFileLock` creates must be
/// removed alongside the `.json`, and aggregates whose source ledger is gone get swept.
final class OpenCodeRouterLedgerAggregateTests: XCTestCase {
    /// Write a decodable aggregate blob plus the `.lock` sidecar for `path`, returning both URLs.
    /// Only the fields `File` decodes matter; the schema value is irrelevant to removal paths.
    private func persistPair(path: String) throws -> (json: URL, lock: URL) {
        let json = OpenCodeRouterLedgerAggregate.fileURL(path: path)
        try FileManager.default.createDirectory(
            at: json.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let blob: [String: Any] = [
            "schema": 18,
            "path": path,
            "timeZoneIdentifier": Calendar.current.timeZone.identifier,
            "device": 1,
            "inode": 2,
            "size": 0,
            "modificationStamp": [
                "seconds": 0, "nanoseconds": 0,
                "changeSeconds": 0, "changeNanoseconds": 0
            ],
            "detailedGoCutoff": 0,
            "offset": 0,
            "partial": "",
            "discarding": false,
            "anchor": "",
            "accountTimestamps": [],
            "buckets": [],
            "goRows": []
        ]
        try JSONSerialization.data(withJSONObject: blob).write(to: json, options: .atomic)
        let lock = json.appendingPathExtension("lock")
        FileManager.default.createFile(atPath: lock.path, contents: Data())
        return (json, lock)
    }

    private func cleanup(_ urls: URL...) {
        for url in urls { try? FileManager.default.removeItem(at: url) }
    }

    func testRemovingPersistedAggregateDeletesLockSidecar() throws {
        let path = "/tmp/opencode-lockpair-\(UUID().uuidString)"
        let (json, lock) = try persistPair(path: path)
        defer { cleanup(json, lock) }

        OpenCodeRouterLedgerAggregate.removePersistedAggregate(path: path)

        XCTAssertFalse(FileManager.default.fileExists(atPath: json.path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: lock.path),
            "the .lock sidecar must not outlive the aggregate it guarded"
        )
    }

    func testRemovingInvalidPersistedAggregateDeletesLockSidecar() throws {
        let path = "/tmp/opencode-invalidpair-\(UUID().uuidString)"
        let json = OpenCodeRouterLedgerAggregate.fileURL(path: path)
        try FileManager.default.createDirectory(
            at: json.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not json".utf8).write(to: json, options: .atomic)
        let lock = json.appendingPathExtension("lock")
        FileManager.default.createFile(atPath: lock.path, contents: Data())
        defer { cleanup(json, lock) }

        OpenCodeRouterLedgerAggregate.removeInvalidPersistedAggregate(path: path)

        XCTAssertFalse(FileManager.default.fileExists(atPath: json.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: lock.path))
    }

    func testOrphanSweepRemovesAggregatesForMissingSourcesAndStrayLocks() throws {
        let gonePath = "/tmp/opencode-gone-source-\(UUID().uuidString)"
        let live = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode-live-ledger-\(UUID().uuidString).jsonl")
        try "{}\n".write(to: live, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.trashItem(at: live, resultingItemURL: nil) }

        let gone = try persistPair(path: gonePath)
        let kept = try persistPair(path: live.path)
        // A lock sidecar whose aggregate blob vanished on its own (crash between unlinks).
        let stray = OpenCodeRouterLedgerAggregate
            .fileURL(path: "/tmp/opencode-stray-\(UUID().uuidString)")
            .appendingPathExtension("lock")
        FileManager.default.createFile(atPath: stray.path, contents: Data())
        defer { cleanup(gone.json, gone.lock, kept.json, kept.lock, stray) }

        OpenCodeRouterLedgerAggregate.removeOrphanedPersistedAggregates()

        XCTAssertFalse(FileManager.default.fileExists(atPath: gone.json.path),
                       "an aggregate whose source disappeared must be swept")
        XCTAssertFalse(FileManager.default.fileExists(atPath: gone.lock.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.json.path),
                      "an aggregate whose source still exists must be kept")
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.lock.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stray.path),
                       "a .lock with no sibling .json is always garbage")
    }

    func testNoonFallsForwardAcrossSkippedDay() throws {
        // Pacific/Apia skipped 2011-12-30 entirely when it jumped the dateline. Asking for that
        // day's noon must still land on a representable midday — the next day — rather than nil.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Pacific/Apia"))
        let skipped = try XCTUnwrap(OpenCodeRouterLedgerAggregate.noon(
            "2011-12-30", timeZoneIdentifier: "Pacific/Apia"
        ))
        XCTAssertEqual(DailyUsageAccumulator.dayKey(from: skipped, calendar: calendar), "2011-12-31")
        let ordinary = try XCTUnwrap(OpenCodeRouterLedgerAggregate.noon(
            "2011-12-29", timeZoneIdentifier: "Pacific/Apia"
        ))
        XCTAssertEqual(DailyUsageAccumulator.dayKey(from: ordinary, calendar: calendar), "2011-12-29")
    }
}
