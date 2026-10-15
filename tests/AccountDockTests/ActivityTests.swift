import XCTest
import AppKit
@testable import AccountDock

final class ActivityTests: XCTestCase {
    @MainActor func testPanelWheelRotatesInPlaceAcrossLayoutChanges() throws {
        let view = PanelWheelView(frame: NSRect(x: 0, y: 0, width: 36, height: 36))
        view.configure(design: .fiveSpoke, count: 2)
        XCTAssertTrue(view.wheelLayer !== view.layer)
        let spin = try XCTUnwrap(view.wheelLayer.animation(forKey: "codexWorking") as? CAKeyframeAnimation)
        for value in try XCTUnwrap(spin.values as? [NSValue]) {
            XCTAssertEqual(value.caTransform3DValue.m41, 0, accuracy: 0.00001)
            XCTAssertEqual(value.caTransform3DValue.m42, 0, accuracy: 0.00001)
        }
        view.frame.size = NSSize(width: 42, height: 40)
        view.layout()
        XCTAssertEqual(view.wheelLayer.position, CGPoint(x: 21, y: 20))
        XCTAssertEqual(view.wheelLayer.bounds.size, CGSize(width: 40, height: 40))
        view.configure(design: .fiveSpoke, count: 0)
        XCTAssertNil(view.wheelLayer.animation(forKey: "codexWorking"))
    }
    @MainActor func testPausedWheelKeepsItsModelAngleWhenNoPresentationLayerExists() {
        let layer = CALayer()
        let pose = MenuBarController.centeredRotation(angle: -1.37, pivot: CGPoint(x: 14, y: 11))
        layer.transform = pose
        MenuBarController.holdRotation(on: layer)
        XCTAssertTrue(CATransform3DEqualToTransform(layer.transform, pose))
        MenuBarController.holdRotation(on: layer)
        XCTAssertEqual(atan2(layer.transform.m12, layer.transform.m11), -1.37, accuracy: 0.00001)
        XCTAssertNil(layer.animation(forKey: "codexWorking"))
    }
    func testGulfHeatmapLevelsRemainBoundedAndOrdered() {
        XCTAssertEqual(GulfActivityPalette.level(value: 0, maximum: 0), 0)
        XCTAssertEqual(GulfActivityPalette.level(value: 1, maximum: 100), 1)
        XCTAssertEqual(GulfActivityPalette.level(value: 100, maximum: 100), 4)
        XCTAssertEqual(GulfActivityPalette.level(value: 200, maximum: 100), 4)
        let levels = (0...100).map { GulfActivityPalette.level(value: Int64($0), maximum: 100) }
        XCTAssertEqual(levels, levels.sorted())
    }

    private func line(_ type: String, _ payload: [String: Any], at: String = "2026-10-13T10:00:00.000Z") throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: ["type": type, "timestamp": at, "payload": payload])
        data.append(10); return data
    }
    private func count(_ total: Int) throws -> Data {
        try line("event_msg", ["type": "token_count", "info": ["total_token_usage": ["total_tokens": total]]])
    }
    func testRuntimeOwnerCountsOnlyObservedFutureUsage() throws {
        var state = ActivityLogState()
        state.observeOwner("work", at: 100)
        state.consume(try count(100), at: 50)
        state.consume(try count(140), at: 100)
        XCTAssertEqual(state.days.values.reduce(0) { $0 + $1["work", default: 0] }, 40)
        XCTAssertEqual(state.days.values.reduce(0) { $0 + $1[ActivitySnapshot.unknown, default: 0] }, 100)
        state.observeOwner("personal", at: 200)
        state.consume(try count(160), at: 210)
        XCTAssertEqual(state.days.values.reduce(0) { $0 + $1["personal", default: 0] }, 20)
        let restored = try JSONDecoder().decode(ActivityLogState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored.attributedAccount, "personal")
        XCTAssertEqual(restored.attributionStart, 200)
    }
    func testRuntimeAttributionSurvivesSplitLineWithoutBackfill() throws {
        var state = ActivityLogState()
        let baseline = try count(100)
        state.offset += UInt64(baseline.count); state.append(baseline)
        state.observeOwner("work", at: state.offset)
        let next = try count(135)
        state.offset += 12; state.append(Data(next.prefix(12)))
        state.offset += UInt64(next.count - 12); state.append(Data(next.dropFirst(12)))
        XCTAssertEqual(state.days.values.reduce(0) { $0 + $1["work", default: 0] }, 35)
        state.observeOwner(nil, at: state.offset)
        let unknown = try count(145)
        state.offset += UInt64(unknown.count); state.append(unknown)
        XCTAssertEqual(state.days.values.reduce(0) { $0 + $1["work", default: 0] }, 35)
    }
    @MainActor func testWheelSpeedIncreasesWithConversationCountAndIsCapped() {
        XCTAssertEqual(MenuBarController.rotationDuration(conversations: 1), 2)
        XCTAssertLessThan(MenuBarController.rotationDuration(conversations: 2), 2)
        XCTAssertLessThan(MenuBarController.rotationDuration(conversations: 4), MenuBarController.rotationDuration(conversations: 2))
        XCTAssertEqual(MenuBarController.rotationDuration(conversations: 100), 0.8)
    }
    @MainActor func testPopoverAnchorStaysOnClickedDisplay() {
        let primaryButton = CGRect(x: 1300, y: 876, width: 28, height: 24)
        for screen in [CGRect(x: -1920, y: 0, width: 1920, height: 1080),
                       CGRect(x: 1440, y: 0, width: 1920, height: 1080),
                       CGRect(x: 0, y: 900, width: 1920, height: 1080),
                       CGRect(x: 0, y: -1080, width: 1920, height: 1080)] {
            let click = CGPoint(x: screen.maxX - 100, y: screen.maxY - 12)
            let rect = MenuBarController.anchorRect(click: click, screen: screen, button: primaryButton, size: primaryButton.size)
            XCTAssertTrue(screen.contains(rect))
            XCTAssertEqual(rect.midX, click.x)
            XCTAssertEqual(rect.midY, click.y)
        }
        let sameScreen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        XCTAssertEqual(MenuBarController.anchorRect(click: CGPoint(x: 1310, y: 880), screen: sameScreen, button: primaryButton, size: primaryButton.size), primaryButton)
        let edge = MenuBarController.anchorRect(click: CGPoint(x: -1919, y: 1079), screen: CGRect(x: -1920,y:0,width:1920,height:1080), button: nil, size: primaryButton.size)
        XCTAssertEqual(edge.minX, -1920)
        XCTAssertEqual(edge.maxY, 1080)
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
    @MainActor func testWheelRotationPreservesCenterForAppKitAnchorPoints() {
        for anchor in [CGPoint.zero, CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0, y: 1)] {
            let pivot = CGPoint(x: 28 * (0.5 - anchor.x), y: 24 * (0.5 - anchor.y))
            for step in -16...16 {
                let transform = MenuBarController.centeredRotation(angle: CGFloat(step) * .pi / 8, pivot: pivot)
                let x = pivot.x * transform.m11 + pivot.y * transform.m21 + transform.m41
                let y = pivot.x * transform.m12 + pivot.y * transform.m22 + transform.m42
                XCTAssertEqual(x, pivot.x, accuracy: 0.00001)
                XCTAssertEqual(y, pivot.y, accuracy: 0.00001)
            }
        }
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
