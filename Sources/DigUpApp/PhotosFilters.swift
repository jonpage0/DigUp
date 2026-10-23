import DigUpKit
import SwiftUI

/// The people, albums and devices the indexed Photos libraries name, as the search window offers them to filter by.
/// Plain data, made on the engine's search queue (`Engine.photosChoices`), so none of it is the main actor's.
nonisolated struct PhotosChoices: Sendable, Equatable {
    var people: [Person] = []
    var albums: [Album] = []
    /// The devices that took the libraries' pictures (`IndexStore.photosCameras`), most files first.
    var cameras: [IndexStore.PhotosCamera] = []

    /// "Shot on my devices" with Settings → Photos → My devices' changes (`AppSettings.myDevicesAdded`,
    /// `myDevicesRemoved`), by the kit's rule (`IndexStore.PhotosCamera.mine`).
    func devices(added: [String], removed: [String]) -> [String] {
        IndexStore.PhotosCamera.mine(of: cameras, added: added, removed: removed)
    }

    /// The devices worth a switch in Settings: one whose camera saved something, or that took older pictures with
    /// nothing recorded (the two kinds "Shot on my devices" reads), and any the user changed, including an added one no
    /// indexed picture names now (so it can be taken off). A device that only took pictures saved from elsewhere or
    /// imported has nothing the filter would keep.
    func deviceChoices(added: [String], removed: [String]) -> [IndexStore.PhotosCamera] {
        let listed = cameras.filter {
            $0.fromCamera > 0 || $0.unknownOrigin > 0 || added.contains($0.model) || removed.contains($0.model)
        }
        let absent = added.filter { name in !cameras.contains { $0.model == name } }
        return listed + absent.map { IndexStore.PhotosCamera(model: $0, files: 0, fromCamera: 0, unknownOrigin: 0) }
    }

    /// One name: Photos can keep two people of one name (two libraries, or a name given twice), and a picture of
    /// either counts (`SearchFilter.people`).
    nonisolated struct Person: Sendable, Equatable, Identifiable {
        let name: String
        /// Each of them: their row in the index, and who they are in Photos (what a saved search keeps).
        let photos: [Int64: PhotosID]
        /// Indexed files showing them (one showing both of a name counts twice).
        let files: Int
        var id: String { name }
        var ids: Set<Int64> { Set(photos.keys) }
        /// The filter for them.
        var token: FilterToken { .person(name: name, ids: ids, photos: PhotosChoices.ordered(photos)) }
    }

    /// One album title in one folder: two libraries can each have it, and a file in either counts.
    nonisolated struct Album: Sendable, Equatable, Identifiable {
        let title: String
        /// The folders it's in, outermost first.
        let folders: [String]
        /// Each library's album of it: its row in the index, and Photos' id for it.
        let photos: [Int64: PhotosID]
        let files: Int
        var id: [String] { folders + [title] }
        var ids: Set<Int64> { Set(photos.keys) }
        var token: FilterToken {
            .album(title: title, folders: folders, ids: ids, photos: PhotosChoices.ordered(photos))
        }
    }

    init() {}

    /// Only people and albums with an indexed file: the others would filter to nothing.
    init(people: [IndexStore.PhotosPerson], albums: [IndexStore.PhotosAlbum], cameras: [IndexStore.PhotosCamera]) {
        self.cameras = cameras
        var byName: [String: (photos: [Int64: PhotosID], files: Int)] = [:]
        var names: [String] = []
        for person in people where person.files > 0 {
            if byName[person.name] == nil { names.append(person.name) }
            byName[person.name, default: ([:], 0)].photos[person.id] = PhotosID(library: person.library,
                                                                                uuid: person.uuid)
            byName[person.name, default: ([:], 0)].files += person.files
        }
        self.people = names.map { Person(name: $0, photos: byName[$0]!.photos, files: byName[$0]!.files) }
        var byPlace: [[String]: (photos: [Int64: PhotosID], files: Int)] = [:]
        var places: [[String]] = []
        for album in albums where album.files > 0 {
            let place = album.folders + [album.title]
            if byPlace[place] == nil { places.append(place) }
            byPlace[place, default: ([:], 0)].photos[album.id] = PhotosID(library: album.library, uuid: album.uuid)
            byPlace[place, default: ([:], 0)].files += album.files
        }
        self.albums = places.map {
            Album(title: $0.last!, folders: Array($0.dropLast()), photos: byPlace[$0]!.photos,
                  files: byPlace[$0]!.files)
        }
    }

    /// Photos' ids in the order of their rows, so a search saved twice is written the same.
    static func ordered(_ photos: [Int64: PhotosID]) -> [PhotosID] {
        photos.sorted { $0.key < $1.key }.map(\.value)
    }

    /// A saved search's person, as the indexed libraries have them now: every row of one of their Photos uuids (a
    /// rename in Photos follows, and the token shows the name it has now). Found nowhere (deleted in Photos, or the
    /// library isn't searched any more), the token keeps the saved name and keeps nothing (`FilterToken.isMissing`).
    /// The token keeps the saved ids, so saving it again keeps who it was.
    func token(for saved: SavedSearch.Person) -> FilterToken {
        let uuids = Set(saved.photos.map(\.uuid))
        var name: String?, ids = Set<Int64>()
        for person in people {
            let found = person.photos.filter { uuids.contains($0.value.uuid) }
            guard !found.isEmpty else { continue }
            name = name ?? person.name
            ids.formUnion(found.keys)
        }
        return .person(name: name ?? saved.name, ids: ids, photos: saved.photos)
    }

    /// A saved search's album, found by Photos' uuid as `token(for:)` finds a person (a rename or a move to another
    /// folder follows).
    func token(for saved: SavedSearch.Album) -> FilterToken {
        let uuids = Set(saved.photos.map(\.uuid))
        var place: (title: String, folders: [String])?, ids = Set<Int64>()
        for album in albums {
            let found = album.photos.filter { uuids.contains($0.value.uuid) }
            guard !found.isEmpty else { continue }
            place = place ?? (album.title, album.folders)
            ids.formUnion(found.keys)
        }
        return .album(title: place?.title ?? saved.title, folders: place?.folders ?? saved.folders, ids: ids,
                      photos: saved.photos)
    }

    /// Filters the words being typed could name: people and albums with a name or a word of it that starts with the
    /// query's last words (three, then two, then one), and Photos' favorites for "fav…" when a library is searched.
    /// At most four, none that's on already. Nothing once a space follows the words: they're meant as words then.
    func suggestions(for query: String, photos: Bool, except active: [FilterToken]) -> [FilterSuggestion] {
        guard let end = query.last, !end.isWhitespace else { return [] }
        let words = query.split(whereSeparator: \.isWhitespace)
        var found: [FilterSuggestion] = []
        func add(_ token: FilterToken, for tail: String, _ detail: String) {
            guard found.count < 4, !active.contains(where: { $0.id == token.id }),
                  !found.contains(where: { $0.token.id == token.id }) else { return }
            found.append(FilterSuggestion(token: token, replacing: tail, detail: detail))
        }
        for count in stride(from: min(3, words.count), through: 1, by: -1) {
            let tail = String(query[words[words.count - count].startIndex...])
            guard tail.count >= 2 else { continue }
            for person in people where Self.wordStarts(person.name, with: tail) {
                add(person.token, for: tail, "person · \(person.files)")
            }
            for album in albums where Self.wordStarts(album.title, with: tail) {
                add(album.token, for: tail, "album · \(album.files)")
            }
        }
        if photos, let last = words.last, last.count >= 3,
           ["favorites", "favourites"].contains(where: { $0.hasPrefix(last.lowercased()) }) {
            add(.photosFavorites, for: String(last), "in Photos")
        }
        if let last = words.last, last.count >= 3, "sensitive".hasPrefix(last.lowercased()) {
            add(.sensitive, for: String(last), "pictures rated sensitive")
        }
        return found
    }

    /// `text` starts `name` or one of its words ("tri" for "Summer Trip"), ignoring case and accents.
    static func wordStarts(_ name: String, with text: String) -> Bool {
        var start = name.startIndex
        while true {
            if name[start...].range(of: text, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) != nil {
                return true
            }
            guard let space = name[start...].firstIndex(where: \.isWhitespace) else { return false }
            start = name.index(after: space)
        }
    }
}

