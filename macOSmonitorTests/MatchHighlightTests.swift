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

/// Review-harness follow-up: highlighting driven by a parsed search, end to end from the
/// search text to the bold runs a table cell shows.
struct FieldQueryHighlightTests {
    private func bold(_ text: String, _ terms: [String]) -> [String] {
        let attributed = MatchHighlight.attributed(text, terms: terms)
        return attributed.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }
            .map { String(attributed[$0.range].characters) }
    }

    /// A quoted phrase bolds as one run, space included; unquoted, the words bold separately.
    @Test func quotedPhraseBoldsAsOneRun() {
        let quoted = ProcessQuery(#""google chrome""#)
        #expect(bold("Google Chrome Helper", quoted.nameHighlights) == ["Google Chrome"])
        let words = ProcessQuery("google chrome")
        #expect(bold("Google Chrome Helper", words.nameHighlights) == ["Google", "Chrome"])
    }

    @Test func nameFieldBoldsInTheNameColumnOnly() {
        let query = ProcessQuery("name:chrome")
        #expect(bold("Google Chrome", query.nameHighlights) == ["Chrome"])
        #expect(query.pidHighlights(for: 771).isEmpty)
    }

    /// user: and path: match fields the table doesn't show, so they bold nothing; the row is
    /// there because of them, not because of its name.
    @Test func userAndPathBoldNothingInTheTable() {
        let query = ProcessQuery(#"user:root path:"/System/Library""#)
        #expect(query.nameHighlights.isEmpty)
        #expect(query.pidHighlights(for: 1).isEmpty)
    }

    @Test func pidFieldBoldsTheWholePIDOnlyWhenItIsThatProcess() {
        let query = ProcessQuery("pid:771")
        #expect(bold("771", query.pidHighlights(for: 771)) == ["771"])
        #expect(bold("7712", query.pidHighlights(for: 7712)).isEmpty)
    }
}
