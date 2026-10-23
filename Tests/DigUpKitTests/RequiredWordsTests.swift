import Foundation
import Testing
@testable import DigUpKit

/// Required words (`RequiredWords`, `Searcher.search`): `+beach` and `+"a phrase"` in a query keep only the results
/// that have each of them, in their words or by what they mean, ranked as the whole query ranks them.
@Suite final class RequiredWordsTests {
    let folder: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DigUpTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: The marks

    @Test func plusMarksAWordOrAPhraseOnlyAtTheStartOfAWord() {
        func read(_ query: String) -> [String] { RequiredWords(query).terms }
        #expect(RequiredWords("a dog running on +beach").text == "a dog running on beach")
        #expect(read("a dog running on +beach") == ["beach"])
        // A phrase, its quote closed or left open (it runs to the end), straight or curly.
        #expect(RequiredWords("+\"golden retriever\" puppy").text == "golden retriever puppy")
        #expect(read("+\"golden retriever\" puppy") == ["golden retriever"])
        #expect(RequiredWords("red +\"golden retr").text == "red golden retr")
        #expect(read("red +\"golden retr") == ["golden retr"])
        #expect(read("+\u{201C}red car\u{201D}") == ["red car"])
        // Several, each once ("Beach" is "beach"); the punctuation after a word isn't the word's.
        #expect(read("+dog on the +beach, +Beach") == ["dog", "beach"])
        #expect(RequiredWords("+dog on the +beach,").text == "dog on the beach,")
        // Ordinary text: a + inside a word, before a digit, alone, or before nothing to require.
        for query in ["c++ tutorial", "call +1 555 0100", "a + b", "+", "x+y", "+\"\" empty", "+\"!\""] {
            #expect(RequiredWords(query) == RequiredWords(literal: query), "\(query)")
        }
        // Typed in full: a space after the word, or the phrase's quote closed.
        #expect(RequiredWords.marks(in: "dog +beach").map(\.isComplete) == [false])
        #expect(RequiredWords.marks(in: "dog +beach ").map(\.isComplete) == [true])
        #expect(RequiredWords.marks(in: "+\"red car").map(\.isComplete) == [false])
        #expect(RequiredWords.marks(in: "+\"red car\"").map(\.isComplete) == [true])
        #expect(RequiredWords("dog +bea").typing == "bea" && RequiredWords("dog +beach ").typing == nil)
        // What's embedded, and the vectors back by term.
        let words = RequiredWords("dog +beach +\"red car\"")
        #expect(words.embedded == ["dog beach red car", "beach", "red car"])
        let vectors = words.vectors([[1], [2], [3]])
        #expect(vectors.query == [1] && vectors.required == ["beach": [2], "red car": [3]])
        #expect(words.vectors([]).query == nil && words.vectors([]).required.isEmpty)
    }

    /// The search field keeps a query as it's typed: what it draws marked is each mark (less the punctuation after a
    /// word), and what's searched and saved is the text itself, so it reads back as typed (cold review R3: these came
    /// back changed from the "must have" tokens the field made of them, and the last one with another meaning).
    @Test func theFieldDrawsEachMarkWhereItIsTyped() {
        func drawn(_ query: String) -> [String] { RequiredWords.marks(in: query).map { String(query[$0.drawn]) } }
        #expect(drawn("beach +beach") == ["+beach"])
        #expect(RequiredWords("beach +beach").terms == ["beach"])
        #expect(drawn("+dog on the +beach, +Beach") == ["+dog", "+beach", "+Beach"])
        #expect(RequiredWords("+dog on the +beach, +Beach").terms == ["dog", "beach"])
        // A phrase is drawn whole, its quotes and a + inside it too: "red +car" is the phrase.
        #expect(drawn("+\"red +car\"") == ["+\"red +car\""])
        #expect(RequiredWords("+\"red +car\"").terms == ["red +car"])
        #expect(drawn("+\"golden retr") == ["+\"golden retr"])
        #expect(drawn("c++ and +1 555 0100").isEmpty)
    }

