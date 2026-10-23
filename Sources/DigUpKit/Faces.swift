import Foundation

/// Telling people apart by their faces, to find the people named in Photos in pictures outside it (approved
/// 2026-10-22: PHOTOS-FACTS-SCHEMA.md, "faces outside Photos"). The index keeps the faces of pictures (`faces`): in a
/// Photos library the ones Photos named, with who they are, and outside every face found. Each face outside is matched
/// to the nearest named face (`FaceMatcher`, kept as `face_matches`) unless you said who it is or isn't
/// (`FaceCorrections`, `FaceMatching`), and the People filter keeps a picture outside Photos with a face that matches
/// the person at `threshold`, or that you said is them (`SearchFilter.people`). `digup faces-eval` measured it.
///
/// A face recognizer (`FaceRecognizer`, on the Mac: Platform/Apple/Faces+Apple.swift) turns each face of a picture into
/// an embedding, its print: a list of numbers that comes out alike for two faces of one person and apart for two
/// people's; how alike two are is the cosine of the angle between them (`cosine`). Apple publishes no way to say who a
/// face is, so there are two: Vision's own faceprints, through a request Vision doesn't publish, and a Core ML model of
/// the ArcFace family given by its file (SFace, from OpenCV Zoo, made by scripts/face-model.py), which needs each face
/// aligned first: turned, scaled and moved so that its eyes, nose and mouth sit where the model expects them
/// (`arcFaceTemplate`, `Similarity`). What's here needs neither Vision nor Core ML: the alignment's arithmetic, the
/// comparison, the matching, the measurement (`Measure`), and the faces Photos found in a library
/// (`PhotosLibrary.photoFaces`, and the listing's `PhotosLibrary.Asset.faces`).
public enum Faces {
    /// A point of a picture, in pixels from its top-left corner (a pixel's center is half a pixel in).
    public struct Point: Equatable, Sendable {
        public var x: Double
        public var y: Double

        public init(x: Double, y: Double) {
            (self.x, self.y) = (x, y)
        }
    }

    /// Where the five points a face is aligned by sit in a face of 112 × 112 pixels, as the ArcFace family of models
    /// was trained on (insightface's `arcface_dst`, and OpenCV's for SFace), in this order: the eye on the picture's
    /// left, the other eye, the tip of the nose, the corner of the mouth on the picture's left, the other corner.
    /// They're pixel indices, as OpenCV counts them (a pixel's center is a whole number): `template(side:)` gives them
    /// as `Point`s.
    public static let arcFaceTemplate: [(x: Double, y: Double)] = [
        (38.2946, 51.6963), (73.5318, 51.5014), (56.0252, 71.7366), (41.5493, 92.3655), (70.7299, 92.2041),
    ]
    public static let arcFaceSide = 112.0

    /// The five points of the template (`arcFaceTemplate`) for a model that takes faces of `side` × `side` pixels:
    /// ArcFace's, scaled to that size, as `Point`s (a pixel's center half a pixel in).
    public static func template(side: Double) -> [Point] {
        arcFaceTemplate.map { Point(x: ($0.x + 0.5) * side / arcFaceSide, y: ($0.y + 0.5) * side / arcFaceSide) }
    }

    /// A turn, a scale the same both ways, and a shift: x' = a·x − b·y + tx, y' = b·x + a·y + ty. The turn is
    /// atan2(b, a), the scale hypot(a, b). It never mirrors: a face stays the way round it is.
    public struct Similarity: Equatable, Sendable {
        public var a: Double
        public var b: Double
        public var tx: Double
        public var ty: Double

        public init(a: Double, b: Double, tx: Double, ty: Double) {
            (self.a, self.b, self.tx, self.ty) = (a, b, tx, ty)
        }

