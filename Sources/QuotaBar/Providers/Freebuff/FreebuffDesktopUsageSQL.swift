import Foundation

/// Read-only projections for Freebuff Desktop's local usage receipts.
enum FreebuffDesktopUsageSQL {
    // Current Desktop can clear threads.model during migration while keeping the selected model in
    // world_snapshot. Project just that scalar; never fetch the rest of the thread snapshot.
    private static let selectedModel = """
    COALESCE(NULLIF(t.model, ''), CASE WHEN json_valid(t.world_snapshot)
      THEN json_extract(t.world_snapshot, '$.model') END, '')
    """
    /// Includes assistant usage and the separate auto-run manager call. The outcome receipt is
    /// deliberately excluded because it repeats the completed assistant turn's usage.
    static let messagesAndMissionManagers = """
    SELECT COALESCE(json_group_array(json_object(
      'id', id,
      'timestamp', timestamp,
      'metrics', metrics,
      'selectedModel', selectedModel
    )), '[]') FROM (
      SELECT
        COALESCE(CASE WHEN m.request_id LIKE 'cloud:%' THEN m.request_id
          ELSE m.thread_id || ':' || m.seq END, '') AS id,
        COALESCE(CAST(m.ts AS TEXT), '') AS timestamp,
        COALESCE(m.metrics_json, '') AS metrics,
        \(selectedModel) AS selectedModel
      FROM messages m JOIN threads t ON t.id = m.thread_id
      WHERE t.harness_id = 'codebuff' AND m.role = 'assistant'
        AND m.metrics_json IS NOT NULL AND m.metrics_json != '{}'

      UNION ALL

      SELECT
        COALESCE('mission-manager:' || r.thread_id || ':' || CAST(r.id AS TEXT), '') AS id,
        COALESCE(
          CAST(json_extract(r.manager_json, '$.startedAt') AS TEXT),
          CAST(r.created_at AS TEXT), ''
        ) AS timestamp,
        json_object(
          'usage', json(json_set(
            json_extract(r.manager_json, '$.usage'),
            '$.model', json_extract(r.manager_json, '$.model')
          )),
          'usageIncomplete', COALESCE(json_extract(r.manager_json, '$.usageIncomplete'), 0)
        ) || '' AS metrics,
        \(selectedModel) AS selectedModel
      FROM auto_run_decision_receipts r JOIN threads t ON t.id = r.thread_id
      WHERE t.harness_id = 'codebuff'
        AND json_extract(r.manager_json, '$.harnessId') = 'codebuff'
        AND json_type(r.manager_json, '$.usage') = 'object'
    )
    """

    /// Compatibility query for stores created before mission-manager receipts existed.
    static let assistantMessages = """
    SELECT COALESCE(json_group_array(json_object(
      'id', COALESCE(CASE WHEN m.request_id LIKE 'cloud:%' THEN m.request_id
        ELSE m.thread_id || ':' || m.seq END, ''),
      'timestamp', COALESCE(CAST(m.ts AS TEXT), ''),
      'metrics', COALESCE(m.metrics_json, ''),
      'selectedModel', \(selectedModel)
    )), '[]') FROM messages m JOIN threads t ON t.id = m.thread_id
    WHERE t.harness_id = 'codebuff' AND m.role = 'assistant'
      AND m.metrics_json IS NOT NULL AND m.metrics_json != '{}'
    """

    static func isMissingMissionReceiptTable(_ error: SQLiteError) -> Bool {
        guard case .queryFailed(let message) = error else { return false }
        return message.localizedCaseInsensitiveContains("no such table: auto_run_decision_receipts")
    }

    /// Older stores may predate either column/table. Retry only a proven missing-schema error;
    /// invalid databases and other query failures still reach the provider's visible history error.
    static func readRows(sqlite: any SQLiteAccessing, path: String) throws -> String? {
        var includeManagers = true
        var includeSnapshot = true
        while true {
            var sql = includeManagers ? messagesAndMissionManagers : assistantMessages
            if !includeSnapshot { sql = sql.replacingOccurrences(of: selectedModel, with: "COALESCE(t.model, '')") }
            do { return try sqlite.queryValue(path: path, sql: sql) }
            catch let error as SQLiteError {
                if includeManagers && isMissingMissionReceiptTable(error) { includeManagers = false }
                else if includeSnapshot, case .queryFailed(let message) = error,
                        message.localizedCaseInsensitiveContains("no such column: t.world_snapshot") {
                    includeSnapshot = false
                } else { throw error }
            }
        }
    }
}
