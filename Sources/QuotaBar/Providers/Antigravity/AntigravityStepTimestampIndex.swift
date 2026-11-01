import Foundation

/// Generation indices and conversation-step indices are different sequences. Match their explicit
/// UUID/bot identities once per changed database instead of attributing historical rows to today.
struct AntigravityStepTimestampIndex: Equatable, Sendable {
    enum LoadError: LocalizedError {
        case memoryLimitExceeded

        var errorDescription: String? {
            "Antigravity step timestamp index exceeded its memory budget"
        }
    }

    let timeZoneIdentifier = Calendar.current.timeZone.identifier
    private var timestamps: [AntigravityProtoDecoder.StepIdentity: Int64] = [:]
    private var ambiguous: Set<AntigravityProtoDecoder.StepIdentity> = []
    private(set) var estimatedMemoryBytes = 0
    private var lastIndex = -1
    private var tableFingerprint: String?
    private var supportsDigest: Bool?

    mutating func insert(_ metadata: [UInt8], maximumEstimatedMemoryBytes: Int) throws {
        guard let (identity, timestamp) = AntigravityProtoDecoder.stepIdentityAndTimestamp(from: metadata),
              !ambiguous.contains(identity) else { return }
        if let previous = timestamps[identity], previous != timestamp {
            // Retries can repeat the same identity at different instants. The accounting is daily:
            // retain the proven day when every candidate agrees, and reject cross-day ambiguity.
            if Calendar.current.isDate(Date(timeIntervalSince1970: TimeInterval(previous)),
                                       inSameDayAs: Date(timeIntervalSince1970: TimeInterval(timestamp))) {
                timestamps[identity] = min(previous, timestamp)
            } else {
                timestamps[identity] = nil
                ambiguous.insert(identity)
            }
        } else {
            if timestamps[identity] == nil {
                let (nextEstimate, overflow) = estimatedMemoryBytes.addingReportingOverflow(
                    Self.estimatedStorageBytes(for: identity)
                )
                guard !overflow, nextEstimate <= maximumEstimatedMemoryBytes else {
                    throw LoadError.memoryLimitExceeded
                }
                estimatedMemoryBytes = nextEstimate
            }
            timestamps[identity] = timestamp
        }
    }

    private static func estimatedStorageBytes(for identity: AntigravityProtoDecoder.StepIdentity) -> Int {
        // Include dictionary/set buckets, bridged string storage, and allocator overhead. This is a
        // conservative bound, not an exact heap measurement.
        256 + (identity.uuid?.utf8.count ?? 0) + (identity.botID?.utf8.count ?? 0)
    }

    func timestamp(for generation: [UInt8]) -> Int64? {
        AntigravityProtoDecoder.generationStepIdentity(from: generation).flatMap { timestamps[$0] }
    }

    func timestamp(for identity: AntigravityProtoDecoder.StepIdentity) -> Int64? { timestamps[identity] }

    /// New steps can append without invalidating existing generations. Edits/removals/ambiguous
    /// identities must replay the old generation rows so their dates cannot remain stale.
    func preserves(_ previous: Self) -> Bool {
        timeZoneIdentifier == previous.timeZoneIdentifier
            && previous.timestamps.allSatisfy { timestamps[$0.key] == $0.value }
            && previous.ambiguous.isSubset(of: ambiguous)
    }

    static func load(
        path: String,
        sqlite: SQLiteAccessing,
        previous: Self? = nil,
        maximumEstimatedMemoryBytes: Int = 64 * 1024 * 1024
    ) throws -> Self {
        struct Row: Decodable { let index: Int; let hex: String? }
        let summary: (prefix: String, table: String)?
        let supportsDigest: Bool?
        if previous?.supportsDigest == false {
            summary = nil
            supportsDigest = false
        } else {
            do {
                summary = try digest(path: path, through: previous?.lastIndex ?? -1, sqlite: sqlite)
                supportsDigest = summary == nil ? nil : true
            } catch {
                guard error.localizedDescription.lowercased().contains("no such function: sha3") else { throw error }
                summary = nil
                supportsDigest = false
            }
        }
        var index = Self()
        if let previous, previous.timeZoneIdentifier == index.timeZoneIdentifier,
           let summary, summary.prefix == previous.tableFingerprint {
            index = previous
        }
        index.supportsDigest = supportsDigest
        index.tableFingerprint = summary?.table
        var cursor = index.lastIndex
        while true {
            try Task.checkCancellation()
            let sql = """
            WITH step_timestamp_candidates AS (
                SELECT idx, metadata FROM steps
                WHERE idx > \(cursor) AND metadata IS NOT NULL ORDER BY idx LIMIT 128
            ), bounded AS (
                SELECT idx, metadata,
                    SUM(CASE WHEN length(metadata) <= \(AntigravityDbUsageScanner.maximumBlobBytes)
                        THEN length(metadata) ELSE 0 END) OVER (ORDER BY idx) AS source_bytes
                FROM step_timestamp_candidates
            )
            SELECT json_group_array(json_object('index', idx, 'hex',
                CASE WHEN length(metadata) <= \(AntigravityDbUsageScanner.maximumBlobBytes)
                    THEN hex(metadata) ELSE NULL END))
            FROM (SELECT idx, metadata FROM bounded
                WHERE source_bytes <= \(AntigravityDbUsageScanner.maximumBatchSourceBytes) ORDER BY idx)
            """
            guard let payload = try JSONLAccountingWorkPacer.shared.perform({
                try sqlite.queryValue(path: path, sql: sql)
            }) else { throw SQLiteError.queryFailed("Antigravity step timestamp query returned no result") }
            let rows = try JSONDecoder().decode([Row].self, from: Data(payload.utf8))
            if rows.isEmpty { return index }
            try JSONLAccountingWorkPacer.shared.perform {
                for row in rows {
                    guard row.index > cursor else {
                        throw SQLiteError.queryFailed("Antigravity step indices are not strictly increasing")
                    }
                    cursor = row.index
                    index.lastIndex = cursor
                    if let hex = row.hex, let bytes = AntigravityDbUsageScanner.bytes(fromHex: hex) {
                        try index.insert(bytes, maximumEstimatedMemoryBytes: maximumEstimatedMemoryBytes)
                    }
                }
            }
        }
    }

    /// Verify the entire old prefix inside SQLite, returning two fixed-size digests. A normal
    /// append then reads/decodes only new metadata; a rewrite or removal rebuilds the index.
    private static func digest(path: String, through lastIndex: Int, sqlite: SQLiteAccessing) throws
        -> (prefix: String, table: String)? {
        let sql = """
        WITH step_timestamp_digest AS MATERIALIZED (
            SELECT idx, printf('%d:%d:%s;', idx, length(metadata),
                CASE WHEN length(metadata) <= \(AntigravityDbUsageScanner.maximumBlobBytes)
                    THEN hex(sha3(metadata, 256)) ELSE 'oversized' END) AS signature
            FROM steps WHERE metadata IS NOT NULL
        )
        SELECT COALESCE(hex(sha3_agg(CASE WHEN idx <= \(lastIndex) THEN signature END ORDER BY idx)), '')
            || '|' || COALESCE(hex(sha3_agg(signature ORDER BY idx)), '')
        FROM step_timestamp_digest
        """
        try Task.checkCancellation()
        guard let value = try JSONLAccountingWorkPacer.shared.perform({
            try sqlite.queryValue(path: path, sql: sql)
        }) else { return nil }
        let fields = value.split(separator: "|", omittingEmptySubsequences: false)
        guard fields.count == 2 else { return nil }
        return (String(fields[0]), String(fields[1]))
    }
}
