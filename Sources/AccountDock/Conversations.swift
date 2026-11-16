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

/// Reads conversation data with SQL writes blocked; SQLite manages WAL/SHM sidecars.
actor ConversationReader {
    let home: URL
    let linksURL: URL
    init(home: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"), linksURL: URL = SideChatLinks.url) { self.home = home; self.linksURL = linksURL }
    private struct ReadFailure: LocalizedError {
        let code: Int32
        let detail: String
        var retryable: Bool { [SQLITE_BUSY, SQLITE_LOCKED, SQLITE_SCHEMA].contains(code & 0xff) }
        var errorDescription: String? {
            if retryable { return "Codex가 대화 기록을 갱신 중입니다. 잠시 후 새로고침해 주세요." }
            if detail.contains("no such table") || detail.contains("no such column") {
                return "현재 대화 저장소 형식을 지원하지 않습니다. 앱 업데이트를 확인해 주세요."
            }
            if code & 0xff == SQLITE_INTERRUPT { return "대화 조회가 지연되고 있습니다. 다시 시도해 주세요." }
            return "대화 저장소를 읽지 못했습니다. 다시 시도해 주세요. (SQLite \(code))"
        }
    }
    private func query(_ file: String, sql: String, values: [String] = []) async throws -> [[String]] {
        let delays = [150, 250, 400, 600, 800]
        for attempt in 0...delays.count {
            try Task.checkCancellation()
            do { return try queryOnce(file, sql: sql, values: values) }
            catch let failure as ReadFailure where failure.retryable && attempt < delays.count {
                // Close the read connection before yielding; do not hold a read transaction
                // while Codex finishes its write or schema migration.
                try await Task.sleep(for: .milliseconds(delays[attempt]))
            }
        }
        throw CancellationError() // Every final attempt returns or throws above.
    }
    private func queryOnce(_ file: String, sql: String, values: [String]) throws -> [[String]] {
        let path = home.appendingPathComponent(file)
        guard FileManager.default.fileExists(atPath: path.path) else { throw DockError.message("로컬 대화 저장소를 찾지 못했습니다.") }
        var db: OpaquePointer?
        guard QueryOnlyDatabase.open(path.path, database: &db) == SQLITE_OK else {
            if let db { sqlite3_close(db) }; throw DockError.message("대화 저장소를 읽지 못했습니다.")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 100)
        sqlite3_progress_handler(db, 2_000_000, { _ in 1 }, nil)
        var stmt: OpaquePointer?
        let prepared = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard prepared == SQLITE_OK else {
            sqlite3_finalize(stmt)
            throw ReadFailure(code: prepared, detail: String(cString: sqlite3_errmsg(db)))
        }
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
        guard result == SQLITE_DONE else { throw ReadFailure(code: result, detail: String(cString: sqlite3_errmsg(db))) }
        return rows
    }
    func conversations() async throws -> [LocalConversation] {
        let links = try SideChatLinks.read(at: linksURL)
        return try await query("state_5.sqlite", sql: """
            SELECT id, attached_thread_parent_id, COALESCE(NULLIF(name,''),NULLIF(title,''),'제목 없는 대화'), updated_at, archived
            FROM threads WHERE (thread_source = 'user' OR (thread_source IS NULL AND source IN ('vscode','cli','exec')))
            ORDER BY updated_at DESC LIMIT 5000
            """).compactMap { row in
                guard UUID(uuidString: row[0]) != nil else { return nil }
                return LocalConversation(id: row[0], parentID: row[1].isEmpty ? links[row[0]] : row[1],
                    title: String(row[2].prefix(300)), updated: Date(timeIntervalSince1970: Double(row[3]) ?? 0), archived: row[4] == "1")
            }
    }
    func hasChildren(threadID: String) async throws -> Bool {
        if !(try await query("state_5.sqlite", sql: "SELECT id FROM threads WHERE attached_thread_parent_id = ? LIMIT 1", values: [threadID])).isEmpty { return true }
        for (child, parent) in try SideChatLinks.read(at: linksURL) where parent == threadID {
            if !(try await query("state_5.sqlite", sql: "SELECT id FROM threads WHERE id = ? LIMIT 1", values: [child])).isEmpty { return true }
        }
        return false
    }
    func messages(threadID: String, before: Int64? = nil) async throws -> (messages: [ConversationMessage], cursor: Int64?) {
        guard UUID(uuidString: threadID) != nil else { throw DockError.message("올바른 대화 ID가 아닙니다.") }
        let rows = try await query("thread_history_1.sqlite", sql: """
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
    @AppStorage("accountDock.conversationAccount") private var account = ""
    @State private var search = ""
    @State private var messages: [ConversationMessage] = []
    @State private var loadedConversationID: String?
    @State private var cursor: Int64?
    @State private var error: String?
    @State private var loading = false
    @State private var refreshingList = false
    @FocusState private var searchFocused: Bool
    @State private var expanded: Set<String> = []
    @State private var selectedQuote: String?
    @State private var sideParent: String?
    @State private var showSideChat = false
    @State private var pendingDeletion: LocalConversation?
    @State private var showDeletion = false
    private var selectedPreset: AccountPreset? { model.presets.first { $0.id == account } }
    private var current: LocalConversation? { conversations.first { $0.id == selected } }
    private var roots: [LocalConversation] {
        let ids = Set(conversations.map(\.id))
        var matches = Set(conversations.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }.map(\.id))
        let parents = Dictionary(uniqueKeysWithValues: conversations.compactMap { item in item.parentID.map { (item.id, $0) } })
        for id in Array(matches) {
            var next = parents[id]
            var seen: Set<String> = [id]
            while let parent = next, seen.insert(parent).inserted { matches.insert(parent); next = parents[parent] }
        }
        return conversations.filter { ($0.parentID == nil || !ids.contains($0.parentID!)) && matches.contains($0.id) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                HStack(spacing: 9) {
                    Image(systemName: "magnifyingglass").foregroundStyle(DockTheme.muted)
                    TextField("대화 검색", text: $search)
                        .textFieldStyle(.plain).font(.system(size: 13)).focused($searchFocused)
                    if !search.isEmpty {
                        Button { search = ""; searchFocused = true } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(DockTheme.muted)
                        }.buttonStyle(.plain).help("검색 지우기").accessibilityLabel("검색 지우기")
                    }
                }.modifier(DockFieldSurface(focused: searchFocused))
                Button { Task { await reload(); await load() } } label: {
                    HStack(spacing: 7) {
                        if refreshingList { ProgressView().controlSize(.small) }
                        else { Image(systemName: "arrow.clockwise") }
                        Text("새로고침")
                    }.frame(height: 22)
                }.buttonStyle(DockButtonStyle()).fixedSize()
                    .help("대화 목록과 메시지 새로고침").disabled(refreshingList || loading || model.busy)
            }
            if let error { Text(error).font(.callout).foregroundStyle(.secondary) }
            HStack(alignment: .top, spacing: 16) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(roots) { root in treeRow(root, ancestors: []) }
                        if roots.isEmpty && !refreshingList {
                            Text(search.isEmpty ? "저장된 대화가 없습니다." : "검색 결과가 없습니다.")
                                .font(.system(size: 12)).foregroundStyle(DockTheme.muted).padding(.top, 24)
                        }
                    }
                }.frame(width: 240)
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    if let current {
                        HStack(alignment: .top) {
                            Text(current.title).font(.headline).lineLimit(3)
                            Spacer()
                            Button { pendingDeletion = current; showDeletion = true } label: {
                                Image(systemName: "trash")
                            }.buttonStyle(DockButtonStyle(kind: .quiet))
                                .help("이 대화 완전 삭제").accessibilityLabel("이 대화 완전 삭제")
                                .disabled(model.busy || model.refreshingUsage)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("실행 계정").font(.system(size: 11, weight: .medium)).foregroundStyle(DockTheme.muted)
                            HStack(spacing: 10) {
                                ConversationAccountMenu(presets: model.presets, selection: $account)
                                    .disabled(model.busy || model.refreshingUsage)
                                Button {
                                    if let preset = selectedPreset { Task { await model.applyToVSCode(preset, conversationID: current.id) } }
                                } label: {
                                    Label("VS Code 새 창에서 열기", systemImage: "arrow.up.forward.app")
                                        .frame(height: 22)
                                }.buttonStyle(DockButtonStyle(kind: .primary)).fixedSize()
                                    .disabled(selectedPreset == nil || model.busy || model.refreshingUsage)
                            }
                        }
                        HStack {
                            Text("대화 기록").font(.system(size: 12, weight: .medium)).foregroundStyle(DockTheme.muted)
                            Spacer()
                            if cursor != nil {
                                Button { Task { await load(older: true) } } label: {
                                    HStack(spacing: 7) {
                                        if loading { ProgressView().controlSize(.small) }
                                        else { Image(systemName: "arrow.up") }
                                        Text("이전 메시지 보기")
                                    }
                                }.buttonStyle(DockButtonStyle()).disabled(loading)
                            } else if loading { ProgressView().controlSize(.small) }
                        }
                        ConversationTranscript(messages: messages) { quote in
                            selectedQuote = quote
                            sideParent = current.id
                            showSideChat = true
                        }.id(current.id)
                            .background(.white.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    } else { ContentUnavailableView("대화를 선택하세요", systemImage: "bubble.left.and.bubble.right") }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 620)
        }.task { await reload() }.task(id: selected) { await load() }
        .alert("대화를 완전히 삭제할까요?", isPresented: $showDeletion) {
            Button("취소", role: .cancel) { pendingDeletion = nil }
            Button("완전 삭제", role: .destructive) {
                guard let item = pendingDeletion else { return }
                Task {
                    if await model.deleteConversation(item.id) {
                        if selected == item.id { selected = nil; messages = []; cursor = nil }
                        expanded.remove(item.id)
                    }
                    pendingDeletion = nil
                    await reload()
                }
            }
        } message: {
            Text("‘\(pendingDeletion?.title ?? "")’의 이 Mac에 저장된 대화 기록을 삭제합니다. 복구할 수 없습니다. 하위 대화는 먼저 개별 삭제해야 합니다.")
        }
        .sheet(isPresented: $showSideChat) {
            VStack(alignment: .leading, spacing: 18) {
                Text("사이드 채팅에 질문하기").font(.title2.bold())
                ScrollView { Text(selectedQuote ?? "").font(.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(14) }
                    .frame(maxHeight: 180).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 6) {
                    Text("실행 계정").font(.system(size: 11, weight: .medium)).foregroundStyle(DockTheme.muted)
                    ConversationAccountMenu(presets: model.presets, selection: $account)
                }
                Text("선택한 내용과 원본 대화의 문맥을 이어받습니다. 질문은 새 VS Code 창에서 입력하세요.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("취소") { showSideChat = false }.buttonStyle(DockButtonStyle()).keyboardShortcut(.cancelAction)
                    Button("사이드 채팅 열기") {
                        guard let parent = sideParent, let quote = selectedQuote,
                              let preset = model.presets.first(where: { $0.id == account }) else { return }
                        showSideChat = false
                        Task {
                            await model.applyToVSCode(preset, sideChat: SideChatRequest(parentID: parent, quote: quote))
                            expanded.insert(parent)
                            await reload()
                        }
                    }.buttonStyle(DockButtonStyle(kind: .primary)).disabled(selectedPreset == nil || model.busy || model.refreshingUsage)
                }
            }.padding(24).frame(width: 520)
        }
    }
    private func treeRow(_ item: LocalConversation, ancestors: Set<String>) -> AnyView {
        let children = conversations.filter { $0.parentID == item.id && !ancestors.contains($0.id) && $0.id != item.id }
        let open = expanded.contains(item.id) || !search.isEmpty
        return AnyView(VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 2) {
                if !children.isEmpty {
                    Button { if open { expanded.remove(item.id) } else { expanded.insert(item.id) } } label: {
                        Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption).frame(width: 16)
                    }.buttonStyle(.plain).accessibilityLabel("사이드 채팅 펼치기 또는 접기")
                }
                row(item, side: !ancestors.isEmpty)
            }
            if open && ancestors.count < 20 {
                ForEach(children) { child in treeRow(child, ancestors: ancestors.union([item.id])).padding(.leading, 14) }
            }
        })
    }
    private func row(_ item: LocalConversation, side: Bool) -> some View {
        Button { selected = item.id } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                Text((side ? "사이드 채팅 · " : "") + (item.archived ? "보관됨 · " : "") + item.updated.formatted(date: .abbreviated, time: .omitted))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                .background(selected == item.id ? DockTheme.blue.opacity(0.35) : .clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    private func reload() async {
        guard !refreshingList else { return }
        refreshingList = true
        defer { refreshingList = false }
        do {
            conversations = try await reader.conversations(); error = nil
            if let selected, !conversations.contains(where: { $0.id == selected }) { self.selected = nil; messages = []; cursor = nil }
        }
        catch { self.error = error.localizedDescription }
    }
    private func load(older: Bool = false) async {
        guard let id = selected else { loading = false; return }
        if loadedConversationID != id { messages = []; cursor = nil; loadedConversationID = nil }
        loading = true
        do {
            let page = try await reader.messages(threadID: id, before: older ? cursor : nil)
            guard selected == id, !Task.isCancelled else { return }
            if older { messages.insert(contentsOf: page.messages, at: 0) } else { messages = page.messages }
            cursor = page.cursor; loadedConversationID = id; error = nil; loading = false
        } catch is CancellationError {
            // A newer selection owns the loading state.
        } catch { if selected == id { self.error = error.localizedDescription; loading = false } }
    }
}


struct ConversationAccountMenu: View {
    let presets: [AccountPreset]
    @Binding var selection: String
    @State private var presented = false
    @State private var hovered: String?
    private var selected: AccountPreset? { presets.first { $0.id == selection } }
    var body: some View {
        Button { presented.toggle() } label: {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle").font(.system(size: 17)).foregroundStyle(DockTheme.muted)
                Text(selected?.displayName ?? "계정 선택").font(.system(size: 13, weight: .medium)).lineLimit(1).layoutPriority(1)
                Spacer(minLength: 4)
                if let selected {
                    Text(selected.planLabel).font(.system(size: 10, weight: .medium)).lineLimit(1)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(DockTheme.blue.opacity(0.28), in: Capsule())
                }
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(DockTheme.muted)
            }.frame(maxWidth: .infinity).modifier(DockFieldSurface(focused: presented))
                .contentShape(RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain)
            .accessibilityLabel("실행 계정").accessibilityValue(selected?.displayName ?? "계정 선택")
            .popover(isPresented: $presented, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("실행 계정").font(.system(size: 12, weight: .semibold)).foregroundStyle(DockTheme.muted).padding(10)
                    if presets.isEmpty { Text("저장한 계정이 없습니다.").font(.callout).padding(10) }
                    ForEach(presets) { preset in
                        Button { selection = preset.id; presented = false } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "person.crop.circle").font(.system(size: 20)).foregroundStyle(DockTheme.muted)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(preset.displayName).font(.system(size: 13, weight: .medium)).lineLimit(2)
                                    Text(preset.planLabel).font(.system(size: 11)).foregroundStyle(DockTheme.muted)
                                }
                                Spacer(minLength: 8)
                                if selection == preset.id { Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)) }
                            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                .background(DockTheme.blue.opacity(selection == preset.id ? 0.3 : hovered == preset.id ? 0.15 : 0), in: RoundedRectangle(cornerRadius: 8))
                                .contentShape(RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain).onHover { hovered = $0 ? preset.id : nil }
                    }
                }.padding(6).frame(width: 300).foregroundStyle(DockTheme.navy)
            }
    }
}
