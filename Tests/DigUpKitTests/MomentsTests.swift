import Foundation
import Testing
@testable import DigUpKit

/// Every matching moment of a recording (`Searcher.moments(of:queryVector:zGate:)`): its frames and windows of sound
/// that stand out for a query, neighbours merged.
@Suite final class MomentsTests {
    let folder: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DigUpTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    static let query = FakeEmbedder.vector(for: "a zebra crossing a river")

    /// A unit vector `cosine` like the query, the rest of it unlike it (from `seed`).
    static func vector(_ cosine: Double, _ seed: String) -> [Float] {
        let other = FakeEmbedder.vector(for: seed)
        let rest = (1 - cosine * cosine).squareRoot()
        let mixed = zip(query, other).map { Float(cosine) * $0 + Float(rest) * $1 }
        let norm = mixed.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return mixed.map { $0 / norm }
    }

    /// An index of the recording at `path` with these segments, each `cosine` like the query, among 40 pictures unlike
    /// it, as most of an index is unlike any one query.
    func index(_ path: String, _ kind: FileKind,
               _ segments: [(kind: SegmentKind, loc: Double?, end: Double?, cosine: Double)]) throws -> Searcher {
        let store = try IndexStore(directory: folder.appendingPathComponent("index"))
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
        return try Searcher(store: store)
    }

    /// Frames that match one after the other are one moment, from the first one's start to the last one's end (each
    /// stands for the stretch until the next); a frame between two that doesn't match makes two. The hit counts them.
    @Test func neighbouringFramesThatMatchAreOneMoment() throws {
        let searcher = try index("/videos/river.mov", .video, [
            (.frame, 0.5, 3.5, 0), (.frame, 3.5, 6.5, 1), (.frame, 6.5, 9.5, 1), (.frame, 9.5, 12.5, 0),
            (.frame, 12.5, 15.5, 1), (.frame, 15.5, 18, 0),
        ])
        let moments = try searcher.moments(of: "/videos/river.mov", queryVector: Self.query)
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
        #expect(try searcher.moments(of: "/videos/river.mov", queryVector: Self.query).map(\.start) == [0.5])
        #expect(try searcher.moments(of: "/videos/river.mov", queryVector: Self.query, zGate: 1).map(\.start)
                == [0.5, 6.5])
    }

    /// A video in iCloud read from Photos' stills (frames with no time, written in the filmstrip's order): each still
    /// that matches is a moment at its place in the filmstrip, never merged with the next (stills carry no time).
    @Test func stillsAreMomentsAtTheirPlace() throws {
        let searcher = try index("/videos/beach.mov", .video, [
            (.frame, nil, nil, 0), (.frame, nil, nil, 1), (.frame, nil, nil, 1), (.frame, nil, nil, 0),
            (.frame, nil, nil, 1),
        ])
        let moments = try searcher.moments(of: "/videos/beach.mov", queryVector: Self.query)
        #expect(moments.map(\.still) == [1, 2, 4])
        #expect(moments.allSatisfy { $0.kind == .seen && $0.start == nil && $0.end == nil })
    }

    /// A window of sound that matches is a moment as long as the window (30 s), though the next one starts 25 s in.
    @Test func aSoundWindowsMomentSpansTheWindow() throws {
        let searcher = try index("/podcasts/sleep.m4a", .audio, [
            (.audio, 0, 30, 0), (.audio, 25, 55, 1), (.audio, 50, 80, 0), (.audio, 75, 96, 0),
        ])
        let moments = try searcher.moments(of: "/podcasts/sleep.m4a", queryVector: Self.query)
        #expect(moments.count == 1)
        #expect(moments.first?.kind == .heard && moments.first?.start == 25 && moments.first?.end == 55)
    }
}
