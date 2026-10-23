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
}
