import XCTest
import SwiftUI
@testable import QuotaBar

final class TotalSpendPaletteTests: XCTestCase {
    func testKnownProvidersMapToBrandColors() {
        XCTAssertEqual(TotalSpendPalette.color(for: "freebuff"), Color(red: 245/255, green: 158/255, blue: 11/255))
        XCTAssertEqual(TotalSpendPalette.color(for: "zai"), Color(red: 6/255, green: 182/255, blue: 212/255))
        XCTAssertEqual(TotalSpendPalette.color(for: "codex"), Color(red: 16/255, green: 163/255, blue: 127/255))
        XCTAssertEqual(TotalSpendPalette.color(for: "claude"), Color(red: 222/255, green: 115/255, blue: 86/255))
    }

    func testFreebuffAndCodexAccountDoNotCollide() {
        let palette = TotalSpendPalette.palette(for: ["freebuff", "codex@0577ce6e", "codex", "zai", "antigravity", "claude", "cursor"])
        XCTAssertNotEqual(palette["freebuff"], palette["codex@0577ce6e"])
        XCTAssertNotEqual(palette["codex"], palette["codex@0577ce6e"])
        XCTAssertNotEqual(palette["freebuff"], palette["codex"])
        XCTAssertNotEqual(palette["zai"], palette["cursor"])
        XCTAssertNotEqual(palette["zai"], palette["antigravity"])
    }

    func testPaletteGuaranteesUniqueColorsForVisibleSlices() {
        let providers = ["freebuff", "codex@0577ce6e", "codex", "zai", "antigravity", "claude", "cursor"]
        let palette = TotalSpendPalette.palette(for: providers)
        var seenColors: Set<Color> = []
        for provider in providers {
            guard let color = palette[provider] else {
                return XCTFail("Missing color for \(provider)")
            }
            XCTAssertFalse(seenColors.contains(color), "Duplicate color detected for provider \(provider)")
            seenColors.insert(color)
        }
        XCTAssertEqual(seenColors.count, providers.count)
    }

    func testSecondaryAccountResolvesToFamilyVariant() {
        let secondary = TotalSpendPalette.color(for: "codex@0577ce6e")
        let primary = TotalSpendPalette.color(for: "codex")
        XCTAssertNotEqual(secondary, primary)
    }

    func testZCodePricingResolution() {
        let flash = TestPricing.bundled.resolve(model: "GLM-5.3-Flash")
        XCTAssertNotNil(flash, "GLM-5.3-Flash should resolve")
        XCTAssertEqual(flash?.inputPerMillion, 0.15)
        XCTAssertEqual(flash?.outputPerMillion, 0.5)
        let glm53 = TestPricing.bundled.resolve(model: "GLM-5.3")
        XCTAssertNotNil(glm53, "GLM-5.3 should resolve")
        let canonical = TestPricing.bundled.canonicalName(for: "GLM-5.3-Flash")
        XCTAssertEqual(canonical, "glm-5.3-flash")
    }
}
