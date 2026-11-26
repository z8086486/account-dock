import Foundation
import SQLite3
import XCTest
@testable import AccountDock

final class LiveRefreshTests: XCTestCase {
    func testStaleWriterAndReadOnlyHandleCannotOwnConversation() {
        XCTAssertTrue(ActivityOwnership.isCurrentWriter(flags: 65547, offset: 300, size: 300))
        XCTAssertFalse(ActivityOwnership.isCurrentWriter(flags: 65547, offset: 200, size: 300))
        XCTAssertFalse(ActivityOwnership.isCurrentWriter(flags: 1, offset: 300, size: 300))
        XCTAssertFalse(ActivityOwnership.isCurrentWriter(flags: 3, offset: -1, size: 300))
    }

    func testRefreshMergesCompletedRolloutItemsWithDelayedDatabase() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let id = UUID().uuidString
        let log = home.appendingPathComponent("rollout.jsonl")
        func database(_ file: String, _ sql: String) {
            var db: OpaquePointer?
            XCTAssertEqual(sqlite3_open(home.appendingPathComponent(file).path, &db), SQLITE_OK)
            defer { sqlite3_close(db) }
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        }
        database("state_5.sqlite", "CREATE TABLE threads(id TEXT,rollout_path TEXT); INSERT INTO threads VALUES('\(id)','\(log.path)');")
        database("thread_history_1.sqlite", """
            CREATE TABLE thread_items(thread_id TEXT,item_id TEXT,item_type TEXT,item_json TEXT,rollout_ordinal INTEGER);
            INSERT INTO thread_items VALUES('\(id)','u1','userMessage','{"content":[{"text":"question"}]}',2000);
            INSERT INTO thread_items VALUES('\(id)','a1','agentMessage','{"text":"old projection"}',2001);
            """)
        func item(_ ordinal: Int, _ id: String, _ type: String, _ text: String) throws -> String {
            let object: [String: Any] = ["ordinal": ordinal, "type": "event_msg",
                "payload": ["type": "item_completed", "item": ["id": id, "type": type,
                    "content": [["type": "text", "text": text]]]]]
            return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self) + "\n"
        }
        var text = try item(2000, "u1", "UserMessage", "question")
        text += try item(2001, "a1", "AgentMessage", "complete answer")
        // A large tool record crosses chunk boundaries. It is not a chat message.
        text += "{\"ordinal\":2002,\"type\":\"response_item\",\"payload\":{\"text\":\"" + String(repeating: "x", count: 300_000) + "\"}}\n"
        text += try item(2003, "u2", "UserMessage", "new question")
        text += try item(2004, "a2", "AgentMessage", "latest answer")
        text += "{\"ordinal\":2005" // writer has not completed the final line
        try text.write(to: log, atomically: true, encoding: .utf8)
        let page = try await ConversationReader(home: home).messages(threadID: id)
        XCTAssertEqual(page.messages.map(\.id), ["u1", "a1", "u2", "a2"])
        XCTAssertEqual(page.messages.map(\.text), ["question", "complete answer", "new question", "latest answer"])
        let older = try RolloutMessages.read(log, after: 1999, before: 2003)
        XCTAssertEqual(older.sorted { $0.0 < $1.0 }.map { $0.1.id }, ["u1", "a1"])
        try FileManager.default.removeItem(at: log)
        let indexed = try await ConversationReader(home: home).messages(threadID: id)
        XCTAssertEqual(indexed.messages.map(\.text), ["question", "old projection"])
    }
}
