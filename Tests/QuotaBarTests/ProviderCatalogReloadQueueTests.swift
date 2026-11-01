import XCTest
@testable import QuotaBar

final class ProviderCatalogReloadQueueTests: XCTestCase {
    func testCodexReloadCoversEarlierOpenCodeReloadButKeepsLaterChanges() {
        var queue = ProviderCatalogReloadQueue()
        queue.enqueue(.openCodeGoKeys)
        queue.enqueue(.codexAccounts)

        XCTAssertEqual(queue.takeNext(), .codexAccounts)
        XCTAssertNil(queue.takeNext(), "the full account scan also captured the earlier OpenCode change")

        queue.enqueue(.openCodeGoKeys)
        XCTAssertEqual(queue.takeNext(), .openCodeGoKeys, "a later OpenCode change needs a fresh composition")
    }

    func testOpenCodeReloadDoesNotConsumePendingCodexRegistration() {
        var queue = ProviderCatalogReloadQueue()
        queue.enqueue(.openCodeGoKeys)

        XCTAssertEqual(queue.takeNext(), .openCodeGoKeys)
        queue.enqueue(.codexAccounts)
        XCTAssertEqual(queue.takeNext(), .codexAccounts)
    }

    func testFullAccountReloadCoversClaudeEnablementAndOpenCodeKeys() {
        var queue = ProviderCatalogReloadQueue()
        queue.enqueue(.openCodeGoKeys)
        queue.enqueue(.claudeAccounts)

        XCTAssertEqual(queue.takeNext(), .claudeAccounts)
        XCTAssertNil(queue.takeNext(), "the Claude account scan also rebuilds OpenCode descriptors")

        queue.enqueue(.claudeAccounts)
        queue.enqueue(.codexAccounts)
        XCTAssertEqual(queue.takeNext(), .codexAccounts, "Codex registration triggers the full account scan")
        XCTAssertNil(queue.takeNext())
    }
}
