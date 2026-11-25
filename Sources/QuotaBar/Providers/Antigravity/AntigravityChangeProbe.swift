import Foundation

/// One SQLite CLI round trip that verifies a changed Antigravity conversation database against its
/// persisted derivation state. The merged statement packs the steps-schema probe, the step table's
/// prefix/table digests and maximum index, and the generation table's prefix/table digests and
/// maximum index into a single JSON object. That removes three subprocess launches (and three
/// shared table scans) from every changed database — the dominant cold-worker cost once the step
/// timestamp index itself is persisted.
///
/// The probe only runs for databases whose cached record already proved `hasStepMetadata`: the
/// statement scans `steps`, so a store without the table (or any other merged-statement failure)
/// falls back to the scanner's sequential probe + digest queries, preserving identical semantics.
enum AntigravityChangeProbe {
    /// Mirrors `stepMetadataProbeSQL` + `AntigravityStepTimestampIndex.digest` + `contentFingerprint`
    /// — every field is produced by the same expressions as the sequential queries so the digests
    /// compare cleanly against fingerprints recorded by either path.
    struct Result: Equatable, Sendable {
        var hasStepMetadata: Bool
        var stepPrefixFingerprint: String
        var stepTableFingerprint: String
        var stepMaximumIndex: Int
        var generationPrefixFingerprint: String
        var generationTableFingerprint: String
        var generationMaximumIndex: Int
    }

    /// `throughStepIndex` is the verified index's last step cursor and `throughGenerationIndex` the
    /// cached generation cursor; both bound the prefix digests, matching the sequential queries.
    static func sql(throughGenerationIndex: Int, throughStepIndex: Int) -> String {
        """
        /* antigravity_change_probe */
        WITH step_digest AS MATERIALIZED (
            SELECT idx AS step_idx, printf('%d:%d:%s;', idx, length(metadata),
                CASE WHEN length(metadata) <= \(AntigravityDbUsageScanner.maximumBlobBytes)
                    THEN hex(sha3(metadata, 256)) ELSE 'oversized' END) AS signature
            FROM steps WHERE metadata IS NOT NULL
        ), generation_digest AS MATERIALIZED (
            SELECT g.idx AS gen_idx, length(g.data) AS byteCount,
                CASE WHEN length(g.data) <= \(AntigravityDbUsageScanner.maximumBlobBytes)
                    THEN hex(sha3(g.data, 256)) ELSE 'oversized' END AS rowDigest,
                \(generationStepDigest) AS stepDigest
            FROM gen_metadata g
            WHERE g.data IS NOT NULL
        )
        SELECT json_object(
            'probe', EXISTS (\(AntigravityDbUsageScanner.stepMetadataProbeSQL)),
            'step_prefix', COALESCE((SELECT hex(sha3_agg(
                CASE WHEN step_idx <= \(throughStepIndex) THEN signature END ORDER BY step_idx
            )) FROM step_digest), ''),
            'step_table', COALESCE((SELECT hex(sha3_agg(signature ORDER BY step_idx)) FROM step_digest), ''),
            'step_max', (SELECT COALESCE(MAX(step_idx), -1) FROM step_digest),
            'gen_max', (SELECT COALESCE(MAX(gen_idx), -1) FROM generation_digest),
            'gen_prefix', COALESCE((SELECT hex(sha3_agg(
                CASE WHEN gen_idx <= \(throughGenerationIndex)
                    THEN printf('%d:%d:%s:%s;', gen_idx, byteCount, rowDigest, stepDigest)
                END ORDER BY gen_idx
            )) FROM generation_digest), ''),
            'gen_table', COALESCE((SELECT hex(sha3_agg(
                printf('%d:%d:%s:%s;', gen_idx, byteCount, rowDigest, stepDigest) ORDER BY gen_idx
            )) FROM generation_digest), '')
        )
        """
    }

    /// The generation row digest's correlated step signature — identical text to the sequential
    /// `contentFingerprintSQL` stepDigest column so fingerprints stay interchangeable.
    private static let generationStepDigest =
        "COALESCE((SELECT CASE WHEN metadata IS NULL THEN 'missing' WHEN length(metadata) <= \(AntigravityDbUsageScanner.maximumBlobBytes) THEN hex(sha3(metadata, 256)) ELSE 'oversized' END FROM steps WHERE idx = g.idx), 'missing')"

    /// nil means the statement ran but produced no row; decode failures are thrown so the caller can
    /// distinguish a runnable-but-unexpected response from the query itself failing.
    static func query(
        path: String,
        sqlite: SQLiteAccessing,
        throughGenerationIndex: Int,
        throughStepIndex: Int
    ) throws -> Result? {
        struct Response: Decodable {
            var probe: Int
            var stepPrefix: String
            var stepTable: String
            var stepMax: Int
            var generationMax: Int
            var generationPrefix: String
            var generationTable: String

            enum CodingKeys: String, CodingKey {
                case probe
                case stepPrefix = "step_prefix"
                case stepTable = "step_table"
                case stepMax = "step_max"
                case generationMax = "gen_max"
                case generationPrefix = "gen_prefix"
                case generationTable = "gen_table"
            }
        }
        guard let payload = try JSONLAccountingWorkPacer.shared.perform({
            try sqlite.queryValue(
                path: path,
                sql: sql(throughGenerationIndex: throughGenerationIndex, throughStepIndex: throughStepIndex)
            )
        }) else { return nil }
        let response = try JSONLAccountingWorkPacer.shared.perform {
            try autoreleasepool { try JSONDecoder().decode(Response.self, from: Data(payload.utf8)) }
        }
        return Result(
            hasStepMetadata: response.probe == 1,
            stepPrefixFingerprint: response.stepPrefix,
            stepTableFingerprint: response.stepTable,
            stepMaximumIndex: response.stepMax,
            generationPrefixFingerprint: response.generationPrefix,
            generationTableFingerprint: response.generationTable,
            generationMaximumIndex: response.generationMax
        )
    }
}
