import AppKit
import Foundation
import Darwin

/// An independent VS Code process, not a profile in the existing VS Code process.
/// Neither the shared Codex home nor the user's existing VS Code settings are modified.
@MainActor
enum VSCodeIsolation {
    static let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/AccountDock/VSCode")
    static var home: URL { root.appendingPathComponent("codex") }
    static var userData: URL { root.appendingPathComponent("user-data") }
    static let executable = URL(fileURLWithPath: "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code")
    static func validateDirectory(_ url: URL) throws {
        guard url.standardizedFileURL == url.resolvingSymlinksInPath().standardizedFileURL else {
            throw DockError.message("전용 VS Code 경로에 심볼릭 링크가 있어 변경하지 않았습니다.")
        }
    }
    static func prepare() throws {
        try validateDirectory(root)
        let fm = FileManager.default
        let marker = root.appendingPathComponent("account-dock-managed-v1")
        if fm.fileExists(atPath: root.path), !fm.fileExists(atPath: marker.path) {
            throw DockError.message("전용 폴더에 기존 데이터가 있어 자동으로 변경하지 않았습니다.")
        }
        for path in [root, home, userData.appendingPathComponent("User")] {
            try validateDirectory(path)
            try fm.createDirectory(at: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        if !fm.fileExists(atPath: marker.path) { try Data("Account Dock managed VS Code v1\n".utf8).write(to: marker, options: .atomic) }
        let settings = userData.appendingPathComponent("User/settings.json")
        if !fm.fileExists(atPath: settings.path) {
            let value: [String: Any] = ["chatgpt.openOnStartup": true, "workbench.startupEditor": "none",
                "window.title": "Account Dock · ${rootName}${separator}${activeEditorShort}",
                "telemetry.telemetryLevel": "off", "extensions.autoUpdate": false]
            try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: settings, options: .atomic)
        }
        // Default Codex file storage; do not copy config, MCP secrets or shared SQLite/session files.
    }
    static func targetsManagedStore(args: [String], environment: [String: String], home: URL, userData: URL) -> Bool {
        if let value = environment["CODEX_HOME"], URL(fileURLWithPath: value).resolvingSymlinksInPath() == home.resolvingSymlinksInPath() { return true }
        for (index, arg) in args.enumerated() {
            let value: String?
            if arg == "--user-data-dir", index + 1 < args.count { value = args[index + 1] }
            else if arg.hasPrefix("--user-data-dir=") { value = String(arg.dropFirst("--user-data-dir=".count)) }
            else { value = nil }
            if let value, URL(fileURLWithPath: value).resolvingSymlinksInPath() == userData.resolvingSymlinksInPath() { return true }
        }
        return false
    }
    static func requireStopped() throws {
        let task = Process(), output = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axo", "pid=,ppid=,comm="]
        task.standardOutput = output; task.standardError = FileHandle.nullDevice
        try task.run()
        let data = output.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw DockError.message("VS Code 실행 상태를 확인하지 못했습니다.") }
        for row in ActivityGate.processRows(String(decoding: data, as: UTF8.self)) {
            let basename = URL(fileURLWithPath: row.path).lastPathComponent
            guard row.path.hasPrefix(AppIdentityReader.editor) || ["codex", "codex-code-mode-host"].contains(basename) else { continue }
            let (args, environment): ([String], [String: String])
            do { (args, environment) = try AppIdentityReader.arguments(row.pid) }
            catch {
                // A process may exit during inspection. A still-running unknown process blocks changes.
                if kill(row.pid, 0) == 0 { throw DockError.message("작업 프로세스의 인증 경로를 확인하지 못해 전환하지 않았습니다.") }
                continue
            }
            if targetsManagedStore(args: args, environment: environment, home: home, userData: userData) {
                throw DockError.message("Account Dock 전용 VS Code가 실행 중입니다. 작업을 저장하고 전용 창의 VS Code를 종료한 뒤 다시 적용해 주세요. 기존 VS Code·ChatGPT는 종료할 필요가 없습니다.")
            }
        }
    }
    static func launchEnvironment(_ input: [String: String], home: URL) -> [String: String] {
        var result = input
        // A CLI inherited from VS Code must not route this launch back to its parent instance.
        for key in ["VSCODE_IPC_HOOK_CLI", "ELECTRON_RUN_AS_NODE", "OPENAI_API_KEY", "CODEX_ACCESS_TOKEN"] { result.removeValue(forKey: key) }
        result["CODEX_HOME"] = home.path
        return result
    }
    static func launch() async throws {
        let task = Process()
        task.executableURL = executable
        task.arguments = ["--user-data-dir", userData.path, "--extensions-dir", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".vscode/extensions").path, "--new-window", "--skip-welcome", "--skip-release-notes"]
        task.environment = launchEnvironment(ProcessInfo.processInfo.environment, home: home)
        task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
        try task.run()
        let deadline = Date().addingTimeInterval(20)
        while task.isRunning {
            if Date() > deadline || Task.isCancelled { task.terminate(); throw DockError.message("VS Code 실행 확인 시간이 초과되었습니다. 적용된 계정은 전용 폴더에만 있습니다.") }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard task.terminationStatus == 0 else { throw DockError.message("전용 VS Code를 열지 못했습니다. 기존 앱 계정은 변경하지 않았습니다.") }
    }
}