        /// The similarity that takes `source` closest to `target`, point for point, in least squares (Umeyama's in
        /// two dimensions, as insightface and OpenCV align faces). Nil when the lists differ in length, are empty, or
        /// the source points all coincide.
        public init?(taking source: [Point], to target: [Point]) {
            guard source.count == target.count, !source.isEmpty else { return nil }
            let count = Double(source.count)
            let from = Point(x: source.map(\.x).reduce(0, +) / count, y: source.map(\.y).reduce(0, +) / count)
            let to = Point(x: target.map(\.x).reduce(0, +) / count, y: target.map(\.y).reduce(0, +) / count)
            var spread = 0.0, dot = 0.0, cross = 0.0
            for (p, q) in zip(source, target) {
                let (px, py, qx, qy) = (p.x - from.x, p.y - from.y, q.x - to.x, q.y - to.y)
                spread += px * px + py * py
                dot += px * qx + py * qy
                cross += px * qy - py * qx
            }
            guard spread > 0 else { return nil }
            let (a, b) = (dot / spread, cross / spread)
            self.init(a: a, b: b, tx: to.x - (a * from.x - b * from.y), ty: to.y - (b * from.x + a * from.y))
        }

        public func applied(to point: Point) -> Point {
            Point(x: a * point.x - b * point.y + tx, y: b * point.x + a * point.y + ty)
        }
    }

