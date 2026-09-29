import Testing
@testable import macOSmonitor

struct ThemeTests {
    @Test func thereAreFiveThemesWithDistinctIDs() {
        #expect(Theme.all.count == 5)
        #expect(Set(Theme.all.map(\.id)).count == 5)
    }

    @Test func namedFallsBackToSystemForUnknownIDs() {
        #expect(Theme.named("vfd-green").id == Theme.vfdGreen.id)
        #expect(Theme.named("nonsense").id == Theme.system.id)
    }

    @Test func contrastRatioMatchesKnownValues() {
        let white = RGB(r: 1, g: 1, b: 1)
        let black = RGB(r: 0, g: 0, b: 0)
        #expect(abs(ContrastRatio.between(white, black) - 21.0) < 0.01)
        #expect(abs(ContrastRatio.between(white, white) - 1.0) < 0.01)
    }

    /// White/black is degenerate: both luminances are exact 0 or 1, so a wrong gamma
    /// curve or swapped channel weights still yield 21:1. These fixtures are not.
    @Test func contrastRatioMatchesMidrangeReferenceValues() {
        let white = RGB(r: 1, g: 1, b: 1)
        let black = RGB(r: 0, g: 0, b: 0)
        // #767676 and #777777 straddle the 4.5:1 AA threshold on white.
        let grey76 = RGB(r: 118 / 255, g: 118 / 255, b: 118 / 255)
        let grey77 = RGB(r: 119 / 255, g: 119 / 255, b: 119 / 255)
        #expect(abs(ContrastRatio.between(grey76, white) - 4.54) < 0.01)
        #expect(abs(ContrastRatio.between(grey77, white) - 4.48) < 0.01)
        // Single-channel colours pin each weight: red 0.2126, green 0.7152.
        #expect(abs(ContrastRatio.between(RGB(r: 1, g: 0, b: 0), white) - 4.00) < 0.01)
        #expect(abs(ContrastRatio.between(RGB(r: 0, g: 1, b: 0), black) - 15.30) < 0.01)
    }

    @Test func everyFixedThemeMeetsWCAGAAForBodyText() {
        for theme in Theme.all where !theme.usesSystemColors {
            guard let text = theme.textSample, let background = theme.backgroundSample else {
                Issue.record("\(theme.id) is a fixed theme but has no colour samples")
                continue
            }
            let ratio = ContrastRatio.between(text, background)
            #expect(ratio >= 4.5, "\(theme.id) text contrast is \(ratio):1, below 4.5:1")
        }
    }

    @Test func systemThemeIsTheOnlyOneUsingSemanticColours() {
        #expect(Theme.system.usesSystemColors)
        #expect(Theme.all.filter(\.usesSystemColors).count == 1)
    }
}
