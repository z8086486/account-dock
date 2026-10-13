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

    func renameAccount(_ preset: AccountPreset, name: String) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try await AccountVault.shared.renameAccount(preset.id, name: name)
            await loadPresets()
            message = "계정 이름을 저장했습니다."
        } catch { message = error.localizedDescription }
    }
    func loadPresets() async {
        let wasBusy = busy
        busy = true; waitingForKeychain = true
        defer { busy = wasBusy; waitingForKeychain = false }
        do { presets = try await AccountVault.shared.all() }
        catch { message = error.localizedDescription }
    }
    func request(_ action: String = "status") async {
        guard !busy, action == "status" else { return }
        busy = true
        message = nil
        defer { busy = false; connection = nil }
        do {
            appAccounts = (try? await AppIdentityReader.read().accounts) ?? ["codex"].map {
                AppIdentity(id: $0, product: $0, status: "unavailable", email: nil, plan: nil, home: nil, version: nil)
            }
            let updated = try await run(action)
            if updated.codex.status == "error" || updated.codex.status == "unavailable" {
                message = "계정을 확인하지 못했습니다. Codex 설치 및 로그인 상태를 확인하고 다시 시도해 주세요."
                report = updated
                activeAccountID = nil
                return
            }
            report = updated
            lastChecked = Date()
            await registerCurrentAccount()
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
            let value = try await CodexService.report(connection: session, home: home)
            await session.shutdown()
            return value
        } catch { await session.shutdown(); throw error }
    }
    func addAccount(name: String) async {
        guard !busy, !refreshingUsage else { return }
        busy = true; addingAccount = true
        message = "브라우저에서 추가할 계정으로 로그인해 주세요. 현재 앱의 계정은 유지됩니다."
        defer { busy = false; addingAccount = false; canCancelLogin = false; connection = nil }
        var home: URL?
        var added = false
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
            let entry = AccountPreset(id: UUID().uuidString, name: label,
                email: email, plan: result.codex.plan, savedAt: Date(), credential: credential)
            try await AccountVault.shared.upsert(entry, preserveName: label.isEmpty)
            await loadPresets()
            added = true
            message = "계정을 추가했습니다. 사용할 계정은 목록에서 선택하세요. 현재 로그인은 변경하지 않았습니다."
        } catch is CancellationError { message = "계정 추가를 취소했습니다. 현재 로그인은 유지됩니다." }
        catch { message = error.localizedDescription }
        await connection?.shutdown()
        if let home { try? FileManager.default.removeItem(at: home) }
        connection = nil
        if added { await refreshUsage(allowWhileAdding: true) }
    }
    func savePreset(name: String) async {
        guard !busy else { return }
        await request()
        guard !busy else { return }
        busy = true
        defer { busy = false }
        guard let report, connected, supportsPresets, let email = report.codex.email else {
            message = "파일 방식의 Codex 로그인만 저장할 수 있습니다. 공식 Codex 실행 파일이 필요합니다."
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
    func closeDedicated(_ account: AppIdentity) async {
        guard !busy, !refreshingUsage else { return }
        busy = true
        defer { busy = false }
        message = "계정별 VS Code 창에 종료를 요청하고 있습니다."
        do {
            guard account.product == "codex" else { throw DockError.message("계정별 VS Code만 닫을 수 있습니다.") }
            let closed = try await VSCodeIsolation.close(home: account.home)
            appAccounts = try await AppIdentityReader.read().accounts
            message = closed ? "계정별 VS Code 창을 닫았습니다." : "VS Code가 아직 열려 있습니다. 저장 확인 창이나 종료 취소 여부를 확인하세요."
        } catch { message = error.localizedDescription }
    }
    func applyToVSCode(_ preset: AccountPreset) async {
        guard !busy, !refreshingUsage else { return }
        busy = true
        defer { busy = false }
        message = "계정별 VS Code 창을 준비하고 있습니다."
        do {
            guard FileManager.default.isExecutableFile(atPath: VSCodeIsolation.executable.path),
                  VersionService.extensionVersion() != nil else { throw DockError.message("기본 경로에 VS Code와 공식 Codex 확장을 설치해 주세요.") }
            guard let latest = (try await AccountVault.shared.all()).first(where: { $0.id == preset.id }) else {
                throw DockError.message("저장한 계정을 다시 선택해 주세요.")
            }
            let workspace = VSCodeIsolation.workspace(for: latest)
            let home = workspace.home
            try VSCodeIsolation.validateDirectory(home)
            try VSCodeIsolation.validateDirectory(workspace.userData)
            let before = try AuthTransaction.snapshot(home.appendingPathComponent("auth.json"))
            if try VSCodeIsolation.isRunning(workspace) {
                // Reuse the account process without touching tokens, history links or settings.
                guard try AppIdentityReader.storedIdentity(home.path).status == "stored_account" else {
                    throw DockError.message("실행 중인 계정별 VS Code 창의 인증을 확인하지 못했습니다.")
                }
                try VSCodeIsolation.requireMatchingIdentity(before, preset: latest)
                try await VSCodeIsolation.launch(workspace)
                appAccounts = try await AppIdentityReader.read().accounts
                message = "\(latest.displayName) 창을 추가로 열었습니다."
                return
            }
            try VSCodeIsolation.requireStopped(workspace)
            try VSCodeIsolation.prepare(workspace, name: latest.displayName)
            try VSCodeEnvironment.prepare(destination: home, targetSettings: workspace.userData.appendingPathComponent("User/settings.json"))
            // Never overwrite a different identity or an unsupported auth store.
            let identity = try AppIdentityReader.storedIdentity(home.path)
            guard ["stored_account", "no_saved_auth"].contains(identity.status) else {
                throw DockError.message("계정별 VS Code의 인증 저장 방식을 지원하지 않습니다.")
            }
            if let before { try VSCodeIsolation.requireMatchingIdentity(before, preset: latest) }
            // Keep tokens refreshed by VS Code instead of replacing them with an older saved copy.
            var credential = before ?? latest.credential
            var validation = try await UsageReader.read(credential)
            if validation.status == "login_required", before != nil {
                credential = latest.credential
                validation = try await UsageReader.read(credential)
            }
            guard ["available", "partial"].contains(validation.status) else {
                throw DockError.message("인증 유효성을 확인하지 못했습니다. 계정 추가에서 다시 로그인하거나 네트워크를 확인하세요.")
            }
            try AuthTransaction.install(credential, home: home, expected: before) {
                try VSCodeIsolation.validateDirectory(home)
                try VSCodeIsolation.requireStopped(workspace)
            }
            do { try await VSCodeIsolation.launch(workspace) }
            catch {
                do {
                    try AuthTransaction.rollback(before, home: home, expected: credential) {
                        try VSCodeIsolation.validateDirectory(home)
                        try VSCodeIsolation.requireStopped(workspace)
                    }
                } catch {
                    throw DockError.message("계정별 VS Code 창의 실행 상태가 불확실해 인증을 복구하지 않았습니다. 해당 창을 확인하세요.")
                }
                throw DockError.message("계정별 VS Code 창을 열지 못해 이전 인증으로 복구했습니다.")
            }
            appAccounts = try await AppIdentityReader.read().accounts
            message = "\(latest.displayName) 계정별 VS Code 창을 열었습니다."
        } catch { message = error.localizedDescription }
    }
    func registerCurrentAccount() async {
        activeAccountID = nil
        guard let report, connected, supportsPresets, let email = report.codex.email else { return }
        do {
            let credential = try PresetVault.credential(at: report.codex_home, expectedEmail: email)
            let entry = AccountPreset(id: UUID().uuidString,
                name: "", email: email,
                plan: report.codex.plan, savedAt: Date(), credential: credential)
            activeAccountID = try await AccountVault.shared.upsert(entry).id
            await loadPresets()
        } catch { message = "현재 계정을 자동 등록하지 못했습니다. 설정 화면에서 Keychain 접근을 확인해 주세요." }
    }
    func refreshUsage(allowWhileAdding: Bool = false) async {
        guard !refreshingUsage, (!busy || (allowWhileAdding && addingAccount)) else { return }
        guard UserDefaults.standard.object(forKey: "accountDock.usageEnabled") as? Bool ?? true else {
            usage = [:]
            return
        }
        refreshingUsage = true
        let snapshot = presets
        usageLoading = Set(snapshot.map(\.id))
        defer { refreshingUsage = false; usageLoading.removeAll() }
        await UsageBatch.read(snapshot) { id, report in
            guard UserDefaults.standard.object(forKey: "accountDock.usageEnabled") as? Bool ?? true else {
                usage = [:]; return
            }
            if presets.contains(where: { $0.id == id }) { usage[id] = report }
            usageLoading.remove(id)
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
    @State private var renamingPreset: AccountPreset?
    @State private var menuRefresh = 0
    @State private var closingAccount: AppIdentity?
    @State private var showCloseDedicated = false
    @State private var showAdd = false
    @State private var newAccountName = ""
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
                    } else if selection == "updates" { UpdatePanel(center: updates) } else if selection == "access" { SetupPanel(refreshToken: menuRefresh) } else {
                        presetSection
                    }
                    footer
                }.padding(32)
            }.background(DockTheme.canvas)
        }
        .foregroundStyle(ink).tint(accent).preferredColorScheme(.light)
        .multilineTextAlignment(.leading)
        .frame(minWidth: 1020, minHeight: 780)
        .onAppear { updates.canRestart = { !model.busy && !model.refreshingUsage } }
        .task {
            if setupCompleted { await start() } else { showSetup = true }
        }
        .task(id: menuRefresh) {
            guard menuRefresh > 0, setupCompleted else { return }
            while model.busy || model.refreshingUsage {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
            guard !Task.isCancelled else { return }
            switch selection {
            case "accounts": await model.request()
            case "presets":
                await model.loadPresets()
                await model.refreshUsage()
            case "updates": await updates.refresh(online: true)
            default: break
            }
        }
        .sheet(isPresented: $showSetup) {
            SetupPanel(firstLaunch: true) {
                setupCompleted = true; showSetup = false
                Task { await start() }
            }.frame(width: 660, height: 650).interactiveDismissDisabled()
        }
        .sheet(item: $renamingPreset) { preset in
            AccountNameSheet(preset: preset) { name in
                renamingPreset = nil
                Task { await model.renameAccount(preset, name: name) }
            }
        }
        .sheet(isPresented: $showAdd) {
            VStack(alignment: .leading, spacing: 18) {
                Text("계정 추가").font(.title2.weight(.semibold))
                Text("별도 로그인 창에서 계정을 등록합니다. 기존 VS Code의 현재 계정은 변경하지 않습니다.").font(.system(size: 12))
                TextField("계정 이름 (선택)", text: $newAccountName).textFieldStyle(.roundedBorder)
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
        .alert("이 VS Code의 모든 창을 닫을까요?", isPresented: $showCloseDedicated, presenting: closingAccount) { account in
            Button("취소", role: .cancel) {}
            Button("모든 창 닫기") { Task { await model.closeDedicated(account) } }
        } message: { account in
            Text("\(account.email.map { AppAccountPresentation.displayName($0, presets: model.presets) } ?? "선택한 계정") 계정으로 열린 이 VS Code의 모든 창을 닫습니다. 진행 중인 Codex 작업이 중단될 수 있습니다. 저장하지 않은 내용은 VS Code의 저장 확인 또는 복원 설정에 따라 처리됩니다. 기본 VS Code와 다른 VS Code는 유지됩니다.")
        }
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
            nav("설정", icon: "lock.shield", id: "access")
            Spacer()
            Divider()
            Text("v\(ReleaseConfiguration.current.version)").font(.system(size: 12)).foregroundStyle(DockTheme.blue.opacity(0.75)).padding(.vertical, 20)
        }.padding(.horizontal, 22).frame(width: 210)
            .foregroundStyle(DockTheme.blue)
            .background(DockTheme.navy)
            .overlay(alignment: .trailing) { Rectangle().fill(DockTheme.orange).frame(width: 4) }
    }
    private func nav(_ title: String, icon: String, id: String) -> some View {
        Button { selection = id; menuRefresh += 1 } label: {
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
                Text(selection == "accounts" ? "계정 관리" : selection == "updates" ? "업데이트" : selection == "access" ? "설정" : "저장한 계정")
                    .font(.system(size: 29, weight: .semibold))

            }
            Spacer()
            Button { Task { await model.request(); await updates.refresh(); await model.refreshUsage() } } label: {
                Label(model.busy ? "확인 중" : "새로고침", systemImage: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium)).padding(.horizontal, 4).padding(.vertical, 3)
            }.buttonStyle(DockButtonStyle()).disabled(model.busy)
        }
    }
    private var targets: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 13) {
                AppAccountCard(title: "VS Code · Codex", icon: "chevron.left.forwardslash.chevron.right",
                    installed: updates.products.first { $0.id == "codex" }?.installed,
                    accounts: model.appAccounts.filter { $0.product == "codex" },
                    presets: model.presets, busy: model.busy || model.refreshingUsage, canSwitch: true,
                    switchExplanation: "계정별로 여러 창을 열 수 있습니다. 같은 대화의 동시 작업은 피하세요.",
                    onAdd: { newAccountName = ""; showAdd = true },
                    onOpenDedicated: { preset in Task { await model.applyToVSCode(preset) } },
                    onCloseDedicated: { account in closingAccount = account; showCloseDedicated = true })
            }.fixedSize(horizontal: false, vertical: true)
            Text("실제 로그인 상태는 VS Code에서 확인하세요.")
                .font(.system(size: 12)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
        }
    }
    private var presetSection: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("\(model.presets.count)개 계정").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { Task { await model.refreshUsage() } } label: { Label(model.refreshingUsage ? "조회 중…" : "사용량 확인", systemImage: "chart.bar") }
                    .buttonStyle(DockButtonStyle(kind: .quiet)).disabled(model.refreshingUsage || model.presets.isEmpty)
                Button { newAccountName = ""; showAdd = true } label: { Label("계정 추가", systemImage: "plus") }.buttonStyle(DockButtonStyle(kind: .primary)).disabled(model.busy || model.refreshingUsage)

            }
            if model.presets.isEmpty {
                HStack(spacing: 16) {
                    Image(systemName: "person.crop.rectangle.badge.plus").font(.system(size: 25)).foregroundStyle(muted)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("저장한 계정 없음").font(.system(size: 13, weight: .medium))
                        Text("계정 추가를 눌러 로그인하세요.")
                            .font(.system(size: 12)).foregroundStyle(muted)
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
                                Text(preset.displayName).font(.system(size: 14, weight: .semibold))
                                if model.activeAccountID == preset.id { Text("기본 Codex 계정").help("현재 선택한 Codex 인증 저장소의 계정입니다.").font(.system(size: 12, weight: .semibold)).padding(.horizontal, 7).padding(.vertical, 4).background(DockTheme.blue.opacity(0.5), in: Capsule()) }
                            }
                            Text(preset.planLabel).font(.system(size: 12)).foregroundStyle(muted)
                        }
                        Spacer()
                        Button {
                            renamingPreset = preset
                        } label: { Label("이름 변경", systemImage: "pencil") }
                            .buttonStyle(DockButtonStyle(kind: .quiet)).disabled(model.busy)
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
            Spacer()
            if let date = model.lastChecked { Text("마지막 확인 · \(date.formatted(date: .omitted, time: .shortened))") }
        }.font(.system(size: 12)).foregroundStyle(muted).padding(.top, 3)
    }
    private func sectionTitle(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(detail).font(.system(size: 12)).foregroundStyle(muted)
        }
    }
    private func badge(_ title: String, green: Bool) -> some View {
        HStack(spacing: 5) { Circle().fill(green ? ink : muted).frame(width: 5, height: 5); Text(title) }
            .font(.system(size: 12)).foregroundStyle(green ? ink : muted)
            .padding(.horizontal, 9).padding(.vertical, 5).background((green ? ink : muted).opacity(0.08), in: Capsule())
    }
}

private struct AccountNameSheet: View {
    let preset: AccountPreset
    let onSave: (String) -> Void
    @State private var name: String
    @Environment(\.dismiss) private var dismiss

    init(preset: AccountPreset, onSave: @escaping (String) -> Void) {
        self.preset = preset
        self.onSave = onSave
        _name = State(initialValue: preset.name)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("계정 이름 지정").font(.title2.weight(.semibold))
            Text(preset.email)
                .font(.system(size: 12)).foregroundStyle(DockTheme.muted)
            TextField("이름 (선택)", text: $name).textFieldStyle(.plain).padding(13)
                .background(.white, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(DockTheme.navy.opacity(0.15)))
            HStack {
                Spacer()
                Button("취소") { dismiss() }.buttonStyle(DockButtonStyle())
                Button("저장") { onSave(name) }.buttonStyle(DockButtonStyle(kind: .primary))

            }
        }.padding(28).frame(width: 420).background(DockTheme.canvas)
    }
}