    /// How alike two embeddings are: the cosine of the angle between them, from −1 (opposite) to 1 (the same
    /// direction), whatever their lengths. 0 when either is all zeros, or they differ in length.
    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        var dot: Float = 0, aa: Float = 0, bb: Float = 0
        for index in a.indices {
            dot += a[index] * b[index]
            aa += a[index] * a[index]
            bb += b[index] * b[index]
        }
        return aa > 0 && bb > 0 ? dot / (aa.squareRoot() * bb.squareRoot()) : 0
    }

    /// The least similarity at which a face outside Photos is kept as its nearest named face's person
    /// (`face_matches`): DigUp's guess, kept with how near it is.
    public static let matchFloor = 0.80
    /// The similarity at which the People filter takes a face outside Photos for the person (`SearchFilter.people`).
    /// A constant to tune: on a real library's named faces, Vision's nearest named face was the same person's for all
    /// of 3,549, and at 0.90 about 97 % of the calls were right, with about 8 % of the faces nobody named called
    /// someone (an upper bound: Photos leaves some faces of named people unnamed). `digup faces-eval` measured it.
    public static let threshold = 0.90

    /// How much a correction's box and a face's have to overlap (`Box.overlap`) for the correction to be of that face
    /// (`FaceCorrections`): at least half.
    public static let sameFace = 0.5

    /// Where a face is in a picture, as the index keeps it (`faces`' x, y, width and height): a box in the picture as
    /// it's shown (upright), in fractions of its width and height from its top-left corner, all of it inside.
    public struct Box: Sendable, Equatable {
        public let x: Double
        public let y: Double
        public let width: Double
        public let height: Double

        /// The part of this box that's inside the picture; nil when none is.
        public init?(x: Double, y: Double, width: Double, height: Double) {
            let (left, top) = (min(max(x, 0), 1), min(max(y, 0), 1))
            let (right, bottom) = (min(max(x + width, 0), 1), min(max(y + height, 0), 1))
            guard right > left, bottom > top else { return nil }
            (self.x, self.y, self.width, self.height) = (left, top, right - left, bottom - top)
        }

        /// Where Photos says a face is (`PhotosLibrary.FaceBox`: its center from the bottom-left corner, the side of a
        /// square over the picture's long side) in a picture of `width` × `height` pixels, shown upright.
        public init?(_ face: PhotosLibrary.FaceBox, width: Double, height: Double) {
            guard width > 0, height > 0 else { return nil }
            let side = face.size * max(width, height)
            let (across, down) = (side / width, side / height)
            self.init(x: face.x - across / 2, y: 1 - face.y - down / 2, width: across, height: down)
        }

        /// The area it and `other` share, over the area they cover together: 0 apart, 1 the same box.
        public func overlap(_ other: Box) -> Double {
            let across = max(0, min(x + width, other.x + other.width) - max(x, other.x))
            let down = max(0, min(y + height, other.y + other.height) - max(y, other.y))
            let together = width * height + other.width * other.height - across * down
            return together > 0 ? across * down / together : 0
        }
    }

    /// A face read from a picture (`FaceReader`): where it is, and its print. `named`: which of the faces Photos named
    /// in it this is (their place in the list it was given); nil for a face found in a picture outside Photos.
    public struct Found: Sendable {
        public let box: Box
        public let print: [Float]
        public let named: Int?

        public init(box: Box, print: [Float], named: Int?) {
            (self.box, self.print, self.named) = (box, print, named)
        }
    }

    /// A print as the index keeps it (`faces.print`): its numbers as 32-bit floats, in this Mac's byte order.
    static func bytes(of print: [Float]) -> Data {
        print.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// A print the index kept (`bytes(of:)`); nil for bytes that aren't one.
    static func floats(fromBytes data: Data) -> [Float]? {
        guard !data.isEmpty, data.count.isMultiple(of: MemoryLayout<Float>.size) else { return nil }
        return data.withUnsafeBytes { raw in
            (0..<raw.count / MemoryLayout<Float>.size).map {
                raw.loadUnaligned(fromByteOffset: $0 * MemoryLayout<Float>.size, as: Float.self)
            }
        }
    }

    /// How well a recognizer's embeddings tell named people apart, and keep everyone else out (`digup faces-eval`).
    /// People are told apart by Photos' id for them: two of one name are two people. Each named face is called by the
    /// nearest of the other named faces (leave-one-out): it's called that face's person, with their similarity. A
    /// face whose person has no other face is left out (`alone`): no call could be right. Each other face (one nobody
    /// named) is called by its nearest named face too: at a threshold that call would wrongly say it's a named person.
    /// (Photos may have left some faces of a named person unnamed: those count as wrong here, so the others' rate is at
    /// most what it says.)
    public struct Measure {
        public struct Call: Equatable, Sendable {
            /// The nearest other face is the same person's.
            public let right: Bool
            public let similarity: Float
        }

        /// The named faces measured, each with its call.
        public let calls: [Call]
        /// Each other face's similarity to the nearest named face.
        public let others: [Float]
        /// Named faces left out: their person has no other face.
        public let alone: Int

        public init(named: [(person: PhotosLibrary.Person, embedding: [Float])], others: [[Float]],
                    similarity: ([Float], [Float]) -> Float) {
            var faces: [String: Int] = [:]
            for face in named { faces[face.person.uuid, default: 0] += 1 }
            var calls: [Call] = []
            for (index, face) in named.enumerated() where faces[face.person.uuid, default: 0] > 1 {
                var best: (person: PhotosLibrary.Person, similarity: Float)?
                for (other, candidate) in named.enumerated() where other != index {
                    let alike = similarity(face.embedding, candidate.embedding)
                    if best.map({ alike > $0.similarity }) ?? true { best = (candidate.person, alike) }
                }
                if let best {
                    calls.append(Call(right: best.person.uuid == face.person.uuid, similarity: best.similarity))
                }
            }
            self.calls = calls
            self.others = others.compactMap { face in named.map { similarity(face, $0.embedding) }.max() }
            alone = named.count - calls.count
        }

        /// The share of named faces whose nearest other face is their own person's, whatever the similarity.
        public var nearestRight: Double {
            calls.isEmpty ? 0 : Double(calls.filter(\.right).count) / Double(calls.count)
        }

        /// At a threshold (a call is made at that similarity or more), the share of named faces called the right
        /// person, called someone else, and not called at all; and the share of the other faces called a named person.
        public struct Rates: Equatable, Sendable {
            public let right: Double
            public let wrong: Double
            public let uncalled: Double
            public let others: Double
        }

        public func rates(at threshold: Float) -> Rates {
            func share(_ count: Int, of total: Int) -> Double { total == 0 ? 0 : Double(count) / Double(total) }
            let made = calls.filter { $0.similarity >= threshold }
            let right = made.filter(\.right).count
            return Rates(right: share(right, of: calls.count), wrong: share(made.count - right, of: calls.count),
                         uncalled: share(calls.count - made.count, of: calls.count),
                         others: share(others.filter { $0 >= threshold }.count, of: others.count))
        }
    }
}

/// Reads the faces of a picture for the index: where each is and its print (on the Mac, `Faces.reader(models:)`). The
/// indexer uses one from its own threads, one picture at a time.
public protocol FaceReader: Sendable {
    /// Which recognizer makes the prints, and its version, as the index records it (`IndexStore.facesModelKey`):
    /// prints of two recognizers are never compared.
    var identity: String { get }
    /// The faces of the picture at `url`, read upright. Given `named` (where Photos found the faces it named in it), those
    /// faces in Photos' boxes, each with its place in `named`, less any it couldn't read; else every face found in it.
    /// Throws when the picture can't be read.
    func faces(inPictureAt url: URL, named: [PhotosLibrary.FaceBox]?) throws -> [Faces.Found]
}

