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
    static func create(_ request: SideChatRequest, home: URL, storageHome: URL = VSCodeEnvironment.originalHome) async throws -> String {
        try request.validate()
        let connection = try CodexConnection(binary: CodexService.binary(), home: home, sqliteHome: storageHome)
        do {
            try await connection.initialize()
            // Native attached fork: shared history stays in Codex's own storage contract.
            // No turn/start: inference and tool execution begin only in the VS Code UI.
            let result = try await connection.request("thread/fork", params: [
                "threadId": request.parentID, "attachToSource": true, "excludeTurns": true, "threadSource": "user"
            ], timeout: 45)
            guard let thread = result["thread"] as? [String: Any], let id = thread["id"] as? String,
                  UUID(uuidString: id) != nil else { throw DockError.message("사이드 채팅 생성 결과를 확인하지 못했습니다.") }
            do {
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
