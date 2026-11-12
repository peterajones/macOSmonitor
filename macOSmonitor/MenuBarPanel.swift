import SwiftUI

/// The menu-bar item's label: a gauge and the live CPU %.
struct MenuBarLabel: View {
    let vitalsModel: VitalsModel

    var body: some View {
        // Read the model inside body (never a snapshot), so the label updates each tick.
        Image(systemName: "gauge.with.dots.needle.33percent")
        Text(MenuBarReadout.label(vitalsModel.vitals))
            .monospacedDigit()
    }
}

/// The panel that opens from the menu-bar item: vitals with meters, the busiest processes,
/// and buttons to open the main window or quit.
struct MenuBarPanel: View {
    let vitalsModel: VitalsModel
    /// Its own process list, sampled only while the panel is open (see `.task` below), so the
    /// menu bar adds no process sampling the rest of the time.
    @State private var processModel = ProcessListModel()
    @Environment(\.openWindow) private var openWindow
    @Environment(\.theme) private var theme

    static let topProcessCount = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                ForEach(MenuBarReadout.rows(vitalsModel.vitals)) { row in
                    GridRow {
                        Text(row.title).foregroundStyle(.secondary)
                        if let fraction = row.fraction {
                            MeterBar(fraction: fraction, orientation: .horizontal,
                                     onColor: theme.color(for: row.metric), offColor: theme.meterOff)
                                .frame(width: 100, height: 8)
                        } else {
                            Color.clear.frame(width: 100, height: 8)
                        }
                        Text(row.value).monospacedDigit()
                            .gridColumnAlignment(.trailing)
                    }
                }
            }

            Divider()

            Text("Top Processes").font(.caption).foregroundStyle(.secondary)
            let top = processModel.topByCPU(limit: Self.topProcessCount)
            if top.isEmpty {
                Text("Sampling…").foregroundStyle(.secondary)
            } else {
                ForEach(top) { row in
                    HStack {
                        Text(row.name).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(row.cpuText + "%").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }

            Divider()

            HStack {
                Button("Open macOSmonitor") {
                    openWindow(id: macOSmonitorApp.mainWindowID)
                    NSApp.activate()
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(14)
        .frame(width: 300)
        .task { await processModel.run() }   // cancelled when the panel closes
    }
}
