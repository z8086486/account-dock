import Foundation
import SQLite3
import XCTest
@testable import AccountDock

final class ActivitySettingsTests: XCTestCase {
    private let thread = "11111111-1111-4111-8111-111111111111"
    private let otherThread = "22222222-2222-4222-8222-222222222222"
    private let turn = "33333333-3333-4333-8333-333333333333"
    private let otherTurn = "44444444-4444-4444-8444-444444444444"

    func testOptionalLocalSamplingMetadataProbe() throws {
        guard ProcessInfo.processInfo.environment["ACCOUNT_DOCK_ACTIVITY_SETTINGS_PROBE"] == "1" else {
            throw XCTSkip("Set ACCOUNT_DOCK_ACTIVITY_SETTINGS_PROBE=1 for a read-only local metadata probe.")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        var pointer: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(home.appendingPathComponent("logs_2.sqlite").path, &pointer,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil), SQLITE_OK)
        let database = try XCTUnwrap(pointer)
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 25)
        sqlite3_progress_handler(database, 20_000, { _ in 1 }, nil)
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(database,
            "SELECT thread_id FROM logs WHERE target='feedback_tags' ORDER BY id DESC LIMIT 1",
            -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        let bytes = try XCTUnwrap(sqlite3_column_text(statement, 0))
        let thread = String(cString: bytes)
        let observed = try XCTUnwrap(ActivitySettingsReader.latestSettings(home: home, threadID: thread,
            since: Date().addingTimeInterval(-300)))
        XCTAssertNotNil(observed.serviceTier)
        XCTAssertNotNil(observed.model)
        XCTAssertNotNil(observed.effort)
        // Explicitly omit thread IDs, account IDs, paths, and message/log contents.
        print("Observed runtime metadata: model=\(observed.model ?? "unknown"), effort=\(observed.effort ?? "unknown"), serviceTier=\(observed.serviceTier ?? "unknown")")
    }

    private func record(turn: String, tier: String) -> String {
        "session_loop:run_sampling_request{turn_id=\(turn) model=test}:try_run_sampling_request{turn_id=\(turn) model=test}: tags_json={\"service_tier\":\"\(tier)\",\"unrelated\":\"not retained\"}"
    }