    /// "Require" (the field's right-click) marks the whole words selected, or the word clicked, where they are.
    @Test func requireMarksTheWordsSelectedWhereTheyAre() {
        func require(_ selected: String, in query: String) -> String? {
            guard let found = query.range(of: selected),
                  let made = RequiredWords.requiring(found, in: query) else { return nil }
            return query.replacingCharacters(in: made.range, with: made.mark)
        }
        #expect(require("beach", in: "a dog on the beach") == "a dog on the +beach")
        #expect(require("ea", in: "a dog on the beach") == "a dog on the +beach")   // part of a word: the word
        #expect(require("beach", in: "beach, at noon") == "+beach, at noon")
        #expect(require("golden retriever", in: "a golden retriever puppy") == "a +\"golden retriever\" puppy")
        #expect(require("den retr", in: "our golden retriever, asleep") == "our +\"golden retriever\", asleep")
        // A number, or a word after punctuation, can't take a + alone.
        #expect(require("4815", in: "order 4815") == "order +\"4815\"")
        #expect(require("beach", in: "(beach) day") == "+\"(beach)\" day")
        // Nothing to require, a quote, or required already.
        #expect(require("!?", in: "what !? now") == nil)
        #expect(require("hi", in: "say \"hi\" there") == nil)
        #expect(require("beach", in: "dog +beach") == nil)
        #expect(require("car", in: "+\"red car\" wash") == nil)
        // The term the menu names, as the mark reads back; the + typed reads as typing it would.
        let query = "dog on the beach,"
        let made = RequiredWords.requiring(query.range(of: "beach")!, in: query)
        #expect(made?.term == "beach" && made?.mark == "+beach,")
        #expect(RequiredWords(query.replacingCharacters(in: made!.range, with: made!.mark))
                == RequiredWords("dog on the +beach,"))
    }

    // MARK: Searching

    private var inode: UInt64 = 0

    func add(_ store: IndexStore, _ path: String, _ text: String, kind: FileKind = .doc,
             segment: SegmentKind = .chunk) throws {
        inode += 1
        let id = try store.insert(Candidate(path: path, kind: kind, size: 1, mtime: 1, inode: inode, device: 1))
        try store.addSegment(file: id, kind: segment, modality: .text, loc: 1, text: text)
    }

    /// A required word keeps the files whose words have it (stemmed, as keyword search matches), several keep the
    /// files that have all of them, and a phrase its words in a row. The ones kept rank as the whole query ranks them.
    @Test func requiredWordsKeepTheFilesWhoseWordsHaveThem() throws {
        let store = try IndexStore(directory: folder.appendingPathComponent("index"))
        try add(store, "/notes/beach dog.txt", "the dog ran along the beach")
        try add(store, "/notes/park dog.txt", "the dog ran in the park")
        try add(store, "/notes/beaches.txt", "sand and sea at the beaches")
        try add(store, "/notes/golden.txt", "our golden retriever")
        try add(store, "/notes/retriever.txt", "a retriever that is golden")
        let searcher = try Searcher(store: store, loadVectors: false)
        func found(_ query: String) throws -> [String] {
            try searcher.search(query, queryVector: nil).map { ($0.path as NSString).lastPathComponent }
        }
        #expect(try Set(found("dog beach")) == ["beach dog.txt", "park dog.txt", "beaches.txt"])
        #expect(try Set(found("dog +beach")) == ["beach dog.txt", "beaches.txt"])
        #expect(try found("+dog +beach") == ["beach dog.txt"])
        #expect(try Set(found("golden retriever")) == ["golden.txt", "retriever.txt"])
        #expect(try found("+\"golden retriever\"") == ["golden.txt"])
        // The same ranking: the kept ones in the same order, with the same scores.
        let all = try searcher.search("dog beach", queryVector: nil)
        let kept = try searcher.search("dog +beach", queryVector: nil)
        #expect(kept.map(\.path) == all.filter { !$0.path.contains("park") }.map(\.path))
        #expect(kept.map(\.score) == all.filter { !$0.path.contains("park") }.map(\.score))
        // While it's typed (the panel's first, keyword-only results), the unfinished word is the start of longer ones;
        // typed in full, two letters are a word of their own, as the query's words are.
        #expect(try searcher.search("dog +be", queryVector: nil, prefixLast: true).map(\.path) == ["/notes/beach dog.txt"])
        #expect(try searcher.search("dog +be ", queryVector: nil, prefixLast: true).isEmpty)
    }

    /// A file with none of a required word's words is kept when it matches the word by meaning on its own (the word
    /// embedded alone, its best segment standing out as a meaning match does): a picture of a beach with no words. The
    /// query's meaning still ranks them, as without the word required.
    @Test func aRequiredWordIsAlsoFoundByMeaning() throws {
        let store = try IndexStore(directory: folder.appendingPathComponent("index"))
        let query = FakeEmbedder.vector(for: "a dog running on beach"), beach = FakeEmbedder.vector(for: "beach")
        func mixed(_ parts: [[Float]]) -> [Float] {
            let sum = parts.dropFirst().reduce(parts[0]) { zip($0, $1).map(+) }
            let norm = sum.reduce(0) { $0 + $1 * $1 }.squareRoot()
            return sum.map { $0 / norm }
        }
        // Named as cameras name them: no words of the query in their names.
        func picture(_ name: String, _ vector: [Float], words: String? = nil) throws {
            inode += 1
            let id = try store.insert(Candidate(path: "/pictures/\(name).jpg", kind: .image, size: 1, mtime: 1,
                                                inode: inode, device: 1))
            try store.addSegment(file: id, kind: .image, modality: .image, vector: vector)
            if let words { try store.addSegment(file: id, kind: .ocr, modality: .text, text: words) }
        }
        for number in 0..<60 { try picture("IMG_\(1000 + number)", FakeEmbedder.vector(for: "other \(number)")) }
        try picture("IMG_1", mixed([query, beach]))                                          // a dog on a beach
        try picture("IMG_2", mixed([query, FakeEmbedder.vector(for: "park")]))               // a dog in a park
        try picture("IMG_3", mixed([query, FakeEmbedder.vector(for: "sign")]), words: "BEACH CLOSED")   // by a sign
        let searcher = try Searcher(store: store)
        func found(_ text: String, required: [String: [Float]] = [:]) throws -> [SearchHit] {
            try searcher.search(text, queryVector: query, requiredVectors: required, kinds: [.image])
        }
        let all = try found("a dog running on beach")
        #expect(Set(all.map(\.path)) == ["/pictures/IMG_1.jpg", "/pictures/IMG_2.jpg", "/pictures/IMG_3.jpg"])
        // By meaning, or by its words (the sign's); without the word's vector, by its words alone.
        let kept = try found("a dog running on +beach", required: ["beach": beach])
        #expect(Set(kept.map(\.path)) == ["/pictures/IMG_1.jpg", "/pictures/IMG_3.jpg"])
        #expect(try found("a dog running on +beach").map(\.path) == ["/pictures/IMG_3.jpg"])
        // Ranked as before.
        let before = all.filter { $0.path != "/pictures/IMG_2.jpg" }
        #expect(kept.map(\.path) == before.map(\.path) && kept.map(\.score) == before.map(\.score))
    }

    /// What leaves a file out of an AI app's sight (`SearchFilter.exclusions`) comes first: a required word never sees
    /// the words of a file the app may not see. "grok" is a word only in a Photos picture the app can't see, so for the
    /// app it's in no file and is matched as the start of longer words ("Grok4"), as the query's own words are.
    @Test func aRequiredWordNeverSeesFilesLeftOut() throws {
        let store = try IndexStore(directory: folder.appendingPathComponent("index"))
        try add(store, "/L.photoslibrary/originals/A/U1.jpeg", "grok", kind: .image, segment: .ocr)
        try add(store, "/shots/settings.png", "Model picker: Grok4 (default)", kind: .screenshot, segment: .ocr)
        let searcher = try Searcher(store: store, loadVectors: false)
        var hidden = SearchFilter()
        hidden.photosOnly = []
        #expect(try searcher.search("model picker +grok", queryVector: nil, filter: hidden).map(\.path)
                == ["/shots/settings.png"])
        // DigUp's own search sees the picture's word: "grok" stays whole, and the screenshot doesn't have it.
        #expect(try searcher.search("model picker +grok", queryVector: nil).isEmpty)
    }

    /// A required word's meaning gate is on the scale of what the caller may see (`Searcher.rowsSettingScale`): an AI
    /// app's search isn't swayed by pictures it can't see. Here 100 Photos pictures, far more like "beach" than any
    /// other, would put a picture that's somewhat like it under the gate; left out of the app's sight, they don't.
    @Test func aRequiredWordsMeaningGateIsOnTheScaleOfWhatTheCallerSees() throws {
        let store = try IndexStore(directory: folder.appendingPathComponent("index"))
        let beach = FakeEmbedder.vector(for: "beach")
        /// A unit vector `cosine` like "beach", the rest of it unlike it (from `seed`).
        func like(_ cosine: Float, _ seed: String) -> [Float] {
            let mixed = zip(beach, FakeEmbedder.vector(for: seed)).map { cosine * $0 + (1 - cosine * cosine).squareRoot() * $1 }
            let norm = mixed.reduce(0) { $0 + $1 * $1 }.squareRoot()
            return mixed.map { $0 / norm }
        }
        func picture(_ path: String, _ vector: [Float], words: String? = nil) throws {
            inode += 1
            let id = try store.insert(Candidate(path: path, kind: .image, size: 1, mtime: 1, inode: inode, device: 1))
            try store.addSegment(file: id, kind: .image, modality: .image, vector: vector)
            if let words { try store.addSegment(file: id, kind: .ocr, modality: .text, text: words) }
        }
        for number in 0..<60 { try picture("/pictures/IMG_\(1000 + number).jpg", like(0, "other \(number)")) }
        for number in 0..<100 { try picture("/L.photoslibrary/originals/A/U\(number).jpeg", like(0.9, "\(number)")) }
        try picture("/pictures/IMG_1.jpg", like(0.3, "dog"), words: "DOG")
        let searcher = try Searcher(store: store)
        var hidden = SearchFilter()
        hidden.photosOnly = []
        func found(_ filter: SearchFilter) throws -> [String] {
            try searcher.search("dog +beach", queryVector: nil, requiredVectors: ["beach": beach], filter: filter)
                .map(\.path)
        }
        #expect(try found(hidden) == ["/pictures/IMG_1.jpg"])
        #expect(try found(SearchFilter()).isEmpty)
    }

    /// Cold review R1: what an AI app can find with a required word doesn't depend on files it may not see. A note with
    /// "atlas" and "beach" is found among 100 notes full of "beach", and still is after 2,000 Photos pictures it can't
    /// see, full of "atlas", are added: matched over the whole index, they made "atlas" common, put the 100 notes ahead
    /// of it, and the best 100 matches left it out.
    @Test func whatAnAIAppFindsWithARequiredWordDoesntDependOnFilesItCantSee() throws {
        let store = try IndexStore(directory: folder.appendingPathComponent("index"))
        let target = "/notes/atlas.txt"
        try store.db.transaction {
            try add(store, target, "atlas beach one two three four five six seven eight nine ten")
            for number in 0..<100 {
                try add(store, "/notes/beach \(number).txt", String(repeating: "beach ", count: 20))
            }
        }
        var hidden = SearchFilter()
        hidden.photosOnly = []
        func found() throws -> [String] {
            try Searcher(store: store, loadVectors: false).search("atlas +beach", queryVector: nil, filter: hidden,
                                                                limit: 200).map(\.path)
        }
        #expect(try found().contains(target))
        try store.db.transaction {
            for number in 0..<2_000 {
                try add(store, "/L.photoslibrary/originals/A/U\(number).jpeg", String(repeating: "atlas ", count: 20),
                        kind: .image, segment: .ocr)
            }
        }
        let after = try found()
        #expect(after.contains(target))
        #expect(!after.contains { $0.contains(".photoslibrary/") })
    }

    /// In a search of code, `+` is literal.
    @Test func codeTakesPlusAsWritten() throws {
        let store = try IndexStore(directory: folder.appendingPathComponent("index"), file: IndexStore.codeFile)
        let id = try store.insert(Candidate(path: "/app/Retry.swift", kind: .code, size: 1, mtime: 1, inode: 1, device: 1))
        try store.addSegment(file: id, kind: .lines, modality: .text, loc: 1, locEnd: 3,
                             text: "func retry() {\n    backoff()\n}")
        let searcher = try Searcher(store: store, loadVectors: false)
        #expect(try searcher.search("retry +zebra", queryVector: nil).map(\.path) == ["/app/Retry.swift"])
    }
}
