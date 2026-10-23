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
        options.photos = PhotosLibrary.Reader { library, _ in try listing(library) }
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

    /// The same asset as Photos records how it came in (its ZIMPORTEDBY number and app), and the device that took it.
    func asset(_ asset: PhotosLibrary.Asset, importedBy number: Int?, app: String? = nil, camera: String? = nil)
        -> PhotosLibrary.Asset {
        PhotosLibrary.Asset(uuid: asset.uuid, path: asset.path, movie: asset.movie, screenshot: asset.screenshot,
                            title: asset.title, date: asset.date, words: asset.words, favorite: asset.favorite,
                            reading: asset.reading, importedBy: number, originApp: app, camera: camera)
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

    @Test func aPersonOrAnAlbumIsFoundByPhotosUuidThroughARenameInPhotos() throws {
        let (library, listed) = try library(1, in: folder)
        let katie = PhotosLibrary.Person(uuid: "P-KATIE", name: "Katie")
        let trip = PhotosLibrary.Album(uuid: "A-TRIP", title: "Trip", folders: ["2024"])
        let store = try IndexStore(directory: folder.appendingPathComponent("index"))
        let first = PhotosLibrary.Listing(assets: [asset(listed[0], people: [katie], albums: [trip])], people: [katie],
                                          albums: [trip])
        _ = try indexer(store) { _ in first }.sync([library])
        let people = try store.photosPeople(), albums = try store.photosAlbums()
        #expect(people.map(\.uuid) == ["P-KATIE"] && people.map(\.library) == [library.path])
        #expect(albums.map(\.uuid) == ["A-TRIP"] && albums.map(\.library) == [library.path])

        // Renamed in Photos, the album moved to another folder: the same uuids, now with the new names.
        let katherine = PhotosLibrary.Person(uuid: "P-KATIE", name: "Katherine")
        let roadTrip = PhotosLibrary.Album(uuid: "A-TRIP", title: "Road trip", folders: ["2025"])
        let second = PhotosLibrary.Listing(assets: [asset(listed[0], people: [katherine], albums: [roadTrip])],
                                           people: [katherine], albums: [roadTrip])
        _ = try indexer(store) { _ in second }.sync([library])
        let renamed = try #require(try store.photosPeople().first { $0.uuid == "P-KATIE" })
        let moved = try #require(try store.photosAlbums().first { $0.uuid == "A-TRIP" })
        #expect(renamed.name == "Katherine" && renamed.id == people[0].id)
        #expect(moved.title == "Road trip" && moved.folders == ["2025"] && moved.id == albums[0].id)
    }

    @Test func aPersonOrAnAlbumNoLongerIndexedKeepsNothing() throws {
        let (library, listed) = try library(2, in: folder)
        let katie = PhotosLibrary.Person(uuid: "P-KATIE", name: "Katie")
        let trip = PhotosLibrary.Album(uuid: "A-TRIP", title: "Trip")
        let store = try IndexStore(directory: folder.appendingPathComponent("index"))
        let listing = PhotosLibrary.Listing(assets: [asset(listed[0], people: [katie], albums: [trip]), listed[1]],
                                            people: [katie], albums: [trip])
        _ = try indexer(store) { _ in listing }.sync([library])
        let katieID = try #require(try store.photosPeople().first?.id)
        let tripID = try #require(try store.photosAlbums().first?.id)
        let searcher = try Searcher(store: store, loadVectors: false)
        func kept(_ words: String, _ filter: SearchFilter) throws -> [String] {
            try searcher.search(words, queryVector: nil, filter: filter).map(\.path)
        }
        #expect(try kept("Beach", SearchFilter()).count == 2)
        // A person with no one behind them (a saved search's, gone from Photos) keeps nothing, alone or beside someone
        // who's there: never everyone.
        #expect(try kept("", SearchFilter(people: [[]])).isEmpty)
        #expect(try kept("Beach", SearchFilter(people: [[]])).isEmpty)
        #expect(try kept("", SearchFilter(people: [[katieID], []])).isEmpty)
        // Albums, any of them: none left keeps nothing; one gone among others keeps the others' files.
        #expect(try kept("", SearchFilter(albums: [])).isEmpty)
        #expect(try kept("Beach", SearchFilter(albums: [])).isEmpty)
        #expect(try kept("", SearchFilter(albums: [tripID])) == [listed[0].path])
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

    @Test func howAnAssetCameIntoTheLibraryIsReadFromWhatPhotosRecorded() throws {
        let cases: [(screenshot: Bool, number: Int?, app: String?, origin: PhotosLibrary.Origin)] = [
            (true, 8, "com.apple.springboard", .screenshot),           // a screenshot, whoever saved it
            (true, 1, nil, .screenshot),
            (false, 1, nil, .camera),                                   // the back camera
            (false, 2, nil, .camera),                                   // the front one
            (false, 1, "com.apple.Photos", .camera),                    // the camera's number before Photos as the app
            (false, 8, "com.apple.camera.CameraMessagesApp", .camera),  // Messages' camera
            (false, 0, "com.apple.camera", .camera),
            (false, nil, "com.apple.camera", .camera),
            (false, 5, nil, .imported),
            (false, 0, "com.apple.Photos", .imported),
            (false, 3, "com.atebits.Tweetie2", .saved),
            (false, 13, "com.apple.sharingd", .saved),                 // AirDrop, by its app
            (false, 3, nil, .saved), (false, 6, nil, .saved), (false, 7, nil, .saved), (false, 8, nil, .saved),
            (false, 9, nil, .saved), (false, 12, nil, .saved),
            (false, 0, nil, .unknown), (false, nil, nil, .unknown), (false, 13, nil, .unknown),
        ]
        for item in cases {
            #expect(PhotosLibrary.Origin(screenshot: item.screenshot, importedBy: item.number, app: item.app)
                    == item.origin, "\(item)")
        }
        // As the listing writes it.
        let listed = try JSONDecoder().decode(PhotosLibrary.Asset.self, from: Data("""
            {"uuid": "FC37DBA6-CF22-4E3E-AB70-755587454608", "path": "/L.photoslibrary/x", "reading": "stills",
             "movie": true, "screenshot": false, "title": "IMG_1.MOV", "date": 1, "words": [], "favorite": false,
             "latitude": null, "longitude": null, "place": null, "people": [], "albums": [], "importedBy": 1,
             "originApp": "com.apple.camera", "camera": "iPhone 15 Pro"}
            """.utf8))
        #expect(listed.reading == .stills && listed.kind == .video)
        #expect(listed.origin == .camera && listed.originApp == "com.apple.camera" && listed.camera == "iPhone 15 Pro")
    }

    @Test func filtersKeepHowItCameInAndTheDeviceAmongMoreWordMatchesThanSearchLooksAt() throws {
        let (library, listed) = try library(5, in: folder)   // taken in this order, a second apart
        let assets = [asset(listed[0], importedBy: 1, app: "com.apple.camera", camera: "iPhone 15 Pro"),
                      asset(listed[1], importedBy: 0, camera: "iPhone 15 Pro"),   // nothing recorded: an older one
                      asset(listed[2], importedBy: 3, app: "com.apple.MobileSMS", camera: "iPhone 12"),   // sent
                      asset(listed[3], importedBy: 2, camera: "iPhone Air"),
                      asset(listed[4], importedBy: 1)]   // a camera's, with no device in its EXIF
        let store = try IndexStore(directory: folder.appendingPathComponent("index"))
        _ = try indexer(store) { _ in PhotosLibrary.Listing(assets: assets) }.sync([library])
        #expect(try store.photosCameras() == [
            IndexStore.PhotosCamera(model: "iPhone 15 Pro", files: 2, fromCamera: 1, unknownOrigin: 1),
            IndexStore.PhotosCamera(model: "iPhone 12", files: 1, fromCamera: 0, unknownOrigin: 0),
            IndexStore.PhotosCamera(model: "iPhone Air", files: 1, fromCamera: 1, unknownOrigin: 0)])
        let searcher = try Searcher(store: store, loadVectors: false)
        func kept(_ filter: SearchFilter) throws -> [String] {
            try searcher.search("", queryVector: nil, filter: filter).map(\.path)
        }
        // "Shot on my devices": what a camera saved, or nothing recorded, and taken with one of mine.
        let mine = SearchFilter(origins: ["camera", "unknown"], cameras: ["iPhone 15 Pro", "iPhone Air"])
        #expect(try kept(mine) == [listed[3].path, listed[1].path, listed[0].path])
        #expect(try kept(SearchFilter(origins: ["saved"])) == [listed[2].path])
        #expect(try kept(SearchFilter(cameras: ["iPhone 12"])) == [listed[2].path])
        #expect(try kept(SearchFilter(origins: ["camera"], cameras: ["iPhone 12"])).isEmpty)
        // "Shot on my devices" as the app asks for it: a camera's with no device named counts too, an older one only
        // with a device of mine.
        #expect(try kept(SearchFilter(shotOn: ["iPhone 15 Pro", "iPhone Air"]))
            == [listed[4].path, listed[3].path, listed[1].path, listed[0].path])
        #expect(try kept(SearchFilter(shotOn: ["iPhone Air"])) == [listed[4].path, listed[3].path])
        // No device of mine left (all taken off in Settings): what a camera saved with no device named, and nothing
        // else; the filter still keeps to the camera's, it doesn't stop filtering.
        #expect(try kept(SearchFilter(shotOn: [])) == [listed[4].path])

        // With words: the filter narrows the matches before they're cut to the best 1,000 (more notes than that say
        // "beach", each more than Photos' words do).
        try store.db.transaction {
            for number in 0..<1_100 {
                let id = try store.insert(Candidate(path: "/notes/beach \(number).txt", kind: .doc, size: 1, mtime: 1,
                                                    inode: UInt64(1_000 + number), device: 1))
                try store.addSegment(file: id, kind: .chunk, modality: .text, text: "beach beach")
            }
        }
        let found = try Searcher(store: store, loadVectors: false).search("beach", queryVector: nil, filter: mine)
        #expect(Set(found.map(\.path)) == [listed[0].path, listed[1].path, listed[3].path])
    }

    @Test func theAppsOwnFavoritesAreFoundByAssetAndKeptByPath() throws {
        let (library, listed) = try library(3, in: folder)   // taken in this order, a second apart
        let store = try IndexStore(directory: folder.appendingPathComponent("index"))
        _ = try indexer(store) { _ in PhotosLibrary.Listing(assets: listed) }.sync([library])
        // An asset's indexed file, wherever it is now; one that isn't indexed has none.
        #expect(try store.paths(ofAssets: [listed[0].uuid, listed[2].uuid, "00000000-0000-0000-0000-000000000000"])
            == [listed[0].uuid: listed[0].path, listed[2].uuid: listed[2].path])
        let searcher = try Searcher(store: store, loadVectors: false)
        func kept(_ filter: SearchFilter) throws -> [String] {
            try searcher.search("", queryVector: nil, filter: filter).map(\.path)
        }
        #expect(try kept(SearchFilter(paths: [listed[0].path, listed[2].path])) == [listed[2].path, listed[0].path])
        // No favorites keeps nothing, and the part combines with the others.
        #expect(try kept(SearchFilter(paths: [])).isEmpty)
        #expect(!SearchFilter(paths: []).isEmpty)
        #expect(try kept(SearchFilter(origins: ["saved"], paths: [listed[0].path])).isEmpty)
    }

    @Test func anAssetStaysOneRowWhileItsFileChanges() throws {
        let (library, listed) = try library(1, in: folder)
        // Its original in iCloud at first: Photos' preview of it is read.
        let uuid = listed[0].uuid
        let previews = library.appendingPathComponent("resources/derivatives/\(uuid.prefix(1))")
        try FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)
        let preview = previews.appendingPathComponent(uuid + "_1_105_c.jpeg")
        try Data("preview".utf8).write(to: preview)
        let katie = PhotosLibrary.Person(uuid: "P-KATIE", name: "Katie")
        let trip = PhotosLibrary.Album(uuid: "A-TRIP", title: "Trip")
        @Sendable func listing(_ path: String, _ reading: PhotosLibrary.Reading) -> PhotosLibrary.Listing {
            let asset = PhotosLibrary.Asset(uuid: uuid, path: path, movie: false, screenshot: false, title: "IMG_1",
                                            date: 1_700_000_000, words: ["Beach"], favorite: true, latitude: 51.5,
                                            longitude: -0.13, people: [katie.uuid], albums: [trip.uuid],
                                            reading: reading)
            return PhotosLibrary.Listing(assets: [asset], people: [katie], albums: [trip])
        }
        let store = try IndexStore(directory: folder.appendingPathComponent("index"))
        #expect(try indexer(store) { _ in listing(preview.path, .preview) }.sync([library]).added == 1)
        let row = try #require(try store.files(under: [library.path]).first)
        /// As if it had been read: a picture's vector.
        func read() throws {
            try store.addSegment(file: row.id, kind: .image, modality: .image, vector: FakeEmbedder.vector(for: "x"))
            try store.finish(row.id, state: "done")
        }
        /// The same row at `path`, waiting to be read again (what was read of it gone), and all Photos said kept.
        func stillOneRow(at path: String, reading: PhotosLibrary.Reading) throws {
            let rows = try store.files(under: [library.path])
            #expect(rows.map(\.id) == [row.id] && rows.map(\.path) == [path] && rows.map(\.state) == ["pending"])
            var images = 0, readings: [String] = []
            try store.db.query("SELECT COUNT(*) FROM segments WHERE kind = 'image'") { images = Int($0.int(0)) }
            #expect(images == 0)
            #expect(try store.photosPeople().map(\.files) == [1] && store.photosAlbums().map(\.files) == [1])
            #expect(try store.locations(of: [path]).count == 1)
            try store.db.query("SELECT reading FROM photos_assets WHERE file = ? AND favorite = 1", [.int(row.id)]) {
                readings.append($0.text(0) ?? "")
            }
            #expect(readings == [reading.rawValue])
        }
        try read()

        // Downloaded: its original is read now, as the same row, with its people, album, favorite and place.
        let downloaded = try indexer(store) { _ in listing(listed[0].path, .original) }.sync([library])
        #expect(downloaded.changed == 1 && downloaded.added == 0 && downloaded.removed == 0)
        #expect(downloaded.queued == [row.id] && downloaded.described == 1)
        try stillOneRow(at: listed[0].path, reading: .original)
        try read()
        // And back to Photos' preview when the original goes to iCloud again.
        let removed = try indexer(store) { _ in listing(preview.path, .preview) }.sync([library])
        #expect(removed.changed == 1 && removed.added == 0 && removed.removed == 0 && removed.queued == [row.id])
        try stillOneRow(at: preview.path, reading: .preview)
    }

    /// Photos' facts about a file, as the index keeps them: its `photos_assets` row (reading), its locations' sources
    /// and its `photosInfo` segments.
    func photosFacts(of file: Int64, in store: IndexStore) throws -> (readings: [String], located: [String], info: Int) {
        var facts = (readings: [String](), located: [String](), info: 0)
        try store.db.query("SELECT reading FROM photos_assets WHERE file = ?", [.int(file)]) {
            facts.readings.append($0.text(0) ?? "")
        }
        try store.db.query("SELECT source FROM locations WHERE file = ?", [.int(file)]) {
            facts.located.append($0.text(0) ?? "")
        }
        try store.db.query("SELECT COUNT(*) FROM segments WHERE file = ? AND kind = ?",
                           [.int(file), .text(SegmentKind.photosInfo.rawValue)]) { facts.info = Int($0.int(0)) }
        return facts
    }

    /// A library's preview read first, then its original downloaded, while a file elsewhere is a hard link to the old
    /// preview (the same inode, size and date): a picture in an ordinary folder, or the same preview in a copy of the
    /// library made with hard links. The asset's row stays the asset's whichever folder the crawl walks first, and the
    /// file elsewhere is a new one, with only what its own library says about it.
    @Test(arguments: [true, false], [false, true])
    func anAssetKeepsItsRowWhenAFileElsewhereSharesItsOldFile(libraryFirst: Bool, inACopy: Bool) throws {
        let (library, listed) = try library(1, in: folder)
        let uuid = listed[0].uuid
        let derivatives = "resources/derivatives/\(uuid.prefix(1))", previewName = uuid + "_1_105_c.jpeg"
        let previews = library.appendingPathComponent(derivatives)
        try FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)
        let preview = previews.appendingPathComponent(previewName)
        try Data("preview".utf8).write(to: preview)
        @Sendable func listing(_ path: String, _ reading: PhotosLibrary.Reading) -> PhotosLibrary.Listing {
            PhotosLibrary.Listing(assets: [
                PhotosLibrary.Asset(uuid: uuid, path: path, movie: false, screenshot: false, title: "IMG_1",
                                    date: 1_700_000_000, words: ["Beach"], favorite: true, latitude: 51.5,
                                    longitude: -0.13, reading: reading),
            ])
        }
        let store = try IndexStore(directory: folder.appendingPathComponent("index"))
        _ = try indexer(store) { _ in listing(preview.path, .preview) }.sync([library])
        let asset = try #require(try store.files(under: [library.path]).first)
        let elsewhere = folder.appendingPathComponent(inACopy ? "Copy.photoslibrary" : "elsewhere")
        let copy = inACopy ? elsewhere.appendingPathComponent(derivatives).appendingPathComponent(previewName)
            : elsewhere.appendingPathComponent("copy.jpeg")
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: preview, to: copy)

        let roots = libraryFirst ? [library, elsewhere] : [elsewhere, library]
        // (The crawl spells a chosen library as it's chosen: /var where the disk says /private/var.)
        let sync = try indexer(store) { path in
            (path as NSString).lastPathComponent == library.lastPathComponent ? listing(listed[0].path, .original)
                : listing(copy.path, .preview)
        }.sync(roots)
        #expect(sync.changed == 1 && sync.added == 1 && sync.moved == 0 && sync.removed == 0)
        let rows = Dictionary(uniqueKeysWithValues: try store.files(under: roots.map(\.path)).map { ($0.path, $0.id) })
        #expect(rows[listed[0].path] == asset.id)
        let other = try #require(rows[copy.path])
        #expect(other != asset.id)
        let facts = try photosFacts(of: asset.id, in: store)
        #expect(facts.readings == ["original"] && facts.located == ["photos"] && facts.info == 1)
        let its = try photosFacts(of: other, in: store)
        if inACopy {
            #expect(its.readings == ["preview"] && its.located == ["photos"] && its.info == 1)
        } else {
            #expect(its.readings.isEmpty && its.located.isEmpty && its.info == 0)
        }
    }

    /// A file whose row moves by its inode stays on its side of a library's edge: a library's file that leaves the
    /// library (its asset gone from Photos, the file moved out) is a new file outside, and its old row goes with all
    /// Photos said about it; a file moved into a library is a new file of it, without its own location.
    @Test func aFileMovedAcrossALibrarysEdgeIsANewFile() throws {
        let (library, listed) = try library(1, in: folder)
        let katie = PhotosLibrary.Person(uuid: "P-KATIE", name: "Katie")
        let elsewhere = folder.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let roots = [elsewhere, library]
        let store = try IndexStore(directory: folder.appendingPathComponent("index"))
        let photographed = asset(listed[0], favorite: true, at: (51.5, -0.13), people: [katie])
        _ = try indexer(store) { _ in PhotosLibrary.Listing(assets: [photographed], people: [katie]) }.sync(roots)
        let asset = try #require(try store.files(under: [library.path]).first)

        // Out: the asset deleted in Photos, its file moved elsewhere.
        let out = elsewhere.appendingPathComponent("out.jpeg")
        try FileManager.default.moveItem(atPath: listed[0].path, toPath: out.path)
        let left = try indexer(store) { _ in PhotosLibrary.Listing(assets: []) }.sync(roots)
        #expect(left.moved == 0 && left.added == 1 && left.removed == 1)
        let outside = try #require(try store.files(under: [elsewhere.path]).first)
        #expect(outside.id != asset.id && outside.path == out.path)
        let none = try photosFacts(of: outside.id, in: store)
        #expect(none.readings.isEmpty && none.located.isEmpty && none.info == 0)
        #expect(try store.photosPeople().isEmpty)

        // In: a picture read elsewhere, with its own GPS tags, moved into the library as a new asset's original.
        try store.setLocation(try #require(Location(latitude: 25.79, longitude: -80.13, source: .exif)), of: outside.id)
        let uuid = UUID().uuidString
        let inside = library.appendingPathComponent("originals/F/\(uuid).jpeg")
        try FileManager.default.moveItem(at: out, to: inside)
        let imported = PhotosLibrary.Asset(uuid: uuid, path: inside.path, movie: false, screenshot: false,
                                           title: "out.jpeg", date: 1_700_000_000, words: ["out.jpeg"])
        let came = try indexer(store) { _ in PhotosLibrary.Listing(assets: [imported]) }.sync(roots)
        #expect(came.moved == 0 && came.added == 1 && came.removed == 1)
        let row = try #require(try store.files(under: [library.path]).first)
        #expect(row.id != outside.id && row.path == inside.path)
        let facts = try photosFacts(of: row.id, in: store)
        #expect(facts.readings == ["original"] && facts.located.isEmpty && facts.info == 1)
    }

    @Test func anIndexFromBeforeTheReadingAndOriginsGetsThemAtTheNextSync() throws {
        let (library, listed) = try library(2, in: folder)
        let assets = [asset(listed[0], importedBy: 1, app: "com.apple.camera", camera: "iPhone 15 Pro"), listed[1]]
        let index = folder.appendingPathComponent("index")
        let first = try IndexStore(directory: index)
        _ = try indexer(first) { _ in PhotosLibrary.Listing(assets: assets) }.sync([library])
        // As the fork's first step left an index: one row a library file, with its favorite alone.
        try first.db.execute("""
            DROP TABLE photos_assets;
            CREATE TABLE photos_assets(
                file INTEGER PRIMARY KEY REFERENCES files(id) ON DELETE CASCADE,
                favorite INTEGER NOT NULL CHECK (favorite IN (0, 1))
            );
            INSERT INTO photos_assets(file, favorite) SELECT id, 0 FROM files;
            UPDATE meta SET value = '1' WHERE key = 'fork_photos_facts';
            """)
        // Step 2 makes the table again, empty: every row is the sync's.
        let store = try IndexStore(directory: index)
        var columns: [String] = [], rows = 0, version: Int64 = 0
        try store.db.query("SELECT name FROM pragma_table_info('photos_assets')") { columns.append($0.text(0) ?? "") }
        try store.db.query("SELECT COUNT(*) FROM photos_assets") { rows = Int($0.int(0)) }
        try store.db.query("PRAGMA user_version") { version = $0.int(0) }
        #expect(columns == ["file", "favorite", "reading", "origin", "origin_app", "camera"] && rows == 0)
        #expect(try store.meta("fork_photos_facts") == "2" && version == 5)

        // The next sync writes them, and reads no file again.
        let sync = try indexer(store) { _ in PhotosLibrary.Listing(assets: assets) }.sync([library])
        #expect(sync.described == 2 && sync.queued.isEmpty && sync.unchanged == 2)
        var written: [String] = []
        try store.db.query("""
            SELECT favorite, reading, origin, coalesce(origin_app, '-'), coalesce(camera, '-') FROM photos_assets
            ORDER BY file
            """) { row in written.append((0..<5).map { row.text(Int32($0)) ?? "" }.joined(separator: " ")) }
        #expect(written == ["0 original camera com.apple.camera iPhone 15 Pro", "0 original unknown - -"])
        let before = try writes(store)
        #expect(try indexer(store) { _ in PhotosLibrary.Listing(assets: assets) }.sync([library]).described == 0)
        #expect(try writes(store) == before)
    }

    #if !os(Windows)
    @Test func whatsHiddenInPhotosIsListedOnlyWhenAskedAndItsListingKeptApart() throws {
        let (library, listed) = try library(1, in: folder)
        // The crawl asks for what the options say.
        var options = IndexOptions()
        options.photos = PhotosLibrary.Reader { _, hidden in
            hidden ? PhotosLibrary.Listing(assets: listed)
                : PhotosLibrary.Listing(assets: [], skipped: ["hidden in Photos": 1])
        }
        #expect(Crawler.crawl([library], options: options).skipped["hidden in Photos"] == 1)
        options.includeHiddenPhotos = true
        #expect(Crawler.crawl([library], options: options).candidates.map(\.path) == [listed[0].path])

        // osxphotos (a stand-in that lists nothing, and notes each run) is asked for one or the other, and a listing
        // kept from one isn't used for the other.
        let program = folder.appendingPathComponent("osxphotos"), runs = folder.appendingPathComponent("runs.txt")
        try """
            #!/bin/sh
            # osxphotos run <script> <library> <output> include-hidden|skip-hidden
            echo "$5" >> '\(runs.path)'
            if [ "$5" = include-hidden ]; then skipped='{}'; else skipped='{"hidden in Photos": 1}'; fi
            printf '{"assets": [], "skipped": %s, "people": [], "albums": []}' "$skipped" > "$4"
            """.write(to: program, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
        let kept = folder.appendingPathComponent("index/photos")
        func listing(hidden: Bool) throws -> PhotosLibrary.Listing {
            try PhotosLibrary.listing(of: library.path, hidden: hidden, program: program.path, keptIn: kept)
        }
        #expect(try listing(hidden: false).skipped == ["hidden in Photos": 1])
        #expect(try listing(hidden: false).skipped == ["hidden in Photos": 1])   // kept
        #expect(try listing(hidden: true).skipped.isEmpty)
        #expect(try listing(hidden: true).skipped.isEmpty)                        // kept
        #expect(try listing(hidden: false).skipped == ["hidden in Photos": 1])
        #expect(try String(contentsOf: runs, encoding: .utf8) == "skip-hidden\ninclude-hidden\nskip-hidden\n")
    }
    #endif

    #if canImport(ImageIO)
    @Test func aLibrarysPictureHasPhotosLocationNeverItsOwn() throws {
        // Both pictures' files carry GPS tags (Miami). Photos says the first was taken in Adelaide (as a location typed
        // or corrected in Photos would), and has no location for the second.
        let (library, listed) = try library(2, in: folder)
        for asset in listed { try ImageTests.writeJPEG(URL(fileURLWithPath: asset.path), at: (25.79, -80.13)) }
        let assets = [asset(listed[0], at: (-34.9, 138.6)), listed[1]]
        let store = try IndexStore(directory: folder.appendingPathComponent("index"))
        var options = IndexOptions()
        options.photos = PhotosLibrary.Reader { _, _ in PhotosLibrary.Listing(assets: assets) }
        let indexer = try Indexer(store: store, options: options, makeEmbedder: { FakeEmbedder() })
        _ = try indexer.sync([library])
        #expect(try indexer.run()["done"] == 2)   // both read: their tags were there to take
        let locations = try store.locations(of: listed.map(\.path))
        #expect(locations.count == 1)
        let adelaide = try #require(locations[listed[0].path])
        #expect(adelaide.source == .photos && adelaide.latitude == -34.9)
    }

    @Test func aVideoInICloudIsReadFromWhatPhotosKeepsOfIt() throws {
        let (library, listed) = try library(2, in: folder)
        // The first: Photos' filmstrip of it, three stills (written out of order), beside a file that isn't one.
        let first = listed[0].uuid, second = listed[1].uuid
        let strip = library.appendingPathComponent("resources/derivatives/cvt/\(first.prefix(1))/\(first)")
        try FileManager.default.createDirectory(at: strip, withIntermediateDirectories: true)
        let stills = (0..<3).map { strip.appendingPathComponent("\(first)_cvt_t000\($0).jpeg") }
        for still in stills.reversed() { try ImageTests.writeJPEG(still) }
        try Data("not a still".utf8).write(to: strip.appendingPathComponent("\(first)_cvt.plist"))
        #expect(PhotosLibrary.filmstrip(startingAt: stills[0].path) == stills.map(\.path))
        // The second: one poster still.
        let previews = library.appendingPathComponent("resources/derivatives/\(second.prefix(1))")
        try FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)
        let poster = previews.appendingPathComponent(second + "_1_105_c.jpeg")
        try ImageTests.writeJPEG(poster)
        let assets = [(listed[0], stills[0], PhotosLibrary.Reading.stills), (listed[1], poster, .poster)].map {
            PhotosLibrary.Asset(uuid: $0.0.uuid, path: $0.1.path, movie: true, screenshot: false, title: $0.0.title,
                                date: $0.0.date, words: $0.0.words, reading: $0.2)
        }
        let store = try IndexStore(directory: folder.appendingPathComponent("index"))
        var options = IndexOptions()
        options.photos = PhotosLibrary.Reader { _, _ in PhotosLibrary.Listing(assets: assets) }
        let indexer = try Indexer(store: store, options: options, makeEmbedder: { FakeEmbedder() })
        _ = try indexer.sync([library])
        #expect(try indexer.run()["done"] == 2)

        // Videos still, each still a frame with its own vector and no time.
        let files = Dictionary(uniqueKeysWithValues: try store.files(under: [library.path]).map { ($0.path, $0) })
        #expect(files.values.map(\.kind) == [.video, .video])
        var frames: [String: [String]] = [:]
        try store.db.query("""
            SELECT f.path, s.kind, s.loc IS NULL, s.vec IS NOT NULL FROM segments s JOIN files f ON f.id = s.file
            WHERE s.kind NOT IN \(IndexStore.crawlKinds) ORDER BY s.id
            """) { row in
            frames[row.text(0) ?? "", default: []].append("\(row.text(1) ?? "") \(row.int(2)) \(row.int(3))")
        }
        #expect(frames == [stills[0].path: Array(repeating: "frame 1 1", count: 3), poster.path: ["frame 1 1"]])
        #expect(try store.info(of: try #require(files[stills[0].path]).id)["frames"] == "3")
        // A result says it's a video in iCloud, read from Photos' stills of it.
        let hits = try Searcher(store: store).search("", queryVector: nil, filter: SearchFilter(origins: ["unknown"]))
        #expect(Set(hits.map { $0.photos?.reading }) == [.stills, .poster])
        // A hit by meaning on the second still shows that still; the poster video shows its poster.
        var onSecond: [Float] = []
        try store.db.query("""
            SELECT s.vec FROM segments s JOIN files f ON f.id = s.file WHERE f.path = ? AND s.kind = 'frame'
            ORDER BY s.id LIMIT 1 OFFSET 1
            """, [.text(stills[0].path)]) { row in
            onSecond = (row.blob(0) ?? Data()).withUnsafeBytes { Array($0.bindMemory(to: Float16.self)).map(Float.init) }
        }
        // Other pictures for it to stand out from (a meaning hit has to, `Searcher.meaning`), on the poster video.
        let other = try #require(files[poster.path]).id
        for index in 0..<60 {
            try store.addSegment(file: other, kind: .image, modality: .image, vector: FakeEmbedder.vector(for: "\(index)"))
        }
        let matched = try Searcher(store: store).search("", queryVector: onSecond)
        #expect(matched.first { $0.path == stills[0].path }?.photos?.still == stills[1].path)
        #expect(hits.first { $0.path == poster.path }?.photos?.still == poster.path)
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
                                                date: 1_700_000_007, reading: .original))
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
        options.photos = PhotosLibrary.Reader { _, _ in
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
        let kept = PhotosLibrary.Kept(library: "/L.photoslibrary", hidden: false, listedAt: 1000, state: state,
                                      listing: PhotosLibrary.Listing(assets: []))
        #expect(kept.isCurrent(library: "/L.photoslibrary", hidden: false, state: state, now: 99_999))
        // A new, edited or downloaded picture: listed again at once.
        let newPicture = PhotosLibrary.State(pictures: "originals/F 11:2", database: state.database)
        #expect(!kept.isCurrent(library: "/L.photoslibrary", hidden: false, state: newPicture, now: 1001))
        // Only the database (Photos writes it all the time): the listing holds for a while.
        let written = PhotosLibrary.State(pictures: state.pictures, database: "Photos.sqlite 6:2")
        #expect(kept.isCurrent(library: "/L.photoslibrary", hidden: false, state: written, now: 1000 + 60))
        #expect(!kept.isCurrent(library: "/L.photoslibrary", hidden: false, state: written, now: 1000 + 600))
        #expect(!kept.isCurrent(library: "/Other.photoslibrary", hidden: false, state: state, now: 1001))
        // Made by another version of the script: made again.
        var older = kept
        older.reader = "0000000000000000"
        #expect(!older.isCurrent(library: "/L.photoslibrary", hidden: false, state: state, now: 1001))
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
