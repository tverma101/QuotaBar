import Foundation
import Darwin
import os

/// The message tables an OpenCode database holds.
///
/// OpenCode 2 moved the session store: v1 kept one row per turn in `message` (the role lives inside
/// the JSON `data` blob), v2 keeps them in `session_message` (the role lives in the `type` column
/// and the model is nested under `$.model`). The v1→v2 migration copies every old session into
/// `session_v2` under the same id and rewrites its turns into `session_message`, so a store that is
/// mid-migration holds BOTH tables: already-migrated messages appear twice under the same message
/// id, and not-yet-migrated ones only in `message`. Reading one table alone loses usage; reading
/// both without deduplicating counts the migrated messages twice.
enum OpenCodeDatabaseSchema: Equatable, Sendable {
    /// Only the v1 `message` table.
    case legacy
    /// Only the v2 `session_message` table.
    case v2
    /// Both tables are present — the v1→v2 migration is in flight.
    case mixed
    /// Neither table was found: the probe could not answer, or the file is not an OpenCode store.
    case unknown

    /// True when the v2 `session_message` table holds rows worth reading.
    var readsV2: Bool { self == .v2 || self == .mixed }
    /// True when the v1 `message` table holds rows worth reading.
    var readsLegacy: Bool { self == .legacy || self == .mixed }

    /// The layout the queries actually run against.
    ///
    /// An unanswered probe falls back to the v1 layout — the one QuotaBar read before OpenCode 2 —
    /// so a probe that cannot answer still produces the query that worked historically. If that
    /// layout is missing too, the query itself fails loudly (the database is not readable), which is
    /// the same failure the scanner has always surfaced for an unreadable OpenCode store.
    var effective: OpenCodeDatabaseSchema { self == .unknown ? .legacy : self }
}

/// Reads one database's message-table layout.
///
/// The probe is a single `sqlite_master` lookup, so it costs one cheap row read per database
/// revision instead of a second full pass over the message tables.
enum OpenCodeDatabaseSchemaProbe {
    /// Names the message tables this file holds. `group_concat` folds them into a single cell, so
    /// the probe returns one row no matter how many tables match.
    static let detectionSQL = """
        SELECT group_concat(name) FROM sqlite_master
        WHERE type='table' AND name IN ('message','session_message');
        """

    /// Classify a probe answer.
    static func schema(fromProbeOutput output: String?) -> OpenCodeDatabaseSchema {
        guard let output else { return .unknown }
        let names = Set(
            output
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        )
        switch (names.contains("message"), names.contains("session_message")) {
        case (true, true): return .mixed
        case (true, false): return .legacy
        case (false, true): return .v2
        case (false, false): return .unknown
        }
    }

    /// Detect the layout of one database, memoized per database revision.
    ///
    /// The layout only changes when the file changes (the migration adds the v2 tables), so the
    /// answer is cached against the file's size/mtime — including the `-wal` companion, because in
    /// WAL mode a commit, and any schema change, lands there first. An inconclusive probe is not
    /// cached: it must not pin a database to a layout that a later read could contradict.
    static func detect(sqlite: SQLiteAccessing, path: String) throws -> OpenCodeDatabaseSchema {
        let stamp = revisionStamp(path: path)
        if let stamp, let cached = memo.withLock({ $0[path] }), cached.stamp == stamp {
            return cached.schema
        }
        let output = try sqlite.queryValue(path: path, sql: detectionSQL)
        let schema = schema(fromProbeOutput: output)
        guard schema != .unknown, let stamp else { return schema }
        memo.withLock { $0[path] = (stamp: stamp, schema: schema) }
        return schema
    }

    /// Forget every memoized layout (tests).
    static func resetMemoForTesting() {
        memo.withLock { $0.removeAll() }
    }

    /// The database revision the memo keys on: the main file's size/mtime plus its `-wal`
    /// companion's. A write in WAL mode moves the companion, so the layout is re-probed as soon as
    /// the database changes.
    static func revisionStamp(path: String) -> String? {
        func stamp(_ path: String, missingAllowed: Bool) -> String? {
            var value = stat()
            guard Darwin.lstat(path, &value) == 0 else {
                return missingAllowed && errno == ENOENT ? "missing" : nil
            }
            return "\(value.st_dev):\(value.st_ino):\(value.st_size):"
                + "\(value.st_mtimespec.tv_sec):\(value.st_mtimespec.tv_nsec):"
                + "\(value.st_ctimespec.tv_sec):\(value.st_ctimespec.tv_nsec)"
        }
        guard let main = stamp(path, missingAllowed: false), let wal = stamp(path + "-wal", missingAllowed: true)
        else { return nil }
        return "\(main)|\(wal)"
    }

