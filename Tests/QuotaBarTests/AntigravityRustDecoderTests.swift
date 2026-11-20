import XCTest
@testable import QuotaBar

/// Parity corpus for the Rust Antigravity decoder bridge (`AntigravityRustDecoder`,
/// `Rust/quotabar-core/src/antigravity.rs`). Every fixture runs through both the Rust port
/// and the Swift reference decoder and the verdicts must agree field-for-field — the port is
/// only allowed to decline (NULL → `.fallback`) for inputs it cannot prove identical.
private func agVarint(_ value: UInt64) -> [UInt8] {
    var remaining = value
    var encoded: [UInt8] = []
    repeat {
        var byte = UInt8(remaining & 0x7f)
        remaining >>= 7
        if remaining != 0 { byte |= 0x80 }
        encoded.append(byte)
    } while remaining != 0
    return encoded
}

private func agVarintField(_ number: UInt32, _ value: UInt64) -> [UInt8] {
    agVarint(UInt64(number) << 3) + agVarint(value)
}

private func agBytesField(_ number: UInt32, _ bytes: [UInt8]) -> [UInt8] {
    agVarint(UInt64(number) << 3 | 2) + agVarint(UInt64(bytes.count)) + bytes
}

private func agFixed64Field(_ number: UInt32, _ value: UInt64) -> [UInt8] {
    var out = agVarint(UInt64(number) << 3 | 1)
    for shift in stride(from: 0, through: 56, by: 8) { out.append(UInt8(value >> shift & 0xff)) }
    return out
}

private func agFixed32Field(_ number: UInt32, _ value: UInt32) -> [UInt8] {
    var out = agVarint(UInt64(number) << 3 | 5)
    for shift in stride(from: 0, through: 24, by: 8) { out.append(UInt8(value >> shift & 0xff)) }
    return out
}

private func agGenerationBlob(
    model: String?,
    input: UInt64,
    output: UInt64,
    cacheRead: UInt64 = 0,
    systemPrompt: UInt64 = 0,
    timestamp: UInt64?,
    stepUUID: String? = "turn-1",
    botID: String? = "bot-1"
) -> [UInt8] {
    var usage = agVarintField(1, systemPrompt)
        + agVarintField(2, input)
        + agVarintField(3, output)
        + agVarintField(5, cacheRead)
    if let botID { usage += agBytesField(7, Array(botID.utf8)) }

    var event: [UInt8] = []
    if let model { event += agBytesField(19, Array(model.utf8)) }
    event += agBytesField(4, usage)
    if let timestamp {
        let wallClock = agVarintField(1, timestamp)
        event += agBytesField(9, agBytesField(4, wallClock))
    }
    var generation = agBytesField(1, event)
    if let stepUUID { generation += agBytesField(4, Array(stepUUID.utf8)) }
    return generation
}

private func agStepMetadata(
    timestamp: UInt64,
    stepUUID: String? = "turn-1",
    botID: String? = "bot-1"
) -> [UInt8] {
    var metadata = agBytesField(1, agVarintField(1, timestamp))
    if let botID { metadata += agBytesField(9, agBytesField(7, Array(botID.utf8))) }
    if let stepUUID { metadata += agBytesField(12, Array(stepUUID.utf8)) }
    return metadata
}

private func agHex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}

final class AntigravityRustDecoderTests: XCTestCase {

    // MARK: - Parity harness

    /// Assert the Rust verdict equals the Swift reference verdict on both the hex and the raw
    /// bytes entry points. `.decoded` must match field-for-field; `.fallback`/`.unreadableBlob`
    /// are failures here — fixtures in this corpus are ASCII by construction.
    private func assertParity(
        _ blob: [UInt8],
        stepMetadata: [UInt8]? = nil,
        matchedStepTimestamp: Int64? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let expected = AntigravityProtoDecoder.decodeGenerationEvent(
            from: blob, stepMetadata: stepMetadata, matchedStepTimestamp: matchedStepTimestamp
        )
        let hex = agHex(blob)
        let stepHex = stepMetadata.map(agHex)
        for outcome in [
            AntigravityRustDecoder.decodeGeneration(
                fromHex: hex, stepHex: stepHex, matchedStepTimestamp: matchedStepTimestamp),
            AntigravityRustDecoder.decodeGeneration(
                fromBytes: blob, stepHex: stepHex, matchedStepTimestamp: matchedStepTimestamp),
        ] {
            switch outcome {
            case .decoded(let result):
                XCTAssertEqual(result, expected, file: file, line: line)
            case .unreadableBlob:
                XCTFail("Rust reported unreadable hex for a valid fixture", file: file, line: line)
            case .fallback:
                XCTFail("Rust declined an ASCII fixture", file: file, line: line)
            }
        }
    }

