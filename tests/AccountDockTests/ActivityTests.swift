import XCTest
import AppKit
@testable import AccountDock

final class ActivityTests: XCTestCase {
    private func line(_ type: String, _ payload: [String: Any], at: String = "2026-10-13T10:00:00.000Z") throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: ["type": type, "timestamp": at, "payload": payload])
        data.append(10); return data
    }
    private func count(_ total: Int) throws -> Data {
        try line("event_msg", ["type": "token_count", "info": ["total_token_usage": ["total_tokens": total]]])
    }
    func testLiveOwnershipRejectsConflictingAccounts() {
        let a = URL(fileURLWithPath: "/tmp/a.jsonl")
        let b = URL(fileURLWithPath: "/tmp/b.jsonl")
        let owners = ActivityOwnership.unique([a: ["personal"], b: ["personal", "work"]])
        XCTAssertEqual(owners[a], "personal")
        XCTAssertNil(owners[b])
    }
    func testCumulativeDuplicatesAndOutOfOrderDoNotInflate() throws {
        var state = ActivityLogState()
        state.append(try line("session_meta", ["creator_account_id": "account-A"]))
        for count in [100, 100, 70, 140] { state.append(try self.count(count)) }
        XCTAssertEqual(state.days.values.reduce(0) { $0 + $1["account-A", default: 0] }, 140)
        state.append(try line("event_msg", ["type": "token_usage_record", "usage": ["total_tokens": 140]]))
        XCTAssertEqual(state.previousTotal, 140)
    }
    func testSplitLinesAndConcurrentTurns() throws {
        var state = ActivityLogState()
        let data = try count(42)
        state.append(Data(data.prefix(12)))
        XCTAssertTrue(state.days.isEmpty)
        state.append(Data(data.dropFirst(12)))
        XCTAssertEqual(state.previousTotal, 42)
        for id in ["a", "b"] { state.append(try line("event_msg", ["type": "task_started", "turn_id": id])) }
        state.append(try line("event_msg", ["type": "task_complete", "turn_id": "a"]))
        XCTAssertEqual(state.turns, ["b"])
        state.append(try line("event_msg", ["type": "turn_aborted", "turn_id": "b"]))
        XCTAssertTrue(state.turns.isEmpty)
    }
    func testScannerDeduplicatesLinkedHistoryAndReadsOnlyAppends() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessions = root.appendingPathComponent("sessions")
        let managed = root.appendingPathComponent("managed")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: managed.appendingPathComponent("codex"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: managed.appendingPathComponent("codex/sessions"), withDestinationURL: sessions)
        let file = sessions.appendingPathComponent("rollout.jsonl")
        var data = try line("session_meta", ["creator_account_id": "account-A"])
        data.append(try count(100))
        data.append(try line("event_msg", ["type": "task_started", "turn_id": "a"]))
        try data.write(to: file)
        let scanner = ActivityScanner(root: root, managed: managed)
        let now = ActivityLogState.parseDate("2026-10-13T10:00:10Z")!
        let first = await scanner.scan(root: root, now: now)
        XCTAssertEqual(first.tokens(), 100)
        XCTAssertTrue(first.active)
        let unchanged = await scanner.scan(root: root, now: now)
        XCTAssertEqual(unchanged.tokens(), 100)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: count(150))
        try handle.write(contentsOf: line("event_msg", ["type": "task_complete", "turn_id": "a"]))
        try handle.close()
        let updated = await scanner.scan(root: root, now: now)
        XCTAssertEqual(updated.tokens(), 150)
        XCTAssertFalse(updated.active)
        try count(5).write(to: file)
        let truncated = await scanner.scan(root: root, now: now)
        XCTAssertEqual(truncated.tokens(), 5)
    }
    func testCacheResumesWithoutPersistingPartialConversationText() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("cache.json")
        let file = sessions.appendingPathComponent("a.jsonl")
        var data = try line("session_meta", ["creator_account_id": "a"])
        data.append(try count(100)); data.append(Data("PRIVATE_PARTIAL_MESSAGE".utf8))
        try data.write(to: file)
        let scanner = ActivityScanner(root: root, managed: root.appendingPathComponent("none"), cacheURL: cache)
        let first = await scanner.scan(root: root)
        XCTAssertEqual(first.tokens(), 100)
        let cached = try String(contentsOf: cache, encoding: .utf8)
        XCTAssertFalse(cached.contains("PRIVATE_PARTIAL_MESSAGE"))
        let cacheJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(cached.utf8)) as? [String: Any])
        let entries = try XCTUnwrap(cacheJSON["files"] as? [String: [String: Any]])
        XCTAssertTrue(entries.values.allSatisfy { ($0["pending"] as? String) == "" })
        let resumed = ActivityScanner(root: root, managed: root.appendingPathComponent("none"), cacheURL: cache)
        let second = await resumed.scan(root: root)
        XCTAssertEqual(second.tokens(), 100)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("\n".utf8)); try handle.write(contentsOf: count(150)); try handle.close()
        let third = await resumed.scan(root: root)
        XCTAssertEqual(third.tokens(), 150)
    }
    func testTwoAccountsRunConcurrentlyAndOneCanFinishIndependently() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let stamp = now.formatted(.iso8601)
        for account in ["a", "b"] {
            var data = try line("session_meta", ["creator_account_id": account], at: stamp)
            data.append(try line("event_msg", ["type": "task_started", "turn_id": account], at: stamp))
            try data.write(to: sessions.appendingPathComponent(account + ".jsonl"))
        }
        let scanner = ActivityScanner(root: root, managed: root.appendingPathComponent("none"))
        let first = await scanner.scan(root: root, now: now)
        XCTAssertEqual(first.activeAccounts, ["a": 1, "b": 1])
        let handle = try FileHandle(forWritingTo: sessions.appendingPathComponent("a.jsonl"))
        try handle.seekToEnd(); try handle.write(contentsOf: line("event_msg", ["type": "task_complete", "turn_id": "a"], at: stamp)); try handle.close()
        let second = await scanner.scan(root: root, now: now)
        XCTAssertEqual(second.activeAccounts, ["b": 1])
        XCTAssertTrue(second.active)
    }
    @MainActor func testWheelRotationLayerKeepsItsCenterWhenViewRelayouts() {
        let view = WheelStatusImage(frame: NSRect(x: 4, y: 2, width: 20, height: 20))
        view.layout()
        XCTAssertEqual(view.rotor.anchorPoint, CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(view.rotor.position, CGPoint(x: 10, y: 10))
        XCTAssertTrue(view.rotor.superlayer === view.layer)
        let original = view.frame
        view.layout()
        XCTAssertEqual(view.frame, original)
        XCTAssertEqual(view.rotor.position, CGPoint(x: 10, y: 10))
        XCTAssertNil(view.hitTest(CGPoint(x: 10, y: 10)))
    }
    func testRegisteredAccountScopeExcludesUnknownAndRemovedAccounts() {
        let snapshot = ActivitySnapshot(limits: [:], days: ["2026-10-13": ["a": 100, "b": 200, ActivitySnapshot.unknown: 500]],
            activeAccounts: ["a": 1, "b": 2, ActivitySnapshot.unknown: 1], active: true)
        let filtered = snapshot.filtered(accounts: ["a"])
        XCTAssertEqual(filtered.tokens(), 100)
        XCTAssertEqual(filtered.activeAccounts, ["a": 1])
        XCTAssertTrue(filtered.active) // wheel follows all Codex work, including unregistered accounts
    }
    @MainActor func testPassiveRateLimitsRefreshWithoutTokenCountOrNetwork() throws {
        var state = ActivityLogState()
        state.append(try line("session_meta", ["creator_account_id": "a"]))
        state.append(try line("event_msg", ["type": "token_count", "info": NSNull(), "rate_limits": [
            "limit_id": "codex", "primary": ["used_percent": 25, "window_minutes": 300],
            "credits": ["has_credits": true, "balance": "12.5", "unlimited": false]]]))
        let report = LocalUsageReport.normalize(try XCTUnwrap(state.limit))
        XCTAssertEqual(report?.windows.first?.remainingPercent, 75)
        XCTAssertEqual(report?.credits?.first?.balance, "12.5")
        XCTAssertTrue(state.days.isEmpty)
    }
    func testStaleStartedTurnDoesNotKeepWheelSpinning() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try line("event_msg", ["type": "task_started", "turn_id": "a"]).write(to: sessions.appendingPathComponent("a.jsonl"))
        let scanner = ActivityScanner(root: root, managed: root.appendingPathComponent("none"))
        let result = await scanner.scan(root: root, now: ActivityLogState.parseDate("2026-10-13T10:05:00Z")!)
        XCTAssertFalse(result.active)
    }
}
