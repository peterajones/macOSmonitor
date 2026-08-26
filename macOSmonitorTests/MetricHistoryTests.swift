import Testing
@testable import macOSmonitor

struct MetricHistoryTests {
    @Test func emptyHistoryHasNoValues() {
        let history = MetricHistory(capacity: 60)
        #expect(history.values.isEmpty)
        #expect(history.isEmpty)
        #expect(history.latest == nil)
        #expect(history.peak == 0)
    }

    @Test func valuesAreOldestToNewest() {
        var history = MetricHistory(capacity: 60)
        history.append(1)
        history.append(2)
        history.append(3)
        #expect(history.values == [1, 2, 3])
        #expect(history.latest == 3)
    }

    @Test func appendingBeyondCapacityEvictsOldest() {
        var history = MetricHistory(capacity: 3)
        for value in 1...5 { history.append(Double(value)) }
        #expect(history.values == [3, 4, 5])
        #expect(history.values.count == 3)
    }

    @Test func peakIsMaxOfWindowNotOfAllTime() {
        var history = MetricHistory(capacity: 3)
        history.append(100)              // will be evicted
        for value in [1.0, 2.0, 3.0] { history.append(value) }
        #expect(history.peak == 3)
    }

    @Test func capacityIsAtLeastOne() {
        var history = MetricHistory(capacity: 0)
        history.append(7)
        #expect(history.values == [7])
    }
}
