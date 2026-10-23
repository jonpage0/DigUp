import Foundation

/// A search the user saved: its words, kind and filters, run again whenever it's opened (a smart folder: nothing about
/// its results is kept). One entry of `saved-searches.json` beside the index folder, which the app alone writes (its
/// search window's Saved menu, `SavedSearches`) and `digup mcp` reads (`search_files`' `saved`, `list_choices`).
///
/// The file's shape (approved 2026-10-22; `{ "sensitive": true }` with it, the same evening; `{ "length": … }` and
/// `{ "shape": … }` with the Length and Shape filters):
///
///     { "version": 1,
///       "searches": [ { "id": "<UUID>", "name": "Tati at the beach", "query": "beach", "kind": "images",
///                       "filters": [ { "person": { "name": "…", "photos": [ { "library": "…", "uuid": "…" } ] } },
///                                    { "album": { "title": "…", "folders": ["…"], "photos": [ … ] } },
///                                    { "photosFavorites": true }, { "digupFavorites": true }, { "from": "mine" },
///                                    { "area": { "south": 25.1, "west": -80.9, "north": 26.2, "east": -79.8 } },
///                                    { "sensitive": true }, { "length": { "atLeast": 15, "under": 60 } },
///                                    { "shape": "16:9" } ],
///                       "saved": "<ISO 8601>" } ] }
///
/// In the user's order, which the menu shows. A file that isn't exactly this shape (a newer version, damaged, a key
/// anywhere that the shape doesn't have, a filter with two keys or none, two From, two areas, two Sensitive, two
/// lengths or two shapes in one search, a length or a shape the filters don't have, a search without a name, an id
/// twice) isn't read (`searches(in:)` throws): the app leaves it as it is and never writes over it.
public struct SavedSearch: Equatable, Identifiable, Sendable {
    /// Made when it's saved; renaming or moving it keeps it.
    public var id: UUID
    /// What the Saved menu shows: never empty, and two may share one.
    public var name: String
    /// The words as typed: "" for filters alone, "code: …" for code, the required ones marked (`+beach`).
    public var query: String
    /// The window's kind button; nil for All.
    public var kind: ResultGroupKind?
    /// The tokens in the search field, in order (the map's area is the last of them there).
    public var filters: [Filter]
    public var saved: Date

    public init(id: UUID, name: String, query: String, kind: ResultGroupKind?, filters: [Filter], saved: Date) {
        (self.id, self.name, self.query, self.kind, self.filters, self.saved) = (id, name, query, kind, filters, saved)
    }

    /// One token of the search field.
    public enum Filter: Equatable, Sendable {
        case person(Person)
        case album(Album)
        case photosFavorites
        case digupFavorites
        case from(From)
        case area(Area)
        /// The Sensitive filter, at the position "Blur sensitive pictures" has when the search runs (as `from: "mine"`
        /// is the devices list as it is then, not a copy of it). `{ "sensitive": true }`, approved 2026-10-22.
        case sensitive
        /// The Length filter: `{ "length": { "atLeast": 15, "under": 60 } }`, either bound left out (approved
        /// 2026-10-22; read strictly: `SearchFilter.Length`'s `Codable`).
        case length(SearchFilter.Length)
        /// The Shape filter: `{ "shape": "portrait" }`, or an exact ratio, `{ "shape": "16:9" }` (approved 2026-10-22).
        case shape(SearchFilter.Shape)
    }

    /// A person by Photos' ids, one per library that has them (everyone of the name, as the People filter joins
    /// them), with the name they had when it was saved.
    public struct Person: Codable, Equatable, Sendable {
        public var name: String
        public var photos: [PhotosID]

        public init(name: String, photos: [PhotosID]) {
            (self.name, self.photos) = (name, photos)
        }
    }

    /// An album by Photos' ids (each library's album of that title in those folders), with its title and folders
    /// when it was saved.
    public struct Album: Codable, Equatable, Sendable {
        public var title: String
        public var folders: [String]
        public var photos: [PhotosID]

        public init(title: String, folders: [String], photos: [PhotosID]) {
            (self.title, self.folders, self.photos) = (title, folders, photos)
        }
    }

    /// The window's From. `mine` is "Shot on my devices" as the list is when the search runs (Settings → Photos → My
    /// devices), not a copy of it.
    public enum From: String, Codable, Sendable {
        case mine, saved, imported
    }

    /// The map's area, in degrees.
    public struct Area: Codable, Equatable, Sendable {
        public var south: Double
        public var west: Double
        public var north: Double
        public var east: Double

        public init(_ area: SearchFilter.Area) {
            (south, north) = (area.latitudes.lowerBound, area.latitudes.upperBound)
            (west, east) = (area.longitudes.lowerBound, area.longitudes.upperBound)
        }

