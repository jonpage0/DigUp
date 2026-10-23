import AppKit
import DigUpKit
import MapKit
import Observation
import Quartz
import SwiftUI

/// The search window, for the searches the panel is too small for: a big field, kind filters with counts, the results
/// as a grid of pictures, and the selected one in a preview pane with why it matched. The Dock icon shows while it's
/// open, and closing it frees its views (the app goes back to its idle size).
final class SearchWindowController: NSObject, NSWindowDelegate {
    let search: SearchModel
    /// Save This Search… and Edit Saved Searches… (the Saved menu).
    let savedSheet: SavedSearchSheet
    private unowned let app: AppController
    private var window: QuickLookWindow?
    private var keyMonitor: Any?
    private var mouseMonitor: Any?

    init(app: AppController) {
        self.app = app
        search = SearchModel(engine: app.engine, favorites: app.favorites, faceCorrections: app.faceCorrections,
                             model: app.model)
        savedSheet = SavedSearchSheet(app: app)
        super.init()
        search.selected = { [weak self] in self?.selectionChanged() }
    }

    var isVisible: Bool { window?.isVisible == true }

    func show(query: String? = nil, kind: ResultGroupKind? = nil) {
        let window = self.window ?? makeWindow()
        if let query {
            search.filter = kind
            search.query = query
        }
        search.searchesPhotos = app.photosLibraries.contains(where: app.searches)
        search.readChoices(force: true)
        app.present(window)
        if !AppController.offscreen { window.makeFirstResponder(search.field) }
        installKeyMonitor()
    }

    func close() {
        window?.close()
    }

    // MARK: Saved searches

    /// Opens a saved search here: the window, with its words, kind, filters and map area, searched again.
    func open(_ saved: SavedSearch) {
        show()
        Task { await search.open(saved) }
    }

    /// Save This Search… (⌘S): asks for the name, the suggested one filled in. Only with something to save.
    func saveSearch() {
        guard search.isSearching, !app.savedSearches.unreadable else { return }
        savedSheet.beginSave(search.saved(named: search.suggestedName), describing: search.savedSummary, on: window)
    }

    func editSavedSearches() {
        savedSheet.beginEdit(on: window)
    }

    private func makeWindow() -> QuickLookWindow {
        let window = QuickLookWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 700),
                                     styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                     backing: .buffered, defer: false)
        // An empty unified toolbar makes the title bar tall enough for the search field to sit beside the window
        // buttons.
        window.toolbar = NSToolbar(identifier: "DigUpSearch")
        window.toolbarStyle = .unified
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "DigUp"
        window.minSize = NSSize(width: 820, height: 520)
        window.isReleasedWhenClosed = false
        window.delegate = self
        // The frame is remembered in the app's real defaults, so dev runs (their own -defaultsSuite) don't keep it.
        if UserDefaults.standard.string(forKey: "defaultsSuite") == nil {
            window.setFrameAutosaveName("DigUpSearchWindow")
        }
        window.contentView = NSHostingView(rootView: SearchWindowView(search: search, model: app.model, app: app))
        if window.frame.origin == .zero { window.center() }
        self.window = window
        return window
    }

    func windowWillClose(_ notification: Notification) {
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().orderOut(nil)
        }
        savedSheet.end()
        removeKeyMonitor()
        PreviewPlayback.shared.stop()
        window?.contentView = nil
        window = nil
        app.windowClosed()
    }

    func snapshot(to url: URL) throws {
        try Snapshot.write(window, to: url)
    }

    // MARK: Keys

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window else { return event }
            // Keys typed here, or in Quick Look while this window is the one showing it (not the panel's).
            let previewing = QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
                && event.window === QLPreviewPanel.shared() && QLPreviewPanel.shared().dataSource === window
            guard event.window === window || previewing else { return event }
            return handle(event) ? nil : event
        }
        // A click back in the search field: Space and ← → type again (after a click on a result, they were its).
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, let window, event.window === window, let field = search.field else { return event }
            if field.bounds.contains(field.convert(event.locationInWindow, from: nil)) { search.editing() }
            return event
        }
    }

    private func removeKeyMonitor() {
        for monitor in [keyMonitor, mouseMonitor].compactMap({ $0 }) { NSEvent.removeMonitor(monitor) }
        keyMonitor = nil
        mouseMonitor = nil
    }

    /// Arrows move through the grid (← → only once you've arrowed, so they still move the cursor while you type),
    /// ↩ opens, ⌘↩ reveals, Space previews, ⌘C copies, ⌘S saves the search, Esc closes the preview or clears the
    /// search, Tab turns the suggested filter on, ⌫ in an empty field takes the last filter off.
    private func handle(_ event: NSEvent) -> Bool {
        // An input method is composing (Japanese, Chinese…): ↩, the arrows and Esc are its keys until it's done.
        if (search.field?.currentEditor() as? NSTextView)?.hasMarkedText() == true { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        let previewing = QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
        switch event.keyCode {
        case 125, 126:   // ↓ ↑
            guard modifiers.isEmpty else { return false }
            search.move(by: event.keyCode == 125 ? search.columns : -search.columns)
        case 123, 124:   // ← →
            guard modifiers.isEmpty, search.navigated || previewing else { return false }
            search.move(by: event.keyCode == 124 ? 1 : -1)
        case 36, 76:   // ↩
            guard let row = search.selectedRow else { return false }
            if modifiers == .command {
                Opener.reveal(row.url)
            } else if modifiers.isEmpty {
                search.open(row)
            } else {
                return false
            }
        // Space previews once you've arrowed or clicked to a result, or with nothing typed (a space would start
        // nothing); while you're typing words it's a space.
        case 49 where modifiers.isEmpty && (search.navigated || previewing || search.query.isEmpty)
            && search.selectedRow != nil:
            toggleQuickLook()
        case 16 where modifiers == .command:   // ⌘Y
            toggleQuickLook()
        case 18...23 where modifiers == .command:   // ⌘1 all, ⌘2…⌘6 one kind
            let kinds: [ResultGroupKind?] = [nil] + ResultGroupKind.files
            let index = [18, 19, 20, 21, 23, 22].firstIndex(of: Int(event.keyCode)) ?? 0   // key codes of 1…6
            search.filter = kinds[index]
        case 26 where modifiers == .command && app.model.hasCode:   // ⌘7: code
            search.filter = .code
        case 1 where modifiers == .command && search.isSearching && !app.savedSearches.unreadable:   // ⌘S
            saveSearch()
        case 8 where modifiers == .command:   // ⌘C
            // The selected file, as in the panel, except right after you selected some of the query's words (then
            // they're what you meant; arrowing or clicking to a result means the file).
            let textSelected = (search.field?.currentEditor()?.selectedRange.length ?? 0) > 0
            guard let row = search.selectedRow, !textSelected || search.navigated else { return false }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([row.url as NSURL])
        case 48 where modifiers.isEmpty && !search.suggestions.isEmpty:   // Tab: the first suggestion becomes a filter
            search.accept(search.suggestions[0])
        case 51 where modifiers.isEmpty && search.query.isEmpty && !search.shownTokens.isEmpty:   // ⌫, nothing typed
            search.removeLastToken()
        case 53:   // Esc
            if previewing {
                QLPreviewPanel.shared().orderOut(nil)
            } else if !search.query.isEmpty {
                search.query = ""
            } else {
                return false
            }
        default:
            return false
        }
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { updateQuickLook() }
        return true
    }

    func toggleQuickLook() {
        let panel = QLPreviewPanel.shared()!
        if QLPreviewPanel.sharedPreviewPanelExists(), panel.isVisible {
            panel.orderOut(nil)
        } else if search.selectedRow != nil {
            updateQuickLook()
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// Quick Look shows the selected result at its page or moment (the one last picked under the preview, if any).
    private func updateQuickLook() {
        window?.showInQuickLook(search.selectedRow.map(PreviewPlayback.shared.placed))
    }

    /// A result was clicked: Quick Look, when it's open, follows.
    private func selectionChanged() {
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { updateQuickLook() }
    }
}

/// A window that hands Quick Look the selected result (Space / ⌘Y).
final class QuickLookWindow: NSWindow, QLPreviewPanelDataSource, QuickLookSource {
    var previewItems: [QuickLookItem] = []
    /// Where in them Quick Look was last told to show (`showInQuickLook`).
    var previewPlace = ""

    nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { panel.dataSource = self }
    }

    nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { panel.dataSource = nil }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewItems.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        previewItems.indices.contains(index) ? previewItems[index] : nil
    }
}

