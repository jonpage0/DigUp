import Foundation
import Testing
@testable import DigUpKit

/// Match by (approved 2026-10-23, `SearchFilter.matchBy`): which parts of a file may make it match. With words, only
/// the chosen parts' meaning and words count, a required word's too, and a result's reason, excerpt and moments come
/// from them, on the scale every part sets; without words, the files that have a chosen part are listed. How a saved
/// search keeps it, and how the CLI and AI apps give it.
@Suite final class MatchByTests {
    let folder: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DigUpTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    static let words = "a zebra crossing a river"
    static let query = FakeEmbedder.vector(for: words)

    /// A unit vector `cosine` like `to` (the query's by default), the rest of it unlike it (from `seed`).
    static func like(_ cosine: Double, _ seed: String, to: [Float] = query) -> [Float] {
        let other = FakeEmbedder.vector(for: seed)
        let rest = (1 - cosine * cosine).squareRoot()
        let mixed = zip(to, other).map { Float(cosine) * $0 + Float(rest) * $1 }
        let norm = mixed.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return mixed.map { $0 / norm }
    }

    /// A filter of these parts alone; none, every part.
    static func matching(_ parts: SearchFilter.Part...) -> SearchFilter {
        var filter = SearchFilter()
        filter.matchBy = SearchFilter.MatchBy(parts)
        return filter
    }

    /// What an AI app that may not see Photos libraries searches with (`SearchFilter.photosOnly`).
    static func unseenPhotos(_ filter: SearchFilter) -> SearchFilter {
        var filter = filter
        filter.photosOnly = []
        return filter
    }

    private var inode: UInt64 = 0

    /// A file read already, with its name row (`IndexStore.insert`).
    func file(_ store: IndexStore, _ path: String, _ kind: FileKind) throws -> Int64 {
        inode += 1
        let id = try store.insert(Candidate(path: path, kind: kind, size: 1, mtime: 1, inode: inode, device: 1))
        try store.finish(id, state: "done")
        return id
    }

    /// Notes with vectors unlike any query and no words of one, as most of an index is: what a query's scale is made
    /// of.
    func fill(_ store: IndexStore, _ count: Int = 60) throws {
        for number in 0..<count {
            let id = try file(store, "/fill/\(number).txt", .doc)
            try store.addSegment(file: id, kind: .chunk, modality: .text, loc: 1,
                                 vector: Self.like(0, "fill \(number)"))
        }
    }

