import Foundation
import Testing
@testable import DigUpKit

/// `media_dimensions` (approved 2026-10-22): a file's size as it's shown and its length, what the Length and Shape
/// filters keep by, how a saved search keeps those two, and how an index made before gets them.
@Suite struct MediaDimensionsTests {
    /// The real path (/private/var/…), as the crawl reports it.
    let folder: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DigUpTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return URL(fileURLWithPath: FolderSelection.realPath(url.path))
    }()

    /// A file of `kind` with that size and length (`file`'s).
    @discardableResult
    func file(_ name: String, _ kind: FileKind, in store: IndexStore, width: Int? = nil, height: Int? = nil,
              seconds: Double? = nil) throws -> Int64 {
        let id = try store.insert(Candidate(path: "/files/" + name, kind: kind, size: 1, mtime: 1, inode: 1, device: 1))
        let dimensions = try #require(MediaDimensions(width: width, height: height, duration: seconds, source: .file))
        try store.setDimensions(dimensions, of: id)
        return id
    }

    /// The names of the files `filter` keeps, with no words.
    func kept(_ filter: SearchFilter, in store: IndexStore) throws -> Set<String> {
        Set(try Searcher(store: store, loadVectors: false).search("", queryVector: nil, filter: filter, limit: 100)
            .map { ($0.path as NSString).lastPathComponent })
    }

    @Test func theTableKeepsASizeAndALengthOnlyAsTheyreKnown() throws {
        let store = try IndexStore(directory: folder)
        let id = try store.insert(Candidate(path: "/files/a.jpg", kind: .image, size: 1, mtime: 1, inode: 1, device: 1))
        func row(_ width: String, _ height: String, _ duration: String, _ source: String) -> Bool {
            (try? store.db.execute("""
                INSERT OR REPLACE INTO media_dimensions(file, width, height, duration, source)
                VALUES(\(id), \(width), \(height), \(duration), \(source))
                """)) != nil
        }
        #expect(row("4032", "3024", "NULL", "'file'"))       // a picture
        #expect(row("1920", "1080", "12.5", "'photos'"))     // a video
        #expect(row("NULL", "NULL", "0", "'file'"))          // a recording, however short
        #expect(!row("4032", "NULL", "NULL", "'file'"))      // a side without the other
        #expect(!row("NULL", "3024", "12.5", "'file'"))
        #expect(!row("0", "3024", "NULL", "'file'"))         // no side of 0
        #expect(!row("4032", "-1", "NULL", "'file'"))
        #expect(!row("NULL", "NULL", "-0.5", "'file'"))      // no length below 0
        #expect(!row("NULL", "NULL", "NULL", "'file'"))      // nothing known: no row
        #expect(!row("4032", "3024", "NULL", "'exif'"))      // who said so: Photos or the file
        // What the index takes from what's read: a size with both sides, a length of seconds.
        #expect(MediaDimensions(width: 0, height: 0, duration: nil, source: .file) == nil)
        #expect(MediaDimensions(width: 640, height: nil, duration: 3, source: .file)
            == MediaDimensions(width: nil, height: nil, duration: 3, source: .file))
        #expect(MediaDimensions(width: 640, height: 480, duration: .nan, source: .file)?.duration == nil)
        #expect(MediaDimensions(width: nil, height: nil, duration: .infinity, source: .file) == nil)
    }

    @Test func anIndexFromBeforeGetsTheTableAndKeepsWhatItHad() throws {
        // As fork step 3 left an index: everything but this table, a picture's location among it.
        let index = folder.appendingPathComponent("index")
        let first = try IndexStore(directory: index)
        let id = try first.insert(Candidate(path: "/files/a.jpg", kind: .image, size: 1, mtime: 1, inode: 1, device: 1))
        try first.setLocation(try #require(Location(latitude: 25.79, longitude: -80.13, source: .exif)), of: id)
        try first.db.execute("DROP TABLE media_dimensions; UPDATE meta SET value = '3' WHERE key = 'fork_photos_facts';")
        let store = try IndexStore(directory: index)
        var columns: [String] = [], version: Int64 = 0
        try store.db.query("SELECT name FROM pragma_table_info('media_dimensions')") { columns.append($0.text(0) ?? "") }
        try store.db.query("PRAGMA user_version") { version = $0.int(0) }
        #expect(columns == ["file", "width", "height", "duration", "source"])
        #expect(try store.meta("fork_photos_facts") == "4" && version == 5)
        #expect(try store.locations(of: ["/files/a.jpg"]).count == 1)
    }

    @Test func lengthKeepsVideosAndRecordingsAtItsBucketsEdges() throws {
        let store = try IndexStore(directory: folder)
        for seconds in [14.99, 15, 59.99, 60, 299.99, 300, 3600] {
            try file("\(seconds).mov", .video, in: store, width: 1920, height: 1080, seconds: seconds)
        }
        try file("voice.m4a", .audio, in: store, seconds: 8)
        try file("photo.jpg", .image, in: store, width: 4032, height: 3024)   // no length: never kept
        func length(_ atLeast: Double?, _ under: Double?) throws -> Set<String> {
            try kept(SearchFilter(length: try #require(SearchFilter.Length(atLeast: atLeast, under: under))), in: store)
        }
        #expect(SearchFilter.Length.buckets.map(\.text) == ["..15", "15..60", "60..300", "300.."])
        #expect(try length(nil, 15) == ["14.99.mov", "voice.m4a"])
        #expect(try length(15, 60) == ["15.0.mov", "59.99.mov"])
        #expect(try length(60, 300) == ["60.0.mov", "299.99.mov"])
        #expect(try length(300, nil) == ["300.0.mov", "3600.0.mov"])
    }

    @Test func shapeKeepsPicturesAndVideosAtItsTolerancesEdges() throws {
        let store = try IndexStore(directory: folder)
        let sizes = [(1000, 1000), (1000, 1050), (1000, 1051), (1051, 1000), (1920, 1080), (1080, 1920), (1920, 1059),
                     (1920, 1058), (1920, 1100), (1920, 1110), (1100, 1920), (2000, 1000), (1999, 1000), (4032, 3024),
                     (3024, 4032)]
        for (width, height) in sizes { try file("\(width)x\(height).jpg", .image, in: store, width: width, height: height) }
        try file("talk.m4a", .audio, in: store, seconds: 30)   // no size: never kept
        func shape(_ text: String) throws -> Set<String> {
            try kept(SearchFilter(shape: try #require(SearchFilter.Shape(text))), in: store)
        }
        // Square: sides within 5 % (1050 is 5 % more than 1000, 1051 a little more), apart from portrait and landscape.
        #expect(try shape("square") == ["1000x1000.jpg", "1000x1050.jpg"])
        #expect(try shape("portrait") == ["1000x1051.jpg", "1080x1920.jpg", "1100x1920.jpg", "3024x4032.jpg"])
        #expect(try shape("landscape") == ["1051x1000.jpg", "1920x1080.jpg", "1920x1059.jpg", "1920x1058.jpg",
                                           "1920x1100.jpg", "1920x1110.jpg", "2000x1000.jpg", "1999x1000.jpg",
                                           "4032x3024.jpg"])
        // Wide: 2:1 or wider, among landscape.
        #expect(try shape("wide") == ["2000x1000.jpg"])
        // An exact ratio within 2 % either way (16:9 is 1.778: from 1.743 to 1.813), its orientation included: a
        // picture and the same picture turned match 16:9 and 9:16 alike.
        #expect(try shape("16:9") == ["1920x1080.jpg", "1920x1059.jpg", "1920x1100.jpg"])
        #expect(try shape("9:16") == ["1080x1920.jpg", "1100x1920.jpg"])
        #expect(try shape("4:3") == ["4032x3024.jpg"])
        #expect(try shape("3:4") == ["3024x4032.jpg"])
        #expect(try shape("3:2").isEmpty)
    }

    @Test func lengthAndShapeCombineWithEachOtherAndWithWords() throws {
        let store = try IndexStore(directory: folder)
        let short = try file("short.mov", .video, in: store, width: 1920, height: 1080, seconds: 12)
        let tall = try file("tall.mov", .video, in: store, width: 1080, height: 1920, seconds: 12)
        try file("long.mov", .video, in: store, width: 1920, height: 1080, seconds: 400)
        for id in [short, tall] { try store.addSegment(file: id, kind: .speech, modality: .text, text: "the beach") }
        let under15 = SearchFilter.Length(under: 15), wide = SearchFilter.Shape.ratio(width: 16, height: 9)
        #expect(try kept(SearchFilter(length: under15, shape: wide), in: store) == ["short.mov"])
        #expect(try kept(SearchFilter(length: under15), in: store) == ["short.mov", "tall.mov"])
        let found = try Searcher(store: store, loadVectors: false).search("beach", queryVector: nil,
                                                                           filter: SearchFilter(shape: .portrait))
        #expect(found.map { ($0.path as NSString).lastPathComponent } == ["tall.mov"])
        #expect(!SearchFilter(shape: .square).isEmpty && !SearchFilter(length: under15).isEmpty)
    }

    @Test func aSavedSearchsLengthAndShapeComeBackAsTheyWereAndBadOnesAreRefused() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        func written<T: Encodable>(_ value: T) throws -> String { String(decoding: try encoder.encode(value), as: UTF8.self) }
        func read<T: Decodable>(_ type: T.Type, _ json: String) -> T? {
            try? JSONDecoder().decode(type, from: Data(json.utf8))
        }
        // As saved-searches.json keeps them (approved): seconds, an open bound left out; a shape's name or W:H.
        #expect(try written(try #require(SearchFilter.Length(atLeast: 15, under: 60))) == #"{"atLeast":15,"under":60}"#)
        #expect(try written(try #require(SearchFilter.Length(under: 15))) == #"{"under":15}"#)
        #expect(try written(try #require(SearchFilter.Length(atLeast: 300))) == #"{"atLeast":300}"#)
        #expect(try written([SearchFilter.Shape.portrait, .ratio(width: 9, height: 16)]) == #"["portrait","9:16"]"#)
        for length in SearchFilter.Length.buckets + [try #require(SearchFilter.Length(atLeast: 7.5, under: 20))] {
            #expect(read(SearchFilter.Length.self, try written(length)) == length)
        }
        for shape in [SearchFilter.Shape.portrait, .landscape, .square, .wide] + SearchFilter.Shape.ratios {
            #expect(read(SearchFilter.Shape.self, try written(shape)) == shape)
        }
        // Not the shape: no bound, bounds the wrong way round or below 0, a bound that's null or not a number,
        // another key; a shape that isn't one of the four or W:H in whole numbers from 1 to 99, written plainly.
        for bad in ["{}", #"{"atLeast": 60, "under": 15}"#, #"{"atLeast": 15, "under": 15}"#, #"{"atLeast": -1}"#,
                    #"{"under": 0}"#, #"{"atLeast": null}"#, #"{"atLeast": "15"}"#, #"{"atLeast": true}"#,
                    #"{"atLeast": 15, "over": 60}"#, #"{"at_least": 15}"#, "15", #"[15, 60]"#, #"{"under": 1e30}"#,
                    #"{"atLeast": 315360001}"#] {
            #expect(read(SearchFilter.Length.self, bad) == nil, "\(bad)")
        }
        for bad in [#""Portrait""#, #""tall""#, #""0:9""#, #""16:0""#, #""100:1""#, #""16:09""#, #""+16:9""#,
                    #""16:9:1""#, #""16""#, #""16.5:9""#, #"":9""#, "16", "null", #"{"shape": "wide"}"#] {
            #expect(read(SearchFilter.Shape.self, bad) == nil, "\(bad)")
        }
    }

    @Test func lengthAndShapeAreWrittenAsTheCLITakesThem() {
        #expect(SearchFilter.Length("15..60") == SearchFilter.Length(atLeast: 15, under: 60))
        #expect(SearchFilter.Length("..15") == SearchFilter.Length(under: 15))
        #expect(SearchFilter.Length("300..") == SearchFilter.Length(atLeast: 300))
        #expect(SearchFilter.Length("7.5..20")?.text == "7.5..20")
        for bad in ["15", "..", "60..15", "-5..10", "a..b", "15..60..90", "nan..", "..inf", "", "..1e30",
                    "315360001.."] {
            #expect(SearchFilter.Length(bad) == nil, "\(bad)")
        }
        #expect(SearchFilter.Shape("16:9") == .ratio(width: 16, height: 9))
        #expect(SearchFilter.Shape("99:1") == .ratio(width: 99, height: 1))
        #expect(SearchFilter.Shape("wide") == .wide)
    }

    /// A length's bounds go up to ten years: any longer is no recording's, and a number that big can't be said in
    /// seconds and minutes (a saved search's token says it so).
    @Test func aLengthsBoundsAreAtMostTenYears() {
        let longest = SearchFilter.Length.longest
        #expect(longest == 10 * 365 * 24 * 60 * 60)
        #expect(SearchFilter.Length(under: longest)?.under == longest)
        #expect(SearchFilter.Length(atLeast: longest)?.atLeast == longest)
        for bad in [longest.nextUp, longest + 1, 1e30, .greatestFiniteMagnitude] {
            #expect(SearchFilter.Length(under: bad) == nil && SearchFilter.Length(atLeast: bad) == nil)
            #expect(SearchFilter.Length(atLeast: 15, under: bad) == nil)
        }
        #expect(SearchFilter.Length("..315360000")?.text == "..315360000")
    }

    #if canImport(ImageIO) && canImport(AVFoundation)
    /// Written for these tests: a picture stored turned (orientation 6, 400 × 240 as stored), a video stored turned
    /// (320 × 192 as stored, two seconds), and a second of silence as a recording.
    func media(in folder: URL) throws -> (picture: URL, video: URL, recording: URL) {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let picture = folder.appendingPathComponent("turned.jpg"), video = folder.appendingPathComponent("turned.mp4")
        let recording = folder.appendingPathComponent("quiet.wav")
        try FileManager.default.copyItem(at: ImageTests.pictures.appendingPathComponent("pattern-o6.jpg"), to: picture)
        try FileManager.default.copyItem(at: VideoTests.turned, to: video)
        try AudioExtractor.writeWAV(ArraySlice(repeating: 0, count: Int(AudioExtractor.sampleRate)), to: recording)
        return (picture, video, recording)
    }

    /// A file's row as the index keeps it, "width height duration source" ("-" for none, the duration to a tenth).
    func row(of path: URL, in store: IndexStore) throws -> String? {
        var row: String?
        try store.db.query("""
            SELECT m.width, m.height, m.duration, m.source FROM media_dimensions m JOIN files f ON f.id = m.file
            WHERE f.path = ?
            """, [.text(path.path)]) { found in
            row = [found.isNull(0) ? "-" : "\(found.int(0))", found.isNull(1) ? "-" : "\(found.int(1))",
                   found.isNull(2) ? "-" : String(format: "%.1f", found.double(2)), found.text(3) ?? ""]
                .joined(separator: " ")
        }
        return row
    }

    @Test func filesReadBeforeGetTheirSizeAndLengthOnceFromTheirMetadata() throws {
        // As an index from before sizes and lengths were kept has them: read, with no row.
        let store = try IndexStore(directory: folder.appendingPathComponent("index"))
        let here = folder.appendingPathComponent("here"), aside = folder.appendingPathComponent("aside")
        let (picture, video, recording) = try media(in: here)
        let library = folder.appendingPathComponent("L.photoslibrary/originals/F")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let asset = library.appendingPathComponent("FC37DBA6-CF22-4E3E-AB70-755587454608.jpeg")
        let away = here.appendingPathComponent("away.jpg"), icon = here.appendingPathComponent("icon.jpg")
        for url in [asset, away, icon] { try FileManager.default.copyItem(at: picture, to: url) }
        var ids: [URL: Int64] = [:]
        for (inode, (url, kind, state)) in [(picture, FileKind.image, "done"), (video, .video, "done"),
                                            (recording, .audio, "skipped"), (asset, .image, "done"),
                                            (away, .image, "done"), (icon, .image, "skipped")].enumerated() {
            ids[url] = try store.insert(Candidate(path: url.path, kind: kind, size: 1, mtime: 1, inode: UInt64(inode),
                                                  device: 1))
            try store.finish(try #require(ids[url]), state: state)
        }
        try FileManager.default.createDirectory(at: aside, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: away, to: aside.appendingPathComponent("away.jpg"))   // away for now

        // The picture as it's shown, the video's size and length, and a recording left out as silent has a length
        // too. Not a library's picture (Photos' size, the sync's), nor a picture too small to have been read.
        #expect(try store.measureOnce() == 3)
        #expect(try row(of: picture, in: store) == "240 400 - file")
        #expect(try row(of: video, in: store) == "192 320 2.0 file")
        #expect(try row(of: recording, in: store) == "- - 1.0 file")
        #expect(try row(of: asset, in: store) == nil && row(of: icon, in: store) == nil)
        // The one away waits, and nothing else is looked at again; back, it gets its size, and nothing waits.
        #expect(try store.meta(IndexStore.dimensionsReadKey) == "[\(try #require(ids[away]))]")
        #expect(try store.measureOnce() == 0)
        try FileManager.default.moveItem(at: aside.appendingPathComponent("away.jpg"), to: away)
        #expect(try store.measureOnce() == 1)
        #expect(try row(of: away, in: store) == "240 400 - file")
        #expect(try store.meta(IndexStore.dimensionsReadKey) == IndexStore.allReadOnce)
        #expect(try store.measureOnce() == 0)
    }

    @Test func aFilesOwnSizeAndLengthAreAsItsShownAndGoWhenItsReadAgain() throws {
        let pictures = folder.appendingPathComponent("pictures")
        let (picture, video, _) = try media(in: pictures)
        let store = try IndexStore(directory: folder.appendingPathComponent("index"))
        let indexer = try Indexer(store: store, options: IndexOptions(), makeEmbedder: { FakeEmbedder() })
        _ = try indexer.sync([pictures])
        _ = try indexer.run()
        #expect(try row(of: picture, in: store) == "240 400 - file")   // turned the way the camera held it
        #expect(try row(of: video, in: store) == "192 320 2.0 file")
        // The picture changed: what was read from it goes, its size with it, until it's read again.
        try ImageTests.writeJPEG(picture)   // 400 × 300, not turned
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)],
                                              ofItemAtPath: picture.path)
        #expect(try indexer.sync([pictures]).changed == 1)
        #expect(try row(of: picture, in: store) == nil)
        _ = try indexer.run()
        #expect(try row(of: picture, in: store) == "400 300 - file")
        // Everything read again (a new model): the same, from reading it.
        try store.resetAll()
        #expect(try row(of: video, in: store) == nil)
        _ = try indexer.run()
        #expect(try row(of: video, in: store) == "192 320 2.0 file")
    }
    #endif
}