/// A filter the window's search keeps to: a token in the search field (× or ⌫ in an empty field takes it off), and
/// checked in the Filters menu (or the Favorites chip) beside the kinds. Plain data, as `PhotosChoices` makes it.
nonisolated enum FilterToken: Equatable, Identifiable, Sendable {
    /// In the picture (every person chosen must be): the ids of everyone with that name, and who they are in Photos
    /// (what a saved search keeps). No ids: a saved search's person who isn't in the indexed libraries now, which
    /// keeps nothing (`isMissing`).
    case person(name: String, ids: Set<Int64>, photos: [PhotosID])
    /// In the album (in any album chosen): the ids of every library's album of that title in those folders, and
    /// Photos' ids for them. No ids: a saved search's album that isn't indexed now, which adds nothing to the albums
    /// and alone keeps nothing.
    case album(title: String, folders: [String], ids: Set<Int64>, photos: [PhotosID])
    /// Marked ♥ in Photos.
    case photosFavorites
    /// Marked ♥ in DigUp (`Favorites`), any file.
    case digupFavorites
    /// Shot on one of my devices (`SearchModel.myDevices`, read each time the search runs, so a change in Settings
    /// applies; `SearchFilter.shotOn`). One "From" choice at a time, as `origin` is.
    case shotOnMyDevices
    /// Came into the library this way (`PhotosLibrary.Origin`): saved from another app, or imported through Photos.
    case origin(PhotosLibrary.Origin)
    /// Taken in the map's area ("Search This Area"; `SearchModel.area` holds the box).
    case area
    /// A picture or video with a picture rated sensitive (`SearchFilter.sensitive`), at the position "Blur sensitive
    /// pictures" has when the search runs (Revealing while blurring is off: `SensitivePosition.filterPosition`).
    case sensitive
    /// A video or a recording this long (`SearchFilter.length`): one Length at a time.
    case length(SearchFilter.Length)
    /// A picture or a video of this shape as it's shown (`SearchFilter.shape`): one Shape at a time.
    case shape(SearchFilter.Shape)

    /// A person by their name and an album by its folders and title, as the menus offer them; one that isn't in
    /// Photos now by the Photos ids it was saved with.
    var id: String {
        switch self {
        case .person(let name, let ids, let photos):
            ids.isEmpty ? "person-missing:\(photos.map(\.uuid).sorted())" : "person:\(name)"
        case .album(let title, let folders, let ids, let photos):
            ids.isEmpty ? "album-missing:\(photos.map(\.uuid).sorted())" : "album:\(folders + [title])"
        case .photosFavorites: "photos-favorites"
        case .digupFavorites: "digup-favorites"
        case .shotOnMyDevices: "from:mine"
        case .origin(let origin): "from:\(origin.rawValue)"
        case .area: "area"
        case .sensitive: "sensitive"
        case .length(let length): "length:\(length.text)"
        case .shape(let shape): "shape:\(shape.text)"
        }
    }

    /// The filters that are on one at a time, each with its group: what was shot on my devices and what was saved from
    /// apps exclude each other (both together would keep nothing), and so do two lengths or two shapes. The one picked
    /// replaces the one on.
    enum Choice {
        case from, length, shape
    }

    var choice: Choice? {
        switch self {
        case .shotOnMyDevices, .origin: .from
        case .length: .length
        case .shape: .shape
        default: nil
        }
    }

    /// It's among the Filters menu's (`FiltersMenu`): every filter but DigUp's favorites (their own chip) and the map's
    /// area (the map's).
    var isInFiltersMenu: Bool {
        switch self {
        case .digupFavorites, .area: false
        default: true
        }
    }

    /// A saved search's person or album that isn't in the indexed libraries now (deleted in Photos, or the library
    /// isn't searched): its token shows struck through, and it keeps nothing rather than everyone.
    var isMissing: Bool {
        switch self {
        case .person(_, let ids, _), .album(_, _, let ids, _): ids.isEmpty
        default: false
        }
    }

    var title: String {
        switch self {
        case .person(let name, _, _): name
        case .album(let title, _, _, _): title
        case .photosFavorites: "Photos Favorites"
        case .digupFavorites: "Favorites"
        case .shotOnMyDevices: "Shot on my devices"
        case .origin(let origin): origin == .imported ? "Imported into Photos" : "Saved from other apps"
        case .area: "In the map's area"
        case .sensitive: "Sensitive"
        case .length(let length): length.title
        case .shape(let shape): shape.title
        }
    }

    var symbol: String {
        switch self {
        case .person: "person.crop.circle"
        case .album: "rectangle.stack"
        case .photosFavorites: "heart.fill"
        case .digupFavorites: "heart.fill"
        case .shotOnMyDevices: "iphone"
        case .origin(let origin): origin == .imported ? "square.and.arrow.down" : "arrow.down.app"
        case .area: "map"
        case .sensitive: "eye.slash"
        case .length: "timer"
        case .shape(let shape): shape.symbol
        }
    }

    var help: String {
        switch self {
        case _ where isMissing:
            "\(title) isn't in Photos now (deleted there, or its library isn't searched): this search keeps nothing "
                + "for it"
        case .person(let name, _, _): "Only pictures Photos knows \(name) is in"
        case .album(let title, _, _, _): "Only what's in the album “\(title)”"
        case .photosFavorites: "Only what you've marked ♥ in Photos"
        case .digupFavorites: "Only what you've marked ♥ in DigUp"
        case .shotOnMyDevices:
            "Only what you shot: what the camera saved to Photos on your devices (Settings → Photos → My devices), "
                + "and older items taken with one of them"
        case .origin(let origin):
            origin == .imported ? "Only what was imported into Photos (from a folder on a Mac, or a camera's card)"
                : "Only what other apps saved to Photos: Messages, AirDrop, Safari and the rest"
        case .area: "Only what was taken in the area you searched on the map"
        case .sensitive:
            "Only pictures and videos with a picture rated sensitive, at Blur sensitive pictures' position (Settings → "
                + "General; Revealing while it's off)"
        case .length(let length): "Only videos and recordings \(length.phrase)"
        case .shape(let shape): "Only pictures and videos \(shape.phrase), as they're shown"
        }
    }
}

