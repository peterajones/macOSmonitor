import Foundation

/// Marks where a search query matches inside a table cell's text, so the process table can
/// bold the matched letters. Uses the same trimming and case-insensitive comparison as
/// `ProcessInfoRow.matches(_:)`, so what is bolded is what made the row match.
enum MatchHighlight {
    /// Every non-overlapping, case-insensitive occurrence of the trimmed `query` in `text`.
    /// Empty when the query is blank or does not occur.
    static func ranges(of query: String, in text: String) -> [Range<String.Index>] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var result: [Range<String.Index>] = []
        var searchStart = text.startIndex
        while let found = text.range(of: trimmed, options: .caseInsensitive,
                                     range: searchStart..<text.endIndex) {
            result.append(found)
            searchStart = found.upperBound
        }
        return result
    }

    /// `text` with each match marked strongly emphasized, which `Text` renders bold.
    /// Bold rather than a background colour, so it stays legible in a selected row.
    static func attributed(_ text: String, query: String) -> AttributedString {
        var attributed = AttributedString(text)
        for range in ranges(of: query, in: text) {
            if let attributedRange = Range(range, in: attributed) {
                attributed[attributedRange].inlinePresentationIntent = .stronglyEmphasized
            }
        }
        return attributed
    }
}
