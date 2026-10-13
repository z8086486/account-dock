import XCTest
import AppKit
@testable import AccountDock

final class NativeTests: XCTestCase {
    @MainActor func testPreviewReleaseSelectionRejectsDraftsAndForeignAssets() throws {
        func release(_ version: String, draft: Bool = false, preview: Bool = true,
                     arch: String = "arm64", host: String = "github.com") -> [String: Any] {
            let name = "AccountDock-\(version)-\(arch)-preview.dmg"
            return ["draft": draft, "prerelease": preview, "tag_name": "v" + version,
                "assets": [["name": name, "state": "uploaded",
                    "browser_download_url": "https://\(host)/z8086486/account-dock/releases/download/v\(version)/\(name)"]]]
        }
        let data = try JSONSerialization.data(withJSONObject: [release("1.0.0", preview: false),
            release("1.1.0"), release("9.0.0", draft: true), release("8.0.0", arch: "x86_64"),
            release("7.0.0", host: "example.com")])
        XCTAssertEqual(try VersionService.downloadableRelease(data, architecture: "arm64", includePreviews: true)?.version, "1.1.0")
        XCTAssertEqual(try VersionService.downloadableRelease(data, architecture: "arm64", includePreviews: false)?.version, "1.0.0")
        XCTAssertNil(try VersionService.downloadableRelease(Data("[]".utf8), architecture: "arm64", includePreviews: true))
        XCTAssertThrowsError(try VersionService.downloadableRelease(Data("{}".utf8), architecture: "arm64", includePreviews: true))
    }
    func testAccountLabelsPreferNamesAndHandleAmbiguousEmails() {
        let named = AccountPreset(id: "a", name: " 업무 ", email: "test@example.com", plan: "plus", savedAt: Date(), credential: Data())
        let unnamed = AccountPreset(id: "b", name: "  ", email: "other@example.com", plan: nil, savedAt: Date(), credential: Data())
        XCTAssertEqual(named.displayName, "업무")
        XCTAssertEqual(named.planLabel, "Plus")
        XCTAssertEqual(unnamed.displayName, "other@example.com")
        XCTAssertEqual(unnamed.planLabel, "플랜 확인 필요")
        XCTAssertEqual(AppAccountPresentation.displayName("TEST@example.com", presets: [named]), "업무")
        let otherOrganization = AccountPreset(id: "c", name: "다른 조직", email: named.email, plan: nil, savedAt: Date(), credential: Data())
        XCTAssertEqual(AppAccountPresentation.displayName(named.email, presets: [named, otherOrganization]), named.email)
    }
    func home() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }
    @MainActor func testUsageBatchRunsConcurrentlyAndKeepsOtherResultsAfterFailure() async {
        let accounts = (0..<5).map { AccountPreset(id: String($0), name: "Fixture", email: "fixture@example.com", plan: nil, savedAt: Date(), credential: Data([UInt8($0)])) }
        final class Counter { var active = 0; var peak = 0 }
        let counter = Counter()
        var results: [String: UsageReport] = [:]
        await UsageBatch.read(accounts, limit: 3, reader: { credential in
            counter.active += 1; counter.peak = max(counter.peak, counter.active)
            defer { counter.active -= 1 }
            try await Task.sleep(for: .milliseconds(30))
            if credential.first == 1 { throw CancellationError() }
            return UsageReport(status: "available", windows: [], activity: [:], checkedAt: 1)
        }) { id, report in results[id] = report }
        XCTAssertEqual(counter.peak, 3)
        XCTAssertEqual(results.count, 5)
        XCTAssertEqual(results["1"]?.status, "unavailable")
        XCTAssertEqual(results["4"]?.status, "available")
    }
    @MainActor func testConnectionGroupingExcludesPrimaryButKeepsDedicatedAccounts() {
        let rows = ["1", "2"].map { AppIdentity(id: $0, product: "codex", status: "stored_account", email: "a@example.com", plan: nil, home: "/shared", version: $0) }
            + [AppIdentity(id: "3", product: "codex", status: "stored_account", email: "b@example.com", plan: nil, home: VSCodeIsolation.home.path, version: "2")]
        XCTAssertEqual(AppAccountPresentation.grouped(rows).count, 2)
        XCTAssertEqual(AppAccountPresentation.grouped(rows).first?.version, "1, 2")
        let presets = ["a", "b", "c"].map { AccountPreset(id: $0, name: $0, email: "\($0)@example.com", plan: nil, savedAt: Date(), credential: Data()) }
        XCTAssertEqual(AppAccountPresentation.choices(presets, accounts: rows).map(\.id), ["b", "c"])
    }
    @MainActor func testAccountWorkspacesSeparateOrganizationsAndSurviveRenameAndTokenRefresh() throws {
        func preset(_ account: String, name: String = "", id: String = "a", token: String = "old") -> AccountPreset {
            let claims = Data(#"{"email":"fixture@example.com"}"#.utf8).base64EncodedString()
            let data = Data("{\"tokens\":{\"account_id\":\"\(account)\",\"access_token\":\"\(token)\",\"id_token\":\"x.\(claims).x\"}}".utf8)
            return AccountPreset(id: id, name: name, email: "fixture@example.com", plan: nil, savedAt: Date(), credential: data)
        }
        let first = preset("org-one"), second = preset("org-two")
        let a = VSCodeIsolation.workspace(for: first), b = VSCodeIsolation.workspace(for: second)
        XCTAssertNotEqual(a.home, b.home)
        XCTAssertNotEqual(a.userData, b.userData)
        XCTAssertLessThan(a.userData.appendingPathComponent("1.99-main.sock").path.utf8.count, 104)
        XCTAssertEqual(a, VSCodeIsolation.workspace(for: preset("org-one", name: "renamed", id: "new-id", token: "renewed")))
        XCTAssertTrue(VSCodeIsolation.isManagedHome(a.home.path))
        XCTAssertFalse(VSCodeIsolation.isManagedHome("/tmp/codex"))
        XCTAssertNoThrow(try VSCodeIsolation.requireMatchingIdentity(preset("org-one", token: "renewed").credential, preset: first))
        XCTAssertThrowsError(try VSCodeIsolation.requireMatchingIdentity(second.credential, preset: first))
        XCTAssertThrowsError(try VSCodeIsolation.requireMatchingIdentity(nil, preset: first))
        XCTAssertFalse(VSCodeIsolation.targetsManagedStore(args: ["--user-data-dir", a.userData.path], environment: ["CODEX_HOME": a.home.path], home: b.home, userData: b.userData))
    }
    @MainActor func testPreparingSecondAccountDoesNotChangeFirstAccount() throws {
        let base = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: base) }
        let a = VSCodeIsolation.Workspace(root: base.appendingPathComponent("first"))
        let b = VSCodeIsolation.Workspace(root: base.appendingPathComponent("second"))
        try VSCodeIsolation.prepare(a, name: "First")
        let auth = Data("first-account-token".utf8)
        try auth.write(to: a.home.appendingPathComponent("auth.json"))
        let settings = try Data(contentsOf: a.userData.appendingPathComponent("User/settings.json"))
        try VSCodeIsolation.prepare(b, name: "Second")
        XCTAssertEqual(try Data(contentsOf: a.home.appendingPathComponent("auth.json")), auth)
        XCTAssertEqual(try Data(contentsOf: a.userData.appendingPathComponent("User/settings.json")), settings)
        XCTAssertFalse(FileManager.default.fileExists(atPath: b.home.appendingPathComponent("auth.json").path))
        try VSCodeIsolation.prepare(a, name: "First")
        let conflicting = VSCodeIsolation.Workspace(root: base.appendingPathComponent("third"), userData: a.userData)
        XCTAssertThrowsError(try VSCodeIsolation.prepare(conflicting, name: "Third"))
        XCTAssertTrue(String(decoding: try Data(contentsOf: b.userData.appendingPathComponent("User/settings.json")), as: UTF8.self).contains("Second"))
    }
    @MainActor func testAppearanceImportLimitsScopeAndParsesComments() throws {
        let source = Data(#"{ /* comment */ "workbench.colorTheme":"Fixture", "editor.fontSize":15, "secret":"keep out", }"#.utf8)
        let destination = Data(#"{"chatgpt.openOnStartup":true,"window.title":"Dedicated","editor.fontSize":12}"#.utf8)
        let result = try JSONSerialization.jsonObject(with: VSCodeEnvironment.mergedAppearance(source: source, destination: destination)) as! [String: Any]
        XCTAssertEqual(result["workbench.colorTheme"] as? String, "Fixture")
        XCTAssertEqual(result["window.title"] as? String, "Dedicated")
        XCTAssertNil(result["secret"])
        XCTAssertEqual(result["editor.fontSize"] as? Int, 15)
    }
    @MainActor func testHistoryLinksKeepCredentialsSeparateAndRefuseExistingHistory() throws {
        let source = try home(), target = try home()
        let settings = target.appendingPathComponent("settings.json"), original = source.appendingPathComponent("settings.json")
        try Data("{}".utf8).write(to: settings); try Data("{}".utf8).write(to: original)
        let credential = Data("dedicated-auth".utf8)
        try credential.write(to: target.appendingPathComponent("auth.json"))
        try FileManager.default.createDirectory(at: source.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: source.appendingPathComponent("sessions/example.jsonl"))
        try VSCodeEnvironment.prepare(source: source, destination: target, sourceSettings: original, targetSettings: settings)
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("sessions/example.jsonl")), Data("fixture".utf8))
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("auth.json")), credential)
        try VSCodeEnvironment.prepare(source: source, destination: target, sourceSettings: original, targetSettings: settings)
        let conflict = try home()
        try FileManager.default.createDirectory(at: conflict.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try VSCodeEnvironment.prepare(source: source, destination: conflict, sourceSettings: original, targetSettings: settings))
        XCTAssertFalse(FileManager.default.fileExists(atPath: conflict.appendingPathComponent("archived_sessions").path))
    }
    func testTransactionConflictAndActivityFailurePreserveCurrentAccount() throws {
        let directory = try home(), path = directory.appendingPathComponent("auth.json")
        let old = Data("old".utf8), new = Data("new".utf8)
        try old.write(to: path)
        XCTAssertThrowsError(try AuthTransaction.install(new, home: directory, expected: nil) {})
        XCTAssertEqual(try Data(contentsOf: path), old)
        XCTAssertThrowsError(try AuthTransaction.install(new, home: directory, expected: old) { throw CancellationError() })
        XCTAssertEqual(try Data(contentsOf: path), old)
        try AuthTransaction.install(new, home: directory, expected: old) {}
        XCTAssertEqual(try Data(contentsOf: path), new)
    }
    func testChangesDuringFinalGateAreNotOverwritten() throws {
        let directory = try home(), path = directory.appendingPathComponent("auth.json")
        let old = Data("old".utf8), external = Data("external".utf8)
        try old.write(to: path)
        XCTAssertThrowsError(try AuthTransaction.install(Data("new".utf8), home: directory, expected: old) {
            try external.write(to: path)
        })
        XCTAssertEqual(try Data(contentsOf: path), external)
    }
    func testDanglingSymlinkIsNotTreatedAsSignedOut() throws {
        let directory = try home(), path = directory.appendingPathComponent("auth.json")
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: directory.appendingPathComponent("missing"))
        XCTAssertThrowsError(try AuthTransaction.snapshot(path))
    }
    @MainActor func testAppIdentityIsolationAndPrivateEnvironmentFiltering() throws {
        let first = try home(), second = try home()
        let payload = Data(#"{"email":"fixture@example.com"}"#.utf8).base64EncodedString()
        try Data("{\"tokens\":{\"id_token\":\"x.\(payload).x\"}}".utf8).write(to: first.appendingPathComponent("auth.json"))
        XCTAssertEqual(try AppIdentityReader.storedIdentity(first.path).email, "fixture@example.com")
        XCTAssertNil(try AppIdentityReader.storedIdentity(second.path).email)
        var argc: Int32 = 2
        var data = withUnsafeBytes(of: &argc) { Data($0) }
        data.append(Data("/fixture\0\0/fixture\0app-server\0HOME=/fixture\0SECRET=do-not-copy\0CODEX_HOME=/isolated\0\0".utf8))
        let parsed = try AppIdentityReader.parseArguments(data)
        XCTAssertEqual(parsed.0, ["/fixture", "app-server"])
        XCTAssertEqual(parsed.1, ["HOME": "/fixture", "CODEX_HOME": "/isolated"])
    }
    @MainActor func testLimitsCreditsAndMalformedNumbers() {
        let result = UsageReader.normalize(limits: ["rateLimits": ["primary": ["usedPercent": 125, "windowDurationMins": true], "credits": ["hasCredits": true, "balance": NSNull()]], "rateLimitResetCredits": ["availableCount": 3]], activity: nil)
        XCTAssertEqual(result.status, "partial")
        XCTAssertEqual(result.windows.first?.remainingPercent, 0)
        XCTAssertNil(result.windows.first?.windowMinutes)
        XCTAssertEqual(result.credits?.first?.status, "available")
        XCTAssertNil(result.credits?.first?.balance)
        XCTAssertEqual(result.resetCredits, 3)
        XCTAssertEqual(UsageReader.normalize(limits: nil, activity: nil).status, "unavailable")
        XCTAssertEqual(UsageReader.normalize(limits: [:], activity: [:], requiresLogin: true).status, "login_required")
    }
    @MainActor func testExpiredCredentialNeverLaunchesOrChangesHome() async throws {
        let payload = Data(#"{"exp":1}"#.utf8).base64EncodedString()
        let credential = Data("{\"tokens\":{\"access_token\":\"x.\(payload).x\",\"account_id\":\"fixture\"}}".utf8)
        let result = try await UsageReader.read(credential)
        XCTAssertEqual(result.status, "login_required")
    }
    @MainActor func testVersionAndProcessParsing() throws {
        XCTAssertTrue(VersionService.newer("26.10.2", "26.9.99"))
        XCTAssertFalse(VersionService.newer("0.6.0-beta", "0.5.0"))
        XCTAssertFalse(VersionService.newer("1.0", "1.0.0"))
        let rows = ActivityGate.processRows(" 123 1 /Applications/Visual Studio Code.app/Contents/MacOS/Electron\ninvalid")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].path, "/Applications/Visual Studio Code.app/Contents/MacOS/Electron")
    }
    @MainActor func testTransportAndTimeoutCleanUp() async throws {
        let directory = try home(), binary = directory.appendingPathComponent("fixture")
        // No network and no credentials. One JSON-RPC reply then deliberately no further replies.
        try Data("#!/bin/sh\nread line\nprintf '%s\\n' '{\"id\":1,\"result\":{\"ok\":true}}'\nwhile read line; do :; done\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let connection = try CodexConnection(binary: binary, home: directory)
        let result = try await connection.request("fixture")
        XCTAssertEqual(result["ok"] as? Bool, true)
        do { _ = try await connection.request("no-response", timeout: 0.1); XCTFail("Expected timeout") }
        catch { XCTAssertTrue(error.localizedDescription.contains("초과")) }
        await connection.shutdown()
        XCTAssertTrue(connection.isClosed)
    }
    func testIsolatedRollbackPreservesExternalWritesAndRestoresSignedOut() throws {
        let directory = try home(), path = directory.appendingPathComponent("auth.json")
        let applied = Data("candidate".utf8), original = Data("original".utf8)
        try applied.write(to: path)
        try AuthTransaction.rollback(original, home: directory, expected: applied) {}
        XCTAssertEqual(try Data(contentsOf: path), original)
        XCTAssertThrowsError(try AuthTransaction.rollback(nil, home: directory, expected: applied) {})
        XCTAssertEqual(try Data(contentsOf: path), original)
        XCTAssertThrowsError(try AuthTransaction.rollback(nil, home: directory, expected: original) { throw CancellationError() })
        XCTAssertEqual(try Data(contentsOf: path), original)
        try AuthTransaction.rollback(nil, home: directory, expected: original) {}
        XCTAssertNil(try AuthTransaction.snapshot(path))
    }
    @MainActor func testManagedVSCodeGuardDoesNotTargetExistingApps() {
        let home = URL(fileURLWithPath: "/tmp/account-dock-test/codex")
        let user = URL(fileURLWithPath: "/tmp/account-dock-test/user-data")
        XCTAssertFalse(VSCodeIsolation.targetsManagedStore(args: ["app-server"], environment: ["CODEX_HOME": "/tmp/shared-codex"], home: home, userData: user))
        XCTAssertTrue(VSCodeIsolation.targetsManagedStore(args: ["app-server"], environment: ["CODEX_HOME": home.path], home: home, userData: user))
        XCTAssertTrue(VSCodeIsolation.targetsManagedStore(args: ["--user-data-dir", user.path], environment: [:], home: home, userData: user))
        XCTAssertTrue(VSCodeIsolation.targetsManagedStore(args: ["--user-data-dir=" + user.path], environment: [:], home: home, userData: user))
        let environment = VSCodeIsolation.launchEnvironment(["HOME": "/Users/fixture", "CODEX_HOME": "/tmp/shared-codex", "VSCODE_IPC_HOOK_CLI": "existing-window", "VSCODE_IPC_HOOK": "legacy-instance", "VSCODE_PID": "123", "OPENAI_API_KEY": "fixture", "ELECTRON_RUN_AS_NODE": "1"], home: home)
        XCTAssertEqual(environment["CODEX_HOME"], home.path)
        XCTAssertEqual(environment["HOME"], "/Users/fixture")
        XCTAssertNil(environment["VSCODE_IPC_HOOK_CLI"])
        XCTAssertNil(environment["VSCODE_IPC_HOOK"])
        XCTAssertNil(environment["VSCODE_PID"])
        XCTAssertNil(environment["OPENAI_API_KEY"])
        XCTAssertNil(environment["ELECTRON_RUN_AS_NODE"])
    }
    @MainActor func testDedicatedCloseFixtureWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["ACCOUNT_DOCK_CLOSE_CHECK"] == "1" else {
            throw XCTSkip("Opt-in disposable VS Code instance check")
        }
        let original = NSRunningApplication.runningApplications(withBundleIdentifier: "com.microsoft.VSCode")
        let key = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let workspace = VSCodeIsolation.Workspace(root: VSCodeIsolation.root.appendingPathComponent("accounts/" + key + key),
            userData: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".account-dock/code/" + key))
        try VSCodeIsolation.prepare(workspace, name: "Account Dock close test")
        defer {
            if (try? VSCodeIsolation.isRunning(workspace)) == false {
                try? FileManager.default.removeItem(at: workspace.root)
                try? FileManager.default.removeItem(at: workspace.userData)
            }
        }
        let process = Process()
        process.executableURL = VSCodeIsolation.executable
        process.arguments = ["--user-data-dir", workspace.userData.path, "--new-window", "--disable-extensions", "--skip-welcome", "--skip-release-notes"]
        process.environment = VSCodeIsolation.launchEnvironment(ProcessInfo.processInfo.environment, home: workspace.home)
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        for _ in 0..<100 {
            if !process.isRunning, try VSCodeIsolation.isRunning(workspace) { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTAssertTrue(try VSCodeIsolation.isRunning(workspace))
        try await Task.sleep(for: .seconds(2))
        let closed = try await VSCodeIsolation.close(home: workspace.home.path)
        XCTAssertTrue(closed)
        XCTAssertFalse(try VSCodeIsolation.isRunning(workspace))
        XCTAssertTrue(original.allSatisfy { !$0.isTerminated }, "Pre-existing VS Code instances must remain running")
    }
    @MainActor func testCloseRequiresBothDedicatedPathsAndRejectsMainVSCode() throws {
        let workspace = VSCodeIsolation.Workspace(root: URL(fileURLWithPath: "/private/tmp/dedicated"))
        let args = ["--user-data-dir", workspace.userData.path]
        let environment = ["CODEX_HOME": workspace.home.path]
        XCTAssertTrue(VSCodeIsolation.matchesCloseTarget(args: args, environment: environment, workspace: workspace))
        XCTAssertTrue(VSCodeIsolation.matchesCloseTarget(args: ["--user-data-dir=" + workspace.userData.path], environment: environment, workspace: workspace))
        XCTAssertFalse(VSCodeIsolation.matchesCloseTarget(args: [], environment: environment, workspace: workspace))
        XCTAssertFalse(VSCodeIsolation.matchesCloseTarget(args: args, environment: [:], workspace: workspace))
        XCTAssertFalse(VSCodeIsolation.matchesCloseTarget(args: args, environment: ["CODEX_HOME": "/Users/fixture/.codex"], workspace: workspace))
        XCTAssertFalse(VSCodeIsolation.matchesCloseTarget(args: ["--user-data-dir", "/private/tmp/other"], environment: environment, workspace: workspace))
        XCTAssertThrowsError(try VSCodeIsolation.closeWorkspace(for: nil))
        XCTAssertThrowsError(try VSCodeIsolation.closeWorkspace(for: AccessSetup.home))
        XCTAssertThrowsError(try VSCodeIsolation.closeWorkspace(for: VSCodeIsolation.root.appendingPathComponent("accounts/not-a-key/codex").path))
    }
    @MainActor func testManagedDirectoryRejectsSymlinks() throws {
        let directory = try home()
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
        XCTAssertThrowsError(try VSCodeIsolation.validateDirectory(link))
    }
    @MainActor func testLiveReadOnlyWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["ACCOUNT_DOCK_LIVE_CHECK"] == "1" else { throw XCTSkip("Opt-in local read-only check") }
        let directory = URL(fileURLWithPath: AccessSetup.home)
        let before = try AuthTransaction.snapshot(directory.appendingPathComponent("auth.json"))
        let connection = try CodexConnection(binary: CodexService.binary(), home: directory)
        do {
            try await connection.initialize()
            let report = try await CodexService.report(connection: connection, home: directory)
            XCTAssertEqual(report.codex.status, "cached_account")
            XCTAssertTrue(report.file_presets_supported)
            await connection.shutdown()
        } catch { await connection.shutdown(); throw error }
        if let before {
            let usage = try await UsageReader.read(before)
            XCTAssertTrue(["available", "partial", "login_required"].contains(usage.status))
        }
        XCTAssertEqual(try AuthTransaction.snapshot(directory.appendingPathComponent("auth.json")), before)
    }
}
