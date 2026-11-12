import SwiftUI

/// The strip above the process table: a preset picker, the Hide System Processes switch,
/// and the Saved Searches menu. All its state is owned by `ContentView` (see ProcessesView).
struct ProcessFilterBar: View {
    @Binding var preset: ProcessFilter.Preset
    @Binding var hidesSystem: Bool
    @Binding var searchText: String
    @Binding var savedSearches: SavedSearches

    private var filter: ProcessFilter { ProcessFilter(preset: preset, hidesSystem: hidesSystem) }

    private var trimmedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        HStack(spacing: 16) {
            Picker("Show", selection: $preset) {
                ForEach(ProcessFilter.Preset.allCases) { preset in
                    Text(preset.title).tag(preset)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()

            Toggle("Hide System Processes", isOn: $hidesSystem)
                .toggleStyle(.checkbox)
                .disabled(!filter.hidesSystemApplies)
                .help(filter.hideSystemHelp)

            Spacer()

            Menu {
                if savedSearches.queries.isEmpty {
                    Text("No Saved Searches")
                } else {
                    ForEach(savedSearches.queries, id: \.self) { query in
                        Button(query) { searchText = query }
                    }
                }
                Divider()
                Button(trimmedSearch.isEmpty ? "Save Current Search" : "Save Search “\(trimmedSearch)”") {
                    savedSearches.save(searchText)
                }
                .disabled(trimmedSearch.isEmpty || savedSearches.contains(searchText))
                Menu("Remove Saved Search") {
                    ForEach(savedSearches.queries, id: \.self) { query in
                        Button(query) { savedSearches.remove(query) }
                    }
                }
                .disabled(savedSearches.queries.isEmpty)
            } label: {
                Label("Saved Searches", systemImage: "bookmark")
            }
            .fixedSize()
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
