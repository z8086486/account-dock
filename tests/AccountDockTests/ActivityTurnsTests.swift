import XCTest
import SQLite3
@testable import AccountDock

final class ActivityTurnsTests: XCTestCase {
    func testQuietLiveTurnRemainsActiveAndTerminalWins() {
        let now = Date()
        let id = UUID().uuidString
        let running = ObservedTurn(id: id, active: true, started: now.addingTimeInterval(-1800), finished: nil)
        var tail = ActivityLogState()
        tail.lastWork = now.addingTimeInterval(-60)
        XCTAssertTrue(ActivityTurnsReader.active(recent: tail, full: nil, observed: running, now: now))
        XCTAssertFalse(ActivityTurnsReader.active(recent: tail, full: nil, observed: nil, now: now))
        tail.lastFinishedTurnID = id; tail.lastFinish = now
        XCTAssertFalse(ActivityTurnsReader.active(recent: tail, full: nil, observed: running, now: now))
        tail.lastFinishedTurnID = nil; tail.lastWork = now
        let completed = ObservedTurn(id: id, active: false, started: running.started, finished: now)
        XCTAssertFalse(ActivityTurnsReader.active(recent: tail, full: nil, observed: completed, now: now))
    }
    func testScannerUsesLiveWriterTurnStateWithoutRecentLogOutput() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let thread = UUID().uuidString.lowercased(), turn = UUID().uuidString.lowercased()
        let log = root.appendingPathComponent("sessions/rollout-" + thread + ".jsonl").resolvingSymlinksInPath()
        let now = Date()
        let meta = "{\"type\":\"session_meta\",\"payload\":{\"creator_account_id\":\"previous\"}}\n"
        let rates: [String: Any] = ["type": "event_msg", "timestamp": now.addingTimeInterval(-600).ISO8601Format(), "payload": ["type": "token_count", "rate_limits": ["limit_id": "codex", "primary": ["used_percent": 6, "window_minutes": 10080]]]]
        var data = Data(meta.utf8); data.append(try JSONSerialization.data(withJSONObject: rates)); data.append(10)
        try data.write(to: log)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-600)], ofItemAtPath: log.path)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("thread_history_1.sqlite").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE thread_turns(thread_id TEXT,turn_id TEXT,status TEXT,started_at INTEGER,completed_at INTEGER,rollout_ordinal INTEGER); CREATE UNIQUE INDEX idx_thread_turns_page ON thread_turns(thread_id,rollout_ordinal); INSERT INTO thread_turns VALUES('\(thread)','\(turn)','inProgress',\(Int(now.timeIntervalSince1970)-1800),NULL,1)", nil, nil, nil), SQLITE_OK)
        let scanner = ActivityScanner(root: root, managed: root.appendingPathComponent("none"), ownership: { [log: "work"] })
        let active = await scanner.scan(root: root, now: now)
        XCTAssertEqual(active.activeAccounts["work"], 1)
        XCTAssertEqual(active.activeConversations.count, 1)
        XCTAssertNotNil(active.limits["work"])
        XCTAssertNil(active.limits["previous"])
        let alias = root.appendingPathComponent("managed-home")
        try FileManager.default.createDirectory(at: alias, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias.appendingPathComponent("sessions"), withDestinationURL: root.appendingPathComponent("sessions"))
        let linkedScanner = ActivityScanner(root: alias, managed: root.appendingPathComponent("none"), ownership: { [log: "work"] })
        let linked = await linkedScanner.scan(root: alias, now: now)
        XCTAssertEqual(linked.activeAccounts["work"], 1)
        XCTAssertEqual(sqlite3_exec(db, "UPDATE thread_turns SET status='completed',completed_at=\(Int(now.timeIntervalSince1970))", nil, nil, nil), SQLITE_OK)
        let finished = await scanner.scan(root: root, now: now.addingTimeInterval(2))
        XCTAssertFalse(finished.active)
        XCTAssertTrue(finished.activeAccounts.isEmpty)
    }
}
