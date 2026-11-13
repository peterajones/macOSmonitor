import SwiftUI

/// Installs, approves and removes the root helper, and says what it's for.
struct PrivilegedHelperView: View {
    @State private var model = PrivilegedHelperModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("The privileged helper runs as root so macOSmonitor can show memory and CPU for system processes, and quit or force-quit them. It answers only this app, signed by your team.")
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Image(systemName: statusSymbol).foregroundStyle(statusColor)
                Text(statusText).bold()
            }

            if let error = model.errorMessage {
                Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                switch model.state {
                case .notInstalled, .notFound:
                    Button("Install Helper") { Task { await model.install() } }
                        .keyboardShortcut(.defaultAction)
                case .needsApproval:
                    Button("Open Login Items…") { model.openLoginItems() }
                        .keyboardShortcut(.defaultAction)
                    Button("Remove") { Task { await model.uninstall() } }
                case .running:
                    Button("Remove Helper") { Task { await model.uninstall() } }
                }
                Spacer()
                Button("Check Again") { Task { await model.refresh() } }
            }
        }
        .padding(20)
        .frame(width: 420)
        .task { await model.refresh() }
    }

    private var statusText: String {
        switch model.state {
        case .notInstalled: "Not installed"
        case .needsApproval: "Waiting for approval in System Settings ▸ General ▸ Login Items"
        case .running(let version?) where version == HelperConstants.protocolVersion: "Running"
        case .running(let version?): "Running an older version (\(version)); remove and install again"
        case .running(nil): "Approved, but not answering"
        case .notFound: "Not found in the app bundle (check the build's Copy Files phases)"
        }
    }

    private var statusSymbol: String {
        if case .running(let version?) = model.state, version == HelperConstants.protocolVersion {
            return "checkmark.circle.fill"
        }
        return model.state == .notInstalled ? "circle" : "exclamationmark.triangle.fill"
    }

    private var statusColor: Color {
        if case .running(let version?) = model.state, version == HelperConstants.protocolVersion { return .green }
        return model.state == .notInstalled ? .secondary : .orange
    }
}
