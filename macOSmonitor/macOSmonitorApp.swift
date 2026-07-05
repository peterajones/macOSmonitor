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