    /// One entry per database path: the revision it was probed at and the layout it reported.
    private static let memo = OSAllocatedUnfairLock<[String: (stamp: String, schema: OpenCodeDatabaseSchema)]>(
        initialState: [:]
    )
}

/// The queries that read a database's hosted assistant usage, one variant per layout.
///
/// Every variant returns the same payload shape, so the scanner parses one format regardless of
/// which OpenCode version wrote the database: a JSON array of
/// `[time_created, cost, tokens, model, provider]` entries.
enum OpenCodeDatabaseSQL {
    /// The hosted assistant rows inside the scan window.
    static func dataSQL(cutoffMs: Int, schema: OpenCodeDatabaseSchema) -> String {
        let source = sourceSQL(
            schema: schema.effective,
            cutoffMs: cutoffMs,
            providers: OpenCodeUsageScanner.hostedProviderIDs
        )
        return """
        WITH source AS (
        \(source)
        )
        SELECT json_group_array(json_array(
                 time_created,
                 CASE
                     WHEN tokens_absent_is_zero = 1 AND (tokens_type IS NULL OR tokens_type = 'null')
                         AND (cost_type IS NULL OR cost_type = 'null') THEN 0
                     WHEN cost_type IS NULL OR cost_type = 'null' THEN NULL
                     WHEN cost_type IN ('integer','real') AND cost >= 0 THEN cost
                     ELSE -1
                 END,
                 \(tokenTotalSQL),
                 model_id,
                 provider_id))
        FROM source;
        """
    }

    /// The earliest Go usage in the whole history — the monthly cycle anchor.
    ///
    /// The anchor asks for a minimum, so a message that exists in both tables (the v1→v2 migration
    /// copies a turn under the same id) cannot move it: the duplicate is simply another candidate
    /// for the same minimum. Only the data query needs the id-based deduplication.
    static func anchorSQL(schema: OpenCodeDatabaseSchema) -> String {
        let branches = anchorBranches(schema: schema.effective)
        return """
        SELECT MIN(time_created) FROM (
        \(branches)
        );
        """
    }

    /// A cheap "does this database hold any hosted usage" probe.
    static func probeSQL(schema: OpenCodeDatabaseSchema) -> String {
        switch schema.effective {
        case .v2:
            return """
            SELECT 1 FROM session_message
            WHERE type = 'assistant'
              AND json_valid(data)
              AND \(providerExpression(v2: true)) IN \(providerList())
              AND json_type(data,'$.cost') IN ('integer','real')
            LIMIT 1;
            """
        case .mixed:
            // Two EXISTS probes instead of one union: each stops at its first match, so the probe
            // never materializes the whole message history.
            return """
            SELECT 1 WHERE EXISTS (
                SELECT 1 FROM session_message
                WHERE type = 'assistant'
                  AND json_valid(data)
                  AND \(providerExpression(v2: true)) IN \(providerList())
                  AND json_type(data,'$.cost') IN ('integer','real')
            ) OR EXISTS (
                SELECT 1 FROM message
                WHERE json_extract(data,'$.role') = 'assistant'
                  AND json_valid(data)
                  AND \(providerExpression(v2: false)) IN \(providerList())
                  AND json_type(data,'$.cost') IN ('integer','real')
            );
            """
        case .legacy, .unknown:
            return """
            SELECT 1 FROM message
            WHERE json_valid(data)
              AND json_extract(data,'$.role') = 'assistant'
              AND \(providerExpression(v2: false)) IN \(providerList())
              AND json_type(data,'$.cost') IN ('integer','real')
            LIMIT 1;
            """
        }
    }

    // MARK: - Row projection

