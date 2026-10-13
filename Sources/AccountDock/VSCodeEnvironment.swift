import Foundation

/// Share local history, but never credentials or the full VS Code settings file.
@MainActor
enum VSCodeEnvironment {
    static var originalHome: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex") }
    static var originalSettings: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Code/User/settings.json") }
    static let appearanceKeys: Set<String> = [
        "workbench.colorTheme", "workbench.iconTheme", "workbench.productIconTheme",
        "workbench.preferredDarkColorTheme", "workbench.preferredLightColorTheme",
        "workbench.preferredHighContrastColorTheme", "workbench.preferredHighContrastLightColorTheme",
        "window.autoDetectColorScheme", "window.autoDetectHighContrast", "window.zoomLevel",
        "workbench.colorCustomizations", "editor.tokenColorCustomizations", "editor.semanticTokenColorCustomizations",
        "editor.fontFamily", "editor.fontSize", "editor.fontLigatures", "editor.fontWeight",
        "chat.fontSize", "chat.editor.fontSize"
    ]
    static func mergedAppearance(source: Data, destination: Data) throws -> Data {
        guard let original = try JSONSerialization.jsonObject(with: source, options: .json5Allowed) as? [String: Any],
              var target = try JSONSerialization.jsonObject(with: destination, options: .json5Allowed) as? [String: Any] else {
            throw DockError.message("VS Code 테마 설정을 읽지 못했습니다. 기존 설정은 유지됩니다.")
        }
        for key in appearanceKeys { target[key] = original[key] }
        return try JSONSerialization.data(withJSONObject: target, options: [.prettyPrinted, .sortedKeys])
    }
    static func prepare(source: URL = originalHome, destination: URL = VSCodeIsolation.home,
                        sourceSettings: URL = originalSettings,
                        targetSettings: URL = VSCodeIsolation.userData.appendingPathComponent("User/settings.json")) throws {
        let fm = FileManager.default
        try VSCodeIsolation.validateDirectory(source)
        try VSCodeIsolation.validateDirectory(destination)
        guard source.standardizedFileURL != destination.standardizedFileURL else { throw DockError.message("인증과 기록 폴더는 달라야 합니다.") }
        // A different SQLite location needs explicit support; never guess which database is current.
        for root in [source, destination] {
            let config = root.appendingPathComponent("config.toml")
            if fm.fileExists(atPath: config.path) {
                let text = try String(contentsOf: config, encoding: .utf8)
                if text.contains("sqlite_home") { throw DockError.message("사용자 지정 대화 저장소는 아직 연결할 수 없습니다.") }
            }
        }
        let names = ["sessions", "archived_sessions", "session_index.jsonl"]
        // Preflight the whole set before creating any links. Existing dedicated history is preserved.
        for name in names {
            let from = source.appendingPathComponent(name), to = destination.appendingPathComponent(name)
            try VSCodeIsolation.validateDirectory(from)
            if let link = try? fm.destinationOfSymbolicLink(atPath: to.path) {
                guard URL(fileURLWithPath: link, relativeTo: destination).standardizedFileURL == from.standardizedFileURL else {
                    throw DockError.message("다른 대화 폴더 연결이 있어 변경하지 않았습니다.")
                }
            } else if fm.fileExists(atPath: to.path) {
                throw DockError.message("계정별 VS Code 창에 기존 대화 데이터가 있습니다. 기록을 보존하기 위해 자동 연결을 중단했습니다.")
            }
        }
        try VSCodeIsolation.validateDirectory(targetSettings)
        try VSCodeIsolation.validateDirectory(sourceSettings)
        let theme: Data?
        if fm.fileExists(atPath: sourceSettings.path) {
            theme = try mergedAppearance(source: Data(contentsOf: sourceSettings), destination: Data(contentsOf: targetSettings))
        } else { theme = nil }
        var created: [URL] = []
        do {
            for name in names {
                let from = source.appendingPathComponent(name), to = destination.appendingPathComponent(name)
                if (try? fm.destinationOfSymbolicLink(atPath: to.path)) != nil { continue }
                // Missing source records stay missing; directory links remain valid when Codex creates them.
                try fm.createSymbolicLink(at: to, withDestinationURL: from)
                created.append(to)
            }
            if let theme {
                let backup = targetSettings.appendingPathExtension("account-dock-backup")
                if !fm.fileExists(atPath: backup.path) { try fm.copyItem(at: targetSettings, to: backup) }
                try theme.write(to: targetSettings, options: .atomic)
            }
        } catch {
            for path in created { try? fm.removeItem(at: path) }
            throw error
        }
    }
}
