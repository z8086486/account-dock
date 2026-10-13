import SwiftUI
import Darwin

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

@MainActor
enum AppIdentityReader {
    static let desktop = "/Applications/ChatGPT.app/Contents/"
    static let editor = "/Applications/Visual Studio Code.app/Contents/"
    static func read() async throws -> AppIdentityReport {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,comm="]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw DockError.message("앱 실행 정보를 확인하지 못했습니다.") }
        let rows = ActivityGate.processRows(String(decoding: data, as: UTF8.self))
        let table = Dictionary(uniqueKeysWithValues: rows.map { ($0.pid, $0) })
        var accounts: [AppIdentity] = [], seen = Set<String>()
        for row in rows {
            let parent = table[row.parent]?.path ?? ""
            let product: String
            if row.path.contains("/.vscode/extensions/openai.chatgpt-"), row.path.hasSuffix("/codex"), parent.hasPrefix(editor), parent.contains("Code Helper (Plugin)") { product = "codex" }
            else { continue }
            var home: String?, version: String?, email: String?, plan: String?, status = "unavailable"
            do {
                let (args, environment) = try arguments(row.pid)
                guard args.contains("app-server") else { continue }
                guard !args.contains(where: { $0 == "--profile" || $0 == "-p" || $0.hasPrefix("--profile=") || $0.contains("cli_auth_credentials_store") }) else { throw DockError.message("인증 설정 재정의") }
                guard let path = environment["CODEX_HOME"] ?? environment["HOME"].map({ $0 + "/.codex" }), path.hasPrefix("/") else { throw DockError.message("인증 경로 미확인") }
                home = URL(fileURLWithPath: path).standardizedFileURL.path
                let identity = try storedIdentity(home!)
                status = identity.status; email = identity.email; plan = identity.plan
                if product == "codex", let component = row.path.split(separator: "/").first(where: { $0.hasPrefix("openai.chatgpt-") }) {
                    version = String(component.dropFirst("openai.chatgpt-".count).split(separator: "-").first ?? "")
                }
            } catch { }
            let key = [product, home ?? "", version ?? "", status].joined(separator: "|")
            if seen.insert(key).inserted { accounts.append(AppIdentity(id: key, product: product, status: status, email: email, plan: plan, home: home, version: version)) }
        }
        for product in ["codex"] where !accounts.contains(where: { $0.product == product }) {
            let root = product == "chatgpt" ? desktop + "MacOS/ChatGPT" : editor + "MacOS/Code"
            accounts.append(AppIdentity(id: product, product: product, status: rows.contains(where: { $0.path == root }) ? "process_unavailable" : "not_running", email: nil, plan: nil, home: nil, version: nil))
        }
        return AppIdentityReport(accounts: accounts, checkedAt: Date().timeIntervalSince1970)
    }
    static func storedIdentity(_ home: String) throws -> (status: String, email: String?, plan: String?) {
        let base = URL(fileURLWithPath: home)
        let configURL = base.appendingPathComponent("config.toml")
        // Conservatively refuse explicit auth-store configuration; do not approximate a TOML parser.
        if FileManager.default.fileExists(atPath: configURL.path) {
            let config = try String(contentsOf: configURL, encoding: .utf8)
            if config.contains("cli_auth_credentials_store") { return ("unsupported_store", nil, nil) }
        }
        guard let data = try AuthTransaction.snapshot(base.appendingPathComponent("auth.json")) else { return ("no_saved_auth", nil, nil) }
        guard data.count <= 1_000_000, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return ("unavailable", nil, nil) }
        guard let tokens = json["tokens"] as? [String: Any], let token = tokens["id_token"] as? String else { return (json["OPENAI_API_KEY"] is String ? "api_key" : "no_saved_auth", nil, nil) }
        let claims = CodexService.claims(token)
        guard let email = claims["email"] as? String else { return ("unavailable", nil, nil) }
        return ("stored_account", email, (claims["https://api.openai.com/auth"] as? [String: Any])?["chatgpt_plan_type"] as? String)
    }
    static func arguments(_ pid: Int32) throws -> ([String], [String: String]) {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var data = [UInt8](repeating: 0, count: 1_048_576), size = 1_048_576
        guard sysctl(&mib, 3, &data, &size, nil, 0) == 0 else { throw DockError.message("프로세스 정보 접근 불가") }
        return try parseArguments(Data(data.prefix(size)))
    }
    static func parseArguments(_ data: Data) throws -> ([String], [String: String]) {
        guard data.count >= 5 else { throw DockError.message("프로세스 응답 오류") }
        let argc = data.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        guard argc > 0 && argc < 4096 else { throw DockError.message("프로세스 응답 오류") }
        let bytes = [UInt8](data)
        var index = 4
        while index < bytes.count && bytes[index] != 0 { index += 1 }
        while index < bytes.count && bytes[index] == 0 { index += 1 }
        func next() throws -> String {
            let start = index
            while index < bytes.count && bytes[index] != 0 { index += 1 }
            guard index < bytes.count else { throw DockError.message("프로세스 응답 오류") }
            defer { index += 1 }
            return String(decoding: bytes[start..<index], as: UTF8.self)
        }
        var args: [String] = []
        for _ in 0..<argc { args.append(try next()) }
        var environment: [String: String] = [:]
        while index < bytes.count {
            let text = try next()
            if let separator = text.firstIndex(of: "=") {
                let key = String(text[..<separator])
                if ["HOME", "CODEX_HOME"].contains(key) { environment[key] = String(text[text.index(after: separator)...]) }
            }
        }
        return (args, environment)
    }
}

