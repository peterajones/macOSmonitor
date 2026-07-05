//
//  ContentView.swift
//  macOSmonitor
//

import SwiftUI

struct ContentView: View {
    @State private var model = ProcessListModel()
    @State private var sortOrder = [KeyPathComparator(\ProcessInfoRow.cpuSortKey, order: .reverse)]
    @State private var showInspector = true
    @State private var searchText = ""
    @State private var searchPresented = false
    @State private var pendingTermination: PendingTermination?
    @State private var errorMessage: String?

    var body: some View {
        @Bindable var model = model   // enables $model.selectedPID binding

        ProcessTableView(
            data: model.rows.filter { $0.matches(searchText) }.sorted(using: sortOrder),
            selection: $model.selectedPID,
            sortOrder: $sortOrder
        )
        .contextMenu(forSelectionType: pid_t.self) { ids in
            let row = ids.first.flatMap { id in model.rows.first(where: { $0.id == id }) }
            Button("Quit") { requestTermination(row, force: false) }
                .disabled(row?.canTerminate != true)
            Button("Force Quit") { requestTermination(row, force: true) }
                .disabled(row?.canTerminate != true)
        }
        .toolbar {
            ToolbarItemGroup {
                Button("Quit") { requestTermination(selectedRow, force: false) }
                    .disabled(selectedRow?.canTerminate != true)
                Button("Force Quit") { requestTermination(selectedRow, force: true) }
                    .disabled(selectedRow?.canTerminate != true)
            }
            ToolbarItem {
                Button { showInspector.toggle() } label: {
                    Label("Toggle Inspector", systemImage: "sidebar.trailing")
                }
            }
        }
        .frame(minWidth: 720, minHeight: 400)
        .navigationTitle("macOSmonitor")
        .searchable(text: $searchText, isPresented: $searchPresented,
                    placement: .toolbar, prompt: "Filter by name or PID")
        .focusedSceneValue(\.searchPresented, $searchPresented)
        .task { await model.run() }
        .onChange(of: model.selectedPID) { model.refreshDetails() }
        .inspector(isPresented: $showInspector) {
            ProcessDetailView(row: selectedRow, details: model.selectedDetails)
                .inspectorColumnWidth(min: 240, ideal: 300, max: 420)
        }
        .confirmationDialog(
            confirmTitle,
            isPresented: presenting($pendingTermination),
            presenting: pendingTermination
        ) { item in
            Button(item.force ? "Force Quit" : "Quit", role: .destructive) {
                performTermination(item)
            }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text(item.force
                 ? "Force-quitting “\(item.name)” ends it immediately; unsaved work is lost."
                 : "“\(item.name)” (PID \(item.pid)) will be asked to quit.")
        }
        .alert(
            "Couldn’t terminate process",
            isPresented: presenting($errorMessage),
            presenting: errorMessage
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }

    // MARK: - Selection helpers

    private var selectedRow: ProcessInfoRow? {
        guard let pid = model.selectedPID else { return nil }
        return model.rows.first { $0.id == pid }
    }

    private var confirmTitle: String {
        guard let item = pendingTermination else { return "" }
        return item.force ? "Force Quit “\(item.name)”?" : "Quit “\(item.name)”?"
    }

    // MARK: - Actions

    private func requestTermination(_ row: ProcessInfoRow?, force: Bool) {
        guard let row, row.canTerminate else { return }
        pendingTermination = PendingTermination(pid: row.pid, name: row.name, force: force)
    }

    private func performTermination(_ item: PendingTermination) {
        switch model.terminate(pid: item.pid, force: item.force) {
        case .success:
            break   // process drops off the next ~1 Hz refresh
        case .denied:
            errorMessage = "Couldn’t terminate “\(item.name)”: permission denied."
        case .noSuchProcess:
            errorMessage = "“\(item.name)” is no longer running."
        case .failure(let reason):
            errorMessage = "Couldn’t terminate “\(item.name)”: \(reason)."
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

/// A pending Quit/Force-Quit awaiting confirmation.
private struct PendingTermination: Identifiable {
    let id = UUID()
    let pid: pid_t
    let name: String
    let force: Bool
}

// MARK: - Table Helper View

private struct ProcessTableView: View {
    let data: [ProcessInfoRow]
    @Binding var selection: pid_t?
    @Binding var sortOrder: [KeyPathComparator<ProcessInfoRow>]

    var body: some View {
        Table(data, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name)
            TableColumn("PID", value: \.pid) { row in
                Text(String(row.pid))
            }
            TableColumn("CPU %", value: \.cpuSortKey) { row in
                Text(row.cpuText)
                    .monospacedDigit()
            }
            TableColumn("CPU Time", value: \.cpuTimeSortKey) { row in
                Text(row.cpuTimeText)
                    .monospacedDigit()
            }
            TableColumn("Memory", value: \.memSortKey) { row in
                Text(row.memoryText)
                    .monospacedDigit()
            }
        }
    }
}

#Preview {
    ContentView()
}
