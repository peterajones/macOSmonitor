import SwiftUI

/// macOSmonitor ▸ Settings… (⌘,): the app's preferences in one place. Every control writes
/// the same AppStorage key as the menu or popover that also offers it, so they always agree.
struct SettingsView: View {
    @AppStorage("themeID") private var themeID: String = Theme.system.id
    @AppStorage(SaturationLevel.storageKey) private var saturationLevel = SaturationLevel.defaultLevel
    @AppStorage(Bloom.storageKey) private var bloomLevel = Bloom.defaultLevel
    @AppStorage(MenuBarSettings.key) private var showsMenuBarExtra = MenuBarSettings.shownByDefault
    @AppStorage(CPUTimeFormat.storageKey) private var cpuTimeFormat: CPUTimeFormat = .adaptive

    @State private var helper = PrivilegedHelperModel()
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $themeID) {
                    ForEach(Theme.all) { option in
                        Text(option.name).tag(option.id)
                    }
                }
                LabeledContent("Saturation") {
                    Slider(value: $saturationLevel, in: Bloom.levels, step: 1)
                    Text("\(Int(saturationLevel))").monospacedDigit().frame(width: 20, alignment: .trailing)
                }
                LabeledContent("Bloom") {
                    Slider(value: $bloomLevel, in: Bloom.levels, step: 1)
                    Text("\(Int(bloomLevel))").monospacedDigit().frame(width: 20, alignment: .trailing)
                }
            }

            Section("Menu Bar") {
                Toggle(MenuBarSettings.menuTitle, isOn: $showsMenuBarExtra)
            }

            Section("Processes") {
                Picker("CPU time format", selection: $cpuTimeFormat) {
                    ForEach(CPUTimeFormat.allCases) { format in
                        Text(format.title).tag(format)
                    }
                }
            }

            Section("Privileged Helper") {
                LabeledContent("Status", value: HelperSummary(helper.state).text)
                Button("Privileged Helper…") { openWindow(id: macOSmonitorApp.helperWindowID) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .task { await helper.refresh() }
    }
}
