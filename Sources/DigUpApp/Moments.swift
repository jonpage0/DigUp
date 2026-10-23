import AVFoundation
import AVKit
import AppKit
import DigUpKit
import Observation
import PDFKit
import Quartz
import SwiftUI

// The page or moment that matched, wherever a result is looked at: Quick Look (Space) opens there, the default app
// opens there when it can be told to, and the preview pane plays a recording from there.

extension ResultRow {
    /// The PDF page that matched (1-based).
    var page: Int? {
        guard kind == .pdf, segment == .page || segment == .pageImage, let loc else { return nil }
        return Int(loc)
    }

    /// Seconds into a recording where the match starts.
    var moment: Double? {
        guard kind == .video || kind == .audio, Moment.Kind(segment) != nil else { return nil }
        return loc
    }

    /// The stretch of a recording that matched, in seconds: to its end as the index has it, else a frame step or a
    /// sound window on (as `Searcher.moments` counts a match).
    var momentSpan: ClosedRange<Double>? {
        guard let moment else { return nil }
        let step = segment == .audio ? IndexOptions().audioWindow : IndexOptions().frameInterval
        return moment...max(moment, locEnd ?? moment + step)
    }

    /// "3 moments": a recording that matched in more places than one.
    var momentsLabel: String? {
        momentCount > 1 ? "\(momentCount) moments" : nil
    }

    /// Whether this result is at `moment`: the one it matched at, or the one picked (`Moment.covers`).
    func isAt(_ moment: Moment, filmstrip: [String]) -> Bool {
        if let still = moment.still { return filmstrip.indices.contains(still) && photos?.still == filmstrip[still] }
        guard let loc else { return false }
        return moment.covers(segment, at: loc)
    }

    /// Where opening or Quick Look should go when it isn't the start: a page after the first, or a moment ("p. 3",
    /// "0:06").
    var jump: String? {
        if let page, page > 1 { return place }
        if let moment, moment >= 1 { return place }
        return nil
    }

    /// Quick Look's display state for the page or moment: what its own previews report as you page through a PDF or
    /// play a movie (`QLPreviewPanel.displayState`, "the currently displayed page … or the position in a movie").
    var quickLookState: [String: Any]? {
        if let page, page > 1 { return ["CurrentPage": page - 1] }
        if let moment, moment >= 1 { return ["CurrentTime": moment] }
        return nil
    }

    /// "Open at 0:06" when the recording's app can be told the moment (QuickTime Player, IINA), else "Open". A PDF
    /// opens with your words in Preview's search, but Preview doesn't go to the page by itself. Code opens in the
    /// editor chosen for it: "Open in Zed".
    var openTitle: String {
        if photos != nil { return "Open in Photos" }
        if kind == .code, !CodeEditor.current.id.isEmpty { return "Open in \(CodeEditor.current.name)" }
        if let moment, moment >= 1, Opener.jumpsToMoments(url) { return "Open at \(Self.clock(moment))" }
        return "Open"
    }

    /// "Show in Finder", or for a picture in a Photos library, where Finder can't show it, "Show in Photos".
    var revealTitle: String { Opener.revealTitle(url) }

    /// The line a code result opens at: where the name is defined or the query's words are, else where its stretch
    /// starts (a notebook's at its top: editors can't be told a cell).
    var codeLine: Int {
        segment == .lines ? max(1, Int(focus ?? loc ?? 1)) : 1
    }
}

/// Quick Look (Space) at the page or moment. Quick Look's panel takes a display state only once its preview is up:
/// set within ~0.1 s it's ignored (and a movie plays from the start); from ~0.6 s it holds, checked on screen
/// 2026-10-08. What it reads back is just the last value set, so it can't confirm the jump: it's set at 0.6 s and once
/// more at 1.2 s for a file that loads slowly (the time is absolute, so a second set that isn't needed changes nothing).
enum QuickLookMoment {
    private static var generation = 0

