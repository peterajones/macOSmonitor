//
//  ContentView.swift
//  macOSmonitor
//

import SwiftUI

struct ContentView: View {
    @State private var model = ProcessListModel()
    @State private var vitalsModel = VitalsModel()
    @State private var surface: Surface? = .processes
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

    private var theme: Theme { Theme.named(themeID) }

    var body: some View {
        NavigationSplitView {
            List(selection: $surface) {
                Label(Surface.processes.title, systemImage: "list.bullet")
                    .tag(Surface.processes)
                Section("Performance") {
                    ForEach(Surface.performance) { item in
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
            switch surface ?? .processes {
            case .processes:
                ProcessesView(model: model,
                              vitalsModel: vitalsModel,
                              sortOrder: $sortOrder,
                              showInspector: $showInspector,
                              searchText: $searchText,
                              searchPresented: $searchPresented,
                              pendingTermination: $pendingTermination,
                              errorMessage: $errorMessage)
            case .cpu:
                CPUPanel(model: vitalsModel)
            case .memory:
                MemoryPanel(model: vitalsModel)
            case .network:
                NetworkPanel(model: vitalsModel)
            case .disk:
                DiskPanel(model: vitalsModel)
            }
        }
        .frame(minWidth: 900, minHeight: 500)
        .navigationTitle("macOSmonitor")
        .environment(\.theme, theme)
        .toolbar {
            ToolbarItem {
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
        .task { await vitalsModel.run() }
    }

    private func meterValue(_ surface: Surface) -> String {
        guard let vitals = vitalsModel.vitals else { return "—" }
        switch surface {
        case .cpu:     return vitals.cpuText
        case .memory:  return vitals.memoryText
        case .network: return vitals.networkText
        case .disk:    return vitals.diskText
        case .processes: return ""
        }
    }

    private func meterFraction(_ surface: Surface) -> Double {
        guard let vitals = vitalsModel.vitals else { return 0 }
        switch surface {
        case .cpu:
            return vitals.cpuUsagePercent / 100
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
        case .processes:
            return 0
        }
    }
}

#Preview {
    ContentView()
}
