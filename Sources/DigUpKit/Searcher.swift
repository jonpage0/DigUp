import Foundation

public struct SearchHit: Sendable {
    public let path: String
    public let kind: FileKind
    public let score: Double          // fused rank score, for ordering only
    public let z: Double?             // how far the best segment stands out for this query (`Searcher.meaning`)
    public let cosine: Double?
    public let keywordRank: Int?      // 1-based rank among keyword matches
    public let segment: SegmentKind
    /// The segment the hit points at (its text is `Searcher.text(ofSegment:)`).
    public let segmentID: Int64
    public let loc: Double?           // PDF page, or seconds into audio/video
    public let locEnd: Double?
    public let excerpt: String?
    /// The file's modification date (seconds since 1970), and what indexing learned about it: "width", "height",
    /// "taken", "pages", "duration"… (see `Indexer`).
    public let modified: Double
    public let size: Int64
    public let info: [String: String]
    /// Code: the line to open at, in the stretch (`loc`…`locEnd`): where the name looked up is defined, or the first
    /// line with the query's words. Nil: the stretch's first line.
    public var focus: Double? = nil
    /// A picture or video of a Photos library: where it is in Photos, and what Photos calls it.
    public var photos: PhotosHit? = nil
    /// A video or audio file: how many moments of it match the query (`Searcher.moments(of:text:queryVector:zGate:)`),
    /// counted from the scores the search has anyway, and from its stretches of speech that hold the query's words. 0
    /// when none does (it's here by its name, say).
    public var momentCount = 0
    /// A picture or a video: what the sensitive-picture detector said of each of its pictures (`SensitivePictures`).
    /// Nil for any other file.
    public var pictures: SensitivePictures? = nil
    /// A picture outside Photos kept by the People filter: the faces in it taken for its people.
    public var faces: [FaceMatch] = []
}

/// A face in a picture outside Photos that the People filter took for one of its people (`SearchFilter.people`): who,
/// by their name in Photos and their row, where the face is, how alike it is to theirs, and whether you said it's them
/// (`FaceCorrections`).
public struct FaceMatch: Sendable, Equatable {
    public let name: String
    public let person: Int64
    public let box: Faces.Box
    public let similarity: Double
    public let confirmed: Bool
}

/// A stretch of a recording that matches a query (`Searcher.moments(of:text:queryVector:zGate:)`): its segments that
/// stand out on the query's scale or hold the query's words, neighbours of the same kind merged into one.
public struct Moment: Sendable, Equatable {
    public enum Kind: String, Sendable {
        /// A frame of the video, or one of Photos' stills of a video in iCloud.
        case seen
        /// A window of its sound (an audio file, or a video's soundtrack).
        case heard
        /// A stretch of what's said in it (`Speech`), found by what its words mean or by the words themselves.
        case said

        /// The kind of moment a recording's segment makes; nil for one that makes none (its name, Photos' words).
        public init?(_ segment: SegmentKind) {
            switch segment {
            case .frame: self = .seen
            case .audio: self = .heard
            case .speech: self = .said
            default: return nil
            }
        }

        /// The segments a moment of this kind is made of.
        public var segment: SegmentKind {
            switch self {
            case .seen: .frame
            case .heard: .audio
            case .said: .speech
            }
        }
    }

    public let kind: Kind
    /// Seconds into the recording, from where its first segment starts to where its last one ends. Nil for a still,
    /// which carries no time.
    public let start: Double?
    public let end: Double?
    /// A video in iCloud read from Photos' filmstrip: the still's place in it, from 0 (the indexer writes a stills
    /// video's frames in the filmstrip's order, `PhotosLibrary.filmstrip(startingAt:)`).
    public let still: Int?
    /// Its best segment's score as `search` scores a file (what it means for the query and the query's words in it):
    /// the moments of a file go best first.
    public let score: Double
    /// Its best segment.
    public let segmentID: Int64
    /// What's said in a `said` moment, as the index keeps it; nil for the others.
    public let words: String?
}

/// A hit from a Photos library (`PhotosLibrary`): the asset it shows, its title and date in Photos (from its
/// `photosInfo` segment), and what DigUp read of it.
public struct PhotosHit: Sendable, Equatable {
    /// The library, as the index spells it (a real path).
    public let library: String
    public let uuid: String
    /// Its title in Photos, else the name of the file it came in as ("" if the crawl hasn't said yet).
    public let title: String
    /// When it was taken, in seconds since 1970.
    public let date: Double?
    /// The file read of it (nil if the crawl hasn't said yet): a video in iCloud was read from Photos' stills of it or
    /// its poster (`PhotosLibrary.Reading.isStandIn`), a photo in iCloud from its preview.
    public var reading: PhotosLibrary.Reading? = nil
    /// A video in iCloud: the still to show for it. The one that matched when the hit is one of its stills (a stills
    /// video's frame segments are its filmstrip's stills, in order), else its first still or its poster.
    public var still: String? = nil
}

/// What a search keeps besides its kinds: Photos' facts about a library's files, where files were taken, how long and
/// what shape they are, and when they're from. The parts combine with AND; an empty filter keeps every file.
public struct SearchFilter: Sendable, Equatable {
    /// People a file must show, every one of them (ids of `IndexStore.photosPeople`). An entry is one person, or the
    /// people who share a name, any of whom counts for it. An empty entry keeps nothing: a saved search's person who
    /// isn't in the indexed libraries any more (the app's saved searches never widen to everyone). A file shows a person
    /// when Photos says so, or, outside Photos, when one of its faces matches theirs at `Faces.threshold` or you said
    /// it's them (`face_matches`, or `faceMatches`).
    public var people: [Set<Int64>]
    /// Albums a file must be in, any of them (ids of `IndexStore.photosAlbums`). Nil keeps every file; an empty set
    /// keeps none (a saved search's albums, none of them indexed any more).
    public var albums: Set<Int64>?
    /// Only Photos' favorites.
    public var favorites: Bool
    /// How a file came into its library, any of these (`PhotosLibrary.Origin`'s raw values).
    public var origins: Set<String>
    /// The device that took a file, any of these (`IndexStore.photosCameras`' models).
    public var cameras: Set<String>
    /// Shot on one of these devices (`IndexStore.photosCameras`' models), the app's "Shot on my devices": a camera
    /// took it into the library (origin camera) on one of them, or with no device recorded (Photos says a camera took
    /// it, which is the user's: 234 of 21,165 in a real library had no device name); or an older item, which Photos
    /// says nothing about (origin unknown), whose device is one of them. Nil doesn't filter; an empty set (every
    /// device taken off the user's list) keeps only what a camera saved with no device named.
    public var shotOn: Set<String>?
    /// Only these files, by path (the app's own favorites, `IndexStore.paths(ofAssets:)` for a Photos item's current
    /// file). Nil keeps every file; an empty set keeps none.
    public var paths: Set<String>?
    /// Only files taken inside this box (`IndexStore.locations`).
    public var area: Area?
    /// Of the Photos libraries' files, only these, by path; every other file of a library is left out (each of them,
    /// when it's empty). Nil keeps them all. What an AI app may see of the libraries (`digup mcp`, `AIAccess`): left out
    /// before anything is matched, counted or cut to the best, so it's never in a result or a count, and found by path,
    /// whatever the index knows of the file yet.
    public var photosOnly: Set<String>?
    /// Only files with a picture rated sensitive at this position (the Sensitive filter): a picture, or a frame or a
    /// still of a video (`sensitive_scores`).
    public var sensitive: SensitivePosition?
    /// Leaves out every file with a picture rated sensitive at this position, and every picture or video not rated yet
    /// (not read, or with a picture the rating pass hasn't got to, or never read: too small, or unreadable): what an AI
    /// app doesn't see while "Pictures rated sensitive" is off (`AIAccess.sensitive`), fail-safe as hidden Photos items
    /// are. Left out before anything is matched, counted or cut to the best, as `photosOnly` is.
    public var leavingOutSensitive: SensitivePosition?
    /// Only videos and recordings this long (`media_dimensions.duration`): the Length filter.
    public var length: Length?
    /// Only pictures and videos of this shape as they're shown (`media_dimensions.width`, `height`): the Shape filter.
    public var shape: Shape?
    /// Only files from this time, by their date (`FileDate`): the When filter.
    public var when: When?
    /// Only files taken near this place (`digup mcp`'s `near`; beside `area`, both keep what's in both).
    public var near: Near?
    /// The faces outside Photos matched to people, by face, to go by instead of the index's own (`face_matches`): what an
    /// AI app is told is matched only with the named faces it may see (`IndexStore.faceMatches(referencesKeptBy:)`,
    /// `digup mcp`). Nil goes by the index's.
    public var faceMatches: [Int64: FaceMatcher.Match]?

    /// A box on the map, in degrees: south to north, west to east.
    public struct Area: Sendable, Equatable {
        public var latitudes: ClosedRange<Double>
        public var longitudes: ClosedRange<Double>

        public init(latitudes: ClosedRange<Double>, longitudes: ClosedRange<Double>) {
            (self.latitudes, self.longitudes) = (latitudes, longitudes)
        }
    }

