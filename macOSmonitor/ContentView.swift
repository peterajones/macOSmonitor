//
//  ContentView.swift
//  macOSmonitor
//

import SwiftUI

struct ContentView: View {
    @State private var model = ProcessListModel(privileged: PrivilegedHelperClient.shared)
    /// Owned by the app, shared with the menu bar and other windows; its loop runs there.
    let vitalsModel: VitalsModel
    @State private var batteryModel = BatteryModel()
    /// Sampled only while the Ports surface shows (its view runs the loop); held here so the
    /// last sample is on screen at once when you come back.
    @State private var portsModel = PortsModel(sampler: PortsSampler(privileged: PrivilegedHelperClient.shared))
    @State private var surface: Surface? = .summary
    @AppStorage("themeID") private var themeID: String = Theme.system.id

    // Owned here, not in ProcessesView: that view lives in one branch of the detail
    // `switch` below, so it is destroyed and recreated on every surface change and
    // any @State it declared would reset. Held here, these survive navigation.
    @State private var sortOrder = [KeyPathComparator(\ProcessInfoRow.cpuSortKey, order: .reverse)]
    @State private var showInspector = true
    @State private var searchText = ""
    @State private var searchPresented = false
    @State private var pendingTermination: PendingTermination?
    @State private var errorMessage: String?
    // The Ports surface's view state, held here for the same reason as the Processes state.
    @State private var portsSearchText = ""
    @State private var portsFilter: PortFilter = .all
    @State private var portsSortOrder: [KeyPathComparator<PortRow>] = []
    // Remembered across launches, like Activity Monitor's View menu choice. Search text
    // itself is not: a filter you forgot about would hide processes on the next launch.
    @AppStorage("processFilterPreset") private var filterPreset: ProcessFilter.Preset = .all
    @AppStorage("hideSystemProcesses") private var hidesSystemProcesses = false
    @AppStorage("savedSearches") private var savedSearches = SavedSearches()

    private var theme: Theme { Theme.named(themeID) }

