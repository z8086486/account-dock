import SwiftUI

enum DockTheme {
    static let navy = Color(red: 0.055, green: 0.14, blue: 0.20)
    static let blue = Color(red: 0.65, green: 0.82, blue: 0.88)
    static let orange = Color(red: 1.0, green: 0.40, blue: 0.13)
    static let canvas = Color(red: 0.935, green: 0.955, blue: 0.955)
    static let muted = Color(red: 0.29, green: 0.37, blue: 0.42)
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
            guard enabled else { return DockTheme.navy.opacity(0.07) }
            switch kind {
            case .primary: return DockTheme.orange
            case .secondary: return hovered ? DockTheme.canvas : .white
            case .quiet: return hovered ? DockTheme.blue.opacity(0.18) : .clear
            case .danger: return Color(red: 0.70, green: 0.18, blue: 0.12)
            }
        }
        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(!enabled ? DockTheme.muted : kind == .danger ? .white : DockTheme.navy)
                .padding(.horizontal, 16).padding(.vertical, 11)
                .frame(minHeight: 40)
                .background(fill, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(DockTheme.navy.opacity(kind == .quiet ? 0 : 0.16)))
                .overlay(RoundedRectangle(cornerRadius: 9).fill(DockTheme.navy.opacity(configuration.isPressed && enabled ? 0.08 : 0)).allowsHitTesting(false))
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
                .onHover { hovered = $0 }
        }
    }
}
