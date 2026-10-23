import Foundation

/// Photos' id for a person or an album in one library, which a saved search and a face correction keep them by. Photos
/// keeps it through a rename; `library` says where it was, for showing, and finding it again is by `uuid` alone, as
/// DigUp's favorites find a picture (a copy of a library has the same people and albums).
public struct PhotosID: Codable, Hashable, Sendable {
    public var library: String
    public var uuid: String

    public init(library: String, uuid: String) {
        (self.library, self.uuid) = (library, uuid)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case library, uuid
    }

    public init(from decoder: any Decoder) throws {
        try onlyKeys(CodingKeys.self, in: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        library = try container.decode(String.self, forKey: .library)
        uuid = try container.decode(String.self, forKey: .uuid)
    }
}

/// Any key at all, to see which an object of a file has (`onlyKeys`).
public struct AnyKey: CodingKey {
    public let stringValue: String
    public init(stringValue: String) { self.stringValue = stringValue }
    public var intValue: Int? { nil }
    public init?(intValue: Int) { nil }
}

/// An object of a file the user makes (`saved-searches.json`, `face-corrections.json`) has only the keys its approved
/// shape gives it (`Key`): one with any other isn't that shape, so the file is left alone rather than read and later
/// written over without that key.
public func onlyKeys<Key: CodingKey & CaseIterable>(_: Key.Type, in decoder: any Decoder) throws {
    let approved = Set(Key.allCases.map(\.stringValue))
    let others = try decoder.container(keyedBy: AnyKey.self).allKeys.map(\.stringValue).filter { !approved.contains($0) }
    guard others.isEmpty else {
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                debugDescription: "keys the approved shape doesn't have: \(others)"))
    }
}

/// What you told DigUp about the faces in pictures outside Photos ("this is Tati", "this isn't Tati"), kept over what it
/// guessed (`FaceMatching`). You make these, so they're kept out of the index, which DigUp rebuilds and which Settings →
/// Storage can delete: `face-corrections.json` beside the index folder, written by the app alone, whole on each change
/// (to a temporary file, then renamed over the old one). A file that isn't exactly this shape is left as it is, never
/// written over, and corrects nothing.
///
/// The shape (approved 2026-10-22, PHOTOS-FACTS-SCHEMA.md, "face corrections"):
///
///     { "version": 1,
///       "corrections": [ { "file": { "bookmark": "<base64>", "path": "<path>" },
///                          "face": { "x": 0.31, "y": 0.12, "width": 0.18, "height": 0.24 },
///                          "person": { "name": "<name>", "photos": [ { "library": "<path>", "uuid": "<uuid>" } ] },
///                          "says": "is", "made": "<ISO 8601>" } ] }
///
/// A file is its bookmark, which follows it when it's moved or renamed on its disk; `path` is where it last was. A face
/// is its box (`Faces.Box`), since a face's row changes whenever its picture is read again: a correction is of the face
/// of that file whose box overlaps it most, by at least half (`Faces.Box.overlap`). A person is Photos' ids for them
/// (everyone of the name, as the People filter has them), with the name they had: a rename in Photos follows, and one
/// gone from Photos makes the correction apply to no one. `is` keeps that face as that person at any likeness, and
/// teaches: it's compared against, with the faces Photos named. `isNot` drops that match, and the face goes to whoever
/// is next nearest, or no one. Only faces outside Photos: in Photos, names are corrected in Photos.
public struct FaceCorrections: Sendable, Equatable {
    public enum Says: String, Codable, Sendable {
        case `is`, isNot
    }

    public struct File: Codable, Sendable, Equatable {
        public var bookmark: Data
        public var path: String

        public init(bookmark: Data, path: String) {
            (self.bookmark, self.path) = (bookmark, path)
        }

        /// Where the file is now: where its bookmark finds it, else where it last was.
        public var whereItIs: String { resolved()?.path ?? path }