    // MARK: - Happy path

    func testDecodesCompleteGenerationRecordFieldByField() throws {
        let blob = agGenerationBlob(
            model: "gemini-3.1-pro-low", input: 1_000, output: 200,
            cacheRead: 50, systemPrompt: 1_132, timestamp: 1_800_000_000
        )
        let outcome = AntigravityRustDecoder.decodeGeneration(
            fromHex: agHex(blob), stepHex: nil, matchedStepTimestamp: nil)
        guard case .decoded(.event(let event)) = outcome else {
            return XCTFail("expected a decoded event, got \(outcome)")
        }
        XCTAssertEqual(event.model, "gemini-3.1-pro-low")
        XCTAssertEqual(event.inputTokens, 2_132)
        XCTAssertEqual(event.outputTokens, 200)
        XCTAssertEqual(event.cacheReadTokens, 50)
        XCTAssertEqual(event.timestampSeconds, 1_800_000_000)
        assertParity(blob)
    }

    func testEmptyHexDecodesLikeTheSwiftEmptyBlob() {
        // bytes(fromHex: "") is [] — the wrapper field is absent, so the row is ignored.
        let outcome = AntigravityRustDecoder.decodeGeneration(
            fromHex: "", stepHex: nil, matchedStepTimestamp: nil)
        guard case .decoded(let result) = outcome else {
            return XCTFail("expected decoded, got \(outcome)")
        }
        XCTAssertEqual(result, .ignored)
    }

    // MARK: - Timestamp correlation

    func testTimestampSourcesMatchSwiftPrecedence() {
        let embedded = agGenerationBlob(
            model: "m", input: 10, output: 5, timestamp: 1_800_000_000)
        // Embedded beats the index-matched timestamp.
        assertParity(embedded, matchedStepTimestamp: 1_700_000_000)

        let undated = agGenerationBlob(model: "m", input: 10, output: 5, timestamp: nil)
        // Matched timestamp beats same-index step metadata.
        let step = agStepMetadata(timestamp: 1_600_000_000)
        assertParity(undated, stepMetadata: step, matchedStepTimestamp: 1_700_000_000)
        // Step metadata correlates when identifiers agree on both sides.
        assertParity(undated, stepMetadata: step)
        // Mismatched identifiers never borrow a timestamp.
        assertParity(undated, stepMetadata: agStepMetadata(timestamp: 1_600_000_000, stepUUID: "other"))
        assertParity(undated, stepMetadata: agStepMetadata(timestamp: 1_600_000_000, botID: "other"))
        assertParity(undated, stepMetadata: agStepMetadata(timestamp: 1_600_000_000, stepUUID: nil, botID: nil))
        // Both sides omitting identifiers keeps the legacy correlation.
        let legacy = agGenerationBlob(model: "m", input: 10, output: 5, timestamp: nil, stepUUID: nil, botID: nil)
        assertParity(legacy, stepMetadata: agStepMetadata(timestamp: 1_600_000_000, stepUUID: nil, botID: nil))
    }

    // MARK: - Reject cases

