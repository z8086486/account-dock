import SwiftUI

enum DockTheme {
    static let navy = Color(red: 0.055, green: 0.14, blue: 0.20)
    static let blue = Color(red: 0.65, green: 0.82, blue: 0.88)
    static let orange = Color(red: 1.0, green: 0.40, blue: 0.13)
    static let canvas = Color(red: 0.935, green: 0.955, blue: 0.955)
    static let muted = Color(red: 0.36, green: 0.43, blue: 0.47)
}

struct DockButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, quiet, danger }
    var kind: Kind = .secondary
    func makeBody(configuration: Configuration) -> some View {
        DockButtonBody(configuration: configuration, kind: kind)
    }
    private struct DockButtonBody: View {
        let configuration: Configuration
        let kind: Kind
        @Environment(\.isEnabled) private var enabled
        @State private var hovered = false
        var fill: Color {
            switch kind {
            case .primary: DockTheme.orange
            case .secondary: .white
            case .quiet: .clear
            case .danger: Color(red: 0.70, green: 0.18, blue: 0.12)
            }
        }
        var body: some View {
            configuration.label
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(kind == .danger ? .white : DockTheme.navy)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(fill, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(DockTheme.navy.opacity(kind == .quiet ? 0 : 0.16)))
                .shadow(color: DockTheme.navy.opacity(kind == .primary && enabled ? 0.14 : 0), radius: 0, y: 3)
                .brightness(hovered && enabled ? -0.035 : 0)
                .opacity(enabled ? 1 : 0.4)
                .offset(y: configuration.isPressed ? 2 : 0)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
                .onHover { hovered = $0 }
        }
    }
}

struct DockStripes: View {
    var body: some View {
        HStack(spacing: 4) {
            Rectangle().fill(DockTheme.orange).frame(width: 24)
            Rectangle().fill(DockTheme.navy).frame(width: 5)
            Rectangle().fill(DockTheme.blue).frame(width: 10)
        }.rotationEffect(.degrees(18)).frame(width: 58).clipped().accessibilityHidden(true)
    }
}
