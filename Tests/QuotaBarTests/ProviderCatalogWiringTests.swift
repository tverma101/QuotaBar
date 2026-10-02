import XCTest
@testable import QuotaBar

/// Guards the seam where a provider's default arguments are silently bypassed.
///
/// `ProviderCatalog` does not use `OpenCodeProvider.init`'s defaults — it constructs an
/// `OpenCodeUsageScanner` itself and passes it in. Wiring a source only on the provider's default argument
/// therefore compiles, passes every test that constructs the scanner directly, and reads **nothing** in the
/// running app. That is exactly how Space Bunny's 2.2B tokens stayed uncounted while the unit tests were
/// green.
///
/// These assert on the catalog-built object, i.e. the object the app really uses.
@MainActor
final class ProviderCatalogWiringTests: XCTestCase {
    private func catalogOpenCode() throws -> OpenCodeProvider {
        try XCTUnwrap(
            ProviderCatalog.make().compactMap { $0 as? OpenCodeProvider }.first
        )
    }

    func testTheProductionScannerIsToldAboutTheRouterLedger() throws {
        let paths = try catalogOpenCode().usageScanner.routerLedgerPaths()
        XCTAssertFalse(
            paths.isEmpty,
            "ProviderCatalog builds the scanner itself, so the router ledger must be wired there — " +
            "relying on OpenCodeProvider.init's default leaves it reading nothing in the real app"
        )
    }

    func testTheProductionScannerIsToldAboutTheOtherFoldsToo() throws {
        let scanner = try catalogOpenCode().usageScanner
        XCTAssertFalse(scanner.claudeRoots().isEmpty, "Claude gateway fold source")
        XCTAssertFalse(scanner.codexHomes().isEmpty, "Codex gateway fold source")
        // Hermes is optional — the closure is what must be wired, and nil is the correct answer on a
        // machine without a Hermes database.
        _ = scanner.hermesStateDBPath()
    }

    /// End-to-end: whatever the fold's sources resolve to must actually produce rows on this machine.
    /// Skipped when none of the sources exist, so it stays honest on a machine without a router.
    func testAtLeastOneConfiguredSourceYieldsRows() throws {
        let scanner = try catalogOpenCode().usageScanner
        let ledgerPaths = scanner.routerLedgerPaths()
        guard let first = ledgerPaths.first(where: { FileManager.default.isReadableFile(atPath: $0) }) else {
            throw XCTSkip("no router ledger on this machine")
        }
        XCTAssertFalse(
            OpenCodeUsageScanner.routerGatewayRows(atPath: first, since: Date().addingTimeInterval(-86_400)).isEmpty,
            "the ledger is readable but yields no rows — the reader or the provider filter is wrong"
        )
    }
}
