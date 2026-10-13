import SwiftUI

@main
struct AccountDockApp: App {
    @StateObject private var updates = UpdateCenter()
    init() {
        if let url = Bundle.module.url(forResource: "AccountDock", withExtension: "png"),
           let image = NSImage(contentsOf: url) { NSApplication.shared.applicationIconImage = image }
    }
    var body: some Scene {
        WindowGroup("Account Dock") { Dashboard().environmentObject(updates) }
            .windowStyle(.hiddenTitleBar)
            .defaultSize(width: 1120, height: 850)
            .commands { CommandGroup(after: .appInfo) {
                Button("Account Dock 업데이트 확인…") { updates.checkSelf() }.disabled(!updates.selfUpdateReady)
            } }
    }
}

@MainActor
final class DockModel: ObservableObject {
    @Published var appAccounts: [AppIdentity] = []
    @Published var report: AccountReport?
    @Published var presets: [AccountPreset] = []
    @Published var busy = false
    @Published var message: String?
    @Published var lastChecked: Date?
    @Published var activeAccountID: String?
    @Published var usage: [String: UsageReport] = [:]
    @Published var usageLoading: Set<String> = []
    @Published var refreshingUsage = false
    private var connection: CodexConnection?
    @Published var addingAccount = false
    @Published var canCancelLogin = false
    @Published var waitingForKeychain = false
    var connected: Bool { report?.codex.status == "cached_account" }
    var supportsPresets: Bool { report?.file_presets_supported == true && report?.codex.type == "chatgpt" }