    /// `now`: the preview is already up (the same files, at a new place), so the state is set at once too. Either way a
    /// newer call replaces what an older one still has to set.
    static func show(_ row: ResultRow?, in panel: QLPreviewPanel, now: Bool = false) {
        generation += 1
        let current = generation
        guard let row else { return }
        // Page 1 or the start: nothing to jump to when the preview opens, but a preview already elsewhere goes back.
        guard let state = row.quickLookState
                ?? (now ? row.page != nil ? ["CurrentPage": 0] : row.moment != nil ? ["CurrentTime": 0] : nil : nil)
        else { return }
        if now { panel.displayState = state }
        for delay in [0.6, 1.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard current == generation, panel.isVisible,
                      (panel.currentPreviewItem?.previewItemURL)?.path == row.url.path else { return }
                panel.displayState = state
                if delay == 0.6 { log("quick look: \(row.name) at \(row.place ?? "?")") }
            }
        }
    }
}

/// One thing Quick Look (Space) shows, under the name the result goes by: a Photos library's file is named after its
/// asset's uuid, so Quick Look's title would be "1EB2B765-….jpeg" without it.
final class QuickLookItem: NSObject, QLPreviewItem {
    let previewItemURL: URL?
    let previewItemTitle: String?

    init(url: URL, title: String) {
        previewItemURL = url
        previewItemTitle = title
    }
}

extension ResultRow {
    /// What Space shows, and which of it first. A video in iCloud (read from Photos' filmstrip or poster): once Space
    /// has downloaded it, the video itself (`QuickLookDownload`); until then every still of it, from the one that
    /// matched (Quick Look's arrows and its index sheet go through them), or its poster, titled with how the download
    /// is going. Anything else: the file.
    var quickLook: (items: [QuickLookItem], start: Int) {
        if kind == .video, let photos, let still = photos.still {
            if let video = PhotosDownloads.shared.video(of: photos.uuid) {
                return ([QuickLookItem(url: video, title: name)], 0)
            }
            let note: String
            switch PhotosDownloads.shared.state(of: photos.uuid) {
            case .failed(let why): note = "the video is in iCloud: \(why)"
            case .done: note = "downloaded, but Quick Look can't play it: Open shows it in Photos"
            default: note = "downloading the video from iCloud…"
            }
            let stills = photos.reading == .stills ? PhotosLibrary.filmstrip(startingAt: url.path) : []
            if stills.count > 1 {
                let items = stills.enumerated().map { index, path in
                    QuickLookItem(url: URL(fileURLWithPath: path),
                                  title: "\(name) · still \(index + 1) of \(stills.count) (\(note))")
                }
                return (items, stills.firstIndex(of: still) ?? 0)
            }
            return ([QuickLookItem(url: URL(fileURLWithPath: still), title: "\(name) (\(note))")], 0)
        }
        return ([QuickLookItem(url: url, title: name)], 0)
    }

    /// A video of the Photos library that's only in iCloud and hasn't been downloaded since the app started (a download
    /// that gave no file Quick Look can play counts as done).
    var needsVideoDownload: Bool {
        guard kind == .video, let photos, photos.reading?.isStandIn == true else { return false }
        return PhotosDownloads.shared.video(of: photos.uuid) == nil && PhotosDownloads.shared.state(of: photos.uuid) != .done
    }
}

/// Space on a video in iCloud: Photos downloads it (as Download Original does, and keeps it in the library), and Quick
/// Look then plays it in place of its stills (Jon, 2026-10-22). A showing is what Quick Look shows from when it opens
/// or its files change until they change again. A download is set off once a showing has lasted 0.6 s (arrowing past
/// results doesn't download every video on the way), at most once a showing (a failure says why in the stills' titles
/// and is tried again only when Quick Look shows the video anew), and what it brings is shown whenever it ends while
/// Quick Look shows that video, in that showing or a later one.
enum QuickLookDownload {
    fileprivate static var showing = 0
    /// The showing a download was last set off in.
    fileprivate static var setOff = -1
    /// What Quick Look was last told to show, at its place then, and by which window or panel (the search window and
    /// the panel each hand Quick Look their own items).
    fileprivate static var latest: ResultRow?
    fileprivate static weak var source: (any QuickLookSource)?
}

/// The window or panel that hands Quick Look the selected result (`QLPreviewPanelDataSource`): what it shows now.
protocol QuickLookSource: AnyObject {
    var previewItems: [QuickLookItem] { get set }
    /// Where in them it was last told to show: the first item, and the page or moment.
    var previewPlace: String { get set }
}

