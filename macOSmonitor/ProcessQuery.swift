import Foundation

/// A parsed process search. Words are separated by spaces and must all match.
///
/// - A plain word matches the name or PID (case-insensitive substring), as before.
/// - `name:`, `user:` and `path:` match that field (case-insensitive substring); `user:` also
///   matches an exact uid, e.g. `user:501`.
/// - `pid:771` matches that PID exactly, so it finds one process rather than 771, 7712, 1771….
/// - Double quotes keep spaces in a word: `path:"Google Chrome.app"`.
///
/// A field with nothing after the colon is ignored, so typing `pid:` doesn't empty the table
/// before the number is typed. An unknown prefix such as `foo:bar` is a plain word.
struct ProcessQuery: Equatable, Sendable {
    enum Field: String, CaseIterable, Sendable { case name, pid, user, path }

    enum Term: Equatable, Sendable {
        case plain(String)
        case field(Field, String)
    }

    let terms: [Term]

    init(_ text: String) {
        terms = Self.words(in: text).compactMap(Self.term)
    }

    func matches(_ row: ProcessInfoRow) -> Bool {
        terms.allSatisfy { term in
            switch term {
            case .plain(let text):
                Self.contains(row.name, text) || String(row.pid).contains(text)
            case .field(.name, let text):
                Self.contains(row.name, text)
            case .field(.pid, let text):
                Int(text) == Int(row.pid)
            case .field(.user, let text):
                row.user.map { Self.contains($0, text) } == true
                    || row.uid.map { String($0) == text } == true
            case .field(.path, let text):
                row.path.map { Self.contains($0, text) } == true
            }
        }
    }

    /// Words to bold in the Name column: plain words and `name:` values.
    var nameHighlights: [String] {
        terms.compactMap {
            switch $0 {
            case .plain(let text), .field(.name, let text): text
            default: nil
            }
        }
    }

    /// Words to bold in the PID column: plain words, and a `pid:` value only where it is the
    /// whole PID (a substring bolded inside 7712 would suggest `pid:771` matched it).
    func pidHighlights(for pid: pid_t) -> [String] {
        terms.compactMap {
            switch $0 {
            case .plain(let text): text
            case .field(.pid, let text) where Int(text) == Int(pid): String(pid)
            default: nil
            }
        }
    }

    // MARK: Parsing

    private static func contains(_ haystack: String, _ needle: String) -> Bool {
        haystack.range(of: needle, options: .caseInsensitive) != nil
    }

    /// Splits on whitespace outside double quotes, dropping the quotes themselves.
    static func words(in text: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quoted = false
        for character in text {
            if character == "\"" {
                quoted.toggle()
            } else if character.isWhitespace && !quoted {
                if !current.isEmpty { words.append(current); current = "" }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    private static func term(_ word: String) -> Term? {
        if let colon = word.firstIndex(of: ":"),
           let field = Field(rawValue: word[..<colon].lowercased()) {
            let value = String(word[word.index(after: colon)...])
            return value.isEmpty ? nil : .field(field, value)
        }
        return .plain(word)
    }
}
