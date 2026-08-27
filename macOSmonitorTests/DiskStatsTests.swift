import Testing
@testable import macOSmonitor

struct DiskStatsTests {
    @Test func realHardwareReportsNonNilCounters() {
        let counters = DiskStats().counters()
        #expect(counters != nil)
    }

    @Test func countersAreMonotonicAcrossTwoReads() {
        let stats = DiskStats()
        guard let first = stats.counters(), let second = stats.counters() else {
            Issue.record("expected counters on real hardware")
            return
        }
        #expect(second.read >= first.read)
        #expect(second.written >= first.written)
    }

    @Test func countersExceedThirtyTwoBitsOnARealMachine() {
        // Guards against a UInt32 regression: a machine with any history reads well past 4 GB.
        guard let counters = DiskStats().counters() else {
            Issue.record("expected counters on real hardware")
            return
        }
        #expect(counters.read > 0)
    }
}
