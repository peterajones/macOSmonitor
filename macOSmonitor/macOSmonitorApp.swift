//
//  macOSmonitorApp.swift
//  macOSmonitor
//
//  Created by Peter Jones on 2026-07-02.
//

import SwiftUI

@main
struct macOSmonitorApp: App {
    static let mainWindowID = "main"
    static let helperWindowID = "helper"

    /// System vitals are the same for every window and the menu bar, so one model samples
    /// them for the whole app. Its loop starts here, once, rather than in a view's `.task`,
    /// because the menu-bar label needs it whether or not any window is open.
    @State private var vitalsModel: VitalsModel
    @AppStorage(MenuBarSettings.key) private var showsMenuBarExtra = MenuBarSettings.shownByDefault

    init() {
        let model = VitalsModel()
        _vitalsModel = State(initialValue: model)
        Task { await model.run() }
        Task { await model.runThermal() }
    }

    var body: some Scene {
        WindowGroup(id: Self.mainWindowID) {
            ContentView(vitalsModel: vitalsModel)
        }
        .commands {
            SearchCommands()
            ProcessCommands()
            CPUTimeFormatCommands()
            MenuBarCommands(showsMenuBarExtra: $showsMenuBarExtra)
            HelperCommands()
        }

        Settings {
            SettingsView()
        }

        Window("Privileged Helper", id: Self.helperWindowID) {
            PrivilegedHelperView()
        }
        .windowResizability(.contentSize)

        MenuBarExtra(isInserted: $showsMenuBarExtra) {
            MenuBarPanel(vitalsModel: vitalsModel)
        } label: {
            MenuBarLabel(vitalsModel: vitalsModel)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Where the menu-bar item's on/off choice is stored. Named so tests can pin the key and the
/// default: renaming the key would silently reset everyone's choice.
enum MenuBarSettings {
    static let key = "showMenuBarExtra"
    static let shownByDefault = true
    /// The View menu item that toggles it.
    static let menuTitle = "Show in Menu Bar"
}

/// macOSmonitor ▸ Privileged Helper…, after About.
private struct HelperCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Privileged Helper…") { openWindow(id: macOSmonitorApp.helperWindowID) }
        }
    }
}

/// View ▸ Show in Menu Bar.
private struct MenuBarCommands: Commands {
    @Binding var showsMenuBarExtra: Bool

    var body: some Commands {
        CommandGroup(before: .toolbar) {
            Toggle(MenuBarSettings.menuTitle, isOn: $showsMenuBarExtra)
        }
    }
}

/// What the Process menu can do to the focused window's selected process. `request` asks
/// for confirmation (the dialog names the process and PID) for every signal but Resume.
struct ProcessTerminationActions {
    let canTerminate: Bool
    let request: (ProcessSignal) -> Void
}

private struct ProcessTerminationKey: FocusedValueKey {
    typealias Value = ProcessTerminationActions
}

extension FocusedValues {
    var processTermination: ProcessTerminationActions? {
        get { self[ProcessTerminationKey.self] }
        set { self[ProcessTerminationKey.self] = newValue }
    }
}

/// A Process menu with Quit Process (⌥⌘Q) and Force Quit Process (⇧⌥⌘Q), matching
/// Activity Monitor, plus a Send Signal submenu (Pause, Resume, Hang Up). Enabled only on
/// the Processes surface with a process we may signal.
private struct ProcessCommands: Commands {
    @FocusedValue(\.processTermination) private var actions

    var body: some Commands {
        CommandMenu("Process") {
            Button("Quit Process") { actions?.request(.terminate) }
                .keyboardShortcut("q", modifiers: [.command, .option])
                .disabled(actions?.canTerminate != true)
            Button("Force Quit Process") { actions?.request(.kill) }
                .keyboardShortcut("q", modifiers: [.command, .option, .shift])
                .disabled(actions?.canTerminate != true)
            Divider()
            Menu("Send Signal") {
                ForEach(ProcessSignal.sendSignalMenu, id: \.self) { signal in
                    Button(signal.menuTitle) { actions?.request(signal) }
                }
            }
            .disabled(actions?.canTerminate != true)
        }
    }
}

/// View ▸ CPU Time Format: how the process table and inspector write CPU time. Stored in
/// @AppStorage, so every window follows the choice and it survives relaunches.
private struct CPUTimeFormatCommands: Commands {
    @AppStorage(CPUTimeFormat.storageKey) private var format: CPUTimeFormat = .adaptive

    var body: some Commands {
        CommandGroup(before: .toolbar) {
            Picker("CPU Time Format", selection: $format) {
                ForEach(CPUTimeFormat.allCases) { format in
                    Text(format.title).tag(format)
                }
            }
            Divider()
        }
    }
}

/// Exposes the focused window's search-field presentation binding to menu commands,
/// so a scene-level Find command can activate the search field in the active window.
private struct SearchPresentedKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

extension FocusedValues {
    var searchPresented: Binding<Bool>? {
        get { self[SearchPresentedKey.self] }
        set { self[SearchPresentedKey.self] = newValue }
    }
}

/// Adds a Find (⌘F) menu command that focuses the process table's search field.
/// Enabled only when a window exposing `searchPresented` is focused.
private struct SearchCommands: Commands {
    @FocusedValue(\.searchPresented) private var searchPresented

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button("Find") { searchPresented?.wrappedValue = true }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(searchPresented == nil)
        }
    }
}
