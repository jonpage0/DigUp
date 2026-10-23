import Foundation

/// Telling people apart by their faces: a prototype, measured with `digup faces-eval` on the people named in a Photos
/// library. Nothing of it is kept or shown in the app yet.
///
/// A face recognizer (`FaceRecognizer`, on the Mac: Platform/Apple/Faces+Apple.swift) turns each face of a picture into
/// an embedding, a list of numbers that comes out alike for two faces of one person and apart for two people's; how
/// alike two are is the cosine of the angle between them (`cosine`). Apple publishes no way to say who a face is, so
/// there are two: Vision's own faceprints, through a request Vision doesn't publish, and a Core ML model of the ArcFace
/// family given by its file (SFace, from OpenCV Zoo, made by scripts/face-model.py), which needs each face aligned
/// first: turned, scaled and moved so that its eyes, nose and mouth sit where the model expects them
/// (`arcFaceTemplate`, `Similarity`). What's here needs neither Vision nor Core ML: the alignment's arithmetic, the
/// comparison, the measurement (`Measure`), and the faces Photos found in a library (`PhotosLibrary.photoFaces`).
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

    /// A face Photos found, and who it is when someone named them in Photos. Where it is, as Photos keeps it and as
    /// Vision gives faces: its center from the picture's left and bottom edges, as fractions of its width and height,
    /// and its size, the side of a square, as a fraction of its long side; all in the picture as it's shown (turned
    /// upright). Checked 2026-10-22 against the faces Vision finds itself: on the osxphotos test library's originals
    /// (each within 0.005), and on 264 random faces of a real library's previews, portrait photos turned by their
    /// orientation among them (252 had one of Vision's within a quarter of the face's size).
    public struct FaceBox: Sendable, Equatable {
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
