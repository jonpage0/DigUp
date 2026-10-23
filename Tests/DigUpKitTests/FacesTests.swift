import Foundation
import Testing
@testable import DigUpKit
#if canImport(Vision) && canImport(CoreML)
import CoreGraphics
#endif

/// Telling people apart by their faces (`Faces`): the alignment's arithmetic, the comparison, and the measurement
/// `digup faces-eval` reports.
@Suite struct FacesTests {
    /// A turn by 25°, a scale of 2 and a shift, as `Similarity` spells it.
    static let move = Faces.Similarity(a: 2 * cos(25 * Double.pi / 180), b: 2 * sin(25 * Double.pi / 180),
                                       tx: 120, ty: 20)

    @Test func theSimilarityFoundIsTheOneThatMovedThePoints() throws {
        let template = Faces.template(side: Faces.arcFaceSide)
        let moved = template.map(Self.move.applied(to:))
        let found = try #require(Faces.Similarity(taking: template, to: moved))
        for (value, expected) in [(found.a, Self.move.a), (found.b, Self.move.b), (found.tx, Self.move.tx),
                                  (found.ty, Self.move.ty)] {
            #expect(abs(value - expected) < 1e-9)
        }
        // Nothing to go by: no points, points all in one place, or lists that don't pair up.
        #expect(Faces.Similarity(taking: [], to: []) == nil)
        let one = Faces.Point(x: 3, y: 4)
        #expect(Faces.Similarity(taking: [one, one], to: Array(template.prefix(2))) == nil)
        #expect(Faces.Similarity(taking: template, to: Array(moved.prefix(4))) == nil)
    }

    @Test func cosineComparesDirectionsNotLengths() {
        #expect(Faces.cosine([1, 0], [2, 0]) == 1)
        #expect(Faces.cosine([1, 0], [0, 3]) == 0)
        #expect(abs(Faces.cosine([1, 1], [-1, -1]) + 1) < 1e-6)
        #expect(Faces.cosine([0, 0], [1, 0]) == 0)          // no direction
        #expect(Faces.cosine([1, 0, 0], [1, 0]) == 0)       // not the same recognizer's
    }

    /// Two people of two faces each, one person of one face, and two faces nobody named: each named face is called by
    /// the nearest of the others, each unnamed one by the nearest named face.
    @Test func eachFaceIsCalledByItsNearestNamedFace() {
        let (a, b, c) = (PhotosLibrary.Person(uuid: "A", name: "A"), PhotosLibrary.Person(uuid: "B", name: "B"),
                         PhotosLibrary.Person(uuid: "C", name: "C"))
        let named: [(person: PhotosLibrary.Person, embedding: [Float])] = [
            (a, [1, 0]), (a, [0.6, 0.8]),     // nearer B's faces (0.91 at most) than A's other (0.6): called B
            (b, [0, 1]), (b, [0.2, 0.9]),
            (c, [-1, 0]),                     // no other face of C's: left out
        ]
        let measure = Faces.Measure(named: named, others: [[0.7, 0.7], [-0.5, -0.5]], similarity: Faces.cosine)
        #expect(measure.alone == 1)
        #expect(measure.calls.map(\.right) == [true, false, true, true])
        #expect(measure.nearestRight == 0.75)
        #expect(measure.rates(at: 0.5) == Faces.Measure.Rates(right: 0.75, wrong: 0.25, uncalled: 0, others: 1))
        // At 0.7, A's [1, 0] (0.6 from A's other face) isn't called; the face nearest C's (0.71) still is.
        #expect(measure.rates(at: 0.7) == Faces.Measure.Rates(right: 0.5, wrong: 0.25, uncalled: 0.25, others: 1))
        // At 0.8, only the face nearly on A's [0.6, 0.8] (0.99) is still called someone.
        #expect(measure.rates(at: 0.8).others == 0.5)
        #expect(measure.rates(at: 0.995) == Faces.Measure.Rates(right: 0, wrong: 0, uncalled: 1, others: 0))
    }