    var body: some View {
        NavigationSplitView {
            List(selection: $surface) {
                Label(Surface.summary.title, systemImage: "square.grid.2x2")
                    .tag(Surface.summary)
                Label(Surface.processes.title, systemImage: "list.bullet")
                    .tag(Surface.processes)
                Label(Surface.ports.title, systemImage: "network")
                    .tag(Surface.ports)
                Section("Performance") {
                    ForEach(Surface.performance(hasGPU: vitalsModel.vitals?.gpu != nil,
                                                hasThermal: vitalsModel.thermal != nil,
                                                hasEnergy: vitalsModel.power != nil,
                                                hasBattery: vitalsModel.vitals?.battery != nil)) { item in
                        if let metric = item.metric {
                            SidebarMeter(title: item.title,
                                         value: meterValue(item),
                                         fraction: meterFraction(item),
                                         metric: metric)
                                .tag(item)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            switch surface ?? .summary {
            case .summary:
                SummaryView(model: model, vitalsModel: vitalsModel, surface: $surface)
            case .processes:
                ProcessesView(model: model,
                              vitalsModel: vitalsModel,
                              sections: sections,
                              sortOrder: $sortOrder,
                              showInspector: $showInspector,
                              searchText: $searchText,
                              searchPresented: $searchPresented,
                              filterPreset: $filterPreset,
                              hidesSystemProcesses: $hidesSystemProcesses,
                              savedSearches: $savedSearches,
                              pendingTermination: $pendingTermination,
                              errorMessage: $errorMessage)
            case .ports:
                PortsView(model: portsModel,
                          searchText: $portsSearchText,
                          filter: $portsFilter,
                          sortOrder: $portsSortOrder)
            case .cpu:
                CPUPanel(model: vitalsModel)
            case .gpu:
                GPUPanel(model: vitalsModel)
            case .memory:
                MemoryPanel(model: vitalsModel)
            case .network:
                NetworkPanel(model: vitalsModel)
            case .disk:
                DiskPanel(model: vitalsModel)
            case .thermal:
                ThermalPanel(model: vitalsModel)
            case .energy:
                EnergyPanel(model: vitalsModel, processes: model)
            case .battery:
                BatteryPanel(model: batteryModel)
            }
        }
        .frame(minWidth: 900, minHeight: 500)
        .navigationTitle("macOSmonitor")
        .environment(\.theme, theme)
        // One customizable toolbar for the whole window (right-click → Customize Toolbar…),
        // declared here so it survives surface changes. Item IDs are what macOS stores the
        // user's arrangement under: don't rename them. The process buttons stay visible but
        // disabled off the Processes surface; hiding them would rebuild the toolbar.
        .toolbar(id: "main") {
            ToolbarItem(id: "quit") {
                Button("Quit") { pendingTermination = processRequest(.terminate) }
                    .disabled(!canTerminateSelection)
            }
            ToolbarItem(id: "forceQuit") {
                Button("Force Quit") { pendingTermination = processRequest(.kill) }
                    .disabled(!canTerminateSelection)
            }
            ToolbarItem(id: "inspector") {
                Button { showInspector.toggle() } label: {
                    Label("Toggle Inspector", systemImage: "sidebar.trailing")
                }
                .disabled(surface != .processes)
            }
            ToolbarItem(id: "theme") {
                Menu {
                    Picker("Theme", selection: $themeID) {
                        ForEach(Theme.all) { option in
                            Text(option.name).tag(option.id)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Theme", systemImage: "paintpalette")
                }
            }
        }
        // The window's loops live here, on the always-alive split view: the process loop
        // moved up in M11 so the Summary's top-processes card has data on every surface.
        // A loop owned by a view inside the detail `switch` would be cancelled on every
        // navigation. The vitals loop moved further up, to the app, so the menu bar shares
        // it (see macOSmonitorApp).
        .task { await model.run() }
        // Battery history records every minute whichever surface is showing.
        .task { await batteryModel.run() }
        .environment(\.graphFrameRate, vitalsModel.graphFrameRate)
    }

    /// The process table's rows as filtered and sorted now. Built here so the toolbar acts
    /// on exactly the rows `ProcessesView` shows.
    private var sections: [ProcessTableSection] {
        ProcessTableSection.make(rows: model.rows,
                                 searchText: searchText,
                                 filter: ProcessFilter(preset: filterPreset, hidesSystem: hidesSystemProcesses),
                                 sortOrder: sortOrder)
    }

    /// The selection as Quit / Force Quit would act on it: visible rows only.
    private var selectionBatch: ProcessBatch {
        ProcessBatch.make(pids: model.selectedPIDs, visibleRows: sections.flatMap(\.rows))
    }

    /// Quit / Force Quit act only on the Processes surface, where the selection is visible.
    private var canTerminateSelection: Bool {
        surface == .processes && !selectionBatch.targets.isEmpty
    }

    /// Quit and Force Quit both confirm, so the toolbar only ever stages a request.
    private func processRequest(_ signal: ProcessSignal) -> PendingTermination? {
        guard surface == .processes else { return nil }
        return PendingTermination.request(for: selectionBatch, signal: signal)
    }

    private func meterValue(_ surface: Surface) -> String {
        guard let vitals = vitalsModel.vitals else { return "—" }
        switch surface {
        case .cpu:     return vitals.cpuText
        case .gpu:     return vitals.gpuText
        case .memory:  return vitals.memoryText
        case .network: return vitals.networkText
        case .disk:    return vitals.diskText
        case .thermal: return ThermalReading.text(vitalsModel.thermal?.headline)
        case .energy:  return PowerReading.text(vitalsModel.power?.systemWatts)
        case .battery: return vitals.battery?.displayText ?? "—"
        case .summary, .processes, .ports: return ""
        }
    }

    private func meterFraction(_ surface: Surface) -> Double {
        guard let vitals = vitalsModel.vitals else { return 0 }
        switch surface {
        case .cpu:
            return vitals.cpuUsagePercent / 100
        case .gpu:
            return (vitals.gpu?.utilizationPercent ?? 0) / 100
        case .memory:
            return vitals.totalMemoryBytes > 0
                ? Double(vitals.usedMemoryBytes) / Double(vitals.totalMemoryBytes)
                : 0
        case .network:
            let range = MetricScale.autoscaled([vitalsModel.history.networkIn,
                                                vitalsModel.history.networkOut])
            return range.upperBound > 0
                ? vitals.networkInBytesPerSec / range.upperBound
                : 0
        case .disk:
            let range = MetricScale.autoscaled([vitalsModel.history.diskRead,
                                                vitalsModel.history.diskWrite])
            return range.upperBound > 0
                ? (vitals.diskReadBytesPerSec + vitals.diskWriteBytesPerSec) / range.upperBound
                : 0
        case .thermal:
            return ThermalPanel.meterFraction(vitalsModel.thermal?.headline)
        case .energy:
            return EnergyPanel.meterFraction(vitalsModel.power?.systemWatts, history: vitalsModel.powerHistory)
        case .battery:
            return Double(vitals.battery?.chargePercent ?? 0) / 100
        case .summary, .processes, .ports:
            return 0
        }
    }
}

#Preview {
    ContentView(vitalsModel: VitalsModel())
}