/// What the Length menu and a Length token say of a length.
nonisolated extension SearchFilter.Length {
    /// The menu's buckets as they're named ("Under 15 s", "15 s – 1 min", "1 – 5 min", "Over 5 min"), any other
    /// length (a saved search's, made by hand) by its bounds the same way.
    var title: String {
        switch (atLeast, under) {
        case (let atLeast?, let under?):
            Self.minutes(atLeast).flatMap { from in Self.minutes(under).map { "\(from) – \($0) min" } }
                ?? "\(Self.spoken(atLeast)) – \(Self.spoken(under))"
        case (let atLeast?, nil): "Over \(Self.spoken(atLeast))"
        case (nil, let under?): "Under \(Self.spoken(under))"
        case (nil, nil): ""   // not a length (`init` turns it down)
        }
    }

    /// "shorter than 15 s", "at least 15 s long and shorter than 1 min", "5 min long or longer".
    var phrase: String {
        switch (atLeast, under) {
        case (let atLeast?, let under?): "at least \(Self.spoken(atLeast)) long and shorter than \(Self.spoken(under))"
        case (let atLeast?, nil): "\(Self.spoken(atLeast)) long or longer"
        case (nil, let under?): "shorter than \(Self.spoken(under))"
        case (nil, nil): ""
        }
    }

    /// "15 s", "1 min", "1 min 30 s".
    private static func spoken(_ seconds: Double) -> String {
        if let whole = minutes(seconds) { return "\(whole) min" }
        let over = Int(seconds) / 60
        let rest = "\((seconds - Double(over * 60)).formatted(.number.precision(.fractionLength(0...1)))) s"
        return over > 0 ? "\(over) min \(rest)" : rest
    }

    /// Whole minutes, from 1 up; nil for any other number of seconds.
    private static func minutes(_ seconds: Double) -> Int? {
        seconds >= 60 && seconds.truncatingRemainder(dividingBy: 60) == 0 ? Int(seconds / 60) : nil
    }
}

