import Testing
import CoreGraphics
@testable import macOSmonitor

/// The Summary's process table fits the space it's given: as many rows as fit (up to its
/// limit), and the Memory column only when the card is wide enough for it.
struct TopProcessesLayoutTests {
    @Test func rowsFillTheHeightWholeRowsOnly() {
        // 19 pt per row: 100 pt holds 5 whole rows, not 5.26 rounded or 6.
        #expect(TopProcessesCard.layout(for: CGSize(width: 320, height: 100), limit: 12).rows == 5)
    }

    @Test func rowsStopAtTheLimit() {
        #expect(TopProcessesCard.layout(for: CGSize(width: 320, height: 1_000), limit: 12).rows == 12)
    }

    @Test func noRoomMeansNoRows() {
        #expect(TopProcessesCard.layout(for: CGSize(width: 320, height: 10), limit: 12).rows == 0)
        #expect(TopProcessesCard.layout(for: CGSize(width: 320, height: -5), limit: 12).rows == 0)
    }

    @Test func memoryColumnNeedsTheWidth() {
        #expect(TopProcessesCard.layout(for: CGSize(width: 280, height: 100), limit: 12).showsMemory)
        #expect(!TopProcessesCard.layout(for: CGSize(width: 279, height: 100), limit: 12).showsMemory)
    }
}
