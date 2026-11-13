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
    /// The table's rows as filtered and sorted now, built by `ContentView` so its toolbar
    /// acts on exactly the rows shown here.
    let sections: [ProcessTableSection]

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
        @Bindable var model = model   // enables the $model.selectedPIDs binding

        VStack(spacing: 0) {
            SystemVitalsView(vitals: vitalsModel.vitals, thermal: vitalsModel.thermal)
            Divider()
            ProcessFilterBar(preset: $filterPreset,
                             hidesSystem: $hidesSystemProcesses,
                             searchText: $searchText,
                             savedSearches: $savedSearches)
            Divider()
            ProcessTableView(
                sections: sections,
                searchText: searchText,
                selection: $model.selectedPIDs,
                sortOrder: $sortOrder
            )
            // `ids` is what was right-clicked: the whole selection when the click is inside
            // it, otherwise just the clicked row (the selection is left alone) — the standard
            // macOS rule, so a right-click never acts on rows you didn't point at.
            .contextMenu(forSelectionType: pid_t.self) { ids in
                let batch = batch(for: ids)
                Button(ProcessSignal.terminate.actionTitle) { requestSignal(.terminate, for: batch) }
                    .disabled(batch.targets.isEmpty)
                Button(ProcessSignal.kill.actionTitle) { requestSignal(.kill, for: batch) }
                    .disabled(batch.targets.isEmpty)
                Divider()
                Menu("Send Signal") {
                    ForEach(ProcessSignal.sendSignalMenu, id: \.self) { signal in
                        Button(signal.menuTitle) { requestSignal(signal, for: batch) }
                    }
                }
                .disabled(batch.targets.isEmpty)
            }
        }
        // The Quit / Force Quit / inspector toolbar buttons live on ContentView's window
        // toolbar: a toolbar declared here is rebuilt on every surface change, which loses
        // the user's customization and blocks "Customize Toolbar…" altogether.
        .searchable(text: $searchText, isPresented: $searchPresented,
                    placement: .toolbar, prompt: "Name, PID, or pid: user: path:")
        .focusedSceneValue(\.searchPresented, $searchPresented)
        .focusedSceneValue(\.processTermination, ProcessTerminationActions(
            canTerminate: !batch(for: model.selectedPIDs).targets.isEmpty,
            request: { signal in requestSignal(signal, for: batch(for: model.selectedPIDs)) }))
        .onChange(of: model.selectedPIDs) {
            model.refreshSelection()
            // A root process's details come from the helper, asynchronously; ask now rather
            // than waiting for the next tick.
            Task { await model.refreshPrivileged() }
        }
        .inspector(isPresented: $showInspector) {
            ProcessDetailView(model: model, visibleRows: sections.flatMap(\.rows))
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
            Text(item.message)
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

    /// What a signal to `pids` would act on: only rows the table shows right now.
    private func batch(for pids: Set<pid_t>) -> ProcessBatch {
        ProcessBatch.make(pids: pids, visibleRows: sections.flatMap(\.rows))
    }

    private var confirmTitle: String {
        pendingTermination?.title ?? ""
    }

    // MARK: - Actions

    /// Confirms first, except for signals that don't need it (Resume), which are sent at once.
    private func requestSignal(_ signal: ProcessSignal, for batch: ProcessBatch) {
        guard let request = PendingTermination.request(for: batch, signal: signal) else { return }
        if signal.needsConfirmation {
            pendingTermination = request
        } else {
            perform(request)
        }
    }

    /// Sends the confirmed signal; quit processes drop off the next ~1 Hz refresh, so only
    /// failures are reported, in one alert.
    private func perform(_ item: PendingTermination) {
        let outcomes = model.send(item.signal, to: item.targets)
        errorMessage = SignalOutcome.failureMessage(outcomes, signal: item.signal)
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

// MARK: - Table Helper View

private struct ProcessTableView: View {
    let sections: [ProcessTableSection]
    /// Bolds the matched letters in the Name and PID columns.
    let searchText: String
    private var query: ProcessQuery { ProcessQuery(searchText) }
    @Binding var selection: Set<pid_t>
    @Binding var sortOrder: [KeyPathComparator<ProcessInfoRow>]

    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(CPUTimeFormat.storageKey) private var cpuTimeFormat: CPUTimeFormat = .adaptive

    var body: some View {
        Table(of: ProcessInfoRow.self, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { row in
                Text(MatchHighlight.attributed(row.name, terms: query.nameHighlights))
                    .themedCell(theme, selected: selection.contains(row.pid))
            }
            TableColumn("PID", value: \.pid) { row in
                Text(MatchHighlight.attributed(String(row.pid), terms: query.pidHighlights(for: row.pid)))
                    .themedCell(theme, selected: selection.contains(row.pid))
            }
            TableColumn("CPU %", value: \.cpuSortKey) { row in
                Text(row.cpuText)
                    .monospacedDigit()
                    .themedCell(theme, selected: selection.contains(row.pid))
            }
            TableColumn("CPU Time", value: \.cpuTimeSortKey) { row in
                Text(row.cpuTimeText(cpuTimeFormat))
                    .monospacedDigit()
                    .themedCell(theme, selected: selection.contains(row.pid))
            }
            TableColumn("GPU %", value: \.gpuSortKey) { row in
                Text(row.gpuText)
                    .monospacedDigit()
                    .themedCell(theme, selected: selection.contains(row.pid))
            }
            TableColumn("Power (W)", value: \.powerSortKey) { row in
                Text(row.powerText)
                    .monospacedDigit()
                    .themedCell(theme, selected: selection.contains(row.pid))
            }
            TableColumn("Memory", value: \.memSortKey) { row in
                Text(row.memoryText)
                    .monospacedDigit()
                    .themedCell(theme, selected: selection.contains(row.pid))
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
