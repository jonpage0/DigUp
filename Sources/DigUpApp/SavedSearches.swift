import AppKit
import DigUpKit
import Observation
import SwiftUI

/// A search the user saved: its words, kind and filters, run again whenever it's opened (a smart folder: nothing about
/// its results is kept). One entry of `saved-searches.json` (`SavedSearches`).
struct SavedSearch: Equatable, Identifiable {
    /// Made when it's saved; renaming or moving it keeps it.
    var id: UUID
    /// What the Saved menu shows: never empty, and two may share one.
    var name: String
    /// The words as typed: "" for filters alone, "code: …" for code.
    var query: String
    /// The window's kind button; nil for All.
    var kind: ResultGroupKind?
    /// The tokens in the search field, in order (the map's area is the last of them there).
    var filters: [Filter]
    var saved: Date

    /// One token of the search field.
    enum Filter: Equatable {
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
        /// 2026-10-22; the kit reads it strictly: `SearchFilter.Length`'s `Codable`).
        case length(SearchFilter.Length)
        /// The Shape filter: `{ "shape": "portrait" }`, or an exact ratio, `{ "shape": "16:9" }` (approved 2026-10-22).
        case shape(SearchFilter.Shape)
        /// The When filter: `{ "when": { "after": "2026-07-01", "before": "2026-08-01" } }` (local days, either left
        /// out) or `{ "when": { "lastDays": 90 } }`, a window ending when the search runs (approved 2026-10-23; the kit
        /// reads it strictly: `SearchFilter.When`'s `Codable`).
        case when(SearchFilter.When)
    }

    /// A person by Photos' ids, one per library that has them (everyone of the name, as the People filter joins
    /// them), with the name they had when it was saved.
    struct Person: Codable, Equatable {
        var name: String
        var photos: [PhotosID]
    }

    /// An album by Photos' ids (each library's album of that title in those folders), with its title and folders
    /// when it was saved.
    struct Album: Codable, Equatable {
        var title: String
        var folders: [String]
        var photos: [PhotosID]
    }

    /// The window's From. `mine` is "Shot on my devices" as the list is when the search runs (Settings → Photos → My
    /// devices), not a copy of it.
    enum From: String, Codable {
        case mine, saved, imported
    }

    /// The map's area, in degrees.
    struct Area: Codable, Equatable {
        var south: Double
        var west: Double
        var north: Double
        var east: Double

        init(_ area: SearchFilter.Area) {
            (south, north) = (area.latitudes.lowerBound, area.latitudes.upperBound)
            (west, east) = (area.longitudes.lowerBound, area.longitudes.upperBound)
        }

        /// A box on the map: south to north, west to east, within the earth's degrees.
        var isBox: Bool { -90 <= south && south <= north && north <= 90 && -180 <= west && west <= east && east <= 180 }

        /// Only for a box (`isBox`, which reading the file checks).
        var searchArea: SearchFilter.Area { SearchFilter.Area(latitudes: south...north, longitudes: west...east) }
    }

    /// What the file's shape asks of a search beyond its keys: a name, at most one From, one area, one Sensitive, one
    /// Length, one Shape and one When, and an area that's a box.
    var isWellFormed: Bool {
        var froms = 0, areas = 0, sensitives = 0, lengths = 0, shapes = 0, whens = 0
        for filter in filters {
            switch filter {
            case .from: froms += 1
            case .area(let area):
                guard area.isBox else { return false }
                areas += 1
            case .sensitive: sensitives += 1
            case .length: lengths += 1
            case .shape: shapes += 1
            case .when: whens += 1
            default: break
            }
        }
        return !name.isEmpty && [froms, areas, sensitives, lengths, shapes, whens].allSatisfy { $0 <= 1 }
    }
}

