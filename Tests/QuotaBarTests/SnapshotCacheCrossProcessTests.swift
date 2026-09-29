import Foundation
import XCTest
@testable import QuotaBar

/// The persisted snapshot blob is shared by two processes: the app and `quotabar-cli`.
///
/// The in-memory mirror that made this cache fast also made it self-contained, and `store` merged into
/// that mirror — so a write rewrote the *whole* blob from state frozen at first read and destroyed every
/// entry another process had added since.
///
/// Reproduced end-to-end before the fix: the CLI wrote `claude = 95%`, the app's next pass stored
/// `cursor` only, and the blob on disk came back with `claude = 80%`. Worse, the destroyed value carried
/// a recent `refreshedAt`, so the next non-forced CLI read served 80% as TTL-fresh.
@MainActor
final class SnapshotCacheCrossProcessTests: XCTestCase {
    /// Builds a cache over an *already cleared* domain. Each instance is a distinct object with its own
    /// memo, standing in for a separate process.
    private func makeCache(_ defaults: UserDefaults) -> ProviderSnapshotCache {
        ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600)
    }

    private func clearedDefaults(_ suite: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    /// `plan` doubles as the payload marker, so the assertion is a plain string compare on what actually
    /// survived to disk.
    private func snapshot(_ provider: String, plan: String, at: Date) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: provider,
            displayName: provider,
            plan: plan,
            lines: [],
            refreshedAt: at
        )
    }

    func testASecondWriterDoesNotGetClobberedByTheFirst() throws {
        let suite = "OpenUsageTests.SnapshotCrossProcess.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let now = Date()

        // Two independent cache instances over the same domain = two processes.
        let defaults = clearedDefaults(suite)
        let app = makeCache(defaults)
        let cli = makeCache(defaults)

        // The interleaving that destroyed data, in order:
        //  1. the app reads the blob — its mirror is now frozen at "no entries";
        //  2. the CLI writes claude;
        //  3. the app stores cursor, merging into that now-stale mirror and rewriting the whole blob.
        _ = app.loadSnapshots(providerIDs: ["claude", "cursor"])
        cli.store(snapshot("claude", plan: "CLI-95", at: now))
        app.store(snapshot("cursor", plan: "APP-12", at: now))

        // Read the result back through a *third* instance, which is what a fresh launch or the other
        // process would see — the observable consequence, not an internal detail.
        let reader = makeCache(defaults)
        let persisted = reader.loadSnapshots(providerIDs: ["claude", "cursor"])
        XCTAssertEqual(
            persisted["claude"]?.plan, "CLI-95",
            "the other process's entry must survive our write"
        )
        XCTAssertEqual(persisted["cursor"]?.plan, "APP-12")
    }

    /// The mirror is still a memo: repeated reads with no external write must not re-decode, or the
    /// fix would reintroduce the O(N)-decode-per-pass cost the memo exists to avoid.
    func testUnchangedBlobStillUsesTheMemo() throws {
        let suite = "OpenUsageTests.SnapshotMemo.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let cache = makeCache(clearedDefaults(suite))
        cache.store(snapshot("claude", plan: "A", at: Date()))

        // Two consecutive reads after our own write: no external change, so the mirror stands.
        XCTAssertEqual(cache.loadSnapshots(providerIDs: ["claude"])["claude"]?.plan, "A")
        XCTAssertEqual(cache.loadSnapshots(providerIDs: ["claude"])["claude"]?.plan, "A")

        cache.store(snapshot("cursor", plan: "B", at: Date()))
        XCTAssertEqual(
            cache.loadSnapshots(providerIDs: ["claude"])["claude"]?.plan, "A",
            "our own earlier write must survive"
        )
        XCTAssertEqual(cache.loadSnapshots(providerIDs: ["cursor"])["cursor"]?.plan, "B")
    }
}
