import Foundation
import SQLite3

/// Reads a conversation-thread's Antigravity stores one per conversation database and reports the
/// planner responses with per-response timing for the TPS lens. Derived from the Agent Speed
/// project's Antigravity sources (https://github.com/zoefix/agent-speed, MIT) — its reader is the
/// reference for the protobuf shapes and the response rules; Attribute preserved in the source
/// headers of ProtobufReader.swift.
///
/// Scope is deliberately narrow: only `PLANNER_RESPONSE` steps (type 15), only the fields TPS
/// needs. Executor metadata is read only to resolve a response's model. Rows without any valid
/// timestamp are skipped; forked conversation copies are dropped by response-id dedup across the
/// stores; failed rows contribute their tokens but no timing.
struct AntigravityResponse: Equatable, Sendable {
    var key: String
    var endMs: Int64
    var startMs: Int64?
    var outputTokens: Int64
    var reasoningTokens: Int64
    var inputTokens: Int64
    var cacheReadTokens: Int64
    var model: String?
    var failed: Bool
}

enum AntigravityConversationReader {
    /// Only the native Antigravity app's store carries production conversation history; CLI, IDE,
    /// parity, and T3 stores are not this app's usage.
    static let storeSubpaths = [
        ".gemini/antigravity"
    ]

    /// The native conversation roots, resolved through the scanner's strict directory discovery
    /// (symlink-out roots are refused there rather than followed).
    static func conversationRoots(home: URL) -> [URL] {
        (try? AntigravityDbUsageScanner.discoverAllConversationDirectories(home: home))?
            .directories.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? []
    }

    /// Every conversation database under the local stores, in path order (stable for dedup),
    /// skipping any whose content cannot hold an in-window row. A database mutates its WAL on
    /// every step, so a stale file (and no newer `-wal` companion) can only hold out-of-window
    /// history — the planner query never needs to open it.
    static func conversationDatabases(home: URL, sinceMs: Int64 = 0) -> [URL] {
        var found: [URL] = []
        for conversations in conversationRoots(home: home) {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: conversations,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for entry in entries {
                let name = entry.lastPathComponent.lowercased()
                guard name.hasSuffix(".db") else { continue }
                // A symlinked leaf could reach outside the native store; never follow it.
                if (try? entry.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                    continue
                }
                guard isConversationDatabaseName(name: entry.lastPathComponent) else { continue }
                if skipStale(entry, sinceMs: sinceMs) { continue }
                found.append(entry)
            }
        }
        return found.sorted { $0.path < $1.path }
    }

    /// True when both the database and an active WAL companion cannot have been written inside the
    /// window. Missing files are treated as stale (nothing to fold).
    private static func skipStale(_ entry: URL, sinceMs: Int64) -> Bool {
        func modifiedMs(_ url: URL) -> Int64? {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                  let mtime = values.contentModificationDate else { return nil }
            return Int64(mtime.timeIntervalSince1970 * 1000)
        }
        let walModifiedMs = modifiedMs(URL(fileURLWithPath: entry.path + "-wal"))
        let mainModifiedMs = modifiedMs(entry)
        // A WAL that is newer than the window can carry in-flight steps; keep the database.
        if let walModifiedMs, walModifiedMs >= sinceMs { return false }
        // No WAL (or a stale WAL) and a stale main file: nothing in the window can exist.
        return mainModifiedMs.map { $0 < sinceMs } ?? true
    }

    /// UUID-shaped database names only — `conversation_summaries.db` and friends are not conversations.
    static func isConversationDatabaseName(name: String) -> Bool {
        name.range(of: #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\.db$"#,
                   options: .regularExpression) != nil
    }