/// What the Shape menu and a Shape token say of a shape.
nonisolated extension SearchFilter.Shape {
    var title: String {
        switch self {
        case .portrait: "Portrait"
        case .landscape: "Landscape"
        case .square: "Square"
        case .wide: "Wide"
        case .ratio: text
        }
    }

    /// The Shape menu's item: its title, and for square and wide what they take in.
    var menuTitle: String {
        switch self {
        case .square: "Square (sides within 5 %)"
        case .wide: "Wide (2:1 or wider)"
        default: title
        }
    }

    var symbol: String {
        switch self {
        case .portrait: "rectangle.portrait"
        case .landscape: "rectangle"
        case .square: "square"
        case .wide: "pano"
        case .ratio: "aspectratio"
        }
    }

    /// "taller than they're wide", "shaped 16:9 (within 2 %)".
    var phrase: String {
        switch self {
        case .portrait: "taller than they're wide"
        case .landscape: "wider than they're tall"
        case .square: "with sides within 5 % of each other"
        case .wide: "at least twice as wide as they're tall (panoramas, cinema)"
        case .ratio: "shaped \(text) (within 2 %)"
        }
    }
}

/// A filter the words being typed could be (`PhotosChoices.suggestions`): taking it takes those words out of the
/// query.
nonisolated struct FilterSuggestion: Equatable, Identifiable, Sendable {
    let token: FilterToken
    /// The end of the query it's for.
    let replacing: String
    /// "person · 120": what it is, and how many indexed files it has.
    let detail: String
    var id: String { token.id }
}

