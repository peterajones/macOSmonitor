import Testing
@testable import macOSmonitor

struct MeterBarTests {
    @Test func passesThroughValuesInRange() {
        #expect(MeterBar.clampedFraction(0) == 0)
        #expect(MeterBar.clampedFraction(0.5) == 0.5)
        #expect(MeterBar.clampedFraction(1) == 1)
    }

    @Test func clampsOutOfRangeValues() {
        #expect(MeterBar.clampedFraction(-0.5) == 0)
        #expect(MeterBar.clampedFraction(1.5) == 1)
    }

    /// A non-finite fraction would otherwise produce a NaN frame height, which
    /// SwiftUI renders as a blank view with no error.
    @Test func mapsNonFiniteValuesToZero() {
        #expect(MeterBar.clampedFraction(.nan) == 0)
        #expect(MeterBar.clampedFraction(.infinity) == 0)
        #expect(MeterBar.clampedFraction(-.infinity) == 0)
    }
}
