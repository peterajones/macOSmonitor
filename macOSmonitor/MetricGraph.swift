import SwiftUI

/// An immediate-mode history graph: grid, filled area, and stroked trace.
/// Redrawn by ordinary @Observable invalidation at ~1 Hz — no TimelineView.
struct MetricGraph: View {
    let values: [Double]
    var capacity: Int = 60
    let range: ClosedRange<Double>
    let lineColor: Color
    let fillColor: Color
    let gridColor: Color

    private let gridDivisions = 4

    var body: some View {
        Canvas { context, size in
            drawGrid(in: &context, size: size)

            let points = GraphGeometry.points(values: values, capacity: capacity,
                                              range: range, size: size)
            guard points.count > 1 else { return }

            var trace = Path()
            trace.addLines(points)

            var area = trace
            area.addLine(to: CGPoint(x: points[points.count - 1].x, y: size.height))
            area.addLine(to: CGPoint(x: points[0].x, y: size.height))
            area.closeSubpath()

            context.fill(area, with: .color(fillColor))
            context.stroke(trace, with: .color(lineColor), lineWidth: 1.5)
        }
    }

    private func drawGrid(in context: inout GraphicsContext, size: CGSize) {
        var grid = Path()
        for division in 0...gridDivisions {
            let y = size.height * CGFloat(division) / CGFloat(gridDivisions)
            grid.move(to: CGPoint(x: 0, y: y))
            grid.addLine(to: CGPoint(x: size.width, y: y))
        }
        for division in 0...gridDivisions {
            let x = size.width * CGFloat(division) / CGFloat(gridDivisions)
            grid.move(to: CGPoint(x: x, y: 0))
            grid.addLine(to: CGPoint(x: x, y: size.height))
        }
        context.stroke(grid, with: .color(gridColor), lineWidth: 0.5)
    }
}

#Preview {
    MetricGraph(values: (0..<40).map { _ in Double.random(in: 10...90) },
                range: 0...100,
                lineColor: .green, fillColor: .green.opacity(0.2), gridColor: .gray.opacity(0.3))
        .frame(width: 400, height: 160)
        .padding()
}
