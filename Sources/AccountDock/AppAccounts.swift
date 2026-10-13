import SwiftUI

struct AppIdentity: Decodable, Identifiable {
    let id: String
    let product: String
    let status: String
    let email: String?
    let plan: String?
    let home: String?
    let version: String?
    var statusLabel: String {
        switch status {
        case "stored_account": return "저장소에서 확인"
        case "not_running": return "앱이 실행 중이 아닙니다"
        case "process_unavailable": return "계정 연결 프로세스를 찾지 못했습니다"
        case "no_saved_auth": return "인증 파일 없음 · 세션은 확인 필요"
        case "unsupported_store": return "이 인증 저장 방식은 아직 지원하지 않습니다"
        case "api_key": return "API 키 인증 · 이메일 계정 아님"
        default: return "계정 정보를 확인할 수 없습니다"
        }
    }
}
struct AppIdentityReport: Decodable {
    let accounts: [AppIdentity]
    let checkedAt: Double
}

enum AppIdentityReader {
    static func read() async throws -> AppIdentityReport {
        let script: String?
        if CommandLine.arguments.count > 1 {
            script = URL(fileURLWithPath: CommandLine.arguments[1]).deletingLastPathComponent().appendingPathComponent("app_accounts.py").path
        } else { script = Bundle.main.path(forResource: "app_accounts", ofType: "py") }
        guard let script else { throw DockError.message("앱별 계정 조회 도구가 없습니다.") }
        return try await Task.detached {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", "-B", script, "--show-email"]
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw DockError.message("앱별 계정 조회에 실패했습니다.") }
            return try JSONDecoder().decode(AppIdentityReport.self, from: data)
        }.value
    }
}

struct AppAccountCard: View {
    let title: String
    let icon: String
    let installed: String?
    let accounts: [AppIdentity]
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 18))
                    .frame(width: 38, height: 38).background(DockTheme.blue.opacity(0.3), in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Text(installed.map { "설치 버전 · \($0)" } ?? "설치 버전 확인 전")
                        .font(.system(size: 10)).foregroundStyle(DockTheme.muted)
                }
                Spacer()
            }
            if accounts.isEmpty {
                Text("계정 확인 전").font(.system(size: 12)).foregroundStyle(DockTheme.muted)
            }
            ForEach(accounts) { account in
                VStack(alignment: .leading, spacing: 6) {
                    if let email = account.email {
                        Text(email).font(.system(size: 13, weight: .medium)).textSelection(.enabled)
                        Text([account.plan?.uppercased(), account.statusLabel].compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 10)).foregroundStyle(DockTheme.muted)
                    } else { Text(account.statusLabel).font(.system(size: 12)).foregroundStyle(DockTheme.muted) }
                    if let version = account.version {
                        Text("실행 중 확장 · \(version)").font(.system(size: 10))
                            .foregroundStyle(version == installed ? DockTheme.muted : DockTheme.orange)
                    }
                    if let version = account.version, let installed, version != installed {
                        Text("설치 버전과 다름 · VS Code 재시작 후 확인")
                            .font(.system(size: 10)).foregroundStyle(DockTheme.muted)
                    }
                    if let home = account.home {
                        Text(home.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(DockTheme.muted)
                            .lineLimit(2).help(home)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                if account.id != accounts.last?.id { Divider().opacity(0.4) }
            }
            Spacer(minLength: 0)
        }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.white, in: RoundedRectangle(cornerRadius: 16))
    }
}
