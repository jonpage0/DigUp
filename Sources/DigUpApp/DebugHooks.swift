import AppKit
import DigUpKit
import Quartz
import ServiceManagement
import SwiftUI

/// Launch arguments for testing without clicks or keystrokes (the terminal has no Accessibility permission):
///
///     -debugOffscreen YES     build and draw windows and the panel but never show them or activate the app, so
///                             snapshot runs don't take the keyboard from whoever is at the Mac (no key tests then)
///     -debugMenu YES          log the menu once the index is open, then run Pause and Resume and log it again
///     -debugQuery "<text>"    open the panel and search for <text>, as if it had been typed ("": the empty panel; a
///                             `+word ` in it becomes a must-have token, as typed)
///     -debugSnapshot <png>    once the final results and their pictures are showing, draw the panel into <png>
///     -debugKeys "down,space,esc,cmd+c"   then press these keys (posted through the app's own event queue, so
///                             no Accessibility permission is needed) and log what each one did. ⌘C goes to a
///                             private pasteboard. Keys: down, up, left, right, space, esc, return, tab, cmd+c,
///                             cmd+y, cmd+o, cmd+s, cmd+1, cmd+2, cmd+comma and letters; `settings`, `window` and
///                             `panel` open those, `wait` waits. Each goes to the window that has the keyboard. With
///                             -debugWindow search they test the window instead.
///     -debugType "a|b c"      then type each query (|-separated) into the field, one key every
///                             `-debugTypeInterval` seconds (default 0.09), waiting for its final results; the panel
///                             logs how long after the last keystroke they arrived
///     -debugCompose YES       then compose 사업자 the way a Korean input method does (marked text) while results
///                             arrive, and log whether the composition held
///     -debugSelect "<name>"   before the snapshot, select the first result whose name contains <name>
///     -debugPlay YES          after the snapshot, play the selected recording from its moment (muted) for 1.5 s and
///                             log where playback got to
///     -debugOpen dry|YES      then open the selected result: `dry` logs where and how it would open (the page's
///                             words for Preview, QuickTime Player at the moment…) without opening; YES opens it
///                             (another app comes forward, so only with someone at the Mac)
///     -debugQuickLook YES     then show Quick Look on the selected result for 2.5 s, log its display state and draw
///                             it into <snapshot>-quicklook.png (on screen: it takes the keyboard)
///     -debugLoginItem YES     turn open-at-login on, log what macOS says, then off again (a signed build in
///                             /Applications; macOS shows a notification)
///     -debugQuit YES          quit after that
///     -debugPauseAfter S / -debugResumeAfter S   press Pause / Resume S seconds after launch
///     -debugFolders a:b -debugFoldersAfter S     choose these folders S seconds after launch (as Settings would)
///     -debugCodeFolders a:b|off -debugCodeFoldersAfter S   the same for code search's folders ("off" turns it off)
///     -debugIcon <png>        draw the menubar icon idle, at 0%, 42% and 90%, paused, and with an update waiting
///     -debugHotkeyCheck a,b   log what the shortcut recorder would say about each combination ("cmd+space"…)
///     -debugMenuView <png>    draw the top of the menu (status, detail, progress) into <png>, after
///                             -debugMenuViewAfter seconds
///     -debugReshow N          after the query's final results, hide and show the panel N times (logs show times)
///     -debugWindow PAGE       open a window instead of the panel and snapshot it: search (with -debugQuery),
///                             settings:general|shortcuts|ai|folders|photos|code|storage, settings:add (Folders with Add Folders open),
///                             settings:addcode (Code with its folders' sheet open),
///                             onboarding:welcome|folders|code|shortcut|ready
///                             (-debugCloseWindow YES closes it afterwards, to measure what closing gives back;
///                             -debugWindowAfter S opens it S seconds after launch, once the helper has reported)
///     -debugChoices "open:real;click:real/videos;add:<path>"   before the snapshot, act on the folder list of
///                             onboarding's folder step or of Add Folders, then log what it would apply. Actions,
///                             `;`-separated: open:NAME (show a folder's subfolders), click:NAME (a folder's
///                             checkbox) or click:NAME/SUB (a subfolder's), add:PATH and skip:PATH (as picked in the
///                             open panel), unskip:PATH, types:heic,txt. NAME is the end of a listed folder's path.
///     -debugAdd YES           after the snapshot, press Add Folders' Add (or the code sheet's) and log what it applied
///     -debugFocus YES         with -debugWindow search: the field has the cursor (its ring shows) in the snapshot
///     -debugMap YES           with -debugWindow search: the map shows above the results
///     -debugArea "lat1,lon1,lat2,lon2"   with -debugWindow search: results kept to that box of the map
///     -debugFilters "person:Katie|album:Pumpkin Farm|favorites|digup|sensitive|length:15..60|shape:16:9|when:last:90"
///                             with -debugWindow search: these filters on (a Photos library's people and albums, by
///                             name; Photos' favorites; DigUp's own; the Sensitive filter; a Length, in seconds as
///                             `digup search --length` takes it; a Shape, as `--shape`; a When, as `--when`)
///     -debugSaved "<name>"    with -debugWindow search: then open the saved search of that name, as the Saved menu
///                             would
///     -debugSavedMenu YES     with -debugWindow search: after the snapshot, log the Saved menu's items and draw them
///                             into <snapshot>-savedmenu.png (an open menu can't be drawn offscreen, so this draws
///                             the items the menu is made from)
///     -debugRequire WORD      with -debugWindow search: after the snapshot, select WORD in the search field, ask the
///                             field for its right-click menu (as a right-click on it would), log the menu's first
///                             items, choose "Require “WORD”", and draw the window into <snapshot>-required.png
///     -debugFiltersMenu YES   with -debugWindow search: after the snapshot, log the Filters menu's items and draw them
///                             into <snapshot>-filtersmenu.png, each submenu's under it (as -debugSavedMenu does)
///     -debugWhenSheet YES|use   with -debugWindow search: after the snapshot, open When's Custom Range… (the range
///                             on, or the past month) and draw it into <snapshot>-when.png; `use` then presses Use and
///                             logs the tokens
///     -debugSavedSheet save|edit   with -debugWindow search: then open Save This Search… (its name suggested) or
///                             Edit Saved Searches…, and draw it into <snapshot>-saved.png; -debugSaveAs NAME
///                             then presses Save with that name
///     -debugMoment N          with -debugWindow search: before the snapshot, pick the selected result's Nth moment
///                             under the preview (1: the best; a video read from Photos' stills: its Nth still) as a
///                             click would: it plays from there (muted), and the log says where playback got to and
///                             where Quick Look and Open would go
///     -debugUpdateCheck YES   check for updates in the background a second after launch, as the daily check does
///     -debugUseModelFiles a:b take these files as the model, as Use Files… does, a second after launch
///     -debugHelperArgs "…"    more arguments for the indexing helper, in dev runs ("--time-limit 0")
///     -debugQuitAfter S       log the menu and quit S seconds after launch (a downloaded update installs on quit)
///     -debugWaitForIndex YES  wait for the model and an idle index with nothing waiting, then search for
///                             -debugQuery in the panel (<snapshot>-5-panel.png), as -debugOnboarding auto ends
///     -debugOnboarding auto   first launch, start to finish: snapshot each onboarding step (<snapshot>-1-welcome.png
///                             …), continue through it (the download starts, the folders apply), wait for the model
///                             and the first index, then search for -debugQuery in the panel (<snapshot>-N-panel.png)
///     -debugSearchCode YES    on onboarding's code step (or -debugWindow onboarding:code), turn code search on
///     -codeLocations a:b      the folders offered for code search (dev runs offer none without it)
enum DebugHooks {
    /// A debug run that decides what to show (the window a launch by hand opens would get in its way).
    static var drivesUI: Bool {
        ["debugOnboarding", "debugWindow", "debugQuery", "debugLoginItem", "debugWaitForIndex", "debugMenu",
         "debugMenuView", "debugIcon", "debugKeys", "debugType"].contains { UserDefaults.standard.object(forKey: $0) != nil }
    }

