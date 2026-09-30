import CoreGraphics
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

struct MeterBarSegmentTests {
    @Test func thereAreTwentyFivePercentSegments() {
        #expect(MeterBar.segmentCount == 20)
    }

    @Test func zeroLightsNothingAndFullLightsEverything() {
        #expect(MeterBar.litSegments(fraction: 0) == 0)
        #expect(MeterBar.litSegments(fraction: 1) == 20)
    }

    /// Round-up: any activity at all shows, so an idle-ish CPU never reads as empty.
    @Test func anyNonZeroReadingLightsAtLeastOneSegment() {
        #expect(MeterBar.litSegments(fraction: 0.001) == 1)
        #expect(MeterBar.litSegments(fraction: 0.999) == 20)
        #expect(MeterBar.litSegments(fraction: 0.051) == 2)
    }

    /// Meter fractions are computed (CPU% / 100, used / total), so they carry
    /// floating-point noise: 3 * 0.05 is 0.15000000000000002, and times 20 that is
    /// 3.0000000000000004. A bare round-up would light 4 segments for a true 15%.
    @Test func arithmeticNoiseDoesNotSpillIntoTheNextSegment() {
        #expect(MeterBar.litSegments(fraction: 3 * 0.05) == 3)
        #expect(MeterBar.litSegments(fraction: 7 * 0.05) == 7)
        #expect(MeterBar.litSegments(fraction: 14 * 0.05) == 14)
        #expect(MeterBar.litSegments(fraction: 0.05) == 1)     // exact boundaries too
        #expect(MeterBar.litSegments(fraction: 0.7) == 14)
    }

    @Test func invalidReadingsAreClamped() {
        #expect(MeterBar.litSegments(fraction: -0.5) == 0)
        #expect(MeterBar.litSegments(fraction: 1.5) == 20)
        #expect(MeterBar.litSegments(fraction: .nan) == 0)
        #expect(MeterBar.litSegments(fraction: .infinity) == 0)
    }

    // 20 segments + 19 one-point gaps in 119pt → exactly 5pt per segment.
    @Test func verticalSegmentsStackUpwardFromTheBottom() {
        let rects = MeterBar.segmentRects(in: CGSize(width: 14, height: 119), orientation: .vertical)
        #expect(rects.count == 20)
        #expect(rects[0] == CGRect(x: 0, y: 114, width: 14, height: 5))    // bottom lights first
        #expect(rects[1] == CGRect(x: 0, y: 108, width: 14, height: 5))
        #expect(rects[19] == CGRect(x: 0, y: 0, width: 14, height: 5))
    }

    @Test func horizontalSegmentsRunLeftToRight() {
        let rects = MeterBar.segmentRects(in: CGSize(width: 119, height: 3), orientation: .horizontal)
        #expect(rects.count == 20)
        #expect(rects[0] == CGRect(x: 0, y: 0, width: 5, height: 3))       // left lights first
        #expect(rects[1] == CGRect(x: 6, y: 0, width: 5, height: 3))
        #expect(rects[19] == CGRect(x: 114, y: 0, width: 5, height: 3))
    }

    @Test func segmentsNeverOverlapAtAnAwkwardSize() {
        let rects = MeterBar.segmentRects(in: CGSize(width: 157.5, height: 4), orientation: .horizontal)
        for (a, b) in zip(rects, rects.dropFirst()) {
            #expect(a.maxX < b.minX, "\(a) overlaps \(b)")
        }
        #expect(abs(rects[19].maxX - 157.5) < 0.0001)
    }

    /// Smaller than the gaps themselves: must not produce negative-size rects.
    @Test func tinySizesYieldNoSegments() {
        #expect(MeterBar.segmentRects(in: CGSize(width: 10, height: 3), orientation: .horizontal).isEmpty)
        #expect(MeterBar.segmentRects(in: .zero, orientation: .vertical).isEmpty)
    }
}
