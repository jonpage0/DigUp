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
        /// The mark without its `+` and a phrase's quotes: what it is in the query once it's taken out.
        public let unmarked: String
        /// Typed in full: a space follows the word, or the phrase's quote is closed. The search window and the panel
        /// make a "must have" token of it then, never while it's being typed.
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
                    marks.append(Mark(term: term, range: index..<end, unmarked: phrase, isComplete: close != nil))
                    index = end
                    continue
                }
            } else if query[next].isLetter {
                let end = query[next...].firstIndex(where: \.isWhitespace) ?? query.endIndex
                let word = String(query[next..<end])
                marks.append(Mark(term: word.trimmingCharacters(in: .punctuationCharacters), range: index..<end,
                                  unmarked: word, isComplete: end < query.endIndex))
                index = end
                continue
            }
            index = next
        }
        return marks
    }

    /// `query` with these of its marks taken out, each as `Mark.unmarked`.
    public static func unmarking(_ marks: [Mark], in query: String) -> String {
        var text = query
        for mark in marks.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            text.replaceSubrange(mark.range, with: mark.unmarked)
        }
        return text
    }

    /// `text` with each of `terms` marked required: its first appearance as a whole word or phrase that starts a word,
    /// or, when it isn't in `text` (any more), the mark ahead of the text, where the search field shows its token. A term
    /// marked already stays as it is. `RequiredWords(marking(terms, in: text))` gives back `text` and `terms` when each
    /// term is in it: the window keeps the words in their place, and a must-have token beside them.
    public static func marking(_ terms: [String], in text: String) -> String {
        var text = text, ahead: [String] = []
        for term in terms {
            let marked = marks(in: text)
            guard !(marked.map(\.term) + ahead).contains(where: { words(of: $0) == words(of: term) }) else { continue }
            if let found = firstAppearance(of: term, in: text, outside: marked.map(\.range)) {
                text.replaceSubrange(found, with: mark(String(text[found])))
            } else {
                ahead.append(term)
            }
        }
        return (ahead.map(mark) + (text.isEmpty ? [] : [text])).joined(separator: " ")
    }

    /// `required` with `terms` after it, each once: one it has already (as keyword search reads it, "Beach" is "beach")
    /// is left out.
    public static func adding(_ terms: [String], to required: [String]) -> [String] {
        var seen = Set(required.map(words(of:)))
        return required + terms.filter { seen.insert(words(of: $0)).inserted }
    }

    /// The selection a right-click asks to require ("beach," selected: "beach"), or nil when it has no word in it.
    public static func term(selected selection: String) -> String? {
        let trimmed = selection.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
            .union(CharacterSet(charactersIn: "+")))
        let term = trimmed.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return hasWords(term) ? term : nil
    }

    /// The mark of a term: `+word` when it reads back as one word, else `+"…"` (a phrase, or a word that starts with
    /// a digit, which `+` alone doesn't mark).
    static func mark(_ term: String) -> String {
        let word = term.first?.isLetter == true && !term.contains { $0.isWhitespace || quotes.contains($0) }
            && term.trimmingCharacters(in: .punctuationCharacters) == term
        return word ? "+" + term : "+\"" + term + "\""
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

    /// Where `term` first is in `text` as a whole word or phrase starting a word (after a space, or first), ignoring
    /// case, and not inside one of the `marked` ranges.
    private static func firstAppearance(of term: String, in text: String,
                                        outside marked: [Range<String.Index>]) -> Range<String.Index>? {
        var from = text.startIndex
        while let found = text.range(of: term, options: [.caseInsensitive], range: from..<text.endIndex) {
            from = found.upperBound
            let starts = found.lowerBound == text.startIndex || text[text.index(before: found.lowerBound)].isWhitespace
            let ends = found.upperBound == text.endIndex
                || !(text[found.upperBound].isLetter || text[found.upperBound].isNumber)
            if starts, ends, !marked.contains(where: { $0.overlaps(found) }) { return found }
        }
        return nil
    }
}