    static func run(_ app: AppController) {
        _ = launched   // first-launch stamps count from here
        let defaults = UserDefaults.standard
        if defaults.string(forKey: "debugOnboarding") == "auto" {
            return runOnboarding(app)
        }
        if let page = defaults.string(forKey: "debugWindow") {
            return showWindow(page, app)
        }
        if defaults.bool(forKey: "debugLoginItem") {
            return loginItem(app)
        }
        if defaults.bool(forKey: "debugWaitForIndex") {
            return waitForFirstIndex(app)
        }
        if defaults.object(forKey: "debugPauseAfter") != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + defaults.double(forKey: "debugPauseAfter")) {
                log("debug: Pause")
                app.engine.setPaused(true)
            }
        }
        if defaults.object(forKey: "debugResumeAfter") != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + defaults.double(forKey: "debugResumeAfter")) {
                log("debug: Resume")
                app.engine.setPaused(false)
            }
        }
        if let folders = defaults.string(forKey: "debugFolders") {
            DispatchQueue.main.asyncAfter(deadline: .now() + defaults.double(forKey: "debugFoldersAfter")) {
                log("debug: folders → \(folders)")
                app.applyFolders(folders.split(separator: ":").map { AppSettings.folderURL(String($0)) })
            }
        }
        if let folders = defaults.string(forKey: "debugCodeFolders") {
            DispatchQueue.main.asyncAfter(deadline: .now() + defaults.double(forKey: "debugCodeFoldersAfter")) {
                log("debug: code folders → \(folders)")
                app.applyCodeFolders(folders == "off" ? [] : folders.split(separator: ":").map {
                    AppSettings.folderURL(String($0))
                }, excluded: [])
            }
        }
        if let files = defaults.string(forKey: "debugUseModelFiles") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                log("debug: model files chosen: \(files)")
                app.model.download.use(files.split(separator: ":").map { URL(fileURLWithPath: String($0)) })
            }
        }
        if defaults.bool(forKey: "debugUpdateCheck") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                log("debug: checking for updates in the background")
                app.updates.checkInBackground()
            }
        }
        if defaults.object(forKey: "debugQuitAfter") != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + defaults.double(forKey: "debugQuitAfter")) {
                log("debug: menu \(app.statusMenu.describeMenu())")
                log("debug: quitting")
                NSApp.terminate(nil)
            }
        }
        if let path = defaults.string(forKey: "debugIcon") {
            drawIcons(to: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        }
        if let list = defaults.string(forKey: "debugHotkeyCheck") {
            // What the shortcut recorder would say about each combination (nothing is saved or kept registered).
            for spec in list.split(separator: ",").map(String.init) {
                guard let combo = KeyCombo(spec) else {
                    log("hotkey check: \(spec): not a usable combination")
                    continue
                }
                let free = combo == app.model.hotkey || GlobalHotkey(combo, action: {}) != nil
                log("hotkey check: \(combo.display): " + (combo.systemConflict ?? (free ? "free" : "taken by another app")))
            }
        }
        if let path = defaults.string(forKey: "debugMenuView") {
            DispatchQueue.main.asyncAfter(deadline: .now() + defaults.double(forKey: "debugMenuViewAfter")) {
                drawMenuHeader(app, to: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
            }
        }
        if defaults.bool(forKey: "debugMenu") {
            let menu = app.statusMenu!
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                log("menu: \(menu.describeMenu())")
                menu.performItem(titled: "Pause Indexing")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    log("menu after Pause: \(menu.describeMenu())")
                    menu.performItem(titled: "Resume Indexing")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        log("menu after Resume: \(menu.describeMenu())")
                    }
                }
            }
        }
        if let text = defaults.string(forKey: "debugQuery") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                searchInPanel(text, app, snapshot: snapshotPath()) {
                    if AppController.offscreen { app.panel.hide() }   // as Esc would: its pictures are dropped
                    if defaults.bool(forKey: "debugQuit") { NSApp.terminate(nil) }
                }
            }
        }
    }

    private static func snapshotPath(_ suffix: String? = nil) -> URL? {
        guard let path = UserDefaults.standard.string(forKey: "debugSnapshot") else { return nil }
        let full = (path as NSString).expandingTildeInPath
        guard let suffix else { return URL(fileURLWithPath: full) }
        return URL(fileURLWithPath: (full as NSString).deletingPathExtension + "-\(suffix).png")
    }

    private static func save(_ name: String, _ draw: (URL) throws -> Void, to url: URL?) {
        guard let url else { return }
        do {
            try draw(url)
            log("snapshot: \(name) → \(url.path)")
        } catch {
            log("snapshot of \(name) failed: \(error)")
        }
    }

    /// Opens the panel with `text`, waits for its final results and pictures, snapshots it, runs the key and typing
    /// tests, then `done`.
    private static func searchInPanel(_ text: String, _ app: AppController, snapshot: URL?,
                                      then done: @escaping () -> Void) {
        let defaults = UserDefaults.standard
        let panel = app.panel!
        if text.isEmpty {   // the panel as the hotkey opens it: nothing to wait for
            panel.show()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                save("panel", { try panel.snapshot(to: $0) }, to: snapshot)
                done()
            }
            return
        }
        let keys = defaults.string(forKey: "debugKeys")?.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        } ?? []
        if !keys.isEmpty {
            panel.pasteboard = NSPasteboard(name: NSPasteboard.Name("com.abdurrahim.DigUp.debug"))
            panel.pasteboard.clearContents()
        }
        let typed = defaults.string(forKey: "debugType")?.split(separator: "|").map(String.init) ?? []
        let interval = defaults.object(forKey: "debugTypeInterval") == nil
            ? 0.09 : defaults.double(forKey: "debugTypeInterval")
        panel.onFinalResults = {
            panel.onFinalResults = nil
            if let name = defaults.string(forKey: "debugSelect") {
                if let row = panel.rows.first(where: { $0.name.localizedCaseInsensitiveContains(name) }) {
                    panel.select(row)
                    log("debug: selected \(row.name) (\(row.place ?? "no page or moment"), \(row.reason))")
                } else {
                    log("debug: no result named like \"\(name)\"")
                }
            }
            whenPicturesSettle {
                save("panel", { try panel.snapshot(to: $0) }, to: snapshot)
                let row = panel.selectedRow
                play(row) {
                    openSelected(row, app) {
                        quickLook(row, panel: panel, snapshot: snapshotPath("quicklook")) {
                            press(keys, app, describe: { panelState(panel) }) {
                                type(typed, in: panel, every: interval) {
                                    compose(in: panel) {
                                        reshow(panel, times: defaults.integer(forKey: "debugReshow"), then: done)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        panel.show()
        panel.typed(text)
    }

    /// `-debugPlay`: plays `row` from its moment, muted, and logs where playback is 1.5 s later.
    private static func play(_ row: ResultRow?, then done: @escaping () -> Void) {
        guard UserDefaults.standard.bool(forKey: "debugPlay"), let row else { return done() }
        let playback = PreviewPlayback.shared
        playback.muted = true
        playback.play(row)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let at = playback.player?.currentTime().seconds ?? -1
            log("debug: playback of \(row.name) from \(ResultRow.clock(row.moment ?? 0)) is at "
                + String(format: "%.2f s", at) + " after 1.5 s (\(playback.isPlaying ? "playing" : "stopped"))")
            playback.stop()
            done()
        }
    }

    /// `-debugOpen dry|YES`: opens `row` as ↩ would (dry: only logs how).
    private static func openSelected(_ row: ResultRow?, _ app: AppController, then done: @escaping () -> Void) {
        guard let mode = UserDefaults.standard.string(forKey: "debugOpen"), let row else { return done() }
        Opener.dryRun = mode == "dry"
        app.engine.open(row)
        // A real open waits for the other app to report back (QuickTime Player says where it is).
        DispatchQueue.main.asyncAfter(deadline: .now() + (Opener.dryRun ? 0.5 : 6), execute: done)
    }

    /// `-debugQuickLook`: Space on `row`, then what Quick Look shows (it's on screen, and takes the keyboard).
    private static func quickLook(_ row: ResultRow?, panel: SearchPanelController, snapshot: URL?,
                                  then done: @escaping () -> Void) {
        guard UserDefaults.standard.bool(forKey: "debugQuickLook"), row != nil else { return done() }
        panel.toggleQuickLook()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            let preview = QLPreviewPanel.shared()!
            log("debug: Quick Look \(preview.isVisible ? "open" : "closed") on "
                + "\(preview.currentPreviewItem?.previewItemURL?.lastPathComponent ?? "nothing"), state "
                + "\(String(describing: preview.displayState).replacingOccurrences(of: "\n", with: " "))")
            if let snapshot { save("quick look", { try Snapshot.capture(preview, to: $0) }, to: snapshot) }
            preview.orderOut(nil)
            done()
        }
    }

    /// Thumbnails and previews load asynchronously; give them a moment (and up to 5 s) before drawing.
    private static func whenPicturesSettle(_ body: @escaping () -> Void) {
        Thumbnails.shared.whenIdle(timeout: 5) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { body() }
        }
    }

    // MARK: Windows

    private static func showWindow(_ page: String, _ app: AppController) {
        let defaults = UserDefaults.standard
        let started = Date()
        let parts = page.split(separator: ":").map(String.init)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5 + defaults.double(forKey: "debugWindowAfter")) {
            let loaded: () -> Bool
            let draw: (URL) throws -> Void
            let close: () -> Void
            var choices: () -> FolderChoices? = { nil }
            switch parts[0] {
            case "settings" where parts.count > 1 && parts[1] == "addcode":
                app.showSettings(.code)
                app.settingsWindow.addCodeFolders()
                let sheet = app.settingsWindow.codeSheet
                choices = { sheet.choices }
                loaded = { app.settingsWindow.state.isLoaded && sheet.choices?.estimatesDone ?? false }
                draw = { try sheet.snapshot(to: $0) }
                close = { sheet.end() }
            case "settings" where parts.count > 1 && parts[1] == "add":
                app.showSettings(.folders)
                app.settingsWindow.addFolders()
                let sheet = app.settingsWindow.addSheet
                choices = { sheet.choices }
                loaded = { app.settingsWindow.state.isLoaded && sheet.choices?.estimatesDone ?? false }
                draw = { try sheet.snapshot(to: $0) }
                close = { sheet.end() }
            case "settings":
                let tab = SettingsTab(rawValue: parts.count > 1 ? parts[1] : "general") ?? .general
                app.showSettings(tab)
                loaded = { app.settingsWindow.state.isLoaded && (tab != .photos || app.settingsWindow.state.photosLoaded) }
                draw = { try app.settingsWindow.snapshot(to: $0) }
                close = {}
            case "onboarding":
                app.showOnboarding()
                let onboarding = app.onboarding!
                if parts.count > 1, let step = OnboardingState.Step.allCases.first(where: { "\($0)" == parts[1] }) {
                    onboarding.state.go(to: step)
                }
                if onboarding.state.step == .code, defaults.bool(forKey: "debugSearchCode") {
                    onboarding.state.searchCode = true
                }
                choices = {
                    switch onboarding.state.step {
                    case .folders: onboarding.state.folders
                    case .code: onboarding.state.searchCode ? onboarding.state.codeFolders : nil
                    default: nil
                    }
                }
                loaded = { onboarding.state.isLoaded }
                draw = { try onboarding.snapshot(to: $0) }
                close = { onboarding.close() }
            default:
                app.showSearchWindow(query: defaults.string(forKey: "debugQuery") ?? "")
                let search = app.searchWindow.search
                // The field with the cursor, as on screen (an offscreen window doesn't take it by itself).
                if defaults.bool(forKey: "debugFocus") { DispatchQueue.main.async { search.focusField() } }
                search.showsMap = defaults.bool(forKey: "debugMap")
                let box = (defaults.string(forKey: "debugArea") ?? "").split(separator: ",").compactMap { Double($0) }
                if box.count == 4 {
                    search.area = SearchFilter.Area(latitudes: min(box[0], box[2])...max(box[0], box[2]),
                                                    longitudes: min(box[1], box[3])...max(box[1], box[3]))
                }
                // -debugFilters: the filters on before the snapshot, once the libraries' people and albums are read;
                // -debugSaved: then a saved search opened, by name.
                let filtering = DebugProgress()
                let filters = defaults.string(forKey: "debugFilters"), opening = defaults.string(forKey: "debugSaved")
                if filters != nil || opening != nil {
                    Task {
                        let choices = await app.engine.photosChoices()
                        for part in (filters ?? "").split(separator: "|").map(String.init) {
                            let (kind, name) = (part.prefix { $0 != ":" }, part.drop { $0 != ":" }.dropFirst())
                            if kind == "person", let person = choices.people.first(where: { $0.name == name }) {
                                search.set(person.token, on: true)
                            } else if kind == "album", let album = choices.albums.first(where: { $0.title == name }) {
                                search.set(album.token, on: true)
                            } else if kind == "favorites" {
                                search.set(.photosFavorites, on: true)
                            } else if kind == "digup" {
                                search.set(.digupFavorites, on: true)
                            } else if kind == "sensitive" {
                                search.set(.sensitive, on: true)
                            } else if kind == "length", let length = SearchFilter.Length(String(name)) {
                                search.set(.length(length), on: true)
                            } else if kind == "shape", let shape = SearchFilter.Shape(String(name)) {
                                search.set(.shape(shape), on: true)
                            } else if kind == "when", let when = SearchFilter.When(String(name)) {
                                search.set(.when(when), on: true)
                            } else {
                                log("debug: no filter \"\(part)\"")
                            }
                        }
                        if let name = opening {
                            if let saved = app.savedSearches.searches.first(where: { $0.name == name }) {
                                await search.open(saved)
                            } else {
                                log("debug: no saved search \"\(name)\"")
                            }
                        }
                        filtering.done = true
                    }
                } else {
                    filtering.done = true
                }
                loaded = { filtering.done && search.isSettled && (!search.isSearching || search.hasResults) }
                draw = { try app.searchWindow.snapshot(to: $0) }
                close = { app.searchWindow.close() }
            }
            let keys = defaults.string(forKey: "debugKeys")?.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            } ?? []
            waitUntil(loaded, deadline: Date().addingTimeInterval(30)) {
                log("window: \(page) loaded in \(ms(since: started)) (after a 0.5 s launch delay)")
                if let list = choices() { act(on: list) }
                waitUntil({ choices()?.estimatesDone ?? true }, deadline: Date().addingTimeInterval(30)) {
                    pickMoment(app) {
                        whenPicturesSettle {
                            save(page, draw, to: snapshotPath())
                            if let list = choices() { log("choices: \(describe(list))") }
                            if defaults.bool(forKey: "debugAdd"), app.settingsWindow.addSheet.isOpen {
                                app.settingsWindow.addSheet.add()
                                let settings = app.model.settings
                                log("debug: added; folders \(settings.roots.map { tildePath($0.path) }) · skipping "
                                    + "\(settings.excludedFolders.map { tildePath($0.path) })")
                            }
                            if defaults.bool(forKey: "debugAdd"), app.settingsWindow.codeSheet.isOpen {
                                app.settingsWindow.codeSheet.add()
                                let settings = app.model.settings
                                log("debug: added; code folders \(settings.codeRoots.map { tildePath($0.path) }) · "
                                    + "skipping \(settings.codeExcluded.map { tildePath($0.path) })")
                            }
                            filtersMenuStep(app)
                            whenSheetStep(app) {
                                savedSearchSteps(app) {
                                    requireSteps(app) {
                                        press(keys, app, describe: { windowState(app) }) {
                                            if defaults.bool(forKey: "debugCloseWindow") {
                                                close()
                                                log("window: closed")
                                            }
                                            if defaults.bool(forKey: "debugQuit") { NSApp.terminate(nil) }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// After the search window's snapshot: `-debugFiltersMenu` logs the Filters menu's items and draws them into
    /// <snapshot>-filtersmenu.png.
    private static func filtersMenuStep(_ app: AppController) {
        guard UserDefaults.standard.bool(forKey: "debugFiltersMenu") else { return }
        let search = app.searchWindow.search
        let items = FilterMenuItem.items(search)
        func described(_ items: [FilterMenuItem]) -> String {
            items.map { item in
                switch item {
                case .toggle(let title, let token, let enabled):
                    (search.has(token) ? "✓ " : "") + title + (enabled ? "" : " (disabled)")
                case .submenu(let title, _, let items): "\(title) ▸ [\(described(items))]"
                case .command(let title, _, _): title
                case .note(let text): "\(text) (disabled)"
                case .divider: "—"
                }
            }.joined(separator: " | ")
        }
        log("filters menu: \(FilterMenuItem.title(on: FilterMenuItem.count(search))) ▾ [\(described(items))]")
        save("filters menu", { url in
            let view = NSHostingView(rootView: FiltersMenuDrawing(items: items, search: search))
            view.frame.size = view.fittingSize
            let drawing = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            drawing.contentView = view
            try Snapshot.write(drawing, to: url, cornerRadius: 6)
        }, to: snapshotPath("filtersmenu"))
    }

    /// After the search window's snapshot: `-debugWhenSheet YES|use` opens When's Custom Range… and draws it into
    /// <snapshot>-when.png; `use` then presses Use and logs the tokens.
    private static func whenSheetStep(_ app: AppController, then done: @escaping () -> Void) {
        guard let mode = UserDefaults.standard.string(forKey: "debugWhenSheet") else { return done() }
        let window = app.searchWindow!
        window.chooseWhen()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            save("custom range sheet", { try window.whenSheet.snapshot(to: $0) }, to: snapshotPath("when"))
            guard mode == "use", let use = window.whenSheet.use else { return done() }
            use()
            let search = window.search
            waitUntil({ search.isSettled && search.hasResults }, deadline: Date().addingTimeInterval(30)) {
                log("debug: custom range used: \(windowState(app))")
                done()
            }
        }
    }

    /// After the search window's snapshot: `-debugSavedMenu` logs the Saved menu's items and draws them into
    /// <snapshot>-savedmenu.png; `-debugSavedSheet save|edit` opens Save This Search… or Edit Saved Searches… and draws
    /// it into <snapshot>-saved.png; `-debugSaveAs NAME` then presses Save with that name.
    private static func savedSearchSteps(_ app: AppController, then done: @escaping () -> Void) {
        let defaults = UserDefaults.standard
        let window = app.searchWindow!
        if defaults.bool(forKey: "debugSavedMenu") {
            let items = SavedMenuItem.items(app.savedSearches, canSave: window.search.isSearching)
            log("saved menu: " + items.map { item in
                switch item {
                case .search(let search): search.name
                case .note(let text): "\(text) (disabled)"
                case .divider: "—"
                case .save(let enabled): SavedMenuItem.saveTitle + " ⌘S" + (enabled ? "" : " (disabled)")
                case .edit(let enabled): SavedMenuItem.editTitle + (enabled ? "" : " (disabled)")
                }
            }.joined(separator: " | "))
            save("saved menu", { url in
                let view = NSHostingView(rootView: SavedMenuDrawing(items: items))
                view.frame.size = view.fittingSize
                let drawing = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered,
                                       defer: false)
                drawing.contentView = view
                try Snapshot.write(drawing, to: url, cornerRadius: 6)
            }, to: snapshotPath("savedmenu"))
        }
        guard let sheet = defaults.string(forKey: "debugSavedSheet") else { return done() }
        if sheet == "edit" { window.editSavedSearches() } else { window.saveSearch() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            save("saved searches sheet", { try window.savedSheet.snapshot(to: $0) }, to: snapshotPath("saved"))
            if let name = defaults.string(forKey: "debugSaveAs"), let saveAs = window.savedSheet.saveAs {
                saveAs(name)
                log("debug: saved as \"\(name)\"; the menu has \(app.savedSearches.searches.map(\.name))")
            }
            done()
        }
    }

    /// `-debugRequire WORD`: the search field's right-click menu on WORD, as AppKit builds it (the field editor asks the
    /// field), its "Require “WORD”" chosen, and the window drawn into <snapshot>-required.png once it has searched.
    private static func requireSteps(_ app: AppController, then done: @escaping () -> Void) {
        guard let word = UserDefaults.standard.string(forKey: "debugRequire") else { return done() }
        let search = app.searchWindow.search
        guard let field = search.field, let window = field.window else { return done() }
        window.makeFirstResponder(field)
        let found = (field.stringValue as NSString).range(of: word, options: .caseInsensitive)
        guard let editor = field.currentEditor() as? NSTextView, found.location != NSNotFound else {
            log("debug: require: \"\(word)\" isn't in the field (\"\(field.stringValue)\")")
            return done()
        }
        editor.selectedRange = found
        let rect = window.convertFromScreen(editor.firstRect(forCharacterRange: found, actualRange: nil))
        guard let click = NSEvent.mouseEvent(with: .rightMouseDown, location: NSPoint(x: rect.midX, y: rect.midY),
                                             modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                             clickCount: 1, pressure: 1),
              let menu = editor.menu(for: click) else {
            log("debug: require: no menu")
            return done()
        }
        log("debug: require: the field's menu: " + menu.items.prefix(4).map { $0.isSeparatorItem ? "—" : $0.title }
            .joined(separator: " | "))
        guard let index = menu.items.firstIndex(where: { $0.title.hasPrefix("Require") }) else { return done() }
        menu.performActionForItem(at: index)
        waitUntil({ search.isSettled && search.hasResults }, deadline: Date().addingTimeInterval(30)) {
            whenPicturesSettle {
                log("debug: require: \(windowState(app))")
                save("required", { try app.searchWindow.snapshot(to: $0) }, to: snapshotPath("required"))
                done()
            }
        }
    }

    /// `-debugMoment N`: picks the search window's selected result's Nth moment (1: the best), or for a video read from
    /// Photos' stills its Nth still (1: the first, matched or not), as a click under the preview would; lets it play
    /// (muted) for 1.5 s, and logs where playback is and where Quick Look and Open would go.
    private static func pickMoment(_ app: AppController, then done: @escaping () -> Void) {
        let number = UserDefaults.standard.integer(forKey: "debugMoment")
        guard number > 0, let row = app.searchWindow.search.selectedRow else { return done() }
        let playback = PreviewPlayback.shared
        playback.muted = true
        func report(_ picked: String) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                let placed = playback.placed(row)
                let at = playback.player.map { String(format: "%.2f s", $0.currentTime().seconds) } ?? "not playing"
                log("debug: picked \(picked) of \(row.name) (\(placed.reason)): playback at \(at); Quick Look opens "
                    + "item \(placed.quickLook.start + 1) at \(placed.quickLookState.map { "\($0)" } ?? "the start"); "
                    + placed.openTitle)
                done()
            }
        }
        if row.photos?.reading == .stills {
            let filmstrip = PhotosLibrary.filmstrip(startingAt: row.url.path)
            guard filmstrip.indices.contains(number - 1) else {
                log("debug: \(row.name) has \(filmstrip.count) stills, no still \(number)")
                return done()
            }
            playback.pick(still: filmstrip[number - 1], at: number - 1, of: row)
            return report("still \(number) of \(filmstrip.count)")
        }
        Task {
            let moments = await app.engine.moments(of: row.id, matching: row.query)
            guard moments.indices.contains(number - 1) else {
                log("debug: \(row.name) has \(moments.count) moments, no moment \(number)")
                return done()
            }
            playback.pick(moments[number - 1], of: row, filmstrip: [])
            report("moment \(number) of \(moments.count)")
        }
    }

    // MARK: Open at login

    private static func loginItem(_ app: AppController) {
        func status() -> String {
            switch SMAppService.mainApp.status {
            case .enabled: "enabled"
            case .requiresApproval: "requires approval (System Settings → Login Items)"
            case .notRegistered: "not registered"
            case .notFound: "not found"
            @unknown default: "unknown"
            }
        }
        log("login item: \(status()) at first · app at \(Bundle.main.bundlePath)")
        let on = app.setLaunchAtLogin(true)
        log("login item: turned on → \(on ?? "ok"), now \(status())")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            let off = app.setLaunchAtLogin(false)
            log("login item: turned off → \(off ?? "ok"), now \(status())")
            if UserDefaults.standard.bool(forKey: "debugQuit") { NSApp.terminate(nil) }
        }
    }

    // MARK: First launch, start to finish

    private static let launched = Date()

    private static func stamp(_ what: String) {
        log("first launch: \(what) at \(String(format: "%.1f s", Date().timeIntervalSince(launched)))")
    }


    private static func runOnboarding(_ app: AppController) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard let onboarding = app.onboarding else {
                log("first launch: onboarding didn't open (folders or onboarded already set?)")
                return NSApp.terminate(nil)
            }
            stamp("onboarding open")
            onboardingStep(0, onboarding, app)
        }
    }

    /// How many steps the onboarding just run had (the panel's snapshot is numbered after them).
    private static var onboardingStepCount = 4

    /// Snapshots step `index` (of the steps this Mac gets), then presses its Continue (Get Started, Continue…, Done).
    /// On the folder step, `-debugChoices` acts on the list first; on the code step, `-debugSearchCode` turns it on.
    private static func onboardingStep(_ index: Int, _ onboarding: OnboardingController, _ app: AppController) {
        let state = onboarding.state
        onboardingStepCount = state.steps.count
        guard index < state.steps.count else { return waitForFirstIndex(app) }
        let name = "\(index + 1)-\(state.step)"
        if state.step == .code, UserDefaults.standard.bool(forKey: "debugSearchCode") { state.searchCode = true }
        waitUntil({ state.isLoaded }, deadline: Date().addingTimeInterval(60)) {
            if state.step == .folders { act(on: state.folders) }
            waitUntil({ state.isLoaded }, deadline: Date().addingTimeInterval(60)) {
                whenPicturesSettle {
                    save(name, { try onboarding.snapshot(to: $0) }, to: snapshotPath(name))
                    if state.step == .folders { log("choices: \(describe(state.folders))") }
                    stamp("step \(name) done")
                    state.next()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { onboardingStep(index + 1, onboarding, app) }
                }
            }
        }
    }

    // MARK: Folder lists

    /// `-debugChoices`: clicks and picks in a folder list, as described at the top.
    private static func act(on choices: FolderChoices) {
        guard let script = UserDefaults.standard.string(forKey: "debugChoices") else { return }
        func row(_ name: String) -> URL? { choices.rows.first { $0.path.hasSuffix("/" + name) } }
        for action in script.split(separator: ";").map(String.init) {
            let parts = action.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let (verb, name) = (parts[0], parts[1])
            switch verb {
            case "open":
                if let row = row(name) { choices.expanded.insert(row.path) } else { log("choices: no folder \(name)") }
            case "click":
                if let row = row(name) {
                    choices.toggle(row)
                } else if let row = row((name as NSString).deletingLastPathComponent) {
                    choices.toggle(subfolder: row.path + "/" + (name as NSString).lastPathComponent)
                } else {
                    log("choices: no folder \(name)")
                }
            case "add": choices.add([AppSettings.folderURL(name)])
            case "skip": choices.skip([AppSettings.folderURL(name)])
            case "unskip": choices.unskip(AppSettings.folderURL(name).path)
            case "types": choices.setTypes(name)
            default: log("choices: don't know \"\(verb)\"")
            }
            log("choices: \(action) → \(describe(choices))")
        }
    }

    /// What a folder list would apply, and how it shows.
    private static func describe(_ choices: FolderChoices) -> String {
        let marks = choices.rows.map { row in
            "\(row.lastPathComponent) \(choices.mark(row))"
                + (choices.searchedPart(of: row).map { String(format: " %.1f s", $0.seconds) } ?? "")
        }
        return "folders \(choices.roots.map { tildePath($0.path) }) · skipping \(choices.skipped.map { tildePath($0.path) })"
            + " · rows [\(marks.joined(separator: ", "))] · first pass ≈ \(roughDuration(choices.totalSeconds))"
            + (choices.note.map { " · note: \($0)" } ?? "")
    }

    private static func waitForFirstIndex(_ app: AppController) {
        var lastLog = Date()
        let finished = {
            if Date().timeIntervalSince(lastLog) > 10 {
                lastLog = Date()
                log("first launch: waiting · \(app.model.statusLine) · model \(app.download.progressText)")
            }
            guard app.download.isReady, case .idle = app.model.status.activity else { return false }
            return app.model.status.pending == 0 && app.model.status.searchable > 0
        }
        waitUntil(finished, deadline: Date().addingTimeInterval(45 * 60)) {
            stamp("model ready and first index done (\(app.model.statusLine))")
            let text = UserDefaults.standard.string(forKey: "debugQuery") ?? "zebra"
            searchInPanel(text, app, snapshot: snapshotPath("\(onboardingStepCount + 1)-panel")) {
                stamp("searched \"\(text)\"")
                if UserDefaults.standard.bool(forKey: "debugQuit") { NSApp.terminate(nil) }
            }
        }
    }

    private static func waitUntil(_ condition: @escaping () -> Bool, deadline: Date, then body: @escaping () -> Void) {
        if condition() || Date() > deadline { return body() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { waitUntil(condition, deadline: deadline, then: body) }
    }

    // MARK: Panel keys

    private static func reshow(_ panel: SearchPanelController, times: Int, then done: @escaping () -> Void) {
        guard times > 0 else { return done() }
        panel.hide()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            panel.show()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                reshow(panel, times: times - 1, then: done)
            }
        }
    }

    /// Posts each key to the window that has the keyboard (the panel, Quick Look, a window), 0.5 s apart, and logs
    /// `describe()` after it. Not keys: `settings`, `window` and `panel` open those; `wait` just waits.
    private static func press(_ keys: [String], _ app: AppController, describe: @escaping () -> String,
                              then done: @escaping () -> Void) {
        guard let key = keys.first else { return done() }
        let next = { press(Array(keys.dropFirst()), app, describe: describe, then: done) }
        switch key {
        case "settings": app.showSettings()
        case "window": app.showSearchWindow()
        case "panel": app.panel.show()
        case "wait": break
        default:
            guard let event = keyEvent(key, window: NSApp.keyWindow?.windowNumber ?? app.panel.windowNumber) else {
                log("keys: don't know \"\(key)\"")
                return next()
            }
            NSApp.postEvent(event, atStart: false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let keyWindow = NSApp.keyWindow.map { window in
                window is QLPreviewPanel ? "Quick Look" : window is SearchPanelWindow ? "panel"
                    : window.title.isEmpty ? "\(Swift.type(of: window))" : window.title
            } ?? "none"
            log("keys: \(key) → \(describe()) · keyboard: \(keyWindow)" + (NSApp.isHidden ? " · app hidden" : ""))
            next()
        }
    }

    /// The panel's state, for key tests.
    private static func panelState(_ panel: SearchPanelController) -> String {
        let ids = panel.rowIDs
        let index = ids.firstIndex { $0 == panel.selection }.map { "\($0 + 1)" } ?? "-"
        let copied = panel.pasteboard.readObjects(forClasses: [NSURL.self])?.first as? URL
        let selected = panel.selection == SearchPanelController.weakerToggle ? "the weaker-matches fold"
            : panel.selectedRow?.name ?? "none"
        return "row \(index) of \(ids.count) (\(selected)) · weaker \(panel.showWeaker ? "shown" : "folded") · "
            + "query \"\(panel.query)\" · panel \(panel.isVisible ? "open" : "hidden") · "
            + "Quick Look \(panel.isPreviewing ? "open" : "closed")"
            + (copied.map { " · pasteboard: \($0.lastPathComponent)" } ?? "")
    }

    /// The search window's state, for key tests.
    private static func windowState(_ app: AppController) -> String {
        let search = app.searchWindow.search
        let rows = search.rows
        let index = rows.firstIndex { $0.id == search.selectedRow?.id }.map { "\($0 + 1)" } ?? "-"
        let previewing = QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
        return "cell \(index) of \(rows.count) (\(search.selectedRow?.name ?? "none")) · columns \(search.columns) · "
            + "filter \(search.filter?.title ?? "All") · query \"\(search.query)\" · "
            + "tokens \(search.shownTokens.map { $0.title + ($0.isMissing ? " (not in Photos now)" : "") }) · "
            + "must have \(search.required) · Quick Look \(previewing ? "open" : "closed")"
    }

    /// Selects the field's text (⌘A) and types `queries[0]` a key at a time, waits for its final results, then the rest.
    private static func type(_ queries: [String], in panel: SearchPanelController, every interval: Double,
                             then done: @escaping () -> Void) {
        guard let query = queries.first else { return done() }
        var events: [NSEvent] = []
        if let selectAll = characterEvent("a", modifiers: .command, window: panel.windowNumber) { events.append(selectAll) }
        events += query.compactMap { characterEvent(String($0), modifiers: [], window: panel.windowNumber) }
        panel.onFinalResults = {
            guard panel.query == query else { return }
            panel.onFinalResults = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                type(Array(queries.dropFirst()), in: panel, every: interval, then: done)
            }
        }
        for (index, event) in events.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + interval * Double(index)) {
                NSApp.postEvent(event, atStart: false)
            }
        }
    }

    /// -debugCompose YES: the calls a Korean input method makes while 사업자 is typed on the 2-Set keyboard (the syllable
    /// in progress is marked text, committed when the next one starts), one key every 0.25 s while results come in.
    /// Logs what the field ended with and how many keys found the composition cut short.
    private static func compose(in panel: SearchPanelController, then done: @escaping () -> Void) {
        guard UserDefaults.standard.bool(forKey: "debugCompose") else { return done() }
        guard let editor = panel.field?.currentEditor() as? NSTextView else {
            log("debug: compose: the field isn't being edited")
            return done()
        }
        editor.selectAll(nil)
        editor.delete(nil)
        // Each key: what it commits (the finished syllable), then the new marked text.
        let keys: [(commit: String, marked: String)] = [("", "ㅅ"), ("", "사"), ("", "상"), ("사", "어"), ("", "업"),
                                                          ("업", "ㅈ"), ("", "자")]
        let nowhere = NSRange(location: NSNotFound, length: 0)
        var cut = 0
        func press(_ index: Int) {
            guard index < keys.count else {
                log("debug: composed 사업자: the field says \"\(panel.field?.stringValue ?? "")\" (still marked: "
                    + "\(editor.hasMarkedText())); the composition was cut short before \(cut) of \(keys.count - 1) keys")
                return done()
            }
            if index > 0, !editor.hasMarkedText() { cut += 1 }
            let key = keys[index]
            if !key.commit.isEmpty { editor.insertText(key.commit, replacementRange: nowhere) }
            editor.setMarkedText(key.marked, selectedRange: NSRange(location: (key.marked as NSString).length, length: 0),
                                 replacementRange: nowhere)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { press(index + 1) }
        }
        press(0)
    }

    private static func characterEvent(_ character: String, modifiers: NSEvent.ModifierFlags, window: Int) -> NSEvent? {
        let code: UInt16 = character == " " ? 49 : letterCodes[character.lowercased()] ?? 0
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window, context: nil,
                                characters: character, charactersIgnoringModifiers: character, isARepeat: false,
                                keyCode: code)
    }

    private static func keyEvent(_ name: String, window: Int) -> NSEvent? {
        let table: [String: (UInt16, String, NSEvent.ModifierFlags)] = [
            "down": (125, "\u{F701}", []), "up": (126, "\u{F700}", []), "space": (49, " ", []),
            "esc": (53, "\u{1B}", []), "return": (36, "\r", []), "cmd+c": (8, "c", .command),
            "cmd+y": (16, "y", .command), "left": (123, "\u{F702}", []), "right": (124, "\u{F703}", []),
            "cmd+1": (18, "1", .command), "cmd+2": (19, "2", .command), "cmd+o": (31, "o", .command),
            "cmd+comma": (43, ",", .command), "tab": (48, "\t", []), "cmd+s": (1, "s", .command),
        ]
        var entry = table[name]
        if entry == nil, name.count == 1, let code = letterCodes[name] { entry = (code, name, []) }
        guard let (code, characters, flags) = entry else { return nil }
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window, context: nil,
                                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false,
                                keyCode: code)
    }

    private static let letterCodes: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
        "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45,
        "m": 46,
    ]

    /// The menu's header view, as it would show if the menu opened now.
    private static func drawMenuHeader(_ app: AppController, to url: URL) {
        let view = NSHostingView(rootView: MenuStatusView(model: app.model))
        view.frame.size = view.fittingSize
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        save("menu header", { try Snapshot.write(window, to: $0, cornerRadius: 6) }, to: url)
    }

    /// The menubar icon idle, at a few progress values, paused, and with an update waiting, scaled up, black on white
    /// (as a template it takes the bar's color).
    private static func drawIcons(to url: URL) {
        let states: [(Double?, Bool, Bool)] = [(nil, false, false), (0.0, false, false), (0.42, false, false),
                                               (0.9, false, false), (nil, true, false), (nil, false, true),
                                               (0.42, false, true)]
        let scale: CGFloat = 4, side: CGFloat = 18
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(side * scale) * states.count,
                                   pixelsHigh: Int(side * scale), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh).fill()
        for (index, (progress, paused, update)) in states.enumerated() {
            StatusIcon.image(progress: progress, paused: paused, update: update)
                .draw(in: NSRect(x: CGFloat(index) * side * scale, y: 0, width: side * scale, height: side * scale))
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        log("icon: \(url.path)")
    }
}

