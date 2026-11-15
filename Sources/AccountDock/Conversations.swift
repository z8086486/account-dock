import Foundation
import SQLite3
import SwiftUI

struct LocalConversation: Identifiable, Sendable {
    let id: String
    let parentID: String?
    let title: String
    let updated: Date
    let archived: Bool
}
struct ConversationMessage: Identifiable, Sendable {
    let id: String
    let role: String
    let text: String
}

/// Never opens authentication files or writes to Codex databases.
actor ConversationReader {
    let home: URL
    init(home: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")) { self.home = home }
    private func query(_ file: String, sql: String, values: [String] = []) throws -> [[String]] {
        let path = home.appendingPathComponent(file)
        guard FileManager.default.fileExists(atPath: path.path) else { throw DockError.message("로컬 대화 저장소를 찾지 못했습니다.") }
        var db: OpaquePointer?
        guard sqlite3_open_v2(path.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }; throw DockError.message("대화 저장소를 읽지 못했습니다.")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 100)
        sqlite3_progress_handler(db, 2_000_000, { _ in 1 }, nil)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw DockError.message("현재 대화 저장소 형식을 지원하지 않습니다.") }
        defer { sqlite3_finalize(stmt) }
        for (i, value) in values.enumerated() {
            guard sqlite3_bind_text(stmt, Int32(i + 1), value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) == SQLITE_OK else { throw DockError.message("대화 조회를 준비하지 못했습니다.") }
        }
        var rows: [[String]] = []
        var result = sqlite3_step(stmt)
        while result == SQLITE_ROW {
            rows.append((0..<sqlite3_column_count(stmt)).map { index in
                guard let text = sqlite3_column_text(stmt, index) else { return "" }
                return String(cString: text)
            })
            result = sqlite3_step(stmt)
        }
        guard result == SQLITE_DONE else { throw DockError.message("대화 조회가 지연되고 있습니다. 다시 시도해 주세요.") }
        return rows
    }
    func conversations() throws -> [LocalConversation] {
        try query("state_5.sqlite", sql: """
            SELECT id, attached_thread_parent_id, COALESCE(NULLIF(name,''),NULLIF(title,''),'제목 없는 대화'), updated_at, archived
            FROM threads WHERE (thread_source = 'user' OR (thread_source IS NULL AND source IN ('vscode','cli','exec')))
            ORDER BY updated_at DESC LIMIT 5000
            """).compactMap { row in
                guard UUID(uuidString: row[0]) != nil else { return nil }
                return LocalConversation(id: row[0], parentID: row[1].isEmpty ? nil : row[1],
                    title: String(row[2].prefix(300)), updated: Date(timeIntervalSince1970: Double(row[3]) ?? 0), archived: row[4] == "1")
            }
    }
    func messages(threadID: String, before: Int64? = nil) throws -> (messages: [ConversationMessage], cursor: Int64?) {
        guard UUID(uuidString: threadID) != nil else { throw DockError.message("올바른 대화 ID가 아닙니다.") }
        let rows = try query("thread_history_1.sqlite", sql: """
            SELECT item_id, item_type, CASE WHEN length(item_json) <= 1048576 THEN item_json ELSE '' END, rollout_ordinal
            FROM thread_items WHERE thread_id = ? AND item_type IN ('userMessage','agentMessage') AND rollout_ordinal < ?
            ORDER BY rollout_ordinal DESC LIMIT 60
            """, values: [threadID, String(before ?? Int64.max)])
        let messages = rows.reversed().map { row -> ConversationMessage in
            guard let data = row[2].data(using: .utf8), let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return ConversationMessage(id: row[0], role: row[1], text: "이 메시지는 크기 또는 형식 때문에 표시할 수 없습니다.")
            }
            let text: String
            if row[1] == "agentMessage" { text = obj["text"] as? String ?? "" }
            else {
                text = (obj["content"] as? [[String: Any]] ?? []).map { item in
                    if let text = item["text"] as? String { return text }
                    return "[첨부: \(item["type"] as? String ?? "파일")]"
                }.joined(separator: "\n")
            }
            return ConversationMessage(id: row[0], role: row[1], text: text)
        }
        return (messages, rows.count == 60 ? Int64(rows.last![3]) : nil)
    }
}

