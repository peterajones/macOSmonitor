import SwiftUI

/// How often the gliding graphs redraw. Every graph on screen animates, so this is a real
/// CPU cost: benchmarked 2026-11-14 on an M3 Pro, a 12-core CPU panel took ~12% of a core at
/// 15 fps, ~18% at 30 and ~27% at 60. Peter chose 30, halved on battery or in Low Power Mode.
enum GraphFrameRate {
    static let normal = 30.0
    static let saving = 15.0

    /// Half rate when the Mac is running on its battery or Low Power Mode is on.
    nonisolated static func rate(for vitals: SystemVitals?) -> Double {
        guard let vitals else { return normal }
        return vitals.lowPowerMode || vitals.battery?.state == .discharging ? saving : normal
    }
}

extension EnvironmentValues {
    /// Frames per second for `MetricGraph`'s glide; set once per scene from `VitalsModel`.
    @Entry var graphFrameRate: Double = GraphFrameRate.normal
}
