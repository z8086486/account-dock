import XCTest
import AppKit
@testable import AccountDock

final class ActivityTests: XCTestCase {
    @MainActor func testRotaryKeepsHousingFixedAndPreservesPhase() throws {
        let view = RotaryIconView(frame: NSRect(x: 0, y: 0, width: 14, height: 22), template: true)
        view.configure(count: 1, reduceMotion: false)
        let animation = try XCTUnwrap(view.frameLayer.animation(forKey: "rotaryFrames") as? CAKeyframeAnimation)
        XCTAssertEqual(animation.duration, MenuBarController.rotationDuration(conversations: 1) * 3, accuracy: 0.000001)
        XCTAssertEqual(animation.values?.count, RotaryIconView.frameCount + 1)
        XCTAssertTrue(CATransform3DIsIdentity(view.frameLayer.transform))
        XCTAssertEqual(view.frameLayer.bounds.width, 20)
        XCTAssertEqual(view.frameLayer.position, CGPoint(x: 7, y: 11))
        view.pause()
        let paused = view.currentPhase()
        XCTAssertEqual(paused, view.currentPhase(at: CACurrentMediaTime() + 100), accuracy: 0.00001)
        XCTAssertNil(view.frameLayer.animationKeys())
        view.configure(count: 4, reduceMotion: false)
        XCTAssertEqual(view.phase, paused, accuracy: 0.00001)
        XCTAssertEqual(try XCTUnwrap(view.frameLayer.animation(forKey: "rotaryFrames")).duration, 2.4, accuracy: 0.00001)
        view.configure(count: 4, reduceMotion: true)
        XCTAssertNil(view.frameLayer.animationKeys())
        XCTAssertEqual(view.count, 0)
    }
    @MainActor func testRotarySelectionSwitchesWithoutSpinningHousingOrLeavingLayers() {
        let view = PanelWheelView(frame: NSRect(x: 0, y: 0, width: 36, height: 36))
        view.configure(design: .fiveSpoke, count: 1)
        view.configure(design: .rotary, count: 1)
        XCTAssertTrue(view.wheelLayer.isHidden)
        XCTAssertNil(view.wheelLayer.animation(forKey: "codexWorking"))
        XCTAssertEqual(view.subviews.compactMap { $0 as? RotaryIconView }.count, 1)
        view.configure(design: .classic, count: 1)
        XCTAssertFalse(view.wheelLayer.isHidden)
        XCTAssertTrue(view.subviews.isEmpty)
        XCTAssertNotNil(view.wheelLayer.animation(forKey: "codexWorking"))
        view.stopAnimation()
    }
    @MainActor func testRotaryArtworkLoadsAndRenders() throws {
        XCTAssertGreaterThan(RotaryIcon.geometry["rotor"]?.count ?? 0, 100)
        XCTAssertEqual(RotaryIcon.geometry["bolts"]?.count, 18)
        for part in [RotaryIcon.Part.housing, .rotor, .shaft, .complete] {
            let image = RotaryIcon.image(size: 264, part: part)
            var rect = CGRect(x: 0, y: 0, width: 264, height: 264)
            XCTAssertNotNil(image.cgImage(forProposedRect: &rect, context: nil, hints: nil))
        }
        if let directory = ProcessInfo.processInfo.environment["ROTARY_PREVIEW_DIR"] {
            for step in 0..<4 {
                let frame = RotaryIcon.image(size: 264, phase: -Double(step) * .pi / 2)
                let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(frame.tiffRepresentation)))
                try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("native-phase-\(step).png"))
            }
            let image = RotaryIcon.image(size: 528)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("native-rotary.png"))
        }
    }
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
        XCTAssertEqual(MenuBarController.rotationDuration(conversations: 1), 1.6)
        XCTAssertLessThan(MenuBarController.rotationDuration(conversations: 2), 1.6)
        XCTAssertLessThan(MenuBarController.rotationDuration(conversations: 4), MenuBarController.rotationDuration(conversations: 2))
        XCTAssertEqual(MenuBarController.rotationDuration(conversations: 100), 0.6)
    }
    @MainActor func testExecutionSettingsIncreaseSpeedWithoutChangingCountsOrExceedingCap() {
        let ordinary = ActiveConversation(id: "one", account: "a", effort: "medium", serviceTier: "default")
        let extra = ActiveConversation(id: "two", account: "a", effort: "xhigh", serviceTier: "priority")
        let ultra = ActiveConversation(id: "three", account: "b", effort: "ultra", serviceTier: "fast")
        XCTAssertEqual(extra.effortLabel, "Extra High")
        XCTAssertEqual(extra.speedLabel, "빠름")
        XCTAssertGreaterThan(extra.animationWeight, ordinary.animationWeight)
        XCTAssertGreaterThan(ultra.animationWeight, extra.animationWeight)
        let snapshot = ActivitySnapshot(activeAccounts: ["a": 2, "b": 1], activeConversations: [ordinary, extra, ultra], active: true)
        XCTAssertEqual(snapshot.activeAccounts["a"], 2)
        XCTAssertGreaterThan(snapshot.animationLoad, 3)
        XCTAssertLessThan(MenuBarController.rotationDuration(load: ultra.animationWeight), MenuBarController.rotationDuration(conversations: 1))
        XCTAssertEqual(MenuBarController.rotationDuration(load: 1000), 0.6)
        XCTAssertTrue(MenuBarController.rotationDuration(load: .nan).isFinite)
        XCTAssertEqual(snapshot.filtered(accounts: ["a"]).activeConversations.count, 2)
        XCTAssertEqual(ActivitySnapshot(activeConversations: [ultra]).animationLoad, 0)
        XCTAssertEqual(ActiveConversation(id: "unknown", account: "a").animationWeight, 1)
    }
    @MainActor func testRotaryRetimesSameConversationAndKeepsPhase() throws {
        let view = RotaryIconView(frame: NSRect(x: 0, y: 0, width: 36, height: 36), template: false)
        view.configure(load: 1, reduceMotion: false)
        let before = view.currentPhase()
        view.configure(load: 2.4, reduceMotion: false)
        XCTAssertGreaterThanOrEqual(view.phase, before)
        XCTAssertLessThan(view.phase - before, 0.1)
        XCTAssertEqual(try XCTUnwrap(view.frameLayer.animation(forKey: "rotaryFrames")).duration,
                       MenuBarController.rotationDuration(load: 2.4) * 3, accuracy: 0.00001)
        view.pause()
        let stopped = view.phase
        view.configure(load: 100, reduceMotion: false)
        XCTAssertEqual(view.phase, stopped, accuracy: 0.00001)
        XCTAssertEqual(try XCTUnwrap(view.frameLayer.animation(forKey: "rotaryFrames")).duration, 1.8, accuracy: 0.00001)
    }
    func testActiveTurnMetadataResetsAndExcludesConversationText() throws {
        var state = ActivityLogState()
        state.append(try line("turn_context", ["turn_id": "a", "effort": "ultra", "service_tier": "fast", "model": "gpt-example",
            "cwd": "/Users/example/work/project", "developer_instructions": "DO_NOT_STORE_THIS"]))
        XCTAssertEqual(state.turnContext?.effort, "ultra")
        XCTAssertEqual(state.turnContext?.serviceTier, "fast")
        XCTAssertEqual(state.turnContext?.project, "project")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(state), as: UTF8.self).contains("DO_NOT_STORE_THIS"))
        state.append(try line("turn_context", ["turn_id": "b", "model": "gpt-example", "collaboration_mode": ["settings": ["reasoning_effort": "xhigh"]]]))
        XCTAssertEqual(state.turnContext?.effort, "xhigh")
        XCTAssertNil(state.turnContext?.serviceTier)
        XCTAssertNil(state.turnContext?.project)
        state.append(try line("event_msg", ["type": "task_started", "turn_id": "b"]))
        state.append(try line("event_msg", ["type": "task_complete", "turn_id": "b"]))
        XCTAssertNil(state.activeTurnID)
        XCTAssertNil(state.turnContext)
    }
    func testScannerDoesNotReusePreviousTurnsSettings() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stamp = Date().formatted(.iso8601)
        var data = try line("session_meta", ["creator_account_id": "a"], at: stamp)
        data.append(try line("event_msg", ["type": "task_started", "turn_id": "first"], at: stamp))
        data.append(try line("turn_context", ["turn_id": "first", "effort": "ultra", "service_tier": "priority", "cwd": "/project"], at: stamp))
        let file = sessions.appendingPathComponent("example.jsonl")
        try data.write(to: file)
        let scanner = ActivityScanner(root: root, managed: root.appendingPathComponent("none"))
        let first = await scanner.scan(root: root)
        XCTAssertEqual(first.activeConversations.first?.effortLabel, "Ultra")
        XCTAssertEqual(first.activeConversations.first?.speedLabel, "빠름")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: line("event_msg", ["type": "task_complete", "turn_id": "first"], at: stamp))
        try handle.write(contentsOf: line("event_msg", ["type": "task_started", "turn_id": "second"], at: stamp))
        try handle.close()
        let second = await scanner.scan(root: root)
        XCTAssertEqual(second.activeAccounts["a"], 1)
        XCTAssertNil(second.activeConversations.first?.effort)
        XCTAssertNil(second.activeConversations.first?.serviceTier)
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
