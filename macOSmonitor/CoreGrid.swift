import SwiftUI

/// One bar per logical core, filled to its current utilisation. Instantaneous —
/// per-core history is deliberately not stored.
struct CoreGrid: View {
    let percentages: [Double]
    let onColor: Color
    let offColor: Color

    private let columns = [GridItem(.adaptive(minimum: 68), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(Array(percentages.enumerated()), id: \.offset) { index, percent in
                VStack(spacing: 4) {
                    GeometryReader { geometry in
                        ZStack(alignment: .bottom) {
                            Rectangle().fill(offColor)
                            Rectangle()
                                .fill(onColor)
                                .frame(height: geometry.size.height * CGFloat(min(max(percent, 0), 100)) / 100)
                        }
                    }
                    .frame(height: 44)
                    Text("\(index)")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
