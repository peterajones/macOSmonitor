//
//  ContentView.swift
//  macOSmonitor
//

import SwiftUI

struct ContentView: View {
    @State private var model = ProcessListModel()
    @State private var vitalsModel = VitalsModel()
    @State private var surface: Surface? = .processes

    var body: some View {
        NavigationSplitView {
            List(selection: $surface) {
                Label(Surface.processes.title, systemImage: "list.bullet")
                    .tag(Surface.processes)
                Section("Performance") {
                    ForEach(Surface.performance) { item in
                        Text(item.title).tag(item)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            switch surface ?? .processes {
            case .processes:
                ProcessesView(model: model, vitalsModel: vitalsModel)
            case .cpu:
                CPUPanel(model: vitalsModel)
            case .memory, .network, .disk:
                Text("Panel coming in the next task")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 900, minHeight: 500)
        .navigationTitle("macOSmonitor")
        .task { await vitalsModel.run() }
    }
}

#Preview {
    ContentView()
}