extension QuickLookSource {
    /// Quick Look shows `row` (or nothing), from its first item to show, at its page or moment.
    func showInQuickLook(_ row: ResultRow?) {
        let panel = QLPreviewPanel.shared()!
        let (items, start) = row?.quickLook ?? ([], 0)
        let place = "\(start) \(row?.page ?? 0) \(row?.moment ?? -1)"
        let sameFiles = items.map(\.previewItemURL) == previewItems.map(\.previewItemURL)
        let sameTitles = items.map(\.previewItemTitle) == previewItems.map(\.previewItemTitle)
        let samePlace = place == previewPlace
        previewItems = items
        previewPlace = place
        if !sameFiles || !panel.isVisible { QuickLookDownload.showing += 1 }
        QuickLookDownload.latest = row
        QuickLookDownload.source = self
        if let row, row.needsVideoDownload, QuickLookDownload.setOff != QuickLookDownload.showing {
            downloadVideo(of: row)
        }
        if sameFiles, panel.isVisible {
            if !sameTitles {
                // Only the stills' titles changed (their video's download failed): no movie to restart.
                let index = panel.currentPreviewItemIndex
                panel.reloadData()
                panel.currentPreviewItemIndex = samePlace ? index : start
                return
            }
            // The same files showing (a key that didn't move the selection, or the same file matching elsewhere):
            // reloading them would restart a movie, so only a new place in them moves Quick Look.
            guard !samePlace else { return }
            if panel.currentPreviewItemIndex != start { panel.currentPreviewItemIndex = start }
            QuickLookMoment.show(row, in: panel, now: true)
            return
        }
        panel.reloadData()
        if start > 0 { panel.currentPreviewItemIndex = start }
        QuickLookMoment.show(row, in: panel)
    }

    /// Sets off `row`'s download in this showing (`QuickLookDownload`), and when it ends has the window or panel Quick
    /// Look shows for now show what it was last told to, if that's still the video: the video, or its stills with why
    /// it failed.
    private func downloadVideo(of row: ResultRow) {
        guard let uuid = row.photos?.uuid else { return }
        let showing = QuickLookDownload.showing
        QuickLookDownload.setOff = showing
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, QuickLookDownload.showing == showing, QLPreviewPanel.shared().isVisible else { return }
            // A download set off in an earlier showing may have ended during this one's wait.
            guard row.needsVideoDownload else { return showInQuickLook(QuickLookDownload.latest) }
            PhotosDownloads.shared.start(uuid) {
                guard QLPreviewPanel.shared().isVisible, QuickLookDownload.latest?.photos?.uuid == uuid else { return }
                QuickLookDownload.source?.showInQuickLook(QuickLookDownload.latest)
            }
        }
    }
}

extension Engine {
    /// Opens `row` in its app: a PDF with words from its page to search for, a recording at its moment when the app
    /// can be told it (see `Opener`).
    func open(_ row: ResultRow) {
        if let photos = row.photos { return Opener.showInPhotos(photos.uuid, name: row.name) }
        if row.kind == .code { return CodeEditor.current.open(row.url, line: row.codeLine) }
        guard let page = row.page else { return Opener.open(row, searching: nil) }
        let (url, words) = (row.url, row.foundWords + row.terms)
        Task {
            let found = await Task.detached(priority: .userInitiated) { () -> String? in
                // The PDF's own text, as Preview will search it (not the index's, which may come from OCR).
                guard let document = PDFDocument(url: url), document.pageCount >= page else { return nil }
                let texts = (0..<page).map { document.page(at: $0)?.string ?? "" }
                return Landmark.find(page: page, texts: texts, words: words)
            }.value
            Opener.open(row, searching: found)
        }
    }
}

/// Opens a result in its app:
/// - a PDF page: with words from that page to search for, as Spotlight opens documents (Preview fills its search with
///   them and lists the matches by page; it doesn't go to the first one by itself, checked 2026-10-08)
/// - a moment in QuickTime Player: it's asked to go there (macOS asks once whether DigUp may control it; without
///   that, the recording opens at the start)
/// - a moment in IINA: its URL scheme takes a start time
enum Opener {
    static let quickTime = "com.apple.QuickTimePlayerX"
    static let iina = "com.colliderli.iina"
    /// Debug runs (`-debugOpen dry`): say how it would open, and don't.
    static var dryRun = false

