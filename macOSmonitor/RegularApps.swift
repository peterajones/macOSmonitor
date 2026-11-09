import AppKit
import Darwin

/// Reports which running processes are regular apps, the ones that get a Dock icon.
/// Behind a protocol so `ProcessSampler` can be tested without the real workspace.
protocol RegularAppProviding: Sendable {
    func regularAppPIDs() -> Set<pid_t>
}

struct RegularApps: RegularAppProviding {
    func regularAppPIDs() -> Set<pid_t> {
        Set(NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .map(\.processIdentifier))
    }
}
