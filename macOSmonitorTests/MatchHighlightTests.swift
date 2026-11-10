import Testing
import Foundation
@testable import macOSmonitor

struct MatchHighlightTests {
    /// Ranges as integer offsets, so expectations read plainly.
    private func offsets(_ query: String, in text: String) -> [Range<Int>] {
        MatchHighlight.ranges(of: query, in: text).map {
            text.distance(from: text.startIndex, to: $0.lowerBound)
                ..< text.distance(from: text.startIndex, to: $0.upperBound)
        }
    }

    @Test func findsEveryOccurrenceCaseInsensitively() {
        // Upper-case query, two occurrences: a first-match-only or case-sensitive
        // implementation gives a visibly different answer.
        #expect(offsets("AF", in: "Safari Safari") == [1..<3, 8..<10])
    }

    @Test func occurrencesDoNotOverlap() {
        #expect(offsets("aa", in: "aaaa") == [0..<2, 2..<4])
        #expect(offsets("aa", in: "aaa") == [0..<2])
    }

    @Test func queryIsTrimmedLikeTheFilter() {
        #expect(offsets("  fari \n", in: "Safari") == [2..<6])
    }

    @Test func emptyOrBlankQueryOrNoMatchHighlightsNothing() {
        #expect(offsets("", in: "Safari").isEmpty)
        #expect(offsets("   ", in: "Safari").isEmpty)
        #expect(offsets("xyz", in: "Safari").isEmpty)
    }

    @Test func matchesInsideAPID() {
        #expect(offsets("23", in: "12323") == [1..<3, 3..<5])
    }

    @Test func attributedStringBoldsOnlyTheMatches() {
        let attributed = MatchHighlight.attributed("Safari", query: "fa")
        let runs = attributed.runs.map {
            (String(attributed[$0.range].characters), $0.inlinePresentationIntent == .stronglyEmphasized)
        }
        #expect(runs.map(\.0) == ["Sa", "fa", "ri"])
        #expect(runs.map(\.1) == [false, true, false])
    }

    @Test func attributedStringWithoutQueryIsPlain() {
        let attributed = MatchHighlight.attributed("Safari", query: "")
        #expect(attributed.runs.count == 1)
        #expect(attributed.runs.first?.inlinePresentationIntent == nil)
    }
}