    /// The file's app can be told where in a recording to start.
    static func jumpsToMoments(_ url: URL) -> Bool {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return false }
        return [quickTime, iina].contains(Bundle(url: app)?.bundleIdentifier)
    }

    /// Shows the file in Finder; a picture in a Photos library, in Photos (Finder would show the library's insides,
    /// which are Photos' to change).
    static func reveal(_ url: URL) {
        if let asset = PhotosLibrary.asset(ofFile: url.path) {
            return showInPhotos(asset.uuid, name: url.lastPathComponent)
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func revealTitle(_ url: URL) -> String {
        PhotosLibrary.asset(ofFile: url.path) == nil ? "Show in Finder" : "Show in Photos"
    }

    /// Shows a picture or video of the Photos library in Photos, as Spotlight does (macOS asks once whether DigUp may
    /// control Photos). Photos shows it if it's in the library it has open; failing that, Photos just comes forward.
    /// osascript, as for QuickTime Player, so that macOS's question doesn't block the main thread.
    static func showInPhotos(_ uuid: String, name: String) {
        let photos = URL(fileURLWithPath: "/System/Applications/Photos.app")
        if dryRun {
            log("open (dry run): \(name) in Photos")
            return
        }
        log("open: \(name) in Photos")
        let script = """
            on run argv
                tell application "Photos"
                    activate
                    spotlight media item id (item 1 of argv)
                end tell
            end run
            """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script, "\(uuid)/L0/001"]   // a media item's id in Photos' scripting
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        process.terminationHandler = { process in
            guard process.terminationStatus != 0 else { return }
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                log("open: Photos didn't show it (\(message.trimmingCharacters(in: .whitespacesAndNewlines)))")
                NSWorkspace.shared.openApplication(at: photos, configuration: NSWorkspace.OpenConfiguration())
            }
        }
        do {
            try process.run()
        } catch {
            NSWorkspace.shared.openApplication(at: photos, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// `words`: what to search for in a PDF (`Landmark.find`).
    static func open(_ row: ResultRow, searching words: String?) {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: row.url) else {
            if !dryRun { NSWorkspace.shared.open(row.url) }
            return
        }
        let appID = Bundle(url: app)?.bundleIdentifier
        let appName = app.deletingPathExtension().lastPathComponent
        let moment = row.moment.flatMap { $0 >= 1 ? $0 : nil }
        if dryRun {
            let how = if let words { "searching “\(words)”" }
                else if let moment, appID == iina || appID == quickTime { "at \(ResultRow.clock(moment))" }
                else { "at the start" }
            log("open (dry run): \(row.name) in \(appName) \(how)")
            return
        }
        if let words {
            log("open: \(row.name) in \(appName), searching \(searchWords(words))")
            // The event alone, as the app's first event: given the file as well, NSWorkspace sends its own event,
            // without the search.
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.appleEvent = openEvent(row.url, searching: words)
            NSWorkspace.shared.openApplication(at: app, configuration: configuration)
        } else if let moment, appID == iina, let link = iinaLink(row.url, at: moment) {
            log("open: \(row.name) at \(ResultRow.clock(moment)) in IINA")
            NSWorkspace.shared.open(link)
        } else if let moment, appID == quickTime {
            log("open: \(row.name) at \(ResultRow.clock(moment)) in QuickTime Player")
            openInQuickTime(row.url, at: moment)
        } else {
            log("open: \(row.name)")
            NSWorkspace.shared.open(row.url)
        }
    }

    /// The Open Documents event, with the text to search for in them (keyAESearchText).
    static func openEvent(_ url: URL, searching text: String) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass),
                                           eventID: AEEventID(kAEOpenDocuments), targetDescriptor: nil,
                                           returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        let files = NSAppleEventDescriptor.list()
        files.insert(NSAppleEventDescriptor(fileURL: url), at: 0)
        event.setParam(files, forKeyword: keyDirectObject)
        event.setParam(NSAppleEventDescriptor(string: text), forKeyword: AEKeyword(keyAESearchText))
        return event
    }

    static func iinaLink(_ url: URL, at seconds: Double) -> URL? {
        var components = URLComponents(string: "iina://open")
        components?.queryItems = [URLQueryItem(name: "url", value: url.absoluteString),
                                  URLQueryItem(name: "mpv_start", value: String(format: "%.1f", seconds))]
        return components?.url
    }

    /// osascript rather than NSAppleScript: macOS's "control QuickTime Player?" question would otherwise block the
    /// main thread until it's answered. The time goes over as whole milliseconds (a decimal point depends on locale).
    private static func openInQuickTime(_ url: URL, at seconds: Double) {
        let script = """
            on run argv
                set theFile to POSIX file (item 1 of argv)
                set theTime to (item 2 of argv as integer) / 1000
                tell application "QuickTime Player"
                    activate
                    set theDocument to open theFile
                    set current time of theDocument to theTime
                    try
                        set miniaturized of (first window whose document is theDocument) to false
                    end try
                    play theDocument
                    return current time of theDocument
                end tell
            end run
            """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script, url.path, String(Int(seconds * 1000))]
        let errors = Pipe(), output = Pipe()
        process.standardError = errors
        process.standardOutput = output
        process.terminationHandler = { process in
            guard process.terminationStatus != 0 else {
                let at = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                DispatchQueue.main.async {
                    log("open: QuickTime Player is at \(at.trimmingCharacters(in: .whitespacesAndNewlines)) s")
                }
                return
            }
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                log("open: QuickTime Player didn't go to the moment (\(message.trimmingCharacters(in: .whitespacesAndNewlines)))")
                // Not allowed to control it (-1743), no answer to macOS's question (-1712), or any other failure: open
                // it the plain way (a recording that did open just comes forward).
                NSWorkspace.shared.open(url)
            }
        }
        do {
            try process.run()
        } catch {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Plays the selected recording in the preview pane, from the moment that matched or the one picked under it. One at a
/// time; it stops when the selection moves, or the panel or window closes.
@Observable
final class PreviewPlayback {
    static let shared = PreviewPlayback()

    private(set) var playingKey: String?
    private(set) var isPlaying = false
    /// Seconds into the recording, while it plays.
    private(set) var time: Double = 0
    /// The moment or still last picked under the window's preview (`MomentsSection`): the result at it, kept under the
    /// result as the search gave it (`pickKey`). The pane shows it, and Quick Look and Open go there (`placed`).
    private(set) var picked: (key: String, row: ResultRow)?
    @ObservationIgnored private(set) var player: AVPlayer?
    /// The file `player` plays.
    @ObservationIgnored private var playingFile: String?
    @ObservationIgnored private var observer: Any?
    /// Debug runs keep quiet.
    @ObservationIgnored var muted = false

    func isCurrent(_ row: ResultRow) -> Bool { playingKey == row.previewKey }

    /// A result and its search (`ResultRow.searched`): what a pick is kept under (a new search may find the file
    /// matching elsewhere, or in other parts of it).
    private static func pickKey(_ row: ResultRow) -> String { "\(row.previewKey)|\(row.searched)" }

    /// Picks `moment` of `row`, as a click under the preview does: `row` is at it from then on (until another is
    /// picked), and plays from there. A still is in `filmstrip`, the video's stills in order.
    func pick(_ moment: Moment, of row: ResultRow, filmstrip: [String]) {
        let placed = row.at(moment, filmstrip: filmstrip)
        picked = (Self.pickKey(row), placed)
        if placed.moment != nil { play(placed) }
    }

    /// Picks one of Photos' stills of a video in iCloud (`row`), the `index`th of its filmstrip, to show.
    func pick(still: String, at index: Int, of row: ResultRow) {
        picked = (Self.pickKey(row), row.showing(still: still, at: index))
    }

    /// `row` at the moment or still last picked for it, else as the search gave it.
    func placed(_ row: ResultRow) -> ResultRow {
        guard let picked, picked.key == Self.pickKey(row) else { return row }
        return picked.row
    }

    /// Play/pause for this row; a different row starts from its moment.
    func toggle(_ row: ResultRow) {
        if isCurrent(row), let player {
            if isPlaying { player.pause() } else { player.play() }
            isPlaying.toggle()
            return
        }
        play(row)
    }

    /// Plays `row` from its moment; the recording already playing (another of its moments picked) goes there.
    func play(_ row: ResultRow) {
        let player: AVPlayer
        if let current = self.player, playingFile == row.id {
            player = current
        } else {
            stop()
            player = AVPlayer(url: row.url)
            player.isMuted = muted
            observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
                                                      queue: .main) { [weak self] time in
                MainActor.assumeIsolated { self?.time = time.seconds }
            }
            self.player = player
            playingFile = row.id
        }
        let start = CMTime(seconds: row.moment ?? 0, preferredTimescale: 600)
        player.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak player] finished in
            guard finished else { return }
            DispatchQueue.main.async {
                // Unless it was stopped (or another one started) meanwhile.
                guard let self, let player, self.player === player, self.isPlaying else { return }
                player.play()
            }
        }
        playingKey = row.previewKey
        time = row.moment ?? 0
        isPlaying = true
        log("preview: playing \(row.name) from \(ResultRow.clock(row.moment ?? 0))")
    }

    func stop() {
        guard let player else { return }
        player.pause()
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
        self.player = nil
        playingFile = nil
        playingKey = nil
        isPlaying = false
    }
}

