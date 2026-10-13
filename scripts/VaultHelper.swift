import Foundation
import Security
import Darwin

@main
struct VaultHelper {
    static func authorizedParent() -> Bool {
        let pid = getppid()
        guard pid > 1 else { return false }
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let code else { return false }
        var requirement: SecRequirement?
        let text = "identifier \"app.accountdock.mac\" and certificate leaf = H\"F5F0DC08DB9A7AAA04658D403B997AA2746D35D3\""
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess && getppid() == pid
    }
    static func reply(_ payload: Any) throws {
        let data = try JSONSerialization.data(withJSONObject: ["ok": true, "payload": payload])
        try FileHandle.standardOutput.write(contentsOf: data)
    }
    static func main() {
        guard authorizedParent() else { exit(77) }
        do {
            var data = Data()
            while let part = try FileHandle.standardInput.read(upToCount: 65536), !part.isEmpty {
                data.append(part)
                guard data.count <= 8_000_000 else { exit(65) }
            }
            guard let request = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let operation = request["operation"] as? String, authorizedParent() else { exit(65) }
            switch operation {
            case "all":
                try reply(JSONSerialization.jsonObject(with: JSONEncoder().encode(PresetVault.all())))
            case "upsert":
                guard let entry = request["entry"] else { exit(65) }
                let preset = try JSONDecoder().decode(AccountPreset.self, from: JSONSerialization.data(withJSONObject: entry))
                let saved = try PresetVault.upsert(preset, preserveName: request["preserveName"] as? Bool ?? true)
                try reply(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)))
            case "rename":
                guard let id = request["id"] as? String, let name = request["name"] as? String else { exit(65) }
                try PresetVault.renameAccount(id, name: name); try reply(true)
            case "delete":
                guard let id = request["id"] as? String else { exit(65) }
                try PresetVault.delete(id); try reply(true)
            case "check":
                _ = try PresetVault.all()
                fallthrough
            case "probe":
                // No account credentials are involved in this storage health check.
                let service = "app.accountdock.access-check"
                let entry = AccountPreset(id: "stable-vault-probe", name: "", email: "", plan: nil,
                    savedAt: Date(), credential: Data("fixture-only".utf8))
                try PresetVault.upsert(entry, serviceName: service)
                try reply(PresetVault.all(serviceName: service).contains { $0.id == entry.id })
            default: exit(65)
            }
        } catch { exit(1) }
    }
}
