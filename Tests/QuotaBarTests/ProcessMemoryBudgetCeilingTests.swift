import XCTest
@testable import QuotaBar

final class ProcessMemoryBudgetCeilingTests: XCTestCase {
    private let megabyte: UInt64 = 1024 * 1024

    /// Regression: the ceiling was capped at the hard limit, so a footprint of 214 MB set it to
    /// 160 MB and the very next provider unloaded every cache again (184 unloads in 2.5 hours).
    func testCeilingAboveTheHardLimitStillSitsAboveTheFootprint() {
        let footprint = 214 * megabyte
        let ceiling = ProcessMemoryBudget.softUnloadCeiling(afterUnloadAt: footprint)
        XCTAssertGreaterThan(ceiling, footprint)
        XCTAssertEqual(ceiling, footprint + ProcessMemoryBudget.softUnloadMarginBytes)
    }

    func testCeilingNeverDropsBelowTheSoftLimit() {
        XCTAssertEqual(
            ProcessMemoryBudget.softUnloadCeiling(afterUnloadAt: 10 * megabyte),
            ProcessMemoryBudget.softLimitBytes
        )
    }
}