/// Who a face outside Photos is likeliest to be: the person of the nearest of the faces it's compared against, by the
/// cosine of their prints, when it's at least `Faces.matchFloor`. Those are the faces Photos named (`references`), and
/// the faces outside Photos you said are someone (`taught`, `FaceCorrections`). `FaceMatching` uses it for what
/// `face_matches` holds, and for what `digup mcp` works out against only the faces an AI app may see. Two people of one
/// name are two people: a match is to a person's row, never to a name.
public struct FaceMatcher {
    public struct Match: Sendable, Equatable {
        /// The person's row (`IndexStore.photosPeople`).
        public let person: Int64
        public let similarity: Double
        /// You said it's them (`FaceCorrections`): kept at any similarity.
        public let confirmed: Bool

        public init(person: Int64, similarity: Double, confirmed: Bool = false) {
            (self.person, self.similarity, self.confirmed) = (person, similarity, confirmed)
        }
    }

    private let people: [Int64]
    /// How many of the columns are faces Photos named: the first ones.
    private let named: Int
    /// The references' prints scaled to length 1, one column each (`dimension` × `people.count`, row-major): one
    /// multiplication scores many faces against all of them.
    private let columns: [Float]
    private let dimension: Int

    /// Faces to compare against: who each is, and its print. One that isn't the first one's length (another
    /// recognizer's), or all zeros, is left out.
    public init(references: [(person: Int64, print: [Float])], taught: [(person: Int64, print: [Float])] = []) {
        let dimension = (references.first ?? taught.first)?.print.count ?? 0
        func units(_ faces: [(person: Int64, print: [Float])]) -> [(person: Int64, unit: [Float])] {
            faces.compactMap { face in Self.unit(face.print, dimension: dimension).map { (face.person, $0) } }
        }
        let named = units(references)
        let kept = named + units(taught)
        var columns = [Float](repeating: 0, count: dimension * kept.count)
        for (column, reference) in kept.enumerated() {
            for row in 0..<dimension { columns[row * kept.count + column] = reference.unit[row] }
        }
        (people, self.named, self.columns, self.dimension) = (kept.map { $0.person }, named.count, columns, dimension)
    }

    /// Faces scored together, at most: a block of scores is this many times the references.
    private static let block = 128

    /// Each print's match: the nearest reference's person and how near, nil below `Faces.matchFloor` (or for a print
    /// that isn't the references' length). `skipping`: by a print's place, people it isn't (`FaceCorrections`), whose
    /// faces it isn't compared with.
    public func matches(_ prints: [[Float]], skipping: [Int: Set<Int64>] = [:]) -> [Match?] {
        var found = [Match?](repeating: nil, count: prints.count)
        let usable: [(index: Int, unit: [Float])] = prints.indices.compactMap { index in
            Self.unit(prints[index], dimension: dimension).map { (index, $0) }
        }
        score(usable.map(\.unit)) { place, scores in
            let index = usable[place].index
            let skip = skipping[index]
            var best: Int?
            for column in scores.indices where skip?.contains(people[column - scores.startIndex]) != true {
                if best.map({ scores[column] > scores[$0] }) ?? true { best = column }
            }
            guard let best, Double(scores[best]) >= Faces.matchFloor else { return }
            found[index] = Match(person: people[best - scores.startIndex], similarity: min(Double(scores[best]), 1))
        }
        return found
    }

    /// The person of the faces Photos named of `persons` that `print` is nearest, and how near, at any likeness; nil
    /// when none of theirs is compared against (or the print isn't the references' length).
    public func nearest(_ print: [Float], among persons: Set<Int64>) -> Match? {
        guard let unit = Self.unit(print, dimension: dimension) else { return nil }
        var best: (person: Int64, score: Float)?
        score([unit]) { _, scores in
            for column in 0..<named where persons.contains(people[column]) {
                let score = scores[scores.startIndex + column]
                if best.map({ score > $0.score }) ?? true { best = (people[column], score) }
            }
        }
        return best.map { Match(person: $0.person, similarity: max(min(Double($0.score), 1), -1)) }
    }

