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

@MainActor
final class WheelStatusImage: NSView {
    let rotor = CALayer()
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(rotor)
        rotor.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        rotor.contentsGravity = .resizeAspect
        updateImage()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        rotor.bounds = CGRect(origin: .zero, size: bounds.size)
        rotor.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateImage() }
    private func updateImage() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let image = WheelIcon.image(size: 60, color: dark ? .white : .black)
        image.isTemplate = false
        rotor.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        rotor.contentsScale = 3
    }
}

/// Core Animation rotates a single cached Retina image; no frame timer or SwiftUI redraw loop.
@MainActor
final class MenuBarController: NSObject, ObservableObject, NSPopoverDelegate {
    private var item: NSStatusItem?
    private let popover = NSPopover()
    private var wheel: WheelStatusImage?
    private var subscription: AnyCancellable?
    private weak var model: DockModel?
    private weak var monitor: ActivityMonitor?
    func install(model: DockModel, monitor: ActivityMonitor) {
        guard item == nil else { return }
        self.model = model; self.monitor = monitor
        let status = NSStatusBar.system.statusItem(withLength: 28)
        item = status
        guard let button = status.button else { return }
        button.target = self; button.action = #selector(togglePanel)
        button.toolTip = "Account Dock · Codex 활동"
        button.setAccessibilityLabel("Account Dock · Codex 활동")
        let image = WheelStatusImage(frame: NSRect(x: 4, y: (button.bounds.height - 20) / 2, width: 20, height: 20))
        image.autoresizingMask = [.minYMargin, .maxYMargin]
        button.addSubview(image); wheel = image
        popover.behavior = .transient; popover.animates = false; popover.delegate = self
        subscription = monitor.$snapshot.map(\.active).removeDuplicates().sink { [weak self] active in
            self?.setRunning(active)
        }
        monitor.start()
    }
    private func setRunning(_ active: Bool) {
        guard let layer = wheel?.rotor else { return }
        if active {
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            // Layer coordinates in this view are flipped: positive rotation moves the top to the right.
            spin.fromValue = 0; spin.toValue = Double.pi * 2
            spin.duration = 2.4; spin.repeatCount = .infinity
            spin.timingFunction = CAMediaTimingFunction(name: .linear)
            layer.add(spin, forKey: "codexWorking")
        } else { layer.removeAnimation(forKey: "codexWorking") }
        item?.button?.toolTip = active ? "Account Dock · Codex 작업 중" : "Account Dock · 대기 중"
    }
    @objc func togglePanel() {
        if popover.isShown { popover.performClose(nil); return }
        guard let button = item?.button, let model, let monitor else { return }
        popover.contentViewController = NSHostingController(rootView: ActivityMenu(model: model, monitor: monitor))
        popover.contentSize = NSSize(width: 410, height: 710)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
    func popoverDidClose(_ notification: Notification) { popover.contentViewController = nil }
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
                Button { NSWorkspace.shared.open(Bundle.main.bundleURL) } label: {
                    Image(systemName: "arrow.up.right.square")
                }.buttonStyle(.plain).help("Account Dock 열기")
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
                                Text("오늘 \(visibleSnapshot.tokens(account: id, day: ActivitySnapshot.day(Date())).formatted()) · 누적 \(visibleSnapshot.tokens(account: id).formatted()) 토큰")
                                    .foregroundStyle(DockTheme.muted)
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
