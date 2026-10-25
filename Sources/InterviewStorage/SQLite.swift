import Foundation
import SQLite3
import InterviewCore

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct SQLiteError: Error, CustomStringConvertible {
    public let code: Int32
    public let message: String
    public var description: String { "sqlite \(code): \(message)" }
}

public enum SQLValue: Equatable, Sendable {
    case null, integer(Int64), real(Double), text(String), blob(Data)
    public var int: Int? { if case .integer(let v) = self { return Int(v) }; return nil }
    public var double: Double? { if case .real(let v) = self { return v }; if case .integer(let v) = self { return Double(v) }; return nil }
    public var string: String? { if case .text(let v) = self { return v }; return nil }
    public var data: Data? { if case .blob(let v) = self { return v }; return nil }
}

/// Minimal serial SQLite wrapper. WAL mode, foreign keys on, journal and temp files kept next to the database
/// so deletion can traverse them (plan §13.2 mentions journals explicitly).
public final class SQLiteDatabase: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()
    public let path: String

    public init(path: String) throws {
        self.path = path
        if path != ":memory:" {
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        var h: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &h, flags, nil) == SQLITE_OK, let db = h else {
            let msg = h.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            throw SQLiteError(code: -1, message: msg)
        }
        handle = db
        try exec("PRAGMA journal_mode=WAL")
        try exec("PRAGMA foreign_keys=ON")
        try exec("PRAGMA secure_delete=ON")
    }

    deinit { if let h = handle { sqlite3_close_v2(h) } }

    public func exec(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &err) == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(err)
            throw SQLiteError(code: sqlite3_errcode(handle), message: msg)
        }
    }

    @discardableResult
    public func run(_ sql: String, _ params: [SQLValue] = []) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw SQLiteError(code: rc, message: String(cString: sqlite3_errmsg(handle))) }
        return Int(sqlite3_changes(handle))
    }

    public func query(_ sql: String, _ params: [SQLValue] = []) throws -> [[String: SQLValue]] {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        var rows: [[String: SQLValue]] = []
        let columnCount = sqlite3_column_count(stmt)
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw SQLiteError(code: rc, message: String(cString: sqlite3_errmsg(handle))) }
            var row: [String: SQLValue] = [:]
            for i in 0..<columnCount {
                let name = String(cString: sqlite3_column_name(stmt, i))
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: row[name] = .integer(sqlite3_column_int64(stmt, i))
                case SQLITE_FLOAT: row[name] = .real(sqlite3_column_double(stmt, i))
                case SQLITE_TEXT: row[name] = .text(String(cString: sqlite3_column_text(stmt, i)))
                case SQLITE_BLOB:
                    let bytes = sqlite3_column_bytes(stmt, i)
                    row[name] = .blob(bytes > 0 ? Data(bytes: sqlite3_column_blob(stmt, i), count: Int(bytes)) : Data())
                default: row[name] = .null
                }
            }
            rows.append(row)
        }
        return rows
    }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        try exec("BEGIN IMMEDIATE")
        do { let r = try body(); try exec("COMMIT"); return r } catch { try? exec("ROLLBACK"); throw error }
    }

    public var userVersion: Int {
        get { (try? query("PRAGMA user_version").first?["user_version"]?.int) ?? 0 }
        set { try? exec("PRAGMA user_version=\(newValue)") }
    }

    private func prepare(_ sql: String, _ params: [SQLValue]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw SQLiteError(code: sqlite3_errcode(handle), message: String(cString: sqlite3_errmsg(handle)))
        }
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case .null: sqlite3_bind_null(s, idx)
            case .integer(let v): sqlite3_bind_int64(s, idx, v)
            case .real(let v): sqlite3_bind_double(s, idx, v)
            case .text(let v): sqlite3_bind_text(s, idx, v, -1, SQLITE_TRANSIENT)
            case .blob(let v): v.withUnsafeBytes { sqlite3_bind_blob(s, idx, $0.baseAddress, Int32(v.count), SQLITE_TRANSIENT) }
            }
        }
        return s
    }

    /// Files that belong to this database (main, WAL, shm) for deletion traversal.
    public var relatedFiles: [URL] {
        guard path != ":memory:" else { return [] }
        return [path, path + "-wal", path + "-shm", path + "-journal"].map { URL(fileURLWithPath: $0) }
    }
}