    /// Scores `units` (prints of length 1) against every reference, a block of them at a time: `each` gets a unit's
    /// place and its scores, one a column.
    private func score(_ units: [[Float]], _ each: (Int, ArraySlice<Float>) -> Void) {
        guard !people.isEmpty, !units.isEmpty else { return }
        var scores = [Float](repeating: 0, count: min(Self.block, units.count) * people.count)
        for start in stride(from: 0, to: units.count, by: Self.block) {
            let some = units[start..<min(start + Self.block, units.count)]
            let rows = some.flatMap { $0 }
            rows.withUnsafeBufferPointer { rows in
                columns.withUnsafeBufferPointer { columns in
                    scores.withUnsafeMutableBufferPointer { scores in
                        Vectors.multiply(rows.baseAddress!, rows: some.count, by: columns.baseAddress!,
                                         columns: people.count, inner: dimension, into: scores.baseAddress!)
                    }
                }
            }
            for row in 0..<some.count { each(start + row, scores[row * people.count..<(row + 1) * people.count]) }
        }
    }

    /// `print` scaled to length 1, or nil when it isn't `dimension` long or is all zeros.
    private static func unit(_ print: [Float], dimension: Int) -> [Float]? {
        guard print.count == dimension, dimension > 0 else { return nil }
        let length = print.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return length > 0 ? print.map { $0 / length } : nil
    }
}

/// Who each face outside Photos is taken for, as `face_matches` holds it (`IndexStore.faceMatching`): the person you
/// said it is (`FaceCorrections`), else the nearest face it's compared against (`FaceMatcher`: the faces Photos named,
/// and the ones you said are someone) of someone you didn't say it isn't.
public struct FaceMatching {
    /// A face outside Photos: its row, its picture's file, where it is in the picture, and its print.
    public struct Face: Sendable {
        public let id: Int64
        public let file: Int64
        public let box: Faces.Box
        public let print: [Float]

        public init(id: Int64, file: Int64, box: Faces.Box, print: [Float]) {
            (self.id, self.file, self.box, self.print) = (id, file, box, print)
        }
    }

    /// A correction as it applies to the index (`IndexStore.faceRulings`): the face's box in its file, the rows of its
    /// person (everyone of their Photos ids), and what it says.
    public struct Ruling: Sendable, Equatable {
        public let box: Faces.Box
        public let people: Set<Int64>
        public let says: FaceCorrections.Says

        public init(box: Faces.Box, people: Set<Int64>, says: FaceCorrections.Says) {
            (self.box, self.people, self.says) = (box, people, says)
        }
    }

    /// What a file's rulings say of one of its faces: who it is (nil: they don't say), and who it isn't.
    struct Said: Equatable {
        var `is`: Set<Int64>?
        var isNot: Set<Int64> = []
    }

    let matcher: FaceMatcher
    /// By the file they're of, in the order they were made.
    let rulings: [Int64: [Ruling]]

    /// `named`: the faces Photos named, with their people. `rulings`: the corrections, by the file they're of.
    /// `ruled`: every face of those files, so the ones you said are someone are compared against too.
    public init(named: [(person: Int64, print: [Float])], rulings: [Int64: [Ruling]] = [:], ruled: [Face] = []) {
        let photos = FaceMatcher(references: named)
        let taught: [(person: Int64, print: [Float])] = Self.said(of: ruled, rulings).compactMap { place, said in
            said.is.flatMap { Self.confirmed(ruled[place].print, as: $0, by: photos) }
                .map { ($0.person, ruled[place].print) }
        }
        matcher = taught.isEmpty ? photos : FaceMatcher(references: named, taught: taught)
        self.rulings = rulings
    }

    /// Each face's match, nil for no one: who you said it is (at its likeness to their faces in Photos), else its
    /// nearest at `Faces.matchFloor` of the people you didn't say it isn't. A picture's faces go together: a correction
    /// is of the face of its file that overlaps it most.
    public func matches(_ faces: [Face]) -> [FaceMatcher.Match?] {
        let said = Self.said(of: faces, rulings)
        let skipping = said.compactMapValues { $0.isNot.isEmpty ? nil : $0.isNot }
        var found = matcher.matches(faces.map(\.print), skipping: skipping)
        for (place, said) in said {
            if let people = said.is, let match = Self.confirmed(faces[place].print, as: people, by: matcher) {
                found[place] = match
            }
        }
        return found
    }