    /// How long a video or a recording is, in seconds: `atLeast` or longer, and shorter than `under`; either may be
    /// left out, not both (approved 2026-10-22). The Length menu offers `buckets`; a saved search keeps one as
    /// `{"atLeast": 15, "under": 60}` (its `Codable`), `digup mcp` takes `{at_least, under}`.
    public struct Length: Sendable, Hashable {
        public let atLeast: Double?
        public let under: Double?
        /// The longest a bound can be: ten years of 365 days, in seconds. Any longer is no recording's, and a number
        /// that big can't be said in minutes and seconds (a Length token says it so): the CLI, `digup mcp` and a saved
        /// search's reader turn it down, as they do any length `init` does.
        public static let longest: Double = 10 * 365 * 24 * 60 * 60

        /// Nil with no bound, a bound below 0 (`under` above it), over `longest` or that isn't a number, or `atLeast`
        /// not below `under`.
        public init?(atLeast: Double? = nil, under: Double? = nil) {
            guard atLeast != nil || under != nil, atLeast.map({ 0 <= $0 && $0 <= Self.longest }) ?? true,
                  under.map({ 0 < $0 && $0 <= Self.longest }) ?? true else { return nil }
            if let atLeast, let under, atLeast >= under { return nil }
            (self.atLeast, self.under) = (atLeast, under)
        }

        /// The Length menu's: under 15 s, 15 s – 1 min, 1 – 5 min, over 5 min.
        public static let buckets: [Length] = {
            let bounds: [(atLeast: Double?, under: Double?)] = [(nil, 15), (15, 60), (60, 300), (300, nil)]
            return bounds.compactMap { Length(atLeast: $0.atLeast, under: $0.under) }
        }()

        /// As `digup search --length` and the app's debug flags write it, in seconds: "15..60", "..15", "300..".
        public init?(_ text: String) {
            let bounds = text.components(separatedBy: "..")
            guard bounds.count == 2, bounds.allSatisfy({ $0.isEmpty || Double($0) != nil }) else { return nil }
            self.init(atLeast: Double(bounds[0]), under: Double(bounds[1]))
        }

        public var text: String {
            func seconds(_ value: Double?) -> String {
                guard let value else { return "" }
                return value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(value)
            }
            return seconds(atLeast) + ".." + seconds(under)
        }

        /// The files this long, as a condition on a `media_dimensions` row (a still picture's has no duration, which
        /// no bound holds), and the values it takes.
        var condition: (sql: String, values: [SQLValue]) {
            let bounds = [atLeast.map { ("duration >= ?", $0) }, under.map { ("duration < ?", $0) }].compactMap { $0 }
            return (bounds.map(\.0).joined(separator: " AND "), bounds.map { .double($0.1) })
        }
    }

    /// What shape a picture or a video is as it's shown (approved 2026-10-22): taller than wide, wider than tall, square
    /// (its sides within 5 %), wide (2:1 or wider: panoramas and cinema), or an exact ratio, width to height in whole
    /// numbers from 1 to 99, its orientation included ("16:9" is landscape, "9:16" portrait), matched within 2 %. Square
    /// is apart from portrait and landscape; wide is among landscape. Written as a saved search and `digup mcp` keep it:
    /// "portrait", "landscape", "square", "wide" or "W:H" (`text`).
    public enum Shape: Sendable, Hashable {
        case portrait, landscape, square, wide
        case ratio(width: Int, height: Int)

        /// Square: the long side at most this many times the short one (5 %).
        public static let squareTolerance = 1.05
        /// Wide: at least this many times as wide as tall (2:1).
        public static let wideRatio = 2.0
        /// An exact ratio: a shape at most this many times wider or narrower than it (2 %), the same either way, so a
        /// picture and the same picture turned match "16:9" and "9:16" alike.
        public static let ratioTolerance = 1.02
        /// The whole numbers an exact ratio is written in.
        public static let ratioTerms = 1...99
        /// The Shape menu's exact ratios.
        public static let ratios: [Shape] = [.ratio(width: 16, height: 9), .ratio(width: 9, height: 16),
                                             .ratio(width: 4, height: 3), .ratio(width: 3, height: 4),
                                             .ratio(width: 3, height: 2), .ratio(width: 2, height: 3)]

        /// From `text`: one of the four names, or "W:H" written plainly (no sign, no leading zero), each from 1 to 99.
        public init?(_ text: String) {
            switch text {
            case "portrait": self = .portrait
            case "landscape": self = .landscape
            case "square": self = .square
            case "wide": self = .wide
            default:
                let terms = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
                guard terms.count == 2, let width = Int(terms[0]), let height = Int(terms[1]),
                      terms == [String(width), String(height)], Self.ratioTerms.contains(width),
                      Self.ratioTerms.contains(height) else { return nil }
                self = .ratio(width: width, height: height)
            }
        }

        public var text: String {
            switch self {
            case .portrait: "portrait"
            case .landscape: "landscape"
            case .square: "square"
            case .wide: "wide"
            case .ratio(let width, let height): "\(width):\(height)"
            }
        }

        /// Whether a `media_dimensions` row's width and height are this shape, in SQL.
        var condition: String {
            switch self {
            case .portrait: "height > width * \(Self.squareTolerance)"
            case .landscape: "width > height * \(Self.squareTolerance)"
            case .square: "MAX(width, height) <= MIN(width, height) * \(Self.squareTolerance)"
            case .wide: "width >= height * \(Self.wideRatio)"
            case .ratio(let width, let height):
                "width * \(height) BETWEEN height * \(width) / \(Self.ratioTolerance) "
                    + "AND height * \(width) * \(Self.ratioTolerance)"
            }
        }
    }

    public init(people: [Set<Int64>] = [], albums: Set<Int64>? = nil, favorites: Bool = false,
                origins: Set<String> = [], cameras: Set<String> = [], shotOn: Set<String>? = nil,
                paths: Set<String>? = nil, area: Area? = nil, length: Length? = nil, shape: Shape? = nil,
                when: When? = nil, near: Near? = nil) {
        (self.people, self.albums, self.favorites, self.area) = (people, albums, favorites, area)
        (self.origins, self.cameras, self.shotOn, self.paths) = (origins, cameras, shotOn, paths)
        (self.length, self.shape, self.when, self.near) = (length, shape, when, near)
    }

    public var isEmpty: Bool {
        people.isEmpty && albums == nil && !favorites && origins.isEmpty && cameras.isEmpty && shotOn == nil
            && paths == nil && area == nil && photosOnly == nil && sensitive == nil && leavingOutSensitive == nil
            && length == nil && shape == nil && when == nil && near == nil
    }

    /// What of it leaves files out of an AI app's sight (`photosOnly`, `leavingOutSensitive`); empty for DigUp's own
    /// searches. A file it leaves out bears on nothing a search does, not even on whether a word counts as indexed
    /// (`Searcher.search`'s prefix matching).
    var exclusions: SearchFilter {
        var exclusions = SearchFilter()
        (exclusions.photosOnly, exclusions.leavingOutSensitive) = (photosOnly, leavingOutSensitive)
        return exclusions
    }

    /// A part of the query that keeps no file (`IN ()` isn't SQL).
    private static let keepsNothing = "SELECT id FROM files WHERE 0"

