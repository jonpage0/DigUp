import AppKit
import DigUpKit
import Observation
import SwiftUI

enum SettingsTab: String, CaseIterable {
    case general, shortcuts, ai, folders, photos, code, storage

    var title: String {
        switch self {
        case .general: "General"
        case .shortcuts: "Shortcuts"
        case .ai: "AI apps"
        case .folders: "Folders"
        case .photos: "Photos"
        case .code: "Code"
        case .storage: "Storage"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .shortcuts: "command"
        case .ai: "sparkles"
        case .folders: "folder"
        case .photos: "photo.on.rectangle.angled"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .storage: "internaldrive"
        }
    }
}

/// Settings, the way Mac apps lay them out: a toolbar of tabs, and the window sized to each one. Folders is also where
/// the index shows how far along it is, folder by folder.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    let state: SettingsState
    /// Folders → Add Folders…, a sheet on this window.
    let addSheet: AddFoldersController
    /// Code → Add Folders… (code search's folders), a sheet on this window.
    let codeSheet: AddFoldersController
    private unowned let app: AppController
    private var window: NSWindow?
    private var tabs: NSTabViewController?

    init(app: AppController) {
        self.app = app
        state = SettingsState(app: app)
        addSheet = AddFoldersController(app: app)
        codeSheet = AddFoldersController(app: app, code: true)
        super.init()
        state.addFolders = { [weak self] in self?.addFolders() }
        state.addCodeFolders = { [weak self] in self?.addCodeFolders() }
        for sheet in [addSheet, codeSheet] {
            sheet.onAdded = { [weak self] in
                guard let self else { return }
                Task { await self.state.refresh() }
            }
        }
    }

    /// Opens Add Folders on the Folders tab.
    func addFolders() {
        addSheet.begin(on: window)
    }

    /// Opens the code folders' sheet on the Code tab.
    func addCodeFolders() {
        codeSheet.begin(on: window)
    }

    var isVisible: Bool { window?.isVisible == true }

    func show(_ tab: SettingsTab = .general) {
        let window = self.window ?? makeWindow()
        tabs?.selectedTabViewItemIndex = SettingsTab.allCases.firstIndex(of: tab) ?? 0
        state.tab = tab
        Task { await state.refresh() }
        app.present(window)
    }

    var selectedTab: SettingsTab { state.tab }

    private func makeWindow() -> NSWindow {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.transitionOptions = [.allowUserInteraction]
        for tab in SettingsTab.allCases {
            let controller = NSHostingController(rootView: SettingsPane(tab: tab, state: state))
            controller.sizingOptions = .preferredContentSize
            controller.title = tab.title   // the window takes the selected tab's title
            let item = NSTabViewItem(viewController: controller)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            item.identifier = tab.rawValue
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.tabs = tabs
        self.window = window
        state.selectTab = { [weak self] tab in
            self?.tabs?.selectedTabViewItemIndex = SettingsTab.allCases.firstIndex(of: tab) ?? 0
        }
        return window
    }

    func windowWillClose(_ notification: Notification) {
        addSheet.end()
        codeSheet.end()
        window?.contentViewController = nil
        window = nil
        tabs = nil
        app.windowClosed()
    }

    func snapshot(to url: URL) throws {
        try Snapshot.write(window, to: url)
    }
}

@Observable
final class SettingsState {
    var tab = SettingsTab.general
    private(set) var summaries: [Engine.RootSummary]?
    private(set) var codeSummaries: [Engine.RootSummary] = []
    private(set) var indexSize: Int64 = 0
    private(set) var codeIndexSize: Int64 = 0
    var launchAtLogin = false
    var loginProblem: String?
    var checksForUpdates = false
    /// The last calls AI apps made through `digup mcp` (AI apps), oldest first.
    private(set) var aiCalls: [AICall] = []
    /// How many of the index's pictures are rated and how many wait (General), and whether the detector is installed.
    private(set) var ratings = (rated: 0, waiting: 0)
    private(set) var detectorInstalled = false
    @ObservationIgnored let app: AppController
    @ObservationIgnored var selectTab: (SettingsTab) -> Void = { _ in }
    @ObservationIgnored var addFolders: () -> Void = {}
    @ObservationIgnored var addCodeFolders: () -> Void = {}

    init(app: AppController) {
        self.app = app
    }

    @ObservationIgnored private var lastRefresh = Date.distantPast
    @ObservationIgnored private var refreshPending = false

    var model: AppModel { app.model }

    func refresh() async {
        lastRefresh = Date()
        launchAtLogin = app.launchesAtLogin
        checksForUpdates = app.updates.automaticallyChecks
        indexSize = app.engine.indexSize
        refreshAICalls()
        detectorInstalled = SensitiveModel.isInstalled(in: model.settings.modelsDirectory)
        ratings = await app.engine.sensitiveCounts()
        codeIndexSize = app.engine.codeIndexSize
        await refreshSpeech()
        codeSummaries = await app.engine.rootSummaries(code: true)
        summaries = await app.engine.rootSummaries()
        // The Photos tab's counts follow indexing as the folders' do (its listings and access are looked at when it shows).
        if !libraries.isEmpty {
            let counts = await app.engine.summaries(of: libraries.map(\.url.path))
            for (index, summary) in counts.enumerated() where index < libraries.count { libraries[index].summary = summary }
        }
        faces = await app.engine.faceCounts()
    }

    /// The index changed: refresh the folder counts, at most every 2 s while files are being indexed.
    func statusChanged() {
        guard !refreshPending else { return }
        refreshPending = true
        let wait = max(0, 2 - Date().timeIntervalSince(lastRefresh))
        Task {
            try? await Task.sleep(for: .seconds(wait))
            refreshPending = false
            await refresh()
        }
    }