struct AppAccountCard: View {
    let title: String
    let icon: String
    let installed: String?
    let accounts: [AppIdentity]
    let presets: [AccountPreset]
    let busy: Bool
    let canSwitch: Bool
    let switchExplanation: String
    let onAdd: () -> Void
    var onOpenDedicated: ((AccountPreset) -> Void)? = nil
    @State private var selectedID: String?
    private var displayedAccounts: [AppIdentity] { AppAccountPresentation.grouped(accounts) }
    private var choices: [AccountPreset] {
        AppAccountPresentation.choices(presets, accounts: accounts)
    }
    private var selected: AccountPreset? { choices.first { $0.id == selectedID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 18))
                    .frame(width: 38, height: 38).background(DockTheme.blue.opacity(0.3), in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Text(installed.map { "설치 버전 · \($0)" } ?? "설치 버전 확인 전")
                        .font(.system(size: 12)).foregroundStyle(DockTheme.muted)
                }
                Spacer()
            }
            Divider().opacity(0.4)
            HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 16) {
            if accounts.isEmpty {
                Text("계정 확인 전").font(.system(size: 12)).foregroundStyle(DockTheme.muted)
            }
            if !canSwitch {
                VStack(alignment: .leading, spacing: 6) {
                    Text("앱 로그인 조회 미지원").font(.system(size: 13, weight: .semibold))
                    Text("\(switchExplanation)").font(.system(size: 12)).foregroundStyle(DockTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text(canSwitch ? "현재 연결 계정" : "Codex 저장소").font(.system(size: 12, weight: .semibold)).foregroundStyle(DockTheme.muted)
            ForEach(displayedAccounts) { account in
                VStack(alignment: .leading, spacing: 6) {
                    if account.product == "codex" {
                        Text(VSCodeIsolation.isManagedHome(account.home) ? "전용 VS Code" : "기존 VS Code")
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(DockTheme.muted)
                    }
                    if let email = account.email {
                        Text(AppAccountPresentation.displayName(email, presets: presets)).font(.system(size: 13, weight: .medium)).textSelection(.enabled)
                        Text([AccountPreset.planLabel(account.plan), account.statusLabel].compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 12)).foregroundStyle(DockTheme.muted)
                    } else { Text(account.statusLabel).font(.system(size: 12)).foregroundStyle(DockTheme.muted) }
                    DisclosureGroup("연결 정보") {
                        VStack(alignment: .leading, spacing: 5) {
                            if let email = account.email { Text(email).textSelection(.enabled) }
                            if let version = account.version {
                                Text("실행 중 확장 · \(version)")
                                if let installed, version != installed { Text("설치 버전과 다름 · VS Code 재시작 후 확인").foregroundStyle(DockTheme.orange) }
                            }
                            if let home = account.home {
                                Text(home.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            }
                        }.font(.system(size: 12)).foregroundStyle(DockTheme.muted).padding(.top, 5)
                    }.font(.system(size: 12)).foregroundStyle(DockTheme.muted)

                }.frame(maxWidth: .infinity, alignment: .leading)
                if account.id != displayedAccounts.last?.id { Divider().opacity(0.4) }
            }
            }.frame(maxWidth: .infinity, alignment: .topLeading)
            Rectangle().fill(DockTheme.navy.opacity(0.10)).frame(width: 1)
            VStack(alignment: .leading, spacing: 16) {
            if canSwitch {
                HStack {
                    Text("전용 창에서 사용할 계정").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Button(action: onAdd) { Label("추가", systemImage: "plus") }
                        .buttonStyle(DockButtonStyle(kind: .quiet)).disabled(busy)
                }
                if choices.isEmpty {
                    Text(presets.isEmpty ? "계정을 추가하면 여기에서 선택할 수 있습니다." : "기존 VS Code 계정 외에 저장된 계정이 없습니다.").font(.system(size: 12)).foregroundStyle(DockTheme.muted)
                }
                ForEach(choices) { preset in
                    Button { selectedID = preset.id } label: {
                        HStack(spacing: 10) {
                            Image(systemName: selectedID == preset.id ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedID == preset.id ? DockTheme.orange : DockTheme.muted)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(preset.displayName).font(.system(size: 14, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                                Text(preset.planLabel).font(.system(size: 12)).foregroundStyle(DockTheme.muted)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            Spacer(minLength: 8)
                            if accounts.contains(where: { $0.home == VSCodeIsolation.workspace(for: preset).home.path }) {
                                Text("연결됨").font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(DockTheme.muted)
                            }
                        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                            .background(selectedID == preset.id ? DockTheme.blue.opacity(0.22) : DockTheme.canvas, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selectedID == preset.id ? DockTheme.orange.opacity(0.5) : Color.clear))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(busy)
                        .accessibilityLabel("\(title), \(preset.displayName)")
                        .accessibilityAddTraits(selectedID == preset.id ? [.isSelected] : [])
                }
                Text(switchExplanation).font(.system(size: 12)).foregroundStyle(DockTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    if let selected {
                        onOpenDedicated?(selected)
                    }
                } label: {
                    Label("전용 창 열기", systemImage: "macwindow.badge.plus")
                        .frame(maxWidth: .infinity)
                }.buttonStyle(DockButtonStyle(kind: .primary))
                    .disabled(busy || !canSwitch || selected == nil)
            }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            }.fixedSize(horizontal: false, vertical: true)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.white, in: RoundedRectangle(cornerRadius: 16))
    }

}

/// Group connection rows by store and identity, retaining observed extension versions.
enum AppAccountPresentation {
    static func displayName(_ email: String, presets: [AccountPreset]) -> String {
        let matches = presets.filter { $0.email.caseInsensitiveCompare(email) == .orderedSame }
        return matches.count == 1 ? matches[0].displayName : email
    }

    static func grouped(_ accounts: [AppIdentity]) -> [AppIdentity] {
        var result: [AppIdentity] = []
        for account in accounts {
            if let index = result.firstIndex(where: { $0.product == account.product && $0.home == account.home && $0.email == account.email && $0.status == account.status }) {
                let old = result[index]
                let versions = Set([old.version, account.version].compactMap { $0 }.flatMap { $0.components(separatedBy: ", ") }).sorted()
                result[index] = AppIdentity(id: old.id, product: old.product, status: old.status, email: old.email, plan: old.plan, home: old.home, version: versions.isEmpty ? nil : versions.joined(separator: ", "))
            } else { result.append(account) }
        }
        return result
    }
    @MainActor static func choices(_ presets: [AccountPreset], accounts: [AppIdentity]) -> [AccountPreset] {
        // Only the ordinary VS Code account is excluded. Dedicated accounts can open more windows.
        let primaryEmails = Set(accounts.filter {
            $0.product == "codex" && !VSCodeIsolation.isManagedHome($0.home)
        }.compactMap { $0.email?.lowercased() })
        return presets.filter { !primaryEmails.contains($0.email.lowercased()) }
    }
}
