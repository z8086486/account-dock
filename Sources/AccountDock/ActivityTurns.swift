import Foundation
import SQLite3

struct ObservedTurn: Sendable {
    let id: String
    let active: Bool
    let started: Date
    let finished: Date?
}

/// A few indexed, read-only lookups for conversations held by live Codex processes.
enum ActivityTurnsReader {
    static func read(home: URL, threadIDs: Set<String>) -> [String: ObservedTurn] {
        guard !threadIDs.isEmpty else { return [:] }
        let path = home.appendingPathComponent("thread_history_1.sqlite").path
        guard FileManager.default.fileExists(atPath: path) else { return [:] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else { if let db { sqlite3_close(db) }; return [:] }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 25)
        sqlite3_progress_handler(db, 20_000, { _ in 1 }, nil)
        var statement: OpaquePointer?
        let sql = "SELECT turn_id,status,started_at,completed_at FROM thread_turns INDEXED BY idx_thread_turns_page WHERE thread_id=? ORDER BY rollout_ordinal DESC LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(statement) }
        var result: [String: ObservedTurn] = [:]
        for thread in threadIDs.sorted().prefix(256) where UUID(uuidString: thread) != nil {
            sqlite3_reset(statement); sqlite3_clear_bindings(statement)
            _ = thread.withCString { sqlite3_bind_text(statement, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            guard sqlite3_step(statement) == SQLITE_ROW,
                  let id = sqlite3_column_text(statement, 0), let status = sqlite3_column_text(statement, 1) else { continue }
            let state = String(cString: status), turn = String(cString: id)
            guard UUID(uuidString: turn) != nil, ["inProgress", "completed", "interrupted", "failed", "cancelled"].contains(state) else { continue }
            let started = Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
            let finished = sqlite3_column_type(statement, 3) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
            result[thread] = ObservedTurn(id: turn, active: state == "inProgress", started: started, finished: finished)
        }
        return result
    }
    static func active(recent: ActivityLogState, full: ActivityLogState?, observed: ObservedTurn?, now: Date) -> Bool {
        if let observed {
            if recent.lastFinishedTurnID == observed.id && recent.lastFinish >= observed.started { return false }
            if observed.active { return true }
            // A newly logged start may briefly precede the history database update.
            guard let turn = recent.activeTurnID, turn != observed.id,
                  recent.latest > (observed.finished ?? observed.started) else { return false }
        }
        let latest = max(recent.latest, full?.latest ?? .distantPast)
        return ((recent.activeTurnID != nil || full?.activeTurnID != nil) && now.timeIntervalSince(latest) < 180)
            || (recent.lastWork > recent.lastFinish && now.timeIntervalSince(recent.lastWork) < 15)
    }
}