/// A filter that's on, in the search field before the words.
struct FilterTokenView: View {
    let token: FilterToken
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: token.symbol).font(.system(size: 10))
            if token.isMissing {
                // "Katie — not in Photos now": a saved search's person or album that's gone keeps nothing.
                Text("\(Text(token.title).strikethrough())\(Text(" — not in Photos now").foregroundStyle(.secondary))")
                    .lineLimit(1).truncationMode(.tail).frame(maxWidth: 220)
            } else {
                Text(token.title).lineLimit(1).truncationMode(.tail).frame(maxWidth: 150)
            }
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold)).opacity(0.6)
            }
            .buttonStyle(.plain)
            .help("Remove this filter (⌫ in an empty field)")
        }
        .font(.system(size: 12.5, weight: .medium))
        .padding(.leading, 8)
        .padding(.trailing, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.accentColor.opacity(0.2)))
        .fixedSize()
        .help(token.help)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Filter: \(token.title)" + (token.isMissing ? ", not in Photos now" : ""))
    }
}

/// Under the field while a name is being typed: the filters it could be. Tab takes the first.
struct FilterSuggestionsBar: View {
    let suggestions: [FilterSuggestion]
    let accept: (FilterSuggestion) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                Button {
                    accept(suggestion)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: suggestion.token.symbol).font(.system(size: 10))
                        Text(suggestion.token.title).fontWeight(.medium).lineLimit(1)
                        Text(suggestion.detail).foregroundStyle(.secondary).lineLimit(1)
                        if index == 0 { Keycaps(caps: ["Tab"], size: 9) }
                    }
                    .font(.system(size: 12))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(index == 0 ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.07)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(index == 0 ? "Filter by this (Tab)" : "Filter by this")
            }
        }
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
    }
}

