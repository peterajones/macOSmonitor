import SwiftUI

/// Turns on a `MetricGraph`'s compressed time axis, with marks every `gridInterval` samples.
struct CompressedTimeAxis {
    let samplesSeen: Int
    let gridInterval: Int
    let lastSample: Date?
    let sampleInterval: TimeInterval
}

extension CompressedTimeAxis {
    /// For a graph of `history`, sampled every `sampleInterval` seconds, with a time mark
    /// every `gridInterval` samples.
    init(history: MetricHistory, lastSample: Date?, sampleInterval: TimeInterval = 1, gridInterval: Int = 10) {
        self.init(samplesSeen: history.totalAppended, gridInterval: gridInterval,
                  lastSample: lastSample, sampleInterval: sampleInterval)
    }
}

/// An immediate-mode history graph: grid, filled area, a glowing trace that brightens with
/// its value, and a marker at the right edge pointing at the current value.
/// Redrawn by ordinary @Observable invalidation at ~1 Hz, except with a compressed time
/// axis, which glides at `graphFrameRate` and only runs while that graph is on screen.
struct MetricGraph: View {
    let values: [Double]
    var capacity: Int = 60
    let range: ClosedRange<Double>
    let lineColor: Color
    let fillColor: Color
    let gridColor: Color
    var timeAxis: CompressedTimeAxis? = nil
    /// A 1 pt frame in the line colour. Off for a second trace overlaid on another graph,
    /// which already has one.
    var showsBorder = true
    /// Called once per animation frame of the compressed time axis. A seam for tests that
    /// check the 15 fps animation runs only while the graph is on screen.
    var onFrame: (() -> Void)? = nil

    @Environment(\.graphFrameRate) private var frameRate

    private let gridDivisions = 4

    var body: some View {
        content.overlay {
            if showsBorder { Rectangle().strokeBorder(lineColor, lineWidth: 1) }
        }
    }

    @ViewBuilder private var content: some View {
        if let timeAxis {
            TimelineView(.animation(minimumInterval: 1.0 / frameRate)) { timeline in
                let _ = onFrame?()
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
            var markerY = points[points.count - 1].y
            if timeAxis == nil {
                trace.addLines(points)
            } else {
                let segments = GraphGeometry.smoothSegments(points)
                trace.move(to: points[0])
                for segment in segments {
                    trace.addCurve(to: segment.end, control1: segment.control1, control2: segment.control2)
                }
                // The newest sample glides in from past the right edge: point at the curve
                // where it crosses the edge, not at a sample that isn't visible yet.
                markerY = GraphGeometry.curveY(atX: size.width, start: points[0], segments: segments) ?? markerY
            }

            var area = trace
            area.addLine(to: CGPoint(x: points[points.count - 1].x, y: size.height))
            area.addLine(to: CGPoint(x: points[0].x, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .color(fillColor))

            context.drawLayer { glow in
                glow.addFilter(.blur(radius: 3))
                glow.stroke(trace, with: .color(lineColor.opacity(0.6)), lineWidth: 3)
            }
            // Full strength at the top of the range, dimmer towards the bottom, in the
            // metric's own colour so every theme (and the monochrome VFDs) keeps its look.
            let shading = GraphicsContext.Shading.linearGradient(
                Gradient(colors: [lineColor, lineColor.opacity(0.55)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height))
            context.stroke(trace, with: shading, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))

            context.fill(Self.marker(atY: markerY, width: size.width), with: .color(lineColor))
        }
    }

    /// A circle centred on the right edge, of which only the left half is drawn.
    nonisolated static func marker(atY y: CGFloat, width: CGFloat) -> Path {
        var path = Path()
        // y points down, so sweeping from 90° (below) through 180° (left) ends above.
        path.addRelativeArc(center: CGPoint(x: width, y: y), radius: 4,
                            startAngle: .degrees(90), delta: .degrees(180))
        path.closeSubpath()
        return path
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
