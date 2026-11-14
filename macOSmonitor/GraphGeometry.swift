import CoreGraphics
import Foundation

/// One cubic piece of a smoothed trace, continuing from the previous segment's end.
struct CurveSegment: Equatable {
    let control1: CGPoint
    let control2: CGPoint
    let end: CGPoint
}

/// Maps a value window onto graph coordinates. Pure, so the layout rules are
/// testable without instantiating a Canvas.
enum GraphGeometry {
    /// How far through the current sample interval `now` is, 0...1. Rests at 1 when a
    /// sample is late or none has arrived, so the graph waits rather than running ahead.
    static func scrollPhase(now: Date, lastSample: Date?, interval: TimeInterval) -> Double {
        guard let lastSample, interval > 0 else { return 1 }
        return min(max(now.timeIntervalSince(lastSample) / interval, 0), 1)
    }

    /// A monotone cubic through `points` (Fritsch-Carlson tangents), which never swings
    /// past a neighbouring sample, so the curve can't show a value that wasn't measured.
    static func smoothSegments(_ points: [CGPoint]) -> [CurveSegment] {
        guard points.count > 1 else { return [] }
        let gaps = zip(points, points.dropFirst()).map { $1.x - $0.x }
        let slopes = zip(zip(points, points.dropFirst()), gaps).map { pair, gap in
            gap > 0 ? (pair.1.y - pair.0.y) / gap : 0
        }

        var tangents = [slopes[0]]
        for k in 1..<slopes.count {
            guard slopes[k - 1] * slopes[k] > 0 else { tangents.append(0); continue }
            let leading = 2 * gaps[k] + gaps[k - 1]
            let trailing = gaps[k] + 2 * gaps[k - 1]
            tangents.append((leading + trailing) / (leading / slopes[k - 1] + trailing / slopes[k]))
        }
        tangents.append(slopes[slopes.count - 1])

        return gaps.indices.map { k in
            let third = gaps[k] / 3
            return CurveSegment(
                control1: CGPoint(x: points[k].x + third, y: points[k].y + tangents[k] * third),
                control2: CGPoint(x: points[k + 1].x - third, y: points[k + 1].y - tangents[k + 1] * third),
                end: points[k + 1])
        }
    }

    /// Height of the smoothed curve at `x`, or nil where the curve doesn't reach. `start` is
    /// the point the first segment continues from. Each segment's controls sit a third of
    /// its gap in from either end, so x runs linearly with the curve parameter t.
    static func curveY(atX x: CGFloat, start: CGPoint, segments: [CurveSegment]) -> CGFloat? {
        var from = start
        for segment in segments {
            defer { from = segment.end }
            guard x >= from.x, x <= segment.end.x else { continue }
            let gap = segment.end.x - from.x
            let t = gap > 0 ? (x - from.x) / gap : 1
            let u = 1 - t
            return u * u * u * from.y + 3 * u * u * t * segment.control1.y
                + 3 * u * t * t * segment.control2.y + t * t * t * segment.end.y
        }
        return nil
    }

    /// How hard older samples are squeezed: the newest are roughly four times wider
    /// than an even spacing would make them.
    private static let compression = 9.0

    /// Distance from the right edge, 0...1, for a sample `age` ticks old. A negative age
    /// is a sample still gliding in past the edge, continuing along the curve's first slope.
    private static func compressedFraction(age: Double, capacity: Int) -> CGFloat {
        let oldest = Double(capacity - 1)
        guard age >= 0 else { return CGFloat(age * compression / (oldest * log1p(compression))) }
        return CGFloat(log1p(compression * age / oldest) / log1p(compression))
    }

    /// Like `points`, but older samples are squeezed progressively towards the left.
    /// `phase` glides everything between ticks: at 0 the newest sample waits one tick
    /// past the right edge, and at 1 it has arrived there, so no gap ever opens.
    static func compressedPoints(values: [Double],
                                 capacity: Int,
                                 range: ClosedRange<Double>,
                                 size: CGSize,
                                 phase: Double = 1) -> [CGPoint] {
        guard capacity > 1, !values.isEmpty else { return [] }
        let span = range.upperBound - range.lowerBound
        let newestIndex = values.count - 1

        return values.enumerated().map { index, value in
            let x = size.width * (1 - compressedFraction(age: Double(newestIndex - index) + phase - 1, capacity: capacity))
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
                                  width: CGFloat,
                                  phase: Double = 1) -> [CGFloat] {
        guard samplesSeen > 0, capacity > 1, interval > 0 else { return [] }
        return stride(from: (samplesSeen - 1) % interval, to: min(capacity, samplesSeen), by: interval)
            .map { width * (1 - compressedFraction(age: Double($0) + phase - 1, capacity: capacity)) }
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