/// Whether a debug step started on another task is done (the snapshot waits for it).
private final class DebugProgress {
    var done = false
}

/// The Saved menu's items as a menu shows them, for `-debugSavedMenu` (an open menu can't be drawn offscreen): the
/// saved searches, a divider, Save This Search… with ⌘S, Edit Saved Searches…, what can't be chosen dimmed.
private struct SavedMenuDrawing: View {
    let items: [SavedMenuItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items) { item in
                switch item {
                case .search(let search): row(search.name, enabled: true)
                case .note(let text): row(text, enabled: false)
                case .divider: Divider().padding(.vertical, 5).padding(.horizontal, 10)
                case .save(let enabled): row(SavedMenuItem.saveTitle, shortcut: "⌘S", enabled: enabled)
                case .edit(let enabled): row(SavedMenuItem.editTitle, enabled: enabled)
                }
            }
        }
        .padding(.vertical, 5)
        .frame(width: 280)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func row(_ title: String, shortcut: String? = nil, enabled: Bool) -> some View {
        HStack {
            Text(title).lineLimit(1)
            Spacer()
            if let shortcut { Text(shortcut).foregroundStyle(.secondary) }
        }
        .font(.system(size: 13))
        .foregroundStyle(enabled ? .primary : .tertiary)
        .padding(.horizontal, 14)
        .frame(height: 22)
    }
}

