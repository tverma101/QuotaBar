import Foundation

struct GenerationSpeedScanner: Sendable {
    var sqlite: any SQLiteAccessing = SQLiteCLIAccessor(allowsReadWriteFallback: false)
    var zcodePath: String = ZAIProvider.zcodeSqlitePath
    var antigravityHome: URL = FileManager.default.homeDirectoryForCurrentUser

    func scan(now: Date = Date(), calendar: Calendar = .current) async throws -> GenerationSpeedReport {
        try await loadOffMainActor {
            try Task.checkCancellation()
            var report = GenerationSpeedReport(now: now, calendar: calendar)
            let since = GenerationSpeedWindow.fortnight.start(now: now, calendar: calendar)
            do {
                for sample in try zcodeSamples(since: since, now: now) { report.add(sample, source: .zcode) }
            } catch let SQLiteError.queryFailed(message) where message.contains("no such column") {
                report.markUnsupported(.zcode)
            } catch {
                try Task.checkCancellation()
                AppLog.warn(.refresh, "Generation Speed could not read ZCode's local timing history")
                report.markUnavailable(.zcode)
            }
            try Task.checkCancellation()
            let antigravity = AntigravityConversationReader.responseScan(home: antigravityHome, since: since, now: now)
            if antigravity.hasReadFailures {
                AppLog.warn(.refresh, "Generation Speed could not read all Antigravity timing history")
                report.markUnavailable(.antigravity)
            }
            for row in antigravity.responses {
                guard let start = row.startMs else { continue }
                report.add(GenerationSpeedSample(finishedAt: Date(timeIntervalSince1970: Double(row.endMs) / 1000),
                                                 seconds: Double(row.endMs - start) / 1000,
                                                 outputTokens: row.outputTokens, model: row.model),
                           source: .antigravity)
            }
            try Task.checkCancellation()
            return report
        }
    }

    func zcodeSamples(since: Date, now: Date) throws -> [GenerationSpeedSample] {
        let lower = Int64(since.timeIntervalSince1970 * 1000)
        let upper = Int64(now.timeIntervalSince1970 * 1000)
        let sql = """
        SELECT json_array(completed_at, completed_at - first_token_at, output_tokens,
                          CASE WHEN typeof(model_id) = 'text' THEN model_id END)
        FROM model_usage
        WHERE status = 'completed' AND typeof(completed_at) = 'integer'
          AND completed_at BETWEEN \(lower) AND \(upper)
          AND typeof(first_token_at) = 'integer' AND first_token_at > 0
          AND completed_at - first_token_at BETWEEN 200 AND 300000
          AND typeof(output_tokens) = 'integer' AND output_tokens > 0
        """
        guard let raw = try sqlite.queryValue(path: zcodePath, sql: sql) else { return [] }
        return try raw.split(whereSeparator: \.isNewline).map { line in
            let json = try JSONSerialization.jsonObject(with: Data(line.utf8))
            guard let fields = json as? [Any], fields.count == 4,
                  let finished = fields[0] as? Int64, let elapsed = fields[1] as? Int64,
                  let output = fields[2] as? Int64 else { throw CocoaError(.fileReadCorruptFile) }
            return GenerationSpeedSample(finishedAt: Date(timeIntervalSince1970: Double(finished) / 1000),
                                         seconds: Double(elapsed) / 1000, outputTokens: output,
                                         model: fields[3] as? String)
        }
    }
}
