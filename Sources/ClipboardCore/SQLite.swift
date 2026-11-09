import Foundation
import SQLite3

/// A value bound to a statement.
enum SQLiteValue {
    case int(Int64)
    case real(Double)
    case text(String)
    case null
}

struct SQLiteError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// One result row, read by column position.
struct SQLiteRow {
    fileprivate let statement: OpaquePointer

    func int(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
    func real(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
    /// Read by byte length, not up to the first zero byte, so text that
    /// contains a NUL character comes back whole.
    func text(_ column: Int32) -> String? {
        guard let bytes = sqlite3_column_text(statement, column) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, column))
        return String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
    }
}

/// A thin wrapper over the SQLite that ships with macOS: open, run, query.
final class SQLiteDatabase {
    private var handle: OpaquePointer?
    /// Tells SQLite to copy bound text, because Swift strings do not outlive the call.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String) throws {
        guard sqlite3_open(path, &handle) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(handle)
            throw SQLiteError(message: "Could not open \(path): \(message)")
        }
    }

    deinit { sqlite3_close(handle) }

    /// Adds `contains_folded(text, query)` to SQL: 1 when `text` contains
    /// `query` ignoring letter case and accents, the way Finder search does.
    /// Running it inside SQLite means rows that do not match are never loaded.
    func installContainsFolded() throws {
        let status = sqlite3_create_function_v2(
            handle, "contains_folded", 2, SQLITE_UTF8 | SQLITE_DETERMINISTIC, nil,
            { context, _, arguments in
                func string(_ index: Int) -> String {
                    guard let value = arguments?[index], let bytes = sqlite3_value_text(value) else { return "" }
                    return String(decoding: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_value_bytes(value))), as: UTF8.self)
                }
                sqlite3_result_int(context, string(0).localizedStandardContains(string(1)) ? 1 : 0)
            }, nil, nil, nil)
        guard status == SQLITE_OK else { throw failure("create function contains_folded") }
    }

    var lastInsertedRowID: Int64 { sqlite3_last_insert_rowid(handle) }
    var changedRows: Int { Int(sqlite3_changes(handle)) }

    func execute(_ sql: String, _ values: [SQLiteValue] = []) throws {
        _ = try query(sql, values) { _ in () }
    }

    func query<T>(_ sql: String, _ values: [SQLiteValue] = [], map: (SQLiteRow) -> T) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw failure(sql)
        }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32
            switch value {
            case .int(let number): status = sqlite3_bind_int64(statement, index, number)
            case .real(let number): status = sqlite3_bind_double(statement, index, number)
            case .text(let string):
                // An explicit length: a negative one would stop at the first NUL.
                var utf8 = Array(string.utf8)
                status = sqlite3_bind_text(statement, index, &utf8, Int32(utf8.count), Self.transient)
            case .null: status = sqlite3_bind_null(statement, index)
            }
            guard status == SQLITE_OK else { throw failure(sql) }
        }
        var rows: [T] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: rows.append(map(SQLiteRow(statement: statement)))
            case SQLITE_DONE: return rows
            default: throw failure(sql)
            }
        }
    }

    private func failure(_ sql: String) -> SQLiteError {
        SQLiteError(message: "\(String(cString: sqlite3_errmsg(handle))) (in: \(sql.prefix(80)))")
    }
}