/// The Filters menu's items as a menu shows them, for `-debugFiltersMenu` (an open menu can't be drawn offscreen): a
/// check by each filter that's on, a submenu's title with ▸ and its items under it, indented, what can't be chosen
/// dimmed.
private struct FiltersMenuDrawing: View {
    let items: [FilterMenuItem]
    let search: SearchModel

    /// Each item with how deep in submenus it is, a submenu's items right after it.
    private struct Line: Identifiable {
        let id: String
        let depth: Int
        let item: FilterMenuItem
    }

    private static func lines(_ items: [FilterMenuItem], depth: Int = 0, under parent: String = "") -> [Line] {
        items.flatMap { item -> [Line] in
            let line = Line(id: parent + "/" + item.id, depth: depth, item: item)
            guard case .submenu(_, _, let inner) = item else { return [line] }
            return [line] + lines(inner, depth: depth + 1, under: line.id)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Self.lines(items)) { line in
                let indent = CGFloat(line.depth) * 18
                switch line.item {
                case .toggle(let title, let token, let enabled):
                    row(title, check: search.has(token), enabled: enabled).padding(.leading, indent)
                case .submenu(let title, _, _): row(title, submenu: true, enabled: true).padding(.leading, indent)
                case .command(let title, _, _): row(title, enabled: true).padding(.leading, indent)
                case .note(let text): row(text, enabled: false).padding(.leading, indent)
                case .divider: Divider().padding(.vertical, 5).padding(.leading, 10 + indent).padding(.trailing, 10)
                }
            }
        }
        .padding(.vertical, 5)
        .frame(width: 320)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func row(_ title: String, check: Bool = false, submenu: Bool = false, enabled: Bool) -> some View {
        HStack(spacing: 0) {
            Text(check ? "✓" : "").frame(width: 16, alignment: .leading)
            Text(title).lineLimit(1)
            Spacer()
            if submenu { Text("▸").foregroundStyle(.secondary) }
        }
        .font(.system(size: 13))
        .foregroundStyle(enabled ? .primary : .tertiary)
        .padding(.horizontal, 10)
        .frame(height: 22)
    }
}
