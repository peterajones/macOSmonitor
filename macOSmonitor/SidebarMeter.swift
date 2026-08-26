import SwiftUI

/// A sidebar row: title, live value, and a thin utilisation bar.
struct SidebarMeter: View {
    let title: String
    let value: String
    /// 0...1; values outside are clamped.
    let fraction: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                Spacer()
                Text(value)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.gray.opacity(0.2))
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: geometry.size.width * min(max(fraction, 0), 1))
                }
            }
            .frame(height: 3)
        }
        .padding(.vertical, 2)
    }
}