    /// The hosted assistant rows, projected into the columns the scanner's aggregation needs.
    ///
    /// Both layouts produce the same columns so they can be unioned. `tokens_absent_is_zero` is the
    /// one intentional difference: a v2 assistant turn that recorded no token object at all (a turn
    /// that errored before the provider answered) carries no usage, while a v1 assistant row always
    /// had a token object — a missing one there is malformed accounting and stays rejected.
    private static func sourceSQL(
        schema: OpenCodeDatabaseSchema,
        cutoffMs: Int?,
        providers: [String]
    ) -> String {
        var branches: [String] = []
        if schema.readsV2 {
            branches.append(v2Branch(cutoffMs: cutoffMs, providers: providers))
        }
        if schema.readsLegacy {
            branches.append(legacyBranch(cutoffMs: cutoffMs, providers: providers, dedupe: schema == .mixed))
        }
        return branches.joined(separator: "\n    UNION ALL\n")
    }

    private static func v2Branch(cutoffMs: Int?, providers: [String]) -> String {
        """
        SELECT
                   time_created,
                   json_type(data,'$.cost') AS cost_type,
                   json_extract(data,'$.cost') AS cost,
                   json_type(data,'$.tokens') AS tokens_type,
                   json_type(data,'$.tokens.total') AS total_type,
                   json_extract(data,'$.tokens.total') AS total,
                   json_type(data,'$.tokens.input') AS input_type,
                   json_extract(data,'$.tokens.input') AS input_tokens,
                   json_type(data,'$.tokens.output') AS output_type,
                   json_extract(data,'$.tokens.output') AS output_tokens,
                   json_type(data,'$.tokens.reasoning') AS reasoning_type,
                   json_extract(data,'$.tokens.reasoning') AS reasoning_tokens,
                   json_type(data,'$.tokens.cache') AS cache_type,
                   json_type(data,'$.tokens.cache.read') AS cache_read_type,
                   json_extract(data,'$.tokens.cache.read') AS cache_read_tokens,
                   json_type(data,'$.tokens.cache.write') AS cache_write_type,
                   json_extract(data,'$.tokens.cache.write') AS cache_write_tokens,
                   COALESCE(json_extract(data,'$.model.id'), json_extract(data,'$.modelID')) AS model_id,
                   COALESCE(json_extract(data,'$.model.providerID'), json_extract(data,'$.providerID')) AS provider_id,
                   1 AS tokens_absent_is_zero
        FROM session_message
        WHERE type = 'assistant'
          \(cutoffClause(cutoffMs))
          AND json_valid(data)
          AND \(providerExpression(v2: true)) IN \(providerList(providers))
        """
    }

    private static func legacyBranch(cutoffMs: Int?, providers: [String], dedupe: Bool) -> String {
        """
        SELECT
                   time_created,
                   json_type(data,'$.cost') AS cost_type,
                   json_extract(data,'$.cost') AS cost,
                   json_type(data,'$.tokens') AS tokens_type,
                   json_type(data,'$.tokens.total') AS total_type,
                   json_extract(data,'$.tokens.total') AS total,
                   json_type(data,'$.tokens.input') AS input_type,
                   json_extract(data,'$.tokens.input') AS input_tokens,
                   json_type(data,'$.tokens.output') AS output_type,
                   json_extract(data,'$.tokens.output') AS output_tokens,
                   json_type(data,'$.tokens.reasoning') AS reasoning_type,
                   json_extract(data,'$.tokens.reasoning') AS reasoning_tokens,
                   json_type(data,'$.tokens.cache') AS cache_type,
                   json_type(data,'$.tokens.cache.read') AS cache_read_type,
                   json_extract(data,'$.tokens.cache.read') AS cache_read_tokens,
                   json_type(data,'$.tokens.cache.write') AS cache_write_type,
                   json_extract(data,'$.tokens.cache.write') AS cache_write_tokens,
                   COALESCE(json_extract(data,'$.modelID'), json_extract(data,'$.model.id')) AS model_id,
                   COALESCE(json_extract(data,'$.providerID'), json_extract(data,'$.model.providerID')) AS provider_id,
                   0 AS tokens_absent_is_zero
        FROM message
        WHERE json_extract(data,'$.role') = 'assistant'
          \(cutoffClause(cutoffMs))
          AND json_valid(data)
          AND \(providerExpression(v2: false)) IN \(providerList(providers))
          \(dedupe ? dedupeClause : "")
        """
    }

