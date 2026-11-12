//
//  ProcessesView.swift
//  macOSmonitor
//

import SwiftUI

/// The process table surface.
///
/// Its view state is owned by `ContentView` rather than held here: this view sits
/// in one branch of the detail pane's `switch`, so navigating to a Performance
/// panel changes structural identity and SwiftUI destroys any `@State` declared
/// locally. Sort order, search text and inspector visibility would reset on every
/// return trip. Bindings keep them alive for the window's lifetime.
struct ProcessesView: View {
    let model: ProcessListModel
    let vitalsModel: VitalsModel

    @Binding var sortOrder: [KeyPathComparator<ProcessInfoRow>]
    @Binding var showInspector: Bool
    @Binding var searchText: String
    @Binding var searchPresented: Bool
    @Binding var filterPreset: ProcessFilter.Preset
    @Binding var hidesSystemProcesses: Bool
    @Binding var savedSearches: SavedSearches
    @Binding var pendingTermination: PendingTermination?
    @Binding var errorMessage: String?

    var body: some View {
        @Bindable var model = model   // enables $model.selectedPID binding

        VStack(spacing: 0) {
            SystemVitalsView(vitals: vitalsModel.vitals)
            Divider()
            ProcessFilterBar(preset: $filterPreset,
                             hidesSystem: $hidesSystemProcesses,
                             searchText: $searchText,
                             savedSearches: $savedSearches)
            Divider()
            ProcessTableView(
                sections: ProcessTableSection.make(
                    rows: model.rows,
                    searchText: searchText,
                    filter: ProcessFilter(preset: filterPreset, hidesSystem: hidesSystemProcesses),
                    sortOrder: sortOrder),
                searchText: searchText,
                selection: $model.selectedPID,
                sortOrder: $sortOrder
            )
            .contextMenu(forSelectionType: pid_t.self) { ids in
                let row = ids.first.flatMap { id in model.rows.first(where: { $0.id == id }) }
                Button(ProcessSignal.terminate.actionTitle) { requestSignal(.terminate, for: row) }
                    .disabled(row?.canTerminate != true)
                Button(ProcessSignal.kill.actionTitle) { requestSignal(.kill, for: row) }
                    .disabled(row?.canTerminate != true)
                Divider()
                Menu("Send Signal") {
                    ForEach(ProcessSignal.sendSignalMenu, id: \.self) { signal in
                        Button(signal.menuTitle) { requestSignal(signal, for: row) }
                    }
                }
                .disabled(row?.canTerminate != true)
            }
        }
        // The Quit / Force Quit / inspector toolbar buttons live on ContentView's window
        // toolbar: a toolbar declared here is rebuilt on every surface change, which loses
        // the user's customization and blocks "Customize Toolbar…" altogether.
        .searchable(text: $searchText, isPresented: $searchPresented,
                    placement: .toolbar, prompt: "Name, PID, or pid: user: path:")
        .focusedSceneValue(\.searchPresented, $searchPresented)
        .focusedSceneValue(\.processTermination, ProcessTerminationActions(
            canTerminate: selectedRow?.canTerminate == true,
            request: { signal in requestSignal(signal, for: selectedRow) }))
        .onChange(of: model.selectedPID) { model.refreshSelection() }
        .inspector(isPresented: $showInspector) {
            ProcessDetailView(model: model)
                .inspectorColumnWidth(min: 240, ideal: 300, max: 420)
        }
        .confirmationDialog(
            confirmTitle,
            isPresented: presenting($pendingTermination),
            presenting: pendingTermination
        ) { item in
            Button(item.signal.actionTitle, role: .destructive) {
                perform(item)
            }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text(item.signal.confirmMessage(name: item.name, pid: item.pid))
        }
        .alert(
            "Couldn’t signal process",
            isPresented: presenting($errorMessage),
            presenting: errorMessage
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }

    // MARK: - Selection helpers

    private var selectedRow: ProcessInfoRow? { model.selectedRow }

    private var confirmTitle: String {
        guard let item = pendingTermination else { return "" }
        return item.signal.confirmTitle(name: item.name)
    }

    // MARK: - Actions

    /// Confirms first, except for signals that don't need it (Resume), which are sent at once.
    private func requestSignal(_ signal: ProcessSignal, for row: ProcessInfoRow?) {
        guard let request = PendingTermination.request(for: row, signal: signal) else { return }
        if signal.needsConfirmation {
            pendingTermination = request
        } else {
            perform(request)
        }
    }

    private func perform(_ item: PendingTermination) {
        let verb = item.signal.actionTitle.lowercased()
        switch model.send(item.signal, to: item.pid) {
        case .success:
            break   // a quit process drops off the next ~1 Hz refresh; status updates likewise
        case .denied:
            errorMessage = "Couldn’t \(verb) “\(item.name)”: permission denied."
        case .noSuchProcess:
            errorMessage = "“\(item.name)” is no longer running."
        case .refusedSelfPause:
            errorMessage = "macOSmonitor can’t pause itself: nothing would be left to resume it."
        case .failure(let reason):
            errorMessage = "Couldn’t \(verb) “\(item.name)”: \(reason)."
        }
    }

    /// Bridges an optional-state binding to the Bool binding dialogs/alerts want:
    /// present when non-nil, clear the state when dismissed.
    private func presenting<T>(_ source: Binding<T?>) -> Binding<Bool> {
        Binding(
            get: { source.wrappedValue != nil },
            set: { shown in if !shown { source.wrappedValue = nil } }
        )
    }
}

/// A signal (Quit, Force Quit, Pause, …) awaiting confirmation.
/// Not file-private: `ContentView` owns this state so it survives navigation.
struct PendingTermination: Identifiable {
    let id = UUID()
    let pid: pid_t
    let name: String
    let signal: ProcessSignal