/// The window's query: keyword and meaning results together after a short pause in typing, optionally of one kind.
@Observable
final class SearchModel {
    var query = "" {
        didSet { if query != oldValue { run() } }
    }
    var filter: ResultGroupKind? {
        didSet { if filter != oldValue { run() } }
    }
    private(set) var results = ResultSet.empty
    /// Results per kind for the query, whatever the filter (the counts on the kind buttons).
    private(set) var counts: [ResultGroupKind: Int] = [:]
    private(set) var hasResults = false
    /// What the window shows instead of results: "code:" alone (what to type), or code search that's off.
    private(set) var codePhase: SearchPhase?
    var selection: String?
    var showWeaker = false
    var showsPreview = true
    /// The map above the results: a pin for each result that was taken somewhere. Apple Maps draws it, so showing it
    /// sends the area in view to Apple (nothing about the files).
    var showsMap = false
    /// Only results taken inside this area of the map ("Search This Area"); with no words, every file taken there.
    var area: SearchFilter.Area? {
        didSet { if area != oldValue { run() } }
    }
    /// The filters on besides the kind and the map's area, in the order they were put on: Photos' people (each one in
    /// the picture), albums (in any of them), favorites and From, DigUp's favorites, Sensitive, Length and Shape.
    var tokens: [FilterToken] = [] {
        didSet { if tokens != oldValue { run() } }
    }
    /// The people and albums the indexed Photos libraries name (the filter menus and suggestions).
    private(set) var choices = PhotosChoices()
    /// A Photos library is searched, so its filters show.
    var searchesPhotos = false
    @ObservationIgnored private var choicesRead: Date?
    /// Where the results were taken, by path (the map's pins).
    private(set) var locations: [String: Location] = [:]
    /// You moved the selection with the arrow keys since the last edit: Space and ← → act on results then.
    private(set) var navigated = false
    /// The grid's columns right now (↑ ↓ move by a row).
    var columns = 4
    @ObservationIgnored weak var field: NSTextField?
    @ObservationIgnored private let engine: Engine
    /// What's marked ♥ in DigUp: the heart in the preview, and the Favorites filter.
    @ObservationIgnored let favorites: Favorites
    /// What you told DigUp about faces outside Photos: "This is…" and "Not …" in the preview.
    @ObservationIgnored let faceCorrections: FaceCorrectionsFile
    /// Bumped each time something is said of a face, so the preview reads its picture's faces again.
    private(set) var facesSaid = 0
    /// The settings (My devices).
    @ObservationIgnored private let model: AppModel
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var shownGeneration = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    /// While a saved search is put in the window: its words, kind, tokens and area change together, then it runs once.
    @ObservationIgnored private var runsHeld = false
    /// A result was clicked, or another moment of it picked under the preview (Quick Look, when it's open, follows).
    @ObservationIgnored var selected: () -> Void = {}

    init(engine: Engine, favorites: Favorites, faceCorrections: FaceCorrectionsFile, model: AppModel) {
        self.engine = engine
        self.favorites = favorites
        self.faceCorrections = faceCorrections
        self.model = model
    }

