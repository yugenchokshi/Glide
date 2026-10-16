import Foundation
import SQLite3

/// Minimal SQLite wrapper (system libsqlite3, no dependencies).
public final class SQLiteDatabase: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSLock()
    public let path: String

    public enum Value: Sendable {
        case text(String)
        case int(Int64)
        case real(Double)
        case null
    }

    public struct DBError: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { "Database error: \(message)" }
    }

    static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(path: String) throws {
        self.path = path
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw DBError(message: "can't open \(path)")
        }
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA foreign_keys=ON")
    }

    deinit { sqlite3_close(db) }

    public func execute(_ sql: String, _ params: [Value] = []) throws {
        try lock.withLock {
            let stmt = try prepare(sql, params)
            defer { sqlite3_finalize(stmt) }
            let rc = sqlite3_step(stmt)
            guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw DBError(message: String(cString: sqlite3_errmsg(db))) }
        }
    }

    public func query(_ sql: String, _ params: [Value] = []) throws -> [[String: Value]] {
        try lock.withLock {
            let stmt = try prepare(sql, params)
            defer { sqlite3_finalize(stmt) }
            var rows: [[String: Value]] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                var row: [String: Value] = [:]
                for i in 0..<sqlite3_column_count(stmt) {
                    let name = String(cString: sqlite3_column_name(stmt, i))
                    switch sqlite3_column_type(stmt, i) {
                    case SQLITE_INTEGER: row[name] = .int(sqlite3_column_int64(stmt, i))
                    case SQLITE_FLOAT: row[name] = .real(sqlite3_column_double(stmt, i))
                    case SQLITE_TEXT: row[name] = .text(String(cString: sqlite3_column_text(stmt, i)))
                    default: row[name] = .null
                    }
                }
                rows.append(row)
            }
            return rows
        }
    }

    private func prepare(_ sql: String, _ params: [Value]) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw DBError(message: String(cString: sqlite3_errmsg(db))) }
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case .text(let s): sqlite3_bind_text(stmt, idx, s, -1, Self.transient)
            case .int(let n): sqlite3_bind_int64(stmt, idx, n)
            case .real(let d): sqlite3_bind_double(stmt, idx, d)
            case .null: sqlite3_bind_null(stmt, idx)
            }
        }
        return stmt
    }
}

extension SQLiteDatabase.Value {
    var string: String? { if case .text(let s) = self { return s }; return nil }
    var int: Int? { if case .int(let n) = self { return Int(n) }; return nil }
    var double: Double? {
        switch self {
        case .real(let d): return d
        case .int(let n): return Double(n)
        default: return nil
        }
    }
}
