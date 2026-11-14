import Testing
@testable import macOSmonitor

/// The Colours popover's Bloom and Saturation sliders, 0–10, and what they draw.
struct BloomTests {
    @Test func theDefaultLevelIsTodaysLook() {
        let bloom = Bloom(level: Bloom.defaultLevel)
        #expect(Bloom.defaultLevel == 5)
        #expect(bloom.graphRadius == 3)
        #expect(bloom.graphOpacity == 0.6)
        #expect(bloom.meterRadius == 2.5)
        #expect(bloom.meterOpacity == 0.9)
        #expect(!bloom.isOff)
    }

    @Test func levelZeroTurnsTheGlowOff() {
        let bloom = Bloom(level: 0)
        #expect(bloom.isOff)
        #expect(bloom.graphRadius == 0)
    }

    @Test func strengthScalesWithTheLevel() {
        let bloom = Bloom(level: 2)
        #expect(abs(bloom.graphRadius - 1.2) < 1e-9)
        #expect(abs(bloom.graphOpacity - 0.24) < 1e-9)
        #expect(abs(bloom.meterRadius - 1.0) < 1e-9)
    }

    @Test func opacityLevelsOffWhileTheHaloKeepsSpreading() {
        let bloom = Bloom(level: 10)
        #expect(bloom.graphRadius == 6)
        #expect(bloom.graphOpacity == 0.9)
        #expect(bloom.meterRadius == 5)
        #expect(bloom.meterOpacity == 1)
    }

    @Test func levelsOutsideTheSliderAreClamped() {
        #expect(Bloom(level: -3) == Bloom(level: 0))
        #expect(Bloom(level: 14) == Bloom(level: 10))
    }
}

struct SaturationTests {
    @Test func levelsMapOntoSwiftUIsSaturation() {
        #expect(SaturationLevel.amount(10) == 1)
        #expect(SaturationLevel.amount(7) == 0.7)
        #expect(SaturationLevel.amount(0) == 0)
        #expect(SaturationLevel.defaultLevel == 10)
    }

    @Test func levelsOutsideTheSliderAreClamped() {
        #expect(SaturationLevel.amount(12) == 1)
        #expect(SaturationLevel.amount(-1) == 0)
    }
}