    /// Two people Photos keeps apart though they share a name are two people: the one with a single face is left out,
    /// and a face whose nearest is the other one's is called wrong.
    @Test func peopleOfOneNameStayTwoPeople() {
        let sam = PhotosLibrary.Person(uuid: "S1", name: "Sam")
        let otherSam = PhotosLibrary.Person(uuid: "S2", name: "Sam")
        let ana = PhotosLibrary.Person(uuid: "A", name: "Ana")
        let named: [(person: PhotosLibrary.Person, embedding: [Float])] = [
            (sam, [1, 0]),                                  // no other face of this Sam's: left out
            (otherSam, [0.9, 0.1]), (otherSam, [0, 1]),     // the first is nearest the other Sam's [1, 0]: wrong
            (ana, [-1, 0]), (ana, [-0.9, -0.1]),
        ]
        let measure = Faces.Measure(named: named, others: [], similarity: Faces.cosine)
        #expect(measure.alone == 1)
        #expect(measure.calls.map(\.right) == [false, true, true, true])
    }

    #if canImport(Vision) && canImport(CoreML)
    /// A picture with five colored dots where a face's five points would be, turned, scaled and moved (`move`): aligned,
    /// each dot lands on its point of the template.
    @Test func aligningPutsTheFivePointsOnTheTemplate() throws {
        let (width, height) = (400, 300)
        let colors: [(CGFloat, CGFloat, CGFloat)] = [(1, 0, 0), (0, 1, 0), (0, 0, 1), (1, 1, 0), (1, 0, 1)]
        let points = Faces.template(side: Faces.arcFaceSide).map(Self.move.applied(to:))
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for (point, color) in zip(points, colors) {   // points are from the top, Core Graphics from the bottom
            context.setFillColor(CGColor(srgbRed: color.0, green: color.1, blue: color.2, alpha: 1))
            context.fillEllipse(in: CGRect(x: point.x - 6, y: Double(height) - point.y - 6, width: 12, height: 12))
        }
        let picture = try #require(context.makeImage())

        let side = Int(Faces.arcFaceSide)
        let aligned = try #require(Faces.aligned(picture, points: points, side: side))
        var rgba = [UInt8](repeating: 0, count: side * side * 4)
        let reading = try #require(CGContext(data: &rgba, width: side, height: side, bitsPerComponent: 8,
                                             bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        reading.draw(aligned, in: CGRect(x: 0, y: 0, width: side, height: side))
        func pixel(_ point: Faces.Point) -> (Int, Int, Int) {
            let index = (Int(point.y) * side + Int(point.x)) * 4   // the first row is the top one
            return (Int(rgba[index]), Int(rgba[index + 1]), Int(rgba[index + 2]))
        }
        for (point, color) in zip(Faces.template(side: Faces.arcFaceSide), colors) {
            let (red, green, blue) = pixel(point)
            #expect((red > 200, green > 200, blue > 200) == (color.0 == 1, color.1 == 1, color.2 == 1),
                    "at \(point): \(red), \(green), \(blue)")
            #expect((red < 60, green < 60, blue < 60) == (color.0 == 0, color.1 == 0, color.2 == 0),
                    "at \(point): \(red), \(green), \(blue)")
        }
        let (red, green, blue) = pixel(Faces.Point(x: 56, y: 30))   // the forehead: the gray around the dots
        #expect(abs(red - 128) <= 2 && abs(green - 128) <= 2 && abs(blue - 128) <= 2)
    }
    #endif

    /// A face outside Photos is its nearest reference's person when it's at least the floor alike, never a name.
    @Test func aFaceMatchesItsNearestNamedFaceAtTheFloorOrMore() {
        let matcher = FaceMatcher(references: [(1, [1, 0, 0]), (2, [0, 2, 0]), (3, [0.6, 0.8, 0]), (4, [1, 0])])
        let matches = matcher.matches([[0.81, 0, 0.586], [0.79, 0, 0.613], [0, 1, 0.1], [0, 0, 1], [1, 0], [0, 0, 0]])
        #expect(matches[0]?.person == 1 && abs((matches[0]?.similarity ?? 0) - 0.81) < 0.001)
        #expect(matches[1] == nil)                     // below the floor
        #expect(matches[2]?.person == 2)               // lengths don't count, only directions
        #expect(matches[3] == nil && matches[4] == nil && matches[5] == nil)   // no one; another length; nothing
        #expect(Faces.matchFloor == 0.8 && Faces.threshold == 0.9)
        #expect(FaceMatcher(references: []).matches([[1, 0, 0]]) == [nil])
    }

    /// Photos' box (its center from the bottom-left, its side over the long side) becomes the index's: from the top-left,
    /// in fractions of each side, inside the picture.
    @Test func photosBoxesAreKeptFromTheTopLeftInsideThePicture() throws {
        let face = PhotosLibrary.FaceBox(person: nil, x: 0.5, y: 0.75, size: 0.25)
        let box = try #require(Faces.Box(face, width: 400, height: 300))   // a side of 100 pixels
        #expect(abs(box.x - 0.375) < 1e-9 && abs(box.y - (0.25 - 1.0 / 6)) < 1e-9)
        #expect(abs(box.width - 0.25) < 1e-9 && abs(box.height - 1.0 / 3) < 1e-9)
        let edge = try #require(Faces.Box(PhotosLibrary.FaceBox(person: nil, x: 0.95, y: 0.02, size: 0.2), width: 100,
                                          height: 100))
        // Over the right and bottom edges: what's inside.
        #expect(abs(edge.x - 0.85) < 1e-9 && abs(edge.x + edge.width - 1) < 1e-9)
        #expect(abs(edge.y - 0.88) < 1e-9 && abs(edge.y + edge.height - 1) < 1e-9)
        #expect(Faces.Box(x: 1.2, y: 0.5, width: 0.1, height: 0.1) == nil)   // none of it inside
    }

    /// The listing's named faces, and a listing kept from before they were listed.
    @Test func aListingSaysTheFacesPhotosNamedOrNothingAboutThem() throws {
        let asset = #"{"uuid": "U", "path": "/L.photoslibrary/originals/U.jpeg", "reading": "original", "movie": false, "#
            + #""screenshot": false, "title": "", "date": 0, "words": [], "favorite": false, "people": ["P"], "#
            + #""albums": []"#
        let named = try JSONDecoder().decode(PhotosLibrary.Asset.self, from: Data((asset + #", "faces": [{"person": "#
            + #"{"uuid": "P", "name": "Katie"}, "x": 0.5, "y": 0.4, "size": 0.2}]}"#).utf8))
        #expect(named.faces == [PhotosLibrary.FaceBox(person: PhotosLibrary.Person(uuid: "P", name: "Katie"), x: 0.5,
                                                      y: 0.4, size: 0.2)])
        #expect(try JSONDecoder().decode(PhotosLibrary.Asset.self, from: Data((asset + "}").utf8)).faces == nil)
    }

    @Test func aPictureKeptByAFaceSaysWhose() {
        func reason(meaning: Bool = false, words: Bool = false, faces: [String]) -> String {
            MatchDescription.reason(.image, kind: .image, loc: nil, locEnd: nil, meaning: meaning, words: words,
                                    listed: !meaning && !words, reading: nil, faces: faces)
        }
        #expect(reason(faces: ["Tatiana Rotari"]) == "Tatiana Rotari, by their face")
        #expect(reason(faces: ["Katie", "Sam"]) == "Katie and Sam, by their faces")
        #expect(reason(faces: ["Sam", "Sam"]) == "Sam, by their faces")   // two people of one name
        #expect(reason(meaning: true, faces: ["Katie"]) == "Matches the picture · Katie, by their face")
        #expect(reason(faces: []) == "Fits your filters")
    }
}

