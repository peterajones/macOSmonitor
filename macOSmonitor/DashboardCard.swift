import SwiftUI

/// The Summary's card frame: rounded, a faint wash of `tint` over the panel background, and a
/// border in `tint`. One modifier, so every card on the dashboard matches.
struct DashboardCard: ViewModifier {
    let tint: Color
    @Environment(\.theme) private var theme

    private let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

    func body(content: Content) -> some View {
        content
            .padding(12)
            .background(shape.fill(tint.opacity(0.07)))
            .background(shape.fill(theme.panelBackground))
            .overlay(shape.strokeBorder(tint.opacity(0.55), lineWidth: 1))
    }
}

extension View {
    func dashboardCard(_ tint: Color) -> some View { modifier(DashboardCard(tint: tint)) }
}