        /// Where its bookmark finds the file, and whether macOS says the bookmark is stale; nil when it finds nothing.
        fileprivate func resolved() -> (path: String, stale: Bool)? {
            #if canImport(Darwin)
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                                  relativeTo: nil, bookmarkDataIsStale: &stale) {
                return (url.path, stale)
            }
            #endif
            return nil
        }
    }

    public struct Person: Codable, Sendable, Equatable {
        public var name: String
        public var photos: [PhotosID]

        public init(name: String, photos: [PhotosID]) {
            (self.name, self.photos) = (name, photos)
        }

        /// The same person: some Photos id of theirs is the other's.
        public func isSame(as other: Person) -> Bool {
            !Set(photos.map(\.uuid)).isDisjoint(with: other.photos.map(\.uuid))
        }
    }

    public struct Correction: Codable, Sendable, Equatable {
        public var file: File
        public var face: Faces.Box
        public var person: Person
        public var says: Says
        public var made: Date

        public init(file: File, face: Faces.Box, person: Person, says: Says, made: Date = Date()) {
            (self.file, self.face, self.person, self.says, self.made) = (file, face, person, says, made)
        }

        /// Of the same face as `other`: the same file, where it last was, and boxes that overlap by at least half.
        public func isOfSameFace(as other: Correction) -> Bool {
            file.path == other.file.path && face.overlap(other.face) >= Faces.sameFace
        }
    }

    /// In the order they were made: a later one says the last word.
    public private(set) var corrections: [Correction]

    public init(_ corrections: [Correction] = []) {
        self.corrections = corrections
    }

    public static let fileName = "face-corrections.json"

    /// Beside the index folder (`~/Library/Application Support/DigUp/face-corrections.json` for the default one).
    public static func url(beside indexDirectory: URL) -> URL {
        indexDirectory.deletingLastPathComponent().appendingPathComponent(fileName)
    }

    /// `correction` added last: it replaces any earlier one of the same face and person, and, saying who the face is,
    /// any earlier one saying it's someone else (a face is one person).
    public mutating func add(_ correction: Correction) {
        corrections.removeAll { old in
            old.isOfSameFace(as: correction)
                && (old.person.isSame(as: correction.person) || old.says == .is && correction.says == .is)
        }
        corrections.append(correction)
    }

    /// Each correction's file looked up by its bookmark again: one moved or renamed gets where it is now (and a fresh
    /// bookmark when macOS says the old one is stale). Whether anything changed.
    public mutating func followMoves() -> Bool {
        var changed = false
        for index in corrections.indices {
            guard let (path, stale) = corrections[index].file.resolved() else { continue }
            if path != corrections[index].file.path {
                corrections[index].file.path = path
                changed = true
            }
            #if canImport(Darwin)
            if stale, let fresh = try? URL(fileURLWithPath: path).bookmarkData() {
                corrections[index].file.bookmark = fresh
                changed = true
            }
            #endif
        }
        return changed
    }

    // MARK: The file

    private struct Stored: Codable {
        var version: Int
        var corrections: [Correction]

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case version, corrections
        }

        init(version: Int, corrections: [Correction]) {
            (self.version, self.corrections) = (version, corrections)
        }

        init(from decoder: any Decoder) throws {
            try onlyKeys(CodingKeys.self, in: decoder)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(Int.self, forKey: .version)
            guard version == 1 else {
                throw DecodingError.dataCorruptedError(forKey: .version, in: container,
                                                       debugDescription: "version \(version); this DigUp reads 1")
            }
            corrections = try container.decode([Correction].self, forKey: .corrections)
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    /// The corrections in `data`, which throws unless it's exactly the approved shape.
    public init(data: Data) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.init(try decoder.decode(Stored.self, from: data).corrections)
    }

    /// The corrections in the file at `url`: none when there's no file. Throws when it can't be read, or isn't exactly
    /// the approved shape.
    public init(contentsOf url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            self.init()
            return
        }
        try self.init(data: Data(contentsOf: url))
    }

    /// The file's bytes.
    public func data() throws -> Data {
        try Self.encoder.encode(Stored(version: 1, corrections: corrections))
    }
}

extension FaceCorrections.File {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case bookmark, path
    }

    public init(from decoder: any Decoder) throws {
        try onlyKeys(CodingKeys.self, in: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bookmark = try container.decode(Data.self, forKey: .bookmark)
        path = try container.decode(String.self, forKey: .path)
    }
}

extension FaceCorrections.Person {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case name, photos
    }

    public init(from decoder: any Decoder) throws {
        try onlyKeys(CodingKeys.self, in: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        photos = try container.decode([PhotosID].self, forKey: .photos)
    }
}

extension FaceCorrections.Correction {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case file, face, person, says, made
    }

    public init(from decoder: any Decoder) throws {
        try onlyKeys(CodingKeys.self, in: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        file = try container.decode(FaceCorrections.File.self, forKey: .file)
        face = try container.decode(Faces.Box.self, forKey: .face)
        person = try container.decode(FaceCorrections.Person.self, forKey: .person)
        says = try container.decode(FaceCorrections.Says.self, forKey: .says)
        made = try container.decode(Date.self, forKey: .made)
    }
}

/// A box as `face-corrections.json` keeps it: its x, y, width and height, all of it inside the picture.
extension Faces.Box: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case x, y, width, height
    }

    public init(from decoder: any Decoder) throws {
        try onlyKeys(CodingKeys.self, in: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let (x, y) = (try container.decode(Double.self, forKey: .x), try container.decode(Double.self, forKey: .y))
        let (width, height) = (try container.decode(Double.self, forKey: .width),
                               try container.decode(Double.self, forKey: .height))
        // As `faces` keeps boxes: a hair over the edge is rounding, more isn't a box in the picture.
        guard x >= 0, y >= 0, width > 0, height > 0, x + width <= 1.0001, y + height <= 1.0001,
              let box = Faces.Box(x: x, y: y, width: width, height: height) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "not a box inside the picture"))
        }
        self = box
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(x, forKey: .x)
        try container.encode(y, forKey: .y)
        try container.encode(width, forKey: .width)
        try container.encode(height, forKey: .height)
    }
}