/// AVKit's player view, for a video playing in the preview pane.
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = false
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

/// Under a recording's picture in the window: every moment of it that matched, best first, on a strip the length of
/// the recording (a video in iCloud: along Photos' stills of it, which carry no time, all of them whether or not one
/// matched) and in a list. A click on a mark, a still or a row plays from there (shows that still), and the result is
/// at it from then on (`PreviewPlayback.pick`).
struct MomentsSection: View {
    /// The result as the search gave it, and as the pane shows it (at the moment last picked).
    let row: ResultRow
    let shown: ResultRow
    let moments: [Moment]
    /// A video in iCloud: Photos' stills of it, in order.
    let filmstrip: [String]
    let width: CGFloat
    /// A moment or still was picked.
    let picked: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if row.photos?.reading == .stills {
                if !filmstrip.isEmpty {
                    StillsStrip(filmstrip: filmstrip, matched: Set(moments.compactMap(\.still)),
                                showing: shown.photos?.still, width: width,
                                hidden: { index in
                                    SensitiveBlur.shared.hides(
                                        row.pictures.flatMap { $0.shown($0.frame(atPlace: index)) })
                                }, pick: pick(still:))
                }
            } else if let duration {
                MomentStrip(row: shown, moments: moments.filter { $0.start != nil }, duration: duration, width: width,
                            label: label, isAt: isAt, pick: pick(_:))
            }
            if !moments.isEmpty {
                MomentList(moments: moments, label: label, isAt: isAt, pick: pick(_:), marked: row.markedWords)
            }
        }
    }

    /// The recording's length as indexing measured it, else as far as its moments go.
    private var duration: Double? {
        row.duration ?? moments.compactMap(\.end).max()
    }

    /// "0:42–0:51 · seen", "2:10–2:40 · heard", "0:12–0:38 · said", "Still 3 of 7 · seen"
    private func label(_ moment: Moment) -> String {
        let kind = moment.kind.rawValue
        if let still = moment.still { return "Still \(still + 1) of \(filmstrip.count) · \(kind)" }
        guard let start = moment.start else { return kind }
        return "\(ResultRow.clock(start))–\(ResultRow.clock(moment.end ?? start)) · \(kind)"
    }

    private func isAt(_ moment: Moment) -> Bool { shown.isAt(moment, filmstrip: filmstrip) }

    /// A click on a moment or a still shows it: blurred, that picture shows from then on (`SensitiveBlur`).
    private func pick(_ moment: Moment) {
        SensitiveBlur.shared.show(row.at(moment, filmstrip: filmstrip))
        PreviewPlayback.shared.pick(moment, of: row, filmstrip: filmstrip)
        picked()
    }

    private func pick(still: String) {
        let index = filmstrip.firstIndex(of: still) ?? 0
        SensitiveBlur.shared.show(row.showing(still: still, at: index))
        PreviewPlayback.shared.pick(still: still, at: index, of: row)
        picked()
    }
}

