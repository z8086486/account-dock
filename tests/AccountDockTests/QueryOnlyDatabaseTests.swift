import Foundation
import SQLite3
import XCTest
@testable import AccountDock

final class QueryOnlyDatabaseTests: XCTestCase {
    func testWALWriterExitAndRestartWithoutLosingHistory() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let path = home.appendingPathComponent("thread_history_1.sqlite").path
        let thread = UUID().uuidString.lowercased()
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &writer), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(writer, "PRAGMA journal_mode=WAL; CREATE TABLE thread_items(thread_id TEXT,item_id TEXT,item_type TEXT,item_json TEXT,rollout_ordinal INTEGER); INSERT INTO thread_items VALUES('\(thread)','first','agentMessage','{\"text\":\"before idle\"}',1);", nil, nil, nil), SQLITE_OK)
        // Codex's SQLite removes sidecars at final writer close; Apple's SQLite
        // defaults to persisting them, so explicitly simulate Codex's lifecycle.
        var persist: Int32 = 0
        XCTAssertEqual(sqlite3_file_control(writer, "main", SQLITE_FCNTL_PERSIST_WAL, &persist), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(writer), SQLITE_OK)
        writer = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path + "-shm"))
        let before = try Data(contentsOf: URL(fileURLWithPath: path))
        let reader = ConversationReader(home: home)
        let idle = try await reader.messages(threadID: thread)
        XCTAssertEqual(idle.messages.map(\.text), ["before idle"])
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), before)
        XCTAssertEqual(sqlite3_open(path, &writer), SQLITE_OK)
        defer { sqlite3_close(writer) }
        XCTAssertEqual(sqlite3_exec(writer, "INSERT INTO thread_items VALUES('\(thread)','second','agentMessage','{\"text\":\"after restart\"}',2)", nil, nil, nil), SQLITE_OK)
        let resumed = try await reader.messages(threadID: thread)
        XCTAssertEqual(resumed.messages.map(\.text), ["before idle", "after restart"])
    }

    func testQueriesCannotWriteOrDisableProtectionAndMissingStoreIsNotCreated() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let path = home.appendingPathComponent("test.sqlite").path
        var db: OpaquePointer?
        XCTAssertNotEqual(QueryOnlyDatabase.open(path, database: &db), SQLITE_OK)
        sqlite3_close(db); db = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE t(x); INSERT INTO t VALUES(1)", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db); db = nil
        XCTAssertEqual(QueryOnlyDatabase.open(path, database: &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        for sql in ["SELECT x FROM t", "SELECT length('ok'),COALESCE(NULL,1)"] {
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, sql)
        }
        for sql in ["INSERT INTO t VALUES(2)", "DELETE FROM t", "UPDATE t SET x=3", "DROP TABLE t", "PRAGMA query_only=OFF", "PRAGMA journal_mode=DELETE", "ATTACH ':memory:' AS other"] {
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_AUTH, sql)
        }
    }
}
