import Foundation
import SQLite3
import XCTest
@testable import AccountDock

final class ConversationTests: XCTestCase {
    func testReadOnlyHierarchyAndPaginatedMessages() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let parent = UUID().uuidString.lowercased(), child = UUID().uuidString.lowercased()
        func create(_ name: String, _ sql: String) throws {
            var db: OpaquePointer?
            XCTAssertEqual(sqlite3_open(home.appendingPathComponent(name).path, &db), SQLITE_OK)
            defer { sqlite3_close(db) }
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        }
        try create("state_5.sqlite", """
            CREATE TABLE threads(id TEXT,attached_thread_parent_id TEXT,name TEXT,title TEXT,updated_at INTEGER,archived INTEGER,thread_source TEXT,source TEXT);
            INSERT INTO threads VALUES('\(parent)',NULL,'Main','original',100,0,'user','vscode');
            INSERT INTO threads VALUES('\(child)','\(parent)','Side','original',101,0,'user','vscode');
            INSERT INTO threads VALUES('\(UUID().uuidString)',NULL,'Agent','hidden',102,0,'subagent','other');
            """)
        var sql = "CREATE TABLE thread_items(thread_id TEXT,item_id TEXT,item_type TEXT,item_json TEXT,rollout_ordinal INTEGER);"
        for i in 0..<65 {
            let item: [String: Any] = ["type": "userMessage", "content": [["type": "text", "text": "message \(i)"]]]
            let json = String(decoding: try JSONSerialization.data(withJSONObject: item), as: UTF8.self)
            sql += "INSERT INTO thread_items VALUES('\(child)','\(i)','userMessage','\(json)',\(i));"
        }
        sql += "INSERT INTO thread_items VALUES('\(parent)','other','agentMessage','{\"text\":\"other thread\"}',100);"
        try create("thread_history_1.sqlite", sql)
        let paths = ["state_5.sqlite", "thread_history_1.sqlite"].map { home.appendingPathComponent($0) }
        let before = try paths.map { try Data(contentsOf: $0) }
        let reader = ConversationReader(home: home)
        let rows = try await reader.conversations()
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first?.parentID, parent)
        let first = try await reader.messages(threadID: child)
        XCTAssertEqual(first.messages.count, 60)
        XCTAssertEqual(first.messages.first?.text, "message 5")
        let older = try await reader.messages(threadID: child, before: first.cursor)
        XCTAssertEqual(older.messages.count, 5)
        XCTAssertNil(older.cursor)
        XCTAssertEqual(try paths.map { try Data(contentsOf: $0) }, before)
    }
    @MainActor func testConversationLinkRejectsInvalidInput() throws {
        let id = UUID().uuidString
        XCTAssertEqual(try VSCodeIsolation.conversationURL(id), "vscode://openai.chatgpt/local/" + id.lowercased() + "?windowId=_blank")
        XCTAssertThrowsError(try VSCodeIsolation.conversationURL("../../settings?command=anything"))
        XCTAssertEqual(try VSCodeIsolation.conversationURL(id, windowID: 2), "vscode://openai.chatgpt/local/" + id.lowercased() + "?windowId=2")
        XCTAssertThrowsError(try VSCodeIsolation.conversationURL(id, windowID: -1))
        XCTAssertEqual(VSCodeIsolation.windowIDs("    0 12345 33379 window [1] (Account Dock)\n    6 23456 54579 window [2] (Account Dock)\nwindow [99] in arbitrary text"), [1, 2])
    }
    func testMissingDatabaseDoesNotCreateOne() async {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do { _ = try await ConversationReader(home: home).conversations(); XCTFail("Expected missing store error") }
        catch { XCTAssertFalse(FileManager.default.fileExists(atPath: home.path)) }
    }
}

extension ConversationTests {
    func testSideChatSelectionValidation() throws {
        let id = UUID().uuidString
        XCTAssertNoThrow(try SideChatRequest(parentID: id, quote: "선택한 문장").validate())
        XCTAssertThrowsError(try SideChatRequest(parentID: "invalid", quote: "text").validate())
        XCTAssertThrowsError(try SideChatRequest(parentID: id, quote: " \n").validate())
        XCTAssertThrowsError(try SideChatRequest(parentID: id, quote: String(repeating: "가", count: 22000)).validate())
    }
}


