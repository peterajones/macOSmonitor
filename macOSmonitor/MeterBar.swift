import SwiftUI

/// A utilisation meter drawn as a row (or column) of LED-style segments.
///
/// Every meter has the same fixed number of segments, so a segment means the same
/// percentage everywhere in the app. The segment maths is pure and static, like
/// `GraphGeometry`, so it is testable without instantiating a Canvas.
struct MeterBar: View {
    enum Orientation { case horizontal, vertical }

    let fraction: Double
    let orientation: Orientation
    let onColor: Color
    let offColor: Color

    /// 20 segments of 5% each.
    static let segmentCount = 20
    /// Space between adjacent segments, in points.
    static let segmentGap: CGFloat = 1

    /// Clamps to 0...1, mapping non-finite input to 0 so a bad fraction can never
    /// produce a negative, infinite, or NaN frame.
    static func clampedFraction(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }

    /// Segments to light for `fraction`, rounding up so any non-zero reading shows.
    ///
    /// The tolerance matters because fractions are computed and carry floating-point
    /// noise: 3 * 0.05 is 0.15000000000000002, times 20 is 3.0000000000000004, and a
    /// bare round-up would light 4 segments for a true 15%.
    static func litSegments(fraction: Double) -> Int {
        let exact = clampedFraction(fraction) * Double(segmentCount)
        return max(0, Int((exact - 1e-9).rounded(.up)))
    }

    /// The segment rectangles for a meter of `size`, in lighting order: index 0 is
    /// the bottom segment of a vertical meter, or the leftmost of a horizontal one.
    /// Empty when the meter is too small to fit the gaps.
    static func segmentRects(in size: CGSize, orientation: Orientation) -> [CGRect] {
        let count = segmentCount
        let length = orientation == .horizontal ? size.width : size.height
        let segmentLength = (length - segmentGap * CGFloat(count - 1)) / CGFloat(count)
        guard segmentLength > 0 else { return [] }

        return (0..<count).map { index in
            let offset = CGFloat(index) * (segmentLength + segmentGap)
            switch orientation {
            case .horizontal:
                return CGRect(x: offset, y: 0, width: segmentLength, height: size.height)
            case .vertical:
                // SwiftUI's origin is top-left, so the first segment sits at the bottom.
                return CGRect(x: 0, y: size.height - offset - segmentLength,
                              width: size.width, height: segmentLength)
            }
        }
    }

    var body: some View {
        Canvas { context, size in
            let lit = MeterBar.litSegments(fraction: fraction)
            for (index, rect) in MeterBar.segmentRects(in: size, orientation: orientation).enumerated() {
                let radius = min(1, rect.width / 2, rect.height / 2)
                context.fill(Path(roundedRect: rect, cornerRadius: radius),
                             with: .color(index < lit ? onColor : offColor))
            }
        }
    }
}
