import Foundation
import Testing
@testable import macOSmonitor

struct GraphGeometryTests {
    private let size = CGSize(width: 100, height: 50)

    @Test func emptyValuesProduceNoPoints() {
        let points = GraphGeometry.points(values: [], capacity: 60, range: 0...100, size: size)
        #expect(points.isEmpty)
    }

    @Test func newestSamplePinsToTheRightEdge() {
        let points = GraphGeometry.points(values: [10, 20, 30], capacity: 60,
                                          range: 0...100, size: size)
        #expect(points.last?.x == 100)
    }

    @Test func stepDerivesFromCapacityNotSampleCount() {
        // capacity 11 over width 100 → step 10. Three samples occupy the right 20pt.
        let points = GraphGeometry.points(values: [1, 2, 3], capacity: 11,
                                          range: 0...100, size: size)
        #expect(points.map(\.x) == [80, 90, 100])
    }

    @Test func fullWindowSpansTheFullWidth() {
        let values = Array(repeating: 50.0, count: 11)
        let points = GraphGeometry.points(values: values, capacity: 11,
                                          range: 0...100, size: size)
        #expect(points.first?.x == 0)
        #expect(points.last?.x == 100)
    }

    @Test func yIsInvertedSoMaximumSitsAtTheTop() {
        let points = GraphGeometry.points(values: [0, 50, 100], capacity: 3,
                                          range: 0...100, size: size)
        #expect(points[0].y == 50)      // value 0   → bottom
        #expect(points[1].y == 25)      // value 50  → middle
        #expect(points[2].y == 0)       // value 100 → top
    }

    @Test func valuesOutsideTheRangeAreClamped() {
        let points = GraphGeometry.points(values: [-10, 250], capacity: 2,
                                          range: 0...100, size: size)
        #expect(points[0].y == 50)      // clamped to the floor
        #expect(points[1].y == 0)       // clamped to the ceiling
    }

    @Test func zeroWidthRangeDoesNotDivideByZero() {
        let points = GraphGeometry.points(values: [5], capacity: 2,
                                          range: 0...0, size: size)
        #expect(points.count == 1)
        #expect(points[0].y == 50)
    }

    // With capacity 10 and a compression factor of 9, an age's distance from the right
    // edge is log10(1 + age) of the width, so these expectations can be checked by hand.
    private func close(_ actual: [CGFloat], _ expected: [CGFloat]) -> Bool {
        actual.count == expected.count && zip(actual, expected).allSatisfy { abs($0 - $1) < 0.01 }
    }

    @Test func compressedPointsSqueezeOlderSamplesTowardsTheLeft() {
        let values = Array(repeating: 50.0, count: 10)
        let points = GraphGeometry.compressedPoints(values: values, capacity: 10,
                                                    range: 0...100, size: size)
        #expect(close(points.map(\.x), [0, 4.58, 9.69, 15.49, 22.18, 30.10, 39.79, 52.29, 69.90, 100]))
    }

    @Test func compressedPointsPinTheNewestAndKeepAgeInAPartialWindow() {
        let points = GraphGeometry.compressedPoints(values: [1, 2], capacity: 10,
                                                    range: 0...100, size: size)
        #expect(close(points.map(\.x), [69.90, 100]))
    }

    @Test func compressedPointsMapValuesOntoTheRange() {
        let points = GraphGeometry.compressedPoints(values: [0, 100], capacity: 10,
                                                    range: 0...100, size: size)
        #expect(points.map(\.y) == [50, 0])
    }

    @Test func compressedPointsNeedDataAndARealWindow() {
        #expect(GraphGeometry.compressedPoints(values: [], capacity: 10, range: 0...1, size: size).isEmpty)
        #expect(GraphGeometry.compressedPoints(values: [1], capacity: 1, range: 0...1, size: size).isEmpty)
    }

    @Test func gridLinesSitAtTheirSamplesAges() {
        // Seven samples, marks on indices 0, 3 and 6: ages 6, 3 and 0.
        let xs = GraphGeometry.timeGridPositions(samplesSeen: 7, capacity: 10, interval: 3, width: 100)
        #expect(close(xs, [100, 39.79, 15.49]))
    }

    @Test func gridLinesDriftLeftAsSamplesArrive() {
        // One more sample ages every mark by one: 1, 4 and 7.
        let xs = GraphGeometry.timeGridPositions(samplesSeen: 8, capacity: 10, interval: 3, width: 100)
        #expect(close(xs, [69.90, 30.10, 9.69]))
    }

    @Test func gridLinesOlderThanTheWindowDropOff() {
        // Twenty samples: marks aged 1, 4 and 7 remain; the one aged 10 is out of the window.
        let xs = GraphGeometry.timeGridPositions(samplesSeen: 20, capacity: 10, interval: 3, width: 100)
        #expect(close(xs, [69.90, 30.10, 9.69]))
    }

    @Test func gridLinesOnlyMarkSamplesThatExist() {
        // Four samples, marks on indices 0 and 3: nothing exists further back.
        let xs = GraphGeometry.timeGridPositions(samplesSeen: 4, capacity: 10, interval: 3, width: 100)
        #expect(close(xs, [100, 39.79]))
    }

    @Test func noSamplesMeansNoGridLines() {
        #expect(GraphGeometry.timeGridPositions(samplesSeen: 0, capacity: 10, interval: 3, width: 100).isEmpty)
    }

    @Test func phaseGlidesTheSamplesBetweenTicks() {
        // Phase 0.5 shifts every age by -0.5: ages 0.5 and -0.5. A negative age continues
        // past the right edge along the curve's starting slope, 1/ln(10) per age here.
        let points = GraphGeometry.compressedPoints(values: [1, 2], capacity: 10,
                                                    range: 0...100, size: size, phase: 0.5)
        #expect(close(points.map(\.x), [82.39, 121.71]))
    }

