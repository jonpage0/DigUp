import Foundation
import Testing
@testable import DigUpKit

/// A detector without a model: every picture gets the same levels, under a model's name of the test's choosing. Counts
/// the pictures it was asked about.
final class FakeRater: PictureRater {
    let model: String
    let levels: SensitiveLevels
    private(set) var rated = 0

    init(model: String = "fake detector", levels: SensitiveLevels) {
        (self.model, self.levels) = (model, levels)
    }

    func levels(ofPictureAt url: URL) throws -> SensitiveLevels {
        rated += 1
        guard FileManager.default.fileExists(atPath: url.path) else { throw ExtractError.unreadable("no picture") }
        return levels
    }
}

/// How revealing pictures are (`sensitive_scores`): written as pictures are read, gone with their segments, rated once
/// for an index from before, all rated again for another model, and what the Sensitive filter and AI apps go by.
@Suite struct SensitiveTests {
    let folder: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DigUpTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return URL(fileURLWithPath: FolderSelection.realPath(url.path))
    }()

    var pictures: URL { folder.appendingPathComponent("pictures") }
    var index: URL { folder.appendingPathComponent("index") }

    static let revealing = SensitiveLevels(low: 0.2, medium: 0.3, high: 0.1)
    static let neutral = SensitiveLevels(low: 0.02, medium: 0.01, high: 0)

    /// Copies of ImageTests' 400 × 240 picture, under these names.
    func makePictures(_ names: [String]) throws -> [String] {
        try FileManager.default.createDirectory(at: pictures, withIntermediateDirectories: true)
        return try names.map { name in
            let url = pictures.appendingPathComponent(name)
            try FileManager.default.copyItem(at: ImageTests.pictures.appendingPathComponent("pattern-o6.jpg"), to: url)
            return url.path
        }
    }

    func makeIndexer(_ store: IndexStore, rater: (any PictureRater)?) throws -> Indexer {
        try Indexer(store: store, options: IndexOptions(), rater: rater, makeEmbedder: { FakeEmbedder() })
    }

    /// The ratings, by the path of the file each picture is of.
    func ratings(in store: IndexStore) throws -> [String: [SensitiveLevels]] {
        var found: [String: [SensitiveLevels]] = [:]
        try store.db.query("""
            SELECT f.path, r.low, r.medium, r.high FROM sensitive_scores r JOIN segments s ON s.id = r.segment
            JOIN files f ON f.id = s.file
            """) { found[$0.text(0) ?? "", default: []].append(SensitiveLevels(low: $0.double(1), medium: $0.double(2),
                                                                                  high: $0.double(3))) }
        return found
    }

    @Test func picturesAreRatedAsTheyAreReadAndTheirRatingsGoWithThem() throws {
        let paths = try makePictures(["a.jpg", "b.jpg"])
        let store = try IndexStore(directory: index)
        let rater = FakeRater(model: "detector 1", levels: Self.revealing)
        let indexer = try makeIndexer(store, rater: rater)
        _ = try indexer.sync([pictures])
        try indexer.run()
        // Each picture's image segment, with the levels the detector gave, and the model recorded.
        #expect(try ratings(in: store) == [paths[0]: [Self.revealing], paths[1]: [Self.revealing]])
        #expect(rater.rated == 2)
        #expect(try store.meta(IndexStore.sensitiveModelKey) == "detector 1")
        #expect(try store.sensitiveCounts() == (rated: 2, waiting: 0))
        // A picture that changed is read again: its rating went with its old segments, and it gets a new one.
        try FileManager.default.removeItem(atPath: paths[0])
        try FileManager.default.copyItem(at: ImageTests.pictures.appendingPathComponent("pattern-o6.heic"),
                                         to: URL(fileURLWithPath: paths[0]))
        _ = try indexer.sync([pictures])
        #expect(try ratings(in: store) == [paths[1]: [Self.revealing]])
        try indexer.run()
        #expect(try ratings(in: store).keys.sorted() == paths.sorted())
        // A picture deleted takes its rating with it.
        try FileManager.default.removeItem(atPath: paths[1])
        _ = try indexer.sync([pictures])
        #expect(try ratings(in: store).keys.sorted() == [paths[0]])
    }

    @Test func theRatingPassRatesWhatWasReadBeforeAndPassesOverWhatIsAway() throws {
        // Read before pictures were rated: no detector then.
        let paths = try makePictures(["a.jpg", "b.jpg", "c.jpg"])
        let store = try IndexStore(directory: index)
        let before = try makeIndexer(store, rater: nil)
        _ = try before.sync([pictures])
        try before.run()
        #expect(try ratings(in: store).isEmpty && store.sensitiveCounts() == (rated: 0, waiting: 3))
        // One is away now (gone, as one on an unplugged drive or only in iCloud is, whose `FileSystem.info` says
        // dataless): it isn't opened, and it waits.
        try FileManager.default.removeItem(atPath: paths[2])
        let rater = FakeRater(levels: Self.neutral)
        let indexer = try makeIndexer(store, rater: rater)
        var steps: [Indexer.Rating] = []
        #expect(try indexer.ratePictures(onStep: { steps.append($0) }) == 2)
        #expect(rater.rated == 2)
        #expect(try ratings(in: store) == [paths[0]: [Self.neutral], paths[1]: [Self.neutral]])
        #expect(steps.map(\.done) == [1, 2, 3] && steps.allSatisfy { $0.total == 3 })
        #expect(try store.sensitiveCounts() == (rated: 2, waiting: 1))
        // Each picture once a process: the one away isn't tried again until the next.
        #expect(try indexer.ratePictures() == 0 && rater.rated == 2)
        // Stopped before its first file, the pass rates nothing.
        #expect(try makeIndexer(store, rater: rater).ratePictures(shouldStop: { true }) == 0)
    }

    @Test func anotherModelsRatingsAreAllDeletedAndEachPictureIsRatedAgain() throws {
        let paths = try makePictures(["a.jpg", "b.jpg"])
        let store = try IndexStore(directory: index)
        let first = try makeIndexer(store, rater: FakeRater(model: "detector 1", levels: Self.revealing))
        _ = try first.sync([pictures])
        try first.run()
        #expect(try store.sensitiveCounts() == (rated: 2, waiting: 0))
        // The same model again: nothing goes.
        #expect(try store.adoptSensitiveModel("detector 1") == 0)
        // Another one: every rating goes at once, never mixed with its own, and the pass rates them all again.
        let second = try makeIndexer(store, rater: FakeRater(model: "detector 2", levels: Self.neutral))
        #expect(try store.meta(IndexStore.sensitiveModelKey) == "detector 2")
        #expect(try store.sensitiveCounts() == (rated: 0, waiting: 2))
        #expect(try second.ratePictures() == 2)
        #expect(try ratings(in: store) == [paths[0]: [Self.neutral], paths[1]: [Self.neutral]])
    }

    @Test func anIndexerWhoseModelWasReplacedWritesNoRating() throws {
        let paths = try makePictures(["a.jpg", "b.jpg"])
        let store = try IndexStore(directory: index)
        let old = try makeIndexer(store, rater: FakeRater(model: "detector 1", levels: Self.revealing))
        _ = try old.sync([pictures])
        try old.run()
        // Another model takes the ratings over while the first indexer is still at work (the app's helper and
        // `digup index`, say): its ratings all go, and the first one's later ratings aren't written.
        let newer = try makeIndexer(try IndexStore(directory: index),
                                    rater: FakeRater(model: "detector 2", levels: Self.neutral))
        #expect(try ratings(in: store).isEmpty)
        #expect(try old.ratePictures() == 0)
        let third = try makePictures(["c.jpg"])[0]
        _ = try old.sync([pictures])
        try old.run()
        #expect(try ratings(in: store).isEmpty)
        #expect(try store.meta(IndexStore.sensitiveModelKey) == "detector 2")
        // The model that has them rates every picture.
        #expect(try newer.ratePictures() == 3)
        #expect(try ratings(in: store) == [paths[0]: [Self.neutral], paths[1]: [Self.neutral], third: [Self.neutral]])
    }

    /// The model `add` writes ratings as.
    static let model = "test detector"

    /// A picture file read, with an image segment rated `levels` (nil: not rated) by `model`, or a video with frames
    /// rated so.
    @discardableResult
    func add(_ path: String, kind: FileKind = .image, state: String = "done", levels: [SensitiveLevels?],
             text: String? = nil, in store: IndexStore) throws -> Int64 {
        try store.adoptSensitiveModel(Self.model)
        let id = try store.insert(Candidate(path: path, kind: kind, size: 1, mtime: 1,
                                            inode: UInt64(abs(path.hashValue) % 1_000_000), device: 1))
        for (place, rating) in levels.enumerated() {
            let segment = try store.addSegment(file: id, kind: kind == .video ? .frame : .image, modality: .image,
                                               loc: kind == .video ? Double(place * 3) : nil)
            if let rating { try store.setSensitive(rating, ofSegment: segment, model: Self.model) }
        }
        if let text { try store.addSegment(file: id, kind: kind == .doc ? .chunk : .ocr, modality: .text, text: text) }
        if state != "pending" { try store.finish(id, state: state) }
        return id
    }

    @Test func theSensitiveFilterKeepsWhatEachPositionFlags() throws {
        let store = try IndexStore(directory: index)
        let levels = [
            "/p/quiet.jpg": SensitiveLevels(low: 0.15, medium: 0.03, high: 0),         // low+ 0.18
            "/p/swimwear.jpg": SensitiveLevels(low: 0.25, medium: 0, high: 0),         // low+ 0.25
            "/p/revealing.jpg": SensitiveLevels(low: 0.3, medium: 0.15, high: 0.1),    // low+ 0.55, medium+ 0.25
            "/p/nude.jpg": SensitiveLevels(low: 0.05, medium: 0.3, high: 0.3),         // low+ 0.65, medium+ 0.6
        ]
        for (path, rating) in levels { try add(path, levels: [rating], in: store) }
        // A video by any of its frames; a picture not rated by none.
        try add("/p/clip.mov", kind: .video, levels: [Self.neutral, SensitiveLevels(low: 0, medium: 0.6, high: 0)],
                in: store)
        try add("/p/unrated.jpg", levels: [nil], in: store)
        let searcher = try Searcher(store: store, loadVectors: false)
        let expected: [SensitivePosition: Set<String>] = [
            .anythingRevealing: ["/p/swimwear.jpg", "/p/revealing.jpg", "/p/nude.jpg", "/p/clip.mov"],
            .revealing: ["/p/revealing.jpg", "/p/nude.jpg", "/p/clip.mov"],
            .nudityOnly: ["/p/nude.jpg", "/p/clip.mov"],
        ]
        for (position, kept) in expected {
            var filter = SearchFilter()
            filter.sensitive = position
            #expect(Set(try searcher.browse(filter, kinds: nil, limit: 50).map(\.path)) == kept)
            // The SQL and the app's blurring read the levels alike.
            #expect(Set(levels.filter { position.flags($0.value) }.keys) == kept.subtracting(["/p/clip.mov"]))
        }
        #expect(SensitivePosition.off.filterPosition == .revealing)
        #expect(SensitivePosition.nudityOnly.filterPosition == .nudityOnly)
        // A video's most revealing frame, as the positions read it.
        let most = try #require(SensitiveLevels.most(of: [SensitiveLevels(low: 0.5, medium: 0, high: 0),
                                                          SensitiveLevels(low: 0, medium: 0.1, high: 0.3)]))
        #expect(abs(most.lowOrHigher - 0.5) < 1e-9 && abs(most.mediumOrHigher - 0.4) < 1e-9 && most.high == 0.3)
    }

    @Test func aClickShowsThePictureClickedAndNoOtherOfItsFile() throws {
        // A video with an ordinary still and a revealing one, as blurring at Revealing sees them.
        let ordinary = SensitivePictures.Picture(segment: 1, loc: nil, levels: Self.neutral)
        let revealing = SensitivePictures.Picture(segment: 2, loc: nil,
                                                  levels: SensitiveLevels(low: 0.6, medium: 0, high: 0))
        let unrated = SensitivePictures.Picture(segment: 3, loc: nil, levels: nil)
        let video = SensitivePictures(path: "/v/clip.mov", read: 1, frames: [ordinary, revealing, unrated])
        let (still, other, thumbnail) = (try #require(video.shown(ordinary)), try #require(video.shown(revealing)),
                                         video.anyFrame)
        var reveal = SensitiveReveal()
        #expect(!reveal.hides(still, at: .revealing) && reveal.hides(other, at: .revealing))
        #expect(!reveal.hides(try #require(video.shown(unrated)), at: .revealing))
        // Quick Look's picture of it could be either still: blurred, as the revealing one is.
        #expect(reveal.hides(thumbnail, at: .revealing))
        // Clicking the ordinary still, or Quick Look's picture, shows the revealing still no more than before.
        let clicks = (still: reveal.reveal(still, at: .revealing), thumbnail: reveal.reveal(thumbnail, at: .revealing))
        #expect(!clicks.still && clicks.thumbnail)
        #expect(!reveal.hides(thumbnail, at: .revealing) && reveal.hides(other, at: .revealing))
        // Only its own click shows it.
        let shown = reveal.reveal(other, at: .revealing)
        #expect(shown && !reveal.hides(other, at: .revealing))
        // Off, nothing is blurred.
        #expect(!SensitiveReveal().hides(other, at: .off))
    }

    @Test func aClickShowsNoOtherPictureThatGetsTheSameSegmentLater() throws {
        // SQLite gives a segment of a picture read later the id of one deleted before (segments' ids are rowids).
        let store = try IndexStore(directory: index)
        let indexer = try makeIndexer(store, rater: FakeRater(levels: Self.revealing))
        func ratings(of path: String) throws -> SensitivePictures {
            try store.sensitivePictures(ofFile: #require(try store.file(at: path, keptBy: SearchFilter())).id)
        }
        func image(_ path: String) throws -> SensitivePictures.Picture { try #require(try ratings(of: path).image) }
        func shown(_ path: String) throws -> SensitiveReveal.Shown {
            let read = try ratings(of: path)
            return try #require(read.shown(read.image))
        }
        let first = try makePictures(["a.jpg"])[0]
        _ = try indexer.sync([pictures])
        try indexer.run()
        var reveal = SensitiveReveal()
        let clicked = try image(first).segment
        #expect(reveal.reveal(try shown(first), at: .revealing))
        // That file goes; another one, rated sensitive too, gets its picture's segment id: it's still blurred.
        try FileManager.default.removeItem(atPath: first)
        _ = try indexer.sync([pictures])
        let other = try makePictures(["b.jpg"])[0]
        _ = try indexer.sync([pictures])
        try indexer.run()
        #expect(try image(other).segment == clicked)
        #expect(reveal.hides(try shown(other), at: .revealing))
        // The same file read again (it changed) is another reading: it's blurred again until it's clicked.
        let again = try makePictures(["c.jpg"])[0]
        _ = try indexer.sync([pictures])
        try indexer.run()
        let read = try image(again).segment
        #expect(reveal.reveal(try shown(again), at: .revealing))
        try FileManager.default.removeItem(atPath: again)
        try FileManager.default.copyItem(at: ImageTests.pictures.appendingPathComponent("pattern-o6.heic"),
                                         to: URL(fileURLWithPath: again))
        _ = try indexer.sync([pictures])
        try indexer.run()
        #expect(try image(again).segment == read)
        #expect(reveal.hides(try shown(again), at: .revealing))
    }

    @Test func aiAppsSeeNoPictureRatedSensitiveNorOneNotRatedYet() throws {
        let store = try IndexStore(directory: index)
        try add("/f/beach notes.txt", kind: .doc, levels: [], text: "beach day", in: store)
        try add("/f/beach plain.jpg", levels: [Self.neutral], text: "beach", in: store)
        try add("/f/beach revealing.jpg", levels: [Self.revealing], text: "beach", in: store)
        try add("/f/beach unrated.jpg", levels: [nil], text: "beach", in: store)
        try add("/f/beach waiting.jpg", state: "pending", levels: [], in: store)       // not read yet
        try add("/f/beach small.jpg", state: "skipped", levels: [], in: store)        // never read: too small
        try add("/f/beach clip.mov", kind: .video, levels: [Self.neutral, Self.neutral], in: store)
        try add("/f/beach half.mov", kind: .video, levels: [Self.neutral, nil], in: store)
        var seen = SearchFilter()
        seen.leavingOutSensitive = .revealing
        let searcher = try Searcher(store: store, loadVectors: false)
        // Left out before anything is matched or listed.
        let shown: Set = ["/f/beach notes.txt", "/f/beach plain.jpg", "/f/beach clip.mov"]
        #expect(Set(try searcher.search("beach", queryVector: nil, filter: seen, limit: 20).map(\.path)) == shown)
        #expect(Set(try searcher.browse(seen, kinds: nil, limit: 20).map(\.path)) == shown)
        // Counted, looked up and read only so.
        #expect(try store.counts(keeping: seen) == [.doc: ["done": 1], .image: ["done": 1], .video: ["done": 1]])
        #expect(try store.file(at: "/f/beach revealing.jpg", keptBy: seen) == nil)
        #expect(try store.words(of: "/f/beach unrated.jpg", keptBy: seen) == nil)
        #expect(try store.words(of: "/f/beach plain.jpg", keptBy: seen)?.map(\.text) == ["beach"])
        // What waits to be rated, which `status` says: not the one rated sensitive, nor the one never read.
        #expect(try store.unratedFiles(keptBy: SearchFilter()) == 3)
        // At a position that doesn't flag it (nudity only: medium or higher at 0.5; it's at 0.4), the revealing
        // picture is seen.
        seen.leavingOutSensitive = .nudityOnly
        #expect(try store.file(at: "/f/beach revealing.jpg", keptBy: seen)?.path == "/f/beach revealing.jpg")
    }

    @Test func theWordsOfFilesLeftOutOfAnAIAppsSightDontBearOnItsSearch() throws {
        // A word that's in no file an AI app may see matches as the start of longer words, as one in no file at all
        // does: one left out (rated sensitive, or a hidden Photos item) having it as typed changes nothing.
        let store = try IndexStore(directory: index)
        try add("/f/notes.txt", kind: .doc, levels: [], text: "reviewtokenextended", in: store)
        try add("/f/revealing.jpg", levels: [Self.revealing], text: "reviewtoken", in: store)
        try add("/f/more notes.txt", kind: .doc, levels: [], text: "hiddentokenextended", in: store)
        try add("/f/Library.photoslibrary/originals/A/hidden.jpg", levels: [Self.neutral], text: "hiddentoken",
                in: store)
        let searcher = try Searcher(store: store, loadVectors: false)
        func found(_ text: String, _ filter: SearchFilter) throws -> Set<String> {
            Set(try searcher.search(text, queryVector: nil, filter: filter, limit: 20).map(\.path))
        }
        var sensitive = SearchFilter()
        sensitive.leavingOutSensitive = .revealing
        #expect(try found("reviewtoken", sensitive) == ["/f/notes.txt"])
        var photos = SearchFilter()
        photos.photosOnly = []
        #expect(try found("hiddentoken", photos) == ["/f/more notes.txt"])
        // Where nothing is left out (DigUp's own window), a word in a file stays whole, as before.
        #expect(try found("reviewtoken", SearchFilter()) == ["/f/revealing.jpg"])
        #expect(try found("hiddentoken", SearchFilter()) == ["/f/Library.photoslibrary/originals/A/hidden.jpg"])
    }
}
