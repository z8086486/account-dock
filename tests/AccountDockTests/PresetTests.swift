import XCTest
@testable import AccountDock

final class PresetTests: XCTestCase {
    func testKeychainRoundTripAndDeletion() throws {
        let service = "app.accountdock.tests.\(UUID().uuidString)"
        let preset = AccountPreset(id: UUID().uuidString, name: "Fixture", email: "test@example.com",
                                   plan: nil, savedAt: Date(), credential: Data("test-only".utf8))
        defer { try? PresetVault.delete(preset.id, serviceName: service) }
        try PresetVault.save(preset, serviceName: service)
        let entries = try PresetVault.all(serviceName: service)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.credential, preset.credential)
        try PresetVault.delete(preset.id, serviceName: service)
        XCTAssertTrue(try PresetVault.all(serviceName: service).isEmpty)
    }
    func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }
    func testRestorePreservesCredentialsAndUsesPrivatePermissions() throws {
        let home = try temporaryDirectory()
        let original = Data(#"{"tokens":{"refresh_token":"test-only"}}"#.utf8)
        let preset = AccountPreset(id: "fixture", name: "Test", email: "test@example.com", plan: nil,
                                   savedAt: Date(), credential: original)
        try PresetVault.restore(preset, home: home.path)
        XCTAssertEqual(try PresetVault.credential(at: home.path), original)
        let attributes = try FileManager.default.attributesOfItem(atPath: home.appendingPathComponent("auth.json").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: home.path), ["auth.json"])
    }
    func testSymlinkCredentialIsRejected() throws {
        let home = try temporaryDirectory()
        let target = home.appendingPathComponent("source")
        try Data("{}".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("auth.json"), withDestinationURL: target)
        XCTAssertThrowsError(try PresetVault.credential(at: home.path))
    }
    func testAPIKeyCredentialIsRejected() throws {
        let home = try temporaryDirectory()
        try Data(#"{"OPENAI_API_KEY":"test-only"}"#.utf8).write(to: home.appendingPathComponent("auth.json"))
        XCTAssertThrowsError(try PresetVault.credential(at: home.path))
    }
    func testFailedRestoreDoesNotChangeOtherFiles() throws {
        let home = try temporaryDirectory()
        let original = Data("existing".utf8)
        try original.write(to: home.appendingPathComponent("auth.json"))
        let preset = AccountPreset(id: "fixture", name: "Test", email: "test@example.com", plan: nil,
                                   savedAt: Date(), credential: Data("new".utf8))
        XCTAssertThrowsError(try PresetVault.restore(preset, home: home.appendingPathComponent("missing").path))
        XCTAssertEqual(try Data(contentsOf: home.appendingPathComponent("auth.json")), original)
    }
}
