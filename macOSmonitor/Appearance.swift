import SwiftUI

/// The glow under graph lines and around lit meter segments, from the Colours popover's
/// Bloom slider (0–10). Level 5 is the original look; 0 turns the glow off, which also
/// spares the blur pass.
struct Bloom: Equatable, Sendable {
    static let storageKey = "bloom"
    static let defaultLevel = 5.0
    static let levels = 0.0...10.0

    let graphRadius: Double
    let graphOpacity: Double
    let meterRadius: Double
    let meterOpacity: Double

    var isOff: Bool { graphRadius == 0 }

    /// The halo spreads in proportion to the level; its opacity grows with it but levels
    /// off, so a high setting widens the glow rather than painting over the line.
    nonisolated init(level: Double) {
        let strength = min(max(level, Self.levels.lowerBound), Self.levels.upperBound) / Self.defaultLevel
        graphRadius = 3 * strength
        graphOpacity = min(0.6 * strength, 0.9)
        meterRadius = 2.5 * strength
        meterOpacity = min(0.9 * strength, 1)
    }
}

/// The Colours popover's Saturation slider (0–10): 10 is full colour, 0 is greyscale.
enum SaturationLevel {
    static let storageKey = "saturation"
    static let defaultLevel = 10.0

    /// The amount for SwiftUI's `saturation(_:)` modifier, 0...1.
    nonisolated static func amount(_ level: Double) -> Double {
        min(max(level, 0), 10) / 10
    }
}

extension EnvironmentValues {
    @Entry var bloom = Bloom(level: Bloom.defaultLevel)
}
