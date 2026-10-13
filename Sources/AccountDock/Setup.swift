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
    func check() {
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
        let probe = AccountPreset(id: UUID().uuidString, name: "access-check", email: "", plan: nil,
                                  savedAt: Date(), credential: Data("access-check".utf8))
        let service = "app.accountdock.access-check"
        defer { try? PresetVault.delete(probe.id, serviceName: service) }
        do {
            try PresetVault.save(probe, serviceName: service)
            let values = try PresetVault.all(serviceName: service)
            keychainReady = values.contains { $0.id == probe.id }
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
            self.check()
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
    var firstLaunch = false
    var onContinue: () -> Void = {}
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 15) {
                DockIcon(size: 68)
                VStack(alignment: .leading, spacing: 7) {
                    Text(firstLaunch ? "계정을 모으기 전에." : "접근 및 개인정보")
                        .font(.system(size: 25, weight: .semibold))
                    Text("필요한 접근과 사용 목적을 먼저 확인해 주세요.")
                        .font(.system(size: 12)).foregroundStyle(DockTheme.muted)
                }
            }
            accessCard("01", title: "로그인 정보 읽기", reason: "현재 로그인한 계정을 찾아 저장한 계정에 자동 등록합니다. 선택한 Codex 폴더의 인증 파일을 사용합니다. 앱별 표시는 해당 앱의 실행 경로와 인증 폴더도 확인합니다.", status: access.fileStatus) {
                Button("폴더 선택") { access.selectFolder() }.buttonStyle(DockButtonStyle())
            }
            accessCard("02", title: "macOS Keychain", reason: "계정을 다시 선택할 수 있도록 인증 정보를 암호화해 이 Mac에 보관합니다. macOS 접근 요청이 나타나면 허용해 주세요.", status: access.keychainStatus) {
                Button("Keychain 열기") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/CoreServices/Applications/Keychain Access.app"))
                }.buttonStyle(DockButtonStyle())
            }
            VStack(alignment: .leading, spacing: 10) {
                Toggle("계정별 온라인 사용량 조회", isOn: $usageEnabled).toggleStyle(.switch)
                    .font(.system(size: 13, weight: .medium))
                Text("저장한 계정으로 OpenAI에 인증해 남은 한도를 조회합니다. 인증 정보는 명령줄이나 로그에 남기지 않습니다. 별도 macOS 권한은 필요 없으며 언제든 끌 수 있습니다.")
                    .font(.system(size: 11)).foregroundStyle(DockTheme.muted)
            }.padding(18).background(.white, in: RoundedRectangle(cornerRadius: 13))
            Text("현재 기능에는 전체 디스크 접근·화면 기록·손쉬운 사용 권한이 필요하지 않습니다.")
                .font(.system(size: 10)).foregroundStyle(DockTheme.muted)
            HStack {
                Button(access.checking ? "확인 중…" : "접근 확인") { access.check() }
                    .buttonStyle(DockButtonStyle()).disabled(access.checking)
                Spacer()
                if firstLaunch {
                    Button("시작하기") { onContinue() }.buttonStyle(DockButtonStyle(kind: .primary))
                        .disabled(!access.fileReady || !access.keychainReady)
                }
            }
        }.padding(28).frame(maxWidth: 660).background(DockTheme.canvas)
            .foregroundStyle(DockTheme.navy)
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
                Text(status).font(.system(size: 10)).foregroundStyle(DockTheme.muted)
                Spacer(); action()
            }
        }.padding(18).background(.white, in: RoundedRectangle(cornerRadius: 13))
    }
}