    /// "Shot on my devices" now: the libraries' devices with Settings → Photos → My devices' changes. The filter reads
    /// it each time it runs, so a change in Settings applies to a search that has it on.
    var myDevices: [String] {
        choices.devices(added: model.settings.myDevicesAdded, removed: model.settings.myDevicesRemoved)
    }

    /// My devices changed in Settings: a search with "Shot on my devices" on runs again.
    func myDevicesChanged() {
        if has(.shotOnMyDevices) { run() }
    }

    /// "Blur sensitive pictures" moved: a search with the Sensitive filter on runs again at the new position.
    func sensitivePositionChanged() {
        if has(.sensitive) { run() }
    }

    /// Every result shown, in order (strong ones, then the weaker ones once they're unfolded).
    var rows: [ResultRow] { results.ranked + (showWeaker ? results.weaker : []) }

    /// What the results are kept to besides their kind. DigUp's favorites are here as "some files" (the paths are
    /// looked up when the search runs, `run`).
    var searchFilter: SearchFilter {
        var filter = SearchFilter(area: area)
        for token in tokens {
            switch token {
            case .person(_, let ids, _): filter.people.append(ids)   // empty: keeps nothing (a saved one that's gone)
            case .album(_, _, let ids, _): filter.albums = (filter.albums ?? []).union(ids)
            case .photosFavorites: filter.favorites = true
            case .digupFavorites: filter.paths = []
            case .shotOnMyDevices: filter.shotOn = Set(myDevices)   // empty: still filtering (`SearchFilter.shotOn`)
            case .origin(let origin): filter.origins = [origin.rawValue]
            case .area: break
            case .sensitive: filter.sensitive = model.settings.blurSensitive.filterPosition
            case .length(let length): filter.length = length
            case .shape(let shape): filter.shape = shape
            }
        }
        return filter
    }

    /// A result was marked ♥ in DigUp or unmarked: with the Favorites filter on, the results follow.
    func favoriteToggled() {
        if has(.digupFavorites) { run() }
    }

    /// What the preview lets you say of the faces in a picture outside Photos (`FaceTelling`); nothing while the
    /// corrections file can't be read.
    var faceTelling: FaceTelling? {
        guard !faceCorrections.unreadable else { return nil }
        return FaceTelling(people: choices.people, said: facesSaid,
                           faces: { [engine] row in await engine.pictureFaces(of: row.url.path) },
                           say: { [weak self] says, person, face, row in self?.say(says, person, face: face, in: row) })
    }

    /// You said who a face in `row`'s picture is, or isn't (everyone of the name): kept beside the index, the matches
    /// made again with it, and the results and the preview follow.
    func say(_ says: FaceCorrections.Says, _ person: PhotosChoices.Person, face: Faces.Box, in row: ResultRow) {
        let saved = faceCorrections.say(says, face: face, in: row, person: .init(
            name: person.name, photos: PhotosChoices.ordered(person.photos)))
        guard saved else { return }
        Task {
            await engine.rebuildFaceMatches()
            facesSaid += 1
            run()
        }
    }