    /// Fold every planner response in the window, deduplicated by response key. Each store fails
    /// open so one unreadable database does not drop the rest; `hasReadFailures` discloses that.
    static func responseScan(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        since: Date,
        now: Date
    ) -> (responses: [AntigravityResponse], hasReadFailures: Bool) {
        let sinceMs = Int64(since.timeIntervalSince1970 * 1000)
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        var seen = Set<String>()
        var results: [AntigravityResponse] = []
        var hasReadFailures = false
        for path in conversationDatabases(home: home, sinceMs: sinceMs) {
            if Task.isCancelled { break }
            guard let rows = readPlannerResponses(at: path, sinceMs: sinceMs) else {
                hasReadFailures = true
                continue
            }
            for row in rows {
                guard let start = row.startMs, start > 0, row.endMs >= start, row.endMs <= nowMs,
                      (200...300_000).contains(row.endMs - start), row.outputTokens > 0,
                      seen.insert(row.key).inserted else { continue }
                results.append(row)
            }
        }
        return (results, hasReadFailures)
    }

    // MARK: - Reading one database

    private static let stepSizeGuard = 1048576

    static func readPlannerResponses(at path: URL, sinceMs: Int64) -> [AntigravityResponse]? {
        var database: OpaquePointer?
        guard Self.openReadonly(path: path.path, database: &database) == SQLITE_OK, let database else {
            return nil
        }
        defer { sqlite3_close_v2(database) }
        let conversationID = String(path.lastPathComponent.dropLast(3)) // strip ".db"

        guard let steps = readSteps(database: database, sinceMs: sinceMs, conversationID: conversationID) else {
            return nil
        }
        // Model resolution needs the generation rows; they are small (a handful of rows).
        let generations = readGenerations(database: database)
        let executors = readExecutors(database: database)
        let modelOfStep = Self.resolveStepModels(
            stepIndices: steps.map(\.idx),
            generations: generations,
            executors: executors
        )
        return steps.map { step in
            AntigravityResponse(
                key: step.key,
                endMs: step.endMs,
                startMs: step.startMs,
                outputTokens: step.outputTokens,
                reasoningTokens: step.reasoningTokens,
                inputTokens: step.inputTokens,
                cacheReadTokens: step.cacheReadTokens,
                model: modelOfStep[step.idx],
                failed: step.failed
            )
        }
    }

