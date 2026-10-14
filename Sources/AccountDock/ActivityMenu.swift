import SwiftUI
import AppKit
import Combine
import QuartzCore

/// Eight rounded spokes, deep concentric rim, open hub and four bolt holes.
/// Rendered at the display scale by AppKit; no downsampled photograph in the menu bar.
@MainActor
enum WheelIcon {
    static func image(angle: CGFloat = 0, size: CGFloat = 20, color: NSColor = .black) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            color.setFill()
            let metal = NSGradient(colors: [NSColor(white: 0.16, alpha: 1), NSColor(white: 0.48, alpha: 1), NSColor(white: 0.11, alpha: 1)])!
            let rimMetal = NSGradient(colors: [NSColor(white: 0.68, alpha: 1), NSColor(white: 0.18, alpha: 1), NSColor(white: 0.50, alpha: 1)])!
            let context = NSGraphicsContext.current!.cgContext
            context.translateBy(x: rect.midX, y: rect.midY)
            context.rotate(by: angle)
            context.scaleBy(x: size / 100, y: size / 100)
            // A continuous stepped barrel, with narrow raised lips rather than two flat rings.
            let rim = NSBezierPath()
            rim.windingRule = .evenOdd
            rim.appendOval(in: NSRect(x: -49, y: -49, width: 98, height: 98))
            rim.appendOval(in: NSRect(x: -38.5, y: -38.5, width: 77, height: 77))
            rimMetal.draw(in: rim, angle: 135)
            for (radius, width, shade) in [(48.5, 0.8, 0.68), (47.2, 1.0, 0.23),
                                           (45.9, 1.7, 0.12), (44.5, 0.9, 0.42),
                                           (42.9, 2.1, 0.17), (40.5, 1.5, 0.09),
                                           (38.9, 0.6, 0.47)] {
                let lip = NSBezierPath(ovalIn: NSRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2))
                lip.lineWidth = width
                NSColor(white: shade, alpha: 1).setStroke(); lip.stroke()
            }
            // The casting connects the hub and spoke roots without a circular overlay seam.
            let hub = NSBezierPath(ovalIn: NSRect(x: -19, y: -19, width: 38, height: 38))
            metal.draw(in: hub, angle: 135)
            for index in 0..<8 {
                context.saveGState()
                context.rotate(by: CGFloat(index) * .pi / 4 + .pi / 8)
                let spoke = NSBezierPath()
                spoke.move(to: NSPoint(x: 13, y: -3.5))
                spoke.curve(to: NSPoint(x: 25, y: -5), controlPoint1: NSPoint(x: 16, y: -5.8), controlPoint2: NSPoint(x: 20, y: -5.8))
                spoke.curve(to: NSPoint(x: 39, y: -4.5), controlPoint1: NSPoint(x: 31, y: -5), controlPoint2: NSPoint(x: 36, y: -4.5))
                spoke.curve(to: NSPoint(x: 39, y: 4.5), controlPoint1: NSPoint(x: 43, y: -4), controlPoint2: NSPoint(x: 43, y: 4))
                spoke.curve(to: NSPoint(x: 25, y: 5), controlPoint1: NSPoint(x: 36, y: 4.5), controlPoint2: NSPoint(x: 31, y: 5))
                spoke.curve(to: NSPoint(x: 13, y: 3.5), controlPoint1: NSPoint(x: 20, y: 5.8), controlPoint2: NSPoint(x: 16, y: 5.8))
                spoke.close()
                // The rounded spoke root overlaps the hub casting with a cylindrical highlight.
                context.saveGState(); spoke.addClip()
                metal.draw(in: spoke, angle: 90)
                context.restoreGState()
                context.restoreGState()
            }
            NSColor(white: 0.45, alpha: 1).setStroke()
            let bore = NSBezierPath(ovalIn: NSRect(x: -9.7, y: -9.7, width: 19.4, height: 19.4))
            bore.lineWidth = 1.4; bore.stroke()
            for index in 0..<4 {
                let a = CGFloat(index) * .pi / 2 + .pi / 4
                let seat = NSBezierPath(ovalIn: NSRect(x: cos(a) * 14 - 3.1, y: sin(a) * 14 - 3.1, width: 6.2, height: 6.2))
                seat.lineWidth = 1; seat.stroke()
            }
            let valve = NSBezierPath(ovalIn: NSRect(x: -1.1, y: -43.1, width: 2.2, height: 3.6))
            NSColor(white: 0.12, alpha: 1).setFill(); valve.fill()
            valve.lineWidth = 0.5; NSColor(white: 0.55, alpha: 1).setStroke(); valve.stroke()
            context.setBlendMode(.clear)
            NSBezierPath(ovalIn: NSRect(x: -9, y: -9, width: 18, height: 18)).fill()
            for index in 0..<4 {
                let a = CGFloat(index) * .pi / 2 + .pi / 4
                NSBezierPath(ovalIn: NSRect(x: cos(a) * 14 - 2.6, y: sin(a) * 14 - 2.6, width: 5.2, height: 5.2)).fill()
            }
            context.setBlendMode(.normal)
            return true
        }
        image.isTemplate = false
        return image
    }
    /// A single silhouette uses the menu bar's appearance, while the asymmetric valve marks rim rotation.
    static func menuImage(size: CGFloat, color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let context = NSGraphicsContext.current!.cgContext
            context.translateBy(x: rect.midX, y: rect.midY)
            context.scaleBy(x: size / 100, y: size / 100)
            color.setFill(); color.setStroke()
            let rim = NSBezierPath(ovalIn: NSRect(x: -46, y: -46, width: 92, height: 92))
            rim.lineWidth = 6; rim.stroke()
            NSBezierPath(ovalIn: NSRect(x: -19, y: -19, width: 38, height: 38)).fill()
            for index in 0..<8 {
                context.saveGState(); context.rotate(by: CGFloat(index) * .pi / 4 + .pi / 8)
                let spoke = NSBezierPath(roundedRect: NSRect(x: 13, y: -5, width: 31, height: 10), xRadius: 5, yRadius: 5)
                spoke.fill(); context.restoreGState()
            }
            // Valve on the inner lip, readable even at 20 points.
            NSBezierPath(roundedRect: NSRect(x: -3, y: -45, width: 6, height: 10), xRadius: 2, yRadius: 2).fill()
            context.setBlendMode(.clear)
            NSBezierPath(ovalIn: NSRect(x: -9, y: -9, width: 18, height: 18)).fill()
            for index in 0..<4 {
                let a = CGFloat(index) * .pi / 2 + .pi / 4
                NSBezierPath(ovalIn: NSRect(x: cos(a) * 14 - 2.7, y: sin(a) * 14 - 2.7, width: 5.4, height: 5.4)).fill()
            }
            return true
        }
    }

}

