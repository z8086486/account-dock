import Foundation

struct SideChatRequest: Sendable {
    let parentID: String
    let quote: String
    var title: String { "사이드 채팅 · " + String(quote.split(whereSeparator: \.isNewline).joined(separator: " ").prefix(55)) }
    func validate() throws {
        guard UUID(uuidString: parentID) != nil, !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              quote.utf8.count <= 64_000 else { throw DockError.message("사이드 채팅에 사용할 내용을 다시 선택해 주세요.") }
    }
    var context: String { "원본 대화에서 사용자가 선택한 부분입니다. 이후 질문의 참고 문맥으로 사용하세요.\n\n<selected_text>\n\(quote)\n</selected_text>" }
}

@MainActor enum SideChatService {
    static func create(_ request: SideChatRequest, home: URL, storageHome: URL = VSCodeEnvironment.originalHome, linksURL: URL = SideChatLinks.url) async throws -> String {
        try request.validate()
        let connection = try CodexConnection(binary: CodexService.binary(), home: home, sqliteHome: storageHome)
        do {
            try await connection.initialize()
            // Native attached fork: shared history stays in Codex's own storage contract.
            // No turn/start: inference and tool execution begin only in the VS Code UI.
            let result: [String: Any]
            do {
                result = try await connection.request("thread/fork", params: [
                    "threadId": request.parentID, "attachToSource": true, "excludeTurns": true, "threadSource": "user"
                ], timeout: 45)
            } catch let error as CodexRPCError where error.isActiveWriter {
                // A live source belongs to another app-server. Ordinary forks use its persisted
                // history without acquiring its writer lease; Account Dock keeps the hierarchy.
                result = try await connection.request("thread/fork", params: [
                    "threadId": request.parentID, "attachToSource": false, "excludeTurns": true,
                    "threadSource": "user", "deferGoalContinuation": true
                ], timeout: 45)
            }
            guard let thread = result["thread"] as? [String: Any], let id = thread["id"] as? String,
                  UUID(uuidString: id) != nil else { throw DockError.message("사이드 채팅 생성 결과를 확인하지 못했습니다.") }
            do {
                try SideChatLinks.record(child: id, parent: request.parentID, at: linksURL)
                _ = try await connection.request("thread/inject_items", params: ["threadId": id, "items": [
                    ["type": "message", "role": "user", "content": [["type": "input_text", "text": request.context]]]
                ]])
                _ = try await connection.request("thread/name/set", params: ["threadId": id, "name": request.title])
            } catch {
                throw DockError.message("사이드 채팅은 생성됐지만 선택 내용 저장을 완료하지 못했습니다. 대화 목록에서 확인해 주세요.")
            }
            await connection.shutdown()
            return id
        } catch { await connection.shutdown(); throw error }
    }
}


/// Only relationship IDs are stored here; conversation text remains in Codex storage.
enum SideChatLinks {
    static var url: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AccountDock/conversation-links.json") }
    static func read(at url: URL = url) throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        guard data.count <= 2_000_000 else { throw DockError.message("사이드 채팅 연결 목록이 너무 큽니다.") }
        let links = try JSONDecoder().decode([String: String].self, from: data)
        return links.filter { UUID(uuidString: $0.key) != nil && UUID(uuidString: $0.value) != nil && $0.key != $0.value }
    }
    static func record(child: String, parent: String, at url: URL = url) throws {
        guard UUID(uuidString: child) != nil, UUID(uuidString: parent) != nil, child != parent else { throw DockError.message("사이드 채팅 연결을 저장하지 못했습니다.") }
        var links = try read(at: url)
        links[child] = parent
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(links).write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}


@MainActor enum ConversationDeletion {
    static func delete(_ id: String, storageHome: URL = VSCodeEnvironment.originalHome, linksURL: URL = SideChatLinks.url) async throws {
        guard UUID(uuidString: id) != nil else { throw DockError.message("올바른 대화 ID가 아닙니다.") }
        guard try await ConversationReader(home: storageHome, linksURL: linksURL).hasChildren(threadID: id) == false else {
            throw DockError.message("하위 사이드 채팅을 먼저 삭제해 주세요. 원본 대화는 삭제하지 않았습니다.")
        }
        // The native delete API resolves both session roots relative to CODEX_HOME.
        // Use the actual history home, never an unrelated temporary home.
        try FileManager.default.createDirectory(at: storageHome.appendingPathComponent("archived_sessions"), withIntermediateDirectories: true)
        let connection = try CodexConnection(binary: CodexService.binary(), home: storageHome, sqliteHome: storageHome)
        do {
            try await connection.initialize()
            _ = try await connection.request("thread/delete", params: ["threadId": id], timeout: 30)
            await connection.shutdown()
        } catch {
            await connection.shutdown()
            if let error = error as? CodexRPCError, error.isActiveWriter {
                throw DockError.message("다른 창에서 열려 있는 대화입니다. 해당 대화 창을 닫은 뒤 다시 삭제해 주세요.")
            }
            throw error
        }
        var links = try SideChatLinks.read(at: linksURL)
        if links.removeValue(forKey: id) != nil {
            try JSONEncoder().encode(links).write(to: linksURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: linksURL.path)
        }
    }
}
