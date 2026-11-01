import Foundation

/// The state of one file the Devin credential is read from.
struct DevinStateRevision: Equatable, Sendable {
    var path: String
    var size: UInt64
    var modified: Date
}

/// Keeps the Devin app's stored credential between refreshes.
///
/// Reading it means forking `/usr/bin/sqlite3` against the Devin app's state database, and that
/// database only changes when the app itself writes to it. Caching the answer against the file's
/// revision (size + modification time, including the write-ahead log) keeps the answer correct
/// while removing a process spawn from every refresh tick.
final class DevinAppAuthCache: @unchecked Sendable {
    private struct Entry {
        var revision: [DevinStateRevision]
        var auth: DevinAuth?
    }

    private let lock = NSLock()
    private var entry: Entry?

    /// The cached credential for `revision`, reading it only when the revision moved. A read that
    /// throws is not cached, so a transient failure is retried on the next refresh.
    func value(revision: [DevinStateRevision], read: () throws -> DevinAuth?) throws -> DevinAuth? {
        lock.lock()
        defer { lock.unlock() }
        if let entry, entry.revision == revision { return entry.auth }
        let auth = try read()
        entry = Entry(revision: revision, auth: auth)
        return auth
    }
}
