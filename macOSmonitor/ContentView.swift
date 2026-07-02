//
//  ContentView.swift
//  macOSmonitor
//
//  Created by Peter Jones on 2026-07-02.
//

import SwiftUI

struct ContentView: View {
    @State private var model = ProcessListModel()
    @State private var sortOrder = [KeyPathComparator(\ProcessInfoRow.cpuSortKey, order: .reverse)]

    var body: some View {
        Table(model.rows.sorted(using: sortOrder), sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name)
            TableColumn("PID", value: \.pid) { row in
                Text(String(row.pid))
            }
            TableColumn("CPU %", value: \.cpuSortKey) { row in
                Text(row.cpuPercent.map { String(format: "%.1f", $0) } ?? "—")
                    .monospacedDigit()
            }
            TableColumn("Memory", value: \.memSortKey) { row in
                Text(row.memoryBytes.map {
                    ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .memory)
                } ?? "—")
                .monospacedDigit()
            }
        }
        .frame(minWidth: 520, minHeight: 360)
        .navigationTitle("macOSmonitor")
        .task { await model.run() }   // SwiftUI cancels this loop when the view goes away
    }
}

#Preview {
    ContentView()
}
