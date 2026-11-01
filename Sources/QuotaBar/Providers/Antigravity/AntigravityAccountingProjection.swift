import Foundation
import SQLite3

/// Large generation records mostly contain prompts and tool results. SQLite's incremental BLOB API
/// lets us skip those byte ranges and retain the same accounting envelope the existing decoder uses.
/// Both the database and BLOB handle are read-only; no whole oversized record is hex-encoded/copied.
enum AntigravityAccountingProjection {
    static let maximumReadBytes = 512 * 1_024
    static let maximumAccountingBytes = 64 * 1_024

    static func read(path: String, index: Int, expectedBytes: Int) throws -> [UInt8]? {
        var database: OpaquePointer?
        let opened = sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        defer { if let database { sqlite3_close(database) } }
        func failure() -> SQLiteError {
            .queryFailed(database.map { String(cString: sqlite3_errmsg($0)) } ?? "Antigravity BLOB read failed")
        }
        guard opened == SQLITE_OK, let database else { throw failure() }
        sqlite3_busy_timeout(database, 1_000)
        guard sqlite3_exec(database, "BEGIN", nil, nil, nil) == SQLITE_OK else { throw failure() }
        // Closing the read-only connection ends this read snapshot, including on cancellation/error.
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT rowid, length(data) FROM gen_metadata WHERE idx = ? LIMIT 2",
                                 -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_int64(statement, 1, Int64(index)) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else { throw failure() }
        let rowID = sqlite3_column_int64(statement, 0)
        guard sqlite3_column_int64(statement, 1) == Int64(expectedBytes) else {
            throw SQLiteError.queryFailed("Antigravity conversation database changed during scan")
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
        var blob: OpaquePointer?
        guard sqlite3_blob_open(database, "main", "gen_metadata", "data", rowID, 0, &blob) == SQLITE_OK,
              let blob else { throw failure() }
        defer { sqlite3_blob_close(blob) }
        guard Int(sqlite3_blob_bytes(blob)) == expectedBytes else {
            throw SQLiteError.queryFailed("Antigravity conversation database changed during scan")
        }
        return try project(byteCount: expectedBytes) { range in
            var bytes = [UInt8](repeating: 0, count: range.count)
            let status = bytes.withUnsafeMutableBytes {
                sqlite3_blob_read(blob, $0.baseAddress, Int32(range.count), Int32(range.lowerBound))
            }
            guard status == SQLITE_OK else { throw failure() }
            return bytes
        }
    }

    /// The injected range reader also makes the work/byte budget testable without a real database.
    static func project(byteCount: Int, read: @escaping (Range<Int>) throws -> [UInt8]) throws -> [UInt8]? {
        guard byteCount >= 0, byteCount <= Int(Int32.max) else { return nil }
        var reader = Reader(byteCount: byteCount, read: read)
        do { return try reader.message(0..<byteCount, wrapped: false) }
        catch ProjectionError.invalid { return nil }
    }

    private enum ProjectionError: Error { case invalid }

    private struct Reader {
        let byteCount: Int
        let read: (Range<Int>) throws -> [UInt8]
        private var pageStart = -1
        private var page: [UInt8] = []
        private var bytesRead = 0
        private var fieldsRead = 0

        init(byteCount: Int, read: @escaping (Range<Int>) throws -> [UInt8]) {
            self.byteCount = byteCount
            self.read = read
        }

        mutating func byte(at offset: Int) throws -> UInt8 {
            try Task.checkCancellation()
            guard offset >= 0, offset < byteCount else { throw ProjectionError.invalid }
            if offset < pageStart || offset >= pageStart + page.count {
                let count = min(4_096, byteCount - offset)
                guard bytesRead <= maximumReadBytes - count else { throw ProjectionError.invalid }
                pageStart = offset
                page = try read(offset..<(offset + count))
                guard page.count == count else { throw ProjectionError.invalid }
                bytesRead += count
            }
            return page[offset - pageStart]
        }

        mutating func varint(at offset: inout Int, end: Int) throws -> UInt64 {
            var value: UInt64 = 0
            for shift in 0..<10 {
                guard offset < end else { throw ProjectionError.invalid }
                let next = try byte(at: offset)
                offset += 1
                guard shift < 9 || next <= 1 else { throw ProjectionError.invalid }
                value |= UInt64(next & 0x7f) << (shift * 7)
                if next & 0x80 == 0 { return value }
            }
            throw ProjectionError.invalid
        }

        mutating func bytes(in range: Range<Int>) throws -> [UInt8] {
            guard range.count <= maximumAccountingBytes else { throw ProjectionError.invalid }
            var output: [UInt8] = []
            output.reserveCapacity(range.count)
            for offset in range { output.append(try byte(at: offset)) }
            return output
        }

        mutating func message(_ range: Range<Int>, wrapped: Bool) throws -> [UInt8] {
            guard range.lowerBound >= 0, range.upperBound <= byteCount else { throw ProjectionError.invalid }
            var offset = range.lowerBound
            var output: [UInt8] = []
            while offset < range.upperBound {
                fieldsRead += 1
                guard fieldsRead <= 100_000 else { throw ProjectionError.invalid }
                let start = offset
                let tag = try varint(at: &offset, end: range.upperBound)
                let field = tag >> 3
                guard field > 0, field < 1 << 29 else { throw ProjectionError.invalid }
                let wanted = wrapped ? [4, 9, 19].contains(field) : [1, 4].contains(field)
                switch tag & 7 {
                case 0:
                    _ = try varint(at: &offset, end: range.upperBound)
                case 1, 5:
                    let width = tag & 7 == 1 ? 8 : 4
                    guard width <= range.upperBound - offset else { throw ProjectionError.invalid }
                    offset += width
                case 2:
                    let length = try varint(at: &offset, end: range.upperBound)
                    guard length <= UInt64(range.upperBound - offset) else { throw ProjectionError.invalid }
                    let end = offset + Int(length)
                    if !wrapped && field == 1 {
                        let nested = try message(offset..<end, wrapped: true)
                        output += Self.varint(tag) + Self.varint(UInt64(nested.count)) + nested
                        offset = end
                        guard output.count <= maximumAccountingBytes else { throw ProjectionError.invalid }
                        continue
                    }
                    offset = end
                default: throw ProjectionError.invalid
                }
                if wanted {
                    guard offset - start <= maximumAccountingBytes - output.count else { throw ProjectionError.invalid }
                    output += try bytes(in: start..<offset)
                }
            }
            return output
        }

        static func varint(_ value: UInt64) -> [UInt8] {
            var remaining = value
            var encoded: [UInt8] = []
            repeat {
                var next = UInt8(remaining & 0x7f)
                remaining >>= 7
                if remaining != 0 { next |= 0x80 }
                encoded.append(next)
            } while remaining != 0
            return encoded
        }
    }
}