    func testRejectCasesCarryTheSameVerdictAndTimestamp() {
        assertParity(agGenerationBlob(model: "m", input: 1, output: 0, timestamp: nil)) // undated
        assertParity(agGenerationBlob(model: "m", input: 0, output: 0, timestamp: 1_800_000_000)) // ignored
        assertParity(agGenerationBlob( // invalidTokenCount with the embedded ts payload
            model: "m", input: UInt64.max, output: 0, timestamp: 1_800_000_000))
        assertParity(agGenerationBlob( // billable input above the ceiling
            model: "m", input: UInt64(AntigravityProtoDecoder.maximumTokenCount), output: 0,
            systemPrompt: 1, timestamp: 1_800_000_000))
        assertParity([0xff, 0xff, 0xff]) // garbage → malformed, no timestamp
        assertParity(agVarintField(3, 9)) // no wrapper → ignored
        let inner = agBytesField(4, agVarintField(2, 5))
        assertParity(agBytesField(1, inner) + agBytesField(1, inner)) // two wrappers → malformed
        // Malformed deep in the tree still carries the resolved timestamp.
        var event = agVarintField(9, 7) // field 9 as a varint — not a message
        event += agBytesField(4, agVarintField(2, 5))
        event += agBytesField(19, Array("m".utf8))
        assertParity(agBytesField(1, event), matchedStepTimestamp: 1_700_000_000)
    }

    // MARK: - Wire types, repeated and packed fields

    func testEveryWireTypeAndNestedMessageWalksLikeSwift() {
        var usage = agVarintField(1, 100) + agVarintField(2, 50) + agVarintField(3, 20)
            + agVarintField(5, 5) + agBytesField(7, Array("bot-1".utf8))
        usage += agFixed64Field(8, 9) + agFixed32Field(9, 1) // unknown fixed fields skipped
        usage += agBytesField(10, agVarintField(1, 1) + agBytesField(2, [1, 2, 3])) // nested unknown

        var event = agBytesField(19, Array("gemini".utf8)) + agBytesField(4, usage)
        event += agFixed32Field(7, 3) // unknown fixed in the wrapper message
        event += agBytesField(9, agBytesField(4, agVarintField(1, 1_800_000_000)))
        assertParity(agBytesField(1, event) + agBytesField(4, Array("turn-1".utf8)))
    }

    func testRepeatedFieldsFollowTheSingularRules() {
        // Duplicate usage field → malformed usage (never silently picks one).
        let usage = agVarintField(2, 5) + agVarintField(3, 1)
        var event = agBytesField(19, Array("m".utf8)) + agBytesField(4, usage) + agBytesField(4, usage)
        event += agBytesField(9, agBytesField(4, agVarintField(1, 1_800_000_000)))
        assertParity(agBytesField(1, event))
        // Duplicate model field → ambiguous → the unpriced placeholder, tokens still counted.
        var twoModels = agBytesField(19, Array("a".utf8)) + agBytesField(19, Array("b".utf8))
        twoModels += agBytesField(4, usage)
        twoModels += agBytesField(9, agBytesField(4, agVarintField(1, 1_800_000_000)))
        let blob = agBytesField(1, twoModels)
        assertParity(blob)
        if case .decoded(.event(let decoded)) = AntigravityRustDecoder.decodeGeneration(
            fromHex: agHex(blob), stepHex: nil, matchedStepTimestamp: nil) {
            XCTAssertEqual(decoded.model, AntigravityProtoDecoder.GenerationEvent.unknownModel)
        } else {
            XCTFail("expected the ambiguous-model event")
        }
        // Duplicate timestamp field → malformed.
        var twoTimestamps = agBytesField(4, usage)
        twoTimestamps += agBytesField(9, agBytesField(4, agVarintField(1, 1_800_000_000)))
        twoTimestamps += agBytesField(9, agBytesField(4, agVarintField(1, 1_800_000_001)))
        assertParity(agBytesField(1, twoTimestamps))
        // Duplicate inner timestamp message → no embedded timestamp → falls to the matched one.
        var nested = agBytesField(4, usage)
        let inner9 = agBytesField(4, agVarintField(1, 1_800_000_000))
            + agBytesField(4, agVarintField(1, 1_800_000_001))
        nested += agBytesField(9, inner9)
        assertParity(agBytesField(1, nested), matchedStepTimestamp: 1_700_000_000)
    }

