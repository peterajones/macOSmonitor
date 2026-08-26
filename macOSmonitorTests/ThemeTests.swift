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