    /// The files it keeps, as a query of their ids and the values it takes; nil when it keeps every file.
    var query: (sql: String, values: [SQLValue])? {
        func list(_ ids: Set<Int64>) -> String { ids.map(String.init).joined(separator: ",") }
        func placeholders(_ words: Set<String>) -> String { words.map { _ in "?" }.joined(separator: ",") }
        var parts: [String] = [], values: [SQLValue] = []
        for group in people {
            guard !group.isEmpty else {
                parts.append(Self.keepsNothing)
                continue
            }
            // Compound selects run left to right: the two ways a file shows someone are one select of the INTERSECT.
            parts.append("SELECT file FROM (SELECT file FROM photos_person_files WHERE person IN (\(list(group))) UNION "
                         + matched(group, values: &values) + ")")
        }
        if let albums {
            parts.append(albums.isEmpty ? Self.keepsNothing
                                        : "SELECT file FROM photos_album_files WHERE album IN (\(list(albums)))")
        }
        if favorites { parts.append("SELECT file FROM photos_assets WHERE favorite = 1") }
        if !origins.isEmpty {
            parts.append("SELECT file FROM photos_assets WHERE origin IN (\(placeholders(origins)))")
            values += origins.map { .text($0) }
        }
        if !cameras.isEmpty {
            parts.append("SELECT file FROM photos_assets WHERE camera IN (\(placeholders(cameras)))")
            values += cameras.map { .text($0) }
        }
        if let shotOn {
            if shotOn.isEmpty {
                parts.append("SELECT file FROM photos_assets WHERE origin = 'camera' AND camera IS NULL")
            } else {
                let devices = placeholders(shotOn)
                parts.append("""
                    SELECT file FROM photos_assets
                    WHERE (origin = 'camera' AND (camera IS NULL OR camera IN (\(devices))))
                        OR (origin = 'unknown' AND camera IN (\(devices)))
                    """)
                values += shotOn.map { .text($0) } + shotOn.map { .text($0) }
            }
        }
        if let paths {
            parts.append(paths.isEmpty ? Self.keepsNothing
                                       : "SELECT id FROM files WHERE path IN (\(placeholders(paths)))")
            values += paths.map { .text($0) }
        }
        if let area {
            parts.append("SELECT file FROM locations WHERE latitude BETWEEN ? AND ? AND longitude BETWEEN ? AND ?")
            values += [.double(area.latitudes.lowerBound), .double(area.latitudes.upperBound),
                       .double(area.longitudes.lowerBound), .double(area.longitudes.upperBound)]
        }
        if let length {
            let condition = length.condition
            parts.append("SELECT file FROM media_dimensions WHERE \(condition.sql)")
            values += condition.values
        }
        if let shape {
            parts.append("SELECT file FROM media_dimensions WHERE \(shape.condition)")   // a recording's has no size
        }
        for part in [when?.query, near?.query].compactMap({ $0 }) {
            parts.append(part.sql)
            values += part.values
        }
        if let photosOnly {
            // As `PhotosLibrary.library(containing:)`; the paths kept go as one value (a library has thousands).
            parts.append("SELECT id FROM files WHERE path NOT LIKE ?"
                         + (photosOnly.isEmpty ? "" : " OR path IN (SELECT value FROM json_each(?))"))
            values.append(.text(PhotosLibrary.filesPattern))
            if !photosOnly.isEmpty {
                // A list of strings always encodes; were it not to, none would be kept.
                let list = try? JSONSerialization.data(withJSONObject: Array(photosOnly), options: .withoutEscapingSlashes)
                values.append(.text(list.map { String(decoding: $0, as: UTF8.self) } ?? "[]"))
            }
        }
        if let sensitive {
            parts.append("SELECT s.file FROM sensitive_scores JOIN segments s ON s.id = segment WHERE "
                         + sensitive.condition)
        }
        if let leavingOutSensitive {
            // A file that isn't a picture or a video has no picture to rate; one that is must have been read, and each
            // of its pictures rated and not sensitive.
            parts.append("""
                SELECT id FROM files f WHERE f.kind NOT IN \(IndexStore.pictureKinds) OR (f.state IN \
                \(IndexStore.readStates) AND NOT \(IndexStore.hasUnratedPicture) AND NOT EXISTS (
                    SELECT 1 FROM sensitive_scores JOIN segments s ON s.id = segment
                    WHERE s.file = f.id AND \(leavingOutSensitive.condition)))
                """)
        }
        return parts.isEmpty ? nil : (parts.joined(separator: " INTERSECT "), values)
    }

    /// The files outside Photos with a face that matches one of `group` at `Faces.threshold`, or that you said is one of
    /// them, as SQL (its values added to `values`).
    private func matched(_ group: Set<Int64>, values: inout [SQLValue]) -> String {
        guard let faceMatches else {
            return """
                SELECT s.file FROM face_matches m JOIN faces f ON f.id = m.face JOIN segments s ON s.id = f.segment
                WHERE m.person IN (\(group.map(String.init).joined(separator: ",")))
                AND (m.similarity >= \(Faces.threshold) OR m.confirmed = 1)
                """
        }
        let faces = faceMatches.filter {
            group.contains($0.value.person) && ($0.value.similarity >= Faces.threshold || $0.value.confirmed)
        }
        values.append(.text("[" + faces.keys.map(String.init).joined(separator: ",") + "]"))
        return """
            SELECT s.file FROM faces f JOIN segments s ON s.id = f.segment WHERE f.id IN (SELECT value FROM json_each(?))
            """
    }
}

/// Any key of a JSON object, to see which keys it has.
struct JSONKey: CodingKey {
    let stringValue: String
    init(stringValue: String) { self.stringValue = stringValue }
    var intValue: Int? { nil }
    init?(intValue: Int) { nil }
}

/// A length as a saved search keeps it (`saved-searches.json`'s `{"length": …}`, approved 2026-10-22): `{"atLeast": 15,
/// "under": 60}`, in seconds, an open bound left out. Read strictly, as the app reads the file: another key, a bound
/// that's null or not a number, or bounds `init(atLeast:under:)` turns down aren't this shape.
extension SearchFilter.Length: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case atLeast, under
    }

    public init(from decoder: any Decoder) throws {
        let keys = try decoder.container(keyedBy: JSONKey.self).allKeys.map(\.stringValue)
        let known = Set(CodingKeys.allCases.map(\.rawValue))
        guard keys.allSatisfy(known.contains) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "a length has atLeast and under, not \(keys)"))
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func bound(_ key: CodingKeys) throws -> Double? {
            container.contains(key) ? try container.decode(Double.self, forKey: key) : nil
        }
        guard let length = Self(atLeast: try bound(.atLeast), under: try bound(.under)) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription:
                "a length has a bound or two, from 0 to \(Int(Self.longest)) seconds, atLeast below under"))
        }
        self = length
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(atLeast, forKey: .atLeast)
        try container.encodeIfPresent(under, forKey: .under)
    }
}

/// A shape as a saved search keeps it (`saved-searches.json`'s `{"shape": …}`, approved 2026-10-22): its `text`, read
/// strictly (`init(_:)`).
extension SearchFilter.Shape: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let shape = Self(try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription:
                "a shape is portrait, landscape, square, wide or W:H in whole numbers from 1 to 99")
        }
        self = shape
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(text)
    }
}

/// Hybrid search: meaning (EmbeddingGemma's vectors) + words (FTS5).
///
/// Meaning is the model's cosine similarity, put on one scale per query (`meaning`): every vector is scored anyway, so
/// the distribution comes for free, and only segments that stand out (`zGate`) count as meaning matches. That also
/// gives an honest "nothing found". Words rescue what a vector can't hold exactly: codes, IDs and names.
public final class Searcher {
    let store: IndexStore
    private var matrix: VectorStorage?   // rows × 768 float16, row-major
    private var rowFile: [Int64] = []
    private var rowSegment: [Int64] = []
    private var rowModality: [Modality] = []
    /// False for the vectors the later pass adds (`Indexer.finishLongFiles`): scored, but they don't set the scale.
    private var rowSetsScale: [Bool] = []
    private var fileKind: [Int64: FileKind] = [:]
    public private(set) var vectorSource: String?
    /// False after `releaseVectors()` (or `loadVectors: false`): keyword search still works, and the next search with
    /// a query vector loads them again.
    public private(set) var vectorsLoaded = false

    public var vectorCount: Int { rowFile.count }

    /// This is the code index's searcher (`IndexStore.codeFile`): names are looked up as names (`CodeLookup`).
    public var isCode: Bool { store.file.lastPathComponent == IndexStore.codeFile }

    /// With `loadVectors: false` only keyword search is ready; vectors load on the first meaning search. The app
    /// uses that to stay small while idle: 20k vectors are ~30 MB.
    public init(store: IndexStore, loadVectors: Bool = true) throws {
        self.store = store
        if loadVectors { try reload() } else { try reloadFiles() }
    }

    /// Reads the files and all vectors again (after indexing added some).
    public func reload() throws {
        releaseVectors()
        try reloadFiles()
        var rows = 0
        try store.db.query("SELECT COUNT(*) FROM segments WHERE vec IS NOT NULL") { rows = Int($0.int(0)) }
        guard let matrix = VectorStorage(rows: rows) else {
            vectorsLoaded = true   // nothing to load
            return
        }
        let rowBytes = Vectors.dimension * MemoryLayout<Float16>.stride
        let steps = IndexOptions()
        try store.db.query("""
            SELECT s.id, s.file, s.modality, s.vec, s.kind, s.loc, f.kind, CAST(json_extract(f.info, '$.pages') AS INTEGER)
            FROM segments s JOIN files f ON f.id = s.file WHERE s.vec IS NOT NULL ORDER BY s.id
            """) { row in
            guard let blob = row.blob(3), blob.count == rowBytes, rowFile.count < rows else { return }
            blob.copyBytes(to: UnsafeMutableRawBufferPointer(start: matrix.halves + rowFile.count * Vectors.dimension,
                                                             count: rowBytes))
            rowSegment.append(row.int(0))
            rowFile.append(row.int(1))
            rowModality.append(Modality(rawValue: row.text(2) ?? "") ?? .none)
            // Past the first step of a long PDF (its pages) or document (its chunks).
            let (kind, place) = (row.text(4), row.isNull(5) ? 0 : Int(row.double(5)))
            let later = row.text(6) == "pdf"
                ? kind != SegmentKind.chunk.rawValue && Int(row.int(7)) > steps.bigPDFPages && place > steps.pdfStep
                : kind == SegmentKind.chunk.rawValue && place > steps.docStep
            rowSetsScale.append(!later)
        }
        self.matrix = matrix
        vectorsLoaded = true
    }

    /// Frees the vectors' memory; keyword search keeps working.
    public func releaseVectors() {
        matrix = nil
        rowFile = []
        rowSegment = []
        rowModality = []
        rowSetsScale = []
        vectorsLoaded = false
    }

    private func reloadFiles() throws {
        fileKind.removeAll(keepingCapacity: true)
        try store.db.query("SELECT id, kind FROM files") { row in
            fileKind[row.int(0)] = FileKind(rawValue: row.text(1) ?? "")
        }
        vectorSource = try store.meta("vector_source")
    }

