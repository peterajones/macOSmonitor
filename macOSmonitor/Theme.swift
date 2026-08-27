import SwiftUI

/// A literal colour, kept alongside each fixed theme so contrast can be asserted in tests.
/// SwiftUI's `Color` cannot be decomposed portably.
struct RGB: Equatable, Sendable {
    let r: Double
    let g: Double
    let b: Double

    var color: Color { Color(red: r, green: g, blue: b) }
}

/// WCAG 2.1 relative-luminance contrast.
enum ContrastRatio {
    static func between(_ a: RGB, _ b: RGB) -> Double {
        let lighter = max(luminance(a), luminance(b))
        let darker = min(luminance(a), luminance(b))
        return (lighter + 0.05) / (darker + 0.05)
    }

    private static func luminance(_ rgb: RGB) -> Double {
        0.2126 * channel(rgb.r) + 0.7152 * channel(rgb.g) + 0.0722 * channel(rgb.b)
    }

    private static func channel(_ value: Double) -> Double {
        value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
}

/// A display palette for the Performance surface. The System theme defers to
/// semantic colours (and therefore tracks light/dark); the four VFD themes are
/// fixed dark palettes that deliberately ignore system appearance.
struct Theme: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let graphLine: Color
    let graphFill: Color
    let gridLine: Color
    let panelBackground: Color
    let primaryText: Color
    let secondaryText: Color
    let meterOn: Color
    let meterOff: Color
    let usesSystemColors: Bool
    /// Literal samples for the contrast test; nil for the System theme.
    let textSample: RGB?
    let backgroundSample: RGB?

    static let system = Theme(
        id: "system", name: "System",
        graphLine: .accentColor, graphFill: .accentColor.opacity(0.2),
        gridLine: .gray.opacity(0.3), panelBackground: Color(nsColor: .windowBackgroundColor),
        primaryText: .primary, secondaryText: .secondary,
        meterOn: .accentColor, meterOff: .gray.opacity(0.2),
        usesSystemColors: true, textSample: nil, backgroundSample: nil
    )

    static let vfdGreen = fixed(id: "vfd-green", name: "VFD Green",
                                accent: RGB(r: 0.24, g: 1.00, b: 0.44))
    static let vfdAmber = fixed(id: "vfd-amber", name: "VFD Amber",
                                accent: RGB(r: 1.00, g: 0.75, b: 0.20))
    static let vfdBlue  = fixed(id: "vfd-blue", name: "VFD Blue",
                                accent: RGB(r: 0.42, g: 0.78, b: 1.00))
    static let monochrome = fixed(id: "mono", name: "Monochrome",
                                  accent: RGB(r: 0.88, g: 0.88, b: 0.88))

    static let all: [Theme] = [.system, .vfdGreen, .vfdAmber, .vfdBlue, .monochrome]

    static func named(_ id: String) -> Theme {
        all.first { $0.id == id } ?? .system
    }

    /// Builds a fixed dark VFD palette from one accent colour on near-black.
    private static func fixed(id: String, name: String, accent: RGB) -> Theme {
        let background = RGB(r: 0.04, g: 0.05, b: 0.05)
        return Theme(
            id: id, name: name,
            graphLine: accent.color,
            graphFill: accent.color.opacity(0.18),
            // Deliberately brighter than graphFill: the grid is drawn first and the
            // fill paints over it, so an equal opacity makes the grid vanish under
            // the trace and show only against bare background.
            gridLine: accent.color.opacity(0.30),
            panelBackground: background.color,
            primaryText: accent.color,
            secondaryText: accent.color.opacity(0.65),
            meterOn: accent.color,
            meterOff: accent.color.opacity(0.12),
            usesSystemColors: false,
            textSample: accent,
            backgroundSample: background
        )
    }
}