#if canImport(ImageIO)
/// Faces read by a reader that knows each picture's faces from its name, prints and all: no Vision. What the index
/// keeps (`faces`, `face_matches`), the faces pass, and what the People filter keeps.
final class FakeFaceReader: FaceReader, @unchecked Sendable {
    let identity: String
    /// A named face's print, by its person's uuid in Photos.
    let people: [String: [Float]]
    /// The prints of the faces in a picture outside Photos, by its file's name.
    let found: [String: [[Float]]]
    /// The pictures read, by file name (the indexer's preparing thread writes it; the test reads it once it's done).
    private(set) var read: [String] = []

    init(_ identity: String, people: [String: [Float]], found: [String: [[Float]]]) {
        (self.identity, self.people, self.found) = (identity, people, found)
    }

    func faces(inPictureAt url: URL, named: [PhotosLibrary.FaceBox]?) throws -> [Faces.Found] {
        read.append(url.lastPathComponent)
        guard let named else {
            return (found[url.lastPathComponent] ?? []).enumerated().compactMap { index, print in
                Faces.Box(x: 0.1 + 0.4 * Double(index), y: 0.2, width: 0.3, height: 0.3)
                    .map { Faces.Found(box: $0, print: print, named: nil) }
            }
        }
        return named.enumerated().compactMap { index, face in
            guard let print = face.person.flatMap({ people[$0.uuid] }), let box = Faces.Box(face, width: 400, height: 300)
            else { return nil }
            return Faces.Found(box: box, print: print, named: index)
        }
    }
}

