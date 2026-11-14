import AppKit

/// Where a process's icon comes from: the innermost app bundle its executable lives in, so
/// a helper nested inside an app (Chrome's renderers) shows its own bundle's icon.
enum ProcessIcon {
    /// The innermost path component ending in ".app", or nil for a tool outside any app.
    nonisolated static func bundlePath(forExecutable path: String?) -> String? {
        guard let path else { return nil }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard let last = components.lastIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        return components[...last].joined(separator: "/")
    }
}

/// Bundle icons, looked up once per bundle: the Summary redraws every second and
/// `NSWorkspace.icon(forFile:)` reads from disk.
@MainActor
final class ProcessIconCache {
    static let shared = ProcessIconCache()
    private var icons: [String: NSImage] = [:]

    /// The icon of the app bundle `path` lives in; nil for a tool outside any app.
    func icon(forExecutable path: String?) -> NSImage? {
        guard let bundle = ProcessIcon.bundlePath(forExecutable: path) else { return nil }
        if let icon = icons[bundle] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: bundle)
        icons[bundle] = icon
        return icon
    }
}