    /// The filters in the search field, in order: the tokens, then the map's area.
    var shownTokens: [FilterToken] { tokens + (area == nil ? [] : [.area]) }
    /// Filters the words being typed could name (Tab takes the first).
    var suggestions: [FilterSuggestion] {
        isCode ? [] : choices.suggestions(for: query, photos: searchesPhotos, except: shownTokens)
    }
    /// There's something to show: words typed, or a filter that lists files by itself.
    var isSearching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !searchFilter.isEmpty }

    /// A search of code: the Code filter, or "code:" typed.
    var isCode: Bool { filter == .code || CodeQuery.text(of: query) != nil }
    var selectedRow: ResultRow? { rows.first { $0.id == selection } ?? rows.first }

    /// A click on a result: like the arrow keys, it makes Space and ← → act on the results.
    func select(_ row: ResultRow) {
        selection = row.id
        navigated = true
        selected()
    }

    /// A click in the search field: keys are the text's again.
    func editing() {
        navigated = false
    }

    /// Puts the cursor in the search field (a click on the empty window lands there).
    func focusField() {
        guard let field, field.currentEditor() == nil else { return }
        field.window?.makeFirstResponder(field)
    }

    func has(_ token: FilterToken) -> Bool { shownTokens.contains { $0.id == token.id } }

    func set(_ token: FilterToken, on: Bool) {
        if token == .area {
            if !on { area = nil }
        } else if on {
            guard !has(token) else { return }
            // One From, one Length and one Shape at a time: the one picked replaces the other.
            tokens = tokens.filter { $0.choice == nil || $0.choice != token.choice } + [token]
        } else {
            tokens.removeAll { $0.id == token.id }
        }
    }

    func toggle(_ token: FilterToken) { set(token, on: !has(token)) }

    /// ⌫ in an empty field: the last filter goes.
    func removeLastToken() {
        if let last = shownTokens.last { set(last, on: false) }
    }

    /// A suggestion taken: its words leave the query, and it's on.
    func accept(_ suggestion: FilterSuggestion) {
        if query.hasSuffix(suggestion.replacing) {
            query = String(query.dropLast(suggestion.replacing.count)).trimmingCharacters(in: .whitespaces)
        }
        set(suggestion.token, on: true)
    }

    /// Reads the libraries' people and albums, again once what it has is half a minute old (an index fills in while
    /// the window is open).
    func readChoices(force: Bool = false) {
        if !force, let read = choicesRead, Date().timeIntervalSince(read) < 30 { return }
        choicesRead = Date()
        Task {
            let read = await engine.photosChoices()
            guard read != choices else { return }
            choices = read
            // The devices came with them: a search with "Shot on my devices" on reads the list again.
            if has(.shotOnMyDevices) { run() }
        }
    }

    // MARK: Saved searches

    /// The window's search as a saved search, under `name`: its words, kind, and tokens in order (the map's area
    /// among them).
    func saved(named name: String) -> SavedSearch {
        SavedSearch(id: UUID(), name: name, query: query, kind: filter, filters: shownTokens.compactMap(savedFilter),
                    saved: Date())
    }

    private func savedFilter(_ token: FilterToken) -> SavedSearch.Filter? {
        switch token {
        case .person(let name, _, let photos): .person(SavedSearch.Person(name: name, photos: photos))
        case .album(let title, let folders, _, let photos):
            .album(SavedSearch.Album(title: title, folders: folders, photos: photos))
        case .photosFavorites: .photosFavorites
        case .digupFavorites: .digupFavorites
        case .shotOnMyDevices: .from(.mine)
        // The window's From offers these two origins (`FilterMenuItem.items`).
        case .origin(let origin): SavedSearch.From(rawValue: origin.rawValue).map { .from($0) }
        case .area: area.map { .area(SavedSearch.Area($0)) }
        case .sensitive: .sensitive
        case .length(let length): .length(length)
        case .shape(let shape): .shape(shape)
        }
    }

    /// The name Save This Search… suggests: the words, then the people and albums ("beach · Tatiana Rotari ·
    /// Florida"); with neither, the other filters ("Photos Favorites · Shot on my devices").
    var suggestedName: String {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let named = shownTokens.filter {
            switch $0 {
            case .person, .album: true
            default: false
            }
        }
        let parts = (words.isEmpty ? [] : [words]) + named.map(\.title)
        return (parts.isEmpty ? shownTokens.map(\.title) : parts).joined(separator: " · ")
    }

    /// What a search saved now keeps: "“beach” · Images · Tatiana Rotari · In the map's area".
    var savedSummary: String {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return ((words.isEmpty ? [] : ["“\(words)”"]) + [filter?.title ?? "All kinds"] + shownTokens.map(\.title))
            .joined(separator: " · ")
    }

    /// Puts a saved search in the window and runs it: its words, kind, tokens and map area. Its people and albums are
    /// found by Photos' uuid in the libraries as they are now (`PhotosChoices.token(for:)`); one that's gone shows
    /// struck through and keeps nothing.
    func open(_ saved: SavedSearch) async {
        let read = await engine.photosChoices()
        choices = read
        choicesRead = Date()
        var tokens: [FilterToken] = [], area: SearchFilter.Area?
        for filter in saved.filters {
            switch filter {
            case .person(let person): tokens.append(read.token(for: person))
            case .album(let album): tokens.append(read.token(for: album))
            case .photosFavorites: tokens.append(.photosFavorites)
            case .digupFavorites: tokens.append(.digupFavorites)
            case .from(.mine): tokens.append(.shotOnMyDevices)
            case .from(.saved): tokens.append(.origin(.saved))
            case .from(.imported): tokens.append(.origin(.imported))
            case .area(let box): area = box.searchArea
            case .sensitive: tokens.append(.sensitive)
            case .length(let length): tokens.append(.length(length))
            case .shape(let shape): tokens.append(.shape(shape))
            }
        }
        runsHeld = true
        self.tokens = tokens
        self.area = area
        filter = saved.kind
        query = saved.query
        runsHeld = false
        run()
        let missing = tokens.filter(\.isMissing).count
        log("window: opened a saved search with \(saved.filters.count) filters"
            + (missing > 0 ? ", \(missing) of them not in Photos now" : ""))
    }

    /// The file in its app, at the page or moment that matched (or the one picked under the preview) when the app can
    /// be told where.
    func open(_ row: ResultRow) {
        engine.open(PreviewPlayback.shared.placed(row))
    }

    func move(by step: Int) {
        let ids = rows.map(\.id)
        guard !ids.isEmpty else { return }
        let index = selection.flatMap { ids.firstIndex(of: $0) } ?? -1
        selection = ids[max(0, min(ids.count - 1, index + step))]
        navigated = true
    }

    private func run() {
        guard !runsHeld else { return }
        readChoices()
        generation += 1
        let current = generation
        task?.cancel()
        navigated = false
        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = isCode
        let text = CodeQuery.text(of: typed) ?? typed
        codePhase = nil
        guard !typed.isEmpty || !searchFilter.isEmpty else {
            results = .empty
            counts = [:]
            hasResults = false
            locations = [:]
            shownGeneration = current
            return
        }
        if code, !engine.hasCode || text.isEmpty {
            results = .empty
            counts = [:]
            hasResults = false
            codePhase = engine.hasCode ? .codeHint : .codeOff
            shownGeneration = current
            return
        }
        let filter = self.filter, searchFilter = self.searchFilter
        if !text.isEmpty {
            engine.prewarm()
            engine.embedAhead(text, code: code)
        }
        let showAt = ContinuousClock.now + SearchPanelController.typingPause
        if code {
            task = Task {
                let vector = await engine.embedQuery(text, code: true)
                guard !Task.isCancelled, current == generation else { return }
                let hits = await engine.search(text, vector: vector, prefixLast: false, limit: 120, code: true)
                try? await Task.sleep(until: showAt, tolerance: .milliseconds(1), clock: .continuous)
                guard !Task.isCancelled, current == generation else { return }
                counts = [.code: Searcher.strongCount(hits)]
                results = ResultSet(hits, query: text)
                showWeaker = false
                if !rows.contains(where: { $0.id == selection }) { selection = rows.first?.id }
                hasResults = true
                shownGeneration = current
                log("window: code \(searchWords(text)): \(results.ranked.count) results + \(results.weaker.count) weaker")
            }
            return
        }
        task = Task {
            var searchFilter = searchFilter
            // DigUp's favorites: the files they are now (a Photos favorite's file changes when it's downloaded, and a
            // file marked ♥ may have moved, which the hearts on the results follow too).
            if searchFilter.paths != nil {
                searchFilter.paths = await favorites.paths(using: engine)
            } else {
                favorites.followMoves()
            }
            let vector = text.isEmpty ? nil : await engine.embedQuery(text)
            guard !Task.isCancelled, current == generation else { return }
            let all = await engine.search(text, vector: vector, prefixLast: false, filter: searchFilter, limit: 120)
            let shown = filter == nil ? all : await engine.search(text, vector: vector, prefixLast: false,
                                                                    kinds: filter!.kinds, filter: searchFilter,
                                                                    limit: 120)
            let located = await engine.locations(of: shown.map(\.path))
            try? await Task.sleep(until: showAt, tolerance: .milliseconds(1), clock: .continuous)
            guard !Task.isCancelled, current == generation else { return }
            var counts: [ResultGroupKind: Int] = [:]
            for hit in all.prefix(Searcher.strongCount(all)) { counts[ResultGroupKind(hit.kind), default: 0] += 1 }
            self.counts = counts
            results = ResultSet(shown, query: text)
            locations = located
            showWeaker = false
            if !rows.contains(where: { $0.id == selection }) { selection = rows.first?.id }
            hasResults = true
            shownGeneration = current
            log("window: \(searchWords(text))\(filter.map { " in \($0.title)" } ?? "")\(area == nil ? "" : " in a map area")"
                + "\(tokens.isEmpty ? "" : " with \(tokens.count) filters"): "
                + "\(results.ranked.count) results + \(results.weaker.count) weaker, \(located.count) with a place")
        }
    }

    /// The last search's results are showing (none is still on its way).
    var isSettled: Bool { shownGeneration == generation }
}