    @Test func eachChoiceIsTheSegmentKindsApproved() {
        let approved: [SearchFilter.Part: Set<SegmentKind>] = [
            .visual: [.image, .frame, .pageImage], .audio: [.audio], .spoken: [.speech],
            .text: [.chunk, .page, .ocr, .name, .lines, .cells], .tags: [.photosInfo],
        ]
        for part in SearchFilter.Part.allCases { #expect(Set(part.segments) == approved[part], "\(part)") }
        // In the order a saved search writes them, and every kind the index keeps in one of them.
        #expect(SearchFilter.Part.allCases.map(\.rawValue) == ["visual", "audio", "spoken", "text", "tags"])
        #expect(SearchFilter.Part.allCases.flatMap(\.segments).count == SegmentKind.allCases.count)
        #expect(SearchFilter.MatchBy([.text, .spoken])?.parts == [.spoken, .text])
        #expect(SearchFilter.MatchBy([SearchFilter.Part]()) == nil)
        #expect(SearchFilter().isEmpty && !Self.matching(.spoken).isEmpty)
    }

    /// An index where each part of a different file means the query, or has its words: a picture that shows it, a
    /// note that says it and means it, a talk whose speech says it and means it, a video whose sound means it, a Photos
    /// picture whose words in Photos say it, a PDF named with its words.
    func eachPartsFile() throws -> Searcher {
        let store = try IndexStore(directory: folder.appendingPathComponent("index"))
        try fill(store)
        let picture = try file(store, "/pictures/IMG_1.jpg", .image)
        try store.addSegment(file: picture, kind: .image, modality: .image, vector: Self.like(1, "picture"))
        let note = try file(store, "/notes/n.txt", .doc)
        try store.addSegment(file: note, kind: .chunk, modality: .text, loc: 1, excerpt: "zebra stripes by the river",
                             text: "zebra stripes by the river", vector: Self.like(1, "note"))
        let talk = try file(store, "/talks/t.m4a", .audio)
        try store.addSegment(file: talk, kind: .audio, modality: .audio, loc: 0, locEnd: 30,
                             vector: Self.like(0, "talk sound"))
        try store.addSegment(file: talk, kind: .speech, modality: .text, loc: 2, locEnd: 5,
                             excerpt: "a zebra is crossing the river", text: "a zebra is crossing the river",
                             vector: Self.like(1, "talk speech"))
        let video = try file(store, "/videos/v.mov", .video)
        try store.addSegment(file: video, kind: .frame, modality: .image, loc: 0.5, locEnd: 3.5,
                             vector: Self.like(0, "video frame"))
        try store.addSegment(file: video, kind: .audio, modality: .audio, loc: 0, locEnd: 30,
                             vector: Self.like(1, "video sound"))
        let photo = try file(store, "/L.photoslibrary/originals/A/U1.jpeg", .image)
        try store.addSegment(file: photo, kind: .photosInfo, modality: .none, text: "Zebra River Crossing")
        try store.addSegment(file: photo, kind: .image, modality: .image, vector: Self.like(0, "photo"))
        _ = try file(store, "/names/zebra river.pdf", .pdf)
        return try Searcher(store: store)
    }

    /// Only the chosen parts make a file match, by what they mean or by their words; the result points at a chosen
    /// part, quoting its words; and a choice changes which parts count, not their scores (the scale is every part's).
    /// An AI app that may not see Photos finds the same, but for the Photos picture.
    @Test(arguments: [false, true])
    func meaningAndWordsCountOnlyInTheChosenParts(unseenPhotos: Bool) throws {
        let searcher = try eachPartsFile()
        func found(_ filter: SearchFilter) throws -> [String: SearchHit] {
            let hits = try searcher.search(Self.words, queryVector: Self.query,
                                           filter: unseenPhotos ? Self.unseenPhotos(filter) : filter, limit: 100)
            return Dictionary(uniqueKeysWithValues: hits.map { (($0.path as NSString).lastPathComponent, $0) })
        }
        let photos: Set<String> = unseenPhotos ? [] : ["U1.jpeg"]
        let every = try found(SearchFilter())
        #expect(Set(every.keys) == Set(["IMG_1.jpg", "n.txt", "t.m4a", "v.mov", "zebra river.pdf"]).union(photos))
        let expected: [(SearchFilter.Part, Set<String>)] = [
            (.visual, ["IMG_1.jpg"]), (.audio, ["v.mov"]), (.spoken, ["t.m4a"]), (.text, ["n.txt", "zebra river.pdf"]),
            (.tags, photos),
        ]
        for (part, names) in expected {
            let hits = try found(Self.matching(part))
            #expect(Set(hits.keys) == names, "\(part)")
            #expect(hits.values.allSatisfy { SearchFilter.Part($0.segment) == part }, "\(part)")
        }
        let two = try found(Self.matching(.spoken, .text))
        #expect(Set(two.keys) == ["t.m4a", "n.txt", "zebra river.pdf"])
        // The reason and the words quoted are the chosen part's: the talk by what's said in it, the note by its text.
        let said = try #require(two["t.m4a"]), written = try #require(two["n.txt"])
        #expect(said.segment == .speech && said.excerpt?.contains("«zebra»") == true && said.loc == 2)
        #expect(written.segment == .chunk && written.excerpt?.contains("«zebra»") == true)
        // The same scale: each file's meaning measured as with every part.
        for (name, part) in [("IMG_1.jpg", SearchFilter.Part.visual), ("v.mov", .audio), ("t.m4a", .spoken),
                             ("n.txt", .text)] {
            let z = try #require(try found(Self.matching(part))[name]?.z)
            #expect(z == every[name]?.z, "\(name)")
        }
    }

    /// A required word must be met in a chosen part: by its words there, or by what one of them means.
    @Test func requiredWordsAreMetOnlyInAChosenPart() throws {
        let store = try IndexStore(directory: folder.appendingPathComponent("index"))
        let beach = FakeEmbedder.vector(for: "beach")
        try fill(store)
        let talk = try file(store, "/talks/t.m4a", .audio)
        try store.addSegment(file: talk, kind: .speech, modality: .text, loc: 0, locEnd: 4,
                             text: "sand everywhere at the beach")
        let note = try file(store, "/notes/beach.txt", .doc)   // "beach" only in its name
        try store.addSegment(file: note, kind: .chunk, modality: .text, loc: 1, text: "sand in my shoes")
        let photo = try file(store, "/L.photoslibrary/originals/A/U1.jpeg", .image)   // "beach" only in Photos' words
        try store.addSegment(file: photo, kind: .photosInfo, modality: .none, text: "Beach")
        try store.addSegment(file: photo, kind: .ocr, modality: .text, text: "sand on the window")
        let picture = try file(store, "/pictures/IMG_2.jpg", .image)   // a beach only by what it shows
        try store.addSegment(file: picture, kind: .image, modality: .image, vector: Self.like(1, "picture", to: beach))
        try store.addSegment(file: picture, kind: .ocr, modality: .text, text: "sand")
        let searcher = try Searcher(store: store)
        func found(_ filter: SearchFilter) throws -> Set<String> {
            Set(try searcher.search("sand +beach", queryVector: nil, requiredVectors: ["beach": beach], filter: filter)
                .map { ($0.path as NSString).lastPathComponent })
        }
        #expect(try found(SearchFilter()) == ["t.m4a", "beach.txt", "U1.jpeg", "IMG_2.jpg"])
        #expect(try found(Self.matching(.spoken)) == ["t.m4a"])
        #expect(try found(Self.matching(.text)) == ["beach.txt"])
        #expect(try found(Self.matching(.text, .tags)) == ["beach.txt", "U1.jpeg"])
        #expect(try found(Self.matching(.visual, .text)) == ["beach.txt", "IMG_2.jpg"])
        #expect(try found(Self.matching(.tags)) == ["U1.jpeg"])
        // An AI app finds the same, but for what it may not see.
        #expect(try found(Self.unseenPhotos(Self.matching(.text, .tags))) == ["beach.txt"])
        #expect(try found(Self.unseenPhotos(Self.matching(.visual, .text))) == ["beach.txt", "IMG_2.jpg"])
    }

    /// Without words, Match by lists the files that have a chosen part: Spoken alone, the recordings with speech.
    @Test func withoutWordsTheFilesWithAChosenPartAreListed() throws {
        let store = try IndexStore(directory: folder.appendingPathComponent("index"))
        let said = try file(store, "/talks/said.m4a", .audio)
        try store.addSegment(file: said, kind: .audio, modality: .audio, loc: 0, locEnd: 30, vector: Self.like(0, "1"))
        try store.addSegment(file: said, kind: .speech, modality: .text, loc: 0, locEnd: 4, text: "hello there")
        let music = try file(store, "/talks/music.m4a", .audio)
        try store.addSegment(file: music, kind: .audio, modality: .audio, loc: 0, locEnd: 30, vector: Self.like(0, "2"))
        let note = try file(store, "/notes/n.txt", .doc)
        try store.addSegment(file: note, kind: .chunk, modality: .text, loc: 1, text: "a note")
        let picture = try file(store, "/pictures/p.jpg", .image)
        try store.addSegment(file: picture, kind: .image, modality: .image, vector: Self.like(0, "3"))
        let video = try file(store, "/videos/v.mov", .video)
        try store.addSegment(file: video, kind: .frame, modality: .image, loc: 0.5, vector: Self.like(0, "4"))
        try store.addSegment(file: video, kind: .audio, modality: .audio, loc: 0, locEnd: 30, vector: Self.like(0, "5"))
        let photo = try file(store, "/L.photoslibrary/originals/A/U1.jpeg", .image)
        try store.addSegment(file: photo, kind: .photosInfo, modality: .none, text: "Beach")
        try store.addSegment(file: photo, kind: .image, modality: .image, vector: Self.like(0, "6"))
        inode += 1
        try store.insert(Candidate(path: "/pictures/waiting.jpg", kind: .image, size: 1, mtime: 1, inode: inode,
                                   device: 1))   // not read yet: its name alone
        let searcher = try Searcher(store: store, loadVectors: false)
        func listed(_ filter: SearchFilter, kinds: Set<FileKind>? = nil) throws -> Set<String> {
            let searched = try searcher.search("", queryVector: nil, kinds: kinds, filter: filter, limit: 100)
            #expect(try searcher.browse(filter, kinds: kinds, limit: 100).map(\.path) == searched.map(\.path))
            return Set(searched.map { ($0.path as NSString).lastPathComponent })
        }
        #expect(try listed(Self.matching(.spoken)) == ["said.m4a"])
        #expect(try listed(Self.matching(.audio)) == ["said.m4a", "music.m4a", "v.mov"])
        #expect(try listed(Self.matching(.visual)) == ["p.jpg", "v.mov", "U1.jpeg"])
        #expect(try listed(Self.matching(.tags)) == ["U1.jpeg"])
        #expect(try listed(Self.matching(.spoken, .tags)) == ["said.m4a", "U1.jpeg"])
        #expect(try listed(Self.matching(.text)).count == 7)   // every file has its name
        #expect(try listed(Self.matching(.audio), kinds: [.video]) == ["v.mov"])
        // An AI app that may not see Photos lists the same, but for the Photos picture.
        #expect(try listed(Self.unseenPhotos(Self.matching(.visual))) == ["p.jpg", "v.mov"])
    }

    /// An AI app's keyword matching (`Searcher.wordsInSight`) keeps to the chosen parts as the window's does, a word's
    /// prefix matching included: a word that's whole only in a part not chosen is in no file for the search, so it's
    /// matched as the start of longer words in the chosen ones ("grok" finds "Grok4" said in a talk). What the app
    /// finds in an index with a Photos picture it may not see is what the window finds in the index without it.
    @Test func anAIAppsWordsKeepToTheChosenPartsAsTheWindowsDo() throws {
        let store = try IndexStore(directory: folder.appendingPathComponent("index"))
        let talk = try file(store, "/talks/t.m4a", .audio)
        try store.addSegment(file: talk, kind: .speech, modality: .text, loc: 3, locEnd: 6,
                             text: "the Grok4 model is in the picker")
        let note = try file(store, "/notes/words.txt", .doc)
        try store.addSegment(file: note, kind: .chunk, modality: .text, loc: 1, text: "to grok the model picker")
        let shot = try file(store, "/shots/s.png", .screenshot)
        try store.addSegment(file: shot, kind: .ocr, modality: .text, text: "Grok4 in the model picker")
        struct Found: Hashable {
            let name: String, segment: SegmentKind, excerpt: String?
        }
        func found(_ query: String, _ filter: SearchFilter) throws -> Set<Found> {
            Set(try Searcher(store: store, loadVectors: false).search(query, queryVector: nil, filter: filter).map {
                Found(name: ($0.path as NSString).lastPathComponent, segment: $0.segment, excerpt: $0.excerpt)
            })
        }
        let queries = ["grok", "model picker", "picker +grok", "+model +grok"]
        let filters = [Self.matching(.spoken), Self.matching(.text), Self.matching(.spoken, .tags), SearchFilter()]
        var window: [[Set<Found>]] = []
        for query in queries {
            window.append(try filters.map { filter in
                let hits = try found(query, filter)
                #expect(hits.allSatisfy { filter.matchBy?.contains(SearchFilter.Part($0.segment)) ?? true })
                return hits
            })
        }
        let photo = try file(store, "/L.photoslibrary/originals/A/U1.jpeg", .image)
        try store.addSegment(file: photo, kind: .photosInfo, modality: .none, text: "grok model picker")
        for (row, query) in queries.enumerated() {
            for (column, filter) in filters.enumerated() {
                #expect(try found(query, Self.unseenPhotos(filter)) == window[row][column],
                        "\(query) \(filter.matchBy?.text ?? "every part")")
            }
        }
        // "grok" is whole in the note and the Photos picture: with every part, or Text, the talk's "Grok4" isn't it…
        #expect(try found("grok", SearchFilter()).map(\.name).sorted() == ["U1.jpeg", "words.txt"])
        #expect(try found("grok", Self.matching(.text)).map(\.name) == ["words.txt"])
        #expect(try found("grok", Self.matching(.spoken, .tags)).map(\.name) == ["U1.jpeg"])
        // …but it's in nothing said: Spoken alone matches it as the start of longer words, as typed, as the app does
        // with Spoken and Tags, the Photos picture left out of its sight.
        let spoken = try found("grok", Self.matching(.spoken))
        #expect(spoken == [Found(name: "t.m4a", segment: .speech, excerpt: "the «Grok4» model is in the picker")])
        #expect(try found("grok", Self.unseenPhotos(Self.matching(.spoken, .tags))) == spoken)
    }

