import Foundation
import Testing
@testable import DigUpKit

/// Every matching moment of a recording (`Searcher.moments(of:text:queryVector:zGate:)`): its frames, windows of sound
/// and stretches of speech that stand out for a query, and its stretches of speech that hold the query's words,
/// neighbours merged.
@Suite final class MomentsTests {
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

    /// A unit vector `cosine` like the query, the rest of it unlike it (from `seed`).
    static func vector(_ cosine: Double, _ seed: String) -> [Float] {
        let other = FakeEmbedder.vector(for: seed)
        let rest = (1 - cosine * cosine).squareRoot()
        let mixed = zip(query, other).map { Float(cosine) * $0 + Float(rest) * $1 }
        let norm = mixed.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return mixed.map { $0 / norm }
    }

    /// An index of the recording at `path` with these segments, each `cosine` like the query, and these stretches of
    /// speech, unlike it, among 40 pictures unlike it, as most of an index is unlike any one query, and `notes` short
    /// notes full of the query's words, which keyword search puts before anything else.
    func index(_ path: String, _ kind: FileKind,
               _ segments: [(kind: SegmentKind, loc: Double?, end: Double?, cosine: Double)],
               said: [(loc: Double, end: Double, text: String)] = [], notes: Int = 0) throws -> Searcher {
        let store = try IndexStore(directory: folder.appendingPathComponent("index"))
        for number in 0..<notes {
            let note = try store.insert(Candidate(path: "/notes/\(number).txt", kind: .doc, size: 1, mtime: 1,
                                                  inode: UInt64(1000 + number), device: 1))
            try store.addSegment(file: note, kind: .chunk, modality: .text, loc: 1,
                                 text: "zebra crossing river zebra crossing river")
        }
        for number in 0..<40 {
            let picture = try store.insert(Candidate(path: "/pictures/\(number).jpg", kind: .image, size: 1, mtime: 1,
                                                     inode: UInt64(number + 1), device: 1))
            try store.addSegment(file: picture, kind: .image, modality: .image,
                                 vector: FakeEmbedder.vector(for: "picture \(number)"))
        }
        let file = try store.insert(Candidate(path: path, kind: kind, size: 1, mtime: 1, inode: 100, device: 1))
        for (index, segment) in segments.enumerated() {
            try store.addSegment(file: file, kind: segment.kind, modality: segment.kind == .audio ? .audio : .image,
                                 loc: segment.loc, locEnd: segment.end, vector: Self.vector(segment.cosine, "\(index)"))
        }
        for (index, stretch) in said.enumerated() {
            try store.addSegment(file: file, kind: .speech, modality: .text, loc: stretch.loc, locEnd: stretch.end,
                                 excerpt: stretch.text, text: stretch.text, vector: Self.vector(0, "said \(index)"))
        }
        return try Searcher(store: store)
    }

    /// Frames that match one after the other are one moment, from the first one's start to the last one's end (each
    /// stands for the stretch until the next); a frame between two that doesn't match makes two. The hit counts them.
    @Test func neighbouringFramesThatMatchAreOneMoment() throws {
        let searcher = try index("/videos/river.mov", .video, [
            (.frame, 0.5, 3.5, 0), (.frame, 3.5, 6.5, 1), (.frame, 6.5, 9.5, 1), (.frame, 9.5, 12.5, 0),
            (.frame, 12.5, 15.5, 1), (.frame, 15.5, 18, 0),
        ])
        let moments = try searcher.moments(of: "/videos/river.mov", text: Self.words, queryVector: Self.query)
        #expect(moments.map(\.kind) == [.seen, .seen])
        #expect(moments.map { [$0.start, $0.end] } == [[3.5, 9.5], [12.5, 15.5]])
        let hit = try #require(try searcher.search("", queryVector: Self.query).first)
        #expect(hit.path == "/videos/river.mov" && hit.momentCount == 2)
    }

