import Foundation
import Security
import Darwin
import CryptoKit

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
struct AccountPreset: Codable, Identifiable, Sendable {
    let id: String
    var name: String
    let email: String
    let plan: String?
    let savedAt: Date
    let credential: Data
    var identityKey: String {
        let json = (try? JSONSerialization.jsonObject(with: credential)) as? [String: Any]
        let tokens = json?["tokens"] as? [String: Any]
        let account = tokens?["account_id"] as? String ?? ""
        return SHA256.hash(data: Data((email.lowercased() + "|" + account).utf8)).map { String(format: "%02x", $0) }.joined()
    }
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
            throw DockError.message("Keychain 저장한 계정을 읽지 못했습니다. 접근 권한을 확인하세요. (\(status))")
        }
        return try values.map { entry in
            guard let id = entry[kSecAttrAccount as String] as? String else {
                throw DockError.message("Keychain 저장한 계정 식별자를 읽지 못했습니다.")
            }
            var item = Self.query(id, serviceName: serviceName)
            item[kSecMatchLimit as String] = kSecMatchLimitOne
            item[kSecReturnData as String] = true
            var value: CFTypeRef?
            guard SecItemCopyMatching(item as CFDictionary, &value) == errSecSuccess,
                  let data = value as? Data else {
                throw DockError.message("Keychain 저장한 계정 데이터를 읽지 못했습니다.")
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
        guard status == errSecSuccess else { throw DockError.message("저장한 계정을 Keychain에 저장하지 못했습니다.") }
    }
    @discardableResult
    static func upsert(_ candidate: AccountPreset, preserveName: Bool = true, serviceName: String = service) throws -> AccountPreset {
        if let existing = try all(serviceName: serviceName).first(where: { $0.identityKey == candidate.identityKey }) {
            let updated = AccountPreset(id: existing.id, name: preserveName ? existing.name : candidate.name,
                email: candidate.email, plan: candidate.plan, savedAt: candidate.savedAt, credential: candidate.credential)
            let status = SecItemUpdate(query(existing.id, serviceName: serviceName) as CFDictionary,
                [kSecValueData as String: try JSONEncoder().encode(updated)] as CFDictionary)
            guard status == errSecSuccess else { throw DockError.message("저장한 계정을 갱신하지 못했습니다.") }
            return updated
        }
        try save(candidate, serviceName: serviceName)
        return candidate
    }
    static func delete(_ id: String, serviceName: String = service) throws {
        let status = SecItemDelete(query(id, serviceName: serviceName) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DockError.message("저장한 계정을 삭제하지 못했습니다.")
        }
    }
    static func credential(at home: String, expectedEmail: String? = nil) throws -> Data {
        let path = URL(fileURLWithPath: home).appendingPathComponent("auth.json")
        let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular else {
            throw DockError.message("일반 인증 파일만 저장한 계정으로 저장할 수 있습니다.")
        }
        let data = try Data(contentsOf: path)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any], tokens["refresh_token"] is String else {
            throw DockError.message("이 인증 방식은 아직 저장한 계정 저장을 지원하지 않습니다.")
        }
        if let expectedEmail {
            // Reject a file changed to a different identity after account/read completed.
            guard let token = tokens["id_token"] as? String else {
                throw DockError.message("계정 식별 정보를 확인하지 못했습니다. 다시 로그인해 주세요.")
            }
            let parts = token.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count >= 2 else { throw DockError.message("계정 식별 정보가 올바르지 않습니다.") }
            var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
            guard let decoded = Data(base64Encoded: payload),
                  let claims = try? JSONSerialization.jsonObject(with: decoded) as? [String: Any],
                  let email = claims["email"] as? String,
                  email.caseInsensitiveCompare(expectedEmail) == .orderedSame else {
                throw DockError.message("조회한 계정과 인증 파일이 다릅니다. 새로고침 후 다시 시도해 주세요.")
            }
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

// Keychain can wait for an OS access prompt. Keep it off the UI executor and
// serialize operations so adding/updating an identity remains ordered.
actor AccountVault {
    static let shared = AccountVault()
    func all() throws -> [AccountPreset] { try PresetVault.all() }
    @discardableResult
    func upsert(_ entry: AccountPreset, preserveName: Bool = true) throws -> AccountPreset {
        try PresetVault.upsert(entry, preserveName: preserveName)
    }
    func delete(_ id: String) throws { try PresetVault.delete(id) }
    func checkAccess() throws -> Bool {
        let probe = AccountPreset(id: UUID().uuidString, name: "access-check", email: "", plan: nil,
                                  savedAt: Date(), credential: Data("access-check".utf8))
        let service = "app.accountdock.access-check"
        defer { try? PresetVault.delete(probe.id, serviceName: service) }
        try PresetVault.save(probe, serviceName: service)
        return try PresetVault.all(serviceName: service).contains { $0.id == probe.id }
    }
}