    /// A recording's moments come from its chosen parts alone, in the preview and as its result counts them.
    @Test func aRecordingsMomentsComeFromItsChosenParts() throws {
        let store = try IndexStore(directory: folder.appendingPathComponent("index"))
        for number in 0..<40 {
            let picture = try file(store, "/pictures/\(number).jpg", .image)
            try store.addSegment(file: picture, kind: .image, modality: .image,
                                 vector: Self.like(0, "picture \(number)"))
        }
        let path = "/videos/river.mov"
        let video = try file(store, path, .video)
        for (loc, end, cosine, seed) in [(0.5, 3.5, 0.0, "a"), (3.5, 6.5, 1, "b")] {
            try store.addSegment(file: video, kind: .frame, modality: .image, loc: loc, locEnd: end,
                                 vector: Self.like(cosine, seed))
        }
        try store.addSegment(file: video, kind: .audio, modality: .audio, loc: 25, locEnd: 55,
                             vector: Self.like(1, "c"))
        let said = "Look, a zebra is crossing the river!"
        try store.addSegment(file: video, kind: .speech, modality: .text, loc: 10, locEnd: 14, excerpt: said,
                             text: said, vector: Self.like(0, "d"))
        let searcher = try Searcher(store: store)
        func moments(_ filter: SearchFilter) throws -> [Moment] {
            try searcher.moments(of: path, text: Self.words, queryVector: Self.query, filter: filter)
        }
        #expect(Set(try moments(SearchFilter()).map(\.kind)) == [.seen, .heard, .said])
        #expect(try moments(Self.matching(.visual)).map(\.start) == [3.5])
        #expect(try moments(Self.matching(.audio)).map(\.start) == [25])
        #expect(try moments(Self.matching(.spoken)).map(\.words) == [said])
        #expect(try moments(Self.matching(.text, .tags)).isEmpty)
        let parts: [(SearchFilter.Part, SegmentKind)] = [(.visual, .frame), (.audio, .audio), (.spoken, .speech)]
        for (part, kind) in parts {
            let found = try searcher.search(Self.words, queryVector: Self.query, filter: Self.matching(part))
            let hit = try #require(found.first)
            #expect(found.count == 1 && hit.path == path && hit.segment == kind && hit.momentCount == 1, "\(part)")
        }
    }

