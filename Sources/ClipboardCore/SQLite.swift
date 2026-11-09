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
    func text(_ column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
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
            case .text(let string): status = sqlite3_bind_text(statement, index, string, -1, Self.transient)
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
