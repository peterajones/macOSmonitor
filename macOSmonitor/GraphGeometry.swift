import CoreGraphics
import Foundation

/// Maps a value window onto graph coordinates. Pure, so the layout rules are
/// testable without instantiating a Canvas.
enum GraphGeometry {
    /// How hard older samples are squeezed: the newest are roughly four times wider
    /// than an even spacing would make them.
    private static let compression = 9.0

    /// Distance from the right edge, 0...1, for a sample `age` ticks old.
    private static func compressedFraction(age: Int, capacity: Int) -> CGFloat {
        CGFloat(log1p(compression * Double(age) / Double(capacity - 1)) / log1p(compression))
    }

    /// Like `points`, but older samples are squeezed progressively towards the left.
    static func compressedPoints(values: [Double],
                                 capacity: Int,
                                 range: ClosedRange<Double>,
                                 size: CGSize) -> [CGPoint] {
        guard capacity > 1, !values.isEmpty else { return [] }
        let span = range.upperBound - range.lowerBound
        let newestIndex = values.count - 1

        return values.enumerated().map { index, value in
            let x = size.width * (1 - compressedFraction(age: newestIndex - index, capacity: capacity))
            let clamped = min(max(value, range.lowerBound), range.upperBound)
            let normalized = span > 0 ? (clamped - range.lowerBound) / span : 0
            return CGPoint(x: x, y: size.height - CGFloat(normalized) * size.height)
        }
    }

    /// X positions of vertical marks tied to every `interval`th sample ever seen, so
    /// they drift left and bunch together as those samples age.
    static func timeGridPositions(samplesSeen: Int,
                                  capacity: Int,
                                  interval: Int,
                                  width: CGFloat) -> [CGFloat] {
        guard samplesSeen > 0, capacity > 1, interval > 0 else { return [] }
        return stride(from: (samplesSeen - 1) % interval, to: min(capacity, samplesSeen), by: interval)
            .map { width * (1 - compressedFraction(age: $0, capacity: capacity)) }
    }

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