        /// A box on the map: south to north, west to east, within the earth's degrees.
        public var isBox: Bool {
            -90 <= south && south <= north && north <= 90 && -180 <= west && west <= east && east <= 180
        }

        /// Only for a box (`isBox`, which reading the file checks).
        public var searchArea: SearchFilter.Area {
            SearchFilter.Area(latitudes: south...north, longitudes: west...east)
        }
    }

    /// What the file's shape asks of a search beyond its keys: a name, at most one From, one area, one Sensitive, one
    /// Length and one Shape, and an area that's a box.
    public var isWellFormed: Bool {
        var froms = 0, areas = 0, sensitives = 0, lengths = 0, shapes = 0
        for filter in filters {
            switch filter {
            case .from: froms += 1
            case .area(let area):
                guard area.isBox else { return false }
                areas += 1
            case .sensitive: sensitives += 1
            case .length: lengths += 1
            case .shape: shapes += 1
            default: break
            }
        }
        return !name.isEmpty && [froms, areas, sensitives, lengths, shapes].allSatisfy { $0 <= 1 }
    }
}

// MARK: The file

extension SavedSearch {
    public static let fileName = "saved-searches.json"

    /// Beside the index folder (`~/Library/Application Support/DigUp/saved-searches.json` for the default one).
    public static func url(beside indexDirectory: URL) -> URL {
        indexDirectory.deletingLastPathComponent().appendingPathComponent(fileName)
    }

    /// Why a file of saved searches isn't read, besides JSON that isn't their shape (`DecodingError`).
    public enum FileError: Error, Equatable {
        /// Another version than this DigUp's (1).
        case version(Int)
        /// A search without a name, with two From, two areas, two Sensitive, two lengths or two shapes, or an area that
        /// isn't a box; or an id twice.
        case notWellFormed
    }

    private struct Stored: Codable {
        var version: Int
        var searches: [SavedSearch]

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case version, searches
        }

        init(version: Int, searches: [SavedSearch]) {
            (self.version, self.searches) = (version, searches)
        }

        init(from decoder: any Decoder) throws {
            try onlyKeys(CodingKeys.self, in: decoder)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(Int.self, forKey: .version)
            searches = try container.decode([SavedSearch].self, forKey: .searches)
        }
    }

    private struct Version: Decodable {
        var version: Int
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// The searches in a file's bytes, in its order. Throws unless it's exactly the approved shape: `FileError` for
    /// another version or a search that isn't well formed, else what decoding said.
    public static func searches(in data: Data) throws -> [SavedSearch] {
        let version = try decoder.decode(Version.self, from: data).version
        guard version == 1 else { throw FileError.version(version) }
        let searches = try decoder.decode(Stored.self, from: data).searches
        guard searches.allSatisfy(\.isWellFormed), Set(searches.map(\.id)).count == searches.count else {
            throw FileError.notWellFormed
        }
        return searches
    }

    /// The file's bytes for these searches, in this order.
    public static func data(_ searches: [SavedSearch]) throws -> Data {
        try encoder.encode(Stored(version: 1, searches: searches))
    }
}

extension SavedSearch: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, name, query, kind, filters, saved
    }

    /// Every key is there, and no other: `kind` too, null for All.
    public init(from decoder: any Decoder) throws {
        try onlyKeys(CodingKeys.self, in: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        query = try container.decode(String.self, forKey: .query)
        kind = try container.decode(ResultGroupKind?.self, forKey: .kind)
        filters = try container.decode([Filter].self, forKey: .filters)
        saved = try container.decode(Date.self, forKey: .saved)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(query, forKey: .query)
        try container.encode(kind, forKey: .kind)   // null for All, not left out
        try container.encode(filters, forKey: .filters)
        try container.encode(saved, forKey: .saved)
    }
}

extension SavedSearch.Person {
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

extension SavedSearch.Album {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case title, folders, photos
    }

    public init(from decoder: any Decoder) throws {
        try onlyKeys(CodingKeys.self, in: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        folders = try container.decode([String].self, forKey: .folders)
        photos = try container.decode([PhotosID].self, forKey: .photos)
    }
}

extension SavedSearch.Area {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case south, west, north, east
    }

    public init(from decoder: any Decoder) throws {
        try onlyKeys(CodingKeys.self, in: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        south = try container.decode(Double.self, forKey: .south)
        west = try container.decode(Double.self, forKey: .west)
        north = try container.decode(Double.self, forKey: .north)
        east = try container.decode(Double.self, forKey: .east)
    }
}

/// A filter is an object with exactly one key, one of these nine; anything else isn't this shape.
extension SavedSearch.Filter: Codable {
    private enum Key: String, CodingKey, CaseIterable {
        case person, album, photosFavorites, digupFavorites, from, area, sensitive, length, shape
    }

