import Testing
import SwiftUI
@testable import macOSmonitor

/// The current-value marker is a circle centred on the right edge with only its left half
/// drawn: a 4 pt bulge into the graph, 8 pt tall, centred on the value.
struct MetricGraphMarkerTests {
    @Test func markerIsTheLeftHalfOfACircleOnTheEdge() {
        let bounds = MetricGraph.marker(atY: 50, width: 200).boundingRect
        #expect(abs(bounds.maxX - 200) < 0.01)
        #expect(abs(bounds.minX - 196) < 0.01)
        #expect(abs(bounds.minY - 46) < 0.01)
        #expect(abs(bounds.maxY - 54) < 0.01)
    }

    @Test func markerIsRoundNotPointed() {
        // A triangle's widest point is only at its centre line; a half circle is still
        // most of its width a quarter of the way up.
        let marker = MetricGraph.marker(atY: 50, width: 200)
        #expect(marker.contains(CGPoint(x: 197, y: 48)))
    }
}
