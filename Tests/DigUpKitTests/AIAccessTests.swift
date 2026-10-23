import Foundation
import Testing
@testable import DigUpKit

/// What `digup mcp` lets AI apps see (`AIAccess`, and `SearchFilter`'s parts that keep things from them), the index it
/// opens only to read, what it logs, and how it says why a result is there.
@Suite struct AIAccessTests {
    let folder: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DigUpTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return URL(fileURLWithPath: FolderSelection.realPath(url.path))
    }()

    /// A library of two pictures that say "Beach" (as `PhotosLibraryTests.library` lays one out), indexed beside more
    /// notes saying "beach beach" than keyword search keeps matches of.
    func indexed() throws -> (store: IndexStore, library: URL, assets: [PhotosLibrary.Asset]) {
        let library = folder.appendingPathComponent("Photos Library.photoslibrary")
        let originals = library.appendingPathComponent("originals/F")
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        let assets = try (0..<2).map { number in
            let uuid = UUID().uuidString
            let file = originals.appendingPathComponent(uuid + ".jpeg")
            try Data("picture \(number)".utf8).write(to: file)
            return PhotosLibrary.Asset(uuid: uuid, path: file.path, movie: false, screenshot: false,
                                       title: "IMG_\(number).JPG", date: 1_700_000_000 + Double(number),
                                       words: ["Beach"])
        }
        let store = try IndexStore(directory: folder.appendingPathComponent("index"))
        var options = IndexOptions()
        options.photos = PhotosLibrary.Reader { _, _ in PhotosLibrary.Listing(assets: assets) }
        _ = try Indexer(store: store, options: options, makeEmbedder: { throw WorkerError.notFound("not needed") })
            .sync([library])
        try store.db.transaction {
            for number in 0..<1_100 {
                let id = try store.insert(Candidate(path: "/notes/beach \(number).txt", kind: .doc, size: 1, mtime: 1,
                                                    inode: UInt64(1_000 + number), device: 1))
                try store.addSegment(file: id, kind: .chunk, modality: .text, loc: 1, text: "beach beach")
            }
        }
        return (store, library, assets)
    }

    @Test func whatAIAppsMayNotSeeIsLeftOutBeforeAnythingIsMatchedCountedOrCut() throws {
        let (store, library, assets) = try indexed()
        let searcher = try Searcher(store: store, loadVectors: false)
        func found(_ filter: SearchFilter, limit: Int = 5) throws -> [String] {
            try searcher.search("beach", queryVector: nil, filter: filter, limit: limit).map(\.path)
        }
        // The notes outrank Photos' words, and there are more of them than keyword search keeps: the pictures are
        // found only because the notes were left out first.
        #expect(try found(SearchFilter()).allSatisfy { $0.hasPrefix("/notes/") })
        var noNotes = SearchFilter()
        noNotes.withoutFolders = ["/notes"]
        #expect(try Set(found(noNotes)) == Set(assets.map(\.path)))
        noNotes.withoutPaths = [assets[0].path]
        #expect(try found(noNotes) == [assets[1].path])
        #expect(try found(noNotes, limit: 1) == [assets[1].path])
        // No Photos library's file at all.
        var noPhotos = SearchFilter()
        noPhotos.photosLibraries = false
        #expect(try found(noPhotos, limit: 50).count == 50)
        #expect(try found(noPhotos, limit: 50).allSatisfy { !$0.contains(".photoslibrary/") })
        // A Photos filter with no library allowed keeps nothing: not even the list of what it would keep.
        var favorites = noPhotos
        favorites.favorites = true
        #expect(try searcher.search("", queryVector: nil, filter: favorites).isEmpty)

        // Counted only as far as they may be seen.
        #expect(try store.counts(keeping: SearchFilter()) == [.doc: ["pending": 1_100], .image: ["pending": 2]])
        #expect(try store.counts(keeping: noPhotos) == [.doc: ["pending": 1_100]])
        var hidden = SearchFilter()
        hidden.withoutPaths = [assets[0].path]
        #expect(try store.counts(keeping: hidden) == [.doc: ["pending": 1_100], .image: ["pending": 1]])
        var wholeLibrary = SearchFilter()
        wholeLibrary.withoutFolders = [library.path]
        #expect(try store.counts(keeping: wholeLibrary) == [.doc: ["pending": 1_100]])

        // A file, and its words, only when it may be seen.
        #expect(try store.file(at: assets[1].path, keptBy: hidden)?.path == assets[1].path)
        #expect(try store.file(at: assets[0].path, keptBy: hidden) == nil)
        #expect(try store.file(at: "/nowhere.txt", keptBy: SearchFilter()) == nil)
        #expect(try store.words(of: assets[0].path, keptBy: hidden) == nil)
        let photosWords = try #require(try store.words(of: assets[1].path, keptBy: hidden))
        #expect(photosWords.map(\.segment) == [.photosInfo] && photosWords[0].loc == nil)
        #expect(photosWords[0].text.contains("Beach"))
        #expect(try store.words(of: "/notes/beach 7.txt", keptBy: noPhotos)
                == [IndexStore.Words(segment: .chunk, loc: 1, locEnd: nil, text: "beach beach")])
    }

    @Test func hiddenItemsAreToldFromTheLibrarysKeptListing() throws {
        let index = folder.appendingPathComponent("index")
        try FileManager.default.createDirectory(at: index.appendingPathComponent("photos"),
                                                withIntermediateDirectories: true)
        let library = "/L.photoslibrary"
        func keep(hidden: Bool, flags: [Bool?], for listed: String = library) throws {
            let assets = flags.enumerated().map { number, flag in
                PhotosLibrary.Asset(uuid: "U\(number)", path: "\(listed)/originals/U\(number).jpeg", movie: false,
                                    screenshot: false, title: "", date: 0, words: [], hidden: flag)
            }
            let kept = PhotosLibrary.Kept(library: listed, hidden: hidden, listedAt: 0,
                                          state: PhotosLibrary.State(pictures: "", database: ""),
                                          listing: PhotosLibrary.Listing(assets: assets))
            try JSONEncoder().encode(kept).write(to: PhotosLibrary.keptListing(of: library, keptIn: index))
        }
        // None kept: can't tell.
        #expect(PhotosLibrary.hiddenAssets(of: library, keptIn: index) == nil)
        // Listed with what's hidden: those.
        try keep(hidden: true, flags: [false, true, false])
        #expect(PhotosLibrary.hiddenAssets(of: library, keptIn: index) == ["U1"])
        // Listed without them: none.
        try keep(hidden: false, flags: [false, false])
        #expect(PhotosLibrary.hiddenAssets(of: library, keptIn: index) == [])
        // From before DigUp recorded it (no flag on an asset), or another library's: can't tell.
        try keep(hidden: true, flags: [false, nil])
        #expect(PhotosLibrary.hiddenAssets(of: library, keptIn: index) == nil)
        try keep(hidden: true, flags: [true], for: "/Other.photoslibrary")
        #expect(PhotosLibrary.hiddenAssets(of: library, keptIn: index) == nil)
        // The listing reads the flag from what the script writes.
        let listed = try JSONDecoder().decode(PhotosLibrary.Asset.self, from: Data("""
            {"uuid": "U", "path": "/L.photoslibrary/x", "reading": "original", "movie": false, "screenshot": false,
             "title": "", "date": 1, "words": [], "favorite": false, "latitude": null, "longitude": null,
             "place": null, "people": [], "albums": [], "hidden": true}
            """.utf8))
        #expect(listed.hidden == true)
        #expect(PhotosLibrary.script.contains("\"hidden\": bool(photo.hidden)"))
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