    func testPackedAndWrongWireTypeCountersAreMalformed() {
        // A counter field carrying packed varints (wire type 2) is malformed, not zero.
        let packedUsage = agBytesField(2, agVarint(1) + agVarint(2)) + agVarintField(3, 1)
        assertParity(agBytesField(1, agBytesField(4, packedUsage)
            + agBytesField(9, agBytesField(4, agVarintField(1, 1_800_000_000)))))
        // Fixed-width counters are malformed too.
        let fixedUsage = agFixed64Field(3, 9) + agVarintField(2, 1)
        assertParity(agBytesField(1, agBytesField(4, fixedUsage)
            + agBytesField(9, agBytesField(4, agVarintField(1, 1_800_000_000)))))
        // Packed data on an *unknown* field is just bytes — skipped like any bytes field.
        var usage = agVarintField(2, 5) + agVarintField(3, 1)
        usage += agBytesField(9, agVarint(1) + agVarint(2) + agVarint(3))
        var event = agBytesField(4, usage)
        event += agBytesField(9, agBytesField(4, agVarintField(1, 1_800_000_000)))
        assertParity(agBytesField(1, event))
        // Group wire types and field number 0 reject the whole message.
        assertParity(agBytesField(1, event) + agVarint(UInt64(3) << 3 | 3))
        assertParity(agBytesField(1, event) + agVarint(0))
        assertParity(agBytesField(1, event) + agVarint(UInt64(4) << 3 | 6))
    }

    // MARK: - Varint and truncation edges

    func testVarintEdgesAndTruncatedBuffers() {
        // Ten-byte maximum varint (top payload bit ≤ 1) decodes; the overflow forms do not.
        let maxVarintUsage = agVarint(UInt64(2) << 3) + [UInt8](repeating: 0xff, count: 9) + [0x01]
        assertParity(agBytesField(1, agBytesField(4, maxVarintUsage)
            + agBytesField(9, agBytesField(4, agVarintField(1, 1_800_000_000)))))
        let tooBigUsage = agVarint(UInt64(2) << 3) + [UInt8](repeating: 0xff, count: 9) + [0x02]
        assertParity(agBytesField(1, agBytesField(4, tooBigUsage)
            + agBytesField(9, agBytesField(4, agVarintField(1, 1_800_000_000)))))
        let neverEndingUsage = agVarint(UInt64(2) << 3) + [UInt8](repeating: 0x80, count: 11)
        assertParity(agBytesField(1, agBytesField(4, neverEndingUsage)
            + agBytesField(9, agBytesField(4, agVarintField(1, 1_800_000_000)))))
        // A length that overruns the buffer is malformed, never a crash.
        assertParity(agBytesField(1, agVarint(UInt64(4) << 3 | 2) + agVarint(UInt64.max) + [0x01]))

        // Every strict prefix of a valid blob must agree with the Swift decoder.
        let blob = agGenerationBlob(
            model: "gemini-3.6-flash", input: 1_000, output: 200,
            cacheRead: 50, systemPrompt: 100, timestamp: 1_800_000_000)
        for end in 0..<blob.count {
            assertParity(Array(blob[..<end]))
        }
    }

    // MARK: - Hex surface

