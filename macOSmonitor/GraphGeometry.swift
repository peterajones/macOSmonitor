import CoreGraphics

/// Maps a value window onto graph coordinates. Pure, so the layout rules are
/// testable without instantiating a Canvas.
enum GraphGeometry {
    /// Points for `values` (oldest → newest), newest pinned to the right edge.
    /// The x-step comes from `capacity`, so a partially-filled window occupies the
    /// right-hand portion and grows leftward rather than stretching to fit.
    static func points(values: [Double],
                       capacity: Int,
                       range: ClosedRange<Double>,
                       size: CGSize) -> [CGPoint] {
        guard capacity > 1, !values.isEmpty else { return [] }
        let step = size.width / CGFloat(capacity - 1)
        let span = range.upperBound - range.lowerBound
        let newestIndex = values.count - 1

        return values.enumerated().map { index, value in
            let x = size.width - CGFloat(newestIndex - index) * step
            let clamped = min(max(value, range.lowerBound), range.upperBound)
            let normalized = span > 0 ? (clamped - range.lowerBound) / span : 0
            // SwiftUI's origin is top-left, so invert: the range maximum sits at y == 0.
            let y = size.height - CGFloat(normalized) * size.height
            return CGPoint(x: x, y: y)
        }
    }
}
