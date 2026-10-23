import Foundation

/// Words every result of a search must have, typed in its query: `+beach`, `+"golden retriever"` (Jon, 2026-10-22: "Is
/// there a way to make the word "beach" absolutely required"; approved as proposed). A result is kept only if, for each
/// of them, its words have it (keyword search's own matching: Photos' words, names, text read in pictures, pages and
/// documents, what's said in recordings) or it matches it by meaning on its own, at the bar a search calls a meaning
/// match (`Searcher.search`). The results are ranked by the whole query, the marks taken out.
///
/// `+` counts only at the start of a word and before a letter or a quote, so `c++`, `+1 555 0100` and a lone `+` stay
/// ordinary text; so does all of a search of code (`CodeQuery`), where `+` is literal. A phrase's quote may be left
/// open: it runs to the end of the query. The marks are kept in the query as it's typed, so a saved search keeps them
/// in its query and an AI app sends them in its own: there's nothing else to store.
public struct RequiredWords: Sendable, Equatable {
    /// The query with its marks taken out (`+beach` → `beach`, `+"a phrase"` → `a phrase`): what's embedded and matched.
    public let text: String
    /// Each required word or phrase, as typed, in order and once (a later `+Beach` adds nothing to `+beach`).
    public let terms: [String]
    /// The term whose mark ends the query unfinished (`dog +bea`, no space after it yet): while it's typed, keyword
    /// search may match it as the start of longer words, as it does the query's last word (`Searcher.search`'s
    /// `prefixLast`).
    public let typing: String?

    /// A `+word` or a `+"phrase"` in a query, and where it is.
    public struct Mark: Sendable, Equatable {
        /// The word or phrase that must be there, as typed ("beach", "golden retriever"): a word without the
        /// punctuation after it, a phrase without the spaces at its ends.
        public let term: String
        /// From the `+` to the end of the word, or through the phrase's closing quote (to the end of the query when it
        /// has none).
        public let range: Range<String.Index>
        /// What the search field draws marked: the mark, less the punctuation after a word (`+beach` of `+beach,`).
        public let drawn: Range<String.Index>
        /// The mark without its `+` and a phrase's quotes: what it is in the query once it's taken out.
        public let unmarked: String
        /// Typed in full: a space follows the word, or the phrase's quote is closed. Until it is, its term is still
        /// being typed (`typing`).
        public let isComplete: Bool
    }

    /// The marks of `query` read, and taken out of it.
    public init(_ query: String) {
        let marks = Self.marks(in: query)
        text = Self.unmarking(marks, in: query)
        var seen = Set<String>()
        terms = marks.map(\.term).filter { seen.insert(Self.words(of: $0)).inserted }
        typing = marks.last.flatMap { $0.isComplete ? nil : $0.term }
    }

    /// A query whose `+` is literal (a search of code): it requires nothing.
    public init(literal query: String) {
        text = query
        terms = []
        typing = nil
    }

    /// What a search embeds for the query: its text, then each required word alone (each a query of its own,
    /// `Prompts.query`); `vectors(_:)` takes their vectors back in this order.
    public var embedded: [String] { [text] + terms }

    /// The vectors of `embedded`, in its order, as `Searcher.search` takes them: the query's, and each term's by its
    /// term. None when there are none (the model can't run).
    public func vectors(_ embedded: [[Float]]) -> (query: [Float]?, required: [String: [Float]]) {
        (embedded.first, Dictionary(zip(terms, embedded.dropFirst()), uniquingKeysWith: { first, _ in first }))
    }

    /// The opening and closing quotes of a phrase: a plain one, and the curly ones macOS types when smart quotes are on.
    static let quotes: Set<Character> = ["\"", "\u{201C}", "\u{201D}"]

