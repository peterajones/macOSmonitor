import SwiftUI

/// A utilisation meter: a track with a proportional fill, in either orientation.
///
/// M12 re-renders this as stacked LED segments. The interface is fixed now so that
/// milestone changes only this file.
struct MeterBar: View {
    enum Orientation { case horizontal, vertical }

    let fraction: Double
    let orientation: Orientation
    let onColor: Color
    let offColor: Color

    /// Clamps to 0...1, mapping non-finite input to 0 so a bad fraction can never
    /// produce a negative, infinite, or NaN frame.
    static func clampedFraction(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: orientation == .horizontal ? .leading : .bottom) {
                Capsule().fill(offColor)
                Capsule()
                    .fill(onColor)
                    .frame(
                        width: orientation == .horizontal
                            ? geometry.size.width * MeterBar.clampedFraction(fraction)
                            : nil,
                        height: orientation == .vertical
                            ? geometry.size.height * MeterBar.clampedFraction(fraction)
                            : nil
                    )
            }
        }
    }
}