/// A recording from start to end, each moment that matched marked (amber; the one the preview is at deeper; each kind,
/// seen, heard or said, on a lane of its own when it matched more than one way) and the playhead drawn across it, apart
/// from the marks. A click on a mark plays from it. Hovering shows the frame there (`Previews.frame`), made where the
/// pointer stops and dropped when it leaves: nothing is kept.
struct MomentStrip: View {
    /// The recording, at the moment the preview shows.
    let row: ResultRow
    let moments: [Moment]
    let duration: Double
    let width: CGFloat
    let label: (Moment) -> String
    let isAt: (Moment) -> Bool
    let pick: (Moment) -> Void
    @State private var pointer: (x: CGFloat, seconds: Double)?
    @State private var frame: NSImage?
    @State private var request: Task<Void, Never>?
    @Environment(\.displayScale) private var scale
    private var playback: PreviewPlayback { .shared }
    private static let height: CGFloat = 22
    private static let cardWidth: CGFloat = 148

    var body: some View {
        ZStack(alignment: .topLeading) {
            Capsule()
                .fill(Color.primary.opacity(0.1))
                .frame(width: width, height: 4)
                .offset(y: (Self.height - 4) / 2)
            ForEach(moments, id: \.segmentID) { moment in mark(moment) }
            if playback.isCurrent(row) { playhead(at: playback.time) }
        }
        .frame(width: width, height: Self.height, alignment: .topLeading)
        .contentShape(Rectangle())
        .onContinuousHover { hover($0) }
        .overlay(alignment: .bottomLeading) { if let pointer { card(pointer) } }
        .onDisappear { request?.cancel() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(moments.count) moments in \(ResultRow.clock(duration))")
    }

    /// What's seen, heard and said each get a lane when the recording matched more than one way.
    private var lanes: [Moment.Kind] {
        [.seen, .heard, .said].filter { kind in moments.contains { $0.kind == kind } }
    }

    private func x(_ seconds: Double) -> CGFloat { width * CGFloat(max(0, min(1, seconds / duration))) }

    private func mark(_ moment: Moment) -> some View {
        let length = min(width, max(5, x(moment.end ?? 0) - x(moment.start ?? 0)))
        let laneHeight = (Self.height - 4) / CGFloat(max(lanes.count, 1))
        let lane = CGFloat(lanes.firstIndex(of: moment.kind) ?? 0)
        let at = isAt(moment)
        return RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(at ? Brand.ember : Brand.amber.opacity(0.75))
            .overlay(RoundedRectangle(cornerRadius: 2, style: .continuous)
                .strokeBorder(Color.primary.opacity(at ? 0.45 : 0), lineWidth: 1))
            .frame(width: length, height: laneHeight - 2)
            .offset(x: min(x(moment.start ?? 0), width - length), y: 3 + lane * laneHeight)
            .onTapGesture { pick(moment) }
            .accessibilityElement()
            .accessibilityLabel("Play \(label(moment))")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { pick(moment) }
    }

    /// Where playback is: a line across the strip, taller than the marks and ringed, so it stands apart from them.
    private func playhead(at seconds: Double) -> some View {
        Capsule()
            .fill(Color.primary)
            .frame(width: 2, height: Self.height + 4)
            .background(Capsule().fill(Color(nsColor: .windowBackgroundColor)).padding(-1.5))
            .offset(x: x(seconds) - 1, y: -2)
            .allowsHitTesting(false)
    }

    private func hover(_ phase: HoverPhase) {
        switch phase {
        case .active(let location):
            let seconds = duration * Double(max(0, min(1, location.x / width)))
            pointer = (location.x, seconds)
            guard row.kind == .video else { return }
            request?.cancel()
            let (url, scale) = (row.url, scale)
            request = Task {
                // Only where the pointer stops: a frame for every point it crosses would queue up behind it.
                try? await Task.sleep(for: .milliseconds(60))
                guard !Task.isCancelled,
                      let picture = await Previews.frame(of: url, at: seconds, pixels: Self.cardWidth * scale),
                      !Task.isCancelled else { return }
                frame = NSImage(cgImage: picture, size: NSSize(width: CGFloat(picture.width) / scale,
                                                               height: CGFloat(picture.height) / scale))
            }
        case .ended:
            request?.cancel()
            request = nil
            pointer = nil
            frame = nil
        }
    }

    /// What's under the pointer: the time, and for a video its frame there.
    private func card(_ pointer: (x: CGFloat, seconds: Double)) -> some View {
        let cardWidth = row.kind == .video ? Self.cardWidth : 52
        return VStack(spacing: 3) {
            if row.kind == .video {
                ZStack {
                    Color.black.opacity(0.85)
                    if let frame {
                        let hidden = SensitiveBlur.shared.hides(
                            row.pictures.flatMap { $0.shown($0.frame(at: pointer.seconds)) })
                        Image(nsImage: frame.veiled(hidden)).resizable().interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .sensitiveCover(hidden, iconSize: 14)
                    }
                }
                .frame(width: cardWidth - 8, height: (cardWidth - 8) * 9 / 16)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            Text(ResultRow.clock(pointer.seconds))
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
        }
        .padding(4)
        .frame(width: cardWidth)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 4, y: 1)
        .offset(x: max(0, min(width - cardWidth, pointer.x - cardWidth / 2)), y: -(Self.height + 6))
        .allowsHitTesting(false)
    }
}

/// A video in iCloud along Photos' stills of it, in order (they carry no time, so there's no timeline): the ones that
/// matched marked under them as the strip marks moments, the one the preview shows ringed. A click shows that still.
struct StillsStrip: View {
    let filmstrip: [String]
    /// Places in the filmstrip that matched.
    let matched: Set<Int>
    /// The still the preview shows.
    let showing: String?
    let width: CGFloat
    /// Whether the still at this place is blurred (`SensitiveBlur`).
    let hidden: (Int) -> Bool
    let pick: (String) -> Void
    private static let spacing: CGFloat = 4