    public init(from decoder: any Decoder) throws {
        let keys = try decoder.container(keyedBy: AnyKey.self).allKeys.map(\.stringValue)
        guard keys.count == 1, let key = Key(stringValue: keys[0]) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription:
                "a filter has one key of \(Key.allCases.map(\.rawValue)), not \(keys)"))
        }
        let container = try decoder.container(keyedBy: Key.self)
        switch key {
        case .person: self = .person(try container.decode(SavedSearch.Person.self, forKey: key))
        case .album: self = .album(try container.decode(SavedSearch.Album.self, forKey: key))
        case .photosFavorites, .digupFavorites, .sensitive:
            guard try container.decode(Bool.self, forKey: key) else {
                throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "is always true")
            }
            self = switch key {
            case .photosFavorites: .photosFavorites
            case .digupFavorites: .digupFavorites
            default: .sensitive
            }
        case .from: self = .from(try container.decode(SavedSearch.From.self, forKey: key))
        case .area: self = .area(try container.decode(SavedSearch.Area.self, forKey: key))
        case .length: self = .length(try container.decode(SearchFilter.Length.self, forKey: key))
        case .shape: self = .shape(try container.decode(SearchFilter.Shape.self, forKey: key))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        switch self {
        case .person(let person): try container.encode(person, forKey: .person)
        case .album(let album): try container.encode(album, forKey: .album)
        case .photosFavorites: try container.encode(true, forKey: .photosFavorites)
        case .digupFavorites: try container.encode(true, forKey: .digupFavorites)
        case .from(let from): try container.encode(from, forKey: .from)
        case .area(let area): try container.encode(area, forKey: .area)
        case .sensitive: try container.encode(true, forKey: .sensitive)
        case .length(let length): try container.encode(length, forKey: .length)
        case .shape(let shape): try container.encode(shape, forKey: .shape)
        }
    }
}

// MARK: Running one

extension SavedSearch.Person {
    /// The person as the indexed libraries have them now (`people`, `IndexStore.photosPeople`, in its order): every row
    /// with an indexed file and one of their Photos uuids, and the name the first of those has now (a rename in Photos
    /// follows). Nil for none: gone from Photos, or from what's searched, and then the search keeps nothing for them.
    public func found(in people: [IndexStore.PhotosPerson]) -> (name: String, ids: Set<Int64>)? {
        let uuids = Set(photos.map(\.uuid))
        let rows = people.filter { $0.files > 0 && uuids.contains($0.uuid) }
        return rows.first.map { ($0.name, Set(rows.map(\.id))) }
    }
}

extension SavedSearch.Album {
    /// The album as the indexed libraries have it now (`albums`, `IndexStore.photosAlbums`, in its order), found by
    /// Photos' uuid as a person is (`SavedSearch.Person.found(in:)`): a rename or a move to another folder follows.
    public func found(in albums: [IndexStore.PhotosAlbum]) -> (title: String, folders: [String], ids: Set<Int64>)? {
        let uuids = Set(photos.map(\.uuid))
        let rows = albums.filter { $0.files > 0 && uuids.contains($0.uuid) }
        return rows.first.map { ($0.title, $0.folders, Set(rows.map(\.id))) }
    }
}

extension SavedSearch {
    /// Its kinds of files; nil for All.
    public var kinds: Set<FileKind>? { kind?.kinds }

    /// It searches code (the Code kind, or "code:" typed, `CodeQuery`): the code index, where no filter applies.
    public var isCode: Bool { kind == .code || CodeQuery.text(of: query) != nil }

    /// What it keeps to when it runs now, narrowing `base`, as the search window keeps to the tokens opening it puts in
    /// the field (`SearchModel.searchFilter`): each of its people, every row of their Photos uuids among `people` (none
    /// there: nothing is kept, so the search never widens to everyone); any of its albums among `albums` (one not there
    /// adds nothing); Photos' favorites; From, "Shot on my devices" being `myDevices` now; the map's area; the
    /// Sensitive filter at the position blurring has now (`blurring`, Revealing while it's off); its length and shape;
    /// DigUp's favorites, the files `favorites` gives (asked for only when it has them).
    public func searchFilter(narrowing base: SearchFilter = SearchFilter(), people: [IndexStore.PhotosPerson],
                             albums: [IndexStore.PhotosAlbum], myDevices: [String], blurring: SensitivePosition,
                             favorites: () throws -> Set<String>) rethrows -> SearchFilter {
        var filter = base
        for element in filters {
            switch element {
            case .person(let person): filter.people.append(person.found(in: people)?.ids ?? [])
            case .album(let album): filter.albums = (filter.albums ?? []).union(album.found(in: albums)?.ids ?? [])
            case .photosFavorites: filter.favorites = true
            case .digupFavorites: filter.paths = try favorites()
            case .from(.mine): filter.shotOn = Set(myDevices)
            case .from(let origin): filter.origins = [origin.rawValue]
            case .area(let area): filter.area = area.searchArea
            case .sensitive: filter.sensitive = blurring.filterPosition
            case .length(let length): filter.length = length
            case .shape(let shape): filter.shape = shape
            }
        }
        return filter
    }

