import AppKit
import Foundation
import Darwin

/// A bounded, cancellable JSON-RPC connection to the installed official Codex binary.
/// Credentials travel only over stdin; stderr and unsolicited payloads are never logged.
@MainActor
final class CodexConnection {
    private let process = Process()
    private let input = Pipe(), output = Pipe()
    private var buffer = Data()
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var timers: [Int: Task<Void, Never>] = [:]
    private var closed = false
    var isClosed: Bool { closed }
    var pid: Int32 { process.processIdentifier }
    var notification: ((String, [String: Any]) -> Void)?
    var serverRequest: ((String) -> Void)?

    init(binary: URL, home: URL, ephemeral: Bool = false) throws {
        process.executableURL = binary
        process.arguments = (ephemeral ? ["-c", "cli_auth_credentials_store=\"ephemeral\""] : []) + ["app-server", "--listen", "stdio://"]
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = home.path
        environment.removeValue(forKey: "OPENAI_API_KEY")
        environment.removeValue(forKey: "CODEX_ACCESS_TOKEN")
        process.environment = environment
        process.currentDirectoryURL = home
        process.standardInput = input; process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in self?.receive(data) }
        }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
        do { try process.run() }
        catch { output.fileHandleForReading.readabilityHandler = nil; throw DockError.message("Codex를 실행할 수 없습니다. 공식 앱 또는 확장을 설치해 주세요.") }
    }
    func initialize() async throws {
        _ = try await request("initialize", params: ["clientInfo": ["name": "account_dock", "version": ReleaseConfiguration.current.version], "capabilities": ["experimentalApi": true]])
        try send(["method": "initialized"])
    }
    func request(_ method: String, params: [String: Any]? = nil, timeout: Double = 15) async throws -> [String: Any] {
        guard !closed, !Task.isCancelled else { throw CancellationError() }
        nextID += 1
        let id = nextID
        let data: Data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                timers[id] = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
                    self?.resolve(id, .failure(DockError.message("응답 시간이 초과되었습니다. 다시 시도해 주세요.")))
                }
                do {
                    var message: [String: Any] = ["id": id, "method": method]
                    if let params { message["params"] = params }
                    try send(message)
                } catch { resolve(id, .failure(error)) }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.close() } }
        return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
    private func send(_ value: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: value)
        data.append(10)
        try input.fileHandleForWriting.write(contentsOf: data)
    }
    private func receive(_ data: Data) {
        guard !closed else { return }
        guard !data.isEmpty, buffer.count + data.count <= 2_000_000 else { close(); return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { close(); return }
            if let method = message["method"] as? String {
                if message["id"] != nil { serverRequest?(method) }
                else { notification?(method, message["params"] as? [String: Any] ?? [:]) }
            } else if let id = message["id"] as? Int {
                if message["error"] != nil { resolve(id, .failure(DockError.message("Codex가 요청을 처리하지 못했습니다."))) }
                else {
                    do { resolve(id, .success(try JSONSerialization.data(withJSONObject: message["result"] as? [String: Any] ?? [:]))) }
                    catch { resolve(id, .failure(error)) }
                }
            }
        }
    }
    private func resolve(_ id: Int, _ result: Result<Data, Error>) {
        timers.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(with: result)
    }
    func shutdown() async {
        close()
        for _ in 0..<60 {
            if !process.isRunning { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
    func close() {
        guard !closed else { return }
        closed = true
        notification = nil; serverRequest = nil
        output.fileHandleForReading.readabilityHandler = nil
        for id in Array(pending.keys) { resolve(id, .failure(CancellationError())) }
        try? input.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
            let process = self.process
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            }
        }
    }
}

@MainActor
enum CodexService {
    static func binary() throws -> URL {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".vscode/extensions")
        #if arch(arm64)
        let platform = "macos-aarch64"
        #else
        let platform = "macos-x86_64"
        #endif
        if let data = try? Data(contentsOf: root.appendingPathComponent("extensions.json")),
           let entries = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
            let matches = entries.filter { ($0["identifier"] as? [String: Any])?["id"] as? String == "openai.chatgpt" }
            for entry in matches.sorted(by: { ($0["version"] as? String ?? "").compare($1["version"] as? String ?? "", options: .numeric) == .orderedDescending }) {
                if let relative = entry["relativeLocation"] as? String, !relative.contains("/"), relative.hasPrefix("openai.chatgpt-") {
                    let url = root.appendingPathComponent(relative).appendingPathComponent("bin/\(platform)/codex")
                    if FileManager.default.isExecutableFile(atPath: url.path) { return url }
                }
            }
        }
        let desktop = URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex")
        guard FileManager.default.isExecutableFile(atPath: desktop.path) else { throw DockError.message("공식 ChatGPT 앱 또는 Codex 확장을 설치해 주세요.") }
        return desktop
    }
    static func report(connection: CodexConnection, home: URL) async throws -> AccountReport {
        let account = try await connection.request("account/read", params: ["refreshToken": false])
        let config = try? await connection.request("config/read", params: ["includeLayers": false])
        let values = config?["config"] as? [String: Any]
        let mode = values?["cli_auth_credentials_store"] as? String
        let fileSupported = values != nil && (mode == nil || mode == "file")
        let info: AccountInfo
        if account["account"] is NSNull { info = AccountInfo(status: "signed_out", type: nil, email: nil, plan: nil, reason: nil) }
        else if let value = account["account"] as? [String: Any], let type = value["type"] as? String {
            info = AccountInfo(status: "cached_account", type: type, email: value["email"] as? String, plan: value["planType"] as? String, reason: nil)
        } else { throw DockError.message("계정 응답을 확인하지 못했습니다.") }
        return AccountReport(codex: info, codex_home: home.path, file_presets_supported: fileSupported)
    }
    static func claims(_ token: String) -> [String: Any] {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return [:] }
        var text = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        guard let data = Data(base64Encoded: text) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
    static func temporaryHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("account-dock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return home
    }
}