    /// A face you said is one of `people` (everyone of a name): the one whose faces in Photos it's nearest, at that
    /// likeness; the first of them, at 0, when none of theirs is compared against.
    private static func confirmed(_ print: [Float], as people: Set<Int64>, by matcher: FaceMatcher)
        -> FaceMatcher.Match? {
        guard let first = people.min() else { return nil }
        let near = matcher.nearest(print, among: people)
        return FaceMatcher.Match(person: near?.person ?? first, similarity: near?.similarity ?? 0, confirmed: true)
    }

    /// What `rulings` say of each of `faces`, by place: each is of the face of its file whose box overlaps its own most,
    /// by at least half, and a later one has the last word (a face is one person: who it is replaces who it was said to
    /// be, and who it is and who it isn't replace each other).
    static func said(of faces: [Face], _ rulings: [Int64: [Ruling]]) -> [Int: Said] {
        var said: [Int: Said] = [:]
        for (file, places) in Dictionary(grouping: faces.indices, by: { faces[$0].file }) {
            for ruling in rulings[file] ?? [] where !ruling.people.isEmpty {
                let overlaps = places.map { (place: $0, overlap: faces[$0].box.overlap(ruling.box)) }
                guard let best = overlaps.max(by: { $0.overlap < $1.overlap }), best.overlap >= Faces.sameFace
                else { continue }
                var what = said[best.place] ?? Said()
                switch ruling.says {
                case .is:
                    what.is = ruling.people
                    what.isNot.subtract(ruling.people)
                case .isNot:
                    if what.is?.isDisjoint(with: ruling.people) == false { what.is = nil }
                    what.isNot.formUnion(ruling.people)
                }
                said[best.place] = what
            }
        }
        return said
    }
}

// MARK: The faces Photos found

extension PhotosLibrary {
    /// One of a library's photos, with the faces Photos found in it, as its catalog keeps them.
    public struct PhotoFaces: Sendable, Equatable {
        public let uuid: String
        /// Its original, inside the library (originals/F/<file>), and whether it's edited: Photos then shows its
        /// render of the edit, and the faces are where they are in that.
        public let original: String
        public let edited: Bool
        public let faces: [FaceBox]

        public init(uuid: String, original: String, edited: Bool, faces: [FaceBox]) {
            (self.uuid, self.original, self.edited, self.faces) = (uuid, original, edited, faces)
        }
    }

    /// A face Photos found, and who it is when someone named them in Photos: in its catalog (`photoFaces`), and in the
    /// listing, which has only the named ones (`Asset.faces`). Where it is, as Photos keeps it and as Vision gives
    /// faces: its center from the picture's left and bottom edges, as fractions of its width and height, and its size,
    /// the side of a square, as a fraction of its long side; all in the picture as it's shown (turned upright), Photos'
    /// render of an edit when it's edited (the listing's file). Checked 2026-10-22 against the faces Vision finds
    /// itself: on the osxphotos test library's originals (each within 0.005), and on 264 random faces of a real
    /// library's previews, portrait photos turned by their orientation among them (252 had one of Vision's within a
    /// quarter of the face's size). osxphotos' `FaceInfo.center_x`, `center_y` and `size` are these as the catalog has
    /// them (ZCENTERX, ZCENTERY, ZSIZE); its `center` and `face_rect` turn them again by the picture's orientation, as
    /// if they were in the picture as stored, which they aren't.
    public struct FaceBox: Codable, Sendable, Equatable {
        /// Who it is, when someone named them in Photos: Photos' id for them and their name (two people can share a
        /// name, and stay two). Nil for a face nobody named.
        public let person: Person?
        public let x: Double
        public let y: Double
        public let size: Double

        public init(person: Person?, x: Double, y: Double, size: Double) {
            (self.person, self.x, self.y, self.size) = (person, x, y, size)
        }
    }