    /// Ready to be drawn (debug snapshots wait for this).
    var isLoaded: Bool { summaries != nil }

    /// How many of AI apps' last calls the AI apps tab shows.
    static let aiCallsShown = 20

    func refreshAICalls() {
        aiCalls = AICall.last(Self.aiCallsShown, in: model.settings.indexDirectory)
    }

    // MARK: Speech

    /// parakeet-mlx and the ffmpeg it needs, as last looked for (`Speech`): with both, what's said in recordings on this
    /// Mac is read.
    private(set) var parakeet = Speech.parakeet
    private(set) var ffmpeg = Speech.ffmpeg
    /// The recordings on this Mac read before what's said in them was (`IndexStore.recordingsWithoutSpeech`), how long
    /// they play, and how long reading them again takes here, their frames and sound with their speech (`MeasuredCosts`).
    private(set) var unheard: (files: Int, seconds: Double, reading: Double) = (0, 0, 0)

    func refreshSpeech() async {
        parakeet = Speech.parakeet
        ffmpeg = Speech.ffmpeg
        let recordings = await app.engine.recordingsWithoutSpeech()
        let costs = MeasuredCosts.load(from: model.settings.indexDirectory).costs
        unheard = (recordings.count, recordings.reduce(0) { $0 + $1.seconds }, recordings.reduce(0) { total, recording in
            total + recording.seconds * ((recording.kind == .audio ? costs.audioSecond : costs.videoSecond)
                                         + costs.speechSecond)
        })
    }

    // MARK: Photos

    /// A Photos library the Photos tab offers: searched or not, what's indexed of it, what its last listing found, and
    /// whether macOS lets DigUp in.
    struct Library: Identifiable {
        let url: URL
        var searched: Bool
        /// The chosen folder it's searched as part of (Pictures), when it isn't chosen on its own.
        var within: String?
        var summary: Engine.RootSummary?
        var listing: PhotosLibrary.ListingSummary?
        var access: PhotosLibrary.Access?
        var estimate: FolderEstimate?
        var id: String { url.path }
    }

    private(set) var libraries: [Library] = []
    private(set) var osxphotos = PhotosLibrary.osxphotos
    /// The Photos tab has looked at its libraries once (debug snapshots wait for this).
    private(set) var photosLoaded = false
    /// The devices the indexed libraries' pictures were taken with (the "My devices" list).
    private(set) var cameras: [IndexStore.PhotosCamera] = []
    /// What the index knows of faces: the recognizer, and the pictures outside Photos that show someone.
    private(set) var faces: IndexStore.FaceCounts?

    /// "Shot on my devices", as the From menu uses it.
    var myDevices: [String] {
        PhotosChoices(people: [], albums: [], cameras: cameras)
            .devices(added: model.settings.myDevicesAdded, removed: model.settings.myDevicesRemoved)
    }

    /// The devices My devices → Edit… offers.
    var deviceChoices: [IndexStore.PhotosCamera] {
        PhotosChoices(people: [], albums: [], cameras: cameras)
            .deviceChoices(added: model.settings.myDevicesAdded, removed: model.settings.myDevicesRemoved)
    }

    func isMine(_ camera: IndexStore.PhotosCamera) -> Bool {
        camera.isMine(added: model.settings.myDevicesAdded, removed: model.settings.myDevicesRemoved)
    }
    @ObservationIgnored private var estimating: [Process] = []

    /// The Photos tab, when it shows: osxphotos looked for again, each library's counts and last listing, whether macOS
    /// lets DigUp in (asking may bring up macOS's question, so only here), and for one not searched, what reading it
    /// would take.
    func refreshPhotos() async {
        osxphotos = PhotosLibrary.osxphotos
        let urls = app.photosLibraries
        let settings = model.settings
        let selection = FolderSelection(chosen: settings.roots.map(\.path), skipped: settings.excludedFolders.map(\.path))
        let summaries = await app.engine.summaries(of: urls.map(\.path))
        let index = settings.indexDirectory
        var found: [Library] = []
        for (url, summary) in zip(urls, summaries) {
            let searched = selection.isSearched(url.path)
            let within = selection.searchedAs(url.path).flatMap { $0 == url.path ? nil : $0 }
            let (listing, access) = await Task.detached(priority: .utility) {
                (PhotosLibrary.lastListing(of: url.path, keptIn: index), PhotosLibrary.access(url.path))
            }.value
            found.append(Library(url: url, searched: searched, within: within, summary: summary, listing: listing,
                                 access: access, estimate: libraries.first { $0.id == url.path }?.estimate))
        }
        libraries = found
        cameras = await app.engine.photosChoices().cameras
        faces = await app.engine.faceCounts()
        photosLoaded = true
        estimating.removeAll { !$0.isRunning }
        let unestimated = found.filter { !$0.searched && $0.estimate == nil && $0.access == .allowed }.map(\.url)
        guard osxphotos != nil, !unestimated.isEmpty, estimating.isEmpty else { return }
        if let helper = Estimates.run(unestimated, update: { [weak self] estimate in
            guard let self, let index = libraries.firstIndex(where: { $0.id == estimate.folder }) else { return }
            libraries[index].estimate = estimate
        }) {
            estimating.append(helper)
        }
    }

    func setLibrary(_ library: Library, on: Bool) {
        app.setLibrary(library.url, on: on)
        Task {
            await refreshPhotos()
            await refresh()
        }
    }
}

