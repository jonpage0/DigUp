import Foundation
import Testing
@testable import DigUpKit

/// What you tell DigUp about faces outside Photos (`FaceCorrections`): the file's shape, which correction says the last
/// word, and how they're kept over DigUp's guesses (`FaceMatching`).
@Suite struct FaceCorrectionsTests {
    static let tati = FaceCorrections.Person(name: "Tati", photos: [PhotosID(library: "/L.photoslibrary", uuid: "T")])
    static let chris = FaceCorrections.Person(name: "Chris", photos: [PhotosID(library: "/L.photoslibrary", uuid: "C")])

    static func box(_ x: Double, _ y: Double = 0.2, side: Double = 0.2) -> Faces.Box {
        Faces.Box(x: x, y: y, width: side, height: side)!
    }

    static func correction(path: String = "/D/beach.jpg", face: Faces.Box = box(0.3),
                           person: FaceCorrections.Person = tati,
                           says: FaceCorrections.Says) -> FaceCorrections.Correction {
        FaceCorrections.Correction(file: .init(bookmark: Data(), path: path), face: face, person: person, says: says,
                                   made: Date(timeIntervalSince1970: 1_761_170_700))
    }

    static let approved = """
        { "version": 1,
          "corrections": [
            { "file": { "bookmark": "AAEC", "path": "/Users/jon/Downloads/beach.jpg" },
              "face": { "x": 0.31, "y": 0.12, "width": 0.18, "height": 0.24 },
              "person": { "name": "Tatiana Rotari",
                          "photos": [ { "library": "/Users/jon/Pictures/Photos Library.photoslibrary", "uuid": "9B1D" } ] },
              "says": "is",
              "made": "2026-10-22T22:05:00Z" }
          ]
        }
        """