extension SavedSearch: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, name, query, kind, filters, saved
    }

    /// Every key is there, and no other: `kind` too, null for All.
    init(from decoder: any Decoder) throws {
        try onlyKeys(CodingKeys.self, in: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        query = try container.decode(String.self, forKey: .query)
        kind = try container.decode(ResultGroupKind?.self, forKey: .kind)
        filters = try container.decode([Filter].self, forKey: .filters)
        saved = try container.decode(Date.self, forKey: .saved)
    }

    func encode(to encoder: any Encoder) throws {
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

    init(from decoder: any Decoder) throws {
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

    init(from decoder: any Decoder) throws {
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

    init(from decoder: any Decoder) throws {
        try onlyKeys(CodingKeys.self, in: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        south = try container.decode(Double.self, forKey: .south)
        west = try container.decode(Double.self, forKey: .west)
        north = try container.decode(Double.self, forKey: .north)
        east = try container.decode(Double.self, forKey: .east)
    }
}

/// A filter is an object with exactly one key, one of these ten; anything else isn't this shape.
extension SavedSearch.Filter: Codable {
    private enum Key: String, CodingKey, CaseIterable {
        case person, album, photosFavorites, digupFavorites, from, area, sensitive, length, shape, when
    }

    init(from decoder: any Decoder) throws {
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
        case .when: self = .when(try container.decode(SearchFilter.When.self, forKey: key))
        }
    }

    func encode(to encoder: any Encoder) throws {
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
        case .when(let when): try container.encode(when, forKey: .when)
        }
    }
}

/// The searches the user saved (the search window's Saved menu). The user makes these, so they're kept out of the
/// index, which DigUp rebuilds and Settings → Storage can delete: `saved-searches.json` beside the index folder, as
/// `favorites.json` is, read once and written whole on each change (to a temporary file, then renamed over the old
/// one).
///
/// The shape (approved 2026-10-22; `{ "sensitive": true }` with it, the same evening; `{ "length": … }` and
/// `{ "shape": … }` with the Length and Shape filters; `{ "when": … }` with When, 2026-10-23):
///
///     { "version": 1,
///       "searches": [ { "id": "<UUID>", "name": "Tati at the beach", "query": "beach", "kind": "images",
///                       "filters": [ { "person": { "name": "…", "photos": [ { "library": "…", "uuid": "…" } ] } },
///                                    { "album": { "title": "…", "folders": ["…"], "photos": [ … ] } },
///                                    { "photosFavorites": true }, { "digupFavorites": true }, { "from": "mine" },
///                                    { "area": { "south": 25.1, "west": -80.9, "north": 26.2, "east": -79.8 } },
///                                    { "sensitive": true }, { "length": { "atLeast": 15, "under": 60 } },
///                                    { "shape": "16:9" }, { "when": { "lastDays": 90 } } ],
///                       "saved": "<ISO 8601>" } ] }
///
/// In the user's order, which the menu shows. A file DigUp can't read as exactly this shape (a newer version, damaged,
/// a key anywhere that the shape doesn't have, a filter with two keys or none, two From, two areas, two Sensitive, two
/// lengths, two shapes or two Whens in one search, a length, a shape or a When the filters don't have) is left as it is
/// and never written over: nothing can be saved, renamed or deleted until it's fixed.
@MainActor @Observable
final class SavedSearches {
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

    private(set) var searches: [SavedSearch] = []
    /// The file is there but isn't this shape.
    private(set) var unreadable = false
    @ObservationIgnored let url: URL

    /// Beside the index folder (`~/Library/Application Support/DigUp/saved-searches.json` for the default one).
    convenience init(beside indexDirectory: URL) {
        self.init(url: indexDirectory.deletingLastPathComponent().appendingPathComponent("saved-searches.json"))
    }

    init(url: URL) {
        self.url = url
        load()
    }

    func add(_ search: SavedSearch) {
        guard !unreadable else { return }
        searches.append(search)
        save()
    }

    /// A new name; a blank one leaves the old.
    func rename(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !unreadable, !name.isEmpty, let index = searches.firstIndex(where: { $0.id == id }),
              searches[index].name != name else { return }
        searches[index].name = name
        save()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        guard !unreadable else { return }
        searches.move(fromOffsets: source, toOffset: destination)
        save()
    }

    func delete(_ id: UUID) {
        guard !unreadable, searches.contains(where: { $0.id == id }) else { return }
        searches.removeAll { $0.id == id }
        save()
    }

    /// The panel's suggestion as a name is typed: the first saved search whose name starts with the words (two
    /// letters at least), ignoring case and accents.
    func suggestion(for typed: String) -> SavedSearch? {
        let text = String(typed.drop(while: \.isWhitespace))
        guard text.count >= 2 else { return nil }
        return searches.first {
            $0.name.range(of: text, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    // MARK: The file

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

    private func load() {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            let version = try Self.decoder.decode(Version.self, from: data).version
            guard version == 1 else {
                unreadable = true
                log("saved searches: \(url.lastPathComponent) is version \(version); this DigUp reads 1, so it's left alone")
                return
            }
            let stored = try Self.decoder.decode(Stored.self, from: data)
            guard stored.searches.allSatisfy(\.isWellFormed),
                  Set(stored.searches.map(\.id)).count == stored.searches.count else {
                unreadable = true
                log("saved searches: \(url.lastPathComponent) has a search without a name, with two From, two areas, "
                    + "two Sensitive, two lengths, two shapes or two Whens, an area that isn't a box, or an id twice; "
                    + "it's left as it is")
                return
            }
            searches = stored.searches
            log("saved searches: \(searches.count)")
        } catch {
            unreadable = true
            log("saved searches: \(url.lastPathComponent) can't be read (\(error)); it's left as it is")
        }
    }

    private func save() {
        guard !unreadable else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.encoder.encode(Stored(version: 1, searches: searches)).write(to: url, options: .atomic)
        } catch {
            log("saved searches: can't save \(url.lastPathComponent): \(error)")
        }
    }
}

// MARK: The Saved menu

/// The Saved menu's items, in order: the saved searches, then Save This Search… (⌘S) and Edit Saved Searches….
enum SavedMenuItem: Identifiable {
    case search(SavedSearch)
    /// A line that can't be chosen: none saved yet, or a file that can't be read.
    case note(String)
    case divider
    case save(enabled: Bool)
    case edit(enabled: Bool)

    var id: String {
        switch self {
        case .search(let search): search.id.uuidString
        case .note(let text): "note:\(text)"
        case .divider: "divider"
        case .save: "save"
        case .edit: "edit"
        }
    }

    static let saveTitle = "Save This Search…"
    static let editTitle = "Edit Saved Searches…"

    /// `canSave`: the window has something to save (words, or a filter).
    static func items(_ saved: SavedSearches, canSave: Bool) -> [SavedMenuItem] {
        var items: [SavedMenuItem] = saved.searches.map { .search($0) }
        if saved.unreadable {
            items = [.note("\(saved.url.lastPathComponent) can't be read")]
        } else if items.isEmpty {
            items = [.note("No saved searches yet")]
        }
        return items + [.divider, .save(enabled: canSave && !saved.unreadable),
                        .edit(enabled: !saved.unreadable && !saved.searches.isEmpty)]
    }
}

/// The bookmark in the search window's header: the saved searches (choosing one puts it in the window and runs it),
/// Save This Search… and Edit Saved Searches….
struct SavedSearchesMenu: View {
    let saved: SavedSearches
    let canSave: Bool
    let open: (SavedSearch) -> Void
    let save: () -> Void
    let edit: () -> Void

    var body: some View {
        Menu {
            ForEach(SavedMenuItem.items(saved, canSave: canSave)) { item in
                switch item {
                case .search(let search): Button(search.name) { open(search) }
                case .note(let text): Text(text)
                case .divider: Divider()
                case .save(let enabled):
                    Button(SavedMenuItem.saveTitle, action: save)
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(!enabled)
                case .edit(let enabled):
                    Button(SavedMenuItem.editTitle, action: edit).disabled(!enabled)
                }
            }
        } label: {
            Image(systemName: "bookmark")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Saved searches: open one, or save this one (⌘S)")
        .accessibilityLabel("Saved searches")
    }
}

// MARK: Sheets

/// Save This Search… and Edit Saved Searches…: sheets on the search window. They're AppKit windows, as Add Folders is,
/// so a snapshot run draws them without showing them.
final class SavedSearchSheet {
    private var sheet: NSWindow?
    private unowned let app: AppController
    /// The open Save sheet's Save, with a name (`-debugSaveAs` presses it).
    private(set) var saveAs: ((String) -> Void)?

    init(app: AppController) {
        self.app = app
    }

    var isOpen: Bool { sheet != nil }

    /// Asks for the name, `search.name` filled in; Save adds it to the end of the menu.
    func beginSave(_ search: SavedSearch, describing summary: String, on window: NSWindow?) {
        let saved = app.savedSearches
        let save: (String) -> Void = { [weak self] name in
            var search = search
            search.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            search.saved = Date()
            guard !search.name.isEmpty else { return }
            saved.add(search)
            log("saved searches: saved one with \(search.filters.count) filters (\(saved.searches.count) now)")
            self?.end()
        }
        present(SaveSearchView(name: search.name, summary: summary, save: save, cancel: { [weak self] in self?.end() }),
                title: SavedMenuItem.saveTitle, on: window)
        saveAs = save
    }

    func beginEdit(on window: NSWindow?) {
        saveAs = nil
        present(EditSavedSearchesView(saved: app.savedSearches, done: { [weak self] in self?.end() }),
                title: "Saved Searches", on: window)
    }

    private func present(_ view: some View, title: String, on window: NSWindow?) {
        end()
        let sheet = NSWindow(contentViewController: NSHostingController(rootView: view))
        sheet.styleMask = [.titled]
        sheet.title = title
        self.sheet = sheet
        guard !AppController.offscreen else { return }   // snapshot runs draw it without showing it
        if let window, window.isVisible { window.beginSheet(sheet) } else { app.present(sheet) }
    }

    func end() {
        if let sheet {
            if let parent = sheet.sheetParent { parent.endSheet(sheet) } else { sheet.close() }
        }
        sheet = nil
        saveAs = nil
    }

    func snapshot(to url: URL) throws {
        try Snapshot.write(sheet, to: url)
    }
}

/// Save This Search…: its name (the suggested one, to keep or change), and what it keeps.
private struct SaveSearchView: View {
    @State var name: String
    let summary: String
    let save: (String) -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save This Search").font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if canSave { save(name) } }
            Text(summary)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("It's in the Saved menu (the bookmark beside the search field), and opening it searches again, so new "
                 + "files show up.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Save") { save(name) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private var canSave: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// Edit Saved Searches…: rename one in place, drag to reorder (the menu's order), delete.
private struct EditSavedSearchesView: View {
    let saved: SavedSearches
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Saved Searches").font(.headline)
            Text("The Saved menu lists them in this order: drag one to move it. Click a name to change it.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List {
                ForEach(saved.searches) { search in
                    SavedSearchRow(search: search, rename: { saved.rename(search.id, to: $0) },
                                   delete: { saved.delete(search.id) })
                }
                .onMove { saved.move(fromOffsets: $0, toOffset: $1) }
            }
            .frame(minHeight: 220, idealHeight: 300, maxHeight: 420)
            HStack {
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

/// One saved search in the editor: its name to edit (applied on Return or when the field is left), what it searches
/// for, and its delete button.
private struct SavedSearchRow: View {
    let search: SavedSearch
    let rename: (String) -> Void
    let delete: () -> Void
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 2) {
                TextField("Name", text: $name)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { rename(name) }
                    .onChange(of: focused) { _, now in if !now { rename(name) } }
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button(action: delete) {
                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Delete this saved search")
            .accessibilityLabel("Delete \(search.name)")
        }
        .padding(.vertical, 2)
        .onAppear { name = search.name }
        .onChange(of: search.name) { _, now in name = now }
    }

    /// "“beach” · Images · 3 filters"
    private var detail: String {
        let words = search.query.trimmingCharacters(in: .whitespaces)
        let count = search.filters.count
        return ([words.isEmpty ? nil : "“\(words)”", search.kind?.title ?? "All kinds",
                 count == 0 ? nil : count == 1 ? "1 filter" : "\(count) filters"] as [String?])
            .compactMap { $0 }.joined(separator: " · ")
    }
}