    @Test func phaseZeroHoldsTheNewestSampleOneTickPastTheEdge() {
        let points = GraphGeometry.compressedPoints(values: [1, 2], capacity: 10,
                                                    range: 0...100, size: size, phase: 0)
        #expect(close(points.map(\.x), [100, 143.43]))
    }

    @Test func gridLinesGlideWithThePhase() {
        // Marks aged 0, 3 and 6 become -1, 2 and 5 at phase 0.
        let xs = GraphGeometry.timeGridPositions(samplesSeen: 7, capacity: 10, interval: 3,
                                                 width: 100, phase: 0)
        #expect(close(xs, [143.43, 52.29, 22.18]))
    }

    private let base = Date(timeIntervalSince1970: 1_000)

    @Test func scrollPhaseIsTheFractionOfATickElapsed() {
        #expect(GraphGeometry.scrollPhase(now: base.addingTimeInterval(0.25), lastSample: base, interval: 2) == 0.125)
    }

    @Test func scrollPhaseStopsAtOneWhenASampleIsLate() {
        #expect(GraphGeometry.scrollPhase(now: base.addingTimeInterval(3), lastSample: base, interval: 1) == 1)
    }

    @Test func scrollPhaseStartsAtZeroForATimestampAhead() {
        #expect(GraphGeometry.scrollPhase(now: base.addingTimeInterval(-1), lastSample: base, interval: 1) == 0)
    }

    @Test func scrollPhaseRestsWithoutASample() {
        #expect(GraphGeometry.scrollPhase(now: base, lastSample: nil, interval: 1) == 1)
    }

    @Test func aCurveNeedsTwoPoints() {
        #expect(GraphGeometry.smoothSegments([]).isEmpty)
        #expect(GraphGeometry.smoothSegments([CGPoint(x: 1, y: 1)]).isEmpty)
    }

    @Test func curvePassesThroughEveryPoint() {
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 10), CGPoint(x: 20, y: 40)]
        #expect(GraphGeometry.smoothSegments(points).map(\.end) == [points[1], points[2]])
    }

    @Test func curveFlattensAtAPeakSoItCannotOvershoot() {
        let segments = GraphGeometry.smoothSegments([CGPoint(x: 0, y: 10), CGPoint(x: 9, y: 0), CGPoint(x: 18, y: 10)])
        #expect(segments.first?.control2 == CGPoint(x: 6, y: 0))
        #expect(segments.last?.control1 == CGPoint(x: 12, y: 0))
    }

    @Test func curveControlsFollowARisingRun() {
        // Slopes 1 and 3 over equal gaps: the middle tangent is their harmonic mean, 1.5.
        let segments = GraphGeometry.smoothSegments([CGPoint(x: 0, y: 0), CGPoint(x: 9, y: 9), CGPoint(x: 18, y: 36)])
        #expect(segments.first?.control1 == CGPoint(x: 3, y: 3))
        #expect(segments.first?.control2 == CGPoint(x: 6, y: 4.5))
        #expect(segments.last?.control1 == CGPoint(x: 12, y: 13.5))
        #expect(segments.last?.control2 == CGPoint(x: 15, y: 27))
    }

    @Test func curveWeighsUnevenGaps() {
        // Gaps 10 and 30, slopes 2 and 1/3: weights 70 and 50 give a tangent of 120/185.
        let segments = GraphGeometry.smoothSegments([CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 20), CGPoint(x: 40, y: 30)])
        let tangent: CGFloat = 120.0 / 185.0
        #expect(abs((segments.last?.control1.y ?? 0) - (20 + tangent * 10)) < 0.001)
        #expect(abs((segments.first?.control2.y ?? 0) - (20 - tangent * 10 / 3)) < 0.001)
    }

    // The current-value marker sits where the drawn curve crosses the right edge.

    @Test func curveHeightFollowsAStraightRun() {
        let points = [CGPoint(x: 0, y: 100), CGPoint(x: 10, y: 50), CGPoint(x: 20, y: 0)]
        let segments = GraphGeometry.smoothSegments(points)
        #expect(GraphGeometry.curveY(atX: 15, start: points[0], segments: segments) == 25)
    }

    @Test func curveHeightAtASampleIsThatSample() {
        let points = [CGPoint(x: 0, y: 80), CGPoint(x: 10, y: 20), CGPoint(x: 20, y: 60)]
        let segments = GraphGeometry.smoothSegments(points)
        #expect(GraphGeometry.curveY(atX: 10, start: points[0], segments: segments) == 20)
        #expect(GraphGeometry.curveY(atX: 20, start: points[0], segments: segments) == 60)
    }

    @Test func curveHeightFollowsTheCurveNotTheChord() {
        // Flat, then a step, then flat: the middle piece eases in and out, so a quarter of the
        // way along it has risen 15.625, where a straight line would have risen 25.
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 20, y: 100), CGPoint(x: 30, y: 100)]
        let segments = GraphGeometry.smoothSegments(points)
        let y = try! #require(GraphGeometry.curveY(atX: 12.5, start: points[0], segments: segments))
        #expect(abs(y - 15.625) < 1e-9)
    }

    @Test func noCurveHeightOutsideTheCurve() {
        let points = [CGPoint(x: 10, y: 0), CGPoint(x: 20, y: 100)]
        let segments = GraphGeometry.smoothSegments(points)
        #expect(GraphGeometry.curveY(atX: 5, start: points[0], segments: segments) == nil)
        #expect(GraphGeometry.curveY(atX: 25, start: points[0], segments: segments) == nil)
        #expect(GraphGeometry.curveY(atX: 15, start: points[0], segments: []) == nil)
    }
}