    /// The approved shape reads, and writes back as itself; anything else (another key anywhere, another version, a box
    /// that isn't in the picture, a word `says` doesn't have) isn't read, so the app never writes over it.
    @Test func aCorrectionsFileIsReadOnlyInItsApprovedShape() throws {
        let read = try FaceCorrections(data: Data(Self.approved.utf8))
        let correction = try #require(read.corrections.first)
        #expect(read.corrections.count == 1 && correction.says == .is && correction.person.name == "Tatiana Rotari")
        #expect(correction.file == FaceCorrections.File(bookmark: Data([0, 1, 2]),
                                                        path: "/Users/jon/Downloads/beach.jpg"))
        #expect(correction.face == Faces.Box(x: 0.31, y: 0.12, width: 0.18, height: 0.24))
        #expect(correction.person.photos == [PhotosID(library: "/Users/jon/Pictures/Photos Library.photoslibrary",
                                                       uuid: "9B1D")])
        #expect(correction.made == ISO8601DateFormatter().date(from: "2026-10-22T22:05:00Z"))
        #expect(try FaceCorrections(data: read.data()) == read)
        for changed in [
            Self.approved.replacingOccurrences(of: "\"version\": 1", with: "\"version\": 2"),
            Self.approved.replacingOccurrences(of: "\"says\": \"is\"", with: "\"says\": \"maybe\""),
            Self.approved.replacingOccurrences(of: "\"says\": \"is\",", with: "\"says\": \"is\", \"note\": \"\","),
            Self.approved.replacingOccurrences(of: "\"uuid\": \"9B1D\"", with: "\"uuid\": \"9B1D\", \"extra\": 1"),
            Self.approved.replacingOccurrences(of: "\"height\": 0.24", with: "\"height\": 0.24, \"angle\": 0"),
            Self.approved.replacingOccurrences(of: "\"width\": 0.18", with: "\"width\": 0.88"),
            Self.approved.replacingOccurrences(of: "\"made\": \"2026-10-22T22:05:00Z\"", with: "\"made\": \"yesterday\""),
            Self.approved.replacingOccurrences(of: "\"version\": 1,", with: "\"version\": 1, \"by\": \"jon\","),
        ] {
            #expect(throws: (any Error).self) { try FaceCorrections(data: Data(changed.utf8)) }
        }
        // No file yet: nothing corrected.
        #expect(try FaceCorrections(contentsOf: URL(fileURLWithPath: "/nonexistent/face-corrections.json")).corrections
                .isEmpty)
    }

    /// A later correction of the same face (the same file, boxes overlapping by half or more) and person replaces the
    /// earlier one; a face is one person, so saying who it is replaces saying it's someone else, but not saying who it
    /// isn't.
    @Test func aLaterCorrectionOfTheSameFaceAndPersonReplacesTheEarlier() {
        var corrections = FaceCorrections()
        corrections.add(Self.correction(says: .is))
        corrections.add(Self.correction(face: Self.box(0.32), says: .isNot))   // the same face, a little to the right
        #expect(corrections.corrections.map(\.says) == [.isNot])
        corrections.add(Self.correction(face: Self.box(0.6), says: .is))       // another face of the picture
        corrections.add(Self.correction(path: "/D/other.jpg", says: .is))      // the same box in another picture
        corrections.add(Self.correction(face: Self.box(0.3), person: Self.chris, says: .is))   // the first is Chris
        #expect(corrections.corrections.count == 4)
        corrections.add(Self.correction(face: Self.box(0.6), person: Self.chris, says: .is))   // Chris, not Tati
        #expect(corrections.corrections.map { "\($0.file.path) \($0.face.x) \($0.person.name) \($0.says)" }
                == ["/D/beach.jpg 0.32 Tati isNot", "/D/other.jpg 0.3 Tati is", "/D/beach.jpg 0.3 Chris is",
                    "/D/beach.jpg 0.6 Chris is"])
    }

    @Test func boxesOverlapByTheAreaTheyShareOverTheAreaTheyCover() {
        #expect(Self.box(0.3).overlap(Self.box(0.3)) == 1)
        #expect(abs(Self.box(0.3).overlap(Self.box(0.4)) - 1.0 / 3) < 1e-9)   // half of each: 0.02 of 0.06
        #expect(Self.box(0.1).overlap(Self.box(0.5)) == 0)
        #expect(abs(Self.box(0.1).overlap(Self.box(0.15, side: 0.1)) - 0.25) < 1e-9)   // inside it, a quarter of it
    }

    /// Prints along axes: Katie's (row 1), Sam's (row 2, two faces) and the other Sam's (row 3) faces in Photos.
    static let named: [(person: Int64, print: [Float])] = [(1, [1, 0, 0, 0]), (2, [0, 1, 0, 0]), (2, [0.6, 0.8, 0, 0]),
                                                           (3, [0, 0, 1, 0])]

    static func face(_ id: Int64, file: Int64 = 10, x: Double, _ print: [Float]) -> FaceMatching.Face {
        FaceMatching.Face(id: id, file: file, box: box(x), print: print)
    }

    /// Each ruling is of the face of its file its box overlaps most, by half or more; the later one has the last word.
    @Test func eachRulingIsOfTheFaceItOverlapsMost() {
        let faces = [Self.face(1, x: 0.1, [1, 0, 0, 0]), Self.face(2, x: 0.25, [1, 0, 0, 0]),
                     Self.face(3, file: 11, x: 0.1, [1, 0, 0, 0])]
        func said(_ rulings: [FaceMatching.Ruling]) -> [Int: FaceMatching.Said] {
            FaceMatching.said(of: faces, [10: rulings])
        }
        let katie = FaceMatching.Ruling(box: Self.box(0.12), people: [1], says: .is)
        #expect(said([katie]) == [0: .init(is: [1])])   // the first face (it overlaps the second less)
        #expect(said([FaceMatching.Ruling(box: Self.box(0.6), people: [1], says: .is)]).isEmpty)   // no face there
        #expect(said([katie, FaceMatching.Ruling(box: Self.box(0.1), people: [1], says: .isNot)])
                == [0: .init(is: nil, isNot: [1])])
        #expect(said([katie, FaceMatching.Ruling(box: Self.box(0.1), people: [2, 3], says: .isNot),
                      FaceMatching.Ruling(box: Self.box(0.1), people: [2, 3], says: .is)])
                == [0: .init(is: [2, 3])])   // one is per face: Sam now, and no longer not Sam
        #expect(said([FaceMatching.Ruling(box: Self.box(0.1), people: [], says: .is)]).isEmpty)   // gone from Photos
    }

    /// Who you said a face is keeps it at any likeness (at its likeness to the nearest of their faces in Photos), and
    /// teaches: faces like it are theirs too. Who you said it isn't sends it to whoever's next nearest, or no one.
    @Test func aFaceYouNamedIsKeptAtAnyLikenessAndTeaches() throws {
        let unlike: [Float] = [0.3, 0, 0, 0.954]   // 0.30 like Katie's face in Photos
        let likeIt: [Float] = [0.35, 0, 0, 0.937]  // 1.00 like that one, 0.35 like Katie's
        let katieOrSam: [Float] = [0.95, 0.31, 0, 0]   // 0.95 like Katie's face, 0.82 like one of Sam's
        let faces = [Self.face(1, x: 0.1, unlike), Self.face(2, file: 11, x: 0.1, likeIt),
                     Self.face(3, file: 12, x: 0.1, katieOrSam), Self.face(4, file: 13, x: 0.1, [0, 0.95, 0.31, 0])]
        #expect(FaceMatching(named: Self.named).matches(faces).map { $0?.person } == [nil, nil, 1, 2])
        let matching = FaceMatching(named: Self.named, rulings: [
            10: [FaceMatching.Ruling(box: Self.box(0.1), people: [1], says: .is)],
            12: [FaceMatching.Ruling(box: Self.box(0.1), people: [1], says: .isNot)],
            13: [FaceMatching.Ruling(box: Self.box(0.1), people: [2, 3], says: .is)],   // Sam: either of them
        ], ruled: faces)
        let matches = matching.matches(faces)
        #expect(matches[0]?.person == 1 && matches[0]?.confirmed == true && abs(matches[0]!.similarity - 0.3) < 0.01)
        #expect(matches[1]?.person == 1 && matches[1]?.confirmed == false && matches[1]!.similarity > 0.99)   // taught
        #expect(matches[2]?.person == 2 && matches[2]?.confirmed == false)   // not Katie: Sam, next nearest
        #expect(matches[3]?.person == 2 && matches[3]?.confirmed == true)    // the Sam it's nearer
        // Not Katie, nor Sam: no one else is near.
        let neither = FaceMatching(named: Self.named, rulings: [12: [
            FaceMatching.Ruling(box: Self.box(0.1), people: [1], says: .isNot),
            FaceMatching.Ruling(box: Self.box(0.1), people: [2], says: .isNot),
        ]], ruled: faces)
        #expect(neither.matches([faces[2]]) == [nil])
        // Someone with no face in Photos to compare: theirs, at no likeness, and taught.
        let new = FaceMatching(named: Self.named, rulings: [10: [FaceMatching.Ruling(box: Self.box(0.1), people: [7, 9],
                                                                                    says: .is)]], ruled: faces)
        #expect(new.matches(faces).map { $0?.person } == [7, 7, 1, 2])
        #expect(new.matches([faces[0]]).first??.similarity == 0)
    }
}