// MARK: Views

struct SearchWindowView: View {
    @Bindable var search: SearchModel
    let model: AppModel
    let app: AppController
    @State private var fieldFocused = false

    var body: some View {
        VStack(spacing: 0) {
            header.zIndex(1)   // the filter suggestions hang below it, over what's under it
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    if search.showsMap, model.hasFolders, !search.isCode {
                        ResultsMap(search: search)
                            .frame(height: 260)
                        Divider()
                    }
                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if search.showsPreview, let row = search.selectedRow, search.hasResults {
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            PreviewPane(row: row, imageSize: CGSize(width: 292, height: 230),
                                        open: { search.open(row) }, exploresMoments: true,
                                        picked: { search.selected() }, telling: search.faceTelling)
                            PreviewActions(row: PreviewPlayback.shared.placed(row), open: { search.open(row) },
                                           reveal: { Opener.reveal(row.url) }, favorites: search.favorites,
                                           toggledFavorite: { search.favoriteToggled() })
                        }
                        .padding(16)
                    }
                    .frame(width: 324)
                    .background(Color.primary.opacity(0.025))
                }
            }
            Divider()
            statusBar
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 820, minHeight: 520)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                HStack(spacing: 9) {
                    Image(systemName: search.isCode ? FileKind.code.symbol : "magnifyingglass")
                        .font(.system(size: search.isCode ? 15 : 17, weight: .semibold))
                        .foregroundStyle(Brand.gradient)
                        .frame(width: 22)
                    ForEach(search.shownTokens) { token in
                        FilterTokenView(token: token) { search.set(token, on: false) }
                    }
                    SearchField(text: $search.query, fontSize: 18, placeholder: placeholder,
                                onMake: { search.field = $0 }, onFocus: { fieldFocused = $0 })
                        .frame(minWidth: 140)
                    if !search.query.isEmpty {
                        Button {
                            search.query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear")
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 38)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06)))
                // Where typing goes, as a Mac text field shows it: a ring in the accent color while it has the cursor.
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(fieldFocused ? 0.6 : 0), lineWidth: 2))
                .animation(.easeOut(duration: 0.15), value: fieldFocused)
                .overlay(alignment: .topLeading) {
                    let suggestions = search.suggestions
                    if !suggestions.isEmpty {
                        FilterSuggestionsBar(suggestions: suggestions) { search.accept($0) }
                            .fixedSize()
                            .offset(x: 30, y: 44)   // just under the field, below the magnifier
                    }
                }
                SavedSearchesMenu(saved: app.savedSearches, canSave: search.isSearching,
                                  open: { app.searchWindow.open($0) }, save: { app.searchWindow.saveSearch() },
                                  edit: { app.searchWindow.editSavedSearches() })
                Button {
                    search.showsMap.toggle()
                } label: {
                    Image(systemName: "map")
                        .font(.system(size: 15))
                        .foregroundStyle(search.showsMap ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                }
                .buttonStyle(.plain)
                .help(search.showsMap ? "Hide Map"
                      : "Show Map: where results were taken (Apple Maps draws it, so the area in view is sent to Apple)")
                Button {
                    search.showsPreview.toggle()
                } label: {
                    Image(systemName: "sidebar.right")
                        .font(.system(size: 15))
                        .foregroundStyle(search.showsPreview ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                }
                .buttonStyle(.plain)
                .help(search.showsPreview ? "Hide Preview" : "Show Preview")
                Button {
                    app.showSettings()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Settings (⌘,)")
            }
            .padding(.leading, 78)   // beside the window buttons
            .frame(height: 52)
            .zIndex(1)   // over the chips below it, for the suggestions
            // All, the kinds and ♥ Favorites as chips, every other filter in the Filters menu: the row fits the
            // window's 1,040 points. It scrolls sideways in a window narrower than that.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    KindFilters(search: search, showsCode: model.hasCode)
                    if !search.isCode {
                        Divider().frame(height: 16).padding(.horizontal, 2)
                        Button {
                            search.toggle(.digupFavorites)
                        } label: {
                            FilterChipLabel(title: "Favorites",
                                            symbol: search.has(.digupFavorites) ? "heart.fill" : "heart",
                                            selected: search.has(.digupFavorites))
                        }
                        .buttonStyle(.plain)
                        .help("Favorites: only what you've marked ♥ in DigUp (\(search.favorites.count))")
                        .accessibilityAddTraits(search.has(.digupFavorites) ? .isSelected : [])
                        FiltersMenu(search: search)
                    }
                }
            }
            .scrollClipDisabled()
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    @ViewBuilder private var content: some View {
        if !model.hasFolders {
            VStack(spacing: 0) {
                BrandMark()
                Text("Choose folders to search").font(.system(size: 20, weight: .bold)).padding(.top, 18)
                Text("DigUp only looks where you tell it to.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
                Button("Choose Folders…") { app.chooseFolders() }
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .padding(.top, 18)
            }
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !search.isSearching {
            SearchHome(search: search, model: model, engine: app.engine)
        } else if let phase = search.codePhase {
            CodeOffOrHint(phase: phase, search: search) { app.chooseCodeFolders() }
        } else if !search.hasResults {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if search.results.isEmpty {
            let words = search.query.trimmingCharacters(in: .whitespaces)
            let onlyArea = search.tokens.isEmpty
            EmptyState(symbol: search.isCode ? FileKind.code.symbol : "magnifyingglass",
                       title: !words.isEmpty ? "No good matches for “\(words)”"
                           : onlyArea ? "Nothing taken in this area" : "Nothing fits these filters",
                       message: search.isCode ? "Try saying what the code does, or a name that's in it."
                           : !words.isEmpty ? "Try describing what's in it: what you'd see or hear, or words you remember."
                           : onlyArea ? "Move the map and search that area, or type what you're looking for."
                           : "Take a filter off (its × in the search field), or type what you're looking for.")
        } else if search.isCode {
            CodeResultsList(search: search)
        } else {
            ResultsGrid(search: search)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            if let progress = model.progress {
                ProgressView(value: progress).progressViewStyle(.circular).controlSize(.mini)
            }
            // What's indexed: a click shows the folders and their progress.
            Button(model.statusLine) { app.showSettings(.folders) }
                .buttonStyle(.plain)
                .lineLimit(1)
                .help("Folders and indexing")
            Spacer()
            if search.hasResults, search.isSearching {
                Text(model.resultsCaveat ?? resultCount).lineLimit(1)
            }
            if let version = model.updateAvailable {
                Button {
                    app.updates.checkNow()
                } label: {
                    Label("DigUp \(version) is available", systemImage: "arrow.down.circle.fill")
                        .foregroundStyle(Brand.ember)
                }
                .buttonStyle(.plain)
                .help("See what's new and update")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(height: 28)
    }

    /// Examples of what to type: code's with the Code chip on, and one of them with code search on (as the panel's).
    private var placeholder: String {
        if search.filter == .code { return "Describe the code: “retry a request with backoff”, a name in it…" }
        if !search.shownTokens.isEmpty { return "Add words…" }
        return model.hasCode ? "Describe it: “zebra in a video”, “code: retry with backoff”…"
            : "Describe it: “receipt from the hardware store”, “zebra in a video”…"
    }

    private var resultCount: String {
        let count = search.results.ranked.count
        return (count == 1 ? "1 result" : "\(count) results")
            + (search.results.weaker.isEmpty ? "" : " · \(search.results.weaker.count) weaker")
    }
}

/// All · Screenshots 4 · Images 9 · …: what the query found of each kind; click to see only that kind. With code search
/// on, Code after them: a search of code alone (as "code:" is).
private struct KindFilters: View {
    @Bindable var search: SearchModel
    var showsCode = false

    var body: some View {
        HStack(spacing: 6) {
            chip(title: "All", symbol: nil, count: nil, selected: search.filter == nil && !search.isCode) {
                search.filter = nil
            }
            ForEach(ResultGroupKind.files, id: \.self) { kind in
                chip(title: kind.title, symbol: kind.symbol, count: search.isCode ? nil : search.counts[kind],
                     selected: search.filter == kind && !search.isCode) {
                    search.filter = search.filter == kind ? nil : kind
                }
            }
            if showsCode {
                Divider().frame(height: 16).padding(.horizontal, 4)
                chip(title: "Code", symbol: FileKind.code.symbol, count: search.isCode ? search.counts[.code] : nil,
                     selected: search.isCode, shortcut: 7) {
                    search.filter = search.filter == .code ? nil : .code
                }
            }
        }
    }

    private func chip(title: String, symbol: String?, count: Int?, selected: Bool, shortcut: Int? = nil,
                      action: @escaping () -> Void) -> some View {
        let number = shortcut ?? (ResultGroupKind.files.firstIndex { $0.title == title }).map { $0 + 2 } ?? 1
        return Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.system(size: 10.5)) }
                Text(title)
                if let count, search.isSearching {
                    Text("\(count)").monospacedDigit().opacity(0.6)
                }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(selected ? AnyShapeStyle(Color.accentColor)
                                                : AnyShapeStyle(Color.primary.opacity(0.06))))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("\(title) (⌘\(number))")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The results that were taken somewhere, as pins on Apple's map; a click on one selects its result. "Search This
/// Area" keeps the results (or, with no words, every file) to the box in view. Apple Maps draws the map, so it's
/// online: the area in view is sent to Apple to draw it, and nothing about the files.
private struct ResultsMap: View {
    @Bindable var search: SearchModel
    @State private var position: MapCameraPosition = .automatic
    @State private var inView: MKCoordinateRegion?

    private struct Pin: Identifiable {
        let row: ResultRow
        let location: Location
        var id: String { row.id }
    }

    var body: some View {
        let pins = search.rows.compactMap { row in search.locations[row.id].map { Pin(row: row, location: $0) } }
        Map(position: $position, selection: selection) {
            ForEach(pins) { pin in
                Marker(pin.row.name, systemImage: pin.row.kind.symbol,
                       coordinate: CLLocationCoordinate2D(latitude: pin.location.latitude,
                                                          longitude: pin.location.longitude))
                    .tag(pin.id)
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .mapControls { MapZoomStepper() }
        .onMapCameraChange(frequency: .onEnd) { inView = $0.region }
        // New results: the map fits their pins again.
        .onChange(of: pins.map(\.id)) { _, _ in position = .automatic }
        .overlay(alignment: .top) {
            HStack(spacing: 8) {
                if pins.isEmpty {
                    Text(search.isSearching ? "None of these results says where it was taken" : "Search, or move the map")
                        .font(.system(size: 12))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.regularMaterial, in: Capsule())
                }
                if let inView {
                    Button("Search This Area") { search.area = Self.area(of: inView) }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(10)
        }
    }

    /// Selecting a pin selects its result, and the selected result's pin shows selected.
    private var selection: Binding<String?> {
        Binding(get: { search.selectedRow?.id }, set: { id in
            if let id, let row = search.rows.first(where: { $0.id == id }) { search.select(row) }
        })
    }

    /// The box in view, in degrees. A view across the 180° meridian is cut there: the box can't wrap.
    static func area(of region: MKCoordinateRegion) -> SearchFilter.Area {
        let (latitude, longitude) = (region.center.latitude, region.center.longitude)
        let (height, width) = (region.span.latitudeDelta / 2, region.span.longitudeDelta / 2)
        return SearchFilter.Area(latitudes: max(-90, latitude - height)...min(90, latitude + height),
                                 longitudes: max(-180, longitude - width)...min(180, longitude + width))
    }
}

private struct ResultsGrid: View {
    @Bindable var search: SearchModel
    private static let cell = CGSize(width: 176, height: 132)

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.cell.width, maximum: 230), spacing: 14)],
                              alignment: .leading, spacing: 18) {
                        ForEach(search.results.ranked) { row in cell(row) }
                    }
                    .padding(16)
                    if !search.results.weaker.isEmpty {
                        WeakerToggle(count: search.results.weaker.count, expanded: search.showWeaker) {
                            search.showWeaker.toggle()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18)
                        if search.showWeaker {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.cell.width, maximum: 230),
                                                         spacing: 14)], alignment: .leading, spacing: 18) {
                                ForEach(search.results.weaker) { row in cell(row).opacity(0.85) }
                            }
                            .padding(16)
                        }
                    }
                }
                .onChange(of: search.selection) { _, id in
                    if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } }
                }
            }
            .onAppear { updateColumns(geometry.size.width) }
            .onChange(of: geometry.size.width) { _, width in updateColumns(width) }
        }
    }

    private func updateColumns(_ width: CGFloat) {
        search.columns = max(1, Int((width - 32 + 14) / (Self.cell.width + 14)))
    }

    private func cell(_ row: ResultRow) -> some View {
        GridCell(row: row, selected: row.id == search.selectedRow?.id, favorite: search.favorites.contains(row))
            .id(row.id)
            .overlay(FileDragArea(url: row.url, openTitle: row.openTitle, onClick: {
                SensitiveBlur.shared.show(row)   // a click shows a blurred picture
                search.select(row)
            }, onOpen: { search.open(row) }))
    }
}