    /// How much finding the query's words counts against meaning (`search`). Code's words count for less: they're
    /// everywhere in code ("app", "running", "location"), and a stretch that shares a few of them beat the one that
    /// does what the query says (2026-10-09, the real-code eval of 27 queries over DigUp, Sparkle and llama.cpp: 18 → 20
    /// found first, the top 5 unchanged; the synthetic code eval 40 → 41 of 41; 1.5 changed nothing, 0.5 lost the top 5).
    public static let wordWeight = 2.0
    public static let codeWordWeight = 1.0

    /// `filter` narrows the files as `kinds` does. With no words (`text` blank) and a filter, the search lists what the
    /// filter keeps instead, newest first (`browse`).
    ///
    /// Required words typed in it (`+beach`, `+"a phrase"`: `RequiredWords`) keep only the files that have each of them,
    /// found as `filesHaving` finds them: the results are ranked by the whole query with the marks removed (as the
    /// caller embeds it for `queryVector`), over the files that have every required term, narrowed the way a filter
    /// narrows, before the keyword matches are cut to the best. `requiredVectors`: each term embedded alone, by the
    /// term as `RequiredWords.terms` has it; a term without one is found by its words only. Code's `+` is literal.
    public func search(_ query: String, queryVector: [Float]?, requiredVectors: [String: [Float]] = [:],
                       kinds: Set<FileKind>? = nil, filter: SearchFilter = SearchFilter(), limit: Int = 20,
                       zGate: Double = 2.0, wordWeight: Double? = nil, prefixLast: Bool = false) throws -> [SearchHit] {
        let required = isCode ? RequiredWords(literal: query) : RequiredWords(query)
        let text = required.text
        if !filter.isEmpty, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return try browse(filter, kinds: kinds, limit: limit)
        }
        let wordWeight = wordWeight ?? (isCode ? Self.codeWordWeight : Self.wordWeight)
        if queryVector != nil || !requiredVectors.isEmpty, !vectorsLoaded { try reload() }
        let fileKind = self.fileKind
        let narrowing = filter.query
        let kept = try narrowing.map { query -> Set<Int64> in
            var files = Set<Int64>()
            try store.db.query(query.sql, query.values) { files.insert($0.int(0)) }
            return files
        }
        // Only the rows the caller may see set the meaning scale (`rowsSettingScale`), the query's and each required
        // word's.
        let setsScale = try rowsSettingScale(seeing: filter.exclusions)
        let having = required.terms.isEmpty ? nil
            : try filesHaving(required.terms, typing: prefixLast ? required.typing : nil, vectors: requiredVectors,
                              zGate: zGate, setsScale: setsScale, narrowing: narrowing, kept: kept,
                              exclusions: filter.exclusions.query)
        let allowed = { (file: Int64) -> Bool in
            (kinds == nil || fileKind[file].map { kinds!.contains($0) } ?? false) && (kept?.contains(file) ?? true)
                && (having?.contains(file) ?? true)
        }
        // Meaning: score every vector on this query's scale (`meaning`), set by the vectors the caller may see
        // (`rowsSettingScale`), keep each file's best segment, and a recording's segments that stand out (its moments,
        // counted for the hits it makes).
        var best: [Int64: (z: Double, cosine: Double, row: Int)] = [:]
        var standouts: [Int64: [(segment: Int64, z: Double)]] = [:]
        if let query = queryVector, query.count == Vectors.dimension, !rowFile.isEmpty {
            let scores = score(query)
            let meaning = Self.meaning(scores, rowModality, setsScale: setsScale)
            for row in 0..<scores.count where allowed(rowFile[row]) {
                let (file, z) = (rowFile[row], meaning[row])
                if z > (best[file]?.z ?? -.infinity) { best[file] = (z, Double(scores[row]), row) }
                if z >= zGate, let kind = fileKind[file], Self.recordings.contains(kind) {
                    standouts[file, default: []].append((rowSegment[row], z))
                }
            }
        }

        // Words: FTS5 with Porter stemming over file names, folder names, OCR, page and document text, and what's said
        // in recordings. A name from code ("quantize_row_q8_0_ref") is matched as one phrase, as it's written.
        let terms = Self.terms(text)
        let identifier = isCode ? CodeLookup.identifier(text) : nil
        var words: [(file: Int64, segment: Int64, snippet: String?)] = []
        var coverage: [Int64: Double] = [:]   // share of the query's words found anywhere in the file
        // Only the files an AI app may see count for a word's prefix matching (`SearchFilter.exclusions`).
        let patterns = try identifier.map { [CodeLookup.phrase($0)] }
            ?? wordPatterns(terms, prefixLast: prefixLast, within: filter.exclusions.query)
        // An AI app's search: which files match, how far, and where, from the files it sees alone (`wordsInSight`).
        let inSight = filter.exclusions.query != nil
        if !patterns.isEmpty, inSight {
            (words, coverage) = try wordsInSight(patterns, within: narrowing, allowed: allowed)
        } else if !patterns.isEmpty {
            var seen = Set<Int64>()
            // The filter and the required words narrow the matches before they're cut to the best 1,000: else a file
            // they keep could be outranked by that many matches they don't, and never be seen.
            var onlyKept = narrowing.map { " AND s.file IN (\($0.sql))" } ?? ""
            var values: [SQLValue] = [.text(patterns.joined(separator: " OR "))] + (narrowing?.values ?? [])
            if let having {
                onlyKept += " AND s.file IN (SELECT value FROM json_each(?))"
                values.append(.text("[" + having.map(String.init).joined(separator: ",") + "]"))
            }
            try store.db.query("""
                SELECT s.file, s.id, snippet(fts, 1, '«', '»', '…', 12), fts.original FROM fts
                JOIN segments s ON s.id = fts.rowid
                WHERE fts MATCH ?\(onlyKept) ORDER BY bm25(fts, 3.0, 1.0) LIMIT 1000
                """, values) { row in
                let file = row.int(0)
                guard words.count < 100, allowed(file), seen.insert(file).inserted else { return }
                // Text that normalizing changed is quoted as it's written (with its hamza, harakat, joiners).
                let snippet = row.text(3).flatMap { SearchText.snippet($0, terms: terms) } ?? row.text(2)
                words.append((file, row.int(1), snippet))
            }
            if !words.isEmpty {
                let files = words.map { String($0.file) }.joined(separator: ",")
                for pattern in patterns {
                    try store.db.query("""
                        SELECT DISTINCT s.file FROM fts JOIN segments s ON s.id = fts.rowid
                        WHERE fts MATCH ? AND s.file IN (\(files))
                        """, [.text(pattern)]) { coverage[$0.int(0), default: 0] += 1 / Double(patterns.count) }
                }
            }
        }

        // A file qualifies by standing out in meaning, or by containing at least half of the query's words.
        // Score: meaning z + a bonus that grows with word coverage, + 1 for the kind the query asks for.
        // One common word can't beat a strong meaning match; all the words of an exact lookup usually do.
        // (This beat reciprocal-rank fusion on both evals, 2026-10-07: R@1 0.88 vs 0.73 synthetic, 0.86 vs 0.82 real.)
        let (meaningWeight, wordsWeight) = Self.weights(lookup: Self.isLookup(terms) || identifier != nil,
                                                        wordWeight: wordWeight)
        let hinted = Self.kindHints(text)
        var candidates = Set(best.filter { $0.value.z >= zGate }.keys)
        for (file, share) in coverage where share >= 0.5 { candidates.insert(file) }
        var scored: [Int64: Double] = [:]
        for file in candidates {
            var score = meaningWeight * max(best[file]?.z ?? 0, 0) + wordsWeight * pow(coverage[file] ?? 0, 1.5)
            if let kind = fileKind[file], hinted.contains(kind) { score += 1 }
            scored[file] = score
        }