    /// The faces Photos found in the library's photos, read from its catalog at `catalog` (the library's
    /// database/Photos.sqlite, or a copy of it), photo by photo: people's faces with a box (not what Photos groups
    /// apart from people, nor a body whose face wasn't seen). What's left out, by reason → faces: faces in videos
    /// (they're on one of its frames), in photos in the trash, and faces whose photo is gone.
    public static func photoFaces(catalog: String) throws -> (photos: [PhotoFaces], left: [String: Int]) {
        let database = try Database(readingOnly: catalog)
        var photos: [PhotoFaces] = [], left: [String: Int] = [:]
        var current: (uuid: String, original: String, edited: Bool, faces: [FaceBox])?
        // ZDETECTIONTYPE 1 is a person's face (Photos groups the others, 3 and 4 in a real library, apart from people);
        // a size of 0 is a body whose face wasn't seen.
        // A video's faces are its asset's (ZKIND 1), or on a stretch of it (ZASSETFORTEMPORALDETECTEDFACES). A person
        // is told apart by ZPERSONUUID (by its row, should one have none), never by name.
        try database.query("""
            SELECT a.ZUUID, a.ZKIND, a.ZTRASHEDSTATE, a.ZDIRECTORY, a.ZFILENAME, a.ZADJUSTMENTSSTATE,
                   f.ZASSETFORTEMPORALDETECTEDFACES IS NOT NULL, f.ZCENTERX, f.ZCENTERY, f.ZSIZE, p.ZFULLNAME,
                   COALESCE(p.ZPERSONUUID, 'Z_PK ' || p.Z_PK)
            FROM ZDETECTEDFACE f
            LEFT JOIN ZASSET a ON a.Z_PK = f.ZASSETFORFACE
            LEFT JOIN ZPERSON p ON p.Z_PK = f.ZPERSONFORFACE
            WHERE f.ZDETECTIONTYPE = 1 AND f.ZSIZE > 0
            ORDER BY a.ZUUID
            """) { row in
            guard let uuid = row.text(0), let directory = row.text(3), let file = row.text(4) else {
                left[row.int(6) != 0 ? "in a video" : "its photo is gone", default: 0] += 1
                return
            }
            guard row.int(1) == 0 else {
                left["in a video", default: 0] += 1
                return
            }
            guard row.int(2) == 0 else {
                left["in the trash", default: 0] += 1
                return
            }
            let name = row.text(10)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let face = FaceBox(person: name.isEmpty ? nil : row.text(11).map { Person(uuid: $0, name: name) },
                               x: row.double(7), y: row.double(8), size: row.double(9))
            if current?.uuid == uuid {
                current?.faces.append(face)
                return
            }
            if let done = current {
                photos.append(PhotoFaces(uuid: done.uuid, original: done.original, edited: done.edited, faces: done.faces))
            }
            current = (uuid, "originals/\(directory)/\(file)", row.int(5) != 0, [face])
        }
        if let done = current {
            photos.append(PhotoFaces(uuid: done.uuid, original: done.original, edited: done.edited, faces: done.faces))
        }
        return (photos, left)
    }

    /// The picture to read a photo's faces in: the largest kept on this Mac of those that show it as Photos does
    /// (the faces' boxes are where they are in that): Photos' render of an edit, else the original, else Photos'
    /// preview (resources/derivatives/F/<uuid>_1_105_c.jpeg, 1,024 pixels on its long side), which is what a library
    /// that keeps its originals in iCloud has, else its small thumbnail (resources/derivatives/masters/F/
    /// <uuid>_4_5005_c.jpeg, 360 pixels on its short side), all a real library had of 1,558 of its 13,745 photos with
    /// faces. A file that's only in iCloud is never read: reading it would download it. Nil when there's none.
    public static func facePicture(of photo: PhotoFaces, in library: String) -> String? {
        let folder = String(photo.uuid.prefix(1))
        let render = ["heic", "jpeg", "jpg"].map { "resources/renders/\(folder)/\(photo.uuid)_1_201_a.\($0)" }
        let stills = ["resources/derivatives/\(folder)/\(photo.uuid)_1_105_c.jpeg",
                      "resources/derivatives/masters/\(folder)/\(photo.uuid)_4_5005_c.jpeg"]
        let candidates = (photo.edited ? render : [photo.original]) + stills
        return candidates.map { (library as NSString).appendingPathComponent($0) }.first { path in
            guard let info = FileSystem.info(of: path) else { return false }
            return info.isRegular && !info.dataless
        }
    }
}
