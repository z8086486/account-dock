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
    @Published var report: AccountReport?
    @Published var presets: [AccountPreset] = []
    @Published var busy = false
    @Published var message: String?
    @Published var lastChecked: Date?
    @Published var activeAccountID: String?
    @Published var usage: [String: UsageReport] = [:]
    @Published var usageLoading: Set<String> = []
    @Published var refreshingUsage = false
    private var process: Process?
    var connected: Bool { report?.codex.status == "cached_account" }
    var supportsPresets: Bool { report?.file_presets_supported == true && report?.codex.type == "chatgpt" }

    func loadPresets() {
        do { presets = try PresetVault.all() }
        catch { message = error.localizedDescription }
    }
    func request(_ action: String = "status") async {
        guard !busy else { return }
        if action != "status", !canMutate() { return }
        busy = true
        message = action == "login" ? "브라우저에서 로그인해 주세요. 최대 3분 동안 기다립니다." : nil
        defer { busy = false; process = nil }
        do {
            let updated = try await run(action)
            if updated.codex.status == "error" || updated.codex.status == "unavailable" {
                message = "계정을 확인하지 못했습니다. Codex 설치 및 로그인 상태를 확인하고 다시 시도해 주세요."
                report = updated
                activeAccountID = nil
                return
            }
            report = action == "status" ? updated : try await run("status")
            lastChecked = Date()
            registerCurrentAccount()
            if action != "status" { message = action == "login" ? "로그인이 완료되었습니다." : "공유 저장소에서 로그아웃했습니다. 저장한 계정은 유지됩니다." }
        } catch { report = nil; activeAccountID = nil; message = error.localizedDescription }
    }
    func cancel() { process?.terminate() }
    private func run(_ action: String) async throws -> AccountReport {
        let script = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : Bundle.main.path(forResource: "doctor", ofType: "py")
        guard let script else {
            throw DockError.message("scripts/doctor.py 경로를 실행 인자로 전달해 주세요.")
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["python3", "-B", script, "--show-email", "--action", action, "--codex-home", AccessSetup.home]
        let output = Pipe()
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice
        try task.run()
        process = task
        let data = await Task.detached { output.fileHandleForReading.readDataToEndOfFile() }.value
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw DockError.message("요청이 취소되었거나 진단 도구를 실행하지 못했습니다.") }
        return try JSONDecoder().decode(AccountReport.self, from: data)
    }
    func canMutate() -> Bool {
        let targets = ["com.openai.codex", "com.openai.chat", "com.microsoft.VSCode"]
        let names = NSWorkspace.shared.runningApplications.filter { targets.contains($0.bundleIdentifier ?? "") }
            .compactMap(\.localizedName)
        guard names.isEmpty else {
            message = "\(names.joined(separator: ", "))를 먼저 종료해 주세요. 실행 중인 앱이 공유 인증 정보를 다시 쓰는 것을 방지합니다."
            return false
        }
        return true
    }
    func savePreset(name: String) async {
        guard !busy else { return }
        await request()
        guard let report, connected, supportsPresets, let email = report.codex.email else {
            message = "파일 방식으로 로그인한 ChatGPT 계정만 저장할 수 있습니다. Python 3.11 이상도 필요합니다."
            return
        }
        do {
            let credential = try PresetVault.credential(at: report.codex_home, expectedEmail: email)
            let preset = AccountPreset(id: UUID().uuidString, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                       email: email, plan: report.codex.plan, savedAt: Date(), credential: credential)
            try PresetVault.upsert(preset, preserveName: false)
            loadPresets()
            message = "저장한 계정을 이 Mac의 Keychain에 저장했습니다."
        } catch { message = error.localizedDescription }
    }
    func activate(_ preset: AccountPreset) async {
        guard !busy, canMutate() else { return }
        await request()
        guard let report, report.file_presets_supported,
              ["cached_account", "signed_out"].contains(report.codex.status) else {
            message = "인증 상태와 파일 저장 방식을 먼저 확인해 주세요."
            return
        }
        guard canMutate() else { return }
        do {
            if connected {
                guard let email = report.codex.email, report.codex.type == "chatgpt" else {
                    message = "현재 인증 방식은 자동 백업을 지원하지 않아 전환하지 않았습니다."
                    return
                }
                let backup = AccountPreset(id: UUID().uuidString, name: "전환 전 자동 백업", email: email,
                    plan: report.codex.plan, savedAt: Date(), credential: try PresetVault.credential(at: report.codex_home, expectedEmail: email))
                try PresetVault.upsert(backup)
            }
            let latest = presets.first { $0.id == preset.id } ?? preset
            try PresetVault.restore(latest, home: report.codex_home)
            loadPresets()
            await request()
            if self.report?.codex.status == "cached_account", self.report?.codex.email == preset.email {
                message = "저장한 계정을 공유 저장소에 적용했습니다. 앱에서 다시 확인해 주세요. 인증이 만료되었다면 재로그인이 필요합니다."
            } else {
                message = "파일은 적용했지만 계정 확인에 실패했습니다. 전환 전 자동 백업을 선택해 복원할 수 있습니다."
            }
        } catch { message = error.localizedDescription }
    }
    func registerCurrentAccount() {
        activeAccountID = nil
        guard let report, connected, supportsPresets, let email = report.codex.email else { return }
        do {
            let credential = try PresetVault.credential(at: report.codex_home, expectedEmail: email)
            let entry = AccountPreset(id: UUID().uuidString,
                name: String(email.split(separator: "@").first ?? "계정"), email: email,
                plan: report.codex.plan, savedAt: Date(), credential: credential)
            activeAccountID = try PresetVault.upsert(entry).id
            loadPresets()
        } catch { message = "현재 계정을 자동 등록하지 못했습니다. 접근 및 개인정보 화면에서 Keychain 접근을 확인해 주세요." }
    }
    func refreshUsage() async {
        guard !refreshingUsage else { return }
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
    func remove(_ preset: AccountPreset) {
        do { try PresetVault.delete(preset.id); loadPresets() }
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
                    if let message = model.message {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "info.circle")
                            Text(message).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            if model.busy { Button("취소") { model.cancel() } }
                            else { Button { model.message = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }
                        }.padding(14).background(accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                    }
                    if selection == "accounts" {
                        overview
                        targets
                        presetSection
                    } else if selection == "updates" { UpdatePanel(center: updates) } else if selection == "access" { SetupPanel() } else { presetSection }
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
            Button("삭제", role: .destructive) { model.remove(preset) }
        } message: { _ in Text("Keychain에 저장한 이 계정의 인증 정보가 삭제됩니다. 현재 로그인에는 영향을 주지 않습니다.") }
    }

    private func start() async {
        model.loadPresets()
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
            Text("CONTROL PANEL").font(.system(size: 9, weight: .semibold)).tracking(2).foregroundStyle(DockTheme.blue.opacity(0.75)).padding(.bottom, 14)
            nav("계정 관리", icon: "square.grid.2x2", id: "accounts")
            nav("저장한 계정", icon: "person.crop.rectangle.stack", id: "presets")
            nav("버전 · 업데이트", icon: "arrow.down.circle", id: "updates")
            nav("접근 및 개인정보", icon: "lock.shield", id: "access")
            Spacer()
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 6) { Circle().fill(accent).frame(width: 5, height: 5); Text("ON THIS MAC").tracking(1.5) }
                    .font(.system(size: 9, weight: .semibold))
                Text("계정은 가까이,\n전환은 간단하게.").font(.system(size: 13)).lineSpacing(5).foregroundStyle(DockTheme.blue.opacity(0.75))
            }.padding(.bottom, 28)
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
                Text("ACCOUNT DOCK  /  CONTROL SERIES").font(.system(size: 9, weight: .medium)).tracking(2.5).foregroundStyle(muted)
                Text(selection == "accounts" ? "내 계정, 한눈에." : selection == "updates" ? "버전과 업데이트." : selection == "access" ? "필요한 접근만." : "다음에도, 이 계정으로.")
                    .font(.system(size: 29, weight: .semibold))
                Text(selection == "accounts" ? "연결 상태를 확인하고 저장한 계정으로 전환하세요." : selection == "updates" ? "설치부터 다음 업데이트까지, 한곳에서." : selection == "access" ? "계정 정보가 어디에 쓰이는지 확인하세요." : "이 Mac에 저장한 계정을 관리하세요.")
                    .font(.system(size: 12)).foregroundStyle(muted)
            }
            Spacer()
            DockStripes().frame(height: 62).padding(.trailing, 12)
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
                badge(model.connected ? "CONNECTED · 로컬 계정" : model.report?.codex.status == "signed_out" ? "로그아웃" : "확인 필요", green: model.connected)
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
            HStack {
                Text("앱별 연결을 분리하기 전까지 공유 저장소를 관리합니다.")
                    .font(.system(size: 11)).foregroundStyle(muted)
                Spacer()
                if model.connected {
                    Button("로그아웃") { showLogout = true }.buttonStyle(DockButtonStyle(kind: .quiet)).foregroundStyle(muted).disabled(model.busy)
                }
                Button(model.connected ? "다른 계정 로그인" : "로그인") { Task { await model.request("login") } }
                    .buttonStyle(DockButtonStyle(kind: .primary)).disabled(model.busy)
            }
        }.padding(24).background(.white, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(ink.opacity(0.07)))
    }
    private var targets: some View {
        VStack(alignment: .leading, spacing: 13) {
            sectionTitle("사용 환경", detail: "앱별 실제 계정은 아직 대조 전입니다")
            HStack(spacing: 13) {
                target("ChatGPT", subtitle: "macOS · " + (updates.products.first { $0.id == "chatgpt" }?.installed ?? "미확인"), icon: "bubble.left.and.bubble.right")
                target("VS Code", subtitle: "Codex · " + (updates.products.first { $0.id == "codex" }?.installed ?? "미확인"), icon: "chevron.left.forwardslash.chevron.right")
            }
        }
    }
    private func target(_ title: String, subtitle: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 16)).frame(width: 35, height: 35)
                    .background(ink.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(muted)
                }
                Spacer()
            }
            HStack { Text("개별 계정 연결 준비 중").font(.system(size: 11)).foregroundStyle(muted); Spacer(); Image(systemName: "link").foregroundStyle(muted) }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(ink.opacity(0.07)))
    }
    private var presetSection: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                sectionTitle("저장한 계정", detail: "현재 로그인은 자동 등록 · Codex 사용량 기준")
                Spacer()
                Button { Task { await model.refreshUsage() } } label: { Label(model.refreshingUsage ? "조회 중…" : "사용량 확인", systemImage: "chart.bar") }
                    .buttonStyle(DockButtonStyle(kind: .quiet)).disabled(model.refreshingUsage || model.presets.isEmpty)
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
                                if model.activeAccountID == preset.id { Text("현재 로그인").font(.system(size: 9, weight: .semibold)).padding(.horizontal, 7).padding(.vertical, 4).background(DockTheme.blue.opacity(0.5), in: Capsule()) }
                            }
                            Text(preset.email).font(.system(size: 11)).foregroundStyle(muted)
                        }
                        Spacer()
                        Text(preset.savedAt, style: .date).font(.system(size: 10)).foregroundStyle(muted)
                        Button("선택") { pendingPreset = preset; showSwitch = true }.buttonStyle(DockButtonStyle()).disabled(model.busy || model.activeAccountID == preset.id)
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
                Text("Claude를 비롯한 다른 서비스도 순차적으로 지원할 예정입니다.")
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