        let wordRank = Dictionary(words.enumerated().map { ($0.element.file, ($0.offset + 1, $0.element)) },
                                  uniquingKeysWith: { first, _ in first })
        var hits: [SearchHit] = []
        for (file, score) in scored.sorted(by: { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) })
            .prefix(limit) {
            let rank = hits.count
            let semantic = best[file]
            var keyword = wordRank[file]
            // An AI app's: the words quoted for the files shown alone (`wordsInSight` matches every file it sees).
            if inSight, let match = keyword, match.1.snippet == nil {
                let quoted = try snippet(ofSegment: match.1.segment, patterns, terms: terms)
                keyword = (match.0, (match.1.file, match.1.segment, quoted))
            }
            // Point at the best meaning segment if it stands out; else at the segment the words matched.
            let useMeaning = semantic.map { $0.z >= zGate || keyword == nil } ?? false
            guard var segmentID = useMeaning ? semantic.map({ rowSegment[$0.row] }) : keyword?.1.segment else { continue }
            var focus: Double?
            if isCode {
                // Where a name is defined is looked for in the first 10 results only: a name used all over a big repo
                // (ggml_tensor) is in hundreds of stretches of every file that has it (2026-10-09, llama.cpp and two
                // more repos: 560 → 100 ms a search; the others take 10–50 ms).
                (segmentID, focus) = try codePlace(file: file, segment: segmentID,
                                                   identifier: rank < 10 ? identifier : nil, query: text, terms: terms,
                                                   wordsHere: keyword?.1.segment == segmentID || identifier != nil)
            }
            let row = try fileRow(file)
            var segment = SegmentKind.name, loc: Double?, locEnd: Double?, storedExcerpt: String?
            try store.db.query("SELECT kind, loc, loc_end, excerpt FROM segments WHERE id = ?", [.int(segmentID)]) {
                segment = SegmentKind(rawValue: $0.text(0) ?? "") ?? .name
                loc = $0.isNull(1) ? nil : $0.double(1)
                locEnd = $0.isNull(2) ? nil : $0.double(2)
                storedExcerpt = $0.text(3)
            }
            // Photos' facts keep the title and the date where other segments keep an excerpt and a place.
            if segment == .photosInfo { (loc, locEnd, storedExcerpt) = (nil, nil, nil) }
            // Quote the matched words only when they come from the segment we point at, so a PDF hit on page 5
            // never shows page 2's words. A segment with no place and no text of its own (a screenshot's image
            // vector) can borrow them from its file's OCR text, which describes the same picture.
            var snippet = keyword.flatMap { $0.1.segment == segmentID ? $0.1.snippet : nil }
                .flatMap { $0.contains("«") ? excerpt($0, limit: 400) : nil }
            if snippet == nil, storedExcerpt == nil, loc == nil, let match = keyword?.1,
               let text = match.snippet, text.contains("«") {
                var matchedKind: String?
                try store.db.query("SELECT kind FROM segments WHERE id = ?", [.int(match.segment)]) {
                    matchedKind = $0.text(0)
                }
                if matchedKind != SegmentKind.name.rawValue { snippet = excerpt(text, limit: 400) }
            }
            // A recording's moments: what stands out in it, and what's said in it with the query's words, looked for in
            // it whether or not it's among keyword search's first files (`words`), as its preview looks (`moments`).
            let said = Self.recordings.contains(row.kind) ? try saidWords(inFile: file, patterns) : [:]
            hits.append(SearchHit(path: row.path, kind: row.kind, score: score, z: semantic?.z,
                                  cosine: semantic?.cosine, keywordRank: keyword?.0, segment: segment,
                                  segmentID: segmentID, loc: loc, locEnd: locEnd, excerpt: snippet ?? storedExcerpt,
                                  modified: row.modified, size: row.size, info: row.info, focus: focus,
                                  photos: try photosHit(file: file, path: row.path, segment: segmentID, kind: segment),
                                  momentCount: try moments(ofFile: file, standouts[file] ?? [], said: said,
                                                           weights: (meaningWeight, wordsWeight)).count,
                                  pictures: try pictures(file: file, kind: row.kind),
                                  faces: try faceMatches(ofFile: file, path: row.path, filter: filter)))
        }
        return hits
    }

    /// The files that have every one of a query's required words or phrases (`RequiredWords`), of those the filter
    /// keeps (`narrowing`, its files `kept`). A file has a term when its words have it, as keyword search finds a word
    /// (its stem, and a word in no file as the start of longer ones, `wordPatterns`; a phrase as its words in a row;
    /// `typing`, the term still being typed at the end of the query, as a start too, as `prefixLast` makes the query's
    /// last word), every file that does (`segmentsHolding`), or when its best segment for the term embedded alone
    /// (`vectors`, by term) stands out as a meaning match does (`meaning`, at least `zGate`, on the scale `setsScale`
    /// says, `rowsSettingScale`). Only the files `exclusions` keeps count for a term's prefix matching, as for the
    /// query's words: a file an AI app may not see bears on nothing.
    private func filesHaving(_ terms: [String], typing: String?, vectors: [String: [Float]], zGate: Double,
                             setsScale: [Bool], narrowing: (sql: String, values: [SQLValue])?, kept: Set<Int64>?,
                             exclusions: (sql: String, values: [SQLValue])?) throws -> Set<Int64> {
        var having: Set<Int64>?
        for term in terms {
            var files = Set<Int64>()
            let words = RequiredWords.words(of: term)
            if !words.isEmpty {
                let pattern = try wordPatterns([words], prefixLast: term == typing, within: exclusions)[0]
                files.formUnion(try segmentsHolding([pattern], within: narrowing)[0].map(\.file))
            }
            if let vector = vectors[term], vector.count == Vectors.dimension, !rowFile.isEmpty {
                let meaning = Self.meaning(score(vector), rowModality, setsScale: setsScale)
                for row in meaning.indices where meaning[row] >= zGate && kept?.contains(rowFile[row]) != false {
                    files.insert(rowFile[row])
                }
            }
            having = having.map { $0.intersection(files) } ?? files
            if having?.isEmpty == true { break }
        }
        return having ?? []
    }

    /// What a filter keeps, with no words: the newest files it keeps (of `kinds`), by their date (`FileDate`: when
    /// Photos or the camera says it was taken, else when the file was modified); an empty filter keeps every file
    /// (`digup mcp`'s kind alone). Each points at its Photos facts, else at its name.
    public func browse(_ filter: SearchFilter, kinds: Set<FileKind>?, limit: Int) throws -> [SearchHit] {
        let kept = filter.query
        let conditions = [kept.map { "f.id IN (\($0.sql))" }, kinds.map { "f.kind IN (\(IndexStore.sqlList($0)))" }]
            .compactMap { $0 }
        var files: [Int64] = []
        try store.db.query("""
            SELECT f.id FROM files f
            \(conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND "))
            ORDER BY \(FileDate.sql(of: "f")) DESC, f.id DESC LIMIT ?
            """, (kept?.values ?? []) + [.int(Int64(limit))]) { files.append($0.int(0)) }
        return try files.map { file in
            let row = try fileRow(file)
            var segment = (id: Int64(0), kind: SegmentKind.name)
            try store.db.query("""
                SELECT id, kind FROM segments WHERE file = ? AND kind IN \(IndexStore.crawlKinds)
                ORDER BY kind = '\(SegmentKind.name.rawValue)' LIMIT 1
                """, [.int(file)]) { segment = ($0.int(0), SegmentKind(rawValue: $0.text(1) ?? "") ?? .name) }
            return SearchHit(path: row.path, kind: row.kind, score: 0, z: nil, cosine: nil, keywordRank: nil,
                             segment: segment.kind, segmentID: segment.id, loc: nil, locEnd: nil, excerpt: nil,
                             modified: row.modified, size: row.size, info: row.info,
                             photos: try photosHit(file: file, path: row.path, segment: segment.id, kind: segment.kind),
                             pictures: try pictures(file: file, kind: row.kind),
                             faces: try faceMatches(ofFile: file, path: row.path, filter: filter))
        }
    }

    /// What the detector said of a picture's or a video's pictures; nil for any other file.
    private func pictures(file: Int64, kind: FileKind) throws -> SensitivePictures? {
        [.image, .screenshot, .video].contains(kind) ? try store.sensitivePictures(ofFile: file) : nil
    }

    /// A file's row, as a hit shows it.
    private func fileRow(_ file: Int64) throws
        -> (path: String, kind: FileKind, modified: Double, size: Int64, info: [String: String]) {
        var row = (path: "", kind: FileKind.doc, modified: 0.0, size: Int64(0), info: [String: String]())
        try store.db.query("SELECT path, kind, mtime, size, info FROM files WHERE id = ?", [.int(file)]) {
            row.path = $0.text(0) ?? ""
            row.kind = FileKind(rawValue: $0.text(1) ?? "") ?? .doc
            row.modified = $0.double(2)
            row.size = $0.int(3)
            if let json = $0.text(4)?.data(using: .utf8) {
                row.info = (try? JSONSerialization.jsonObject(with: json) as? [String: String]) ?? [:]
            }
        }
        return row
    }

    /// A Photos library's file: the asset it shows, its title and date in Photos (its `photosInfo` segment), what was
    /// read of it (`photos_assets`), and for a video in iCloud the still the hit is on. Nil for any other file.
    private func photosHit(file: Int64, path: String, segment: Int64, kind: SegmentKind) throws -> PhotosHit? {
        guard let asset = PhotosLibrary.asset(ofFile: path) else { return nil }
        var title = "", date: Double?, reading: PhotosLibrary.Reading?
        try store.db.query("SELECT excerpt, loc FROM segments WHERE file = ? AND kind = ? LIMIT 1",
                           [.int(file), .text(SegmentKind.photosInfo.rawValue)]) {
            title = $0.text(0) ?? ""
            date = $0.isNull(1) ? nil : $0.double(1)
        }
        try store.db.query("SELECT reading FROM photos_assets WHERE file = ?", [.int(file)]) {
            reading = PhotosLibrary.Reading(rawValue: $0.text(0) ?? "")
        }
        var still: String?
        if reading?.isStandIn == true { still = path }
        if reading == .stills, kind == .frame {
            // The indexer writes a stills video's frames in its filmstrip's order (`Indexer.stills`), so a frame's place
            // among the file's frames is its still's.
            var place = 0
            try store.db.query("SELECT COUNT(*) FROM segments WHERE file = ? AND kind = ? AND id < ?",
                               [.int(file), .text(SegmentKind.frame.rawValue), .int(segment)]) { place = Int($0.int(0)) }
            let stills = PhotosLibrary.filmstrip(startingAt: path)
            if stills.indices.contains(place) { still = stills[place] }
        }
        return PhotosHit(library: asset.library, uuid: asset.uuid, title: title, date: date, reading: reading,
                         still: still)
    }

    /// The faces of a picture outside Photos that the filter's people were taken for (`SearchFilter.people`, at
    /// `Faces.threshold` or because you said so, by `face_matches` or the filter's own `faceMatches`): each person's
    /// likeliest (one you said is them first), likeliest first. None for a library's file, or without people to filter
    /// by.
    private func faceMatches(ofFile file: Int64, path: String, filter: SearchFilter) throws -> [FaceMatch] {
        let people = filter.people.reduce(into: Set<Int64>()) { $0.formUnion($1) }
        guard !people.isEmpty, PhotosLibrary.library(containing: path) == nil else { return [] }
        var best: [Int64: (match: FaceMatcher.Match, box: Faces.Box)] = [:]
        func rank(_ match: FaceMatcher.Match) -> (Int, Double) { (match.confirmed ? 1 : 0, match.similarity) }
        try store.db.query("""
            SELECT f.id, f.x, f.y, f.width, f.height, m.person, m.similarity, m.confirmed FROM faces f
            JOIN segments s ON s.id = f.segment LEFT JOIN face_matches m ON m.face = f.id
            WHERE s.file = ? AND f.person IS NULL
            """, [.int(file)]) { row in
            let match: FaceMatcher.Match? = if let given = filter.faceMatches { given[row.int(0)] }
                else if row.isNull(5) { nil }
                else { FaceMatcher.Match(person: row.int(5), similarity: row.double(6), confirmed: row.int(7) == 1) }
            guard let match, people.contains(match.person), match.similarity >= Faces.threshold || match.confirmed,
                  best[match.person].map({ rank(match) > rank($0.match) }) ?? true,
                  let box = Faces.Box(x: row.double(1), y: row.double(2), width: row.double(3), height: row.double(4))
            else { return }
            best[match.person] = (match, box)
        }
        guard !best.isEmpty else { return [] }
        var names: [Int64: String] = [:]
        let ids = best.keys.map(String.init).joined(separator: ",")
        try store.db.query("SELECT id, name FROM photos_people WHERE id IN (\(ids))") { names[$0.int(0)] = $0.text(1) }
        return best.compactMap { person, face in
            names[person].map {
                FaceMatch(name: $0, person: person, box: face.box, similarity: face.match.similarity,
                          confirmed: face.match.confirmed)
            }
        }.sorted { $0.similarity > $1.similarity }
    }

    // MARK: Moments

    /// The files read as recordings, a frame every few seconds, a window of sound and a stretch of speech at a time: the
    /// ones with moments.
    private static let recordings: Set<FileKind> = [.video, .audio]

    /// Every moment of the recording at `path` that matches the query (its words, `text`, and its vector), best first:
    /// its frames (or Photos' stills of it), windows of sound and stretches of speech that stand out on the query's scale
    /// as `search` puts it (`meaning`, at least `zGate`), and its stretches of speech that hold at least half of the
    /// query's words, as a file qualifies by them (`saidWords`). Each is scored as `search` scores a file, and
    /// neighbours of the same kind are merged (`merged`). A search's hits count theirs the same way (`momentCount`).
    /// None for a file that isn't a video or audio; without a vector, only what's said can match.
    public func moments(of path: String, text: String, queryVector: [Float]?, zGate: Double = 2.0) throws -> [Moment] {
        var file: (id: Int64, kind: FileKind?)?
        try store.db.query("SELECT id, kind FROM files WHERE path = ?", [.text(path)]) {
            file = ($0.int(0), FileKind(rawValue: $0.text(1) ?? ""))
        }
        guard let file, let kind = file.kind, Self.recordings.contains(kind) else { return [] }
        var standouts: [(segment: Int64, z: Double)] = []
        if let query = queryVector, query.count == Vectors.dimension {
            if !vectorsLoaded { try reload() }
            // The app's preview: nothing is left out of its sight.
            let setsScale = try rowsSettingScale(seeing: SearchFilter())
            let meaning = Self.meaning(score(query), rowModality, setsScale: setsScale)
            standouts = rowFile.indices.filter { rowFile[$0] == file.id && meaning[$0] >= zGate }
                .map { (segment: rowSegment[$0], z: meaning[$0]) }
        }
        let terms = Self.terms(text)
        // The app's preview: nothing is left out of its sight.
        let said = try saidWords(inFile: file.id, wordPatterns(terms, prefixLast: false, within: nil))
        return try moments(ofFile: file.id, standouts, said: said,
                           weights: Self.weights(lookup: Self.isLookup(terms), wordWeight: Self.wordWeight))
    }

    /// A recording's stretches of speech that hold at least half of the query's words (`patterns`), as a file
    /// qualifies by them (`search`), with the share of them each holds.
    private func saidWords(inFile file: Int64, _ patterns: [String]) throws -> [Int64: Double] {
        var shares: [Int64: Double] = [:]
        for pattern in patterns {
            try store.db.query("""
                SELECT s.id FROM fts JOIN segments s ON s.id = fts.rowid
                WHERE fts MATCH ? AND s.file = ? AND s.kind = '\(SegmentKind.speech.rawValue)'
                """, [.text(pattern), .int(file)]) { shares[$0.int(0), default: 0] += 1 / Double(patterns.count) }
        }
        return shares.filter { $0.value >= 0.5 }
    }

    /// A recording's moments, from its segments that stand out (with how far), its stretches of speech that hold the
    /// query's words (with their share of them), and where the index has them. Each is scored as `search` scores a file,
    /// its meaning and its words weighed by `weights`.
    private func moments(ofFile file: Int64, _ standouts: [(segment: Int64, z: Double)], said: [Int64: Double],
                         weights: (meaning: Double, words: Double)) throws -> [Moment] {
        guard !standouts.isEmpty || !said.isEmpty else { return [] }
        let z = Dictionary(uniqueKeysWithValues: standouts.map { ($0.segment, $0.z) })
        let ids = Set(z.keys).union(said.keys).map(String.init).joined(separator: ",")
        var placed: [(segment: Int64, kind: Moment.Kind, start: Double?, end: Double?, words: String?)] = []
        try store.db.query("""
            SELECT s.id, s.kind, s.loc, s.loc_end, coalesce(fts.original, fts.body) FROM segments s
            LEFT JOIN fts ON fts.rowid = s.id WHERE s.id IN (\(ids))
            """) { row in
            guard let kind = SegmentKind(rawValue: row.text(1) ?? "").flatMap(Moment.Kind.init) else { return }
            placed.append((row.int(0), kind, row.isNull(2) ? nil : row.double(2), row.isNull(3) ? nil : row.double(3),
                           kind == .said ? row.text(4) : nil))
        }
        // A frame with no time is one of Photos' stills of a video in iCloud: the indexer writes them in the
        // filmstrip's order (`Indexer.stills`), so its place among the file's frames is its place in the filmstrip.
        var filmstrip: [Int64: Int] = [:]
        if placed.contains(where: { $0.kind == .seen && $0.start == nil }) {
            try store.db.query("SELECT id FROM segments WHERE file = ? AND kind = ? ORDER BY id",
                               [.int(file), .text(SegmentKind.frame.rawValue)]) { filmstrip[$0.int(0)] = filmstrip.count }
        }
        return Self.merged(placed.map {
            MomentPiece(segment: $0.segment, kind: $0.kind, start: $0.start, end: $0.end,
                        still: $0.start == nil ? filmstrip[$0.segment] : nil, words: $0.words,
                        score: weights.meaning * max(z[$0.segment] ?? 0, 0)
                            + weights.words * pow(said[$0.segment] ?? 0, 1.5))
        })
    }

    /// A segment of a recording that matches a query, and where it is: what a moment is made of (`merged`).
    private struct MomentPiece {
        let segment: Int64
        let kind: Moment.Kind
        /// Seconds into the recording; nil for a still.
        let start: Double?
        let end: Double?
        /// A still's place in its filmstrip.
        let still: Int?
        /// What's said in a stretch of speech.
        let words: String?
        let score: Double
    }

    /// Moments from pieces, best first. Timed frames and windows of sound merge while each starts where the moment so
    /// far of its kind ends, or sooner: a video's kept frame stands for the stretch until the next one
    /// (`VideoExtractor.keyframes`), so two frames that match one after the other touch, and windows of sound overlap
    /// (30 s long, 25 s apart); a frame or window between them that doesn't match leaves a gap, and two moments. A piece
    /// spans at least its own stretch: to its end as the index has it, else a frame step or a sound window on from its
    /// start. A stretch of speech is a moment of its own, with its words: stretches end where speech pauses or runs long
    /// (`Speech.stretches(of:)`), so none overlaps the next. A still is one too: stills carry no time, so none is known
    /// to be next to another.
    private static func merged(_ pieces: [MomentPiece]) -> [Moment] {
        let defaults = IndexOptions()
        func moment(_ best: MomentPiece, from start: Double?, to end: Double?) -> Moment {
            Moment(kind: best.kind, start: start, end: end, still: best.still, score: best.score,
                   segmentID: best.segment, words: best.words)
        }
        let (said, others) = (pieces.filter { $0.kind == .said }, pieces.filter { $0.kind != .said })
        var moments = said.map { moment($0, from: $0.start, to: $0.end) }
        for kind in [Moment.Kind.seen, .heard] {
            let step = kind == .seen ? defaults.frameInterval : defaults.audioWindow
            let timed = others.compactMap { piece in piece.start.map { (piece: piece, start: $0) } }
                .filter { $0.piece.kind == kind }
                .sorted { $0.start < $1.start }
            var open: (start: Double, end: Double, best: MomentPiece)?
            for (piece, start) in timed {
                let end = max(piece.end ?? start + step, start)
                if let current = open, start <= current.end {
                    open = (current.start, max(current.end, end), piece.score > current.best.score ? piece : current.best)
                } else {
                    if let done = open { moments.append(moment(done.best, from: done.start, to: done.end)) }
                    open = (start, end, piece)
                }
            }
            if let done = open { moments.append(moment(done.best, from: done.start, to: done.end)) }
        }
        moments += others.filter { $0.start == nil }.map { moment($0, from: nil, to: nil) }
        return moments.sorted { first, second in
            first.score != second.score ? first.score > second.score
                : (first.start ?? Double(first.still ?? 0)) < (second.start ?? Double(second.still ?? 0))
        }
    }

    /// Code: the stretch to point at, and the line in it to open at. A name looked up points at the stretch that
    /// defines it, when one does (not the ones that call it). Otherwise the line is the first with the query's words,
    /// when they matched in this stretch; a match by meaning alone opens at the stretch's first line.
    private func codePlace(file: Int64, segment: Int64, identifier: [String]?, query: String, terms: [String],
                           wordsHere: Bool) throws -> (Int64, Double?) {
        let name = query.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "()", with: "")
        if let identifier {
            var best: (segment: Int64, line: Int, strength: Int)?
            try store.db.query("""
                SELECT s.id, s.loc, coalesce(fts.original, fts.body) FROM fts JOIN segments s ON s.id = fts.rowid
                WHERE fts MATCH ? AND s.file = ? ORDER BY s.loc LIMIT 300
                """, [.text(CodeLookup.phrase(identifier)), .int(file)]) { row in
                guard best?.strength ?? 0 < 2, let text = row.text(2),
                      let found = CodeLookup.definition(of: name, in: text, first: Int(row.double(1))) else { return }
                if found.strength > (best?.strength ?? 0) { best = (row.int(0), found.line, found.strength) }
            }
            if let best { return (best.segment, Double(best.line)) }
        }
        guard wordsHere || identifier != nil, let text = try text(ofSegment: segment) else { return (segment, nil) }
        var first = 1
        try store.db.query("SELECT loc FROM segments WHERE id = ?", [.int(segment)]) { first = Int($0.double(0)) }
        let words = identifier == nil ? terms : [name.lowercased()]
        return (segment, CodeLookup.firstLine(with: words, in: text, first: first).map(Double.init))
    }

    /// Codes and IDs ("K7Q2LM", "TRX50") and long numbers ("4815162342": an order, a phone number) mean nothing to an
    /// embedding but everything to keyword search: a query made of them weighs words double and meaning half. Numbers
    /// count since 2026-10-09, when text of digits lost its vectors (`SearchText.hasWords`): a number in a data dump fell
    /// below unrelated meaning matches.
    static func isLookup(_ terms: [String]) -> Bool {
        !terms.isEmpty && terms.allSatisfy {
            $0.contains(where: \.isNumber) && ($0.contains(where: \.isLetter) || $0.count >= 4)
        }
    }

    /// How much a match's meaning and the query's words in it count (`search`, a recording's moments): a lookup
    /// (`isLookup`, or a name from code) weighs words double and meaning half.
    static func weights(lookup: Bool, wordWeight: Double) -> (meaning: Double, words: Double) {
        lookup ? (0.5, wordWeight * 2) : (1, wordWeight)
    }

    /// How many of `hits` (best first) are strong: scoring at least `ratio` × the top hit. The rest pass the gates but
    /// trail far behind, and the app folds them under "weaker matches". On both evals (2026-10-07), 0.5 cut the list
    /// from 26.2 to 5.7 results per query and never folded an expected answer.
    public static func strongCount(_ hits: [SearchHit], ratio: Double = 0.5) -> Int {
        guard let top = hits.first?.score, top > 0 else { return hits.count }
        return hits.prefix { $0.score >= top * ratio }.count
    }

    /// Cosine similarity of `query` with every stored vector (all are L2-normalized): a matrix-vector product, done a
    /// block of rows at a time, each block turned into float32 first.
    private func score(_ query: [Float]) -> [Float] {
        let rows = rowFile.count
        var scores = [Float](repeating: 0, count: rows)
        guard let matrix, rows > 0 else { return scores }
        query.withUnsafeBufferPointer { query in
            scores.withUnsafeMutableBufferPointer { scores in
                var row = 0
                while row < rows {
                    let count = min(VectorStorage.blockRows, rows - row)
                    Vectors.floats(fromHalf: matrix.halves + row * Vectors.dimension, count: count * Vectors.dimension,
                                   to: matrix.block)
                    // (count × 768) · (768 × 1)
                    Vectors.scores(of: matrix.block, count: count, query: query.baseAddress!,
                                   into: scores.baseAddress! + row)
                    row += count
                }
            }
        }
        return scores
    }

    /// This query's meaning scores: each vector's cosine similarity minus the average of its modality (text, image and
    /// audio vectors can sit at slightly different levels for the same query), in standard deviations of all of them
    /// together. Within a modality that's the model's own order. Scaling each modality by its own deviation instead
    /// inflated the narrow ones and buried PDF pages under pictures (2026-10-08, on the three evals: 91 → 94 of 105
    /// queries with the right answer first).
    ///
    /// The scale (the averages and the deviation) comes from the vectors in `setsScale` (all by default): `search` leaves
    /// out the later pages of long files, which are scored on it but don't move it. A book's hundreds of pages pulled the
    /// text average down for every query, and documents rose over screenshots everywhere (2026-10-09, the testbed's long
    /// files finished: real eval 24 → 22 of 26 first; 24 with the scale kept). What the caller may not see is left
    /// out of it too (`rowsSettingScale`).
    static func meaning(_ scores: [Float], _ modality: [Modality], setsScale: [Bool]? = nil) -> [Double] {
        let means = modalityMeans(scores, modality, setsScale: setsScale)
        let centered = zip(scores, modality).map { Double($0) - means[$1, default: 0] }
        var count = 0.0, sum = 0.0
        for row in centered.indices where setsScale?[row] ?? true {
            count += 1
            sum += centered[row]
        }
        let mean = sum / max(count, 1)
        var squares = 0.0
        for row in centered.indices where setsScale?[row] ?? true {
            squares += (centered[row] - mean) * (centered[row] - mean)
        }
        let deviation = max((squares / max(count, 1)).squareRoot(), 0.02)
        return centered.map { ($0 - mean) / deviation }
    }

    /// The vectors that set a query's scale (`meaning`) for a caller who sees what `exclusions` keeps (an AI app's,
    /// `SearchFilter.exclusions`): of those that set it at all (`rowSetsScale`), only its files'. A file left out of an
    /// AI app's sight bears on nothing it searches (MCP-PLAN.md), and its vectors would move the averages and the
    /// deviation, and so whether a file the app sees stands out (`zGate`). With nothing left out (DigUp's own window),
    /// `rowSetsScale` as it is. Every meaning score of a search is put on the scale these give.
    private func rowsSettingScale(seeing exclusions: SearchFilter) throws -> [Bool] {
        guard let seen = exclusions.query else { return rowSetsScale }
        var files = Set<Int64>()
        try store.db.query(seen.sql, seen.values) { files.insert($0.int(0)) }
        return rowSetsScale.indices.map { rowSetsScale[$0] && files.contains(rowFile[$0]) }
    }

    /// The average score of each modality for this query. Small groups (< 20 vectors) take the average of all.
    static func modalityMeans(_ scores: [Float], _ modality: [Modality], setsScale: [Bool]? = nil) -> [Modality: Double] {
        var sum: [Modality: Double] = [:], count: [Modality: Int] = [:]
        for row in scores.indices where setsScale?[row] ?? true {
            sum[modality[row], default: 0] += Double(scores[row])
            count[modality[row], default: 0] += 1
        }
        let all = sum.values.reduce(0, +) / Double(max(count.values.reduce(0, +), 1))
        var out: [Modality: Double] = [:]
        for modality in Modality.allCases {
            if let n = count[modality], n >= 20 {
                out[modality] = sum[modality]! / Double(n)
            } else {
                out[modality] = all
            }
        }
        return out
    }

    /// The text of a page, a document's passage, a screenshot's OCR or a stretch of what's said, as it's written: the
    /// preview shows the part of a document that matched, and all of what's said there.
    public func text(ofSegment id: Int64) throws -> String? {
        var text: String?
        try store.db.query("SELECT coalesce(original, body) FROM fts WHERE rowid = ?", [.int(id)]) { text = $0.text(0) }
        return text
    }

    /// (The Windows and Linux app's previews keep the same list in shell/ui/results.js.)
    static let stopwords: Set<String> = [
        "a", "an", "the", "of", "in", "on", "at", "to", "for", "with", "and", "or", "my", "me", "that", "this",
        "these", "those", "from", "about", "where", "what", "which", "who", "when", "is", "was", "are", "were", "be",
        "it", "its", "some", "any", "find", "show", "file", "files", "photo", "photos", "picture", "image", "images",
        "screenshot", "screenshots", "video", "videos", "pdf", "document", "documents", "recording",
        // Bengali and Arabic (normalized, as `terms` sees them)
        "এবং", "ও", "এই", "সেই", "একটি", "আমার", "থেকে", "জন্য", "সাথে", "মধ্যে", "কোথায়", "কোন", "কী", "কি", "যে",
        "ছবি", "স্ক্রিনশট", "ভিডিও", "ফাইল", "পিডিএফ",
        "في", "من", "على", "الى", "عن", "مع", "هذا", "هذه", "ذلك", "التي", "الذي", "اين", "ما",
        "صورة", "صور", "لقطة", "شاشة", "فيديو", "ملف", "مستند",
    ]

    /// The content words of a query, normalized as keyword search keeps its text (`SearchText`). Kind words
    /// ("screenshot", "video") and stopwords are dropped: they describe what to look for, not what's in it. Words of
    /// two letters or more count; a Bengali letter with its vowel sign ("মা") is two.
    public static func terms(_ text: String) -> [String] {
        var seen = Set<String>()
        return SearchText.normalized(text).lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.unicodeScalars.count >= 2 && !stopwords.contains($0) && seen.insert($0).inserted }
    }

    /// FTS5 patterns for the query's words: quoted, and as prefixes for the last word while it's being typed and for
    /// words of languages that attach endings (`SearchText.inflects`). `wordPatterns` makes a word that's in no file a
    /// prefix too.
    static func patterns(_ terms: [String], prefixLast: Bool) -> [String] {
        terms.enumerated().map { index, term in
            let prefix = (prefixLast && index == terms.count - 1) || SearchText.inflects(term)
            return "\"\(term)\"" + (prefix ? "*" : "")
        }
    }

    /// `patterns`, with a word that's in no file as typed matched as the start of longer words, as the last word is
    /// while it's being typed: "grok" finds "Grok4" and "Grokipedia" (stemming only covers endings, as in "grokking").
    /// Otherwise a file the panel showed while you typed dropped out once you stopped. A word that is in the index as
    /// typed stays whole, so "cat" doesn't bring in "category"; so does a word of two letters, the start of too many
    /// words to stand for one. Only the files `within` keeps count (an AI app's, `SearchFilter.exclusions`; nil, every
    /// file): one left out having the word must not make it stay whole, nor show that it's there.
    private func wordPatterns(_ terms: [String], prefixLast: Bool,
                              within kept: (sql: String, values: [SQLValue])?) throws -> [String] {
        var patterns = Self.patterns(terms, prefixLast: prefixLast)
        for index in terms.indices where terms[index].count >= 3 && !patterns[index].hasSuffix("*") {
            if try !isIndexed(patterns[index], within: kept) { patterns[index] += "*" }
        }
        return patterns
    }

    /// Whether keyword search finds `pattern` in any file, or in any of the files `within` keeps.
    private func isIndexed(_ pattern: String, within kept: (sql: String, values: [SQLValue])?) throws -> Bool {
        var found = false
        guard let kept else {
            try store.db.query("SELECT 1 FROM fts WHERE fts MATCH ? LIMIT 1", [.text(pattern)]) { _ in found = true }
            return found
        }
        try store.db.query("""
            SELECT 1 FROM fts JOIN segments s ON s.id = fts.rowid WHERE fts MATCH ? AND s.file IN (\(kept.sql)) LIMIT 1
            """, [.text(pattern)] + kept.values) { _ in found = true }
        return found
    }

    /// Keyword matches for a caller who doesn't see every file (an AI app's, `SearchFilter.exclusions`), none of them
    /// decided by a file it may not see (MCP-PLAN.md): keyword search's own ranking (bm25) weighs a word by how many of
    /// all the index's segments have it, so it isn't used, and no match is left out by a cap. Every segment of the
    /// files `narrowing` keeps (and `allowed`) that holds one of `patterns` counts (`segmentsHolding`): each file at
    /// its segment that holds the most of them (of those that hold as many, the first), in order of how much of the
    /// query the file holds (`coverage`, as `search` has it), then of how much that segment does, then of id. Their
    /// words are quoted later, for the files shown (`snippet`).
    private func wordsInSight(_ patterns: [String], within narrowing: (sql: String, values: [SQLValue])?,
                              allowed: (Int64) -> Bool)
        throws -> (words: [(file: Int64, segment: Int64, snippet: String?)], coverage: [Int64: Double]) {
        var coverage: [Int64: Double] = [:]
        var held: [Int64: (file: Int64, patterns: Int)] = [:]   // by segment
        for found in try segmentsHolding(patterns, within: narrowing) {
            for file in Set(found.map(\.file)) where allowed(file) {
                coverage[file, default: 0] += 1 / Double(patterns.count)
            }
            for (file, segment) in found where allowed(file) {
                held[segment, default: (file, 0)].patterns += 1
            }
        }
        var best: [Int64: (segment: Int64, patterns: Int)] = [:]   // by file
        for (segment, match) in held {
            if let current = best[match.file], current.patterns > match.patterns
                || current.patterns == match.patterns && current.segment < segment { continue }
            best[match.file] = (segment, match.patterns)
        }
        let ordered = best.sorted { first, second in
            (coverage[first.key] ?? 0, first.value.patterns, second.key)
                > (coverage[second.key] ?? 0, second.value.patterns, first.key)
        }
        return (ordered.map { (file: $0.key, segment: $0.value.segment, snippet: nil) }, coverage)
    }

    /// The segments of the files `kept` keeps (nil: every file) that hold each of `patterns`: every one of them, in no
    /// order of keyword search's, so that nothing outside `kept` bears on which they are (`wordsInSight`).
    private func segmentsHolding(_ patterns: [String], within kept: (sql: String, values: [SQLValue])?) throws
        -> [[(file: Int64, segment: Int64)]] {
        try patterns.map { pattern in
            var found: [(file: Int64, segment: Int64)] = []
            try store.db.query("""
                SELECT s.file, s.id FROM fts JOIN segments s ON s.id = fts.rowid
                WHERE fts MATCH ?\(kept.map { " AND s.file IN (\($0.sql))" } ?? "")
                """, [.text(pattern)] + (kept?.values ?? [])) { found.append(($0.int(0), $0.int(1))) }
            return found
        }
    }

    /// A keyword match's words in its segment, quoted as `search` quotes them: marked, as they're written (FTS5's
    /// snippet, which looks at the segment alone).
    private func snippet(ofSegment segment: Int64, _ patterns: [String], terms: [String]) throws -> String? {
        var snippet: String?
        try store.db.query("""
            SELECT snippet(fts, 1, '«', '»', '…', 12), original FROM fts WHERE fts MATCH ? AND rowid = ?
            """, [.text(patterns.joined(separator: " OR ")), .int(segment)]) { row in
            // Text that normalizing changed is quoted as it's written (with its hamza, harakat, joiners).
            snippet = row.text(1).flatMap { SearchText.snippet($0, terms: terms) } ?? row.text(0)
        }
        return snippet
    }

    /// The query's words as an FTS5 OR-query.
    public static func ftsQuery(_ text: String, prefixLast: Bool = false) -> String? {
        let words = terms(text)
        guard !words.isEmpty else { return nil }
        return patterns(words, prefixLast: prefixLast).joined(separator: " OR ")
    }

    static let kindWords: [String: FileKind] = [
        "screenshot": .screenshot, "screenshots": .screenshot, "photo": .image, "photos": .image, "picture": .image,
        "pictures": .image, "image": .image, "images": .image, "pdf": .pdf, "pdfs": .pdf, "paper": .pdf,
        "papers": .pdf, "document": .doc, "documents": .doc, "note": .doc, "notes": .doc, "video": .video,
        "videos": .video, "clip": .video, "movie": .video, "audio": .audio, "song": .audio, "podcast": .audio,
        "voice": .audio, "sound": .audio,
        "স্ক্রিনশট": .screenshot, "ছবি": .image, "পিডিএফ": .pdf, "নোট": .doc, "ভিডিও": .video, "অডিও": .audio,
        "গান": .audio, "রেকর্ডিং": .audio,
        "لقطة": .screenshot, "صورة": .image, "صور": .image, "مستند": .doc, "ملاحظات": .doc, "فيديو": .video,
        "مقطع": .video, "صوت": .audio, "تسجيل": .audio, "اغنية": .audio,
    ]

    /// Kinds the query asks for ("…in a video", "screenshot of…", "ভিডিওতে"): a soft boost, not a filter. Bengali
    /// attaches case endings, so a Bengali kind word also counts at the start of a longer word.
    static func kindHints(_ text: String) -> Set<FileKind> {
        Set(SearchText.normalized(text).lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .compactMap { word in
                kindWords[word] ?? kindWords.first { key, _ in
                    SearchText.inflects(key) && key.unicodeScalars.count >= 3 && word.hasPrefix(key)
                }?.value
            })
    }
}
