import SwiftUI
import ServiceManagement

@MainActor
final class StartupSettings: ObservableObject {
    @Published var status = SMAppService.mainApp.status
    @Published var error: String?
    var enabled: Bool { status == .enabled || status == .requiresApproval }
    func refresh() { status = SMAppService.mainApp.status }
    func setEnabled(_ enabled: Bool) {
        error = nil
        do {
            if enabled {
                if status != .enabled && status != .requiresApproval { try SMAppService.mainApp.register() }
            } else if status != .notRegistered { try SMAppService.mainApp.unregister() }
        } catch { self.error = "자동 실행을 설정하지 못했습니다. Applications에 설치된 앱에서 다시 시도해 주세요." }
        refresh()
    }
    var label: String {
        switch status {
        case .enabled: return "자동 실행 켜짐"
        case .requiresApproval: return "시스템 설정에서 허용이 필요합니다"
        case .notRegistered: return "자동 실행 꺼짐"
        case .notFound: return "설치된 앱에서 설정할 수 있습니다"
        @unknown default: return "상태 확인 필요"
        }
    }
}

struct StartupPanel: View {
    @StateObject private var settings = StartupSettings()
    @Environment(\.scenePhase) private var phase
    var introductory = false
    var onContinue: () -> Void = {}
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                WheelPreview(size: 42)
                Text("메뉴 막대에서 계속 사용").font(.system(size: 19, weight: .semibold))
            }
            Text("창을 닫아도 Codex 활동과 사용량을 확인할 수 있습니다. Mac에 로그인할 때 자동으로 시작하려면 자동 실행을 켜세요.")
                .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            Toggle("Mac 로그인 시 자동 실행", isOn: Binding(get: { settings.enabled }, set: { settings.setEnabled($0) }))
                .toggleStyle(.switch).font(.system(size: 13, weight: .medium))
            Text(settings.label).font(.system(size: 12)).foregroundStyle(DockTheme.muted)
            if settings.status == .requiresApproval {
                Text("macOS가 로그인 항목 실행을 제한하고 있습니다. ‘로그인 항목’에서 Account Dock을 허용해 주세요.")
                    .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                Button("로그인 항목 설정 열기") { SMAppService.openSystemSettingsLoginItems() }
                    .buttonStyle(DockButtonStyle())
            }
            if let error = settings.error { Text(error).font(.system(size: 12)).foregroundStyle(DockTheme.orange) }
            Text("활동 확인은 로컬 기록을 사용합니다. 남은 한도는 사용량 패널이 열려 있을 때만 주기적으로 조회합니다.")
                .font(.system(size: 12)).foregroundStyle(DockTheme.muted).fixedSize(horizontal: false, vertical: true)
            if introductory {
                HStack { Spacer(); Button("완료", action: onContinue).buttonStyle(DockButtonStyle(kind: .primary)) }
            }
        }.padding(22).background(.white, in: RoundedRectangle(cornerRadius: 14))
            .foregroundStyle(DockTheme.navy)
            .onChange(of: phase) { _, _ in settings.refresh() }.onAppear { settings.refresh() }
    }
}

struct WheelPreview: View {
    @AppStorage(WheelDesign.preferenceKey) private var selection = WheelDesign.classic.rawValue
    var size: CGFloat
    var body: some View {
        Image(nsImage: WheelIcon.image(size: size, design: WheelDesign(rawValue: selection) ?? .classic))
    }
}

struct WheelDesignPanel: View {
    @AppStorage(WheelDesign.preferenceKey) private var selection = WheelDesign.classic.rawValue
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("메뉴바 아이콘").font(.system(size: 17, weight: .semibold))
            HStack(spacing: 12) {
                ForEach(WheelDesign.allCases) { design in
                    Button { selection = design.rawValue } label: {
                        VStack(spacing: 10) {
                            Image(nsImage: WheelIcon.image(size: 64, design: design))
                            Text(design.title).font(.system(size: 12, weight: .medium))
                            Image(systemName: selection == design.rawValue ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selection == design.rawValue ? DockTheme.orange : DockTheme.muted)
                        }.frame(maxWidth: .infinity).padding(.vertical, 16)
                            .background(selection == design.rawValue ? DockTheme.canvas : .white, in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selection == design.rawValue ? DockTheme.orange : DockTheme.muted.opacity(0.2)))
                    }.buttonStyle(.plain).accessibilityLabel(design.title)
                        .accessibilityAddTraits(selection == design.rawValue ? .isSelected : [])
                }
            }
        }.padding(22).background(.white, in: RoundedRectangle(cornerRadius: 14))
    }
}
