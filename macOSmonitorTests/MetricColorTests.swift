import Testing
import AppKit
@testable import macOSmonitor

@MainActor
struct MetricColorTests {

    /// Resolves the real system window background at a given appearance, so the
    /// contrast assertion measures what actually ships rather than a guessed constant.
    private func windowBackground(_ name: NSAppearance.Name) -> RGB? {
        guard let appearance = NSAppearance(named: name) else { return nil }
        var result: RGB?
        appearance.performAsCurrentDrawingAppearance {
            if let c = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) {
                result = RGB(r: Double(c.redComponent),
                             g: Double(c.greenComponent),
                             b: Double(c.blueComponent))
            }
        }
        return result
    }

    @Test func everyFixedThemeUsesItsAccentForEveryMetric() {
        for theme in Theme.all where !theme.usesSystemColors {
            for metric in Metric.allCases {
                #expect(theme.color(for: metric) == theme.graphLine,
                        "\(theme.name) should be monochrome for \(metric)")
            }
        }
    }

    @Test func systemThemeGivesEveryMetricItsOwnHue() {
        #expect(Theme.systemMetricSamples.count == Metric.allCases.count)
        for metric in Metric.allCases {
            #expect(Theme.systemMetricSamples[metric] != nil, "missing hue for \(metric)")
        }
        // No two metrics may share a hue, or the dashboard's colour coding is a lie.
        let samples = Metric.allCases.compactMap { Theme.systemMetricSamples[$0] }
        for i in samples.indices {
            for j in samples.indices where j > i {
                #expect(samples[i] != samples[j], "hues \(i) and \(j) collide")
            }
        }
    }

    @Test func systemHuesAreLegibleInBothAppearances() {
        guard let light = windowBackground(.aqua),
              let dark = windowBackground(.darkAqua) else {
            Issue.record("could not resolve NSColor.windowBackgroundColor in both appearances")
            return
        }
        for metric in Metric.allCases {
            guard let hue = Theme.systemMetricSamples[metric] else {
                Issue.record("missing hue for \(metric)")
                continue
            }
            // WCAG 2.1 SC 1.4.11 Non-text Contrast: 3:1 for graphical objects.
            #expect(ContrastRatio.between(hue, light) >= 3.0,
                    "\(metric) fails against light background")
            #expect(ContrastRatio.between(hue, dark) >= 3.0,
                    "\(metric) fails against dark background")
        }
    }
}