    func testHexDecodingMirrorsBytesFromHex() {
        let blob = agGenerationBlob(model: "m", input: 5, output: 1, timestamp: 1_800_000_000)
        // Upper- and lowercase both decode.
        let upper = agHex(blob).uppercased()
        if case .decoded(let result) = AntigravityRustDecoder.decodeGeneration(
            fromHex: upper, stepHex: nil, matchedStepTimestamp: nil) {
            XCTAssertEqual(result, .event(AntigravityProtoDecoder.generationEvent(from: blob)!))
        } else {
            XCTFail("uppercase hex declined")
        }
        // Odd length and invalid characters are the unreadable status — the scanner's
        // oversized/undecodable path, not a decode attempt.
        for bad in ["0", "zz", "0x", "ab0"] {
            guard case .unreadableBlob = AntigravityRustDecoder.decodeGeneration(
                fromHex: bad, stepHex: nil, matchedStepTimestamp: nil) else {
                return XCTFail("\(bad) did not report unreadable")
            }
        }
        // UInt8(_, radix: 16) sign quirks are mirrored, not declined.
        let signed = "0a" + "+f" + "-0"
        if case .decoded = AntigravityRustDecoder.decodeGeneration(
            fromHex: signed, stepHex: nil, matchedStepTimestamp: nil) {} else {
            XCTFail("sign-prefixed hex window did not mirror Swift")
        }
        // An unreadable step row is absent metadata — the generation still decodes.
        if case .decoded(let result) = AntigravityRustDecoder.decodeGeneration(
            fromHex: agHex(blob), stepHex: "z", matchedStepTimestamp: nil) {
            XCTAssertEqual(result, .event(AntigravityProtoDecoder.generationEvent(from: blob)!))
        } else {
            XCTFail("bad step hex did not degrade to absent metadata")
        }
        // Non-ASCII input is the fallback signal — Swift windows by Character.
        for nonASCII in ["éé", "ａ１"] {
            guard case .fallback = AntigravityRustDecoder.decodeGeneration(
                fromHex: nonASCII, stepHex: nil, matchedStepTimestamp: nil) else {
                return XCTFail("\(nonASCII) did not decline")
            }
            guard case .fallback = AntigravityRustDecoder.decodeGeneration(
                fromHex: agHex(blob), stepHex: nonASCII, matchedStepTimestamp: nil) else {
                return XCTFail("non-ASCII step hex did not decline")
            }
        }
    }

    // MARK: - Oversize inputs

    func testOversizeBlobStillDecodesIdentically() {
        // A row bigger than the SQL hex projection limit still decodes on the projected path.
        var event = agBytesField(19, Array("m".utf8))
        event += agBytesField(4, agVarintField(2, 5) + agVarintField(3, 1))
        event += agBytesField(9, agBytesField(4, agVarintField(1, 1_800_000_000)))
        event += agBytesField(30, [UInt8](repeating: 0x55, count: 1_100_000)) // > maximumBlobBytes
        assertParity(agBytesField(1, event))
    }

    // MARK: - Identities

    func testGenerationStepIdentityParity() {
        func assertIdentityParity(_ blob: [UInt8], file: StaticString = #filePath, line: UInt = #line) {
            let expected = AntigravityProtoDecoder.generationStepIdentity(from: blob)
            for outcome in [
                AntigravityRustDecoder.generationStepIdentity(fromHex: agHex(blob)),
                AntigravityRustDecoder.generationStepIdentity(fromBytes: blob),
            ] {
                switch (outcome, expected) {
                case (.present(let identity), .some(let wanted)):
                    XCTAssertEqual(identity.uuid, wanted.uuid, file: file, line: line)
                    XCTAssertEqual(identity.botID, wanted.botID, file: file, line: line)
                case (.absent, .none):
                    break
                default:
                    XCTFail("identity \(outcome) != \(String(describing: expected))", file: file, line: line)
                }
            }
        }
        assertIdentityParity(agGenerationBlob(model: "m", input: 1, output: 1, timestamp: nil))
        assertIdentityParity(agGenerationBlob(model: "m", input: 1, output: 1, timestamp: nil, botID: nil))
        assertIdentityParity(agGenerationBlob(model: "m", input: 1, output: 1, timestamp: nil, stepUUID: nil))
        assertIdentityParity(agGenerationBlob(model: "m", input: 1, output: 1, timestamp: nil, stepUUID: nil, botID: nil))
        // Whitespace-only identifier → invalid → whole identity absent.
        assertIdentityParity(agGenerationBlob(model: "m", input: 1, output: 1, timestamp: nil, stepUUID: "  "))
        // Truncated wrapper → absent rather than a partial identity.
        assertIdentityParity([0x0a, 0x05, 0x22])
        // A non-ASCII identifier declines — Swift String == is canonical equivalence and the
        // index hashes on these strings, so the port cannot prove the same bucket.
        let nonASCII = agGenerationBlob(
            model: "m", input: 1, output: 1, timestamp: nil, stepUUID: "café")
        guard case .fallback = AntigravityRustDecoder.generationStepIdentity(fromHex: agHex(nonASCII)) else {
            return XCTFail("non-ASCII identity did not decline")
        }
    }

