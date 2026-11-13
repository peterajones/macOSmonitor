import SwiftUI

/// Every open TCP/UDP socket on the Mac, by process: answers "what's on port 3000?".
///
/// Its view state (search, filter, sort) is owned by `ContentView`, like the Processes
/// surface's: this view sits in one branch of the detail `switch`, so local `@State` would
/// reset on every navigation. The sampling loop, on the other hand, belongs here: it should
/// stop when you navigate away.
struct PortsView: View {
    let model: PortsModel
    @Binding var searchText: String
    @Binding var filter: PortFilter
    @Binding var sortOrder: [KeyPathComparator<PortRow>]

    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Show", selection: $filter) {
                    ForEach(PortFilter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Spacer()
                Text("\(rows.count) sockets")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            Table(rows, sortOrder: $sortOrder) {
                TableColumn("Process", value: \.processName) { row in
                    Text(row.processName).themedPortCell(theme)
                }
                TableColumn("PID", value: \.pid) { row in
                    Text(String(row.pid)).monospacedDigit().themedPortCell(theme)
                }
                .width(min: 50, ideal: 60)
                TableColumn("Protocol", value: \.protocolKey) { row in
                    Text(row.port.protocolName).themedPortCell(theme)
                }
                .width(min: 50, ideal: 60)
                TableColumn("Local", value: \.localPortKey) { row in
                    Text(row.localText).monospacedDigit().themedPortCell(theme)
                }
                TableColumn("Remote", value: \.remoteText) { row in
                    Text(row.remoteText).monospacedDigit().themedPortCell(theme)
                }
                TableColumn("State", value: \.stateText) { row in
                    Text(row.stateText).themedPortCell(theme)
                }
            }
            // Same theming as the process table: the System theme keeps the native look.
            .scrollContentBackground(theme.usesSystemColors ? .automatic : .hidden)
            .background(theme.usesSystemColors ? Color.clear : theme.panelBackground)
            .alternatingRowBackgrounds(theme.usesSystemColors ? .enabled : .disabled)
            .environment(\.colorScheme, theme.forcedColorScheme ?? colorScheme)
            .overlay {
                if rows.isEmpty && !model.rows.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "Process, PID, port, address")
        .task { await model.run() }
    }

    /// Filtered and searched; listening first (the sampler's order) until a column is clicked.
    private var rows: [PortRow] {
        let visible = PortRow.visible(model.rows, filter: filter, searchText: searchText)
        return sortOrder.isEmpty ? visible : visible.sorted(using: sortOrder)
    }
}

private extension View {
    /// Phosphor-coloured text for a fixed palette; the System theme keeps the default.
    @ViewBuilder
    func themedPortCell(_ theme: Theme) -> some View {
        if theme.usesSystemColors { self } else { foregroundStyle(theme.primaryText) }
    }
}