    /// Every mark in `query`, in order.
    public static func marks(in query: String) -> [Mark] {
        var marks: [Mark] = []
        var index = query.startIndex
        while index < query.endIndex {
            let next = query.index(after: index)
            guard query[index] == "+", index == query.startIndex || query[query.index(before: index)].isWhitespace,
                  next < query.endIndex else {
                index = next
                continue
            }
            if quotes.contains(query[next]) {
                let inside = query.index(after: next)
                let close = query[inside...].firstIndex(where: quotes.contains)
                let phrase = String(query[inside..<(close ?? query.endIndex)])
                let term = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
                if hasWords(term) {
                    let end = close.map { query.index(after: $0) } ?? query.endIndex
                    marks.append(Mark(term: term, range: index..<end, drawn: index..<end, unmarked: phrase,
                                      isComplete: close != nil))
                    index = end
                    continue
                }
            } else if query[next].isLetter {
                let end = query[next...].firstIndex(where: \.isWhitespace) ?? query.endIndex
                let word = String(query[next..<end])
                // Not the punctuation after it (it starts with a letter, so it doesn't run out).
                var drawnEnd = end
                while query[query.index(before: drawnEnd)].unicodeScalars
                    .allSatisfy(CharacterSet.punctuationCharacters.contains) {
                    drawnEnd = query.index(before: drawnEnd)
                }
                marks.append(Mark(term: word.trimmingCharacters(in: .punctuationCharacters), range: index..<end,
                                  drawn: index..<drawnEnd, unmarked: word, isComplete: end < query.endIndex))
                index = end
                continue
            }
            index = next
        }
        return marks
    }

    /// `query` with these of its marks taken out, each as `Mark.unmarked`.
    static func unmarking(_ marks: [Mark], in query: String) -> String {
        var text = query
        for mark in marks.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            text.replaceSubrange(mark.range, with: mark.unmarked)
        }
        return text
    }

    /// What "Require" (the search field's right-click) makes of the words `selected` in `query`: the whole words it
    /// touches, marked, as the range of `query` to replace and the mark to put there, with its term as it reads back.
    /// One word that starts with a letter gets a `+` (`beach,` → `+beach,`); several, or one that starts with
    /// something else (`4815`, `(beach)`), are quoted (`+"golden retriever"`, the punctuation after them left after
    /// the quote). Nil when there's nothing in them to require, or a quote a phrase can't hold, or when one of them is
    /// required already.
    public static func requiring(_ selected: Range<String.Index>, in query: String)
        -> (range: Range<String.Index>, mark: String, term: String)? {
        var start = selected.lowerBound, end = selected.upperBound
        while start < end, query[start].isWhitespace { start = query.index(after: start) }
        while end > start, query[query.index(before: end)].isWhitespace { end = query.index(before: end) }
        guard start < end else { return nil }
        while start > query.startIndex, !query[query.index(before: start)].isWhitespace {
            start = query.index(before: start)
        }
        while end < query.endIndex, !query[end].isWhitespace { end = query.index(after: end) }
        let words = String(query[start..<end])
        guard hasWords(words), !words.contains(where: quotes.contains),
              !marks(in: query).contains(where: { $0.range.overlaps(start..<end) }) else { return nil }
        let mark: String
        if words.first!.isLetter, !words.contains(where: \.isWhitespace) {
            mark = "+" + words
        } else if words.first!.isLetter || words.first!.isNumber {
            let after = words.reversed().prefix { !($0.isLetter || $0.isNumber) }.count
            mark = "+\"" + String(words.dropLast(after)) + "\"" + String(words.suffix(after))
        } else {
            mark = "+\"" + words + "\""
        }
        guard let term = marks(in: mark).first(where: { $0.range.lowerBound == mark.startIndex })?.term else {
            return nil
        }
        return (start..<end, mark, term)
    }

    /// A term's words as keyword search reads them, one space apart: two terms are one when they read alike ("Beach"
    /// and "beach"), and a phrase is matched as these words one after another (`Searcher.search`).
    static func words(of term: String) -> String {
        SearchText.normalized(term).lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func hasWords(_ text: String) -> Bool {
        text.contains { $0.isLetter || $0.isNumber }
    }
}