    func testStepMetadataIdentityAndTimestampParity() {
        func assertStepParity(_ metadata: [UInt8], file: StaticString = #filePath, line: UInt = #line) {
            let expected = AntigravityProtoDecoder.stepIdentityAndTimestamp(from: metadata)
            switch (AntigravityRustDecoder.stepMetadataIdentityAndTimestamp(fromHex: agHex(metadata)), expected) {
            case (.present(let identity, let timestamp), .some(let wanted)):
                XCTAssertEqual(identity.uuid, wanted.0.uuid, file: file, line: line)
                XCTAssertEqual(identity.botID, wanted.0.botID, file: file, line: line)
                XCTAssertEqual(timestamp, wanted.1, file: file, line: line)
            case (.absent, .none):
                break
            default:
                XCTFail("step metadata outcome != \(String(describing: expected))", file: file, line: line)
            }
        }
        assertStepParity(agStepMetadata(timestamp: 1_800_000_000))
        assertStepParity(agStepMetadata(timestamp: 1_800_000_000, botID: nil))
        // Identity without a timestamp is absent — the index only stores timestamped rows.
        assertStepParity(agBytesField(12, Array("turn-1".utf8)))
        // No identifiers → absent even with a timestamp.
        assertStepParity(agStepMetadata(timestamp: 1_800_000_000, stepUUID: nil, botID: nil))
        // Unreadable hex is definitively absent — the Swift loader skips it silently.
        guard case .absent = AntigravityRustDecoder.stepMetadataIdentityAndTimestamp(fromHex: "z") else {
            return XCTFail("unreadable step hex was not absent")
        }
    }

    // MARK: - Benchmark (opt-in)

    func testBenchmarkRustVsSwiftDecode() {
        guard ProcessInfo.processInfo.environment["QUOTABAR_ANTIGRAVITY_BENCH"] == "1" else { return }
        // ~1 KB generation row plus its same-index step row — the shape a full scan decodes.
        let blob = agGenerationBlob(
            model: "gemini-3.6-flash", input: 4_200, output: 900,
            cacheRead: 120, systemPrompt: 2_400, timestamp: nil)
            + agBytesField(30, [UInt8](repeating: 0x55, count: 700))
        let step = agStepMetadata(timestamp: 1_800_000_000)
        let hex = agHex(blob)
        let stepHex = agHex(step)
        let iterations = 2_000

        func time(_ body: () -> Void) -> UInt64 {
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            return DispatchTime.now().uptimeNanoseconds - start
        }
        // Warm both paths, then measure.
        _ = AntigravityRustDecoder.decodeGeneration(fromHex: hex, stepHex: stepHex, matchedStepTimestamp: nil)
        _ = AntigravityProtoDecoder.decodeGenerationEvent(
            from: blob, stepMetadata: AntigravityDbUsageScanner.bytes(fromHex: stepHex))
        let rustNanos = time {
            for _ in 0..<iterations {
                _ = AntigravityRustDecoder.decodeGeneration(
                    fromHex: hex, stepHex: stepHex, matchedStepTimestamp: nil)
            }
        }
        let swiftNanos = time {
            for _ in 0..<iterations {
                let metadata = AntigravityDbUsageScanner.bytes(fromHex: stepHex)
                if let bytes = AntigravityDbUsageScanner.bytes(fromHex: hex) {
                    _ = AntigravityProtoDecoder.decodeGenerationEvent(from: bytes, stepMetadata: metadata)
                }
            }
        }
        let speedup = Double(swiftNanos) / Double(max(rustNanos, 1))
        print(String(
            format: "antigravity bench: %d rows — rust %.2f ms, swift %.2f ms (%.2fx)",
            iterations, Double(rustNanos) / 1e6, Double(swiftNanos) / 1e6, speedup))
        XCTAssertGreaterThan(rustNanos, 0)
    }
}