    /// The request for `row`, or nil when there is none or we may not signal it.
    static func request(for row: ProcessInfoRow?, signal: ProcessSignal) -> PendingTermination? {
        guard let row, row.canTerminate else { return nil }
        return PendingTermination(pid: row.pid, name: row.name, signal: signal)
    }
}

// MARK: - Table Helper View

private struct ProcessTableView: View {
    let sections: [ProcessTableSection]
    /// Bolds the matched letters in the Name and PID columns.
    let searchText: String
    private var query: ProcessQuery { ProcessQuery(searchText) }
    @Binding var selection: pid_t?
    @Binding var sortOrder: [KeyPathComparator<ProcessInfoRow>]

    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(CPUTimeFormat.storageKey) private var cpuTimeFormat: CPUTimeFormat = .adaptive

    var body: some View {
        Table(of: ProcessInfoRow.self, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { row in
                Text(MatchHighlight.attributed(row.name, terms: query.nameHighlights))
                    .themedCell(theme, selected: row.pid == selection)
            }
            TableColumn("PID", value: \.pid) { row in
                Text(MatchHighlight.attributed(String(row.pid), terms: query.pidHighlights(for: row.pid)))
                    .themedCell(theme, selected: row.pid == selection)
            }
            TableColumn("CPU %", value: \.cpuSortKey) { row in
                Text(row.cpuText)
                    .monospacedDigit()
                    .themedCell(theme, selected: row.pid == selection)
            }
            TableColumn("CPU Time", value: \.cpuTimeSortKey) { row in
                Text(row.cpuTimeText(cpuTimeFormat))
                    .monospacedDigit()
                    .themedCell(theme, selected: row.pid == selection)
            }
            TableColumn("Memory", value: \.memSortKey) { row in
                Text(row.memoryText)
                    .monospacedDigit()
                    .themedCell(theme, selected: row.pid == selection)
            }
        } rows: {
            ForEach(sections) { section in
                Section(section.title) {
                    ForEach(section.rows) { row in
                        TableRow(row)
                    }
                }
            }
        }
        // The System theme keeps the native table. Fixed (VFD) palettes paint the panel
        // background, drop the light alternating stripes, and force dark appearance so the
        // header, section headers and scrollers — which can't be coloured — match.
        .scrollContentBackground(theme.usesSystemColors ? .automatic : .hidden)
        .background(theme.usesSystemColors ? Color.clear : theme.panelBackground)
        .alternatingRowBackgrounds(theme.usesSystemColors ? .enabled : .disabled)
        .environment(\.colorScheme, theme.forcedColorScheme ?? colorScheme)
    }
}

private extension View {
    /// Phosphor-coloured text for a fixed palette. Left alone for the System theme, and in
    /// the selected row, where the system's white-on-blue stays legible and a green or
    /// amber accent on blue would not.
    @ViewBuilder
    func themedCell(_ theme: Theme, selected: Bool) -> some View {
        if theme.usesSystemColors || selected {
            self
        } else {
            foregroundStyle(theme.primaryText)
        }
    }
}