    /// As saved-searches.json keeps it (approved): the parts' names in the order above. One that isn't exactly that
    /// (empty, a name twice, one that isn't a part's, out of order, not a list of names) isn't read.
    @Test func aSavedSearchsMatchByComesBackAsItWasAndBadOnesAreRefused() throws {
        let encoder = JSONEncoder()
        func written(_ value: SearchFilter.MatchBy) throws -> String {
            String(decoding: try encoder.encode(value), as: UTF8.self)
        }
        func read(_ json: String) -> SearchFilter.MatchBy? {
            try? JSONDecoder().decode(SearchFilter.MatchBy.self, from: Data(json.utf8))
        }
        #expect(try written(try #require(SearchFilter.MatchBy([.text, .spoken]))) == #"["spoken","text"]"#)
        // Every choice there can be comes back as it was.
        let parts = SearchFilter.Part.allCases
        for mask in 1..<(1 << parts.count) {
            let chosen = try #require(SearchFilter.MatchBy(parts.indices.filter { mask & (1 << $0) != 0 }
                .map { parts[$0] }))
            #expect(read(try written(chosen)) == chosen)
        }
        for bad in ["[]", #"["spoken","spoken"]"#, #"["text","spoken"]"#, #"["Spoken"]"#, #"["speech"]"#,
                    #"["spoken",null]"#, #"[1]"#, #""spoken""#, "null", "true", #"{"matchBy":["spoken"]}"#,
                    #"["visual","audio","spoken","text","tags","tags"]"#] {
            #expect(read(bad) == nil, "\(bad)")
        }
    }

    /// `digup search --match-by spoken,text` and `digup mcp`'s `match_by: ["spoken", "text"]`: the parts by name, in
    /// any order, each once; nothing else.
    @Test func matchByIsTakenAsTheCLIAndAIAppsGiveIt() throws {
        let spokenText = try #require(SearchFilter.MatchBy([.spoken, .text]))
        #expect(SearchFilter.MatchBy("spoken,text") == spokenText && SearchFilter.MatchBy("text, spoken") == spokenText)
        #expect(SearchFilter.MatchBy(choosing: ["text", "spoken"]) == spokenText)
        #expect(SearchFilter.MatchBy(choosing: SearchFilter.Part.allCases.map(\.rawValue))?.parts
                == SearchFilter.Part.allCases)
        #expect(spokenText.text == "spoken,text" && SearchFilter.MatchBy(spokenText.text) == spokenText)
        #expect(spokenText.title == "Match: Spoken + Text")
        for bad in ["", "spoken,,text", "spoken,spoken", "voice", "Spoken", "spoken text", ","] {
            #expect(SearchFilter.MatchBy(bad) == nil, "\(bad)")
        }
        for bad in [[], ["spoken", "spoken"], ["sound"], ["spoken", ""], ["TEXT"]] as [[String]] {
            #expect(SearchFilter.MatchBy(choosing: bad) == nil, "\(bad)")
        }
    }
}