    /// What it uses that the user can keep from AI apps (Settings → AI apps, `AIAccess.allows`): Photos, for its
    /// people, albums, Photos' favorites and From; pictures rated sensitive, for the Sensitive filter; code, for a
    /// search of code. A code search's other filters count too, though none applies to it: its summary line names them.
    public var aiUses: Set<AIAccess.Use> {
        var uses: Set<AIAccess.Use> = isCode ? [.code] : []
        for element in filters {
            switch element {
            case .person, .album, .photosFavorites, .from: uses.insert(.photos)
            case .sensitive: uses.insert(.sensitive)
            case .digupFavorites, .area, .length, .shape: break
            }
        }
        return uses
    }

    /// Why an AI app may not run it, nor see it listed (`digup mcp`): something it uses that the user keeps from AI
    /// apps, or one of its people or albums it doesn't see.
    public enum Withheld: Equatable, Sendable {
        case use(AIAccess.Use)
        /// Gone from Photos, or only in pictures the app may not see (`people` and `albums` of `withheld(from:)`).
        case outOfSight
    }

    /// Why an AI app with `access` may not run it, nil when it may: it uses nothing `access` keeps from AI apps
    /// (`aiUses`), and each of its people and albums is among what the app sees (`people` and `albums`,
    /// `IndexStore.photosPeople(keptBy:)` and `photosAlbums(keptBy:)` for its sight). A saved search's name is made
    /// from its people and albums when it's saved ("beach · Tatiana Rotari"), so one it can't run answers as a name
    /// that's nowhere.
    public func withheld(from access: AIAccess, people: [IndexStore.PhotosPerson],
                         albums: [IndexStore.PhotosAlbum]) -> Withheld? {
        if let use = AIAccess.Use.allCases.first(where: { aiUses.contains($0) && !access.allows($0) }) {
            return .use(use)
        }
        let seen = filters.allSatisfy { element in
            switch element {
            case .person(let person): person.found(in: people) != nil
            case .album(let album): album.found(in: albums) != nil
            default: true
            }
        }
        return seen ? nil : .outOfSight
    }
}

// MARK: What it says

extension SavedSearch.From {
    /// Its item in From, and its token.
    public var title: String {
        switch self {
        case .mine: "Shot on my devices"
        case .saved: "Saved from other apps"
        case .imported: "Imported into Photos"
        }
    }
}

extension SavedSearch.Area {
    /// The map's area's token.
    public static let title = "In the map's area"
}

extension SavedSearch.Filter {
    /// What its token in the search field says ("Photos Favorites", "Shot on my devices", "Under 15 s"); a person or an
    /// album by the name it was saved with.
    public var title: String {
        switch self {
        case .person(let person): person.name
        case .album(let album): album.title
        case .photosFavorites: "Photos Favorites"
        case .digupFavorites: "Favorites"
        case .from(let from): from.title
        case .area: SavedSearch.Area.title
        case .sensitive: "Sensitive"
        case .length(let length): length.title
        case .shape(let shape): shape.title
        }
    }
}

extension SavedSearch {
    /// What a search keeps, in a line, as Save This Search… says it: its words as searched (the required ones marked),
    /// its kind ("All kinds" for none), and each filter's token, in order: "“+beach” · Images · Tatiana Rotari · In the
    /// map's area".
    public static func summary(query: String, kind: ResultGroupKind?, filters: [String]) -> String {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return ((words.isEmpty ? [] : ["“\(words)”"]) + [kind?.title ?? "All kinds"] + filters).joined(separator: " · ")
    }

    /// Its line (`summary(query:kind:filters:)`), its people and albums by the names `people` and `albums` give them
    /// now (a rename in Photos followed), else as they were saved.
    public func summary(people: [IndexStore.PhotosPerson], albums: [IndexStore.PhotosAlbum]) -> String {
        Self.summary(query: query, kind: kind, filters: filters.map { element in
            switch element {
            case .person(let person): person.found(in: people)?.name ?? person.name
            case .album(let album): album.found(in: albums)?.title ?? album.title
            default: element.title
            }
        })
    }
}
