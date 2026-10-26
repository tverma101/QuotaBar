import Foundation

/// Read-only projections for Freebuff Desktop's local usage receipts.
enum FreebuffDesktopUsageSQL {
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
        COALESCE(m.thread_id || ':' || m.seq, '') AS id,
        COALESCE(CAST(m.ts AS TEXT), '') AS timestamp,
        COALESCE(m.metrics_json, '') AS metrics,
        COALESCE(t.model, '') AS selectedModel
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
        COALESCE(t.model, '') AS selectedModel
      FROM auto_run_decision_receipts r JOIN threads t ON t.id = r.thread_id
      WHERE t.harness_id = 'codebuff'
        AND json_extract(r.manager_json, '$.harnessId') = 'codebuff'
        AND json_type(r.manager_json, '$.usage') = 'object'
    )
    """

    /// Compatibility query for stores created before mission-manager receipts existed.
    static let assistantMessages = """
    SELECT COALESCE(json_group_array(json_object(
      'id', COALESCE(m.thread_id || ':' || m.seq, ''),
      'timestamp', COALESCE(CAST(m.ts AS TEXT), ''),
      'metrics', COALESCE(m.metrics_json, ''),
      'selectedModel', COALESCE(t.model, '')
    )), '[]') FROM messages m JOIN threads t ON t.id = m.thread_id
    WHERE t.harness_id = 'codebuff' AND m.role = 'assistant'
      AND m.metrics_json IS NOT NULL AND m.metrics_json != '{}'
    """

    static func isMissingMissionReceiptTable(_ error: SQLiteError) -> Bool {
        guard case .queryFailed(let message) = error else { return false }
        return message.localizedCaseInsensitiveContains("no such table: auto_run_decision_receipts")
    }
}
