import SwiftUI

@main
struct AccountDockApp: App {
    var body: some Scene {
        WindowGroup("Account Dock") { Dashboard() }
    }
}

struct Dashboard: View {
    @State private var output = "계정 확인을 누르면 로컬 Codex 인증 상태를 조회합니다."
    @State private var busy = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Account Dock").font(.largeTitle.bold())
            Text("ChatGPT · VS Code 계정 관리 시제품").foregroundStyle(.secondary)
            Text("현재 조회 대상은 Codex 로컬 인증 저장소입니다. 실행 중인 앱의 계정과 일치하는지는 별도 확인이 필요합니다.")
            HStack {
                Button(busy ? "조회 중…" : "계정 확인") {
                    busy = true
                    Task {
                        output = await Self.inspect()
                        busy = false
                    }
                }.disabled(busy)
                Button("ChatGPT 열기") { NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/ChatGPT.app")) }
                Button("VS Code 열기") { NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Visual Studio Code.app")) }
            }
            ScrollView {
                Text(output).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("ChatGPT 계정 조회 및 로그인·로그아웃은 다음 개발 단계입니다.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(28).frame(minWidth: 680, minHeight: 430)
    }

    nonisolated static func inspect() async -> String {
        await Task.detached {
            guard CommandLine.arguments.count > 1 else {
                return "실행 방법: swift run AccountDock \"$PWD/scripts/doctor.py\""
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", CommandLine.arguments[1], "--show-email"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { return "진단 도구 실행 실패. Python 3와 스크립트 경로를 확인하세요." }
                return String(data: data, encoding: .utf8) ?? "응답을 읽을 수 없습니다."
            } catch { return "진단 도구를 시작할 수 없습니다." }
        }.value
    }
}
