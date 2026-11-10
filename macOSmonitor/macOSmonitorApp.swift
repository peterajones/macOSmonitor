//
//  macOSmonitorApp.swift
//  macOSmonitor
//
//  Created by Peter Jones on 2026-07-02.
//

import SwiftUI

@main
struct macOSmonitorApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            SearchCommands()
            ProcessCommands()
        }
    }
}

/// What the Process menu can do to the focused window's selected process. Both actions
/// only ask for confirmation; the dialog (which names the process and PID) does the rest.
struct ProcessTerminationActions {
    let canTerminate: Bool
    let quit: () -> Void
    let forceQuit: () -> Void
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
/// Activity Monitor. Enabled only on the Processes surface with a process we may signal.
private struct ProcessCommands: Commands {
    @FocusedValue(\.processTermination) private var actions

    var body: some Commands {
        CommandMenu("Process") {
            Button("Quit Process") { actions?.quit() }
                .keyboardShortcut("q", modifiers: [.command, .option])
                .disabled(actions?.canTerminate != true)
            Button("Force Quit Process") { actions?.forceQuit() }
                .keyboardShortcut("q", modifiers: [.command, .option, .shift])
                .disabled(actions?.canTerminate != true)
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