extension ConversationTests {
    @MainActor func testNativeAttachedForkKeepsSelectedContextAcrossRestart() async throws {
        guard ProcessInfo.processInfo.environment["ACCOUNT_DOCK_CODEX_INTEGRATION"] == "1" else { throw XCTSkip("Requires installed Codex; opt-in isolated integration test") }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("accountdock-side-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let connection = try CodexConnection(binary: CodexService.binary(), home: home, sqliteHome: home)
        try await connection.initialize()
        let start = try await connection.request("thread/start", params: ["historyMode": "paginated", "threadSource": "user", "cwd": home.path])
        let parent = try XCTUnwrap((start["thread"] as? [String: Any])?["id"] as? String)
        _ = try await connection.request("thread/inject_items", params: ["threadId": parent, "items": [["type": "message", "role": "user", "content": [["type": "input_text", "text": "Synthetic parent context"]]]]])
        let liveRequest = SideChatRequest(parentID: parent, quote: "열린 원본의 선택 내용")
        let liveChild = try await SideChatService.create(liveRequest, home: home, storageHome: home, linksURL: home.appendingPathComponent("links.json"))
        let liveRows = try await ConversationReader(home: home, linksURL: home.appendingPathComponent("links.json")).conversations()
        XCTAssertEqual(liveRows.first(where: { $0.id == liveChild })?.parentID, parent)
        // Source writer remains responsive after the fallback fork.
        _ = try await connection.request("thread/read", params: ["threadId": parent, "includeTurns": false])
        await connection.shutdown()
        let request = SideChatRequest(parentID: parent, quote: "선택한 문장 — 계정 독립 테스트")
        let child = try await SideChatService.create(request, home: home, storageHome: home, linksURL: home.appendingPathComponent("links.json"))
        let rows = try await ConversationReader(home: home).conversations()
        XCTAssertEqual(rows.first(where: { $0.id == child })?.parentID, parent)
        XCTAssertEqual(rows.first(where: { $0.id == child })?.title, request.title)
        let reopened = try CodexConnection(binary: CodexService.binary(), home: home, sqliteHome: home)
        try await reopened.initialize()
        let read = try await reopened.request("thread/read", params: ["threadId": child, "includeTurns": false])
        let thread = try XCTUnwrap(read["thread"] as? [String: Any])
        XCTAssertEqual(thread["attachedToThreadId"] as? String, parent)
        XCTAssertEqual(thread["forkedFromId"] as? String, parent)
        XCTAssertEqual(thread["historyMode"] as? String, "paginated")
        let path = try XCTUnwrap(thread["path"] as? String)
        let stored = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(stored.contains(request.quote))
        let parentRead = try await reopened.request("thread/read", params: ["threadId": parent, "includeTurns": false])
        let parentPath = try XCTUnwrap((parentRead["thread"] as? [String: Any])?["path"] as? String)
        let parentContent = try String(contentsOfFile: parentPath, encoding: .utf8)
        XCTAssertTrue(parentContent.contains("Synthetic parent context"))
        XCTAssertFalse(parentContent.contains(request.quote))
        await reopened.shutdown()
    }
}


extension ConversationTests {
    func testWriterFailureClassificationAndLinkPersistence() throws {
        XCTAssertTrue(CodexRPCError(code: -32600, serverMessage: "thread example already has an active writer").isActiveWriter)
        XCTAssertFalse(CodexRPCError(code: -32600, serverMessage: "unknown method").isActiveWriter)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("links.json")
        let parent = UUID().uuidString, child = UUID().uuidString
        try SideChatLinks.record(child: child, parent: parent, at: path)
        XCTAssertEqual(try SideChatLinks.read(at: path)[child], parent)
        XCTAssertThrowsError(try SideChatLinks.record(child: parent, parent: parent, at: path))
        XCTAssertEqual(try SideChatLinks.read(at: path).count, 1)
    }
}
