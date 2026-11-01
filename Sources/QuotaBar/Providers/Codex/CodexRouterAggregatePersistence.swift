import Darwin
import Foundation

/// The app and one-shot CLI can temporarily use different rates for a model. Keep the previous
/// priced fold alongside the current one so they can both resume instead of repeatedly replacing
/// each other's only disk checkpoint. Unrelated catalogue changes still use one file.
enum CodexRouterAggregatePersistence {
    private static let mutationLock = NSLock()

    static func fileURL(id: String) -> URL {
        JSONLScanCachePaths.defaultDirectory
            .appendingPathComponent("codex-router-aggregate", isDirectory: true)
            .appendingPathComponent("\(id).json")
    }

    static func read(id: String) -> CodexRouterAggregateIndex.Record? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let data = try? Data(contentsOf: fileURL(id: id)),
              let record = try? decoder.decode(CodexRouterAggregateIndex.Record.self, from: data),
              record.schema == CodexRouterAggregateIndex.schema
        else { return nil }
        return record
    }

    static func write(_ record: CodexRouterAggregateIndex.Record, id: String) throws {
        try mutationLock.withLock {
            let directory = fileURL(id: id).deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // A separate kernel lock protects the two-file update across app/CLI processes. Atomic
            // individual writes also let readers safely inspect either completed checkpoint.
            let descriptor = Darwin.open(directory.appendingPathComponent("aggregate-write.lock").path,
                                         O_CREAT | O_RDWR | O_CLOEXEC, mode_t(S_IRUSR | S_IWUSR))
            guard descriptor >= 0 else { throw posixError() }
            defer { Darwin.close(descriptor) }
            guard flock(descriptor, LOCK_EX) == 0 else { throw posixError() }
            defer { flock(descriptor, LOCK_UN) }

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            if let previous = read(id: id), previous.complete,
               previous.key.matchesIgnoringPricing(record.key),
               previous.pricingDependencies != nil,
               previous.key.pricingToken != record.key.pricingToken,
               previous.pricingDependencies != record.pricingDependencies {
                try encoder.encode(previous).write(to: fileURL(id: id + "-previous"), options: .atomic)
            }
            try encoder.encode(record).write(to: fileURL(id: id), options: .atomic)
        }
    }

    private static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}
