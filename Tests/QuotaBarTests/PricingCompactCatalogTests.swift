import XCTest
@testable import QuotaBar

/// End-to-end coverage of the Rust compact-catalog fallback through the Swift bridge: the Rust
/// path is selected in production only when Foundation's decoder throws, but it must never crash
/// and must produce a the same shape of `PricingCatalog` when it does run.
final class PricingCompactCatalogTests: XCTestCase {
    private func resource(_ name: String) -> Data {
        guard let url = Bundle.openUsageResources.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            fatalError("bundled resource \(name).json missing")
        }
        return data
    }

    private func approxEqual(_ a: Double, _ b: Double) -> Bool {
        if a == b { return true }
        let scale = max(a.magnitude, b.magnitude, 1)
        return abs(a - b) <= 4 * .ulpOfOne * scale
    }

    func testBundledSnapshotsRoundTripThroughRustParser() throws {
        for name in ["pricing_litellm_snapshot", "pricing_models_dev_snapshot"] {
            let data = resource(name)
            let swift = try PricingCatalogCodecs.catalogFromCompact(data)
            let rust = try XCTUnwrap(CompactCatalogRustParser.parse(data), "Rust fallback failed on bundled \(name)")
            XCTAssertEqual(Set(swift.entries.keys), Set(rust.entries.keys), "key sets diverge for \(name)")
            for (key, reference) in swift.entries {
                let entry = try XCTUnwrap(rust.entries[key], "Rust parser dropped \(key) in \(name)")
                XCTAssertTrue(approxEqual(reference.inputPerMillion, entry.inputPerMillion), "\(key) input")
                XCTAssertTrue(approxEqual(reference.outputPerMillion, entry.outputPerMillion), "\(key) output")
                XCTAssertTrue(approxEqual(reference.cacheWritePerMillion, entry.cacheWritePerMillion), "\(key) cache write")
                XCTAssertTrue(approxEqual(reference.cacheReadPerMillion, entry.cacheReadPerMillion), "\(key) cache read")
                XCTAssertEqual(reference.cacheReadIsExplicit, entry.cacheReadIsExplicit, "\(key) cache-read provenance")
                XCTAssertTrue(approxEqual(reference.fastMultiplier, entry.fastMultiplier), "\(key) fast multiplier")
                XCTAssertEqual(reference.promptRateTiers.count, entry.promptRateTiers.count, "\(key) tier count")
                for (index, pair) in zip(reference.promptRateTiers, entry.promptRateTiers).enumerated() {
                    XCTAssertEqual(pair.0.thresholdPromptTokens, pair.1.thresholdPromptTokens, "\(key) tier \(index) threshold")
                    XCTAssertEqual(pair.0.includesThreshold, pair.1.includesThreshold, "\(key) tier \(index) includesThreshold")
                    XCTAssertEqual(pair.0.inputPerMillion == nil, pair.1.inputPerMillion == nil)
                    if let a = pair.0.inputPerMillion, let b = pair.1.inputPerMillion {
                        XCTAssertTrue(approxEqual(a, b), "\(key) tier \(index) input")
                    }
                }
            }
            XCTAssertEqual(swift.retrievedAt, rust.retrievedAt, "retrievedAt diverges for \(name)")
            XCTAssertEqual(swift.retiredKeys, rust.retiredKeys, "retired keys diverge for \(name)")
            XCTAssertEqual(swift.retiredKeysAreAuthoritative, rust.retiredKeysAreAuthoritative, "retired authority diverges for \(name)")
        }
    }

    func testHugeTierThresholdDoesNotTrapTheDecoder() throws {
        // threshold_prompt_tokens past Int64.max: Foundation's decoder throws, and the Rust
        // fallback must reject the catalog cleanly instead of trapping on Int(_:).
        let json = Data(#"""
        {"models":{"cheap":{"i":0.1,"o":0.2,"cw":0.1,"cr":0.01,
        "tiers":[{"threshold_prompt_tokens":17000000000000000000,"input_per_million":1}]}}}
        """#.utf8)
        XCTAssertThrowsError(try PricingCatalogCodecs.catalogFromCompact(json))
    }

    func testWrongTypedTiersAreRejected() throws {
        let json = Data(#"""
        {"models":{"cheap":{"i":0.1,"o":0.2,"cw":0.1,"cr":0.01,"tiers":"not-an-array"}}}
        """#.utf8)
        XCTAssertThrowsError(try PricingCatalogCodecs.catalogFromCompact(json))
    }

    func testWrongTypedRetiredKeyIsRejected() throws {
        let json = Data(#"""
        {"models":{},"retired":"not-an-array"}
        """#.utf8)
        XCTAssertThrowsError(try PricingCatalogCodecs.catalogFromCompact(json))
    }

    func testWrongTypedOptionalFieldsAreRejected() throws {
        let json = Data(#"""
        {"models":{"cheap":{"i":0.1,"o":0.2,"cw":0.1,"cr":0.01,"ia":"not-a-number"}}}
        """#.utf8)
        XCTAssertThrowsError(try PricingCatalogCodecs.catalogFromCompact(json))
    }

    func testTierOnlyCacheReadRemainsCompatibleWithLegacyCompactReaders() throws {
        let rates = ModelRates(
            inputPerMillion: 1, outputPerMillion: 2, cacheWritePerMillion: 1, cacheReadPerMillion: 1,
            promptRateTiers: [PromptRateTier(thresholdPromptTokens: 1_000, cacheReadPerMillion: 0.25)],
            cacheReadIsExplicit: false
        )
        let compact = try PricingCatalogCodecs.compactData(from: PricingCatalog(entries: ["model": rates]))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: compact) as? [String: Any])
        let models = try XCTUnwrap(json["models"] as? [String: [String: Any]])
        let model = try XCTUnwrap(models["model"])
        XCTAssertNil(model["cre"], "legacy readers must still see an explicit tier")
        XCTAssertEqual(model["crb"] as? Bool, false)
        let swiftRates = try XCTUnwrap(PricingCatalogCodecs.catalogFromCompact(compact).entries["model"])
        let rustRates = try XCTUnwrap(CompactCatalogRustParser.parse(compact)?.entries["model"])
        XCTAssertEqual(swiftRates, rates)
        XCTAssertEqual(rustRates, rates)
    }

    func testEmptyRetiredArrayIsPresentAsAuthoritative() throws {
        let json = Data(#"""
        {"models":{"cheap":{"i":0.1,"o":0.2,"cw":0.1,"cr":0.01}},"retired":[]}
        """#.utf8)
        // Foundation decodes this fine; the Swift-first path carries the authoritative flag.
        let catalog = try PricingCatalogCodecs.catalogFromCompact(json)
        XCTAssertTrue(catalog.retiredKeys.isEmpty)
        XCTAssertTrue(catalog.retiredKeysAreAuthoritative)
    }
}
