import XCTest
@testable import OpenUsage

/// The app-saved OpenCode Go key store: file roundtrip, add/remove, corrupt-file failure, and the
/// active-selection persistence (UserDefaults).
final class OpenCodeGoKeyStoreTests: XCTestCase {
    private func store(files: TextFileAccessing = FakeFiles(), path: String = "/keys.json") -> OpenCodeGoKeyStore {
        OpenCodeGoKeyStore(files: files, filePath: { path })
    }

    func testLoadKeysEmptyWhenAbsent() throws {
        XCTAssertEqual(try store().loadKeys(), [])
    }

    func testAddKeyPersistsWithTrimmedKeyAndDefaultLabel() throws {
        let files = FakeFiles()
        let saved = try store(files: files).addKey(label: "   ", key: "  sk-abc  ")
        XCTAssertEqual(saved.label, "Account 1")
        XCTAssertEqual(saved.key, "sk-abc")
        XCTAssertEqual(try store(files: files).loadKeys(), [saved])
    }

    func testAddKeyRejectsEmptyKey() {
        XCTAssertThrowsError(try store().addKey(label: "Work", key: "   "))
    }

    func testRemoveKeyPersists() throws {
        let files = FakeFiles()
        let s = store(files: files)
        let a = try s.addKey(label: "A", key: "sk-a")
        let b = try s.addKey(label: "B", key: "sk-b")
        try s.removeKey(id: a.id)
        XCTAssertEqual(try s.loadKeys(), [b])
    }

    func testRemoveMissingKeyIsNoOp() throws {
        let s = store()
        try s.removeKey(id: UUID())
        XCTAssertEqual(try s.loadKeys(), [])
    }

    func testCorruptFileThrows() {
        let files = FakeFiles(["/keys.json": "not json"])
        XCTAssertThrowsError(try store(files: files).loadKeys())
    }

    func testSelectionRoundTrip() {
        let suite = "OpenCodeGoKeyStoreTests-" + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else { return XCTFail("suite unavailable") }
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertNil(OpenCodeGoKeyStore.activeSelection(defaults: defaults))
        OpenCodeGoKeyStore.setActiveSelection("abc", defaults: defaults)
        XCTAssertEqual(OpenCodeGoKeyStore.activeSelection(defaults: defaults), "abc")
        OpenCodeGoKeyStore.setActiveSelection(nil, defaults: defaults)
        XCTAssertNil(OpenCodeGoKeyStore.activeSelection(defaults: defaults))
    }
}
