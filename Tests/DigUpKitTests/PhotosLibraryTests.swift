import Foundation
import Testing
@testable import DigUpKit

/// Photos libraries through a reader that lists them as osxphotos would (`PhotosLibrary.Reader`): no osxphotos, no
/// Photos, no model.
@Suite struct PhotosLibraryTests {
    /// The real path (/private/var/…), as the crawl reports it.
    let folder: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DigUpTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return URL(fileURLWithPath: FolderSelection.realPath(url.path))
    }()

    /// A library laid out as Photos lays it out, in `parent`: `count` originals in one folder (originals/F), and its
    /// database, which isn't a picture. Returns the library and its assets as a listing names them.
    func library(_ count: Int, in parent: URL) throws -> (URL, [PhotosLibrary.Asset]) {
        let library = parent.appendingPathComponent("Photos Library.photoslibrary")
        let originals = library.appendingPathComponent("originals/F")
        let database = library.appendingPathComponent("database")
        for folder in [originals, database] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try Data("SQLite format 3".utf8).write(to: database.appendingPathComponent("Photos.sqlite"))
        let assets = try (0..<count).map { number in
            let uuid = UUID().uuidString
            let file = originals.appendingPathComponent(uuid + ".jpeg")
            try Data("picture \(number)".utf8).write(to: file)
            return PhotosLibrary.Asset(uuid: uuid, path: file.path, movie: false, screenshot: false,
                                       title: "IMG_\(1000 + number).JPG", date: 1_700_000_000 + Double(number),
                                       words: ["IMG_\(1000 + number).JPG", "Beach"])
        }
        return (library, assets)
    }

    func indexer(_ store: IndexStore, reading listing: @escaping @Sendable (String) throws -> PhotosLibrary.Listing)
        throws -> Indexer {
        var options = IndexOptions()
        options.photos = PhotosLibrary.Reader(list: listing)
        return try Indexer(store: store, options: options,
                           makeEmbedder: { throw WorkerError.notFound("no model needed to sync") })
    }

    /// The same asset with other words.
    func asset(_ asset: PhotosLibrary.Asset, title: String? = nil, words: [String]) -> PhotosLibrary.Asset {
        PhotosLibrary.Asset(uuid: asset.uuid, path: asset.path, movie: asset.movie, screenshot: asset.screenshot,
                            title: title ?? asset.title, date: asset.date, words: words)
    }

    /// The same asset with what else Photos says about it: a favorite, where it was taken, who's in it, its albums.
    func asset(_ asset: PhotosLibrary.Asset, favorite: Bool = false, at point: (Double, Double)? = nil,
               place: String? = nil, people: [PhotosLibrary.Person] = [], albums: [PhotosLibrary.Album] = [])
        -> PhotosLibrary.Asset {
        PhotosLibrary.Asset(uuid: asset.uuid, path: asset.path, movie: asset.movie, screenshot: asset.screenshot,
                            title: asset.title, date: asset.date, words: asset.words, favorite: favorite,
                            latitude: point?.0, longitude: point?.1, place: place, people: people.map(\.uuid),
                            albums: albums.map(\.uuid))
    }

    /// The same asset, its file in `library` instead of in `old` (the library renamed or moved).
    func asset(_ asset: PhotosLibrary.Asset, movedFrom old: String, to library: String) -> PhotosLibrary.Asset {
        PhotosLibrary.Asset(uuid: asset.uuid, path: library + asset.path.dropFirst(old.count), movie: asset.movie,
                            screenshot: asset.screenshot, title: asset.title, date: asset.date, words: asset.words,
                            favorite: asset.favorite, latitude: asset.latitude, longitude: asset.longitude,
                            place: asset.place, people: asset.people, albums: asset.albums)
    }

    /// Rows this index's connection has written since it opened.
    func writes(_ store: IndexStore) throws -> Int64 {
        var count: Int64 = 0
        try store.db.query("SELECT total_changes()") { count = $0.int(0) }
        return count
    }

    @Test func photosPeopleAlbumsAndPlacesFollowTheListing() throws {
        let (library, listed) = try library(3, in: folder)
        let katie = PhotosLibrary.Person(uuid: "P-KATIE", name: "Katie")
        let suzy = PhotosLibrary.Person(uuid: "P-SUZY", name: "Suzy")
        let otherSuzy = PhotosLibrary.Person(uuid: "P-SUZY-2", name: "Suzy")
        let trip = PhotosLibrary.Album(uuid: "A-TRIP", title: "Trip", folders: ["2024", "Florida"])
        let farm = PhotosLibrary.Album(uuid: "A-FARM", title: "Pumpkin Farm")
        let empty = PhotosLibrary.Album(uuid: "A-EMPTY", title: "Nothing in it")
        var assets = [asset(listed[0], favorite: true, at: (51.50357167, -0.1318055), place: "St James's Park",
                            people: [katie, suzy], albums: [trip]),
                      asset(listed[1], people: [otherSuzy], albums: [farm]),
                      listed[2]]
        let store = try IndexStore(directory: folder.appendingPathComponent("index"))
        let first = PhotosLibrary.Listing(assets: assets, people: [katie, suzy, otherSuzy], albums: [trip, farm, empty])
        #expect(try indexer(store) { _ in first }.sync([library]).described == 3)
        let people = try store.photosPeople()
        #expect(people.map(\.name) == ["Katie", "Suzy", "Suzy"])   // one name, two people: two rows
        #expect(people.map(\.files) == [1, 1, 1])
        #expect(Set(people.map(\.library)) == [library.path])
        let albums = try store.photosAlbums()   // an album no indexed picture is in isn't kept
        #expect(albums.map(\.title) == ["Pumpkin Farm", "Trip"])
        #expect(albums.map(\.folders) == [[], ["2024", "Florida"]])
        let london = try #require(try store.locations(of: listed.map(\.path))[listed[0].path])
        #expect(london == Location(latitude: 51.50357167, longitude: -0.1318055, source: .photos,
                                   place: "St James's Park"))
        var favorites: [Int64] = []
        try store.db.query("SELECT favorite FROM photos_assets ORDER BY file") { favorites.append($0.int(0)) }
        #expect(favorites == [1, 0, 0])   // one row a library file

        // Unchanged: nothing is written.
        let before = try writes(store)
        #expect(try indexer(store) { _ in first }.sync([library]).described == 0)
        #expect(try writes(store) == before)

        // Renamed in Photos, an album renamed and moved, a name taken off a picture, a location removed: the same
        // rows change in place, and a person no picture shows any more goes.
        let katherine = PhotosLibrary.Person(uuid: "P-KATIE", name: "Katherine")
        let roadTrip = PhotosLibrary.Album(uuid: "A-TRIP", title: "Road trip", folders: ["2025"])
        assets[0] = asset(listed[0], favorite: true, people: [katherine, suzy], albums: [roadTrip])
        assets[1] = asset(listed[1], albums: [farm])
        let second = PhotosLibrary.Listing(assets: assets, people: [katherine, suzy, otherSuzy],
                                           albums: [roadTrip, farm])
        #expect(try indexer(store) { _ in second }.sync([library]).described == 2)
        let renamed = try store.photosPeople()
        #expect(renamed.map(\.name) == ["Katherine", "Suzy"])
        #expect(renamed.map(\.id) == [people[0].id, people[1].id])
        let moved = try store.photosAlbums()
        #expect(moved.map(\.title) == ["Pumpkin Farm", "Road trip"])
        #expect(moved.last?.id == albums.last?.id && moved.last?.folders == ["2025"])
        #expect(try store.locations(of: listed.map(\.path)).isEmpty)
    }

    @Test func aLibraryRenamedInAChosenFolderHasItsPeopleAndAlbumsUnderItsNewName() throws {
        let pictures = folder.appendingPathComponent("Pictures")
        let (library, listed) = try library(2, in: pictures)
        let katie = PhotosLibrary.Person(uuid: "P-KATIE", name: "Katie")
        let trip = PhotosLibrary.Album(uuid: "A-TRIP", title: "Trip")
        let assets = [asset(listed[0], favorite: true, people: [katie], albums: [trip]),
                      asset(listed[1], people: [katie])]
        let store = try IndexStore(directory: folder.appendingPathComponent("index"))
        // The listing names the files under the library's path as it is when it's read.
        let indexer = try indexer(store) { path in
            PhotosLibrary.Listing(assets: assets.map { asset($0, movedFrom: library.path, to: path) }, people: [katie],
                                  albums: [trip])
        }
        #expect(try indexer.sync([pictures]).described == 2)

        // Renamed in Pictures: its files move with it (nothing is read again), and they're linked to the people and
        // album of the library under its new name; the old name's rows go with their last links.
        let renamed = pictures.appendingPathComponent("Renamed.photoslibrary")
        try FileManager.default.moveItem(at: library, to: renamed)
        let sync = try indexer.sync([pictures])
        #expect(sync.moved == 2 && sync.added == 0 && sync.removed == 0 && sync.queued.isEmpty)
        #expect(sync.described == 2)
        let people = try store.photosPeople()
        #expect(people.map(\.library) == [renamed.path] && people.map(\.files) == [2])
        let albums = try store.photosAlbums()
        #expect(albums.map(\.library) == [renamed.path] && albums.map(\.files) == [1])
        let katieID = try #require(people.first?.id)
        let withKatie = try Searcher(store: store, loadVectors: false)
            .search("", queryVector: nil, filter: SearchFilter(people: [[katieID]]))
        #expect(withKatie.count == 2 && withKatie.allSatisfy { $0.path.hasPrefix(renamed.path + "/") })

        // Unchanged since: nothing is written.
        let before = try writes(store)
        let again = try indexer.sync([pictures])
        #expect(again.unchanged == 2 && again.described == 0)
        #expect(try writes(store) == before)
    }

    @Test func filtersKeepWhoIsInItTheAlbumsFavoritesAndPlace() throws {
        let (library, listed) = try library(4, in: folder)   // taken in this order, a second apart
        let katie = PhotosLibrary.Person(uuid: "P-KATIE", name: "Katie")
        let suzy = PhotosLibrary.Person(uuid: "P-SUZY", name: "Suzy")
        let otherSuzy = PhotosLibrary.Person(uuid: "P-SUZY-2", name: "Suzy")
        let trip = PhotosLibrary.Album(uuid: "A-TRIP", title: "Trip")
        let farm = PhotosLibrary.Album(uuid: "A-FARM", title: "Pumpkin Farm")
        let assets = [asset(listed[0], favorite: true, at: (51.5, -0.13), people: [katie, suzy], albums: [trip]),
                      asset(listed[1], at: (-34.9, 138.6), people: [katie], albums: [farm]),
                      asset(listed[2], people: [otherSuzy], albums: [farm]),
                      listed[3]]
        let store = try IndexStore(directory: folder.appendingPathComponent("index"))
        let listing = PhotosLibrary.Listing(assets: assets, people: [katie, suzy, otherSuzy], albums: [trip, farm])
        _ = try indexer(store) { _ in listing }.sync([library])
        // A picture of London from outside the library, newer than all of them, located by its own GPS tags.
        let elsewhere = try store.insert(Candidate(path: "/elsewhere/london.jpg", kind: .image, size: 1,
                                                   mtime: 1_700_000_010, inode: 99, device: 1))
        try store.setLocation(try #require(Location(latitude: 51.51, longitude: -0.12, source: .exif)), of: elsewhere)

        let people = try store.photosPeople()
        let katieID = try #require(people.first { $0.name == "Katie" }?.id)
        let suzys = Set(people.filter { $0.name == "Suzy" }.map(\.id))
        let albums = Set(try store.photosAlbums().map(\.id))
        let london = SearchFilter.Area(latitudes: 51...52, longitudes: -1...1)
        let searcher = try Searcher(store: store, loadVectors: false)
        // With no words: what the filter keeps, newest first.
        func kept(_ filter: SearchFilter, kinds: Set<FileKind>? = nil) throws -> [String] {
            try searcher.search("", queryVector: nil, kinds: kinds, filter: filter).map(\.path)
        }
        #expect(try kept(SearchFilter(people: [[katieID]])) == [assets[1].path, assets[0].path])
        // People: each one in it. A name two people share: either of them.
        #expect(try kept(SearchFilter(people: [[katieID], suzys])) == [assets[0].path])
        #expect(try kept(SearchFilter(people: [suzys])) == [assets[2].path, assets[0].path])
        // Albums: any of them.
        #expect(try kept(SearchFilter(albums: albums)) == [assets[2].path, assets[1].path, assets[0].path])
        #expect(try kept(SearchFilter(favorites: true)) == [assets[0].path])
        // A box on the map: by Photos' date, else the file's own.
        #expect(try kept(SearchFilter(area: london)) == ["/elsewhere/london.jpg", assets[0].path])
        #expect(try kept(SearchFilter(favorites: true, area: london)) == [assets[0].path])
        #expect(try kept(SearchFilter(area: london), kinds: [.video]).isEmpty)
        let first = try #require(try searcher.search("", queryVector: nil, filter: SearchFilter(favorites: true)).first)
        #expect(first.segment == .photosInfo && first.photos?.title == assets[0].title)

        // With words, the filter narrows what they find.
        let found = try searcher.search("Beach", queryVector: nil, filter: SearchFilter(people: [[katieID]]))
        #expect(Set(found.map(\.path)) == [assets[0].path, assets[1].path])
        #expect(try searcher.search("Beach", queryVector: nil).count == 4)
    }

    @Test func aFilterKeepsItsFilesAmongMoreWordMatchesThanSearchLooksAt() throws {
        let (library, listed) = try library(2, in: folder)
        let assets = [asset(listed[0], favorite: true), listed[1]]
        let store = try IndexStore(directory: folder.appendingPathComponent("index"))
        _ = try indexer(store) { _ in PhotosLibrary.Listing(assets: assets) }.sync([library])
        // More notes than keyword search keeps matches of (1,000), each saying "beach" more than Photos' words do.
        try store.db.transaction {
            for number in 0..<1_100 {
                let id = try store.insert(Candidate(path: "/notes/beach \(number).txt", kind: .doc, size: 1, mtime: 1,
                                                    inode: UInt64(1_000 + number), device: 1))
                try store.addSegment(file: id, kind: .chunk, modality: .text, text: "beach beach")
            }
        }
        let searcher = try Searcher(store: store, loadVectors: false)
        #expect(try searcher.search("beach", queryVector: nil, filter: SearchFilter(favorites: true)).map(\.path)
                == [assets[0].path])
    }

    #if canImport(ImageIO)
    @Test func aLibrarysPictureHasPhotosLocationNeverItsOwn() throws {
        // Both pictures' files carry GPS tags (Miami). Photos says the first was taken in Adelaide (as a location typed
        // or corrected in Photos would), and has no location for the second.
        let (library, listed) = try library(2, in: folder)
        for asset in listed { try ImageTests.writeJPEG(URL(fileURLWithPath: asset.path), at: (25.79, -80.13)) }
        let assets = [asset(listed[0], at: (-34.9, 138.6)), listed[1]]
        let store = try IndexStore(directory: folder.appendingPathComponent("index"))
        var options = IndexOptions()
        options.photos = PhotosLibrary.Reader { _ in PhotosLibrary.Listing(assets: assets) }
        let indexer = try Indexer(store: store, options: options, makeEmbedder: { FakeEmbedder() })
        _ = try indexer.sync([library])
        #expect(try indexer.run()["done"] == 2)   // both read: their tags were there to take
        let locations = try store.locations(of: listed.map(\.path))
        #expect(locations.count == 1)
        let adelaide = try #require(locations[listed[0].path])
        #expect(adelaide.source == .photos && adelaide.latitude == -34.9)
    }
    #endif

    @Test func aLibraryInAChosenFolderIsReadThroughItsCatalog() throws {
        // Pictures, with a library in it: 300 pictures to a folder, named for their uuids, which a walk would take
        // for a dataset. Its database is never a candidate: only what the listing names is.
        let pictures = folder.appendingPathComponent("Pictures")
        let (library, listed) = try library(300, in: pictures)
        var assets = listed
        assets[7] = asset(assets[7], title: "Beach day", words: ["Beach day", "Tati", "Miami Beach", "Florida"])
        let listing = PhotosLibrary.Listing(assets: assets, skipped: ["hidden in Photos": 2])
        let store = try IndexStore(directory: folder.appendingPathComponent("index"))
        let indexer = try indexer(store) { path in
            #expect(path == library.path)
            return listing
        }
        let sync = try indexer.sync([pictures])
        #expect(sync.added == 300 && sync.described == 300)
        #expect(sync.crawl.datasets.isEmpty)
        #expect(sync.crawl.skipped["hidden in Photos"] == 2)
        #expect(Set(sync.crawl.candidates.map(\.path)) == Set(assets.map(\.path)))

        // What Photos knows is found by keyword, and the result knows its way back to Photos.
        let hits = try Searcher(store: store).search("Tati in Miami", queryVector: nil)
        #expect(hits.first?.path == assets[7].path)
        #expect(hits.first?.segment == .photosInfo)
        #expect(hits.first?.photos == PhotosHit(library: library.path, uuid: assets[7].uuid, title: "Beach day",
                                                date: 1_700_000_007))
        #expect(hits.first?.loc == nil)   // a Photos fact's loc is its date, not a place in the file

        // Unchanged: nothing is queued or described again.
        let again = try indexer.sync([pictures])
        #expect(again.unchanged == 300 && again.described == 0 && again.queued.isEmpty)
    }

    @Test func photosFactsChangeWithoutReadingThePictureAgain() throws {
        let (library, assets) = try library(2, in: folder)
        let store = try IndexStore(directory: folder.appendingPathComponent("index"))
        _ = try indexer(store) { _ in PhotosLibrary.Listing(assets: assets) }.sync([library])
        // A face named in Photos since: its words change, and that's all.
        let tagged = assets.map { asset($0, words: $0.words + ["Tati"]) }
        let renamed = try indexer(store) { _ in PhotosLibrary.Listing(assets: tagged) }
        let sync = try renamed.sync([library])
        #expect(sync.described == 2 && sync.changed == 0 && sync.queued.isEmpty)
        #expect(try Searcher(store: store).search("Tati", queryVector: nil).count == 2)

        // Read again (the picture changed; a new model): the facts stay, since the crawl owns them.
        try Data("edited".utf8).write(to: URL(fileURLWithPath: assets[0].path))
        let edited = try renamed.sync([library])
        #expect(edited.changed == 1 && edited.described == 0)
        try store.resetAll()
        #expect(try Searcher(store: store).search("Tati", queryVector: nil).count == 2)
    }

    @Test func aLibraryThatCantBeReadKeepsWhatsIndexed() throws {
        let (library, assets) = try library(3, in: folder)
        let store = try IndexStore(directory: folder.appendingPathComponent("index"))
        #expect(try indexer(store) { _ in PhotosLibrary.Listing(assets: assets) }.sync([library]).added == 3)
        // osxphotos failed, or macOS said no: that's not "every picture deleted".
        let failing = try indexer(store) { _ in throw PhotosLibrary.Failure(description: "osxphotos couldn't read it") }
        let sync = try failing.sync([library])
        #expect(sync.removed == 0)
        #expect(sync.crawl.unlisted.contains(library.path))
        #expect(sync.crawl.problems == ["osxphotos couldn't read it"])
        #expect(try store.files(under: [library.path]).count == 3)
    }

    @Test func aLibraryIsReadOnlyWhenItCanBeAndIsntSkipped() throws {
        let pictures = folder.appendingPathComponent("Pictures")
        let (library, assets) = try library(1, in: pictures)
        // Skipped inside a chosen folder, as a folder would be: not read at all.
        var options = IndexOptions()
        options.photos = PhotosLibrary.Reader { _ in
            Issue.record("a skipped library was read")
            return PhotosLibrary.Listing(assets: assets)
        }
        options.excludedFolders = [library.path]
        #expect(Crawler.crawl([pictures], options: options).candidates.isEmpty)
        // Without osxphotos it's a bundle like any other, never walked.
        let unread = Crawler.crawl([pictures], options: IndexOptions())
        #expect(unread.candidates.isEmpty)
        #expect(unread.skippedFolders["Photos library (osxphotos isn't installed)"] == 1)
        // Chosen as a code folder: neither read nor walked (its files would be walked like any folder's).
        try Data("print('not code to read')".utf8).write(to: library.appendingPathComponent("database/stray.py"))
        var code = IndexOptions()
        code.code = true
        let codeCrawl = Crawler.crawl([library], options: code)
        #expect(codeCrawl.candidates.isEmpty)
        #expect(codeCrawl.skippedFolders["Photos library"] == 1)
    }

    @Test func aFileOfALibraryNamesItsAsset() {
        let library = "/Users/me/Pictures/Photos Library.photoslibrary"
        let uuid = "FC37DBA6-CF22-4E3E-AB70-755587454608"
        for file in ["originals/F/\(uuid).heic", "resources/renders/F/\(uuid)_1_201_a.heic",
                     "resources/derivatives/F/\(uuid)_1_105_c.jpeg"] {
            #expect(PhotosLibrary.asset(ofFile: library + "/" + file)?.uuid == uuid)
            #expect(PhotosLibrary.asset(ofFile: library + "/" + file)?.library == library)
        }
        #expect(PhotosLibrary.asset(ofFile: library + "/database/Photos.sqlite") == nil)
        #expect(PhotosLibrary.asset(ofFile: "/Users/me/Pictures/\(uuid).heic") == nil)   // not in a library
    }

    @Test func aKeptListingIsUsedUntilThePicturesChangeOrItsOld() {
        let state = PhotosLibrary.State(pictures: "originals/F 10:1", database: "Photos.sqlite 5:1")
        let kept = PhotosLibrary.Kept(library: "/L.photoslibrary", listedAt: 1000, state: state,
                                      listing: PhotosLibrary.Listing(assets: []))
        #expect(kept.isCurrent(library: "/L.photoslibrary", state: state, now: 99_999))
        // A new, edited or downloaded picture: listed again at once.
        let newPicture = PhotosLibrary.State(pictures: "originals/F 11:2", database: state.database)
        #expect(!kept.isCurrent(library: "/L.photoslibrary", state: newPicture, now: 1001))
        // Only the database (Photos writes it all the time): the listing holds for a while.
        let written = PhotosLibrary.State(pictures: state.pictures, database: "Photos.sqlite 6:2")
        #expect(kept.isCurrent(library: "/L.photoslibrary", state: written, now: 1000 + 60))
        #expect(!kept.isCurrent(library: "/L.photoslibrary", state: written, now: 1000 + 600))
        #expect(!kept.isCurrent(library: "/Other.photoslibrary", state: state, now: 1001))
        // Made by another version of the script: made again.
        var older = kept
        older.reader = "0000000000000000"
        #expect(!older.isCurrent(library: "/L.photoslibrary", state: state, now: 1001))
    }

    @Test func photosSearchDatabaseCountsAsTheDatabase() throws {
        // Photos' labels and places live in its search database, not the catalog: a change there alone is a change.
        let (library, _) = try library(1, in: folder)
        let search = library.appendingPathComponent("database/search")
        try FileManager.default.createDirectory(at: search, withIntermediateDirectories: true)
        try Data("labels".utf8).write(to: search.appendingPathComponent("leo.sqlite"))
        let before = PhotosLibrary.State(of: library.path)
        try Data("labels, and a new one".utf8).write(to: search.appendingPathComponent("leo.sqlite"))
        let after = PhotosLibrary.State(of: library.path)
        #expect(after.pictures == before.pictures)
        #expect(after.database != before.database)
    }

    #if canImport(Vision)
    /// A reading Photos made of a picture (a can's label, in osxphotos' test library for macOS 27), as its catalog
    /// keeps it.
    static let reading = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Photos/reading.bplist")

    @Test func photosReadingIsUsedAndOnlyAMissingOneLeavesItToDigUp() throws {
        let library = folder.appendingPathComponent("L.photoslibrary")
        try FileManager.default.createDirectory(at: library.appendingPathComponent("database"),
                                                withIntermediateDirectories: true)
        let catalog = try Database(path: library.appendingPathComponent("database/Photos.sqlite").path)
        try catalog.execute("""
            CREATE TABLE ZASSET (Z_PK INTEGER PRIMARY KEY, ZUUID VARCHAR);
            CREATE TABLE ZMEDIAANALYSISASSETATTRIBUTES (Z_PK INTEGER PRIMARY KEY, ZASSET INTEGER,
                ZCHARACTERRECOGNITIONATTRIBUTES INTEGER, ZCHARACTERRECOGNITIONVERSION INTEGER);
            CREATE TABLE ZCHARACTERRECOGNITIONATTRIBUTES (Z_PK INTEGER PRIMARY KEY, ZCHARACTERRECOGNITIONDATA BLOB);
            """)
        let archive = try Data(contentsOf: Self.reading)
        // Read with words; read and none found; Photos couldn't read it (32767); not read yet (0).
        let assets: [(String, Int64, Data?)] = [("READ", 9, archive), ("EMPTY", 9, nil), ("FAILED", 32767, nil),
                                                ("UNREAD", 0, nil)]
        for (number, (uuid, version, data)) in assets.enumerated() {
            let key = SQLValue.int(Int64(number + 1))
            try catalog.run("INSERT INTO ZASSET VALUES (?, ?)", [key, .text(uuid)])
            try catalog.run("INSERT INTO ZMEDIAANALYSISASSETATTRIBUTES VALUES (?, ?, ?, ?)",
                            [key, key, key, .int(version)])
            try catalog.run("INSERT INTO ZCHARACTERRECOGNITIONATTRIBUTES VALUES (?, ?)", [key, data.map { .blob($0) } ?? .null])
        }
        let readings = PhotosLibrary.RecognizedText(library: library.path)
        #expect(readings.text(of: "READ") == "PROUTS\nMojito Mint")
        #expect(readings.text(of: "EMPTY") == "")       // nothing for DigUp to read again
        #expect(readings.text(of: "FAILED") == nil)     // DigUp reads it itself
        #expect(readings.text(of: "UNREAD") == nil)
        #expect(readings.text(of: "NOT-IN-THE-CATALOG") == nil)

        // A catalog from before Photos kept readings (macOS 12): no readings, and nothing goes wrong.
        let older = folder.appendingPathComponent("Older.photoslibrary")
        try FileManager.default.createDirectory(at: older.appendingPathComponent("database"),
                                                withIntermediateDirectories: true)
        try Database(path: older.appendingPathComponent("database/Photos.sqlite").path)
            .execute("CREATE TABLE ZASSET (Z_PK INTEGER PRIMARY KEY, ZUUID VARCHAR)")
        #expect(PhotosLibrary.RecognizedText(library: older.path).text(of: "READ") == nil)
    }
    #endif
}