    var body: some View {
        let count = CGFloat(filmstrip.count)
        let side = max(28, min(48, (width - Self.spacing * (count - 1)) / count))
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Self.spacing) {
                ForEach(Array(filmstrip.enumerated()), id: \.offset) { index, path in
                    still(path, at: index, side: side)
                }
            }
        }
        .frame(width: width, height: side + 6)
    }

    private func still(_ path: String, at index: Int, side: CGFloat) -> some View {
        let name = "Still \(index + 1) of \(filmstrip.count)" + (matched.contains(index) ? ", matched" : "")
        return VStack(spacing: 2) {
            ThumbnailView(url: URL(fileURLWithPath: path), side: side, veiled: hidden(index))
                .sensitiveCover(hidden(index), iconSize: max(9, side / 4))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(path == showing ? Color.accentColor : Color.primary.opacity(0.12),
                                  lineWidth: path == showing ? 2.5 : 0.5))
            Capsule()
                .fill(matched.contains(index) ? Brand.amber : Color.clear)
                .frame(width: side - 8, height: 4)
        }
        .contentShape(Rectangle())
        .onTapGesture { pick(path) }
        .help("Show still \(index + 1) of \(filmstrip.count)")
        .accessibilityElement()
        .accessibilityLabel(name)
        .accessibilityAddTraits(path == showing ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { pick(path) }
    }
}

