import Foundation

/// The history database is a delayed projection. Completed rollout items are the
/// authoritative recent messages; response_item also contains injected prompts
/// and must not be displayed as conversation messages.
enum RolloutMessages {
    static func read(_ url: URL, after: Int64, before: Int64) throws -> [(Int64, ConversationMessage)] {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            // Codex can retain the indexed conversation after removing its rollout.
            return []
        }
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        var end = size
        var suffix = Data()
        var result: [(Int64, ConversationMessage)] = []
        // Read backwards in chunks, stopping at the database page boundary.
        // Never load a whole multi-hundred-MB conversation into memory.
        while end > 0 {
            let start = end > 262_144 ? end - 262_144 : 0
            try handle.seek(toOffset: start)
            var data = try handle.read(upToCount: Int(end - start)) ?? Data()
            data.append(suffix)
            let lines = data.split(separator: 10, omittingEmptySubsequences: false)
            suffix = start > 0 ? Data(lines.first ?? Data.SubSequence()) : Data()
            let complete = start > 0 ? Array(lines.dropFirst()) : Array(lines)
            for line in complete.reversed() {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      let ordinal = (object["ordinal"] as? NSNumber)?.int64Value else { continue }
                if ordinal <= after { return result }
                guard ordinal < before, object["type"] as? String == "event_msg",
                      let payload = object["payload"] as? [String: Any],
                      payload["type"] as? String == "item_completed",
                      let item = payload["item"] as? [String: Any],
                      let type = item["type"] as? String,
                      ["UserMessage", "AgentMessage"].contains(type),
                      let id = item["id"] as? String else { continue }
                let text = (item["content"] as? [[String: Any]] ?? []).map {
                    $0["text"] as? String ?? "[첨부: \($0["type"] as? String ?? "파일")]"
                }.joined(separator: "\n")
                result.append((ordinal, ConversationMessage(id: id,
                    role: type == "UserMessage" ? "userMessage" : "agentMessage", text: text)))
            }
            end = start
        }
        return result
    }
}