/// Filters ▾ beside the kinds and the Favorites chip (Jon, 2026-10-22: "yes"): every filter but DigUp's favorites and
/// the map's area, in one menu, so the row fits the window. Photos' people (everyone picked must be in a picture),
/// albums (it may be in any one picked), favorites and From while a library is searched; then Sensitive, Length and
/// Shape. A filter with choices has a submenu, whose title says which is on. The menu's title counts the filters on
/// ("Filters · 2"), and each is a token in the field too.
struct FiltersMenu: View {
    let search: SearchModel

    var body: some View {
        let count = FilterMenuItem.count(search)
        Menu {
            FilterMenuContent(items: FilterMenuItem.items(search), search: search)
        } label: {
            FilterChipLabel(title: FilterMenuItem.title(on: count), symbol: "line.3.horizontal.decrease.circle",
                            selected: count > 0, menu: true)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(search.searchesPhotos
              ? "Filters: Photos' people, albums, favorites and where it came from, pictures rated sensitive, how long "
                + "a video or a recording is, and what shape a picture or a video is"
              : "Filters: pictures rated sensitive, how long a video or a recording is, and what shape a picture or a "
                + "video is")
    }
}

/// One item of the Filters menu, as data: `FiltersMenu` makes the menu of them, and `-debugFiltersMenu` draws them (an
/// open menu can't be drawn offscreen).
enum FilterMenuItem: Identifiable {
    /// A filter, checked while it's on.
    case toggle(String, FilterToken, enabled: Bool = true)
    /// A submenu: its title, which says what of it is on, a name for it among its neighbours, and its items.
    case submenu(String, id: String, [FilterMenuItem])
    /// A line that can't be chosen.
    case note(String)
    case divider(id: String)

    var id: String {
        switch self {
        case .toggle(_, let token, _): token.id
        case .submenu(_, let id, _): "menu:\(id)"
        case .note(let text): "note:\(text)"
        case .divider(let id): "divider:\(id)"
        }
    }

    /// How many of the menu's filters are on.
    static func count(_ search: SearchModel) -> Int {
        search.tokens.filter(\.isInFiltersMenu).count
    }

    /// "Filters", or "Filters · 2" with two of its filters on.
    static func title(on count: Int) -> String {
        count == 0 ? "Filters" : "Filters · \(count)"
    }

    /// The menu as it is for the window's search now.
    static func items(_ search: SearchModel) -> [FilterMenuItem] {
        var items = search.searchesPhotos ? photosItems(search) + [.divider(id: "photos")] : []
        items.append(.toggle("Sensitive", .sensitive))
        let lengths = SearchFilter.Length.buckets.map { FilterMenuItem.toggle($0.title, .length($0)) }
        items.append(.submenu(titled("Length", on: titles(of: .length, in: search)), id: "length", lengths))
        let shapes: [SearchFilter.Shape] = [.portrait, .landscape, .square, .wide]
        let shapeItems = shapes.map { FilterMenuItem.toggle($0.menuTitle, .shape($0)) } + [.divider(id: "ratios")]
            + SearchFilter.Shape.ratios.map { FilterMenuItem.toggle($0.menuTitle, .shape($0)) }
        items.append(.submenu(titled("Shape", on: titles(of: .shape, in: search)), id: "shape", shapeItems))
        return items
    }