@Suite struct FaceIndexTests {
    let folder: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DigUpTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return URL(fileURLWithPath: FolderSelection.realPath(url.path))
    }()

    static let katie = PhotosLibrary.Person(uuid: "P-KATIE", name: "Katie")
    static let sam = PhotosLibrary.Person(uuid: "P-SAM", name: "Sam")
    static let otherSam = PhotosLibrary.Person(uuid: "P-SAM-2", name: "Sam")
    /// Each person's print, one direction each; the fourth is no one's.
    static let prints: [String: [Float]] = ["P-KATIE": [1, 0, 0, 0], "P-SAM": [0, 1, 0, 0], "P-SAM-2": [0, 0, 1, 0]]

    /// A print `cosine` alike to direction `axis`'s, and otherwise no one's.
    static func face(_ cosine: Float, like axis: Int) -> [Float] {
        var print: [Float] = [0, 0, 0, (1 - cosine * cosine).squareRoot()]
        print[axis] = cosine
        return print
    }

    /// The pictures outside Photos, by name, and their faces.
    static let outside: [String: [[Float]]] = [
        "katie-95.jpg": [face(0.95, like: 0)], "katie-85.jpg": [face(0.85, like: 0)], "stranger.jpg": [face(0, like: 0)],
        "nobody.jpg": [], "sam2-97.jpg": [face(0.97, like: 2)], "katie-and-sam.jpg": [face(0.93, like: 0), face(0.92, like: 1)],
    ]

    struct Indexed {
        let store: IndexStore
        let library: URL
        let downloads: URL
        /// The library's three pictures: Katie's, Sam's and the other Sam's.
        let pictures: [String]
        var listing: PhotosLibrary.Listing

        func path(_ name: String) -> String { downloads.appendingPathComponent(name).path }

        func person(_ uuid: String) throws -> Int64 {
            try #require(try store.photosPeople().first { $0.uuid == uuid }?.id)
        }

        func indexer(_ reader: FakeFaceReader?) throws -> Indexer {
            var options = IndexOptions()
            let listing = listing
            options.photos = PhotosLibrary.Reader { _, _ in listing }
            return try Indexer(store: store, options: options, faces: reader, makeEmbedder: { FakeEmbedder() })
        }

        func kept(_ people: [Set<Int64>], _ filter: SearchFilter = SearchFilter()) throws -> [SearchHit] {
            var filter = filter
            filter.people = people
            return try Searcher(store: store, loadVectors: false).search("", queryVector: nil, filter: filter)
        }

        func count(_ table: String, _ condition: String = "1") throws -> Int {
            var count = 0
            try store.db.query("SELECT COUNT(*) FROM \(table) WHERE \(condition)") { count = Int($0.int(0)) }
            return count
        }
    }

    func reader(_ identity: String = "fake 1", more: [String: [[Float]]] = [:]) -> FakeFaceReader {
        FakeFaceReader(identity, people: Self.prints, found: Self.outside.merging(more) { $1 })
    }

    /// A library of three pictures, one person named in each (two of them Sams), and Downloads with `outside`'s (and
    /// `more`, which `reader` knows the faces of), read by `reader` (none: an index from before faces were kept).
    func indexed(by reader: FakeFaceReader?, more: [String: [[Float]]] = [:]) throws -> Indexed {
        let library = folder.appendingPathComponent("Photos Library.photoslibrary")
        let originals = library.appendingPathComponent("originals/F")
        let downloads = folder.appendingPathComponent("Downloads")
        for made in [originals, library.appendingPathComponent("database"), downloads] {
            try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        }
        try Data("SQLite format 3".utf8).write(to: library.appendingPathComponent("database/Photos.sqlite"))
        var assets: [PhotosLibrary.Asset] = []
        for (number, person) in [Self.katie, Self.sam, Self.otherSam].enumerated() {
            let uuid = UUID().uuidString
            let file = originals.appendingPathComponent(uuid + ".jpeg")
            try ImageTests.writeJPEG(file)
            assets.append(PhotosLibrary.Asset(uuid: uuid, path: file.path, movie: false, screenshot: false,
                                              title: "IMG_\(number)", date: 1_700_000_000 + Double(number), words: [],
                                              people: [person.uuid],
                                              faces: [PhotosLibrary.FaceBox(person: person, x: 0.5, y: 0.5, size: 0.3)]))
        }
        for name in Array(Self.outside.keys) + more.keys {
            try ImageTests.writeJPEG(downloads.appendingPathComponent(name))
        }
        let indexed = Indexed(store: try IndexStore(directory: folder.appendingPathComponent("index")), library: library,
                              downloads: downloads, pictures: assets.map(\.path),
                              listing: PhotosLibrary.Listing(assets: assets, people: [Self.katie, Self.sam, Self.otherSam]))
        let indexer = try indexed.indexer(reader)
        _ = try indexer.sync([library, downloads])
        #expect(try indexer.run()["done"] == 9 + more.count)
        return indexed
    }

    /// Read with its faces: a library picture's named ones with their person, every one outside Photos with none, each
    /// matched to its nearest named face at the floor or more; the People filter keeps those at the threshold.
    @Test func picturesReadKeepTheirFacesAndThoseOutsideAreMatched() throws {
        let indexed = try indexed(by: reader())
        let katie = try indexed.person("P-KATIE"), sam = try indexed.person("P-SAM")
        #expect(try indexed.count("faces", "person IS NOT NULL") == 3)
        #expect(try indexed.count("faces", "person IS NULL") == 6)
        var matched: [String: [String]] = [:]
        try indexed.store.db.query("""
            SELECT fi.path, p.name, round(m.similarity, 2) FROM face_matches m JOIN faces f ON f.id = m.face
            JOIN segments s ON s.id = f.segment JOIN files fi ON fi.id = s.file JOIN photos_people p ON p.id = m.person
            ORDER BY m.similarity DESC
            """) { matched[($0.text(0)! as NSString).lastPathComponent, default: []].append("\($0.text(1)!) \($0.double(2))") }
        // The stranger matches no one: below the floor.
        #expect(matched == ["sam2-97.jpg": ["Sam 0.97"], "katie-95.jpg": ["Katie 0.95"], "katie-85.jpg": ["Katie 0.85"],
                            "katie-and-sam.jpg": ["Katie 0.93", "Sam 0.92"]])

        // Katie: her picture in Photos, and the ones outside with her face at the threshold, not the one below it.
        let withKatie = try indexed.kept([[katie]])
        #expect(Set(withKatie.map(\.path)) == [indexed.pictures[0], indexed.path("katie-95.jpg"),
                                               indexed.path("katie-and-sam.jpg")])
        let byFace = try #require(withKatie.first { $0.path == indexed.path("katie-95.jpg") })
        #expect(byFace.faces.map(\.name) == ["Katie"] && byFace.photos == nil)
        #expect(byFace.faces.first?.box == Faces.Box(x: 0.1, y: 0.2, width: 0.3, height: 0.3))
        #expect(withKatie.first { $0.path == indexed.pictures[0] }?.faces == [])   // Photos says so: no guess
        // Everyone picked must be in it: by their faces, both of them.
        let both = try indexed.kept([[katie], [sam]])
        #expect(both.map(\.path) == [indexed.path("katie-and-sam.jpg")])
        #expect(both.first?.faces.map(\.name) == ["Katie", "Sam"])
        #expect(try indexed.kept([[]]).isEmpty)   // a saved search's person who's gone keeps nothing
    }

    /// Two people of one name are two people: a face matched to one isn't the other's, and the name's group has both.
    @Test func twoPeopleOfOneNameStayTwo() throws {
        let indexed = try indexed(by: reader())
        let sam = try indexed.person("P-SAM"), otherSam = try indexed.person("P-SAM-2")
        let sam2 = indexed.path("sam2-97.jpg")
        #expect(!(try indexed.kept([[sam]]).map(\.path).contains(sam2)))
        #expect(try indexed.kept([[otherSam]]).map(\.path).contains(sam2))
        let either = try indexed.kept([[sam, otherSam]])
        #expect(either.contains { $0.path == sam2 && $0.faces.map(\.name) == ["Sam"] })
    }

    /// Faces go with their picture's segment, their person or their file, and their matches with them; a named face
    /// that went takes away the matches made with it once `face_matches` is made again.
    @Test func facesAndMatchesGoWithWhatTheyreOf() throws {
        let indexed = try indexed(by: reader())
        let store = indexed.store
        let files = Dictionary(uniqueKeysWithValues: try store.files(under: [indexed.library.path, indexed.downloads.path])
            .map { ($0.path, $0.id) })
        // Read again (it changed): its faces go, and those matched with Katie's go with the next making.
        try store.requeue(try #require(files[indexed.pictures[0]]))
        #expect(try indexed.count("faces", "person IS NOT NULL") == 2)
        #expect(try store.rebuildFaceMatchesIfChanged())
        #expect(!(try store.rebuildFaceMatchesIfChanged()))   // nothing changed since
        #expect(try indexed.count("face_matches", "person = \(try indexed.person("P-KATIE"))") == 0)
        // A file gone: its faces and their matches.
        try store.delete(try #require(files[indexed.path("katie-and-sam.jpg")]))
        #expect(try indexed.count("faces", "person IS NULL") == 4 && indexed.count("face_matches") == 1)
        // A person gone from Photos: their named faces and the matches to them.
        try store.db.run("DELETE FROM photos_people WHERE id = ?", [.int(try indexed.person("P-SAM-2"))])
        #expect(try indexed.count("faces", "person IS NOT NULL") == 1 && indexed.count("face_matches") == 0)
    }

    /// An index from before faces gets them once from the pass; another recognizer takes every face, and the pass reads
    /// them all again. Once it's through, nothing waits: the helper goes idle.
    @Test func thePassReadsTheFacesOfPicturesReadBeforeAndAgainForAnotherRecognizer() throws {
        let indexed = try indexed(by: nil)
        #expect(try indexed.count("faces") == 0 && indexed.store.meta(IndexStore.facesModelKey) == nil)
        for identity in ["fake 1", "fake 2"] {
            let reader = reader(identity)
            let indexer = try indexed.indexer(reader)
            #expect(try indexed.count("faces") == 0 && indexed.count("face_matches") == 0)   // none, or another's
            _ = try indexer.sync([indexed.library, indexed.downloads])
            #expect(try indexer.facesWaiting() == 9)   // three named, six outside (one has no face)
            #expect(try indexer.readFaces() == 9)
            #expect(try indexed.count("faces") == 9 && indexed.count("face_matches") == 5)
            #expect(try indexer.facesWaiting() == 0)
            #expect(Set(reader.read).count == 9)
            #expect(try indexed.store.meta(IndexStore.facesModelKey) == identity)
        }
        // The next helper, with the same recognizer: nothing to read.
        let next = try indexed.indexer(reader("fake 2"))
        _ = try next.sync([indexed.library, indexed.downloads])
        #expect(try next.facesWaiting() == 0)
    }

    /// Someone named in Photos in a picture already read, or a name taken off: the pass reads that picture's named
    /// faces again (none read for a name taken off), and the matches follow.
    @Test func namesGivenOrTakenOffInPhotosAreReadAgain() throws {
        var indexed = try indexed(by: reader())
        // Sam's picture shows Katie too, now; Katie's own picture has no one named in it any more.
        var assets = indexed.listing.assets
        func asset(_ index: Int, faces: [PhotosLibrary.FaceBox]) -> PhotosLibrary.Asset {
            let old = assets[index]
            return PhotosLibrary.Asset(uuid: old.uuid, path: old.path, movie: false, screenshot: false, title: old.title,
                                       date: old.date, words: [], people: faces.compactMap { $0.person?.uuid }, faces: faces)
        }
        assets[1] = asset(1, faces: [PhotosLibrary.FaceBox(person: Self.sam, x: 0.5, y: 0.5, size: 0.3),
                                     PhotosLibrary.FaceBox(person: Self.katie, x: 0.2, y: 0.5, size: 0.2)])
        assets[0] = asset(0, faces: [])
        indexed.listing.assets = assets
        let reader = reader()
        let indexer = try indexed.indexer(reader)
        _ = try indexer.sync([indexed.library, indexed.downloads])
        let (waiting, stored) = (try indexer.facesWaiting(), try indexed.store.namedFacePeople())
        #expect(waiting == 2, "\(waiting) waiting; stored \(stored)")
        #expect(try indexer.readFaces() == 2)
        #expect(reader.read == [(indexed.pictures[1] as NSString).lastPathComponent], "\(reader.read)")
        var named: [String: Int] = [:]
        try indexed.store.db.query("""
            SELECT p.name, COUNT(*) FROM faces f JOIN photos_people p ON p.id = f.person GROUP BY p.id
            """) { named[$0.text(0)! + ($0.int(1) == 1 ? "" : " ×\($0.int(1))")] = 1 }
        #expect(Set(named.keys) == ["Katie", "Sam"])   // Katie's face now in Sam's picture; the other Sam's picture
        #expect(try indexed.count("faces", "person IS NOT NULL") == 3)
        #expect(try indexer.facesWaiting() == 0)
    }

    /// What an AI app is told is matched only with the named faces it may see: a picture outside Photos matched with a
    /// face in an item kept from it isn't anyone's to it.
    @Test func faceMatchesForAnAIAppUseOnlyTheFacesItMaySee() throws {
        let indexed = try indexed(by: reader())
        let katie = try indexed.person("P-KATIE")
        var allowed = SearchFilter()
        #expect(try indexed.store.faceMatches(referencesKeptBy: allowed) == nil)   // all of them: the index's own
        allowed.photosOnly = Set(indexed.pictures.dropFirst())   // Katie's picture kept from it
        let matches = try #require(try indexed.store.faceMatches(referencesKeptBy: allowed))
        #expect(!matches.values.contains { $0.person == katie })
        var filter = allowed
        filter.faceMatches = matches
        #expect(try indexed.kept([[katie]], filter).isEmpty)
        // By the index's own matches the pictures outside with her face would be hers.
        #expect(try indexed.kept([[katie]], SearchFilter()).count == 3)
        allowed.photosOnly = Set(indexed.pictures)
        #expect(try indexed.store.faceMatches(referencesKeptBy: allowed) == nil)
    }

    /// `face-corrections.json` beside the index folder, as the app writes it (the approved shape): `says` of the face of
    /// the picture outside Photos called `name` (its place among the reader's faces of it) for `person`.
    func correct(_ indexed: Indexed, _ said: [(name: String, face: Int, person: PhotosLibrary.Person, says: String)])
        throws {
        let corrections: [[String: Any]] = try said.map { name, face, person, says in
            let url = URL(fileURLWithPath: indexed.path(name))
            return ["file": ["bookmark": try url.bookmarkData().base64EncodedString(), "path": url.path],
                    "face": ["x": 0.1 + 0.4 * Double(face), "y": 0.2, "width": 0.3, "height": 0.3],
                    "person": ["name": person.name, "photos": [["library": indexed.library.path, "uuid": person.uuid]]],
                    "says": says, "made": "2026-10-22T22:05:00Z"]
        }
        try JSONSerialization.data(withJSONObject: ["version": 1, "corrections": corrections])
            .write(to: folder.appendingPathComponent("face-corrections.json"))
    }

    /// What you told DigUp about faces is kept over its guesses whenever `face_matches` is made again: "this is Katie"
    /// keeps a face at any likeness, and teaches (a face like it is hers too); "this isn't Katie" sends a face to
    /// whoever's next nearest, or no one.
    @Test func correctionsAreKeptOverTheGuessesAndTeach() throws {
        // Like the face in katie-85.jpg (0.97), less like Katie's in Photos (0.70) than the floor.
        let more: [String: [[Float]]] = ["like-katie-85.jpg": [[0.7, 0, 0, 0.714]]]
        let indexed = try indexed(by: reader(more: more), more: more)
        let katie = try indexed.person("P-KATIE"), sam = try indexed.person("P-SAM")
        try correct(indexed, [("katie-85.jpg", 0, Self.katie, "is"), ("katie-95.jpg", 0, Self.katie, "isNot"),
                              ("katie-and-sam.jpg", 1, Self.sam, "isNot")])
        // Until the matches are made again, the guesses stand.
        #expect(Set(try indexed.kept([[katie]]).map(\.path))
                == [indexed.pictures[0], indexed.path("katie-95.jpg"), indexed.path("katie-and-sam.jpg")])
        try indexed.store.rebuildFaceMatches()
        let withKatie = try indexed.kept([[katie]])
        #expect(Set(withKatie.map(\.path)) == [indexed.pictures[0], indexed.path("katie-85.jpg"),
                                               indexed.path("like-katie-85.jpg"), indexed.path("katie-and-sam.jpg")])
        #expect(withKatie.first { $0.path == indexed.path("katie-85.jpg") }?.faces.map(\.name) == ["Katie"])
        // Sam's face in katie-and-sam.jpg isn't Sam's, and no one else's is near it.
        #expect(try indexed.kept([[sam]]).map(\.path) == [indexed.pictures[1]])
        #expect(try indexed.count("face_matches", "confirmed = 1") == 1)
    }

    /// Corrections saved are read the next time `face_matches` might be stale (the end of a sync or a run, the faces
    /// pass), and follow a picture read again (its faces' rows are new). One of a picture in Photos, or of someone who
    /// isn't in Photos any more, corrects nothing; nor does a file that isn't their shape.
    @Test func correctionsAreReadWhenSavedAndFollowAPictureReadAgain() throws {
        let indexed = try indexed(by: reader())
        let katie = try indexed.person("P-KATIE")
        let store = indexed.store
        #expect(!(try store.rebuildFaceMatchesIfChanged()))
        func said(_ path: String, _ person: PhotosLibrary.Person, uuid: String? = nil) throws
            -> FaceCorrections.Correction {
            FaceCorrections.Correction(
                file: .init(bookmark: try URL(fileURLWithPath: path).bookmarkData(), path: path),
                face: try #require(Faces.Box(x: 0.1, y: 0.2, width: 0.3, height: 0.3)),
                person: .init(name: person.name, photos: [PhotosID(library: indexed.library.path,
                                                                   uuid: uuid ?? person.uuid)]), says: .is)
        }
        let url = FaceCorrections.url(beside: store.directory)
        try FaceCorrections([try said(indexed.path("katie-85.jpg"), Self.katie),
                             try said(indexed.pictures[1], Self.katie),                    // in Photos: Sam's
                             try said(indexed.path("stranger.jpg"), Self.katie, uuid: "P-GONE")]).data().write(to: url)
        #expect(try store.faceRulings().count == 1)
        #expect(try store.rebuildFaceMatchesIfChanged())
        #expect(!(try store.rebuildFaceMatchesIfChanged()))
        #expect(try indexed.count("face_matches", "confirmed = 1") == 1)
        #expect(try indexed.kept([[katie]]).contains { $0.path == indexed.path("katie-85.jpg") })
        // The picture changed and is read again: its face is a new row, still Katie.
        let files = Dictionary(uniqueKeysWithValues: try store.files(under: [indexed.downloads.path])
            .map { ($0.path, $0.id) })
        try store.requeue(try #require(files[indexed.path("katie-85.jpg")]))
        #expect(try indexed.count("face_matches", "confirmed = 1") == 0)
        #expect(try indexed.indexer(reader()).run()["done"] == 1)
        let kept = try #require(try indexed.kept([[katie]]).first { $0.path == indexed.path("katie-85.jpg") })
        #expect(kept.faces.map { "\($0.name) \($0.confirmed)" } == ["Katie true"])
        #expect(try store.pictureFaces(ofPath: indexed.path("katie-85.jpg")).map { $0.match?.name } == ["Katie"])
        // A file that isn't the shape: nothing corrected (and it's left as it is).
        try Data(#"{"version": 1, "corrections": [], "by": "jon"}"#.utf8).write(to: url)
        #expect(try store.rebuildFaceMatchesIfChanged())
        #expect(try indexed.count("face_matches", "confirmed = 1") == 0)
        #expect(try store.pictureFaces(ofPath: indexed.path("katie-85.jpg")).map { $0.match?.name } == [nil])
        #expect(try String(contentsOf: url, encoding: .utf8).contains("jon"))
    }

    /// An AI app isn't told of a match taught by a face it may not see: a picture outside Photos you said is Katie
    /// teaches only when the app may see that picture.
    @Test func faceMatchesForAnAIAppAreTaughtOnlyByPicturesItMaySee() throws {
        let more: [String: [[Float]]] = ["like-katie-85.jpg": [[0.7, 0, 0, 0.714]]]
        let indexed = try indexed(by: reader(more: more), more: more)
        let katie = try indexed.person("P-KATIE")
        try correct(indexed, [("katie-85.jpg", 0, Self.katie, "is")])
        try indexed.store.rebuildFaceMatches()
        let everything = Set(try indexed.store.files(under: [indexed.library.path, indexed.downloads.path]).map(\.path))
        var allowed = SearchFilter()
        allowed.paths = everything
        #expect(try indexed.store.faceMatches(referencesKeptBy: allowed) == nil)   // it sees them all
        allowed.paths = everything.subtracting([indexed.path("katie-85.jpg")])
        var filter = allowed
        filter.faceMatches = try #require(try indexed.store.faceMatches(referencesKeptBy: allowed))
        #expect(Set(try indexed.kept([[katie]], filter).map(\.path))
                == [indexed.pictures[0], indexed.path("katie-95.jpg"), indexed.path("katie-and-sam.jpg")])
        #expect(try indexed.kept([[katie]]).contains { $0.path == indexed.path("like-katie-85.jpg") })
    }
}
#endif
