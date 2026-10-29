import Foundation

/// Minimal CSV parser supporting quoted fields with embedded commas, newlines, and escaped quotes
/// (`""` → `"`). Streams records keyed by the header row. Adapted from
/// `../cursorcat/Sources/CursorCat/API/CSVParser.swift`.
enum CursorCSVParser {
    struct Summary: Equatable {
        var isStructurallyComplete: Bool
        var rejectedRecordCount: Int
        var wasCancelled: Bool = false
    }

    private struct RowScanResult {
        var isStructurallyComplete: Bool
        var wasCancelled: Bool
    }

    /// Streams records and reports structural failures plus rows whose width differs from the header.
    /// `header` exposes the normalized header once so boundary mappers can validate their required
    /// schema without parsing the whole export a second time.
    @discardableResult
    static func forEachRecord(
        in text: String,
        header onHeader: (([String]) -> Void)? = nil,
        _ body: ([String: String]) -> Void
    ) -> Summary {
        var header: [String]?
        var rejectedRecordCount = 0
        let rowScan = forEachRow(in: text) { row in
            guard let keys = header else {
                let normalized = row.map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
                }
                header = normalized
                onHeader?(normalized)
                return
            }

            guard row.count == keys.count else {
                rejectedRecordCount += 1
                return
            }
            var dict: [String: String] = [:]
            for (i, key) in keys.enumerated() {
                dict[key] = row[i]
            }
            body(dict)
        }
        return Summary(
            isStructurallyComplete: rowScan.isStructurallyComplete,
            rejectedRecordCount: rejectedRecordCount,
            wasCancelled: rowScan.wasCancelled
        )
    }

    private static func forEachRow(in text: String, _ body: ([String]) -> Void) -> RowScanResult {
        // CSV syntax is ASCII. Scan its UTF-8 storage directly and decode each field once, rather
        // than segmenting graphemes and growing a String for every character of the export.
        var text = text
        return text.withUTF8 { bytes in
            scanRows(bytes, body)
        }
    }

    private static func scanRows(_ bytes: UnsafeBufferPointer<UInt8>, _ body: ([String]) -> Void) -> RowScanResult {
        enum FieldState: Equatable {
            case start
            case unquoted
            case quoted
            case quoteClosed
        }

        var row: [String] = []
        var state = FieldState.start
        var fieldStart = 0
        var fieldEnd = 0
        // Only escaped quotes need a scratch buffer; ordinary fields decode their source slice.
        var unescaped: [UInt8]?
        var i = 0

        func appendField(through end: Int) {
            if var value = unescaped {
                value.append(contentsOf: bytes[fieldStart..<end])
                row.append(String(decoding: value, as: UTF8.self))
                unescaped = nil
            } else {
                row.append(String(decoding: bytes[fieldStart..<end], as: UTF8.self))
            }
        }

        var cancellationCheckAt = 0
        while i < bytes.count {
            if i >= cancellationCheckAt {
                cancellationCheckAt = i + 2_048
                if Task<Never, Never>.isCancelled {
                    return RowScanResult(isStructurallyComplete: false, wasCancelled: true)
                }
            }
            let c = bytes[i]

            if state == .quoted {
                if c == 34 {
                    if i + 1 < bytes.count && bytes[i + 1] == 34 {
                        if unescaped == nil { unescaped = [] }
                        unescaped!.append(contentsOf: bytes[fieldStart..<i])
                        unescaped!.append(34)
                        i += 2
                        fieldStart = i
                        continue
                    }
                    fieldEnd = i
                    state = .quoteClosed
                }
                i += 1
                continue
            }

            if c == 44 || c == 13 || c == 10 {
                appendField(through: state == .quoteClosed ? fieldEnd : i)
                if c != 44 {
                    emit(row, body)
                    row.removeAll(keepingCapacity: true)
                    if c == 13, i + 1 < bytes.count, bytes[i + 1] == 10 { i += 1 }
                }
                i += 1
                fieldStart = i
                state = .start
                continue
            }

            switch state {
            case .start:
                if c == 34 {
                    state = .quoted
                    fieldStart = i + 1
                } else {
                    state = .unquoted
                }
            case .unquoted:
                if c == 34 {
                    return RowScanResult(isStructurallyComplete: false, wasCancelled: false)
                }
            case .quoteClosed:
                return RowScanResult(isStructurallyComplete: false, wasCancelled: false)
            case .quoted:
                preconditionFailure("quoted fields are handled before the state switch")
            }
            i += 1
        }

        guard state != .quoted else {
            return RowScanResult(isStructurallyComplete: false, wasCancelled: false)
        }
        // Trailing partial row.
        if fieldStart < bytes.count || !row.isEmpty || state == .quoteClosed {
            appendField(through: state == .quoteClosed ? fieldEnd : bytes.count)
            emit(row, body)
        }
        return RowScanResult(isStructurallyComplete: true, wasCancelled: false)
    }

    private static func emit(_ row: [String], _ body: ([String]) -> Void) {
        if !row.allSatisfy(\.isEmpty) {
            body(row)
        }
    }
}