struct ConversationExplorer: View {
    @ObservedObject var model: DockModel
    private let reader = ConversationReader()
    @State private var conversations: [LocalConversation] = []
    @State private var selected: String?
    @State private var account = ""
    @State private var search = ""
    @State private var messages: [ConversationMessage] = []
    @State private var cursor: Int64?
    @State private var error: String?
    @State private var loading = false
    @State private var expanded: Set<String> = []
    private var current: LocalConversation? { conversations.first { $0.id == selected } }
    private var roots: [LocalConversation] {
        let ids = Set(conversations.map(\.id))
        return conversations.filter { item in
            (item.parentID == nil || !ids.contains(item.parentID!)) &&
            (search.isEmpty || item.title.localizedCaseInsensitiveContains(search) || conversations.contains { $0.parentID == item.id && $0.title.localizedCaseInsensitiveContains(search) })
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("대화 검색", text: $search).textFieldStyle(.roundedBorder)
                Button("목록 새로고침") { Task { await reload() } }
            }
            if let error { Text(error).font(.callout).foregroundStyle(.secondary) }
            HStack(alignment: .top, spacing: 16) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(roots) { root in
                            let children = conversations.filter { $0.parentID == root.id }
                            HStack(spacing: 4) {
                                if !children.isEmpty {
                                    Button { if expanded.contains(root.id) { expanded.remove(root.id) } else { expanded.insert(root.id) } } label: {
                                        Image(systemName: expanded.contains(root.id) || !search.isEmpty ? "chevron.down" : "chevron.right").frame(width: 16)
                                    }.buttonStyle(.plain).accessibilityLabel("사이드 채팅 펼치기 또는 접기")
                                }
                                row(root, side: false)
                            }
                            if expanded.contains(root.id) || !search.isEmpty {
                                ForEach(children) { child in row(child, side: true).padding(.leading, 22) }
                            }
                        }
                    }
                }.frame(width: 240)
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    if let current {
                        Text(current.title).font(.headline).lineLimit(3)
                        HStack {
                            Picker("실행 계정", selection: $account) {
                                Text("계정 선택").tag("")
                                ForEach(model.presets) { Text($0.displayName).tag($0.id) }
                            }
                            Button("VS Code 새 창에서 열기") {
                                if let preset = model.presets.first(where: { $0.id == account }) {
                                    Task { await model.applyToVSCode(preset, conversationID: current.id) }
                                }
                            }.disabled(account.isEmpty || model.busy || model.refreshingUsage)
                        }
                        Text("읽기 전용 미리보기 · 대화는 선택한 계정의 VS Code에서 이어갑니다. 같은 대화의 동시 작업은 피하세요.")
                            .font(.caption).foregroundStyle(.secondary)
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 16) {
                                if cursor != nil { Button("이전 메시지 보기") { Task { await load(older: true) } }.disabled(loading) }
                                ForEach(messages) { item in
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(item.role == "userMessage" ? "나" : "Codex").font(.caption.bold()).foregroundStyle(.secondary)
                                        Text(item.text).textSelection(.enabled).font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading)
                                    }.padding(12).background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
                                }
                                if loading { ProgressView() }
                                if !loading && messages.isEmpty { Text("표시할 메시지가 없습니다.").foregroundStyle(.secondary) }
                            }
                        }.id(current.id)
                    } else { ContentUnavailableView("대화를 선택하세요", systemImage: "bubble.left.and.bubble.right") }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 560)
        }.task { await reload() }.task(id: selected) { await load() }
    }
    private func row(_ item: LocalConversation, side: Bool) -> some View {
        Button { selected = item.id } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                Text((side ? "사이드 채팅 · " : "") + (item.archived ? "보관됨 · " : "") + item.updated.formatted(date: .abbreviated, time: .omitted))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                .background(selected == item.id ? DockTheme.blue.opacity(0.35) : .clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    private func reload() async {
        do { conversations = try await reader.conversations(); error = nil }
        catch { self.error = error.localizedDescription }
    }
    private func load(older: Bool = false) async {
        guard let id = selected else { return }
        if !older { messages = []; cursor = nil }
        loading = true
        do {
            let page = try await reader.messages(threadID: id, before: older ? cursor : nil)
            guard selected == id, !Task.isCancelled else { return }
            if older { messages.insert(contentsOf: page.messages, at: 0) } else { messages = page.messages }
            cursor = page.cursor; error = nil; loading = false
        } catch { if selected == id { self.error = error.localizedDescription; loading = false } }
    }
}
