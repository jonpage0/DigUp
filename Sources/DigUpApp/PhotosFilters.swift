import DigUpKit
import SwiftUI

/// The people, albums and devices the indexed Photos libraries name, as the search window offers them to filter by.
struct PhotosChoices: Sendable, Equatable {
    var people: [Person] = []
    var albums: [Album] = []
    /// The devices that took the libraries' pictures (`IndexStore.photosCameras`), most files first.
    var cameras: [IndexStore.PhotosCamera] = []

    /// "Shot on my devices": every device a camera saved something from into a library, plus the ones the user added,
    /// minus the ones they took off (`AppSettings.myDevicesAdded`, `myDevicesRemoved`), most files first; an added one
    /// no indexed picture names (yet, or any more) is on it too, last.
    func devices(added: [String], removed: [String]) -> [String] {
        let known = cameras.filter { Self.isMine($0, added: added, removed: removed) }.map(\.model)
        return known + added.filter { name in !removed.contains(name) && !cameras.contains { $0.model == name } }
    }

    /// The rule behind the list (approved 2026-10-22): a device whose camera saved something is the user's unless
    /// they took it off; any other is theirs only if they added it.
    static func isMine(_ camera: IndexStore.PhotosCamera, added: [String], removed: [String]) -> Bool {
        (camera.fromCamera > 0 || added.contains(camera.model)) && !removed.contains(camera.model)
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
    struct Person: Sendable, Equatable, Identifiable {
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
    struct Album: Sendable, Equatable, Identifiable {
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
/// checked in its menu beside the kinds.
enum FilterToken: Equatable, Identifiable {
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
        }
    }

    /// Only one "From" filter is on at a time: what was shot on my devices and what was saved from apps exclude each
    /// other, and both together would keep nothing.
    var isFrom: Bool { id.hasPrefix("from:") }

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
        }
    }
}

/// A filter the words being typed could be (`PhotosChoices.suggestions`): taking it takes those words out of the
/// query.
struct FilterSuggestion: Equatable, Identifiable {
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

/// People ▾ · Albums ▾ · ♥ Favorites beside the kinds: what Photos knows, as filters. A choice is a token in the field
/// too. Everyone picked must be in a picture; it may be in any album picked.
struct PhotosFilterMenus: View {
    let search: SearchModel

    var body: some View {
        HStack(spacing: 6) {
            if !search.choices.people.isEmpty {
                Menu {
                    ForEach(search.choices.people) { person in
                        PhotosFilterToggle(title: "\(person.name)  ·  \(person.files)", token: person.token,
                                           search: search)
                    }
                } label: {
                    FilterChipLabel(title: title(of: people, none: "People"), symbol: "person.crop.circle",
                                    selected: !people.isEmpty, menu: true)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("People: only pictures everyone you pick is in")
            }
            if !search.choices.albums.isEmpty {
                Menu {
                    AlbumMenuItems(albums: search.choices.albums, depth: 0, search: search)
                } label: {
                    FilterChipLabel(title: title(of: albums, none: "Albums"), symbol: "rectangle.stack",
                                    selected: !albums.isEmpty, menu: true)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Albums: only what's in any album you pick")
            }
            Button {
                search.toggle(.photosFavorites)
            } label: {
                FilterChipLabel(title: "Photos Favorites", symbol: search.has(.photosFavorites) ? "heart.fill" : "heart",
                                selected: search.has(.photosFavorites))
            }
            .buttonStyle(.plain)
            .help("Photos Favorites: only what you've marked ♥ in Photos")
            .accessibilityAddTraits(search.has(.photosFavorites) ? .isSelected : [])
            Menu {
                let devices = search.myDevices
                PhotosFilterToggle(title: "Shot on my devices", token: .shotOnMyDevices, search: search)
                    .disabled(devices.isEmpty && !search.has(.shotOnMyDevices))
                if !devices.isEmpty {
                    Text(devices.formatted(.list(type: .and)))
                }
                Divider()
                PhotosFilterToggle(title: "Saved from other apps", token: .origin(.saved), search: search)
                PhotosFilterToggle(title: "Imported into Photos", token: .origin(.imported), search: search)
            } label: {
                FilterChipLabel(title: from?.title ?? "From", symbol: from?.symbol ?? "iphone", selected: from != nil,
                                menu: true)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("From: what you shot on your own devices, what other apps saved, or what was imported")
        }
    }

    private var people: [String] {
        search.tokens.compactMap { if case .person(let name, _, _) = $0 { name } else { nil } }
    }

    /// The "From" filter that's on, if one is.
    private var from: FilterToken? { search.tokens.first(where: \.isFrom) }

    private var albums: [String] {
        search.tokens.compactMap { if case .album(let title, _, _, _) = $0 { title } else { nil } }
    }

    /// "People", "Tati", or "Tati + 2".
    private func title(of names: [String], none: String) -> String {
        guard let first = names.first else { return none }
        return names.count == 1 ? first : "\(first) + \(names.count - 1)"
    }
}

/// An album menu's items at one depth of folders: its albums, then a submenu for each folder.
private struct AlbumMenuItems: View {
    let albums: [PhotosChoices.Album]
    let depth: Int
    let search: SearchModel

    var body: some View {
        let here = albums.filter { $0.folders.count == depth }
        var folders: [String] = []
        for album in albums where album.folders.count > depth && !folders.contains(album.folders[depth]) {
            folders.append(album.folders[depth])
        }
        return Group {
            ForEach(here) { album in
                PhotosFilterToggle(title: "\(album.title)  ·  \(album.files)", token: album.token, search: search)
            }
            ForEach(folders, id: \.self) { folder in
                Menu(folder) {
                    AnyView(AlbumMenuItems(albums: albums.filter { $0.folders.count > depth && $0.folders[depth] == folder },
                                           depth: depth + 1, search: search))
                }
            }
        }
    }
}

/// A menu item that turns one filter on and off (a check shows while it's on).
private struct PhotosFilterToggle: View {
    let title: String
    let token: FilterToken
    let search: SearchModel

    var body: some View {
        Toggle(title, isOn: Binding(get: { search.has(token) }, set: { search.set(token, on: $0) }))
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
