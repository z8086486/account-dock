import SwiftUI

@MainActor
final class AccessSetup: ObservableObject {
    @Published var fileStatus = "아직 확인하지 않음"
    @Published var keychainStatus = "아직 확인하지 않음"
    @Published var keychainReady = false
    @Published var fileReady = false
    @Published var checking = false
    static var home: String {
        UserDefaults.standard.string(forKey: "accountDock.authHome")
        ?? ProcessInfo.processInfo.environment["CODEX_HOME"]
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
    }
    func check() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        let path = URL(fileURLWithPath: Self.home).appendingPathComponent("auth.json").path
        if !FileManager.default.fileExists(atPath: path) {
            fileStatus = "로그인 파일 없음 · 로그인 후 자동 등록됩니다"
            fileReady = true
        } else {
            fileReady = FileManager.default.isReadableFile(atPath: path)
            fileStatus = fileReady ? "읽기 가능 · 현재 계정을 불러올 수 있습니다" : "접근 불가 · 로그인 폴더를 직접 선택해 주세요"
        }
        keychainStatus = "macOS Keychain 접근 요청을 확인해 주세요"
        do {
            keychainReady = try await AccountVault.shared.checkAccess()
            keychainStatus = keychainReady ? "읽기·저장 확인 완료" : "접근을 확인하지 못했습니다"
        } catch {
            keychainReady = false
            keychainStatus = "Keychain 접근을 허용하거나 잠금을 해제해 주세요"
        }
    }
    func selectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: Self.home)
        panel.message = "Codex 로그인 정보가 들어 있는 폴더를 선택하세요. 일반적으로 홈 폴더의 .codex입니다."
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            UserDefaults.standard.set(url.path, forKey: "accountDock.authHome")
            Task { await self.check() }
        }
    }
}

struct DockIcon: View {
    var size: CGFloat = 48
    var body: some View {
        let url = Bundle.main.url(forResource: "AccountDock", withExtension: "png")
            ?? Bundle.module.url(forResource: "AccountDock", withExtension: "png")
        if let url, let image = NSImage(contentsOf: url) {
            Image(nsImage: image).resizable().interpolation(.high).frame(width: size, height: size)
        }
    }
}

struct SetupPanel: View {
    @StateObject private var access = AccessSetup()
    @AppStorage("accountDock.usageEnabled") private var usageEnabled = true
    var refreshToken = 0
    var firstLaunch = false
    var onContinue: () -> Void = {}
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 15) {
                DockIcon(size: 68)
                VStack(alignment: .leading, spacing: 7) {
                    Text(firstLaunch ? "초기 설정" : "접근 권한")
                        .font(.system(size: 25, weight: .semibold))
                    Text("계정 저장에 필요한 접근을 확인합니다.")
                        .font(.system(size: 12)).foregroundStyle(DockTheme.muted)
                }
            }
            accessCard("01", title: "로그인 정보 읽기", reason: "Codex 인증 파일에서 계정을 읽습니다.", status: access.fileStatus) {
                Button("폴더 선택") { access.selectFolder() }.buttonStyle(DockButtonStyle())
            }
            accessCard("02", title: "macOS Keychain", reason: "인증 정보를 이 Mac에 저장합니다. 접근 요청에서 ‘항상 허용’을 선택하세요.", status: access.keychainStatus) {
                Button("Keychain 열기") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/CoreServices/Applications/Keychain Access.app"))
                }.buttonStyle(DockButtonStyle())
            }
            VStack(alignment: .leading, spacing: 10) {
                Toggle("계정별 온라인 사용량 조회", isOn: $usageEnabled).toggleStyle(.switch)
                    .font(.system(size: 13, weight: .medium))
                Text("OpenAI에 계정별 사용량을 요청합니다.")
                    .font(.system(size: 12)).foregroundStyle(DockTheme.muted)
            }.padding(18).background(.white, in: RoundedRectangle(cornerRadius: 13))
            if !firstLaunch { StartupPanel() }
            HStack {
                Button(access.checking ? "확인 중…" : "접근 확인") { Task { await access.check() } }
                    .buttonStyle(DockButtonStyle()).disabled(access.checking)
                Spacer()
                if firstLaunch {
                    Button("시작하기") { onContinue() }.buttonStyle(DockButtonStyle(kind: .primary))
                        .disabled(!access.fileReady || !access.keychainReady)
                }
            }
        }.padding(28).frame(maxWidth: 660).background(DockTheme.canvas)
            .foregroundStyle(DockTheme.navy)
            .task(id: refreshToken) { await access.check() }
    }
    private func accessCard<Content: View>(_ number: String, title: String, reason: String, status: String,
                                          @ViewBuilder action: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(number).font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundStyle(DockTheme.orange)
                Text(title).font(.system(size: 14, weight: .semibold))
                Spacer()
            }
            Text(reason).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(status).font(.system(size: 12)).foregroundStyle(DockTheme.muted)
                Spacer(); action()
            }
        }.padding(18).background(.white, in: RoundedRectangle(cornerRadius: 13))
    }
}
