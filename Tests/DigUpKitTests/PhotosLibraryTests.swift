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
    }
}
