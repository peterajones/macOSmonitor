import Testing
import AppKit
@testable import macOSmonitor

/// Reads the real main menu of the test host (which is the app) to guard the Process menu's
/// shortcuts. When a command's shortcut clashes with an existing one (e.g. ⌘Q), SwiftUI
/// silently strips it from the command rather than listing it twice, so a clash shows up
/// here as a missing shortcut. Checked on 2026-11-10 by giving Quit Process plain ⌘Q.
@MainActor
struct MenuShortcutTests {
    private struct Shortcut: Equatable {
        let key: String
        let modifiers: NSEvent.ModifierFlags.RawValue
    }

    /// Every menu item with a key equivalent, by title.
    private func menuShortcuts() async throws -> [(title: String, shortcut: Shortcut)] {
        // SwiftUI builds the main menu shortly after launch.
        for _ in 0..<20 where NSApp.mainMenu?.items.contains(where: { $0.title == "Process" }) != true {
            try await Task.sleep(for: .milliseconds(100))
        }
        var result: [(String, Shortcut)] = []
        func walk(_ menu: NSMenu) {
            for item in menu.items {
                if !item.keyEquivalent.isEmpty {
                    let modifiers = item.keyEquivalentModifierMask
                        .intersection(.deviceIndependentFlagsMask).rawValue
                    result.append((item.title, Shortcut(key: item.keyEquivalent.lowercased(),
                                                        modifiers: modifiers)))
                }
                if let submenu = item.submenu { walk(submenu) }
            }
        }
        if let main = NSApp.mainMenu { walk(main) }
        return result
    }

    @Test func processMenuHasQuitAndForceQuitShortcuts() async throws {
        let shortcuts = try await menuShortcuts()
        let byTitle = Dictionary(shortcuts.map { ($0.title, $0.shortcut) }, uniquingKeysWith: { a, _ in a })
        #expect(byTitle["Quit Process"] == Shortcut(key: "q", modifiers: NSEvent.ModifierFlags([.command, .option]).rawValue))
        #expect(byTitle["Force Quit Process"] == Shortcut(key: "q", modifiers: NSEvent.ModifierFlags([.command, .option, .shift]).rawValue))
    }
}