/// The moments as a list, best first ("0:42–0:51 · seen"), the one the preview is at lit, and under a moment of what's
/// said, its words, the query's marked. A click plays one (shows the still). The best few show, the rest a click away.
struct MomentList: View {
    let moments: [Moment]
    let label: (Moment) -> String
    let isAt: (Moment) -> Bool
    let pick: (Moment) -> Void
    /// The words to mark in what's said (`ResultRow.markedWords`).
    let marked: Set<String>
    @State private var showsAll = false
    private static let few = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(showsAll ? moments : Array(moments.prefix(Self.few)), id: \.segmentID) { moment in
                item(moment)
            }
            if moments.count > Self.few {
                Button(showsAll ? "Show fewer" : "Show all \(moments.count) moments") { showsAll.toggle() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.top, 2)
            }
        }
    }

    private func item(_ moment: Moment) -> some View {
        Button { pick(moment) } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Image(systemName: Self.symbol(moment.kind))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Brand.ember)
                        .frame(width: 14)
                    Text(label(moment))
                    Spacer(minLength: 0)
                }
                .font(.system(size: 11.5).monospacedDigit())
                if let words = moment.words {
                    Text(marking(marked, in: words))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .padding(.leading, 21)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isAt(moment) ? Color.accentColor.opacity(0.18) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isAt(moment) ? .isSelected : [])
    }

    private static func symbol(_ kind: Moment.Kind) -> String {
        switch kind {
        case .seen: "eye"
        case .heard: "ear"
        case .said: "quote.bubble"
        }
    }
}