private struct GridCell: View {
    let row: ResultRow
    let selected: Bool
    /// Marked ♥ in DigUp.
    var favorite = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // A fixed box the picture fills and is clipped to: a picture's own shape must never size the cell.
            Color.primary.opacity(0.05)
                .frame(height: 132)
                .frame(maxWidth: .infinity)
                .overlay {
                    if row.kind == .audio {
                        Image(systemName: "waveform")
                            .font(.system(size: 34, weight: .light))
                            .foregroundStyle(Brand.gradient)
                    } else {
                        let hidden = SensitiveBlur.shared.hides(row)
                        MomentThumbnail(row: row, hidden: hidden)
                            .sensitiveCover(hidden, iconSize: 20)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(alignment: .topLeading) {
                if row.kind != .image && row.kind != .screenshot {
                    Image(systemName: row.kind.symbol)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(Circle().fill(.black.opacity(0.5)))
                        .padding(6)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let place = row.place { PlaceBadge(text: place, onImage: true).padding(6) }
            }
            // A recording that matched in more places than one: the preview lists them all.
            .overlay(alignment: .bottomLeading) {
                if let moments = row.momentsLabel { PlaceBadge(text: moments, onImage: true).padding(6) }
            }
            .overlay(alignment: .topTrailing) {
                if favorite {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(Circle().fill(Brand.ember.opacity(0.9)))
                        .padding(6)
                        .accessibilityHidden(true)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: selected ? 3 : 0.5)
                .padding(selected ? -3 : 0))
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(row.folder)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.kind.title), \(row.name), \(row.reason)"
            + (row.momentsLabel.map { ", \($0)" } ?? "") + (favorite ? ", in Favorites" : ""))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Code results, one under another: the file, where in its repo, the lines that matched, and why.
private struct CodeResultsList: View {
    @Bindable var search: SearchModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(search.results.ranked) { row in item(row) }
                    if !search.results.weaker.isEmpty {
                        WeakerToggle(count: search.results.weaker.count, expanded: search.showWeaker) {
                            search.showWeaker.toggle()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        if search.showWeaker {
                            ForEach(search.results.weaker) { row in item(row).opacity(0.85) }
                        }
                    }
                }
                .padding(12)
            }
            .onChange(of: search.selection) { _, id in
                if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } }
            }
            .onAppear { search.columns = 1 }
        }
    }

    private func item(_ row: ResultRow) -> some View {
        CodeResultRow(row: row, selected: row.id == search.selectedRow?.id)
            .id(row.id)
            .overlay(FileDragArea(url: row.url, openTitle: row.openTitle, onClick: { search.select(row) },
                                  onOpen: { search.open(row) }))
    }
}

