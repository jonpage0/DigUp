import Foundation
import Testing
@testable import DigUpKit

/// What `digup mcp` lets AI apps see (`AIAccess`, `SearchFilter.photosOnly`, `PhotosLibrary.visibleAssets`), the index
/// it opens only to read, what it logs, and how it says why a result is there.
@Suite struct AIAccessTests {
    let folder: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DigUpTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return URL(fileURLWithPath: FolderSelection.realPath(url.path))
    }()

    var index: URL { folder.appendingPathComponent("index") }

    /// Keeps a listing of `library` in the index folder as the osxphotos reader does: made with hidden items or
    /// without, its assets marked hidden or not (nil: from before DigUp marked them).
    func keep(_ assets: [(uuid: String, hidden: Bool?)], of library: String, hidden: Bool,
              listedAs listed: String? = nil) throws {
        let kept = PhotosLibrary.Kept(library: listed ?? library, hidden: hidden, listedAt: 0,
                                      state: PhotosLibrary.State(pictures: "", database: ""),
                                      listing: PhotosLibrary.Listing(assets: assets.map {
                                          PhotosLibrary.Asset(uuid: $0.uuid, path: "\(library)/originals/\($0.uuid).jpeg",
                                                              movie: false, screenshot: false, title: "", date: 0,
                                                              words: [], hidden: $0.hidden)
                                      }))
        let file = PhotosLibrary.keptListing(of: library, keptIn: index)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(kept).write(to: file)
    }

    @Test func hiddenItemsAreToldFromTheLibrarysKeptListing() throws {
        let library = "/L.photoslibrary"
        // None kept: none vouched for.
        #expect(PhotosLibrary.visibleAssets(of: library, keptIn: index).isEmpty)
        // Listed with hidden items: the ones marked not hidden.
        try keep([("U0", false), ("U1", true), ("U2", false)], of: library, hidden: true)
        #expect(PhotosLibrary.visibleAssets(of: library, keptIn: index) == ["U0", "U2"])
        // Listed without them: every one listed, marked or not (the script before marked none).
        try keep([("U0", false), ("U1", nil)], of: library, hidden: false)
        #expect(PhotosLibrary.visibleAssets(of: library, keptIn: index) == ["U0", "U1"])
        // With hidden items, from before DigUp marked them: an unmarked one isn't vouched for.
        try keep([("U0", false), ("U1", nil)], of: library, hidden: true)
        #expect(PhotosLibrary.visibleAssets(of: library, keptIn: index) == ["U0"])
        // Another library's listing: none.
        try keep([("U0", false)], of: library, hidden: false, listedAs: "/Other.photoslibrary")
        #expect(PhotosLibrary.visibleAssets(of: library, keptIn: index).isEmpty)
        // The listing reads the mark from what the script writes.
        let listed = try JSONDecoder().decode(PhotosLibrary.Asset.self, from: Data("""
            {"uuid": "U", "path": "/L.photoslibrary/x", "reading": "original", "movie": false, "screenshot": false,
             "title": "", "date": 1, "words": [], "favorite": false, "latitude": null, "longitude": null,
             "place": null, "people": [], "albums": [], "hidden": true}
            """.utf8))
        #expect(listed.hidden == true)
        #expect(PhotosLibrary.script.contains("\"hidden\": bool(photo.hidden)"))
    }

    @Test func onlyPhotosItemsTheListingVouchesForAreSeenMatchedCountedOrRead() throws {
        // A library of three pictures that say "Beach": the first two synced with Photos' facts (Suzy in the first,
        // Katie and the album Secret in the second), the third without any, as in an index just brought up to new
        // facts. Beside them, more files inside the library that say "beach beach" than keyword search keeps matches
        // of (no asset's), and a note outside it.
        let library = folder.appendingPathComponent("Photos Library.photoslibrary")
        let originals = library.appendingPathComponent("originals/F")
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        let uuids = (0..<3).map { _ in UUID().uuidString }
        let paths = uuids.map { originals.appendingPathComponent($0 + ".jpeg").path }
        for path in paths { try Data(path.utf8).write(to: URL(fileURLWithPath: path)) }
        let suzy = PhotosLibrary.Person(uuid: "P-SUZY", name: "Suzy")
        let katie = PhotosLibrary.Person(uuid: "P-KATIE", name: "Katie")
        let secret = PhotosLibrary.Album(uuid: "A-SECRET", title: "Secret")
        let assets = [PhotosLibrary.Asset(uuid: uuids[0], path: paths[0], movie: false, screenshot: false,
                                          title: "IMG_0.JPG", date: 1_700_000_000, words: ["Beach"],
                                          people: [suzy.uuid]),
                      PhotosLibrary.Asset(uuid: uuids[1], path: paths[1], movie: false, screenshot: false,
                                          title: "IMG_1.JPG", date: 1_700_000_001, words: ["Beach"],
                                          people: [katie.uuid], albums: [secret.uuid])]
        let store = try IndexStore(directory: index)
        var options = IndexOptions()
        options.photos = PhotosLibrary.Reader { _, _ in
            PhotosLibrary.Listing(assets: assets, people: [suzy, katie], albums: [secret])
        }
        _ = try Indexer(store: store, options: options, makeEmbedder: { throw WorkerError.notFound("not needed") })
            .sync([library])
        try store.db.transaction {
            let factless = try store.insert(Candidate(path: paths[2], kind: .image, size: 1, mtime: 1, inode: 3,
                                                      device: 1))
            try store.addSegment(file: factless, kind: .ocr, modality: .text, text: "Beach")
            for number in 0..<1_100 {
                let id = try store.insert(Candidate(path: library.path + "/resources/beach \(number).txt", kind: .doc,
                                                    size: 1, mtime: 1, inode: UInt64(1_000 + number), device: 1))
                try store.addSegment(file: id, kind: .chunk, modality: .text, text: "beach beach")
            }
            let note = try store.insert(Candidate(path: "/notes/beach.txt", kind: .doc, size: 1, mtime: 1, inode: 9,
                                                  device: 1))
            try store.addSegment(file: note, kind: .chunk, modality: .text, loc: 1, text: "beach beach")
        }
        // Hidden items were just left out of indexing: the new listing, made without them, doesn't have the second
        // picture, which the index still has until its next sync. The third is listed, though the index has no facts.
        try keep([(uuids[0], nil), (uuids[2], nil)], of: library.path, hidden: false)
        var seen = SearchFilter()
        seen.photosOnly = try store.photosFiles { PhotosLibrary.visibleAssets(of: $0, keptIn: index) }
        #expect(seen.photosOnly == [paths[0], paths[2]])

        // Searched: the library's other files are left out before the best matches are kept, so the pictures are
        // found under the 1,100 that outrank them.
        let searcher = try Searcher(store: store, loadVectors: false)
        func found(_ filter: SearchFilter) throws -> Set<String> {
            Set(try searcher.search("beach", queryVector: nil, filter: filter, limit: 5).map(\.path))
        }
        #expect(try found(seen) == ["/notes/beach.txt", paths[0], paths[2]])
        #expect(try Set(searcher.browse(seen, kinds: [.image], limit: 10).map(\.path)) == [paths[0], paths[2]])
        // Counted, looked up and read only so.
        #expect(try store.counts(keeping: seen) == [.doc: ["pending": 1], .image: ["pending": 2]])
        #expect(try store.file(at: paths[1], keptBy: seen) == nil && store.words(of: paths[1], keptBy: seen) == nil)
        #expect(try store.file(at: paths[0], keptBy: seen)?.path == paths[0])
        let words = try #require(try store.words(of: paths[0], keptBy: seen))
        #expect(words.map(\.segment) == [.photosInfo] && words[0].loc == nil && words[0].text.contains("Beach"))
        // People and albums only from what's seen: Katie and Secret are only on the second picture.
        #expect(try store.photosPeople(keptBy: seen).map(\.name) == ["Suzy"])
        #expect(try store.photosPeople().map(\.name) == ["Katie", "Suzy"])
        #expect(try store.photosAlbums(keptBy: seen).isEmpty && store.photosAlbums().map(\.title) == ["Secret"])

        // No Photos library's file at all, whatever the index knows of it.
        var none = SearchFilter()
        none.photosOnly = []
        #expect(try found(none) == ["/notes/beach.txt"])
        #expect(try store.counts(keeping: none) == [.doc: ["pending": 1]])
        #expect(try store.words(of: "/notes/beach.txt", keptBy: none)
                == [IndexStore.Words(segment: .chunk, loc: 1, locEnd: nil, text: "beach beach")])
        // No listing: none of the library's.
        try FileManager.default.removeItem(at: PhotosLibrary.keptListing(of: library.path, keptIn: index))
        #expect(try store.photosFiles { PhotosLibrary.visibleAssets(of: $0, keptIn: index) }.isEmpty)
        // A kind alone lists what it keeps, newest first.
        #expect(try searcher.browse(SearchFilter(), kinds: [.image], limit: 10).map(\.path).count == 3)
    }

    /// What an AI app may not see bears on nothing it searches, the meaning scale included (`Searcher.meaning`): a
    /// Photos item left out (`photos`) or a picture not rated yet (`SearchFilter.leavingOutSensitive`) neither sets
    /// the averages and the deviation a note's meaning is measured in, nor so decides whether it stands out.
    @Test(arguments: [true, false])
    func whatsLeftOutOfSightDoesntMoveTheMeaningScale(photos: Bool) throws {
        // A note that means what's asked, among 25 that don't: all of them seen.
        let store = try IndexStore(directory: index)
        let query = FakeEmbedder.vector(for: "a zebra crossing a river")
        var inode: UInt64 = 0
        func add(_ path: String, _ kind: FileKind, _ vector: [Float]) throws {
            inode += 1
            let id = try store.insert(Candidate(path: path, kind: kind, size: 1, mtime: 1, inode: inode, device: 1))
            let (segment, modality): (SegmentKind, Modality) = kind == .doc ? (.chunk, .text) : (.image, .image)
            try store.addSegment(file: id, kind: segment, modality: modality, loc: kind == .doc ? 1 : nil,
                                 vector: vector)
            try store.finish(id, state: "done")
        }
        try add("/notes/zebra.txt", .doc, query)
        for number in 0..<25 { try add("/notes/\(number).txt", .doc, FakeEmbedder.vector(for: "note \(number)")) }
        var seen = SearchFilter()
        if photos { seen.photosOnly = [] } else { seen.leavingOutSensitive = .revealing }
        func z(_ filter: SearchFilter) throws -> Double? {
            try Searcher(store: store).search("zebra", queryVector: query, filter: filter)
                .first { $0.path == "/notes/zebra.txt" }?.z
        }
        let before = try #require(try z(seen))
        #expect(try z(SearchFilter()) == before)

        // Then 40 pictures as unlike the query as can be, which the app may not see: a library's, or not rated yet.
        let opposite = query.map { -$0 }
        for number in 0..<40 {
            try add(photos ? "/L.photoslibrary/originals/F/\(UUID().uuidString).jpeg" : "/pictures/\(number).jpg",
                    .image, opposite)
        }
        // The same, but for the last bits of the products, which depend on how many rows are multiplied at once.
        let after = try #require(try z(seen))
        #expect(abs(after - before) < 1e-6)
        // DigUp's own window sees them all, and its scale moves, as before.
        #expect(try #require(try z(SearchFilter())) > before)
    }

    /// Nor does it decide which files match by words, how much of the query each holds, the segment each is shown at,
    /// or their order (`Searcher.search`'s keyword matching): keyword search's own ranking (bm25) weighs a word by how
    /// many of all the index's segments have it, and the files it ranked best were the only ones that counted, so a
    /// word in many files left out made the files the app sees that have it lose to others.
    @Test(arguments: [true, false])
    func whatsLeftOutOfSightDoesntDecideWhatMatchesByWords(photos: Bool) throws {
        // A note that says one word of the query, then 100 that say the other: more than keyword search ranked.
        let store = try IndexStore(directory: index)
        var inode: UInt64 = 0
        func add(_ path: String, _ kind: FileKind, _ text: String) throws {
            inode += 1
            let id = try store.insert(Candidate(path: path, kind: kind, size: 1, mtime: 1, inode: inode, device: 1))
            if kind == .image { try store.addSegment(file: id, kind: .image, modality: .image) }   // not rated yet
            try store.addSegment(file: id, kind: kind == .doc ? .chunk : .ocr, modality: .text, loc: 1, text: text)
            try store.finish(id, state: "done")
        }
        try add("/notes/target.txt", .doc, "quasar")
        for number in 0..<100 { try add("/notes/common-\(number).txt", .doc, "zebra") }
        var seen = SearchFilter()
        if photos { seen.photosOnly = [] } else { seen.leavingOutSensitive = .revealing }
        struct Found: Equatable {
            let path: String, rank: Int?, segment: Int64, excerpt: String?
        }
        func found(_ limit: Int) throws -> [Found] {
            try Searcher(store: store, loadVectors: false)
                .search("quasar zebra", queryVector: nil, filter: seen, limit: limit)
                .map { Found(path: $0.path, rank: $0.keywordRank, segment: $0.segmentID, excerpt: $0.excerpt) }
        }
        let first = try found(1), all = try found(150)
        #expect(first.map(\.path) == ["/notes/target.txt"] && first[0].excerpt == "«quasar»")
        #expect(all.count == 101)   // every file the app sees that holds half the query

        // Then 200 pictures that say the first word, which the app may not see: a library's, or not rated yet.
        for number in 0..<200 {
            try add(photos ? "/L.photoslibrary/originals/F/\(UUID().uuidString).jpeg" : "/pictures/\(number).jpg",
                    .image, "quasar")
        }
        #expect(try found(1) == first)
        #expect(try found(150) == all)
    }

    @Test func anIndexOpenedToReadIsReadAndNeverChanged() throws {
        let index = folder.appendingPathComponent("index")
        let made = try IndexStore(directory: index)
        try made.insert(Candidate(path: "/a.txt", kind: .doc, size: 1, mtime: 1, inode: 1, device: 1))
        let reading = try IndexStore(readingOnly: index)
        #expect(try reading.counts(keeping: SearchFilter()) == [.doc: ["pending": 1]])
        #expect(throws: (any Error).self) {
            try reading.insert(Candidate(path: "/b.txt", kind: .doc, size: 1, mtime: 1, inode: 2, device: 1))
        }
        // None there, or one the app hasn't brought up to date: refused, and left as it was.
        #expect(throws: (any Error).self) { try IndexStore(readingOnly: folder.appendingPathComponent("none")) }
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("none").path))
        let older = folder.appendingPathComponent("older")
        try FileManager.default.createDirectory(at: older, withIntermediateDirectories: true)
        try Database(path: older.appendingPathComponent(IndexStore.mainFile).path).execute("PRAGMA user_version = 4")
        #expect(throws: (any Error).self) { try IndexStore(readingOnly: older) }
        var version: Int64 = 0
        try Database(readingOnly: older.appendingPathComponent(IndexStore.mainFile).path)
            .query("PRAGMA user_version") { version = $0.int(0) }
        #expect(version == 4)
    }

    @Test func anIndexNothingElseHasOpenIsReadAndTheReaderNeverWritesIt() throws {
        let index = folder.appendingPathComponent("index")
        let file = index.appendingPathComponent(IndexStore.mainFile)
        func candidate(_ number: UInt64) -> Candidate {
            Candidate(path: "/\(number).txt", kind: .doc, size: 1, mtime: 1, inode: number, device: 1)
        }
        try IndexStore(directory: index).insert(candidate(1))
        // DigUp quit: its last connection closed, and its write-ahead log and shared memory went with it (as SQLite
        // does on Linux and Windows; macOS's keeps them, so they're taken away here).
        for sidecar in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: file.path + sidecar) }
        let written = try Data(contentsOf: file)
        var reading: IndexStore? = try IndexStore(readingOnly: index)
        #expect(try reading?.counts(keeping: SearchFilter()) == [.doc: ["pending": 1]])
        // The indexing helper comes, writes and goes while it's read: what it wrote is read. Closing last, the reader
        // moves nothing into the file (the helper's writes wait in the log for the next writer).
        try IndexStore(directory: index).insert(candidate(2))
        #expect(try reading?.counts(keeping: SearchFilter()) == [.doc: ["pending": 2]])
        #expect(throws: (any Error).self) { try reading?.insert(candidate(3)) }
        reading = nil
        #expect(try Data(contentsOf: file) == written)
        #expect(try IndexStore(directory: index).counts(keeping: SearchFilter()) == [.doc: ["pending": 2]])
    }

    @Test func theConnectionThatMakesTheLogNeverMovesItIntoTheFileWhateverHappensNext() throws {
        let index = folder.appendingPathComponent("index")
        let file = index.appendingPathComponent(IndexStore.mainFile)
        func candidate(_ number: UInt64) -> Candidate {
            Candidate(path: "/\(number).txt", kind: .doc, size: 1, mtime: 1, inode: number, device: 1)
        }
        try IndexStore(directory: index).insert(candidate(1))
        for sidecar in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: file.path + sidecar) }
        let written = try Data(contentsOf: file)
        // `Database.reader(of:)` with nothing else having the index open: the log maker opens it.
        var maker: Database? = try Database.logMaker(of: file.path)
        // The indexing helper writes and goes: what it wrote waits in the log, since the maker still has it open.
        try IndexStore(directory: index).insert(candidate(2))
        #expect(try Data(contentsOf: file) == written)
        #if !os(Windows)
        // Then the read-only connection meant to take over can't open (made unreadable for the moment)…
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        #expect(throws: (any Error).self) { try Database(readingOnly: file.path) }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        #endif
        // …and the maker closes last: it moves nothing into the file, which the helper's next connection does.
        maker = nil
        #expect(try Data(contentsOf: file) == written)
        #expect(try IndexStore(readingOnly: index).counts(keeping: SearchFilter()) == [.doc: ["pending": 2]])
        #expect(try Data(contentsOf: file) == written)
    }

    @Test func aiAccessIsOffUntilTurnedOn() throws {
        let suite = "DigUpTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(AIAccess(defaults) == AIAccess())
        #expect(AIAccess() == AIAccess(on: false, photos: false, hiddenPhotos: false, code: false, pictures: false))
        let some = AIAccess(on: true, photos: true, hiddenPhotos: false, code: true, pictures: false)
        some.save(to: defaults)
        #expect(AIAccess(defaults) == some)
        #expect(defaults.bool(forKey: AppDefaults.aiAccessOn) && defaults.bool(forKey: AppDefaults.aiAccessCode))
    }

    @Test func eachCallIsALineOfTheLogAndTheLastOnesAreRead() throws {
        #expect(AICall.last(20, in: folder).isEmpty)
        let time = Date(timeIntervalSince1970: 1_792_000_000)
        for number in 0..<25 {
            try AICall.append(AICall(time: time, client: "Claude Code", tool: "search_files", results: number,
                                     refused: number == 24 ? "access off" : nil), in: folder)
        }
        let log = try String(contentsOf: folder.appendingPathComponent(AICall.fileName), encoding: .utf8)
        let lines = log.split(separator: "\n")
        #expect(lines.count == 25)
        // When, which app, which tool, how many, why it was refused: nothing searched for.
        #expect(lines[0] == #"{"client":"Claude Code","results":0,"time":"2026-10-14T17:46:40Z","tool":"search_files"}"#)
        #expect(lines[24].contains(#""refused":"access off""#))
        let last = AICall.last(20, in: folder)
        #expect(last.map(\.results) == Array(5..<25))
        #expect(last.last == AICall(time: time, client: "Claude Code", tool: "search_files", results: 24,
                                    refused: "access off"))
        // A line that can't be read (a write cut short) is passed over.
        let handle = try FileHandle(forWritingTo: folder.appendingPathComponent(AICall.fileName))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"client":"Cod"#.utf8) + Data("\n".utf8))
        try handle.close()
        try AICall.append(AICall(time: time, client: "Codex", tool: "status", results: 1), in: folder)
        #expect(AICall.last(2, in: folder).map(\.client) == ["Claude Code", "Codex"])
    }

    @Test func callsLoggedAtOnceByManyHelpersAreEachALine() throws {
        // Each AI app runs a helper of its own, all writing the one log.
        let calls = 800, folder = self.folder
        DispatchQueue.concurrentPerform(iterations: calls) { number in
            try? AICall.append(AICall(client: "app \(number % 8)", tool: "status", results: number), in: folder)
        }
        let lines = try String(contentsOf: folder.appendingPathComponent(AICall.fileName), encoding: .utf8)
            .split(separator: "\n")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let logged = lines.compactMap { try? decoder.decode(AICall.self, from: Data($0.utf8)) }
        #expect(lines.count == calls && Set(logged.map(\.results)) == Set(0..<calls))
    }

    @Test func myDevicesAreTheCamerasWithTheUsersChanges() {
        let cameras = [IndexStore.PhotosCamera(model: "iPhone 15 Pro", files: 9, fromCamera: 5, unknownOrigin: 1),
                       IndexStore.PhotosCamera(model: "iPhone 12", files: 3, fromCamera: 0, unknownOrigin: 0),
                       IndexStore.PhotosCamera(model: "iPhone Air", files: 2, fromCamera: 2, unknownOrigin: 0)]
        #expect(IndexStore.PhotosCamera.mine(of: cameras, added: [], removed: []) == ["iPhone 15 Pro", "iPhone Air"])
        // Added: one no camera of theirs saved from, and one no picture names (yet); taken off: one that did save.
        #expect(IndexStore.PhotosCamera.mine(of: cameras, added: ["iPhone 12", "iPhone 18"], removed: ["iPhone Air"])
                == ["iPhone 15 Pro", "iPhone 12", "iPhone 18"])
    }

    @Test func whyAResultIsThereIsSaidAsTheAppSaysIt() {
        #expect(MatchDescription.clock(6) == "0:06" && MatchDescription.clock(3723) == "1:02:03")
        #expect(MatchDescription.span(.lines, loc: 12, locEnd: 40) == "lines 12–40")
        #expect(MatchDescription.span(.cells, loc: 3, locEnd: 3) == "cell 3")
        func reason(_ segment: SegmentKind, _ kind: FileKind, loc: Double? = nil, meaning: Bool = true,
                    words: Bool = false, listed: Bool = false, reading: PhotosLibrary.Reading? = nil) -> String {
            MatchDescription.reason(segment, kind: kind, loc: loc, locEnd: nil, meaning: meaning, words: words,
                                    listed: listed, reading: reading)
        }
        #expect(reason(.page, .pdf, loc: 3) == "Matches the text on page 3")
        #expect(reason(.frame, .video, loc: 6) == "Matches the frame at 0:06")
        #expect(reason(.frame, .video, reading: .stills) == "Matches one of Photos' stills of it")
        #expect(reason(.audio, .video, loc: 62) == "Matches the sound at 1:02")
        #expect(reason(.image, .screenshot) == "Matches what's on screen")
        #expect(reason(.photosInfo, .image, meaning: false, words: true) == "Has your words in Photos")
        #expect(reason(.name, .image, meaning: false, listed: true) == "Fits your filters")
        #expect(reason(.name, .doc, meaning: false) == "Matches its name")
    }

    /// A saved search an AI app may not run (`digup mcp`'s `saved`) isn't listed to it either (`list_choices`): one
    /// that uses what the user keeps from AI apps, each by its switch, or names someone or an album it doesn't see,
    /// since its name is made from them. The Sensitive filter is refused by the switch `search_files` asks too.
    @Test func aSavedSearchUsingWhatsKeptFromAIAppsIsntTheirs() throws {
        let suzy = SavedSearch.Person(name: "Suzy", photos: [PhotosID(library: "/L.photoslibrary", uuid: "P-SUZY")])
        let seen = [IndexStore.PhotosPerson(id: 1, library: "/L.photoslibrary", uuid: "P-SUZY", name: "Suzy", files: 1)]
        let photos = AIAccess(on: true, photos: true)
        func withheld(_ search: SavedSearch, _ access: AIAccess) -> SavedSearch.Withheld? {
            search.withheld(from: access, people: seen, albums: [])
        }
        typealias Search = SavedSearchTests
        // Photos for its people, albums, Photos' favorites and From; pictures rated sensitive; code.
        for filters: [SavedSearch.Filter] in [[.person(suzy)], [.photosFavorites], [.from(.mine)], [.from(.imported)]] {
            #expect(withheld(Search.search(filters), AIAccess(on: true)) == .use(.photos))
            #expect(withheld(Search.search(filters), photos) == nil)
        }
        #expect(withheld(Search.search([.sensitive]), photos) == .use(.sensitive) && !photos.allows(.sensitive))
        let sensitive = AIAccess(on: true, sensitive: true)
        #expect(withheld(Search.search([.sensitive]), sensitive) == nil && sensitive.allows(.sensitive))
        #expect(withheld(Search.search(query: "code: retry"), photos) == .use(.code))
        #expect(withheld(Search.search(query: "", kind: .code), photos) == .use(.code))
        #expect(withheld(Search.search(query: "", kind: .code), AIAccess(on: true, code: true)) == nil)
        // Nothing kept from it: its own.
        let short = try #require(SearchFilter.Length(under: 15))
        #expect(withheld(Search.search([.digupFavorites, .length(short), .shape(.wide)]), AIAccess(on: true)) == nil)
    }

    /// `list_choices`: the people, albums and devices an AI app is told of are only those of what it sees, counted by
    /// what it sees; a saved search naming someone or an album it doesn't see isn't its own.
    @Test func anAIAppIsToldOnlyOfThePeopleAlbumsAndDevicesOfWhatItSees() throws {
        // A library of two pictures shot on two phones: the first of Suzy, in the album Trip and in a second album of
        // that title; the second, hidden, of Suzy and Katie, in the album Secret and in the second Trip.
        let library = folder.appendingPathComponent("Photos Library.photoslibrary")
        let originals = library.appendingPathComponent("originals/F")
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        let uuids = (0..<2).map { _ in UUID().uuidString }   // a library's file is named for its asset's uuid
        let paths = uuids.map { originals.appendingPathComponent($0 + ".jpeg").path }
        for path in paths { try Data(path.utf8).write(to: URL(fileURLWithPath: path)) }
        let suzy = PhotosLibrary.Person(uuid: "P-SUZY", name: "Suzy")
        let katie = PhotosLibrary.Person(uuid: "P-KATIE", name: "Katie")
        let trip = PhotosLibrary.Album(uuid: "A-TRIP", title: "Trip")
        let otherTrip = PhotosLibrary.Album(uuid: "A-TRIP-2", title: "Trip")
        let secret = PhotosLibrary.Album(uuid: "A-SECRET", title: "Secret")
        let assets = [PhotosLibrary.Asset(uuid: uuids[0], path: paths[0], movie: false, screenshot: false,
                                          title: "IMG_0.JPG", date: 1_700_000_000, words: [], people: [suzy.uuid],
                                          albums: [trip.uuid, otherTrip.uuid], importedBy: 1, camera: "iPhone 15 Pro"),
                      PhotosLibrary.Asset(uuid: uuids[1], path: paths[1], movie: false, screenshot: false,
                                          title: "IMG_1.JPG", date: 1_700_000_001, words: [],
                                          people: [suzy.uuid, katie.uuid], albums: [secret.uuid, otherTrip.uuid],
                                          importedBy: 1, camera: "iPhone Air", hidden: true)]
        let store = try IndexStore(directory: index)
        var options = IndexOptions()
        options.photos = PhotosLibrary.Reader { _, _ in
            PhotosLibrary.Listing(assets: assets, people: [suzy, katie], albums: [trip, otherTrip, secret])
        }
        _ = try Indexer(store: store, options: options, makeEmbedder: { throw WorkerError.notFound("not needed") })
            .sync([library])
        try keep([(uuids[0], false), (uuids[1], true)], of: library.path, hidden: true)
        var seen = SearchFilter()
        seen.photosOnly = try store.photosFiles { PhotosLibrary.visibleAssets(of: $0, keptIn: index) }
        #expect(seen.photosOnly == [paths[0]])

        // People: Suzy alone, in the one picture it sees. DigUp's window has Katie too, and Suzy in both.
        func named(_ filter: SearchFilter) throws -> [String] {
            try store.photosNames(keptBy: filter).map { "\($0.name) \($0.files)" }
        }
        #expect(try named(seen) == ["Suzy 1"])
        #expect(try named(SearchFilter()) == ["Katie 1", "Suzy 2"])
        // Albums: Trip alone, one choice for both albums of the title, its picture in both counted once. DigUp's window
        // has Secret too, and Trip's two pictures.
        func albumed(_ filter: SearchFilter) throws -> [String] {
            try store.photosAlbumChoices(keptBy: filter).map { "\($0.title) \($0.folders) \($0.files)" }
        }
        #expect(try albumed(seen) == ["Trip [] 1"])
        #expect(try albumed(SearchFilter()) == ["Secret [] 1", "Trip [] 2"])
        let albums = try store.photosAlbums(keptBy: seen)
        // The devices "mine" covers, by the rule over what it sees: the one whose camera saved what it sees, not the one
        // that saved only the hidden picture, which "mine" has for DigUp's window. One the user added is theirs whatever
        // took it: the one that took only the hidden picture as much as one that took nothing indexed, so the hidden
        // picture shows in nothing it's told.
        #expect(try store.myDevices(added: [], removed: [], keptBy: seen) == ["iPhone 15 Pro"])
        #expect(try store.myDevices(added: [], removed: []) == ["iPhone 15 Pro", "iPhone Air"])
        #expect(try store.myDevices(added: ["iPhone Air", "iPhone 18"], removed: [], keptBy: seen)
                == ["iPhone 15 Pro", "iPhone Air", "iPhone 18"])
        // Saved searches: one of Suzy in Trip is its own; one naming Katie, or Secret, isn't.
        let people = try store.photosPeople(keptBy: seen)
        func person(_ who: PhotosLibrary.Person) -> SavedSearch.Filter {
            .person(.init(name: who.name, photos: [PhotosID(library: library.path, uuid: who.uuid)]))
        }
        func album(_ which: PhotosLibrary.Album) -> SavedSearch.Filter {
            .album(.init(title: which.title, folders: [], photos: [PhotosID(library: library.path, uuid: which.uuid)]))
        }
        func withheld(_ filters: [SavedSearch.Filter], _ access: AIAccess = AIAccess(on: true, photos: true),
                      people: [IndexStore.PhotosPerson], albums: [IndexStore.PhotosAlbum]) -> SavedSearch.Withheld? {
            SavedSearchTests.search(filters).withheld(from: access, people: people, albums: albums)
        }
        #expect(withheld([person(suzy), album(trip)], people: people, albums: albums) == nil)
        #expect(withheld([person(katie)], people: people, albums: albums) == .outOfSight)
        #expect(withheld([album(trip), album(secret)], people: people, albums: albums) == .outOfSight)
        // Hidden items allowed, she's in sight.
        #expect(withheld([person(katie)], AIAccess(on: true, photos: true, hiddenPhotos: true),
                         people: try store.photosPeople(), albums: try store.photosAlbums()) == nil)
    }

    #if canImport(ImageIO)
    /// A person's count for an AI app has their pictures outside Photos, by the faces it may see
    /// (`IndexStore.photosNames(keptBy:)`, as `search_files`' `people` keeps them).
    @Test func aPersonsCountForAnAIAppHasTheirFacesOutsidePhotosItSees() throws {
        let faces = FaceIndexTests()
        let more: [String: [[Float]]] = ["like-katie-85.jpg": [[0.7, 0, 0, 0.714]]]
        let indexed = try faces.indexed(by: faces.reader(more: more), more: more)
        // katie-85.jpg is Katie, the user said, which teaches: the picture like it is hers too.
        try faces.correct(indexed, [("katie-85.jpg", 0, FaceIndexTests.katie, "is")])
        try indexed.store.rebuildFaceMatches()
        func named(_ filter: SearchFilter) throws -> [String] {
            try indexed.store.photosNames(keptBy: filter).map { "\($0.name) \($0.files)" }
        }
        // Katie: her picture in Photos, and four outside, two by her face, one she was said to be and one it taught.
        // Sam, two people of the name: their pictures in Photos, and two outside with one or the other's face.
        #expect(try named(SearchFilter()) == ["Katie 5", "Sam 4"])
        // The picture that teaches kept from it: neither it nor the one it taught is hers to it.
        let everything = Set(try indexed.store.files(under: [indexed.library.path, indexed.downloads.path]).map(\.path))
        var seen = SearchFilter()
        seen.paths = everything.subtracting([indexed.path("katie-85.jpg")])
        #expect(try named(seen) == ["Katie 3", "Sam 4"])
        // Sam's picture in Photos kept from it: the other Sam is the name's, and the picture outside that's Sam's by
        // his face in that picture is no one's to it.
        seen = SearchFilter()
        seen.photosOnly = [indexed.pictures[0], indexed.pictures[2]]
        #expect(try named(seen) == ["Katie 5", "Sam 2"])
        // No picture in Photos: no one.
        seen.photosOnly = []
        #expect(try named(seen).isEmpty)
    }
    #endif

    /// A recording's moments for an AI app (`digup mcp`'s `moments`) come only from what it sees: a recording kept
    /// from it has none, and what's kept from it doesn't move the scale its moments stand out on. The one its result
    /// is at isn't among the others.
    @Test func aRecordingsMomentsForAnAIAppComeOnlyFromWhatItSees() throws {
        let fixture = MomentsTests()
        let video = "/videos/river.mov"
        let searcher = try fixture.index(video, .video, [
            (.frame, 0.5, 3.5, 1), (.frame, 3.5, 6.5, 0), (.frame, 6.5, 9.5, 0.25), (.frame, 9.5, 12.5, 0),
            (.frame, 12.5, 15.5, 0.9),
        ])
        var seen = SearchFilter()
        seen.photosOnly = []
        func moments(_ path: String, _ filter: SearchFilter, in searcher: Searcher) throws -> [Moment] {
            try searcher.moments(of: path, text: MomentsTests.words, queryVector: MomentsTests.query, filter: filter)
        }
        let before = try moments(video, seen, in: searcher)
        #expect(before.map(\.start) == [0.5, 12.5])
        // Its result is at the best of them; the other is the one left.
        let hit = try #require(try searcher.search(MomentsTests.words, queryVector: MomentsTests.query, filter: seen)
            .first { $0.path == video })
        #expect(before.filter { !$0.holds(hit) }.map(\.start) == [12.5])

        let store = searcher.store
        var inode: UInt64 = 500
        func add(_ path: String, _ kind: FileKind, _ segment: SegmentKind, _ vector: [Float]) throws {
            inode += 1
            let id = try store.insert(Candidate(path: path, kind: kind, size: 1, mtime: 1, inode: inode, device: 1))
            try store.addSegment(file: id, kind: segment, modality: .image, loc: kind == .video ? 0 : nil,
                                 locEnd: kind == .video ? 3 : nil, vector: vector)
        }
        // A library's video like the query, which it may not see: no moments, though the window has one.
        let hidden = "/L.photoslibrary/originals/F/clip.mov"
        try add(hidden, .video, .frame, MomentsTests.query)
        let withVideo = try Searcher(store: store)
        #expect(try moments(hidden, seen, in: withVideo).isEmpty)
        #expect(try moments(hidden, SearchFilter(), in: withVideo).map(\.start) == [0])
        // Then 40 of the library's pictures as unlike the query as can be: the same moments, but for the last bits
        // of the products (rows are multiplied a block at a time).
        for number in 0..<40 {
            try add("/L.photoslibrary/originals/F/\(number).jpeg", .image, .image, MomentsTests.query.map { -$0 })
        }
        let now = try Searcher(store: store)
        let after = try moments(video, seen, in: now)
        #expect(after.map(\.start) == before.map(\.start) && after.map(\.end) == before.map(\.end))
        #expect(zip(after, before).allSatisfy { abs($0.score - $1.score) < 1e-6 })
        // DigUp's own preview sees them all, and its scale moves.
        let window = try #require(try moments(video, SearchFilter(), in: now).first)
        #expect(abs(window.score - before[0].score) > 1e-3)
    }
}
