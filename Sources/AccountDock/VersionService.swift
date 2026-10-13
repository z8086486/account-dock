import Foundation

@MainActor
enum VersionService {
    static func numeric(_ value: String) -> [Int]? {
        guard value.range(of: #"^v?\d+(?:\.\d+)*$"#, options: .regularExpression) != nil else { return nil }
        let parts = value.drop(while: { $0 == "v" }).split(separator: ".")
        let result = parts.compactMap { Int($0) }
        return result.count == parts.count ? result : nil
    }
    static func newer(_ candidate: String, _ installed: String) -> Bool {
        guard let a = numeric(candidate), let b = numeric(installed) else { return false }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
    static func extensionVersion() -> String? {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".vscode/extensions/extensions.json")
        guard let data = try? Data(contentsOf: root), let entries = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        return entries.filter { ($0["identifier"] as? [String: Any])?["id"] as? String == "openai.chatgpt" }
            .compactMap { $0["version"] as? String }.filter { numeric($0) != nil }.max { newer($1, $0) }
    }
    static func desktopVersion() -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Info.plist")),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { return nil }
        return plist["CFBundleShortVersionString"] as? String
    }
    static func marketplace(_ data: Data, platform: String) throws -> String {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        var versions: [String] = []
        for result in json?["results"] as? [[String: Any]] ?? [] {
            for entry in result["extensions"] as? [[String: Any]] ?? [] {
                guard (entry["publisher"] as? [String: Any])?["publisherName"] as? String == "openai", entry["extensionName"] as? String == "chatgpt" else { continue }
                for version in entry["versions"] as? [[String: Any]] ?? [] {
                    if let target = version["targetPlatform"] as? String, target != platform && target != "universal" { continue }
                    let pre = (version["properties"] as? [[String: Any]] ?? []).contains { $0["key"] as? String == "Microsoft.VisualStudio.Code.PreRelease" && ($0["value"] as? String)?.lowercased() == "true" }
                    if !pre, let value = version["version"] as? String, numeric(value) != nil { versions.append(value) }
                }
            }
        }
        guard let latest = versions.max(by: { newer($1, $0) }) else { throw DockError.message("안정 버전을 찾지 못했습니다.") }
        return latest
    }
    static var releaseAPI: URL { URL(string: "https://api.github.com/repos/z8086486/account-dock/releases?per_page=100")! }
    static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }
    static func downloadableRelease(_ data: Data, architecture: String, includePreviews: Bool) throws -> (version: String, download: URL)? {
        guard let releases = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw DockError.message("GitHub 릴리즈 응답을 확인하지 못했습니다.")
        }
        var candidates: [(version: String, download: URL)] = []
        for release in releases {
            guard release["draft"] as? Bool == false,
                  includePreviews || release["prerelease"] as? Bool == false,
                  let tag = release["tag_name"] as? String, numeric(tag) != nil else { continue }
            let version = String(tag.drop(while: { $0 == "v" }))
            for asset in release["assets"] as? [[String: Any]] ?? [] {
                guard let name = asset["name"] as? String,
                      ["AccountDock-\(version)-\(architecture)-preview.dmg", "AccountDock-\(version)-\(architecture)-signed.dmg"].contains(name),
                      asset["state"] as? String == "uploaded",
                      let raw = asset["browser_download_url"] as? String,
                      let url = URL(string: raw), url.scheme == "https", url.host == "github.com",
                      url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil,
                      url.path == "/z8086486/account-dock/releases/download/\(tag)/\(name)" else { continue }
                candidates.append((version, url))
            }
        }
        return candidates.max { newer($1.version, $0.version) }
    }
    static func previewDownload() async throws -> (version: String, download: URL)? {
        var request = URLRequest(url: releaseAPI, timeoutInterval: 15)
        request.setValue("AccountDock-version-check", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 16_000_000 else {
            throw DockError.message("GitHub 다운로드 정보를 확인하지 못했습니다. 잠시 후 다시 시도해 주세요.")
        }
        return try downloadableRelease(data, architecture: architecture, includePreviews: ReleaseConfiguration.current.channel == "preview")
    }
    static func latest(_ product: String) async -> (String?, String) {
        do {
            let url: URL
            switch product {
            case "codex": url = URL(string: "https://marketplace.visualstudio.com/_apis/public/gallery/extensionquery")!
            case "chatgpt": url = URL(string: "https://updates.oaistatic.com/codex/app/appcast")!
            default: url = releaseAPI
            }
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.setValue("AccountDock-version-check", forHTTPHeaderField: "User-Agent")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if product == "codex" {
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("application/json;api-version=3.0-preview.1", forHTTPHeaderField: "Accept")
                request.httpBody = try JSONSerialization.data(withJSONObject: ["filters": [["criteria": [["filterType": 7, "value": "openai.chatgpt"]]]], "flags": 19])
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return (nil, "unavailable") }
            if product == "accountdock", http.statusCode == 404 { return (nil, "not_released") }
            guard http.statusCode == 200, data.count <= 16_000_000 else { return (nil, "unavailable") }
            let value: String
            if product == "codex" {
                #if arch(arm64)
                value = try marketplace(data, platform: "darwin-arm64")
                #else
                value = try marketplace(data, platform: "darwin-x64")
                #endif
            } else if product == "chatgpt" {
                let delegate = VersionFeedParser(), parser = XMLParser(data: data)
                parser.delegate = delegate
                guard parser.parse(), let latest = delegate.versions.filter({ numeric($0) != nil }).max(by: { newer($1, $0) }) else { return (nil, "unavailable") }
                value = latest
            } else {
                guard let release = try downloadableRelease(data, architecture: architecture,
                    includePreviews: ReleaseConfiguration.current.channel == "preview") else { return (nil, "not_released") }
                value = release.version
            }
            return (value, "checked")
        } catch { return (nil, "unavailable") }
    }
    static func inventory(online: Bool, update: String?) async throws -> VersionReport {
        if let update {
            guard numeric(update) != nil, let installed = extensionVersion(), newer(update, installed), await latest("codex").0 == update else { throw DockError.message("업데이트 버전이 변경되었습니다. 다시 확인해 주세요.") }
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code")
            task.arguments = ["--install-extension", "openai.chatgpt@" + update, "--force"]
            task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
            try task.run()
            let deadline = Date().addingTimeInterval(180)
            while task.isRunning {
                if Date() > deadline || Task.isCancelled { task.terminate(); throw DockError.message("확장 업데이트가 중단되었습니다.") }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard task.terminationStatus == 0, extensionVersion() == update else { throw DockError.message("설치된 확장 버전을 확인하지 못했습니다.") }
        }
        let manifest = (try JSONSerialization.jsonObject(with: Data(contentsOf: ReleaseConfiguration.url))) as? [String: Any] ?? [:]
        let compatibility = manifest["compatibility"] as? [String: [String: Any]] ?? [:]
        var rows: [ProductVersion] = []
        for (id, version) in [("accountdock", Optional(ReleaseConfiguration.current.version)), ("codex", extensionVersion())] {
            let remote = online ? await latest(id) : (nil, "not_checked")
            let tests = compatibility[id]?["versions"] as? [String] ?? []
            rows.append(ProductVersion(id: id, installed: version, latest: remote.0, check: remote.1, tested: tests,
                scope: compatibility[id]?["scope"] as? String ?? "", known_version: version.map { tests.contains($0) } ?? false,
                update_available: version.flatMap { installed in remote.0.map { newer($0, installed) } } ?? false))
        }
        return VersionReport(products: rows)
    }
}

final class VersionFeedParser: NSObject, XMLParserDelegate {
    var versions: [String] = []
    private var collecting = false, text = ""
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        if elementName == "enclosure", let value = attributes["sparkle:shortVersionString"] { versions.append(value) }
        collecting = elementName == "sparkle:shortVersionString"
        if collecting { text = "" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if collecting { text += string } }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "sparkle:shortVersionString" { versions.append(text.trimmingCharacters(in: .whitespacesAndNewlines)); collecting = false }
    }
}
