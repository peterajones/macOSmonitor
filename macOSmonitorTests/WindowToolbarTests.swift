import Testing
import AppKit
@testable import macOSmonitor

/// Reads the real window toolbar of the test host (which is the app). Guards "Customize
/// Toolbar…": it disappeared when the process buttons lived in their own toolbar on
/// ProcessesView, which also lost the user's arrangement on every surface change.
@MainActor
struct WindowToolbarTests {
    private func mainToolbar() async throws -> NSToolbar? {
        for _ in 0..<20 {
            if let toolbar = NSApp.windows.lazy.compactMap(\.toolbar).first,
               !toolbar.items.isEmpty {
                return toolbar
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    @Test func toolbarIsCustomizableAndHoldsEveryButton() async throws {
        let toolbar = try #require(try await mainToolbar())
        // The app's default items, not `toolbar.items`: the test host shares the app's
        // preferences, so `items` reflects whatever the user has customized away.
        let identifiers = try #require(toolbar.delegate?.toolbarDefaultItemIdentifiers?(toolbar))
            .map(\.rawValue)

        #expect(toolbar.allowsUserCustomization, "toolbar items: \(identifiers)")
        // Present on the launch surface (Summary), not only on Processes: a toolbar that
        // changes with the surface is rebuilt and forgets the user's customization.
        for id in ["quit", "forceQuit", "inspector", "theme"] {
            #expect(identifiers.contains { $0 == id || $0.hasSuffix(".\(id)") },
                    "no toolbar item \(id) in \(identifiers)")
        }
    }
}
