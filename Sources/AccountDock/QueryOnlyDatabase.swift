import Foundation
import SQLite3

/// Allows SQLite to initialize missing WAL/SHM sidecars after the last Codex
/// writer exits. SQL remains query-only; do not use immutable=1 on a live store.
enum QueryOnlyDatabase {
    static func open(_ path: String, database: inout OpaquePointer?) -> Int32 {
        // No CREATE: an absent store must never become an empty database.
        var result = sqlite3_open_v2(path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX, nil)
        if result != SQLITE_OK {
            if let database { sqlite3_close(database) }
            database = nil
            // Existing WAL/SHM may still permit reading a genuinely read-only store.
            result = sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        }
        guard result == SQLITE_OK else { return result }
        result = sqlite3_exec(database, "PRAGMA query_only=ON", nil, nil, nil)
        guard result == SQLITE_OK else { return result }
        // A second guard prevents future call sites from disabling query_only,
        // changing schema, attaching another database, or writing conversation data.
        return sqlite3_set_authorizer(database, { _, action, _, _, _, _ in
            switch action {
            case SQLITE_SELECT, SQLITE_READ, SQLITE_FUNCTION, SQLITE_RECURSIVE: return SQLITE_OK
            default: return SQLITE_DENY
            }
        }, nil)
    }
}
