import SwiftUI

/// Turns on a `MetricGraph`'s compressed time axis, with marks every `gridInterval` samples.
struct CompressedTimeAxis {
    let samplesSeen: Int
    let gridInterval: Int
    let lastSample: Date?
    let sampleInterval: TimeInterval
}

/// An immediate-mode history graph: grid, filled area, and stroked trace.
/// Redrawn by ordinary @Observable invalidation at ~1 Hz, except with a compressed time
/// axis, which glides at 15 fps and only runs while that graph is on screen.
struct MetricGraph: View {
    let values: [Double]
    var capacity: Int = 60
    let range: ClosedRange<Double>
    let lineColor: Color
    let fillColor: Color
    let gridColor: Color
    var timeAxis: CompressedTimeAxis? = nil

    private let gridDivisions = 4

    var body: some View {
        if let timeAxis {
            TimelineView(.animation(minimumInterval: 1.0 / 15)) { timeline in
                canvas(phase: GraphGeometry.scrollPhase(now: timeline.date,
                                                        lastSample: timeAxis.lastSample,
                                                        interval: timeAxis.sampleInterval))
            }
        } else {
            canvas(phase: 1)
        }
    }

    private func canvas(phase: Double) -> some View {
        Canvas { context, size in
            drawGrid(in: &context, size: size, phase: phase)

            let points = timeAxis == nil
                ? GraphGeometry.points(values: values, capacity: capacity, range: range, size: size)
                : GraphGeometry.compressedPoints(values: values, capacity: capacity,
                                                 range: range, size: size, phase: phase)
            guard points.count > 1 else { return }

            var trace = Path()
            if timeAxis == nil {
                trace.addLines(points)
            } else {
                trace.move(to: points[0])
                for segment in GraphGeometry.smoothSegments(points) {
                    trace.addCurve(to: segment.end, control1: segment.control1, control2: segment.control2)
                }
            }

            var area = trace
            area.addLine(to: CGPoint(x: points[points.count - 1].x, y: size.height))
            area.addLine(to: CGPoint(x: points[0].x, y: size.height))
            area.closeSubpath()

            context.fill(area, with: .color(fillColor))
            context.stroke(trace, with: .color(lineColor), lineWidth: 1.5)
        }
    }

    private func drawGrid(in context: inout GraphicsContext, size: CGSize, phase: Double) {
        var grid = Path()
        for division in 0...gridDivisions {
            let y = size.height * CGFloat(division) / CGFloat(gridDivisions)
            grid.move(to: CGPoint(x: 0, y: y))
            grid.addLine(to: CGPoint(x: size.width, y: y))
        }
        for x in verticalGridPositions(width: size.width, phase: phase) {
            grid.move(to: CGPoint(x: x, y: 0))
            grid.addLine(to: CGPoint(x: x, y: size.height))
        }
        context.stroke(grid, with: .color(gridColor), lineWidth: 0.5)
    }

    private func verticalGridPositions(width: CGFloat, phase: Double) -> [CGFloat] {
        if let timeAxis {
            return GraphGeometry.timeGridPositions(samplesSeen: timeAxis.samplesSeen,
                                                   capacity: capacity,
                                                   interval: timeAxis.gridInterval,
                                                   width: width,
                                                   phase: phase)
        }
        return (0...gridDivisions).map { width * CGFloat($0) / CGFloat(gridDivisions) }
    }
}

#Preview {
    MetricGraph(values: (0..<40).map { _ in Double.random(in: 10...90) },
                range: 0...100,
                lineColor: .green, fillColor: .green.opacity(0.2), gridColor: .gray.opacity(0.3))
        .frame(width: 400, height: 160)
        .padding()
}
