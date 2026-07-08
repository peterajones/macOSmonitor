import Testing
@testable import macOSmonitor

struct NetworkStatsTests {
    @Test func countersArePresentAndPositive() {
        let counters = NetworkStats().counters()
        #expect(counters != nil)
        // A real machine has cumulative traffic on at least one non-loopback interface.
        #expect((counters.map { $0.received + $0.sent } ?? 0) > 0)
    }
}