@MainActor
final class ActivityMonitor: ObservableObject {
    @Published var snapshot = ActivitySnapshot()
    private var polling: Task<Void, Never>?
    private let scanner = ActivityScanner(root: URL(fileURLWithPath: AccessSetup.home), managed: VSCodeIsolation.root,
        cacheURL: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/app.accountdock.mac/activity-v1.json"))
    func start() {
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if UserDefaults.standard.bool(forKey: "accountDock.setupCompleted.v1") {
                    let value = await scanner.scan(root: URL(fileURLWithPath: AccessSetup.home))
                    snapshot = value
                }
                do { try await Task.sleep(for: .seconds(snapshot.active || snapshot.indexing ? 2 : 5)) } catch { return }
            }
        }
    }
}

/// Animate only the live menu-bar button. Inactive-display replicas remain static.
@MainActor
final class MenuBarController: NSObject, ObservableObject, NSPopoverDelegate {
    private var item: NSStatusItem?
    private let popover = NSPopover()
    private var positioningPanel: NSPanel?
    private var subscription: AnyCancellable?
    private var outsideMonitor: Any?
    private var localMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    static func rotationDuration(conversations: Int) -> Double {
        max(0.8, 2.0 / sqrt(Double(max(1, conversations))))
    }
    private weak var model: DockModel?
    private weak var monitor: ActivityMonitor?
    func install(model: DockModel, monitor: ActivityMonitor) {
        guard item == nil else { return }
        self.model = model; self.monitor = monitor
        let status = NSStatusBar.system.statusItem(withLength: 28)
        item = status
        guard let button = status.button else { return }
        button.target = self; button.action = #selector(statusItemClicked(_:))
        button.toolTip = "Account Dock · Codex 활동"
        button.setAccessibilityLabel("Account Dock · Codex 활동")
        // Keep native template rendering: AppKit supplies light/dark and inactive-display tint.
        let image = WheelIcon.menuImage(size: 20, color: .black)
        image.isTemplate = true
        button.image = image
        button.imagePosition = .imageOnly
        button.wantsLayer = true
        popover.behavior = .transient; popover.animates = false; popover.delegate = self
        subscription = monitor.$snapshot.map { $0.active ? max(1, $0.activeAccounts.values.reduce(0, +)) : 0 }.removeDuplicates().sink { [weak self] count in
            self?.setRunning(count)
        }
        monitor.start()
    }
    private func setRunning(_ count: Int) {
        guard let layer = item?.button?.layer else { return }
        if count > 0 {
            let spin = CAKeyframeAnimation(keyPath: "transform")
            let phase = layer.presentation().map { atan2($0.transform.m12, $0.transform.m11) } ?? 0
            // Native status-button layer coordinates are unflipped: negative angles turn clockwise.
            // Rotate around the visual center without changing AppKit's backing-layer anchor.
            let pivot = CGPoint(x: layer.bounds.width * (0.5 - layer.anchorPoint.x),
                                y: layer.bounds.height * (0.5 - layer.anchorPoint.y))
            spin.values = (0...64).map { step in
                NSValue(caTransform3D: Self.centeredRotation(angle: phase - CGFloat(step) * .pi * 2 / 64, pivot: pivot))
            }
            spin.duration = Self.rotationDuration(conversations: count); spin.repeatCount = .infinity
            spin.calculationMode = .linear
            spin.timingFunction = CAMediaTimingFunction(name: .linear)
            layer.add(spin, forKey: "codexWorking")
        } else { layer.removeAnimation(forKey: "codexWorking") }
        item?.button?.toolTip = count > 0 ? "Account Dock · Codex 작업 중" : "Account Dock · 대기 중"
    }
    static func centeredRotation(angle: CGFloat, pivot: CGPoint) -> CATransform3D {
        var transform = CATransform3DMakeRotation(angle, 0, 0, 1)
        transform.m41 = pivot.x - cos(angle) * pivot.x + sin(angle) * pivot.y
        transform.m42 = pivot.y - sin(angle) * pivot.x - cos(angle) * pivot.y
        return transform
    }
    /// Use global AppKit coordinates; display origins may be negative or vertically stacked.
    static func anchorRect(click: CGPoint, screen: CGRect, button: CGRect?, size: CGSize) -> CGRect {
        if let button, screen.contains(button), button.contains(click) { return button }
        let width = min(max(1, size.width), screen.width)
        let height = min(max(1, size.height), screen.height)
        return CGRect(x: min(max(click.x - width / 2, screen.minX), screen.maxX - width),
                      y: min(max(click.y - height / 2, screen.minY), screen.maxY - height),
                      width: width, height: height)
    }
    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        // Capture before activation changes the key window, active display, or status-item replica.
        showPanel(at: NSEvent.mouseLocation)
    }
    @objc func togglePanel() { showPanel(at: nil) }
    private func showPanel(at click: CGPoint?) {
        if popover.isShown { popover.performClose(nil); return }
        guard let button = item?.button, let model, let monitor else { return }
        let buttonRect = button.window.map { $0.convertToScreen(button.convert(button.bounds, to: nil)) }
        let point = click ?? buttonRect.map { CGPoint(x: $0.midX, y: $0.midY) } ?? NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? button.window?.screen else { return }
        let rect = Self.anchorRect(click: point, screen: screen.frame, button: buttonRect, size: button.bounds.size)
        // A clear positioning window anchors the popover to the clicked display rather than the
        // status item's canonical window, which can belong to another menu-bar replica.
        let anchor = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        anchor.isReleasedWhenClosed = false
        anchor.isOpaque = false; anchor.backgroundColor = .clear; anchor.hasShadow = false
        anchor.ignoresMouseEvents = true; anchor.level = .statusBar
        anchor.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        anchor.contentView = NSView(frame: CGRect(origin: .zero, size: rect.size))
        anchor.setFrame(rect, display: false)
        positioningPanel = anchor
        anchor.orderFrontRegardless()
        guard let positioningView = anchor.contentView else { return }
        popover.contentViewController = NSHostingController(rootView: ActivityMenu(model: model, monitor: monitor))
        popover.contentSize = NSSize(width: 410, height: 710)
        popover.show(relativeTo: positioningView.bounds, of: positioningView, preferredEdge: .minY)
        // Keep the current app/display active. Activating Account Dock here can bring its
        // main window on another display forward; a transient popover needs no activation.
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.popover.performClose(nil) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { self.popover.performClose(nil); return nil }
            } else if event.window !== self.popover.contentViewController?.view.window && event.window !== self.item?.button?.window {
                self.popover.performClose(nil)
            }
            return event
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.popover.performClose(nil) }
        }
    }
    func popoverDidClose(_ notification: Notification) {
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        outsideMonitor = nil; localMonitor = nil; resignObserver = nil
        popover.contentViewController = nil
        positioningPanel?.orderOut(nil)
        positioningPanel = nil
    }
}