    /// A frame somewhat like the query, but not enough to stand out (under the search's gate), is no moment; with the
    /// gate under it, it is.
    @Test func aFrameUnderTheGateIsNoMoment() throws {
        let searcher = try index("/videos/river.mov", .video, [
            (.frame, 0.5, 3.5, 1), (.frame, 3.5, 6.5, 0), (.frame, 6.5, 9.5, 0.25), (.frame, 9.5, 12, 0),
        ])
        #expect(try searcher.moments(of: "/videos/river.mov", text: Self.words, queryVector: Self.query).map(\.start)
                == [0.5])
        #expect(try searcher.moments(of: "/videos/river.mov", text: Self.words, queryVector: Self.query, zGate: 1)
                .map(\.start) == [0.5, 6.5])
    }

    /// A video in iCloud read from Photos' stills (frames with no time, written in the filmstrip's order): each still
    /// that matches is a moment at its place in the filmstrip, never merged with the next (stills carry no time).
    @Test func stillsAreMomentsAtTheirPlace() throws {
        let searcher = try index("/videos/beach.mov", .video, [
            (.frame, nil, nil, 0), (.frame, nil, nil, 1), (.frame, nil, nil, 1), (.frame, nil, nil, 0),
            (.frame, nil, nil, 1),
        ])
        let moments = try searcher.moments(of: "/videos/beach.mov", text: Self.words, queryVector: Self.query)
        #expect(moments.map(\.still) == [1, 2, 4])
        #expect(moments.allSatisfy { $0.kind == .seen && $0.start == nil && $0.end == nil })
    }

    /// A window of sound that matches is a moment as long as the window (30 s), though the next one starts 25 s in.
    @Test func aSoundWindowsMomentSpansTheWindow() throws {
        let searcher = try index("/podcasts/sleep.m4a", .audio, [
            (.audio, 0, 30, 0), (.audio, 25, 55, 1), (.audio, 50, 80, 0), (.audio, 75, 96, 0),
        ])
        let moments = try searcher.moments(of: "/podcasts/sleep.m4a", text: Self.words, queryVector: Self.query)
        #expect(moments.count == 1)
        #expect(moments.first?.kind == .heard && moments.first?.start == 25 && moments.first?.end == 55)
    }

    /// A stretch of speech that holds at least half of the query's words is a moment of what's said, with its words,
    /// though what it means doesn't stand out; one with fewer of them isn't. The hit counts it with the frame that
    /// matches.
    @Test func speechWithTheQuerysWordsIsAMoment() throws {
        let searcher = try index("/videos/river.mov", .video, [(.frame, 0.5, 3.5, 0), (.frame, 3.5, 6, 1)],
                                 said: [(1.2, 4.8, "Look, a zebra is crossing the river!"), (7, 9.5, "Just the river.")])
        let moments = try searcher.moments(of: "/videos/river.mov", text: Self.words, queryVector: Self.query)
        let said = moments.filter { $0.kind == .said }
        #expect(moments.count == 2 && said.count == 1)
        #expect(said.first?.start == 1.2 && said.first?.end == 4.8)
        #expect(said.first?.words == "Look, a zebra is crossing the river!")
        let hit = try #require(try searcher.search(Self.words, queryVector: Self.query).first)
        #expect(hit.path == "/videos/river.mov" && hit.momentCount == 2)
    }

    /// A recording found by what it shows counts what's said in it with the query's words, as its preview lists them,
    /// however many files keyword search found the words in before it.
    @Test func aRecordingFoundByMeaningCountsWhatsSaidWithTheQuerysWords() throws {
        let searcher = try index("/videos/clip.mov", .video, [(.frame, 0.5, 3.5, 0), (.frame, 3.5, 6, 1)],
                                 said: [(1.2, 4.8, "Look, a zebra is crossing the river!")], notes: 100)
        let hit = try #require(try searcher.search(Self.words, queryVector: Self.query, limit: 200)
            .first { $0.path == "/videos/clip.mov" })
        #expect(try searcher.moments(of: "/videos/clip.mov", text: Self.words, queryVector: Self.query).count == 2)
        #expect(hit.momentCount == 2)
    }
}
