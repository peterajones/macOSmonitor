import SwiftUI

/// Where battery history samples land in the graph: x by time across the last 24 hours,
/// y by charge. Pure and static, like `GraphGeometry`, so the mapping is testable.
enum BatteryGraphGeometry {
    static func point(_ sample: BatteryHistory.Sample, now: Date, in size: CGSize) -> CGPoint {
        let start = now.addingTimeInterval(-BatteryHistory.window)
        let fraction = sample.date.timeIntervalSince(start) / BatteryHistory.window
        let charge = min(max(Double(sample.percent), 0), 100) / 100
        return CGPoint(x: fraction * size.width, y: (1 - charge) * size.height)
    }

    /// The horizontal spans (x ranges) during which the Mac was on power, for the strip
    /// under the graph. A span ends where its segment does, or where power was removed.
    static func onPowerSpans(_ segments: [[BatteryHistory.Sample]], now: Date,
                             in size: CGSize) -> [ClosedRange<CGFloat>] {
        var spans: [ClosedRange<CGFloat>] = []
        for segment in segments {
            var spanStart: CGFloat?
            for sample in segment {
                let x = point(sample, now: now, in: size).x
                if sample.onPower, spanStart == nil { spanStart = x }
                if !sample.onPower, let start = spanStart { spans.append(start...x); spanStart = nil }
            }
            if let start = spanStart, let last = segment.last {
                spans.append(start...point(last, now: now, in: size).x)
            }
        }
        return spans
    }
}

/// The Battery Performance panel: charge history for the last 24 hours, then health.
struct BatteryPanel: View {
    let model: BatteryModel
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Battery").font(.title2).foregroundStyle(theme.primaryText)
                Spacer()
                Text(model.info?.displayText ?? "—")
                    .font(.title2)
                    .monospacedDigit()
                    .foregroundStyle(theme.primaryText)
            }

            BatteryHistoryGraph(segments: model.history.segments, now: Date(),
                                lineColor: theme.graphLine, fillColor: theme.graphFill,
                                gridColor: theme.gridLine)
                .frame(minHeight: 180)

            HStack {
                Text("Last 24 hours, while macOSmonitor was running")
                Spacer()
                // A key, not a status: worded so it can't be read as "on power now", and only
                // shown when there is a bar for it to explain.
                if model.history.hasOnPowerTime {
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 1).fill(theme.graphLine).frame(width: 12, height: 4)
                        Text("Bar below graph = on power")
                    }
                }
            }
            .font(.caption2)
            .foregroundStyle(theme.secondaryText)

            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                fact("Status", BatteryModel.statusText(model.info))
                fact("Maximum Capacity", model.health?.maximumCapacityText ?? "—")
                fact("Cycle Count", model.health?.cycleCountText ?? "—")
                fact("Full Charge", model.health?.capacityText ?? "—")
                fact("Temperature", model.health?.temperatureText ?? "—")
                fact("Power", model.health?.powerText ?? "—")
            }
            .padding(.top, 8)

            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.panelBackground)
    }

    private func fact(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(theme.secondaryText)
            Text(value).monospacedDigit().foregroundStyle(theme.primaryText)
        }
    }
}

/// 24-hour charge graph: 0–100% with quarter grid lines and 6-hour marks, one line per
/// unbroken run of samples, and a strip along the bottom wherever the Mac was on power.
struct BatteryHistoryGraph: View {
    let segments: [[BatteryHistory.Sample]]
    let now: Date
    let lineColor: Color
    let fillColor: Color
    let gridColor: Color

    private let stripHeight: CGFloat = 4

    var body: some View {
        Canvas { context, size in
            let plot = CGSize(width: size.width, height: size.height - stripHeight - 2)

            var grid = Path()
            for quarter in 1...3 {
                let y = plot.height * CGFloat(quarter) / 4
                grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: plot.width, y: y))
            }
            for sixth in 1...3 {
                let x = plot.width * CGFloat(sixth) / 4
                grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: plot.height))
            }
            grid.addRect(CGRect(origin: .zero, size: plot))
            context.stroke(grid, with: .color(gridColor), lineWidth: 0.5)

            for segment in segments {
                let points = segment.map { BatteryGraphGeometry.point($0, now: now, in: plot) }
                guard let first = points.first, let last = points.last else { continue }
                var line = Path()
                line.addLines(points)
                if points.count == 1 {   // a lone sample: a dot, or it would be invisible
                    context.fill(Path(ellipseIn: CGRect(x: first.x - 1.5, y: first.y - 1.5, width: 3, height: 3)),
                                 with: .color(lineColor))
                    continue
                }
                var area = line
                area.addLine(to: CGPoint(x: last.x, y: plot.height))
                area.addLine(to: CGPoint(x: first.x, y: plot.height))
                area.closeSubpath()
                context.fill(area, with: .color(fillColor))
                context.stroke(line, with: .color(lineColor),
                               style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }

            for span in BatteryGraphGeometry.onPowerSpans(segments, now: now, in: plot) {
                let rect = CGRect(x: span.lowerBound, y: size.height - stripHeight,
                                  width: max(span.upperBound - span.lowerBound, 2), height: stripHeight)
                context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(lineColor))
            }
        }
        .accessibilityLabel("Battery charge over the last 24 hours")
    }
}
