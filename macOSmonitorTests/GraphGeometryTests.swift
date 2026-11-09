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
}