    private func withDatabase(_ body: (URL, OpaquePointer) throws -> Void) throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        var pointer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(home.appendingPathComponent("logs_2.sqlite").path, &pointer), SQLITE_OK)
        let database = try XCTUnwrap(pointer)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, "CREATE TABLE logs(id INTEGER PRIMARY KEY, ts INTEGER, ts_nanos INTEGER, thread_id TEXT, target TEXT, feedback_log_body TEXT); CREATE INDEX idx_logs_thread_id_ts ON logs(thread_id, ts DESC, ts_nanos DESC, id DESC);", nil, nil, nil), SQLITE_OK)
        try body(home, database)
    }

    private func insert(_ database: OpaquePointer, thread: String, body: String, target: String = "feedback_tags", ts: Int64 = 1, nanos: Int64 = 0) throws {
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(database, "INSERT INTO logs(ts,ts_nanos,thread_id,target,feedback_log_body) VALUES(?,?, ?,?,?)", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        XCTAssertEqual(sqlite3_bind_int64(statement, 1, ts), SQLITE_OK)
        XCTAssertEqual(sqlite3_bind_int64(statement, 2, nanos), SQLITE_OK)
        for (index, value) in [thread, target, body].enumerated() {
            XCTAssertEqual(sqlite3_bind_text(statement, Int32(index + 3), value, -1, transient), SQLITE_OK)
        }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
    }

    func testUsesOnlyExactThreadAndSamplingTurn() throws {
        try withDatabase { home, database in
            try insert(database, thread: thread, body: record(turn: turn, tier: "priority"))
            try insert(database, thread: thread, body: record(turn: otherTurn, tier: "default"))
            try insert(database, thread: otherThread, body: record(turn: turn, tier: "standard"))
            try insert(database, thread: thread, body: record(turn: turn, tier: "ultrafast"), target: "unrelated")
            XCTAssertEqual(ActivitySettingsReader.settings(home: home, threadID: thread, turnID: turn)?.serviceTier, "priority")
            XCTAssertEqual(ActivitySettingsReader.settings(home: home, threadID: thread, turnID: otherTurn)?.serviceTier, "default")
            XCTAssertNil(ActivitySettingsReader.settings(home: home, threadID: otherThread, turnID: otherTurn))
            XCTAssertNil(ActivitySettingsReader.settings(home: home, threadID: "' OR 1=1 --", turnID: turn))
            XCTAssertNil(ActivitySettingsReader.settings(home: home, threadID: thread, turnID: "' OR 1=1 --"))
        }
    }

    func testDoesNotInferFromConfigurationOrUnknownRecords() throws {
        XCTAssertNil(ActivitySettingsReader.parseSamplingRecord("config{turn_id=\(turn)}: tags_json={\"service_tier\":\"priority\"}", turnID: turn))
        XCTAssertNil(ActivitySettingsReader.parseSamplingRecord(record(turn: turn, tier: "future-tier"), turnID: turn)?.serviceTier)
        XCTAssertNil(ActivitySettingsReader.parseSamplingRecord(record(turn: otherTurn, tier: "priority"), turnID: turn))
        XCTAssertNil(ActivitySettingsReader.parseSamplingRecord("run_sampling_request{turn_id=\(turn)}: tags_json={broken", turnID: turn)?.serviceTier)
        for tier in ["standard", "default", "priority", "fast", "ultrafast"] {
            XCTAssertEqual(ActivitySettingsReader.parseSamplingRecord(record(turn: turn, tier: tier), turnID: turn)?.serviceTier, tier)
        }
    }

    func testModelAndEffortComeFromMatchingSamplingMetadataOnly() throws {
        let body = "session_loop:run_sampling_request{turn_id=\(turn) model=gpt-6-astra cwd=/private/ effort=Some(Low) /example}:try_run_sampling_request{turn_id=\(turn) model=gpt-6-astra}: model=\"gpt-6-astra\" effort=Some(Ultra) auth_mode=Some(Chatgpt) tags_json={\"service_tier\":\"priority\"}"
        let settings = try XCTUnwrap(ActivitySettingsReader.parseSamplingRecord(body, turnID: turn))
        XCTAssertEqual(settings.model, "gpt-6-astra")
        XCTAssertEqual(settings.effort, "ultra")
        XCTAssertEqual(settings.serviceTier, "priority")
        XCTAssertEqual(settings.turnID, turn)
        XCTAssertNil(ActivitySettingsReader.parseSamplingRecord(body, turnID: otherTurn))
    }

    func testLatestSamplingHonorsThreadAndFinishBoundary() throws {
        try withDatabase { home, database in
            try insert(database, thread: thread, body: record(turn: otherTurn, tier: "priority"), ts: 100)
            try insert(database, thread: thread, body: record(turn: turn, tier: "standard"), ts: 200, nanos: 500_000_000)
            try insert(database, thread: otherThread, body: record(turn: otherTurn, tier: "ultrafast"), ts: 300)
            let latest = try XCTUnwrap(ActivitySettingsReader.latestSettings(home: home, threadID: thread, since: Date(timeIntervalSince1970: 200.4)))
            XCTAssertEqual(latest.turnID, turn)
            XCTAssertEqual(latest.serviceTier, "standard")
            XCTAssertEqual(latest.sampledAt, Date(timeIntervalSince1970: 200.5))
            XCTAssertNil(ActivitySettingsReader.latestSettings(home: home, threadID: thread, since: Date(timeIntervalSince1970: 200.6)))
            XCTAssertNil(ActivitySettingsReader.latestSettings(home: home, threadID: thread, since: Date(timeIntervalSince1970: 301)))
        }
    }

    func testMalformedNewestSamplingDoesNotReuseOlderTier() throws {
        try withDatabase { home, database in
            try insert(database, thread: thread, body: record(turn: turn, tier: "priority"))
            try insert(database, thread: thread, body: "run_sampling_request{turn_id=\(turn)}: tags_json={broken")
            XCTAssertNil(ActivitySettingsReader.settings(home: home, threadID: thread, turnID: turn)?.serviceTier)
        }
    }

    func testNewestMatchingRuntimeSettingWinsAndReadLeavesDatabaseUnchanged() throws {
        try withDatabase { home, database in
            try insert(database, thread: thread, body: record(turn: turn, tier: "default"))
            try insert(database, thread: thread, body: record(turn: turn, tier: "priority"))
            let path = home.appendingPathComponent("logs_2.sqlite")
            let before = try Data(contentsOf: path)
            XCTAssertEqual(ActivitySettingsReader.settings(home: home, threadID: thread, turnID: turn)?.serviceTier, "priority")
            XCTAssertEqual(try Data(contentsOf: path), before)
        }
    }

    func testLockedCorruptAndMissingDatabaseAreUnknown() throws {
        try withDatabase { home, database in
            try insert(database, thread: thread, body: record(turn: turn, tier: "priority"))
            XCTAssertEqual(sqlite3_exec(database, "BEGIN EXCLUSIVE", nil, nil, nil), SQLITE_OK)
            let started = Date()
            XCTAssertNil(ActivitySettingsReader.settings(home: home, threadID: thread, turnID: turn))
            XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
            XCTAssertEqual(sqlite3_exec(database, "ROLLBACK", nil, nil, nil), SQLITE_OK)
        }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertNil(ActivitySettingsReader.settings(home: home, threadID: thread, turnID: turn))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.path))
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try Data("invalid sqlite data".utf8).write(to: home.appendingPathComponent("logs_2.sqlite"))
        XCTAssertNil(ActivitySettingsReader.settings(home: home, threadID: thread, turnID: turn))
    }

    func testBoundedLookupDoesNotSearchOldSettingsIndefinitely() throws {
        try withDatabase { home, database in
            try insert(database, thread: thread, body: record(turn: turn, tier: "priority"))
            for _ in 0..<96 { try insert(database, thread: thread, body: record(turn: otherTurn, tier: "default")) }
            XCTAssertNil(ActivitySettingsReader.settings(home: home, threadID: thread, turnID: turn))
        }
    }

    func testUnknownSchemaDoesNotFallBackToFullScan() throws {
        try withDatabase { home, database in
            try insert(database, thread: thread, body: record(turn: turn, tier: "priority"))
            XCTAssertEqual(sqlite3_exec(database, "DROP INDEX idx_logs_thread_id_ts", nil, nil, nil), SQLITE_OK)
            XCTAssertNil(ActivitySettingsReader.settings(home: home, threadID: thread, turnID: turn))
        }
    }
}
