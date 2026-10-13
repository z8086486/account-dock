import AppKit
import Foundation
import Darwin

@MainActor
enum ActivityGate {
    static func blockers(excluding: Set<Int32> = []) throws -> [String] {
        var names = Set(NSWorkspace.shared.runningApplications.filter {
            ["com.openai.codex", "com.openai.chat", "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"].contains($0.bundleIdentifier ?? "")
        }.compactMap(\.localizedName))
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,comm="]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else {
            throw DockError.message("실행 중인 작업을 확인하지 못해 계정을 변경하지 않았습니다.")
        }
        for row in processRows(text) where !excluding.contains(row.pid) {
            if ["codex", "codex-code-mode-host"].contains(URL(fileURLWithPath: row.path).lastPathComponent) { names.insert("Codex 작업 프로세스") }
        }
        return names.sorted()
    }
    struct ProcessRow { let pid: Int32; let parent: Int32; let path: String }
    static func processRows(_ text: String) -> [ProcessRow] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.split(maxSplits: 2, omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace })
            guard parts.count == 3, let pid = Int32(parts[0]), let parent = Int32(parts[1]) else { return nil }
            return ProcessRow(pid: pid, parent: parent, path: String(parts[2]))
        }
    }
    static func requireIdle(excluding: Set<Int32> = []) throws {
        let names = try blockers(excluding: excluding)
        guard names.isEmpty else { throw DockError.message("\(names.joined(separator: ", "))가 실행 중입니다. 작업을 마치고 종료한 뒤 전환해 주세요. 앱은 자동 종료하지 않습니다.") }
    }
}

/// Local lock + compare-before-write + readback. Never overwrites a file changed since validation.
/// Other applications do not cooperate with this lock: ActivityGate must also be checked immediately before commit.
enum AuthTransaction {
    static func install(_ credential: Data, home: URL, expected: Data?, beforeWrite: () throws -> Void) throws {
        let lock = home.appendingPathComponent(".account-dock.lock")
        let fd = open(lock.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw DockError.message("전환 잠금 파일을 만들지 못했습니다.") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw DockError.message("다른 Account Dock에서 계정을 변경하고 있습니다.") }
        defer { flock(fd, LOCK_UN) }
        let path = home.appendingPathComponent("auth.json")
        let current = try snapshot(path)
        guard current == expected else { throw DockError.message("인증 정보가 다른 곳에서 변경되어 전환을 중단했습니다. 새로고침해 주세요.") }
        try beforeWrite()
        guard try snapshot(path) == expected else { throw DockError.message("인증 정보가 변경되어 전환을 중단했습니다.") }
        let preset = AccountPreset(id: "transaction", name: "", email: "", plan: nil, savedAt: Date(), credential: credential)
        try PresetVault.restore(preset, home: home.path)
        do {
            guard try snapshot(path) == credential else { throw DockError.message("전환 후 다른 앱이 인증 정보를 변경했습니다. 현재 상태를 다시 확인해 주세요.") }
        } catch {
            // Never roll back over a third-party write. Atomic rename already leaves either old or new data.
            throw error
        }
    }
    static func snapshot(_ path: URL) throws -> Data? {
        let descriptor = open(path.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw DockError.message("인증 파일을 안전하게 읽지 못했습니다.")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size <= 1_000_000 else { throw DockError.message("일반 인증 파일만 전환할 수 있습니다.") }
        return try handle.readToEnd() ?? Data()
    }
}
