import Testing
@testable import macOSmonitor

struct MetricScaleTests {
    @Test func fixedRangeStartsAtZeroAndUsesUpperBound() {
        let range = MetricScale.fixed(100)
        #expect(range.lowerBound == 0)
        #expect(range.upperBound == 100)
    }

    @Test func fixedRangeNeverCollapsesToZeroWidth() {
        let range = MetricScale.fixed(0)
        #expect(range.upperBound > range.lowerBound)
    }

    @Test func autoscaleTracksWindowPeakWhenAboveFloor() {
        var series = MetricHistory(capacity: 60)
        series.append(500_000)
        series.append(2_000_000)
        series.append(1_000_000)
        let range = MetricScale.autoscaled([series])
        #expect(range.upperBound == 2_000_000)
    }

    @Test func autoscaleHoldsFloorWhenIdle() {
        var series = MetricHistory(capacity: 60)
        for _ in 0..<10 { series.append(37) }        // a trickle of noise
        let range = MetricScale.autoscaled([series])
        #expect(range.upperBound == MetricScale.rateFloor)
    }

    @Test func autoscaleSharesOneAxisAcrossSeries() {
        var down = MetricHistory(capacity: 60)
        var up = MetricHistory(capacity: 60)
        down.append(5_000_000)
        up.append(200_000)
        let range = MetricScale.autoscaled([down, up])
        #expect(range.upperBound == 5_000_000)       // the larger series sets the axis
    }

    @Test func autoscaleOnEmptySeriesUsesFloor() {
        let range = MetricScale.autoscaled([MetricHistory(capacity: 60)])
        #expect(range.upperBound == MetricScale.rateFloor)
    }
}