private struct CodeResultRow: View {
    let row: ResultRow
    let selected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ThumbnailView(url: row.url, side: 30, iconOnly: true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if let place = row.place { PlaceBadge(text: place) }
                    Text(row.folder)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                if let excerpt = row.excerpt {
                    Text(highlighted(excerpt, size: 11))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(selected ? Color.accentColor.opacity(0.22) : Color.clear))
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Code, \(row.name), \(row.reason)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// "code:" typed without code search on (how to turn it on), or with nothing after it (what to type).
private struct CodeOffOrHint: View {
    let phase: SearchPhase
    let search: SearchModel
    let chooseFolders: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: FileKind.code.symbol)
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(Brand.gradient)
            if phase == .codeOff {
                Text("Code search is off").font(.system(size: 17, weight: .semibold))
                Text("DigUp can find code by what it does, in the folders you pick. Code gets an index of its own and "
                     + "never shows up in other searches.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                Button("Choose Code Folders…", action: chooseFolders).padding(.top, 6)
            } else {
                Text("Search your code").font(.system(size: 17, weight: .semibold))
                Text("Say what the code does, or type a name that's in it.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A grid cell's picture: the video frame or PDF page that matched (from the preview cache), else Quick Look's; veiled
/// while it's `hidden` (`SensitiveBlur`).
private struct MomentThumbnail: View {
    let row: ResultRow
    var hidden = false
    @State private var image: NSImage?
    @Environment(\.displayScale) private var scale

    var body: some View {
        Group {
            if let image {
                // A page shows its top (its title), anything else its middle.
                Image(nsImage: image.veiled(hidden)).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: row.page == nil ? .center : .top)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: row.url.path))
                    .resizable()
                    .frame(width: 56, height: 56)
            }
        }
        .task(id: row.previewKey) {
            let side: CGFloat = 230
            image = Previews.shared.cached(row, side: side)
            if image == nil { image = await Previews.shared.load(row, side: side, scale: scale) }
        }
    }
}

struct WeakerToggle: View {
    let count: Int
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                Text(expanded ? "Weaker matches" : "\(count) weaker \(count == 1 ? "match" : "matches")")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// After a search: a big quiet symbol, what happened, what to try.
private struct EmptyState: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Nothing typed yet: the app's mark (not a magnifier, which reads as a second search field), a pointer to the field
/// above, examples to click (each with the kind it finds), what's in the index, and the shortcut. A click anywhere else
/// puts the cursor in the field.
private struct SearchHome: View {
    let search: SearchModel
    let model: AppModel
    let engine: Engine
    @State private var kinds: [FileKind: Int] = [:]

    private static let examples: [(text: String, kind: ResultGroupKind)] = [
        ("a screenshot of an error message", .screenshots), ("receipt", .documents), ("whiteboard notes", .images),
        ("someone laughing", .audio), ("a dog on the beach", .video), ("slides about the budget", .documents),
    ]

    var body: some View {
        VStack(spacing: 0) {
            BrandMark()
            Text("Describe it. Dig it up.")
                .font(.system(size: 24, weight: .bold))
                .padding(.top, 18)
            Text("Type what you remember in the search field above: what's in it, what it looks or sounds like, or "
                 + "words from it.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 440)
                .padding(.top, 6)
            Text("TRY")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.tertiary)
                .padding(.top, 26)
            FlowRow(spacing: 8) {
                ForEach(examples, id: \.text) { example in
                    ExampleChip(text: example.text, kind: example.kind) { search.query = example.text }
                }
            }
            .frame(maxWidth: 560)
            .padding(.top, 8)
            VStack(spacing: 8) {
                if !kinds.isEmpty {
                    HStack(spacing: 8) {
                        KindCounts(counts: kinds)
                        Text("in \(folders)")
                    }
                } else if model.status.searchable > 0 {
                    Text("\(model.status.searchable.formatted()) files to search in \(folders)")
                }
                if let hotkey = model.hotkey {
                    HStack(spacing: 6) {
                        Keycaps(caps: hotkey.caps, size: 10)
                        Text("opens DigUp from any app")
                    }
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .padding(.top, 30)
        }
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { search.focusField() }
        .task(id: model.status.files) {
            var counts: [FileKind: Int] = [:]
            for summary in await engine.rootSummaries() { counts.merge(summary.kinds, uniquingKeysWith: +) }
            kinds = counts
        }
    }

    /// With code search on, one of code's too.
    private var examples: [(text: String, kind: ResultGroupKind)] {
        Self.examples + (model.hasCode ? [("code: where the settings are saved", .code)] : [])
    }

    private var folders: String {
        let names = model.settings.roots.map(\.lastPathComponent)
        return names.count <= 3 ? names.formatted(.list(type: .and)) : "\(names.count) folders"
    }
}

/// The app's icon with its own glow (the find in the D) spread soft around it: the window's empty states.
private struct BrandMark: View {
    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .frame(width: 84, height: 84)
            .shadow(color: Brand.moss.opacity(0.3), radius: 14, y: 6)
            .background {
                Circle()
                    .fill(RadialGradient(colors: [Brand.amber.opacity(0.22), Brand.leaf.opacity(0.08), .clear],
                                         center: .center, startRadius: 0, endRadius: 150))
                    .frame(width: 300, height: 300)
                    .allowsHitTesting(false)
            }
            .accessibilityHidden(true)
    }
}

/// An example query: the kind it finds, the words; a click searches for it.
private struct ExampleChip: View {
    let text: String
    let kind: ResultGroupKind
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: kind.symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Brand.leaf)
                Text(text)
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(Capsule().fill(Brand.leaf.opacity(hovering ? 0.2 : 0.1)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Search for “\(text)”")
        .onHover { inside in
            hovering = inside
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .onDisappear { if hovering { NSCursor.pop() } }
    }
}

/// Lays children out in rows, wrapping like text.
struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews) {
            var x = bounds.minX + (bounds.width - row.width) / 2
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> [(items: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(items: [Int], width: CGFloat, height: CGFloat)] = []
        var current: (items: [Int], width: CGFloat, height: CGFloat) = ([], 0, 0)
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.items.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.items.isEmpty {
                rows.append(current)
                current = ([index], size.width, size.height)
            } else {
                current = (current.items + [index], needed, max(current.height, size.height))
            }
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }
}