    func loadPresets() async {
        let wasBusy = busy
        busy = true; waitingForKeychain = true
        defer { busy = wasBusy; waitingForKeychain = false }
        do { presets = try await AccountVault.shared.all() }
        catch { message = error.localizedDescription }
    }
    func request(_ action: String = "status") async {
        guard !busy, ["status", "logout"].contains(action) else { return }
        if action != "status", !canMutate() { return }
        busy = true
        message = nil
        defer { busy = false; connection = nil }
        do {
            appAccounts = (try? await AppIdentityReader.read().accounts) ?? ["chatgpt", "codex"].map {
                AppIdentity(id: $0, product: $0, status: "unavailable", email: nil, plan: nil, home: nil, version: nil)
            }
            let updated = try await run(action)
            if updated.codex.status == "error" || updated.codex.status == "unavailable" {
                message = "계정을 확인하지 못했습니다. Codex 설치 및 로그인 상태를 확인하고 다시 시도해 주세요."
                report = updated
                activeAccountID = nil
                return
            }
            report = action == "status" ? updated : try await run("status")
            lastChecked = Date()
            await registerCurrentAccount()
            if action != "status" { message = "공유 저장소에서 로그아웃했습니다. 저장한 계정은 유지됩니다." }
        } catch { report = nil; activeAccountID = nil; message = error.localizedDescription }
    }
    func cancel() { connection?.close() }
    private func run(_ action: String) async throws -> AccountReport {
        let home = URL(fileURLWithPath: AccessSetup.home)
        if !FileManager.default.fileExists(atPath: home.path) {
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let session = try CodexConnection(binary: CodexService.binary(), home: home)
        connection = session
        do {
            try await session.initialize()
            if action == "logout" {
                try ActivityGate.requireIdle(excluding: [session.pid])
                _ = try await session.request("account/logout")
            }
            let value = try await CodexService.report(connection: session, home: home)
            await session.shutdown()
            return value
        } catch { await session.shutdown(); throw error }
    }
    func canMutate() -> Bool {
        do {
            guard !addingAccount, !refreshingUsage else { throw DockError.message("진행 중인 계정 확인이 끝난 뒤 전환해 주세요.") }
            try ActivityGate.requireIdle()
            return true
        } catch { message = error.localizedDescription; return false }
    }
    func addAccount(name: String) async {
        guard !busy else { return }
        busy = true; addingAccount = true
        message = "브라우저에서 추가할 계정으로 로그인해 주세요. 현재 앱의 계정은 유지됩니다."
        defer { busy = false; addingAccount = false; canCancelLogin = false; connection = nil }
        var home: URL?
        do {
            let isolated = try CodexService.temporaryHome(); home = isolated
            try Data("cli_auth_credentials_store = \"file\"\n".utf8).write(to: isolated.appendingPathComponent("config.toml"))
            let session = try CodexConnection(binary: CodexService.binary(), home: isolated)
            connection = session
            var completed: Bool?
            session.notification = { method, parameters in
                if method == "account/login/completed" { completed = parameters["success"] as? Bool ?? false }
            }
            try await session.initialize()
            let login = try await session.request("account/login/start", params: ["type": "chatgpt"])
            guard let raw = login["authUrl"] as? String, let url = URL(string: raw), url.scheme == "https",
                  ["auth.openai.com", "auth.chatgpt.com", "chatgpt.com"].contains(url.host ?? "") else {
                throw DockError.message("공식 로그인 주소를 확인하지 못했습니다.")
            }
            canCancelLogin = true
            guard NSWorkspace.shared.open(url) else { throw DockError.message("로그인 브라우저를 열지 못했습니다.") }
            let deadline = Date().addingTimeInterval(180)
            while completed == nil {
                guard !session.isClosed, !Task.isCancelled else { throw CancellationError() }
                guard Date() < deadline else { throw DockError.message("로그인 시간이 초과되었습니다. 다시 추가해 주세요.") }
                try await Task.sleep(for: .milliseconds(100))
            }
            canCancelLogin = false
            guard completed == true else { throw DockError.message("로그인이 완료되지 않았습니다.") }
            let result = try await CodexService.report(connection: session, home: isolated)
            guard result.codex.type == "chatgpt", let email = result.codex.email, result.file_presets_supported else {
                throw DockError.message("추가할 계정의 인증 정보를 확인하지 못했습니다.")
            }
            let credential = try PresetVault.credential(at: isolated.path, expectedEmail: email)
            let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let entry = AccountPreset(id: UUID().uuidString, name: label.isEmpty ? String(email.split(separator: "@").first ?? "계정") : label,
                email: email, plan: result.codex.plan, savedAt: Date(), credential: credential)
            try await AccountVault.shared.upsert(entry, preserveName: label.isEmpty)
            await loadPresets()
            message = "계정을 추가했습니다. 사용할 계정은 목록에서 선택하세요. 현재 로그인은 변경하지 않았습니다."
        } catch is CancellationError { message = "계정 추가를 취소했습니다. 현재 로그인은 유지됩니다." }
        catch { message = error.localizedDescription }
        await connection?.shutdown()
        if let home { try? FileManager.default.removeItem(at: home) }
    }
    func savePreset(name: String) async {
        guard !busy else { return }
        await request()
        guard !busy else { return }
        busy = true
        defer { busy = false }
        guard let report, connected, supportsPresets, let email = report.codex.email else {
            message = "파일 방식으로 로그인한 ChatGPT 계정만 저장할 수 있습니다. 공식 Codex 실행 파일이 필요합니다."
            return
        }
        do {
            let credential = try PresetVault.credential(at: report.codex_home, expectedEmail: email)
            let preset = AccountPreset(id: UUID().uuidString, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                       email: email, plan: report.codex.plan, savedAt: Date(), credential: credential)
            try await AccountVault.shared.upsert(preset, preserveName: false)
            await loadPresets()
            message = "저장한 계정을 이 Mac의 Keychain에 저장했습니다."
        } catch { message = error.localizedDescription }
    }
    func activate(_ preset: AccountPreset) async {
        guard !busy, canMutate() else { return }
        busy = true
        message = "저장한 인증의 유효성을 확인하고 있습니다. 아직 계정은 변경하지 않았습니다."
        defer { busy = false; connection = nil }
        do {
            let home = URL(fileURLWithPath: AccessSetup.home)
            let before = try AuthTransaction.snapshot(home.appendingPathComponent("auth.json"))
            let current = try await run("status")
            guard current.file_presets_supported, ["cached_account", "signed_out"].contains(current.codex.status) else {
                throw DockError.message("파일 방식 인증을 확인하지 못해 전환하지 않았습니다.")
            }
            let latest = (try await AccountVault.shared.all()).first { $0.id == preset.id } ?? preset
            let validation = try await UsageReader.read(latest.credential)
            guard ["available", "partial"].contains(validation.status) else {
                throw DockError.message(validation.status == "login_required" ? "저장된 인증이 만료되었습니다. 계정 추가에서 다시 로그인해 주세요. 현재 계정은 유지됩니다." : "인증 유효성을 확인하지 못해 전환하지 않았습니다. 네트워크를 확인해 주세요.")
            }
            // Back up only after proving the current metadata still matches the file.
            if current.codex.status == "cached_account" {
                guard let email = current.codex.email, current.codex.type == "chatgpt" else { throw DockError.message("현재 인증의 자동 백업을 지원하지 않아 전환하지 않았습니다.") }
                let credential = try PresetVault.credential(at: home.path, expectedEmail: email)
                guard credential == before else { throw DockError.message("인증 정보가 변경되어 전환을 중단했습니다.") }
                try await AccountVault.shared.upsert(AccountPreset(id: UUID().uuidString, name: "전환 전 자동 백업", email: email, plan: current.codex.plan, savedAt: Date(), credential: credential))
            }
            try AuthTransaction.install(latest.credential, home: home, expected: before) { try ActivityGate.requireIdle() }
            report = AccountReport(codex: AccountInfo(status: "cached_account", type: "chatgpt", email: latest.email, plan: latest.plan, reason: nil), codex_home: home.path, file_presets_supported: true)
            await registerCurrentAccount()
            message = "계정을 적용했습니다. 앱을 다시 열어 로그인 계정을 확인해 주세요."
        } catch { message = error.localizedDescription }
    }
    func applyToVSCode(_ preset: AccountPreset) async {
        guard !busy, !refreshingUsage else { return }
        busy = true
        defer { busy = false }
        message = "전용 VS Code에 적용할 계정을 확인하고 있습니다."
        do {
            guard FileManager.default.isExecutableFile(atPath: VSCodeIsolation.executable.path),
                  VersionService.extensionVersion() != nil else { throw DockError.message("기본 경로에 VS Code와 공식 Codex 확장을 설치해 주세요.") }
            try VSCodeIsolation.requireStopped()
            try VSCodeIsolation.prepare()
            let home = VSCodeIsolation.home
            let before = try AuthTransaction.snapshot(home.appendingPathComponent("auth.json"))
            let inspection = try CodexConnection(binary: CodexService.binary(), home: home)
            do {
                try await inspection.initialize()
                let report = try await CodexService.report(connection: inspection, home: home)
                await inspection.shutdown()
                guard report.file_presets_supported else { throw DockError.message("전용 VS Code의 인증 저장 방식이 변경되었습니다. 파일 방식만 지원합니다.") }
            } catch { await inspection.shutdown(); throw error }
            let latest = (try await AccountVault.shared.all()).first { $0.id == preset.id }
            guard let latest else { throw DockError.message("저장한 계정을 다시 선택해 주세요.") }
            let validation = try await UsageReader.read(latest.credential)
            guard ["available", "partial"].contains(validation.status) else {
                throw DockError.message("저장한 인증이 만료되었거나 유효성을 확인하지 못했습니다. 계정 추가에서 다시 로그인해 주세요. 기존 인증은 유지됩니다.")
            }
            if before != nil {
                let identity = try AppIdentityReader.storedIdentity(home.path)
                guard let email = identity.email else { throw DockError.message("전용 VS Code의 기존 계정을 백업할 수 없어 전환하지 않았습니다.") }
                let credential = try PresetVault.credential(at: home.path, expectedEmail: email)
                guard credential == before else { throw DockError.message("전용 인증이 변경되어 중단했습니다.") }
                try await AccountVault.shared.upsert(AccountPreset(id: UUID().uuidString, name: "VS Code 이전 계정", email: email, plan: identity.plan, savedAt: Date(), credential: credential))
            }
            try AuthTransaction.install(latest.credential, home: home, expected: before) {
                try VSCodeIsolation.validateDirectory(home)
                try VSCodeIsolation.requireStopped()
            }
            do { try await VSCodeIsolation.launch() }
            catch {
                do {
                    try AuthTransaction.rollback(before, home: home, expected: latest.credential) {
                        try VSCodeIsolation.validateDirectory(home)
                        try VSCodeIsolation.requireStopped()
                    }
                } catch {
                    throw DockError.message("VS Code 실행을 확인하지 못했습니다. 실행 중이거나 인증 파일이 변경되어 자동 복구하지 않았습니다. 전용 창의 상태를 확인해 주세요. ChatGPT와 기존 VS Code 인증은 유지됩니다.")
                }
                throw DockError.message("VS Code 실행에 실패해 이전 전용 인증으로 복구했습니다. 기존 앱 계정은 유지됩니다.")
            }
            // Observe the extension process itself using this home; this is not a live-session claim.
            var attached = false
            for _ in 0..<30 {
                let result = try await AppIdentityReader.read()
                appAccounts = result.accounts
                if result.accounts.contains(where: { $0.product == "codex" && $0.home == home.path }) { attached = true; break }
                try await Task.sleep(for: .seconds(1))
            }
            await loadPresets()
            message = attached ? "전용 VS Code의 인증 폴더 연결을 확인했습니다. 확장 설정에서 실제 로그인 계정을 확인해 주세요. ChatGPT와 기존 VS Code 계정은 변경하지 않았습니다." : "전용 폴더에 계정을 적용했지만 확장 연결은 아직 확인되지 않았습니다. 전용 창에서 Codex를 열고 새로고침해 주세요."
        } catch { message = error.localizedDescription }
    }
    func registerCurrentAccount() async {
        activeAccountID = nil
        guard let report, connected, supportsPresets, let email = report.codex.email else { return }
        do {
            let credential = try PresetVault.credential(at: report.codex_home, expectedEmail: email)
            let entry = AccountPreset(id: UUID().uuidString,
                name: String(email.split(separator: "@").first ?? "계정"), email: email,
                plan: report.codex.plan, savedAt: Date(), credential: credential)
            activeAccountID = try await AccountVault.shared.upsert(entry).id
            await loadPresets()
        } catch { message = "현재 계정을 자동 등록하지 못했습니다. 접근 및 개인정보 화면에서 Keychain 접근을 확인해 주세요." }
    }
    func refreshUsage() async {
        guard !refreshingUsage, !busy else { return }
        guard UserDefaults.standard.object(forKey: "accountDock.usageEnabled") as? Bool ?? true else {
            usage = [:]
            return
        }
        refreshingUsage = true
        defer { refreshingUsage = false }
        for account in presets {
            guard UserDefaults.standard.object(forKey: "accountDock.usageEnabled") as? Bool ?? true else { break }
            usageLoading.insert(account.id)
            do { usage[account.id] = try await UsageReader.read(account.credential) }
            catch { usage[account.id] = UsageReport(status: "unavailable", windows: [], activity: [:], checkedAt: nil) }
            usageLoading.remove(account.id)
        }
    }
    func remove(_ preset: AccountPreset) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do { try await AccountVault.shared.delete(preset.id); await loadPresets() }
        catch { message = error.localizedDescription }
    }
}

