import Foundation
import Security
import Darwin

struct AccountInfo: Decodable {
    let status: String
    let type: String?
    let email: String?
    let plan: String?
    let reason: String?
}
struct AccountReport: Decodable {
    let codex: AccountInfo
    let codex_home: String
    let file_presets_supported: Bool
}
struct AccountPreset: Codable, Identifiable {
    let id: String
    var name: String
    let email: String
    let plan: String?
    let savedAt: Date
    let credential: Data
}

enum DockError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}

// Credentials and labels stay together in the local, non-synchronizing Keychain.
enum PresetVault {
    static let service = "app.accountdock.presets.v1"
    static func query(_ id: String? = nil, serviceName: String = service) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: serviceName]
        if let id { query[kSecAttrAccount as String] = id }
        return query
    }
    static func all(serviceName: String = service) throws -> [AccountPreset] {
        var query = query(serviceName: serviceName)
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let values = result as? [[String: Any]] else {
            throw DockError.message("Keychain 프리셋을 읽지 못했습니다. 접근 권한을 확인하세요. (\(status))")
        }
        return try values.map { entry in
            guard let id = entry[kSecAttrAccount as String] as? String else {
                throw DockError.message("Keychain 프리셋 식별자를 읽지 못했습니다.")
            }
            var item = Self.query(id, serviceName: serviceName)
            item[kSecMatchLimit as String] = kSecMatchLimitOne
            item[kSecReturnData as String] = true
            var value: CFTypeRef?
            guard SecItemCopyMatching(item as CFDictionary, &value) == errSecSuccess,
                  let data = value as? Data else {
                throw DockError.message("Keychain 프리셋 데이터를 읽지 못했습니다.")
            }
            return try JSONDecoder().decode(AccountPreset.self, from: data)
        }
            .sorted { $0.savedAt > $1.savedAt }
    }
    static func save(_ preset: AccountPreset, serviceName: String = service) throws {
        let data = try JSONEncoder().encode(preset)
        var entry = query(preset.id, serviceName: serviceName)
        entry[kSecValueData as String] = data
        entry[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        entry[kSecAttrSynchronizable as String] = false
        let status = SecItemAdd(entry as CFDictionary, nil)
        guard status == errSecSuccess else { throw DockError.message("프리셋을 Keychain에 저장하지 못했습니다.") }
    }
    static func delete(_ id: String, serviceName: String = service) throws {
        let status = SecItemDelete(query(id, serviceName: serviceName) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DockError.message("프리셋을 삭제하지 못했습니다.")
        }
    }
    static func credential(at home: String) throws -> Data {
        let path = URL(fileURLWithPath: home).appendingPathComponent("auth.json")
        let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular else {
            throw DockError.message("일반 인증 파일만 프리셋으로 저장할 수 있습니다.")
        }
        let data = try Data(contentsOf: path)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any], tokens["refresh_token"] is String else {
            throw DockError.message("이 인증 방식은 아직 프리셋 저장을 지원하지 않습니다.")
        }
        return data
    }
    static func restore(_ preset: AccountPreset, home: String) throws {
        let directory = URL(fileURLWithPath: home)
        let destination = directory.appendingPathComponent("auth.json")
        let temporary = directory.appendingPathComponent(".account-dock-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: preset.credential,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw DockError.message("인증 파일을 준비하지 못했습니다.")
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard rename(temporary.path, destination.path) == 0 else {
            throw DockError.message("인증 파일을 적용하지 못했습니다. 기존 계정은 유지됩니다.")
        }
    }
}