    /// People, Albums, Photos Favorites and From: what Photos knows, while a library is searched.
    private static func photosItems(_ search: SearchModel) -> [FilterMenuItem] {
        var items: [FilterMenuItem] = []
        let people = search.choices.people, albums = search.choices.albums
        if !people.isEmpty {
            let named = search.tokens.compactMap { if case .person(let name, _, _) = $0 { name } else { nil } }
            items.append(.submenu(titled("People", on: named), id: "people", people.map {
                FilterMenuItem.toggle("\($0.name)  ·  \($0.files)", $0.token)
            }))
        }
        if !albums.isEmpty {
            let picked = search.tokens.compactMap { if case .album(let title, _, _, _) = $0 { title } else { nil } }
            items.append(.submenu(titled("Albums", on: picked), id: "albums", albumItems(albums, depth: 0)))
        }
        items.append(.toggle("Photos Favorites", .photosFavorites))
        let devices = search.myDevices
        let from: [FilterMenuItem] = [
            .toggle("Shot on my devices", .shotOnMyDevices, enabled: !devices.isEmpty || search.has(.shotOnMyDevices)),
        ] + (devices.isEmpty ? [] : [.note(devices.formatted(.list(type: .and)))]) + [
            .divider(id: "from"),
            .toggle("Saved from other apps", .origin(.saved)),
            .toggle("Imported into Photos", .origin(.imported)),
        ]
        items.append(.submenu(titled("From", on: titles(of: .from, in: search)), id: "from", from))
        return items
    }

    /// The title of the From, Length or Shape that's on, if one is.
    private static func titles(of choice: FilterToken.Choice, in search: SearchModel) -> [String] {
        search.tokens.filter { $0.choice == choice }.map(\.title)
    }

    /// The albums at one depth of folders: their toggles, then a submenu for each folder.
    private static func albumItems(_ albums: [PhotosChoices.Album], depth: Int) -> [FilterMenuItem] {
        var folders: [String] = []
        for album in albums where album.folders.count > depth && !folders.contains(album.folders[depth]) {
            folders.append(album.folders[depth])
        }
        return albums.filter { $0.folders.count == depth }.map {
            FilterMenuItem.toggle("\($0.title)  ·  \($0.files)", $0.token)
        } + folders.map { folder in
            .submenu(folder, id: "folder:\(folder)", albumItems(albums.filter {
                $0.folders.count > depth && $0.folders[depth] == folder
            }, depth: depth + 1))
        }
    }

    /// "Length", "Length · 15 s – 1 min", "People · Tati + 2": a submenu's title with what's on in it.
    private static func titled(_ name: String, on: [String]) -> String {
        guard let first = on.first else { return name }
        return "\(name) · " + (on.count == 1 ? first : "\(first) + \(on.count - 1)")
    }
}

/// The Filters menu's items at one level of it (a submenu's are a level of their own).
private struct FilterMenuContent: View {
    let items: [FilterMenuItem]
    let search: SearchModel

    var body: some View {
        ForEach(items) { item in
            switch item {
            case .toggle(let title, let token, let enabled):
                Toggle(title, isOn: Binding(get: { search.has(token) }, set: { search.set(token, on: $0) }))
                    .disabled(!enabled)
            case .submenu(let title, _, let items):
                Menu(title) { AnyView(FilterMenuContent(items: items, search: search)) }
            case .note(let text):
                Text(text)
            case .divider:
                Divider()
            }
        }
    }
}

/// A filter chip's look, as the kind chips': filled in the accent color while on.
struct FilterChipLabel: View {
    let title: String
    let symbol: String
    let selected: Bool
    var menu = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 10.5))
            Text(title).lineLimit(1)
            if menu { Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).opacity(0.6) }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary.opacity(0.06))))
        .contentShape(Capsule())
        // One element named by its title (VoiceOver, and the menus' items read as one button each, not three).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }
}
