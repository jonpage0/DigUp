import AppKit
import DigUpKit
import Observation
import SwiftUI

/// The searches the user saved (the search window's Saved menu). The user makes these, so they're kept out of the
/// index, which DigUp rebuilds and Settings → Storage can delete: `saved-searches.json` beside the index folder, as
/// `favorites.json` is, read once and written whole on each change (to a temporary file, then renamed over the old
/// one), in the shape the kit reads and writes (`SavedSearch`), which `digup mcp` reads too.
///
/// In the user's order, which the menu shows. A file DigUp can't read as exactly that shape is left as it is and never
/// written over: nothing can be saved, renamed or deleted until it's fixed.
@MainActor @Observable
final class SavedSearches {
    private(set) var searches: [SavedSearch] = []
    /// The file is there but isn't this shape.
    private(set) var unreadable = false
    @ObservationIgnored let url: URL

    /// Beside the index folder (`~/Library/Application Support/DigUp/saved-searches.json` for the default one).
    convenience init(beside indexDirectory: URL) {
        self.init(url: SavedSearch.url(beside: indexDirectory))
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

    private func load() {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            searches = try SavedSearch.searches(in: Data(contentsOf: url))
            log("saved searches: \(searches.count)")
        } catch SavedSearch.FileError.version(let version) {
            unreadable = true
            log("saved searches: \(url.lastPathComponent) is version \(version); this DigUp reads 1, so it's left "
                + "alone")
        } catch SavedSearch.FileError.notWellFormed {
            unreadable = true
            log("saved searches: \(url.lastPathComponent) has a search without a name, with two From, two areas, "
                + "two Sensitive, two lengths, two shapes or two Match by, an area that isn't a box, or an id "
                + "twice; it's left as it is")
        } catch {
            unreadable = true
            log("saved searches: \(url.lastPathComponent) can't be read (\(error)); it's left as it is")
        }
    }

    private func save() {
        guard !unreadable else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try SavedSearch.data(searches).write(to: url, options: .atomic)
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
