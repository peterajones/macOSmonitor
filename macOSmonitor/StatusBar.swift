import SwiftUI
import Darwin

/// The Mac's main IPv4 address, for the status bar.
enum PrimaryAddress {
    /// The built-in interface (en0) first, then any other en* interface, then anything else
    /// routable. Loopback and self-assigned (169.254.x.x, what macOS uses when DHCP fails)
    /// addresses don't count.
    nonisolated static func pick(_ candidates: [(interface: String, address: String)]) -> String? {
        let usable = candidates.filter { !$0.interface.hasPrefix("lo") && !$0.address.hasPrefix("169.254.") }
        return (usable.first { $0.interface == "en0" }
                ?? usable.first { $0.interface.hasPrefix("en") }
                ?? usable.first)?.address
    }

    /// Every up interface's IPv4 address, from `getifaddrs` (public, works in the sandbox).
    nonisolated static func read() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let head else { return nil }
        defer { freeifaddrs(head) }
        var candidates: [(interface: String, address: String)] = []
        for entry in sequence(first: head, next: { $0.pointee.ifa_next }) {
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0,
                  let sockaddr = entry.pointee.ifa_addr, sockaddr.pointee.sa_family == UInt8(AF_INET)
            else { continue }
            let address = sockaddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            guard let text = ProcInfo.ipv4(address) else { continue }
            candidates.append((String(cString: entry.pointee.ifa_name), text))
        }
        return pick(candidates)
    }
}

/// The privileged helper's state in a few words, with a tone for its dot.
struct HelperSummary: Equatable {
    enum Tone: Equatable { case good, warning, bad, neutral }

    let text: String
    let tone: Tone

    nonisolated init(_ state: PrivilegedHelperModel.State) {
        switch state {
        case .running(let version?) where version == HelperConstants.protocolVersion:
            (text, tone) = ("Helper running", .good)
        case .running(_?):
            (text, tone) = ("Helper out of date", .warning)
        case .running(nil):
            (text, tone) = ("Helper not answering", .bad)
        case .needsApproval:
            (text, tone) = ("Helper waiting for approval", .warning)
        case .notInstalled, .notFound:
            (text, tone) = ("Helper not installed", .neutral)
        }
    }
}

/// The strip along the bottom of the window: helper state (click for the Privileged Helper
/// window), process count, IP address and uptime. Lives outside the detail `switch`, so its
/// state survives surface changes.
struct StatusBarView: View {
    let processCount: Int
    let uptime: String?

    @State private var helper = PrivilegedHelperModel()
    @State private var address: String?
    @Environment(\.theme) private var theme
    @Environment(\.openWindow) private var openWindow

    nonisolated static func processCountText(_ count: Int) -> String {
        switch count {
        case 0: "Sampling…"
        case 1: "1 process"
        default: "\(count) processes"
        }
    }

    var body: some View {
        let summary = HelperSummary(helper.state)
        HStack(spacing: 10) {
            Button { openWindow(id: macOSmonitorApp.helperWindowID) } label: {
                HStack(spacing: 5) {
                    Circle().fill(color(for: summary.tone)).frame(width: 7, height: 7)
                    Text(summary.text)
                }
            }
            .buttonStyle(.plain)
            .help("Privileged Helper…")
            separator
            Text(Self.processCountText(processCount))
            separator
            Text("IP \(address ?? "—")")
            separator
            Text("Up \(uptime ?? "—")")
            Spacer(minLength: 0)
        }
        .font(.caption)
        .monospacedDigit()
        .lineLimit(1)
        .foregroundStyle(theme.secondaryText)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(theme.panelBackground)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.secondaryText.opacity(0.25)).frame(height: 1)
        }
        // The address and the helper change rarely: every 5 s is plenty.
        .task {
            while !Task.isCancelled {
                address = PrimaryAddress.read()
                await helper.refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private var separator: some View {
        Rectangle().fill(theme.secondaryText.opacity(0.3)).frame(width: 1, height: 12)
    }

    /// Traffic-light colours, except in the monochrome VFD palettes: there a running helper
    /// is bright and anything else dim.
    private func color(for tone: HelperSummary.Tone) -> Color {
        guard theme.usesSystemColors else {
            return tone == .good ? theme.primaryText : theme.secondaryText.opacity(0.5)
        }
        switch tone {
        case .good: return .green
        case .warning: return .orange
        case .bad: return .red
        case .neutral: return .gray
        }
    }
}