/// One tab's content, at the width every tab shares.
private struct SettingsPane: View {
    let tab: SettingsTab
    let state: SettingsState
    /// The content's own height. The window is that tall up to what the screen has room for, and scrolls past it (a
    /// long list of folders ran it off the screen, Add Folders… with it).
    @State private var height: CGFloat?

    var body: some View {
        ScrollView(.vertical) {
            Group {
                switch tab {
                case .general: GeneralSettings(state: state)
                case .shortcuts: ShortcutsSettings(state: state)
                case .ai: AIAppsSettings(state: state)
                case .folders: FolderSettings(state: state)
                case .photos: PhotosSettings(state: state)
                case .code: CodeSettings(state: state)
                case .storage: StorageSettings(state: state)
                }
            }
            .frame(width: 580)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: 580, height: height.map { min($0, Self.tallest) })
    }

    /// The screen's room below the menu bar, less the window's title bar and tabs and a margin.
    private static var tallest: CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 800) - 140
    }
}

private struct GeneralSettings: View {
    @Bindable var state: SettingsState

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { state.launchAtLogin }, set: { on in
                    state.loginProblem = state.app.setLaunchAtLogin(on)
                    state.launchAtLogin = state.app.launchesAtLogin
                })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Open DigUp when you log in")
                        Text(state.loginProblem ?? "So the shortcut always works.")
                            .font(.system(size: 11))
                            .foregroundStyle(state.loginProblem == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                    }
                }
            }
            Section {
                Toggle(isOn: Binding(get: { state.checksForUpdates }, set: { on in
                    state.app.updates.automaticallyChecks = on
                    state.checksForUpdates = on
                })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Check for updates automatically")
                        Text("Once a day DigUp asks GitHub for its newest version; nothing about your files is sent. "
                             + "Updates install with one click.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                LabeledContent {
                    Button("Check Now") { state.app.updates.checkNow() }
                } label: {
                    Text(state.model.updateAvailable.map { "DigUp \($0) is available" }
                         ?? "DigUp \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                }
            }
            SensitiveSettings(state: state)
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }
}

/// General → Sensitive pictures: "Blur sensitive pictures" (approved with `sensitive_scores`, 2026-10-22), and how far
/// the detector has got, or how to make it while it isn't installed.
private struct SensitiveSettings: View {
    @Bindable var state: SettingsState

    var body: some View {
        Section {
            Picker(selection: Binding(get: { state.model.settings.blurSensitive },
                                      set: { state.app.setBlurSensitive($0) })) {
                ForEach(SensitivePosition.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Blur sensitive pictures")
                    Text(Self.detail(state.model.settings.blurSensitive))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if state.detectorInstalled {
                LabeledContent("Pictures rated") {
                    Text(state.ratings.rated.formatted()
                         + (state.ratings.waiting > 0 ? " · \(state.ratings.waiting.formatted()) waiting" : ""))
                        .monospacedDigit()
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("The detector isn't installed").font(.system(size: 13, weight: .medium))
                    }
                    Text("Pictures read from now on aren't rated: they aren't blurred or kept by the Sensitive "
                         + "filter, and AI apps don't see them unless you let them see pictures rated sensitive. "
                         + "Pictures rated before keep their ratings. To install it, run this in Terminal from DigUp's "
                         + "source folder; it goes into \(folder):")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(command)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        } header: {
            Text("Sensitive pictures")
        } footer: {
            Text("Each picture is rated as it's read, on this Mac (Freepik's detector), and the ones read before once. "
                 + "A blurred picture shows when you click it; Quick Look shows it as it is. Pictures not rated yet "
                 + "aren't blurred. It misses tiny nudes inside screenshots and figures far away, and sometimes flags "
                 + "skin-toned close-ups and shirtless men.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Where the detector goes: the models folder's sensitive/.
    private var folder: String { tildePath(SensitiveModel.folder(in: state.model.settings.modelsDirectory).path) }

    /// The command that makes it, told the models folder when it isn't the usual one (as the script reads it).
    private var command: String {
        let models = state.model.settings.modelsDirectory
        guard models.standardizedFileURL != ModelFiles.installed.standardizedFileURL else {
            return SensitiveModel.makeCommand
        }
        return "DIGUP_MODELS=\(AIClientSetup.shellQuoted(models.path)) \(SensitiveModel.makeCommand)"
    }

    /// What each position blurs, with what ADULT-CONTENT-EVAL.md measured it catches.
    static func detail(_ position: SensitivePosition) -> String {
        switch position {
        case .off: "Pictures show as they are. The Sensitive filter, in the search window's Filters menu, keeps the "
            + "revealing ones."
        case .anythingRevealing: "Swimwear, lingerie and anything more, even when the detector isn't sure: nearly "
            + "every nude picture, and the most ordinary pictures blurred with them."
        case .revealing: "Revealing pictures the detector is fairly sure of: about 9 in 10 nude pictures."
        case .nudityOnly: "Nudity and explicit pictures: most nude pictures, and the fewest ordinary ones blurred."
        }
    }
}

/// Shortcuts: the one that opens DigUp from any app, the keys for what you do with a result, in the panel and the
/// window (`SearchPanelController.handle`, `SearchWindowController.handle`, the preview's buttons), and what can be
/// typed in the search field besides words (`RequiredWords`).
private struct ShortcutsSettings: View {
    @Bindable var state: SettingsState

    /// What a key does, and where (both, or only the panel or the window).
    private struct Key: Identifiable {
        let caps: [String]
        /// Said aloud for the caps ("Command Return").
        let spoken: String
        let action: String
        var id: String { spoken }
    }

    private static let results: [Key] = [
        Key(caps: ["↩"], spoken: "Return", action: "Open it (a Photos picture opens in Photos)"),
        Key(caps: ["⌘", "↩"], spoken: "Command Return", action: "Show it in Finder, or in Photos"),
        Key(caps: ["Space"], spoken: "Space", action: "Quick Look, at the page or moment that matched; Space again closes it "
            + "(once you've arrowed or clicked to a result, or with nothing typed)"),
        Key(caps: ["⌘", "Y"], spoken: "Command Y", action: "Quick Look, while you're still typing"),
        Key(caps: ["↑", "↓"], spoken: "Up and Down arrows", action: "Move through the results (Quick Look follows)"),
        Key(caps: ["⌘", "C"], spoken: "Command C", action: "Copy the file, to paste into a folder, a chat or a mail"),
        Key(caps: ["⌘", "D"], spoken: "Command D", action: "Add it to DigUp's Favorites, or take it off"),
        Key(caps: ["Esc"], spoken: "Escape", action: "Close Quick Look; then clear the search (the window) or close the panel"),
    ]

    private static let window: [Key] = [
        Key(caps: ["←", "→"], spoken: "Left and Right arrows", action: "The result beside it, once you've arrowed or clicked"),
        Key(caps: ["⌘", "1"], spoken: "Command 1", action: "All kinds"),
        Key(caps: ["⌘", "2…6"], spoken: "Command 2 to 6",
            action: "Only screenshots, images, documents, video or audio"),
        Key(caps: ["⌘", "7"], spoken: "Command 7", action: "Code (when code search is on)"),
        Key(caps: ["Tab"], spoken: "Tab", action: "Take the suggested filter (a person, an album) for the words you typed"),
        Key(caps: ["⌫"], spoken: "Delete", action: "With nothing typed, take the last filter off"),
        Key(caps: ["⌘", "S"], spoken: "Command S",
            action: "Save this search, with its filters (the Saved menu, the bookmark beside the field, opens it again)"),
        Key(caps: ["⌘", ","], spoken: "Command comma", action: "Settings"),
    ]

    private static let panel: [Key] = [
        Key(caps: ["⌘", "O"], spoken: "Command O", action: "The same search in the search window, for a bigger look"),
        Key(caps: ["Tab"], spoken: "Tab",
            action: "Open the saved search whose name you're typing in the search window (↩ too, before you've "
                + "arrowed to a result)"),
    ]

    /// What the search field reads besides words: a required word or phrase (`RequiredWords`).
    private static let syntax: [(typed: String, meaning: String)] = [
        ("+beach", "Every result must have the word: in its words (its name, its text, what Photos knows, what's "
            + "said) or by what it shows. All the words still rank the results."),
        ("+\"red car\"", "The same for a phrase: its words one after another."),
    ]

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    ShortcutRecorder(combo: state.model.hotkey, apply: { state.app.setHotkey($0) },
                                     listening: { state.app.hotkeyRecording($0) }, capSize: 13)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Search shortcut")
                        Text("Opens the search panel from any app.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            // What can be typed, near the top: it's how a search is made, so it shouldn't need a scroll to find.
            Section {
                ForEach(Self.syntax, id: \.typed) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(item.typed)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(width: 96, alignment: .leading)
                        Text(item.meaning)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(item.typed): \(item.meaning)")
                }
            } header: {
                Text("Search syntax")
            } footer: {
                Text("In the search field a required word is highlighted; delete its + and it's an ordinary word "
                     + "again. You can also right-click a word (or select several) and choose Require.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            keys(Self.results, header: "With a result selected, in the panel and the window")
            keys(Self.window, header: "In the search window")
            keys(Self.panel, header: "In the panel")
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }

    private func keys(_ keys: [Key], header: String) -> some View {
        Section {
            ForEach(keys) { key in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Keycaps(caps: key.caps, size: 11)
                        .frame(width: 96, alignment: .leading)
                    Text(key.action)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(key.spoken): \(key.action)")
            }
        } header: {
            Text(header)
        }
    }
}

private struct FolderSettings: View {
    @Bindable var state: SettingsState
    @State private var removing: Engine.RootSummary?

    var body: some View {
        Form {
            Section {
                IndexProgress(model: state.model) { state.app.engine.setPaused(!state.model.status.paused) }
            }
            Section {
                if let summaries = state.summaries {
                    if summaries.isEmpty {
                        Text("No folders yet. Add the ones DigUp should search.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(summaries) { summary in
                        FolderStatusRow(summary: summary) { removing = summary }
                    }
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                }
            } header: {
                Text("Folders to search")
            } footer: {
                HStack {
                    Button(action: state.addFolders) {
                        Label("Add Folders…", systemImage: "plus")
                    }
                    Spacer()
                }
            }
            Section {
                ForEach(state.model.settings.excludedFolders, id: \.path) { folder in
                    HStack {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: folder.path))
                            .resizable()
                            .frame(width: 18, height: 18)
                        Text(tildePath(folder.path)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button {
                            state.app.setExcluded(state.model.settings.excludedFolders.filter { $0 != folder })
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Search this folder again")
                    }
                }
                if state.model.settings.excludedFolders.isEmpty {
                    Text("None. Code projects, app bundles and caches are skipped anyway (code has its own tab).")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Skip these folders")
            } footer: {
                HStack {
                    Button {
                        state.app.pickFolders(for: NSApp.keyWindow, prompt: "Skip") { folders in
                            guard !folders.isEmpty else { return }
                            state.app.setExcluded(state.model.settings.excludedFolders
                                + folders.filter { !state.model.settings.excludedFolders.contains($0) })
                        }
                    } label: {
                        Label("Skip a Folder…", systemImage: "plus")
                    }
                    Spacer()
                }
            }
            Section {
                TypeExclusions(types: state.model.settings.excludedTypes) { state.app.setExcludedTypes($0) }
            } header: {
                Text("Skip these file types")
            } footer: {
                Text("DigUp only reads pictures, PDFs, documents (txt, md, rtf, docx, odt, html), audio and video here; "
                     + "code is read only in the code folders (the Code tab). Keys, certificates and password files are "
                     + "never read, nor are hidden folders like ~/.ssh.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Toggle(isOn: Binding(get: { state.model.settings.indexOnBattery },
                                     set: { state.app.setIndexOnBattery($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(AppSettings.batteryTitle)
                        Text(AppSettings.batteryDetail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: Binding(get: { state.model.settings.indexHoursOn }, set: { on in
                    state.app.setIndexHours(on: on, hours: state.model.settings.indexHours)
                })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Index only at set hours")
                        Text("Files are read only between these times, and what changed meanwhile is picked up when "
                             + "they begin. Search works all day.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if state.model.settings.indexHoursOn {
                    LabeledContent("From") {
                        HStack(spacing: 6) {
                            DatePicker("From", selection: time(\.start), displayedComponents: .hourAndMinute)
                                .labelsHidden()
                            Text("to")
                            DatePicker("To", selection: time(\.end), displayedComponents: .hourAndMinute)
                                .labelsHidden()
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .onChange(of: state.model.status) { state.statusChanged() }
        .confirmationDialog(removalTitle, isPresented: Binding(get: { removing != nil },
                                                               set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) {
                guard let removing else { return }
                state.app.removeFolder(URL(fileURLWithPath: removing.path))
                Task { await state.refresh() }
            }
        } message: {
            Text("Its \(removing?.files.formatted() ?? "") files leave the index. Adding it back later indexes them "
                 + "again.")
        }
    }

    private var removalTitle: String {
        "Stop searching “\(removing.map { ($0.path as NSString).lastPathComponent } ?? "")”?"
    }

    /// One end of the set hours, as a time of day for a date picker.
    private func time(_ end: KeyPath<IndexHours, Int>) -> Binding<Date> {
        Binding(get: {
            let minute = state.model.settings.indexHours[keyPath: end]
            return Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: Date()) ?? Date()
        }, set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            let hours = state.model.settings.indexHours
            state.app.setIndexHours(on: true, hours: end == \IndexHours.start ? IndexHours(start: minute, end: hours.end)
                                                                              : IndexHours(start: hours.start, end: minute))
        })
    }
}

/// Extensions typed as "heic, txt": applied on Return or when the field loses focus.
private struct TypeExclusions: View {
    let types: [String]
    let apply: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Extensions", text: $text, prompt: Text("e.g. heic, txt"))
            .labelsHidden()
            .focused($focused)
            .onSubmit { apply(text) }
            .onChange(of: focused) { _, now in if !now { apply(text) } }
            .onAppear { text = types.joined(separator: ", ") }
            .onChange(of: types) { _, now in text = now.joined(separator: ", ") }
    }
}

/// What the index is doing, with Pause/Resume.
private struct IndexProgress: View {
    let model: AppModel
    let togglePause: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(model.statusLine).font(.system(size: 13, weight: .semibold))
                if let progress = model.progress {
                    ProgressView(value: progress).controlSize(.small)
                }
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.hasFolders {
                Button(model.status.paused ? "Resume" : "Pause", action: togglePause)
            }
        }
    }

    /// "357 of 365 files searchable · 8 waiting · 2 long files to finish"
    private var detail: String {
        let status = model.status
        var text = "\(status.searchable.formatted()) of \(status.files.formatted()) files searchable"
        if status.pending > 0 { text += " · \(status.pending.formatted()) waiting" }
        if status.unfinished > 0 {
            text += " · \(status.unfinished.formatted()) long \(status.unfinished == 1 ? "file" : "files") to finish"
        }
        if model.download.isActive { text += " · model \(model.download.progressText)" }
        return text
    }
}

private struct FolderStatusRow: View {
    let summary: Engine.RootSummary
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: summary.missing ? "/Volumes" : summary.path))
                .resizable()
                .frame(width: 32, height: 32)
                .opacity(summary.missing ? 0.5 : 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text((summary.path as NSString).lastPathComponent).font(.system(size: 13, weight: .semibold))
                    if summary.missing || summary.unreadable {
                        Text(summary.missing ? "Not connected" : "No access")
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.orange.opacity(0.2)))
                    }
                    if summary.unreadable {
                        Button("Allow in Settings…", action: openFolderPrivacySettings)
                            .buttonStyle(.link)
                            .font(.system(size: 11))
                    }
                }
                Text(tildePath(summary.path))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !summary.kinds.isEmpty {
                    KindCounts(counts: summary.kinds).padding(.top, 1)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(summary.missing || summary.unreadable ? "Kept for when it's back"
                     : "\(summary.indexed.formatted()) of \(summary.files.formatted()) indexed")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                if !states.isEmpty {
                    Text(states).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Button(action: remove) {
                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Stop searching this folder")
            .accessibilityLabel("Remove \((summary.path as NSString).lastPathComponent)")
        }
        .padding(.vertical, 2)
    }

    private var states: String {
        [summary.pending > 0 ? "\(summary.pending.formatted()) waiting" : nil,
         summary.unfinished > 0
            ? "\(summary.unfinished.formatted()) long \(summary.unfinished == 1 ? "file" : "files") to finish" : nil,
         summary.skipped > 0 ? "\(summary.skipped.formatted()) skipped" : nil,
         summary.failed > 0 ? "\(summary.failed.formatted()) couldn't be read" : nil].compactMap { $0 }
            .joined(separator: " · ")
    }
}

private struct StorageSettings: View {
    let state: SettingsState

    var body: some View {
        Form {
            Section {
                LabeledContent("EmbeddingGemma 2") {
                    Text("Google · Apache 2.0 · 865 MB")
                }
                LabeledContent("Status") {
                    HStack(spacing: 8) {
                        Text(state.model.download.isReady ? "Downloaded" : state.model.download.progressText)
                        switch state.model.download.phase {
                        case .needed, .failed:
                            Button("Download") { state.model.download.start() }.controlSize(.small)
                            Button("Use Files…") { state.model.download.chooseFiles(for: NSApp.keyWindow) }
                                .controlSize(.small)
                        default:
                            EmptyView()
                        }
                    }
                }
                LabeledContent("Location") {
                    PathButton(url: state.model.settings.modelsDirectory)
                }
            } header: {
                Text("Model")
            } footer: {
                if !state.model.download.isReady {
                    HStack(alignment: .firstTextBaseline) {
                        Text("If your network blocks Hugging Face, download the two files on another network and "
                             + "click Use Files… to choose them. DigUp checks them before it uses them.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Copy Links") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(ModelDownload.links, forType: .string)
                        }
                        .controlSize(.small)
                        .help("Copies the addresses of the two files")
                    }
                }
            }
            Section {
                SpeechStatus(state: state)
            } header: {
                Text("Speech")
            } footer: {
                Text("What's said in recordings on this Mac is found by its words and by what it means, and shows under "
                     + "its moment. parakeet-mlx runs NVIDIA's Parakeet TDT 0.6B v3 (25 European languages) on this "
                     + "Mac, and downloads it the first time (\(roughBytes(Double(Speech.modelBytes)))). Recordings "
                     + "indexed before it was found get one more pass, by themselves; a video that's only in iCloud is "
                     + "read once it's downloaded.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Index") {
                LabeledContent("Size on disk", value: bytes(state.indexSize))
                if state.model.hasCode {
                    LabeledContent("Code index", value: bytes(state.codeIndexSize))
                }
                LabeledContent("Location") {
                    PathButton(url: state.model.settings.indexDirectory)
                }
            }
            Section("Privacy") {
                Text("DigUp reads the folders you choose and keeps what it learns in its index, on this Mac. "
                     + "It goes online only to download its model, once, and to check for updates (General), "
                     + "which sends nothing about your files. parakeet-mlx, once you install it, downloads its speech "
                     + "model once too.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Text("DigUp \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") · "
                     + "EmbeddingGemma 2 by Google (Apache 2.0), run by llama.cpp (MIT). Speech: Parakeet TDT 0.6B v3 "
                     + "by NVIDIA (CC BY 4.0), run by parakeet-mlx (Apache 2.0).")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }
}

/// Storage → Speech: parakeet-mlx, which reads what's said in recordings on this Mac (`Speech`), found or how to install
/// it, and how long the first pass over the recordings indexed before takes.
private struct SpeechStatus: View {
    let state: SettingsState

    var body: some View {
        if let path = state.parakeet, state.ffmpeg != nil {
            LabeledContent("parakeet-mlx") {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(tildePath(path)).lineLimit(1).truncationMode(.middle)
                }
            }
            let unheard = state.unheard
            if unheard.files > 0 {
                LabeledContent("First pass") {
                    Text("\(unheard.files == 1 ? "1 recording" : "\(unheard.files.formatted()) recordings") indexed "
                         + "before, \(roughDuration(unheard.seconds)) of sound · \(approximately(unheard.reading))")
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(state.parakeet == nil ? "parakeet-mlx isn't installed" : "ffmpeg isn't installed")
                        .font(.system(size: 13, weight: .medium))
                }
                Text("DigUp reads what's said in recordings through parakeet-mlx, a free tool you install once, in "
                     + "Terminal, with ffmpeg, which it needs. Until then recordings are found by what's seen and heard "
                     + "in them.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                InstallCommand(command: state.parakeet == nil ? Speech.installCommand : Speech.ffmpegInstallCommand,
                               about: InstallCommand.parakeet, checkAgain: { Task { await state.refreshSpeech() } })
            }
        }
    }
}

/// Photos: the libraries DigUp can search (each on or off, with what's indexed of it and what its last listing left
/// out and why), osxphotos, which reads them, and what comes along from Photos.
private struct PhotosSettings: View {
    @Bindable var state: SettingsState
    @State private var editingDevices = false

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Search your Photos library").font(.system(size: 13, weight: .semibold))
                    Text("Its pictures are found by what they show, as any picture is, and by what Photos knows that "
                         + "no picture shows: the people and pets you've named, places, titles, captions, keywords, "
                         + "albums and Photos' own labels, as in “Tati at the beach”. Results open in Photos.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Section {
                if let path = state.osxphotos {
                    LabeledContent("osxphotos") {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            Text(tildePath(path)).lineLimit(1).truncationMode(.middle)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            Text("osxphotos isn't installed").font(.system(size: 13, weight: .medium))
                        }
                        Text("DigUp reads Photos libraries through osxphotos, a free tool you install once, in "
                             + "Terminal. Until then a library is skipped, as an app would be.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        InstallCommand(command: PhotosLibrary.installCommand, about: InstallCommand.osxphotos,
                                       checkAgain: { Task { await state.refreshPhotos() } })
                    }
                }
            } header: {
                Text("Reader")
            }
            Section {
                if !state.photosLoaded {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                } else if state.libraries.isEmpty {
                    Text("No Photos library in Pictures. To search one kept elsewhere, add it in Folders → Add "
                         + "Folders… (it can be chosen like a folder).")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(state.libraries) { library in
                    LibraryRow(library: library, set: { state.setLibrary(library, on: $0) })
                }
            } header: {
                Text("Libraries")
            } footer: {
                Text("Each picture is read as Photos shows it, edited or not; when the original is only in iCloud, "
                     + "from Photos' own preview, and a video only in iCloud from the stills Photos keeps of it "
                     + "(Download Original, on a result, has Photos get the original). Left out: what's in Recently "
                     + "Deleted, the shots of a burst nobody picked, shared albums, and Shared with You items not saved "
                     + "to the library. Your pictures, and what Photos knows about them, are never changed.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Toggle(isOn: Binding(get: { state.model.settings.includeHiddenPhotos },
                                     set: { state.app.setIncludeHiddenPhotos($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Include what's hidden in Photos")
                        Text("Its Hidden album. They show in DigUp's results like any picture; Photos may ask for Touch "
                             + "ID or your password when one is opened there.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Section {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Faces outside Photos")
                        Text(facesDetail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Text(state.faces?.recognizer == nil ? "Off" : "On").foregroundStyle(.secondary)
                }
            } footer: {
                Text("People ▾ also keeps your other pictures (Downloads, the Desktop, anywhere DigUp searches) that show "
                     + "someone you've named in Photos: DigUp compares the faces in them with the faces you named, on "
                     + "this Mac. It's a guess, said as “Tati, by their face”. Click a face in the search window's "
                     + "preview to say who it is, or that it isn't who DigUp took it for; what you say is kept in "
                     + "face-corrections.json beside the index.")
                    .font(.system(size: 11))
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Whenever there's a device to turn on or off, an added one no picture names now included.
            if !state.deviceChoices.isEmpty {
                Section {
                    let mine = state.myDevices
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("My devices")
                            Text(mine.isEmpty ? "None" : mine.formatted(.list(type: .and)))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Button("Edit…") { editingDevices = true }
                    }
                } footer: {
                    Text("From → Shot on my devices, in the search window, keeps what these took: what their camera "
                         + "saved to Photos, and older pictures taken with one of them. A device whose camera saved "
                         + "something is on by itself, so a new phone joins without asking.")
                        .font(.system(size: 11))
                        .multilineTextAlignment(.leading)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .sheet(isPresented: $editingDevices) { MyDevicesSheet(state: state) }
        .task { await state.refreshPhotos() }
        .onChange(of: state.model.status) { state.statusChanged() }
    }

    /// How many pictures outside Photos show someone, and how the faces are read; or that none are yet.
    private var facesDetail: String {
        guard let faces = state.faces, let recognizer = faces.recognizer else {
            return "No faces read yet: DigUp reads them as it indexes, where this Mac can tell faces apart (Apple's "
                + "Vision, or the SFace model)."
        }
        let by = recognizer.split(separator: ",").first.map(String.init) ?? recognizer
        return "\(faces.matchedPictures.formatted()) "
            + (faces.matchedPictures == 1 ? "picture shows" : "pictures show") + " someone you've named · "
            + "\(faces.outside.formatted()) faces found in \(faces.outsidePictures.formatted()) pictures, compared with "
            + "\(faces.named.formatted()) you named (\(by))"
            + (faces.confirmed == 0 ? "" : " · \(faces.confirmed.formatted()) you said who they are")
    }
}

/// Settings → Photos → My devices → Edit…: a switch per device whose pictures "Shot on my devices" can keep (one whose
/// camera saved something to Photos, or that took older pictures with nothing recorded of how they came in).
private struct MyDevicesSheet: View {
    @Bindable var state: SettingsState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("My devices").font(.headline)
            Text("Pictures taken with these count as shot on your devices. One whose camera saved something to Photos "
                 + "is on by itself; turn on one that only took older pictures (from before Photos recorded where a "
                 + "picture came from) if it was yours.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List(state.deviceChoices) { camera in
                let settings = state.model.settings
                Toggle(isOn: Binding(get: { state.isMine(camera) }, set: {
                    state.app.setMyDevice(camera.model, mine: $0, fromCamera: camera.fromCamera > 0)
                })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(camera.model)
                        Text(MyDevicesSheet.counts(of: camera, added: settings.myDevicesAdded.contains(camera.model)))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)
            }
            .frame(minHeight: 260, idealHeight: 360, maxHeight: 420)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    static func counts(of camera: IndexStore.PhotosCamera, added: Bool) -> String {
        var parts: [String] = []
        if camera.fromCamera > 0 { parts.append("\(camera.fromCamera.formatted()) shot with its camera") }
        if camera.unknownOrigin > 0 { parts.append("\(camera.unknownOrigin.formatted()) older, origin not recorded") }
        if parts.isEmpty { parts.append(added ? "added by you; nothing it took counts yet" : "nothing it took counts") }
        return parts.joined(separator: " · ")
    }
}

/// A Photos library: on or off, what's indexed of it, and what Photos' last listing of it left out.
private struct LibraryRow: View {
    let library: SettingsState.Library
    let set: (Bool) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: library.url.path))
                .resizable()
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text((library.url.lastPathComponent as NSString).deletingPathExtension)
                        .font(.system(size: 13, weight: .semibold))
                    if library.access == .denied {
                        Text("No access")
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.orange.opacity(0.2)))
                        Button("Allow in Settings…", action: openPhotosPrivacySettings)
                            .buttonStyle(.link)
                            .font(.system(size: 11))
                    }
                }
                Text(tildePath(library.url.path))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let within = library.within {
                    Text("Searched as part of “\((within as NSString).lastPathComponent)”: off skips it there.")
                }
                ForEach(lines, id: \.self) { line in
                    Text(line).fixedSize(horizontal: false, vertical: true)
                }
                if library.searched, let kinds = library.summary?.kinds, !kinds.isEmpty {
                    KindCounts(counts: kinds).padding(.top, 1)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Toggle("Search \(library.url.lastPathComponent)", isOn: Binding(get: { library.searched }, set: set))
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(.vertical, 2)
    }

    /// What's indexed of it, or what reading it would take; then what Photos' last listing found and left out.
    private var lines: [String] {
        var lines: [String] = []
        if library.searched, let summary = library.summary, summary.files > 0 {
            lines.append("\(summary.indexed.formatted()) of \(summary.files.formatted()) indexed"
                         + (summary.pending > 0 ? " · \(summary.pending.formatted()) waiting" : ""))
        } else if !library.searched, let estimate = library.estimate {
            let count = estimate.files.values.reduce(0, +)
            if count > 0 {
                lines.append("\(count.formatted()) pictures and videos to read, \(approximately(estimate.seconds))")
            }
        }
        if let listing = library.listing {
            let left = listing.skipped.sorted { $0.value > $1.value }
                .map { "\($0.value.formatted()) \($0.key)" }.joined(separator: " · ")
            lines.append("Last read from Photos " + listing.listedAt.formatted(.relative(presentation: .named))
                         + ": \(listing.assets.formatted()) pictures and videos"
                         + (left.isEmpty ? "" : "; left out: \(left)"))
        }
        return lines
    }
}

/// System Settings → Privacy & Security → Photos.
func openPhotosPrivacySettings() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") {
        NSWorkspace.shared.open(url)
    }
}

/// Code search: its folders and how far along their index is, the editor results open in, and turning it off.
private struct CodeSettings: View {
    @Bindable var state: SettingsState
    @State private var turningOff = false
    @State private var removing: Engine.RootSummary?

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Search your code").font(.system(size: 13, weight: .semibold))
                    Text("Find code by what it does, or by a name in it: type code: in the search panel, as in "
                         + "“code: retry with backoff”. Code has an index of its own, and it never shows up in "
                         + "other searches.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if state.model.hasCode {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(state.model.codeStatusLine).font(.system(size: 12, weight: .medium))
                            if let indexing = state.model.status.code.indexing, indexing.total > 0 {
                                ProgressView(value: Double(indexing.done) / Double(indexing.total)).controlSize(.small)
                            }
                        }
                        Spacer()
                        Text(bytes(state.codeIndexSize))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                if state.codeSummaries.isEmpty {
                    Text("No code folders yet. Add the folders that hold your projects.")
                        .foregroundStyle(.secondary)
                }
                ForEach(state.codeSummaries) { summary in
                    FolderStatusRow(summary: summary) { removing = summary }
                }
            } header: {
                Text("Code folders")
            } footer: {
                HStack {
                    Button(action: state.addCodeFolders) {
                        Label(state.model.hasCode ? "Add Folders…" : "Choose Code Folders…", systemImage: "plus")
                    }
                    Spacer()
                }
            }
            Section {
                Picker("Open code in", selection: Binding(get: { CodeEditor.current.id },
                                                          set: { state.app.setCodeEditor($0) })) {
                    ForEach(CodeEditor.installed) { editor in Text(editor.name).tag(editor.id) }
                    Text(CodeEditor.defaultApp.name).tag(CodeEditor.defaultApp.id)
                }
            } footer: {
                Text("A result opens there at the line that matched. Space shows the whole file in Quick Look.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Section {
                Text("The code index keeps your code's text on this Mac, as the main index keeps your documents'. "
                     + "It skips what git ignores, vendored and generated code, data files, and anything that looks "
                     + "like a key or a password.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if state.model.hasCode {
                    HStack {
                        Spacer()
                        Button("Turn Off Code Search…", role: .destructive) { turningOff = true }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .onChange(of: state.model.status) { state.statusChanged() }
        .confirmationDialog("Turn off code search?", isPresented: $turningOff) {
            Button("Turn Off", role: .destructive) {
                state.app.applyCodeFolders([], excluded: [])
                Task { await state.refresh() }
            }
        } message: {
            Text("The code index (\(bytes(state.codeIndexSize))) is deleted. Turning it on again reads the code again.")
        }
        .confirmationDialog("Stop searching the code in “\(removing.map { ($0.path as NSString).lastPathComponent } ?? "")”?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) {
                guard let removing else { return }
                state.app.removeCodeFolder(URL(fileURLWithPath: removing.path))
                Task { await state.refresh() }
            }
        } message: {
            Text("Its \(removing?.files.formatted() ?? "") code files leave the code index.")
        }
    }
}

/// "~/Library/…/Models" that shows the folder in Finder.
private struct PathButton: View {
    let url: URL

    var body: some View {
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } label: {
            HStack(spacing: 4) {
                Text(tildePath(url.path)).lineLimit(1).truncationMode(.middle)
                Image(systemName: "arrow.right.circle.fill").foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .help("Show in Finder")
    }
}