    /// The token total for one row.
    ///
    /// A reported total wins when it is positive; otherwise the total is derived from the token
    /// components, which requires a token object with valid input and output counts. Anything else
    /// is malformed accounting and is reported as `-1` so the caller rejects the fold instead of
    /// publishing a smaller total. The one exception is the v2 layout, where a turn that recorded
    /// no token object at all carries no usage rather than malformed usage.
    private static let tokenTotalSQL = """
        CASE
            WHEN total_type IN ('integer','real') AND total > 0 THEN total
            WHEN tokens_type = 'object'
              AND (total_type IS NULL OR total_type = 'null' OR (total_type IN ('integer','real') AND total = 0))
              AND input_type IN ('integer','real') AND input_tokens >= 0
              AND output_type IN ('integer','real') AND output_tokens >= 0
              AND (reasoning_type IS NULL OR reasoning_type = 'null' OR (reasoning_type IN ('integer','real') AND reasoning_tokens >= 0))
              AND (cache_type IS NULL OR cache_type IN ('null','object'))
              AND (cache_read_type IS NULL OR cache_read_type = 'null' OR (cache_read_type IN ('integer','real') AND cache_read_tokens >= 0))
              AND (cache_write_type IS NULL OR cache_write_type = 'null' OR (cache_write_type IN ('integer','real') AND cache_write_tokens >= 0))
            THEN COALESCE(input_tokens,0)
               + COALESCE(output_tokens,0)
               + COALESCE(reasoning_tokens,0)
               + COALESCE(cache_read_tokens,0)
               + COALESCE(cache_write_tokens,0)
            WHEN tokens_absent_is_zero = 1 AND (tokens_type IS NULL OR tokens_type = 'null')
              AND (cost_type IS NULL OR cost_type = 'null' OR (cost_type IN ('integer','real') AND cost = 0)) THEN 0
            ELSE -1
        END
        """

    /// The Go anchor's rows: the earliest Go usage, with a real recorded cost.
    private static func anchorBranches(schema: OpenCodeDatabaseSchema) -> String {
        var branches: [String] = []
        if schema.readsV2 {
            branches.append(
                """
                SELECT time_created FROM session_message
                WHERE type = 'assistant'
                  AND json_valid(data)
                  AND \(providerExpression(v2: true)) = '\(OpenCodeUsageScanner.goProviderID)'
                  AND json_type(data,'$.cost') IN ('integer','real')
                """
            )
        }
        if schema.readsLegacy {
            branches.append(
                """
                SELECT time_created FROM message
                WHERE json_extract(data,'$.role') = 'assistant'
                  AND json_valid(data)
                  AND \(providerExpression(v2: false)) = '\(OpenCodeUsageScanner.goProviderID)'
                  AND json_type(data,'$.cost') IN ('integer','real')
                """
            )
        }
        return branches.joined(separator: "\n    UNION ALL\n")
    }

    /// The hosted provider id list, as a SQL literal list.
    private static func providerList(_ providers: [String] = OpenCodeUsageScanner.hostedProviderIDs) -> String {
        "(" + providers.map { "'\($0)'" }.joined(separator: ",") + ")"
    }

    /// The provider id of a row. The v2 layout nests it under `$.model`; the v1 layout keeps it at
    /// the top level. Each expression falls back to the other shape so a store that carries both
    /// still reads.
    private static func providerExpression(v2: Bool) -> String {
        v2
            ? "COALESCE(json_extract(data,'$.model.providerID'), json_extract(data,'$.providerID'))"
            : "COALESCE(json_extract(data,'$.providerID'), json_extract(data,'$.model.providerID'))"
    }

    /// The window bound, or nothing for an unbounded (full-history) read.
    private static func cutoffClause(_ cutoffMs: Int?) -> String {
        guard let cutoffMs else { return "" }
        return "AND time_created >= \(cutoffMs)"
    }

    /// Drops a v1 row whose message id the v2 table already holds.
    ///
    /// The v1→v2 migration copies a turn under the same message id, so a store mid-migration holds
    /// the migrated turns twice. The v2 copy is the one OpenCode keeps writing, so it wins and the
    /// duplicate v1 row is skipped — the usage is counted once, not twice.
    private static let dedupeClause = """
        AND NOT EXISTS (SELECT 1 FROM session_message AS migrated WHERE migrated.id = message.id)
        """
}