struct Dashboard: View {
    @StateObject private var model = DockModel()
    @EnvironmentObject private var updates: UpdateCenter
    @State private var selection = "accounts"
    @AppStorage("accountDock.setupCompleted.v1") private var setupCompleted = false
    @State private var showSetup = false
    @State private var showSave = false
    @State private var showAdd = false
    @State private var showVSCode = false
    @State private var newAccountName = ""
    @State private var presetName = ""
    @State private var pendingPreset: AccountPreset?
    @State private var showLogout = false
    @State private var showSwitch = false
    @State private var showDelete = false
    @State private var pendingDelete: AccountPreset?
    private let ink = DockTheme.navy
    private let muted = DockTheme.muted
    private let accent = DockTheme.orange

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            ScrollView {
                VStack(alignment: .leading, spacing: 25) {
                    header
                    if let message = model.waitingForKeychain ? "Keychain 접근 응답을 기다리고 있습니다. macOS 접근 요청을 확인해 주세요." : model.message {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "info.circle")
                            Text(message).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            if model.canCancelLogin { Button("취소") { model.cancel() } }
                            else if !model.waitingForKeychain { Button { model.message = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }
                        }.padding(14).background(accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                    }
                    if selection == "accounts" {
                        targets
                    } else if selection == "updates" { UpdatePanel(center: updates) } else if selection == "access" { SetupPanel() } else {
                        presetSection
                        DisclosureGroup("공유 인증 관리 · 고급") { overview.padding(.top, 12) }
                    }
                    footer
                }.padding(32)
            }.background(DockTheme.canvas)
        }
        .foregroundStyle(ink).tint(accent).preferredColorScheme(.light)
        .frame(minWidth: 1020, minHeight: 780)
        .task {
            if setupCompleted { await start() } else { showSetup = true }
        }
        .sheet(isPresented: $showSetup) {
            SetupPanel(firstLaunch: true) {
                setupCompleted = true; showSetup = false
                Task { await start() }
            }.frame(width: 660, height: 650).interactiveDismissDisabled()
        }
        .sheet(isPresented: $showSave) { saveSheet }
        .sheet(isPresented: $showAdd) {
            VStack(alignment: .leading, spacing: 18) {
                Text("계정 추가").font(.title2.weight(.semibold))
                Text("별도 로그인 창에서 계정을 등록합니다. ChatGPT·VS Code의 현재 계정은 변경하지 않습니다.").font(.system(size: 12))
                TextField("이름 (선택) · 개인용, 업무용", text: $newAccountName).textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button("취소") { showAdd = false }.buttonStyle(DockButtonStyle())
                    Button("브라우저에서 로그인") {
                        let name = newAccountName; showAdd = false
                        Task { await model.addAccount(name: name) }
                    }.buttonStyle(DockButtonStyle(kind: .primary))
                }
            }.padding(28).frame(width: 440).background(DockTheme.canvas)
        }
        .alert("전용 VS Code에 이 계정을 적용할까요?", isPresented: $showVSCode, presenting: pendingPreset) { preset in
            Button("취소", role: .cancel) {}
            Button("적용하고 열기") { Task { await model.applyToVSCode(preset) } }
        } message: { _ in Text("별도의 VS Code 창을 엽니다. ChatGPT·기존 VS Code 계정은 유지됩니다. 기존 설정·MCP·스킬·대화 기록은 복사하지 않으며 전용 창은 별도로 관리됩니다. 다음 전환 전에는 전용 VS Code를 종료해야 합니다.") }
        .alert("공유 저장소에서 로그아웃할까요?", isPresented: $showLogout) {
            Button("취소", role: .cancel) {}
            Button("로그아웃", role: .destructive) { Task { await model.request("logout") } }
        } message: { Text("같은 저장소를 사용하는 ChatGPT, VS Code, Codex CLI에 영향을 줄 수 있습니다. 저장한 계정은 유지됩니다.") }
        .alert("이 계정으로 전환할까요?", isPresented: $showSwitch, presenting: pendingPreset) { preset in
            Button("취소", role: .cancel) {}
            Button("전환") { Task { await model.activate(preset) } }
        } message: { _ in Text("현재 계정은 Keychain에 자동 백업합니다. 공유 저장소를 사용하는 앱에 함께 적용되며, 만료된 인증은 다시 로그인해야 합니다.") }
        .alert("저장한 계정을 삭제할까요?", isPresented: $showDelete, presenting: pendingDelete) { preset in
            Button("취소", role: .cancel) {}
            Button("삭제", role: .destructive) { Task { await model.remove(preset) } }
        } message: { _ in Text("Keychain에 저장한 이 계정의 인증 정보가 삭제됩니다. 현재 로그인에는 영향을 주지 않습니다.") }
    }

    private func start() async {
        await model.loadPresets()
        await model.request()
        await updates.refresh()
        await model.refreshUsage()
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                DockIcon(size: 42)
                Text("Account Dock").font(.system(size: 16, weight: .semibold))
            }.padding(.top, 40).padding(.bottom, 42)
            nav("계정 관리", icon: "square.grid.2x2", id: "accounts")
            nav("저장한 계정", icon: "person.crop.rectangle.stack", id: "presets")
            nav("버전 · 업데이트", icon: "arrow.down.circle", id: "updates")
            nav("접근 및 개인정보", icon: "lock.shield", id: "access")
            Spacer()
            Text("계정 정보는 이 Mac에 보관됩니다.").font(.system(size: 10)).foregroundStyle(DockTheme.blue.opacity(0.75)).padding(.bottom, 20)
            Divider()
            Text("v\(ReleaseConfiguration.current.version) · PREVIEW").font(.system(size: 10)).foregroundStyle(DockTheme.blue.opacity(0.75)).padding(.vertical, 20)
        }.padding(.horizontal, 22).frame(width: 210)
            .foregroundStyle(DockTheme.blue)
            .background(DockTheme.navy)
            .overlay(alignment: .trailing) { Rectangle().fill(DockTheme.orange).frame(width: 4) }
    }
    private func nav(_ title: String, icon: String, id: String) -> some View {
        Button { selection = id } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).frame(width: 18)
                Text(title).font(.system(size: 12, weight: selection == id ? .semibold : .regular))
                Spacer()
            }.padding(12).foregroundStyle(selection == id ? ink : DockTheme.blue)
                .background(selection == id ? DockTheme.blue : Color.clear, in: RoundedRectangle(cornerRadius: 9))
                .overlay(alignment: .leading) { if selection == id { RoundedRectangle(cornerRadius: 2).fill(accent).frame(width: 3, height: 18) } }
        }.buttonStyle(.plain).padding(.bottom, 5)
    }
    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 9) {
                Text(selection == "accounts" ? "내 계정, 한눈에." : selection == "updates" ? "버전과 업데이트." : selection == "access" ? "필요한 접근만." : "다음에도, 이 계정으로.")
                    .font(.system(size: 29, weight: .semibold))
                Text(selection == "accounts" ? "연결 상태를 확인하고 저장한 계정으로 전환하세요." : selection == "updates" ? "설치부터 다음 업데이트까지, 한곳에서." : selection == "access" ? "계정 정보가 어디에 쓰이는지 확인하세요." : "이 Mac에 저장한 계정을 관리하세요.")
                    .font(.system(size: 12)).foregroundStyle(muted)
            }
            Spacer()
            Button { Task { await model.request(); await updates.refresh(); await model.refreshUsage() } } label: {
                Label(model.busy ? "확인 중" : "새로고침", systemImage: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium)).padding(.horizontal, 4).padding(.vertical, 3)
            }.buttonStyle(DockButtonStyle()).disabled(model.busy)
        }
    }
    private var overview: some View {
        VStack(alignment: .leading, spacing: 19) {
            HStack {
                Label("OpenAI · 공유 계정", systemImage: "person.crop.circle").font(.system(size: 12, weight: .medium))
                Spacer()
                badge(model.connected ? "저장소 계정" : model.report?.codex.status == "signed_out" ? "로그아웃" : "확인 필요", green: model.connected)
            }
            HStack(spacing: 15) {
                Text(model.connected ? String((model.report?.codex.email ?? "A").prefix(1)).uppercased() : "—")
                    .font(.system(size: 23, weight: .medium)).frame(width: 54, height: 54)
                    .background(DockTheme.blue, in: RoundedRectangle(cornerRadius: 17))
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.report?.codex.email ?? (model.busy ? "계정을 확인하고 있어요" : model.report?.codex.status == "signed_out" ? "연결된 계정 없음" : "계정 확인 필요"))
                        .font(.system(size: 18, weight: .medium)).textSelection(.enabled)
                    Text(model.report?.codex.plan.map { "\($0.uppercased()) PLAN" } ?? "OpenAI account")
                        .font(.system(size: 10, weight: .medium)).tracking(1.5).foregroundStyle(muted)
                }
            }
            Divider().opacity(0.5)
            Menu("공유 계정 전환") {
                ForEach(model.presets) { preset in
                    Button(preset.name) { pendingPreset = preset; showSwitch = true }
                        .disabled(model.activeAccountID == preset.id)
                }
            }.disabled(model.busy || model.refreshingUsage || model.presets.isEmpty)
            HStack {
                Text("계정 추가는 별도로 로그인하며, 로그아웃은 공유 저장소에 적용됩니다.")
                    .font(.system(size: 11)).foregroundStyle(muted)
                Spacer()
                if model.connected {
                    Button("로그아웃") { showLogout = true }.buttonStyle(DockButtonStyle(kind: .quiet)).foregroundStyle(muted).disabled(model.busy)
                }
                Button("계정 추가") { newAccountName = ""; showAdd = true }
                    .buttonStyle(DockButtonStyle(kind: .primary)).disabled(model.busy)
            }
        }.padding(24).background(.white, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(ink.opacity(0.07)))
    }
    private var targets: some View {
        VStack(alignment: .leading, spacing: 13) {
            sectionTitle("앱별 계정", detail: "현재 연결 계정을 확인하고, 앱별로 사용할 계정을 선택하세요")
            HStack(alignment: .top, spacing: 13) {
                AppAccountCard(title: "ChatGPT", icon: "bubble.left.and.bubble.right",
                    installed: updates.products.first { $0.id == "chatgpt" }?.installed,
                    accounts: model.appAccounts.filter { $0.product == "chatgpt" },
                    presets: model.presets, busy: model.busy || model.refreshingUsage, canSwitch: false,
                    switchExplanation: "ChatGPT 앱만 바꾸는 독립 전환은 아직 지원하지 않습니다. 표시된 정보는 앱의 Codex 인증 저장소 기준입니다.",
                    onSwitch: { _ in }, onAdd: { newAccountName = ""; showAdd = true })
                AppAccountCard(title: "VS Code · Codex", icon: "chevron.left.forwardslash.chevron.right",
                    installed: updates.products.first { $0.id == "codex" }?.installed,
                    accounts: model.appAccounts.filter { $0.product == "codex" },
                    presets: model.presets, busy: model.busy || model.refreshingUsage, canSwitch: true,
                    switchExplanation: "현재는 전용 창만 전환합니다. 기존 창의 테마·기록을 유지하는 전환은 준비 중입니다. 전용 VS Code를 종료한 뒤 선택해 주세요.",
                    onSwitch: { preset in pendingPreset = preset; showVSCode = true },
                    onAdd: { newAccountName = ""; showAdd = true })
            }.fixedSize(horizontal: false, vertical: true)
            Text("저장소의 계정 정보입니다. 실행 중 세션은 아직 직접 확인하지 못하므로, 실제 앱에 표시된 계정과 다를 수 있습니다.")
                .font(.system(size: 11)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
        }
    }
    private var presetSection: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                sectionTitle("저장한 계정", detail: "현재 로그인은 자동 등록 · Codex 사용량 기준")
                Spacer()
                Button { Task { await model.refreshUsage() } } label: { Label(model.refreshingUsage ? "조회 중…" : "사용량 확인", systemImage: "chart.bar") }
                    .buttonStyle(DockButtonStyle(kind: .quiet)).disabled(model.refreshingUsage || model.presets.isEmpty)
                Button { newAccountName = ""; showAdd = true } label: { Label("계정 추가", systemImage: "plus") }.buttonStyle(DockButtonStyle(kind: .primary)).disabled(model.busy)
                Button { presetName = ""; showSave = true } label: { Label("계정 이름 지정", systemImage: "pencil") }
                    .font(.system(size: 11)).buttonStyle(DockButtonStyle(kind: .quiet))
                    .disabled(!model.connected || !model.supportsPresets || model.busy)
            }
            if model.presets.isEmpty {
                HStack(spacing: 16) {
                    Image(systemName: "person.crop.rectangle.badge.plus").font(.system(size: 25)).foregroundStyle(muted)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("자주 쓰는 계정을 저장해 두세요").font(.system(size: 13, weight: .medium))
                        Text("개인용, 업무용처럼 이름을 붙여 다음에 목록에서 선택할 수 있어요.")
                            .font(.system(size: 11)).foregroundStyle(muted)
                    }
                    Spacer()
                }.padding(24).frame(maxWidth: .infinity)
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(ink.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
            } else {
                ForEach(model.presets) { preset in
                    VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 13) {
                        Image(systemName: "person.crop.circle.fill").font(.system(size: 28)).foregroundStyle(accent.opacity(0.7))
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 8) {
                                Text(preset.name).font(.system(size: 13, weight: .medium))
                                if model.activeAccountID == preset.id { Text("공유 계정").font(.system(size: 9, weight: .semibold)).padding(.horizontal, 7).padding(.vertical, 4).background(DockTheme.blue.opacity(0.5), in: Capsule()) }
                            }
                            Text(preset.email).font(.system(size: 11)).foregroundStyle(muted)
                        }
                        Spacer()
                        Text(preset.savedAt, style: .date).font(.system(size: 10)).foregroundStyle(muted)
                        Button { pendingDelete = preset; showDelete = true } label: { Image(systemName: "trash").accessibilityLabel("저장한 계정 삭제") }
                            .buttonStyle(DockButtonStyle(kind: .quiet)).disabled(model.busy || model.activeAccountID == preset.id)
                    }
                    Divider().opacity(0.5)
                    AccountUsageView(report: model.usage[preset.id], loading: model.usageLoading.contains(preset.id))
                    }.padding(18).background(.white, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }
    private var footer: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text("독립적으로 개발된 앱 · OpenAI 및 Anthropic의 공식 제품이 아닙니다.")
            }
            Spacer()
            if let date = model.lastChecked { Text(date, style: .time) }
        }.font(.system(size: 9)).foregroundStyle(muted).padding(.top, 3)
    }
    private func sectionTitle(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(detail).font(.system(size: 10)).foregroundStyle(muted)
        }
    }
    private func badge(_ title: String, green: Bool) -> some View {
        HStack(spacing: 5) { Circle().fill(green ? ink : muted).frame(width: 5, height: 5); Text(title) }
            .font(.system(size: 10)).foregroundStyle(green ? ink : muted)
            .padding(.horizontal, 9).padding(.vertical, 5).background((green ? ink : muted).opacity(0.08), in: Capsule())
    }
    private var saveSheet: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("계정 이름 지정").font(.title2.weight(.semibold))
            Text("개인용, 업무용처럼 알아보기 쉬운 이름을 정하세요. 같은 계정은 중복 등록하지 않습니다.")
                .font(.system(size: 12)).foregroundStyle(muted)
            TextField("예: 개인용, 업무용", text: $presetName).textFieldStyle(.plain).padding(13).background(.white, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(ink.opacity(0.15)))
            HStack {
                Spacer()
                Button("취소") { showSave = false }.buttonStyle(DockButtonStyle())
                Button("저장") { let name = presetName; showSave = false; Task { await model.savePreset(name: name) } }
                    .buttonStyle(DockButtonStyle(kind: .primary))
                    .disabled(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(28).frame(width: 420).background(DockTheme.canvas)
    }
}