struct ActivityMenu: View {
    @ObservedObject var model: DockModel
    @ObservedObject var monitor: ActivityMonitor
    @State private var selected = "all"
    @StateObject private var panel = ActivityPanelWindow()
    @State private var failures = 0
    @State private var lastAutomatic = Date.distantPast
    @AppStorage("accountDock.usageEnabled") private var usageEnabled = true
    private var visibleSnapshot: ActivitySnapshot {
        let ids = Set(accounts.map(\.id))
        var result = monitor.snapshot
        result = result.filtered(accounts: ids)
        return result
    }
    private var selectedAccount: String? { selected == "all" ? nil : selected }
    private func accountID(_ preset: AccountPreset) -> String? {
        let json = (try? JSONSerialization.jsonObject(with: preset.credential)) as? [String: Any]
        return (json?["tokens"] as? [String: Any])?["account_id"] as? String
    }
    private var accounts: [(id: String, name: String)] {
        var seen: Set<String> = []
        return model.presets.compactMap { preset in
            guard let id = accountID(preset), seen.insert(id).inserted else { return nil }
            return (id, preset.displayName)
        }
    }
    private func report(_ preset: AccountPreset) -> UsageReport? {
        let server = model.usage[preset.id]
        guard let id = accountID(preset), let sample = visibleSnapshot.limits[id],
              sample.date.timeIntervalSince1970 > (server?.checkedAt ?? 0),
              let local = LocalUsageReport.normalize(sample) else { return server }
        return UsageReport(status: local.status, windows: local.windows, activity: server?.activity ?? [:],
            credits: local.credits, resetCredits: server?.resetCredits, checkedAt: local.checkedAt)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(nsImage: WheelIcon.image(size: 24))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Codex 활동").font(.system(size: 17, weight: .semibold))
                    Text(monitor.snapshot.active ? "작업 중" : "대기 중").font(.system(size: 12)).foregroundStyle(DockTheme.muted)
                }
                Spacer()
            }
            Picker("계정", selection: $selected) {
                Text("등록된 계정 전체").tag("all")
                ForEach(accounts, id: \.id) { Text($0.name).tag($0.id) }
            }.labelsHidden()
            HStack(spacing: 12) {
                metric("오늘 토큰", value: visibleSnapshot.tokens(account: selectedAccount, day: ActivitySnapshot.day(Date())))
                metric("누적 토큰", value: visibleSnapshot.tokens(account: selectedAccount))
            }
            ActivityHeatmap(snapshot: visibleSnapshot, account: selectedAccount)
            HStack {
                Text(monitor.snapshot.indexing ? "로컬 기록 집계 중…" : "이 Mac의 로컬 기록 기준")
                Spacer()
                if let date = monitor.snapshot.updatedAt { Text(date, style: .time).monospacedDigit() }
            }.font(.system(size: 11)).foregroundStyle(DockTheme.muted)
            if monitor.snapshot.unreadableFiles > 0 {
                Text("일부 기록을 읽을 수 없습니다.").font(.system(size: 12)).foregroundStyle(DockTheme.muted)
            }
            Divider()
            HStack {
                Text("남은 한도 · 크레딧").font(.system(size: 13, weight: .semibold))
                Spacer()
                if model.refreshingUsage { ProgressView().controlSize(.small) }
                Button {
                    Task { await model.refreshUsage(minimumInterval: 5); failures = 0; lastAutomatic = Date() }
                } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).help("지금 사용량 조회")
                    .disabled(model.refreshingUsage || model.busy || !usageEnabled || model.presets.isEmpty)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !usageEnabled { Text("온라인 사용량 조회가 꺼져 있습니다.") }
                    else if model.presets.isEmpty { Text("Account Dock에서 계정을 추가하세요.") }
                    ForEach(model.presets.filter { selected == "all" || accountID($0) == selected }) { preset in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack { Text(preset.displayName).fontWeight(.semibold); Spacer(); Text(preset.planLabel).foregroundStyle(DockTheme.muted) }
                            if let id = accountID(preset) {
                                let count = monitor.snapshot.activeAccounts[id, default: 0]
                                HStack(spacing: 6) {
                                    Circle().fill(count > 0 ? DockTheme.orange : DockTheme.muted.opacity(0.4)).frame(width: 6, height: 6)
                                    Text(count > 0 ? "작업 중 · 대화 \(count)개" : (monitor.snapshot.observedAccounts.contains(id) ? "대기 중" : "활동 기록 없음"))
                                        .foregroundStyle(count > 0 ? DockTheme.orange : DockTheme.muted)
                                }
                            }
                            if let id = accountID(preset) {
                                if visibleSnapshot.days.values.contains(where: { $0[id] != nil }) {
                                    Text("오늘 \(visibleSnapshot.tokens(account: id, day: ActivitySnapshot.day(Date())).formatted()) · 누적 \(visibleSnapshot.tokens(account: id).formatted()) 토큰")
                                        .foregroundStyle(DockTheme.muted)
                                } else {
                                    Text("집계된 토큰 기록 없음 · 계정 확인 이후 기록부터 반영")
                                        .foregroundStyle(DockTheme.muted)
                                }
                            }
                            if usageEnabled { AccountUsageView(report: report(preset), loading: report(preset) == nil && model.usageLoading.contains(preset.id), compact: true) }
                        }.font(.system(size: 12)).padding(14)
                            .background(.white, in: RoundedRectangle(cornerRadius: 12))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 220)
            HStack {
                Text("등록된 계정의 식별 가능한 로컬 기록만 집계합니다. 작업 중인 Codex의 한도 정보는 자동 반영됩니다.")
                .font(.system(size: 11)).foregroundStyle(DockTheme.muted).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("종료") { NSApp.terminate(nil) }.buttonStyle(.plain).font(.system(size: 12)).fixedSize()
            }
        }
        .padding(20).frame(width: 410).background(DockTheme.canvas)
        .foregroundStyle(DockTheme.navy).preferredColorScheme(.light)
        .background(ActivityPanelReader(panel: panel).frame(width: 0, height: 0))
        .onChange(of: accounts.map(\.id)) { _, ids in
            if selected != "all" && !ids.contains(selected) { selected = "all" }
        }
        .task {
            monitor.start()
            try? await Task.sleep(for: .milliseconds(250))
            while !Task.isCancelled {
                if panel.window?.isVisible == true && UserDefaults.standard.bool(forKey: "accountDock.setupCompleted.v1") && usageEnabled {
                    let interval: TimeInterval = failures > 0 ? min(300, 60 * pow(2, Double(failures))) : (monitor.snapshot.active ? 30 : 60)
                    if Date().timeIntervalSince(lastAutomatic) >= interval && !model.busy && !model.refreshingUsage {
                        let recentLocal = Set(model.presets.filter { preset in
                            guard let id = accountID(preset), let sample = monitor.snapshot.limits[id] else { return false }
                            return Date().timeIntervalSince(sample.date) < 30 && LocalUsageReport.normalize(sample) != nil
                        }.map(\.id))
                        await model.refreshUsage(minimumInterval: interval, skippingAccounts: recentLocal)
                        lastAutomatic = Date()
                        let available = model.usage.values.contains { ["available", "partial"].contains($0.status) }
                        failures = available ? 0 : min(3, failures + 1)
                    }
                }
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
    }
    private func metric(_ title: String, value: Int64) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12)).foregroundStyle(DockTheme.muted)
            Text(value.formatted()).font(.system(size: 21, weight: .semibold, design: .rounded)).monospacedDigit().minimumScaleFactor(0.6).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(DockTheme.blue.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct ActivityHeatmap: View {
    let snapshot: ActivitySnapshot
    let account: String?
    private var dates: [Date] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let weekday = (calendar.component(.weekday, from: today) + 5) % 7
        let start = calendar.date(byAdding: .day, value: -weekday - 20 * 7, to: today)!
        return (0..<147).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }
    var body: some View {
        let days = dates
        let maximum = max(1, days.map { snapshot.tokens(account: account, day: ActivitySnapshot.day($0)) }.max() ?? 1)
        VStack(alignment: .leading, spacing: 7) {
            HStack { Text("최근 21주"); Spacer(); Text("토큰 사용량") }.font(.system(size: 11)).foregroundStyle(DockTheme.muted)
            HStack(alignment: .top, spacing: 4) {
                ForEach(0..<21, id: \.self) { week in
                    VStack(spacing: 4) {
                        ForEach(0..<7, id: \.self) { weekday in
                            let date = days[week * 7 + weekday]
                            let value = snapshot.tokens(account: account, day: ActivitySnapshot.day(date))
                            let opacity = value == 0 ? 0.07 : 0.25 + 0.75 * sqrt(Double(value) / Double(maximum))
                            RoundedRectangle(cornerRadius: 2)
                                .fill(date > Date() ? .clear : DockTheme.navy.opacity(opacity))
                                .frame(width: 13, height: 13)
                                .help("\(date.formatted(date: .abbreviated, time: .omitted)) · \(value.formatted()) 토큰")
                                .accessibilityLabel("\(ActivitySnapshot.day(date)), \(value) 토큰")
                        }
                    }
                }
            }
            HStack(spacing: 4) {
                Spacer(); Text("적음")
                ForEach([0.07, 0.25, 0.5, 0.75, 1.0], id: \.self) { opacity in
                    RoundedRectangle(cornerRadius: 2).fill(DockTheme.navy.opacity(opacity)).frame(width: 10, height: 10)
                }
                Text("많음")
            }.font(.system(size: 10)).foregroundStyle(DockTheme.muted)
        }
    }
}

@MainActor
final class ActivityPanelWindow: ObservableObject {
    weak var window: NSWindow?
}
struct ActivityPanelReader: NSViewRepresentable {
    let panel: ActivityPanelWindow
    func makeNSView(context: Context) -> PanelView { PanelView(panel: panel) }
    func updateNSView(_ nsView: PanelView, context: Context) {}
    final class PanelView: NSView {
        let panel: ActivityPanelWindow
        init(panel: ActivityPanelWindow) { self.panel = panel; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); panel.window = window }
    }
}
