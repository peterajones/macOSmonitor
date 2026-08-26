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
}