    private static func openReadonly(path: String, database: UnsafeMutablePointer<OpaquePointer?>) -> Int32 {
        let hasWAL = FileManager.default.fileExists(atPath: path + "-wal")
        if hasWAL {
            return sqlite3_open_v2(path, database, SQLITE_OPEN_READONLY, nil)
        }
        // A closed WAL-mode database opens fine with immutable; without it the header checks fail.
        return sqlite3_open_v2(URL(fileURLWithPath: path).absoluteString + "?immutable=1",
                               database, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
    }

    private struct StepRow {
        var idx: Int64
        var key: String
        var startMs: Int64?
        var endMs: Int64
        var inputTokens: Int64
        var outputTokens: Int64
        var thinkingTokens: Int64
        var responseOutputTokens: Int64
        var cacheReadTokens: Int64
        var reasoningTokens: Int64 { thinkingTokens }
        var failed: Bool
    }

    private static func readSteps(database: OpaquePointer?, sinceMs: Int64, conversationID: String) -> [StepRow]? {
        let sql = """
        SELECT idx, step_type, status, CASE WHEN length(metadata) <= \(stepSizeGuard) THEN metadata END
        FROM steps WHERE step_type = 15 ORDER BY idx, rowid
        """
        var rows: [StepRow] = []
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        var statusCode = sqlite3_step(statement)
        while statusCode == SQLITE_ROW {
            defer { statusCode = sqlite3_step(statement) }
            if Task.isCancelled { return nil }
            let idx = sqlite3_column_int64(statement, 0)
            let status = sqlite3_column_int64(statement, 2)
            let metadataBytes: UnsafeRawBufferPointer
            if let blob = sqlite3_column_blob(statement, 3) {
                metadataBytes = UnsafeRawBufferPointer(start: blob, count: Int(sqlite3_column_bytes(statement, 3)))
            } else {
                continue // NULL or over the size guard
            }
            guard let metadata = decodeStepMetadata(metadataBytes) else { continue }
            // Completed steps with explicit timing only; in-flight and failed rows carry none.
            guard !Self.isOpenStatus(status) else { continue }
            let output = metadata.outputTokens > 0
                ? metadata.outputTokens
                : metadata.thinkingTokens + metadata.responseOutputTokens
            guard output > 0 || metadata.inputTokens > 0 || metadata.cacheReadTokens > 0 else { continue }
            guard !failedStatuses.contains(status), let startMs = metadata.createdMs,
                  let endMs = metadata.finishedGeneratingMs, endMs >= sinceMs else { continue }
            let key = metadata.usageKey ?? "antigravity:\(conversationID):\(idx)"
            rows.append(StepRow(
                idx: idx, key: key, startMs: startMs, endMs: endMs,
                inputTokens: metadata.inputTokens,
                outputTokens: output,
                thinkingTokens: metadata.thinkingTokens,
                responseOutputTokens: metadata.responseOutputTokens,
                cacheReadTokens: metadata.cacheReadTokens,
                failed: Self.failedStatuses.contains(status)
            ))
        }
        return statusCode == SQLITE_DONE ? rows : nil
    }

    // MARK: - Model resolution

    private struct Generation {
        var idx: Int64
        var stepIndices: Set<UInt64>
        var model: String?
    }

    private struct Executor {
        var idx: Int64
        var lastStepIdx: Int64
        var model: String?
    }

    private static func readGenerations(database: OpaquePointer?) -> [Generation] {
        let sql = """
        SELECT idx, CASE WHEN typeof(size) = 'integer' AND size <= \(stepSizeGuard) AND length(data) <= \(stepSizeGuard) THEN data END
        FROM gen_metadata ORDER BY idx, rowid
        """
        var rows: [Generation] = []
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return []
        }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            let idx = sqlite3_column_int64(statement, 0)
            guard let blob = sqlite3_column_blob(statement, 1) else { continue }
            let bytes = UnsafeRawBufferPointer(start: blob, count: Int(sqlite3_column_bytes(statement, 1)))
            guard let generation = decodeGeneration(bytes) else { continue }
            rows.append(Generation(idx: idx, stepIndices: generation.stepIndices,
                                   model: generation.responseModel ?? generation.label))
        }
        return rows
    }

    private static func readExecutors(database: OpaquePointer?) -> [Executor] {
        let sql = """
        SELECT idx, CASE WHEN length(data) <= \(stepSizeGuard) THEN data END
        FROM executor_metadata ORDER BY idx, rowid
        """
        var rows: [Executor] = []
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return []
        }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            let idx = sqlite3_column_int64(statement, 0)
            guard let blob = sqlite3_column_blob(statement, 1) else { continue }
            let bytes = UnsafeRawBufferPointer(start: blob, count: Int(sqlite3_column_bytes(statement, 1)))
            guard let executor = decodeExecutor(bytes) else { continue }
            rows.append(Executor(idx: idx, lastStepIdx: executor.lastStepIdx, model: executor.model))
        }
        return rows
    }

    /// Step idx → model, from the lowest generation listing the step, else from the executor run
    /// with the smallest `last_step_idx >= the step` (ties: lowest idx).
    private static func resolveStepModels(
        stepIndices: [Int64],
        generations: [Generation],
        executors: [Executor]
    ) -> [Int64: String] {
        var modelOfStep: [Int64: String] = [:]

        var generationOfStep: [UInt64: Int64] = [:]
        for generation in generations.sorted(by: { $0.idx < $1.idx }) {
            for step in generation.stepIndices {
                if let current = generationOfStep[step], current <= generation.idx { continue }
                generationOfStep[step] = generation.idx
            }
        }
        let generationByIndex = Dictionary(generations.map { ($0.idx, $0) }, uniquingKeysWith: { first, _ in first })
        for (step, generationIndex) in generationOfStep {
            guard let generation = generationByIndex[generationIndex], let model = generation.model else { continue }
            modelOfStep[Int64(bitPattern: step)] = model
        }

        // Executor fallback for steps with no generation-attributed model.
        let resolvable = executors.compactMap { executor in
            executor.model.map { (last: executor.lastStepIdx, idx: executor.idx, model: $0) }
        }
        for step in stepIndices where modelOfStep[step] == nil {
            let best = resolvable
                .filter { $0.last >= step }
                .min { ($0.last, $0.idx) < ($1.last, $1.idx) }
            if let best { modelOfStep[step] = best.model }
        }
        return modelOfStep
    }

    // MARK: - Decoding

    private struct StepMetadata {
        var createdMs: Int64?
        var viewableMs: Int64?
        var finishedGeneratingMs: Int64?
        var completedMs: Int64?
        var lastCompletedChunkMs: Int64?
        var startedMs: Int64?
        var usageKey: String?
        var inputTokens: Int64 = 0
        var outputTokens: Int64 = 0
        var thinkingTokens: Int64 = 0
        var responseOutputTokens: Int64 = 0
        var cacheReadTokens: Int64 = 0

        var timestamps: [Int64] {
            [createdMs, viewableMs, finishedGeneratingMs, completedMs, lastCompletedChunkMs, startedMs].compactMap { $0 }
        }
    }

    private static func decodeStepMetadata(_ bytes: UnsafeRawBufferPointer) -> StepMetadata? {
        guard let message = try? ProtobufMessage(bytes) else { return nil }
        var step = StepMetadata()
        step.createdMs = try? message.timestampMs(1)
        step.viewableMs = try? message.timestampMs(6)
        step.finishedGeneratingMs = try? message.timestampMs(7)
        step.completedMs = try? message.timestampMs(8)
        step.lastCompletedChunkMs = try? message.timestampMs(22)
        step.startedMs = try? message.timestampMs(32)
        if let usage = try? message.message(9) {
            let input = usage.uint(2), output = usage.uint(3), cacheRead = usage.uint(5)
            let thinking = usage.uint(9), response = usage.uint(10)
            guard input <= maxTokens, output <= maxTokens, cacheRead <= maxTokens,
                  thinking <= maxTokens, response <= maxTokens else { return nil }
            step.inputTokens = Int64(input)
            step.outputTokens = Int64(output)
            step.cacheReadTokens = Int64(cacheRead)
            step.thinkingTokens = Int64(thinking)
            step.responseOutputTokens = Int64(response)
            step.usageKey = nonEmpty(usage.string(11)) ?? nonEmpty(usage.string(7))
        }
        return step
    }

    private struct GenerationMetadata {
        var responseModel: String?
        var label: String?
        var stepIndices: Set<UInt64>
    }

    private static func decodeGeneration(_ bytes: UnsafeRawBufferPointer) -> GenerationMetadata? {
        guard let message = try? ProtobufMessage(bytes) else { return nil }
        let chat = try? message.message(1)
        let generation = GenerationMetadata(
            responseModel: nonEmpty(chat?.string(19)),
            label: nonEmpty(chat?.string(21)),
            stepIndices: Set((try? message.repeatedUInt(2)) ?? [])
        )
        return generation
    }

    private struct ExecutorMetadata {
        var terminationReason: Int64 = 0
        var lastStepIdx: Int64 = 0
        var model: String?
    }

    private static func decodeExecutor(_ bytes: UnsafeRawBufferPointer) -> ExecutorMetadata? {
        guard let message = try? ProtobufMessage(bytes) else { return nil }
        let planner = try? message.message(10)?.message(1)
        let override = try? planner?.message(56)
        let modelName = nonEmpty(message.string(28)) ?? nonEmpty(planner?.string(28))
        return ExecutorMetadata(
            terminationReason: message.int(1),
            lastStepIdx: message.int(3),
            model: modelName ?? nonEmpty(override?.string(19))
        )
    }

    private static let maxTokens: UInt64 = 10_000_000
    private static let openStatuses: Set<Int64> = [1, 2, 8, 9, 11]
    private static let failedStatuses: Set<Int64> = [6, 7, 12]

    private static func isOpenStatus(_ status: Int64) -> Bool { openStatuses.contains(status) }

    private static func nonEmpty(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return trimmed.isEmpty ? nil : trimmed
    }
}
