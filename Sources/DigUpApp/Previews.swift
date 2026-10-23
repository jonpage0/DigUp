import AVFoundation
import AppKit
import DigUpKit
import PDFKit
import QuickLookThumbnailing
import SwiftUI

/// Big pictures for the preview pane: the picture itself, the video frame at the moment that matched, or the PDF page
/// that matched. Cached while the panel or a window is open, and dropped with the thumbnails when they close.
final class Previews {
    static let shared = Previews()
    private let cache = NSCache<NSString, NSImage>()
    /// The text of a document's passage, a stretch of code or a stretch of what's said (`Engine.text(ofSegment:code:)`),
    /// set when the app starts.
    var passage: (Int64, Bool) async -> String? = { _, _ in nil }
    /// Every moment of a recording that matches a query, by path, query and the parts the search kept to
    /// (`Engine.moments(of:matching:matchBy:)`), set when the app starts. Not cached: the preview asks once a result.
    var moments: (String, String, SearchFilter.MatchBy?) async -> [Moment] = { _, _, _ in [] }

    init() {
        cache.totalCostLimit = 48 << 20
    }

    func cached(_ row: ResultRow, side: CGFloat) -> NSImage? {
        cache.object(forKey: key(row, side))
    }

    func load(_ row: ResultRow, side: CGFloat, scale: CGFloat) async -> NSImage? {
        if let image = cached(row, side: side) { return image }
        var picture: CGImage?
        if row.kind == .video, let still = row.photos?.still {
            // A video in iCloud: the still of it that matched (Photos' filmstrip or poster).
            picture = await Self.thumbnail(URL(fileURLWithPath: still), side: side, scale: scale)
        } else if row.kind == .video, let loc = row.loc {
            picture = await Self.frame(of: row.url, at: loc, pixels: side * scale)
        } else if row.kind == .image, row.segment == .frame, let loc = row.loc {
            picture = await Self.animationFrame(of: row.url, at: loc, pixels: side * scale)
        } else if let page = row.page {
            picture = await Self.page(page, of: row.url, pixels: side * scale, marking: row.foundWords + row.terms)
        }
        if picture == nil { picture = await Self.thumbnail(row.url, side: side, scale: scale) }
        guard let picture else { return nil }
        let image = NSImage(cgImage: picture, size: NSSize(width: CGFloat(picture.width) / scale,
                                                           height: CGFloat(picture.height) / scale))
        cache.setObject(image, forKey: key(row, side), cost: picture.bytesPerRow * picture.height)
        return image
    }

    func clear() {
        cache.removeAllObjects()
    }

    /// What a picture depends on: the file, the page or moment, and for a page the words marked on it.
    func key(_ row: ResultRow, _ side: CGFloat) -> NSString {
        "\(Int(side)) \(row.previewKey) \(row.page == nil ? "" : (row.foundWords + row.terms).joined(separator: " "))"
            as NSString
    }

    /// The frame at `seconds` (within half a second, so it's a quick seek). Also what the window's moment strip shows
    /// under the pointer (`MomentStrip`), which keeps none of them.
    nonisolated static func frame(of url: URL, at seconds: Double, pixels: CGFloat) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: pixels, height: pixels)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        return try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    }

    /// An animated GIF's frame shown at `seconds`: its start is the delays of the frames before it, counted as the
    /// indexer counts them (`ImageExtractor.animationFrames`).
    private nonisolated static func animationFrame(of url: URL, at seconds: Double, pixels: CGFloat) async -> CGImage? {
        await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            var start = 0.0, index = 0
            for frame in 0..<CGImageSourceGetCount(source) {
                if start > seconds + 0.001 { break }
                index = frame
                let gif = (CGImageSourceCopyPropertiesAtIndex(source, frame, nil) as? [CFString: Any])?[
                    kCGImagePropertyGIFDictionary] as? [CFString: Any]
                start += (gif?[kCGImagePropertyGIFDelayTime] ?? gif?[kCGImagePropertyGIFUnclampedDelayTime]) as? Double ?? 0
            }
            return CGImageSourceCreateThumbnailAtIndex(source, index, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: pixels,
            ] as CFDictionary)
        }.value
    }

    /// Page `number` (1-based), fitted into a square of `pixels`, with `words` marked where they're on it, the way
    /// Preview marks what you searched for. With marks, it shows the band of the page around them (as wide as the page,
    /// 2:3 as high), so the words can be read in a small preview.
    private nonisolated static func page(_ number: Int, of url: URL, pixels: CGFloat, marking words: [String]) async
        -> CGImage? {
        await Task.detached(priority: .userInitiated) {
            guard let document = PDFDocument(url: url),
                  let page = document.page(at: max(0, number - 1)) ?? document.page(at: 0) else { return nil }
            let transform = page.transform(for: .cropBox)
            let bounds = page.bounds(for: .cropBox).applying(transform)
            let marks = Self.places(of: words, on: page)
            var shown = CGRect(origin: .zero, size: bounds.size)
            if let first = marks.first?.applying(transform) {
                let height = min(bounds.height, bounds.width / 1.5)
                let top = min(max(0, first.midY - height * 0.55), bounds.height - height)
                shown = CGRect(x: 0, y: top, width: bounds.width, height: height)
            }
            let scale = pixels / max(shown.width, shown.height, 1)
            let width = max(1, Int(shown.width * scale)), height = max(1, Int(shown.height * scale))
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.setFillColor(.white)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -shown.minX, y: -shown.minY)
            page.draw(with: .cropBox, to: context)
            if !marks.isEmpty {
                context.concatenate(transform)
                context.setBlendMode(.multiply)
                context.setFillColor(CGColor(red: 1, green: 0.85, blue: 0.1, alpha: 0.85))
                for rect in marks { context.fill(rect.insetBy(dx: -1, dy: -1)) }
            }
            return context.makeImage()
        }.value
    }

    /// Where `words` are on `page` (as keyword search finds them: `SearchText.matches`), in page space.
    private nonisolated static func places(of words: [String], on page: PDFPage) -> [CGRect] {
        guard let text = page.string, !text.isEmpty else { return [] }
        var rects: [CGRect] = []
        for word in Set(words.filter { $0.count >= 2 }) {
            for found in SearchText.matches(of: word, in: text).prefix(200) {
                guard let selection = page.selection(for: NSRange(found, in: text)) else { continue }
                rects += selection.selectionsByLine().map { $0.bounds(for: page) }
            }
        }
        return rects
    }

    /// Quick Look's picture of the file (the system caches these across apps).
    private nonisolated static func thumbnail(_ url: URL, side: CGFloat, scale: CGFloat) async -> CGImage? {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side), scale: scale,
                                                   representationTypes: .thumbnail)
        return await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                continuation.resume(returning: representation?.cgImage)
            }
        }
    }
}

/// The selected result, big: its picture (or the frame or page that matched), what it is, and why it's here. A
/// recording that matched in more places than one marks them all.
struct PreviewPane: View {
    let row: ResultRow
    /// The picture's box.
    let imageSize: CGSize
    /// A double-click on the picture or passage: the file in its app, like Open.
    var open: () -> Void = {}
    /// The window's pane: a recording's moments under its picture, as a strip and a list to play them from, and the
    /// result shown at the one last picked (`MomentsSection`). The panel has room only to mark them on the picture.
    var exploresMoments = false
    /// A moment or still was picked under the picture (the window's Quick Look follows).
    var picked: () -> Void = {}
    /// What you can say of the faces in a picture outside Photos (the window's preview; none in the panel's).
    var telling: FaceTelling?
    @State private var found: Found?

    /// What was found for one result (`key`): its moments for the query, and a video in iCloud's stills in order.
    private struct Found {
        let key: String
        let moments: [Moment]
        let filmstrip: [String]
    }

    var body: some View {
        let shown = exploresMoments ? PreviewPlayback.shared.placed(row) : row
        VStack(alignment: .leading, spacing: 0) {
            // With the strip under it, the picture sits at the bottom of its box, on the strip.
            PreviewPicture(row: shown, size: imageSize, open: open, stretches: barStretches,
                           alignment: showsMoments ? .bottom : .center, telling: telling)
                .frame(maxWidth: .infinity)
            if showsMoments {
                MomentsSection(row: row, shown: shown, moments: current?.moments ?? [],
                               filmstrip: current?.filmstrip ?? [], width: imageSize.width, picked: picked)
                    .id(foundKey)
                    .padding(.top, 10)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(row.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Button {
                    Opener.reveal(row.url)
                } label: {
                    Text(row.folder).lineLimit(1).truncationMode(.head)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .help(row.revealTitle)
                Text(row.details)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.top, 12)
            WhyItMatched(row: shown)
                .padding(.top, 12)
            if let telling, row.segment != .frame, !row.faces.isEmpty {
                NotThem(row: row, telling: telling)
                    .padding(.top, 8)
            }
            Spacer(minLength: 0)
        }
        .task(id: foundKey) { await find() }
    }

    /// One result's, of one search (`ResultRow.searched`: its query and Match by): the meaning results that follow a
    /// search's first, keyword-only ones count its moments, and a video in iCloud read while it's selected gets its
    /// stills (`info["frames"]`), which bring its strip.
    private var foundKey: String { "\(row.id)|\(row.searched)|\(row.momentCount)|\(row.info["frames"] ?? "")" }

    /// What was found for this result (nothing yet, while it's being looked for).
    private var current: Found? { found?.key == foundKey ? found : nil }

    /// The moments under the picture, in the window: a recording that matched somewhere in it, or a video in iCloud
    /// read from more than one of Photos' stills, which line up whether or not one matched (it may be here by Photos'
    /// words alone). A poster video has only the one picture.
    private var showsMoments: Bool {
        guard exploresMoments else { return false }
        if row.photos?.reading == .stills { return (row.info["frames"].flatMap(Int.init) ?? 0) > 1 }
        return row.momentCount > 0 && row.photos?.reading != .poster
    }

    /// What the bar on a recording's picture marks: nothing when the strip under it shows the moments, else every one
    /// found, or until they are the one the result points at.
    private var barStretches: [ClosedRange<Double>] {
        if showsMoments { return [] }
        let all = (current?.moments ?? []).compactMap { moment in
            moment.start.map { $0...max($0, moment.end ?? $0) }
        }
        return all.isEmpty ? (row.momentSpan.map { [$0] } ?? []) : all
    }

    /// Worth looking for: the window shows every moment; the panel only marks a recording's timed ones on its bar,
    /// where the one the result points at is marked already.
    private var wantsMoments: Bool {
        exploresMoments ? showsMoments : row.momentCount > 1 && row.photos?.reading?.isStandIn != true
    }

    private func find() async {
        guard wantsMoments else { return }
        let key = foundKey
        let moments = row.momentCount > 0 ? await Previews.shared.moments(row.id, row.query, row.matchBy) : []
        let filmstrip = showsMoments && row.photos?.reading == .stills
            ? PhotosLibrary.filmstrip(startingAt: row.url.path) : []
        guard !Task.isCancelled else { return }
        found = Found(key: key, moments: moments, filmstrip: filmstrip)
    }
}

/// Open and Show in Finder (Show in Photos, for a Photos library's picture), and ♥ (DigUp's own favorites), under the
/// preview (the panel and the window). A Photos library's item whose original is in iCloud also gets Download Original
/// (`PhotosDownloads`).
struct PreviewActions: View {
    let row: ResultRow
    let open: () -> Void
    let reveal: () -> Void
    let favorites: Favorites
    /// The heart was pressed (the window's Favorites filter follows).
    var toggledFavorite: () -> Void = {}
    var controlSize: ControlSize = .regular

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button(row.openTitle, action: open)
                    .keyboardShortcut(.defaultAction)
                Button(row.revealTitle, action: reveal)
                let marked = favorites.contains(row)
                Button {
                    favorites.toggle(row)
                    toggledFavorite()
                } label: {
                    Image(systemName: marked ? "heart.fill" : "heart")
                        .foregroundStyle(marked ? AnyShapeStyle(Brand.ember) : AnyShapeStyle(.secondary))
                }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(favorites.unreadable)
                .help(favorites.unreadable ? "DigUp's favorites file can't be read, so nothing can be marked"
                      : marked ? "Remove from Favorites (⌘D)" : "Add to Favorites (⌘D): DigUp's own, not Photos'")
                .accessibilityLabel(marked ? "Remove from Favorites" : "Add to Favorites")
            }
            if let photos = row.photos, let reading = photos.reading, reading == .preview || reading.isStandIn {
                DownloadOriginal(uuid: photos.uuid, video: row.kind == .video)
            }
        }
        .controlSize(controlSize)
    }
}

/// Download Original, for a Photos item whose original is only in iCloud: Photos fetches it and keeps it in the library;
/// DigUp then reads the original under the same result (a video as a video, frames and sound).
private struct DownloadOriginal: View {
    let uuid: String
    let video: Bool
    private var downloads: PhotosDownloads { .shared }

    var body: some View {
        switch downloads.state(of: uuid) {
        case .downloading(let progress):
            HStack(spacing: 8) {
                ProgressView(value: progress).frame(width: 120)
                Text("Downloading from iCloud…").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        case .done:
            Label("Downloaded: DigUp reads it again shortly", systemImage: "checkmark.circle")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        case .failed(let why):
            VStack(alignment: .leading, spacing: 4) {
                button
                Text(why).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        case nil:
            button
        }
    }

    private var button: some View {
        Button {
            downloads.start(uuid)
        } label: {
            Label("Download Original", systemImage: "icloud.and.arrow.down")
        }
        .help(video ? "Photos downloads the video from iCloud and keeps it; DigUp then reads the video itself (its frames "
              + "and sound), not Photos' stills of it"
              : "Photos downloads the full picture from iCloud and keeps it; DigUp then reads it instead of the preview")
    }
}

/// The picture part of the preview. A video's moments sit on the frame as a scrub bar; audio has no picture, so it
/// gets them on a timeline instead.
struct PreviewPicture: View {
    let row: ResultRow
    let size: CGSize
    /// Double-click opens it, as in Finder's and Spotlight's previews (not on the player or its controls).
    var open: () -> Void = {}
    /// What a recording's bar marks, in seconds: its moments (none, and there's no bar).
    let stretches: [ClosedRange<Double>]
    /// Where the picture sits in its box when it's smaller.
    var alignment: Alignment = .center
    /// What you can say of its faces, when it's a picture outside Photos (the window's preview): they're all outlined,
    /// and each can be clicked.
    var telling: FaceTelling?
    @State private var image: NSImage?
    @State private var loaded = false
    /// The faces found in it, for `telling`.
    @State private var faces: [IndexStore.PictureFace] = []
    @Environment(\.displayScale) private var scale

    var body: some View {
        Group {
            if row.kind == .audio {
                AudioMoment(row: row, stretches: stretches)
                    .frame(height: min(size.height, 150))
            } else if row.kind == .code {
                CodeLines(row: row)
                    .frame(maxWidth: size.width, maxHeight: size.height)
                    .onTapGesture(count: 2, perform: open)
            } else if row.segment == .chunk {
                Passage(row: row)
                    .frame(maxWidth: size.width, maxHeight: size.height)
                    .onTapGesture(count: 2, perform: open)
            } else if row.moment != nil, let player = PreviewPlayback.shared.player,
                      PreviewPlayback.shared.isCurrent(row) {
                PlayerView(player: player)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .frame(maxWidth: size.width, maxHeight: size.height)
            } else if let image {
                let hidden = SensitiveBlur.shared.hides(row)
                Image(nsImage: image.veiled(hidden))
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .overlay(alignment: .bottomLeading) { marks }
                    // The faces found in it, to say who they are; else the ones the People filter took it for. Not
                    // on a GIF's later frame: they're on its first.
                    .overlay {
                        if row.segment != .frame {
                            if let telling, !faces.isEmpty {
                                TellableFaces(faces: faces, row: row, telling: telling)
                            } else if !row.faces.isEmpty {
                                FaceOutlines(faces: row.faces)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2, perform: open)
                    .overlay { if row.moment != nil { PlayButton(row: row) } }
                    // Over the play button too: playing it would show it. A click shows it.
                    .sensitiveCover(hidden, iconSize: 26, show: { SensitiveBlur.shared.show(row) })
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                    .frame(maxWidth: size.width, maxHeight: size.height, alignment: alignment)
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
                    .overlay {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: row.url.path))
                            .resizable()
                            .frame(width: 64, height: 64)
                            .opacity(loaded ? 1 : 0.4)
                    }
                    .overlay(alignment: .bottomLeading) { marks }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2, perform: open)
                    .frame(maxWidth: size.width, maxHeight: size.height)
            }
        }
        .frame(height: row.kind == .audio ? min(size.height, 150) : size.height)
        // The selection moved on (not to another moment of the recording playing, picked under the preview).
        .onChange(of: row.previewKey) {
            if !PreviewPlayback.shared.isCurrent(row) { PreviewPlayback.shared.stop() }
        }
        // The pane went away (the weaker-matches row selected, no results, the window's preview hidden): no sound
        // without its controls.
        .onDisappear { if PreviewPlayback.shared.isCurrent(row) { PreviewPlayback.shared.stop() } }
        .task(id: Previews.shared.key(row, max(size.width, size.height))) {
            guard row.segment != .chunk, row.kind != .code else { return }
            let side = max(size.width, size.height)
            image = Previews.shared.cached(row, side: side)
            loaded = image != nil
            if image == nil {
                image = await Previews.shared.load(row, side: side, scale: scale)
                loaded = true
            }
        }
        .task(id: "\(row.id)|\(telling?.said ?? -1)") {
            faces = []
            guard let telling, row.photos == nil, row.kind == .image || row.kind == .screenshot else { return }
            faces = await telling.faces(row)
        }
    }

    /// The page or moment that matched, on the picture; for a video, where in it.
    @ViewBuilder private var marks: some View {
        if let place = row.place {
            VStack(alignment: .leading, spacing: 7) {
                PlaceBadge(text: place, onImage: true)
                if row.kind == .video, !stretches.isEmpty, let duration = row.duration, duration > 0 {
                    MomentBar(stretches: stretches, duration: duration, onImage: true)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .bottom) {
                if row.kind == .video {
                    LinearGradient(colors: [.clear, .black.opacity(0.35)], startPoint: .top, endPoint: .bottom)
                }
            }
        }
    }
}

/// The faces the People filter took a picture outside Photos for (`ResultRow.faces`), outlined where they are, each with
/// the person's name.
struct FaceOutlines: View {
    let faces: [FaceMatch]

    var body: some View {
        GeometryReader { geometry in
            ForEach(Array(faces.enumerated()), id: \.offset) { _, face in
                FaceOutline(name: face.name, box: face.box, in: geometry.size)
                    .offset(x: face.box.x * geometry.size.width, y: face.box.y * geometry.size.height)
                    .accessibilityLabel("\(face.name), by their face")
            }
        }
        .allowsHitTesting(false)
    }
}

/// One face's outline on a picture: solid, with the name of who it's taken for under it, or dashed for no one.
private struct FaceOutline: View {
    let name: String?
    let box: Faces.Box
    let size: CGSize

    init(name: String?, box: Faces.Box, in size: CGSize) {
        (self.name, self.box, self.size) = (name, box, size)
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .strokeBorder(Color.white.opacity(name == nil ? 0.75 : 1),
                          style: StrokeStyle(lineWidth: name == nil ? 1.5 : 2, dash: name == nil ? [4, 3] : []))
            .shadow(color: .black.opacity(0.6), radius: 2)
            .frame(width: box.width * size.width, height: box.height * size.height)
            .contentShape(Rectangle())
            .overlay(alignment: .bottomLeading) {
                if let name {
                    Text(name)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(.black.opacity(0.55)))
                        .offset(y: 18)
                }
            }
    }
}

/// What the search window's preview lets you say of the faces in a picture outside Photos (`FaceCorrections`): who
/// one is, among the people named in Photos, or that it isn't who DigUp took it for. The panel's preview has none.
struct FaceTelling {
    /// The people named in Photos, by name (`PhotosChoices.people`).
    let people: [PhotosChoices.Person]
    /// Changes each time something is said, so the picture's faces are read again.
    let said: Int
    let faces: @MainActor (ResultRow) async -> [IndexStore.PictureFace]
    let say: @MainActor (FaceCorrections.Says, PhotosChoices.Person, Faces.Box, ResultRow) -> Void

    /// Everyone of the name of the person a face was taken for.
    func person(of match: FaceMatch) -> PhotosChoices.Person? {
        people.first { $0.photos[match.person] != nil }
    }
}

/// Every face found in a picture outside Photos, outlined where it is, with the name of who it's taken for under it.
/// Clicking one asks who it is ("This is…", among the people named in Photos), or offers "Not Tati" for one taken for
/// Tati.
struct TellableFaces: View {
    let faces: [IndexStore.PictureFace]
    let row: ResultRow
    let telling: FaceTelling
    @State private var asking: Int?

    var body: some View {
        GeometryReader { geometry in
            ForEach(Array(faces.enumerated()), id: \.offset) { index, face in
                Button {
                    asking = index
                } label: {
                    FaceOutline(name: face.match?.name, box: face.box, in: geometry.size)
                }
                .buttonStyle(.plain)
                .help(face.match.map { "DigUp took this face for \($0.name): click to say it isn't them, or who it is" }
                      ?? "Click to say who this is: DigUp then finds them by this face too")
                .accessibilityLabel(face.match.map { "\($0.name), by their face" } ?? "A face")
                .popover(isPresented: Binding(get: { asking == index }, set: { if !$0 { asking = nil } }),
                         arrowEdge: .trailing) {
                    WhoIsThis(face: face, telling: telling) { says, person in
                        asking = nil
                        telling.say(says, person, face.box, row)
                    }
                }
                .offset(x: face.box.x * geometry.size.width, y: face.box.y * geometry.size.height)
            }
        }
    }
}

/// A face clicked: "Not Tati" when it was taken for Tati, and "This is…" with the people named in Photos (typing
/// narrows them, as the filter suggestions do).
private struct WhoIsThis: View {
    let face: IndexStore.PictureFace
    let telling: FaceTelling
    let say: (FaceCorrections.Says, PhotosChoices.Person) -> Void
    @State private var typed = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let match = face.match, let person = telling.person(of: match) {
                Button("Not \(match.name)") { say(.isNot, person) }
                Divider()
            }
            Text("This is…")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("Name", text: $typed)
                .textFieldStyle(.roundedBorder)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(shown) { person in
                        Button {
                            say(.is, person)
                        } label: {
                            Text(person.name)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 3)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 220)
        }
        .padding(12)
        .frame(width: 220)
    }

    private var shown: [PhotosChoices.Person] {
        typed.isEmpty ? telling.people : telling.people.filter { PhotosChoices.wordStarts($0.name, with: typed) }
    }
}

/// "Not Tati", for each person a picture outside Photos was kept for by a face (`ResultRow.faces`): it isn't them, so
/// it's no longer kept for them (`FaceTelling`).
private struct NotThem: View {
    let row: ResultRow
    let telling: FaceTelling

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(row.faces.enumerated()), id: \.offset) { _, face in
                if let person = telling.person(of: face) {
                    Button("Not \(face.name)") { telling.say(.isNot, person, face.box, row) }
                        .help("This face isn't \(face.name)'s: DigUp stops taking it for them")
                }
            }
        }
        .controlSize(.small)
    }
}

/// An audio hit: where it matched, on the file's timeline.
struct AudioMoment: View {
    let row: ResultRow
    /// What its timeline marks, in seconds: its moments (none, and the window's strip under it shows them).
    let stretches: [ClosedRange<Double>]
    private var playback: PreviewPlayback { .shared }

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 16) {
                Image(systemName: "waveform")
                    .font(.system(size: 54, weight: .light))
                    .foregroundStyle(Brand.gradient)
                Button { playback.toggle(row) } label: {
                    Image(systemName: playback.isCurrent(row) && playback.isPlaying ? "pause.circle.fill"
                                                                                     : "play.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .help(row.loc.map { "Play from \(ResultRow.clock($0))" } ?? "Play")
            }
            if let loc = row.loc {
                VStack(spacing: 5) {
                    if !stretches.isEmpty, let duration = row.duration, duration > 0 {
                        MomentBar(stretches: stretches, duration: duration,
                                  playhead: playback.isCurrent(row) ? playback.time : nil)
                            .frame(maxWidth: 260)
                    }
                    Text(playback.isCurrent(row) ? "\(ResultRow.clock(playback.time)) – playing from "
                         + ResultRow.clock(loc) : span(from: loc))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.04)))
    }

    /// "0:25 – 0:55 of 3:12"
    private func span(from start: Double) -> String {
        let end = row.momentSpan?.upperBound ?? start
        let total = row.duration.map { " of " + ResultRow.clock($0) } ?? ""
        return ResultRow.clock(start) + " – " + ResultRow.clock(end) + total
    }
}

/// "Matches the frame at 0:06" and the words it has, if any: what's said, for a stretch of speech.
struct WhyItMatched: View {
    let row: ResultRow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(row.reason)
            } icon: {
                Image(systemName: row.matchedMeaning ? "sparkle.magnifyingglass"
                      : row.faces.isEmpty ? "textformat" : "person.crop.rectangle")
                    .foregroundStyle(row.matchedMeaning ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(.secondary))
            }
            .font(.system(size: 12, weight: .medium))
            // What's said shows whole, its words marked; code shows its lines above, the words marked there.
            if row.segment == .speech {
                SpokenWords(row: row)
                    .padding(.leading, 22)
            } else if let excerpt = row.excerpt, row.kind != .code {
                Text(highlighted(excerpt, size: 12))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .padding(.leading, 22)
                    .textSelection(.enabled)
            }
        }
    }
}

/// What's said in the stretch of speech a result is at, all of it as the index keeps it, with the query's words marked
/// as a PDF page's are (`ResultRow.markedWords`).
struct SpokenWords: View {
    let row: ResultRow
    @State private var text: String?

    var body: some View {
        Text(marking(row.markedWords, in: text ?? row.excerpt.map(Self.unmarked) ?? ""))
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .lineLimit(6)
            .textSelection(.enabled)
            .task(id: row.previewKey) { text = await Previews.shared.passage(row.segmentID, false) }
    }

    /// An excerpt without keyword search's « » marks.
    private static func unmarked(_ excerpt: String) -> String {
        excerpt.replacingOccurrences(of: "«", with: "").replacingOccurrences(of: "»", with: "")
    }
}

/// ▶ on a video's frame: plays it in the pane from the moment that matched.
struct PlayButton: View {
    let row: ResultRow

    var body: some View {
        Button { PreviewPlayback.shared.play(row) } label: {
            Image(systemName: "play.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(Circle().fill(.black.opacity(0.45)))
                .overlay(Circle().strokeBorder(.white.opacity(0.7), lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .help(row.moment.map { "Play from \(ResultRow.clock($0))" } ?? "Play")
        .accessibilityLabel(row.moment.map { "Play from \(ResultRow.clock($0))" } ?? "Play")
    }
}

/// The part of a document that matched, on a page-like card, with the query's words marked.
struct Passage: View {
    let row: ResultRow
    @State private var text: String?

    var body: some View {
        ScrollView {
            Text(marked)
                .font(.system(size: 12))
                .lineSpacing(3)
                .foregroundStyle(Color.black.opacity(0.85))
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
        }
        .scrollIndicators(.never)
        .environment(\.layoutDirection, Self.isRightToLeft(text ?? row.excerpt ?? "") ? .rightToLeft : .leftToRight)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white))
        .overlay(alignment: .bottomTrailing) {
            if let part = partLabel { PlaceBadge(text: part, onImage: true).padding(8) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.12),
                                                                                    lineWidth: 0.5))
        .shadow(color: .black.opacity(0.15), radius: 5, y: 2)
        .task(id: row.previewKey) { text = await Previews.shared.passage(row.segmentID, false) }
    }

    /// "Part 2 of 5", when the document has more than one.
    private var partLabel: String? {
        guard let part = row.loc.map(Int.init), let parts = row.info["chunks"].flatMap(Int.init), parts > 1 else {
            return nil
        }
        return "Part \(part) of \(parts)"
    }

    /// Up to ~900 characters from just before the first marked word, the words marked like a search in Preview.
    private var marked: AttributedString {
        let source = text ?? row.excerpt?.replacingOccurrences(of: "«", with: "").replacingOccurrences(of: "»", with: "") ?? ""
        let words = row.markedWords
        let first = words.compactMap { SearchText.matches(of: $0, in: source).first?.lowerBound }.min()
        var start = source.startIndex
        if let first, source.distance(from: source.startIndex, to: first) > 200 {
            start = source.index(first, offsetBy: -160)
            while start < first, !source[start].isWhitespace { start = source.index(after: start) }
        }
        let window = String(source[start...].prefix(900))
        let lead = start > source.startIndex ? "…" : ""
        return marking(words, in: lead + window + (source.distance(from: start, to: source.endIndex) > 900 ? "…" : ""))
    }

    /// Arabic or Hebrew text reads from the right.
    static func isRightToLeft(_ text: String) -> Bool {
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            return (0x0590...0x08FF).contains(scalar.value) || (0xFB1D...0xFEFC).contains(scalar.value)
        }
        return false
    }
}

/// `text` with `words` marked where keyword search would find them (`SearchText.matches`), as Preview marks what you
/// searched for: a document's passage, what's said in a recording.
func marking(_ words: Set<String>, in text: String) -> AttributedString {
    var result = AttributedString(text)
    for word in words {
        for found in SearchText.matches(of: word, in: text) {
            guard let range = Range(found, in: result) else { continue }
            result[range].backgroundColor = Color(red: 1, green: 0.86, blue: 0.2)
            result[range].foregroundColor = .black
        }
    }
    return result
}

/// The lines of code that matched, numbered as in the file, in a monospaced card like an editor's: the query's words
/// are marked, the line it opens at is lit, and the card opens scrolled to it. Long lines run past the edge.
struct CodeLines: View {
    let row: ResultRow
    @State private var text: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { offset, line in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(number(offset))
                                .foregroundStyle(.tertiary)
                                .frame(width: gutter, alignment: .trailing)
                            Text(marked(line))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .padding(.vertical, 0.5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(isFocus(offset) ? Brand.amber.opacity(0.16) : Color.clear)
                        .id(offset)
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .padding(.vertical, 10)
                .padding(.horizontal, 8)
            }
            .scrollIndicators(.never)
            .onChange(of: text) {
                if let target = focusOffset ?? firstMarked, target > 3 { proxy.scrollTo(target - 2, anchor: .top) }
            }
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.045)))
        .overlay(alignment: .bottomTrailing) {
            if let span = row.span { PlaceBadge(text: span, onImage: true).padding(8) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.1),
                                                                                    lineWidth: 0.5))
        .task(id: row.previewKey) { text = await Previews.shared.passage(row.segmentID, true) }
    }

    private var lines: [String] {
        (text ?? "").split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" })
            .map { $0.replacingOccurrences(of: "\t", with: "    ") }
    }

    /// A stretch's lines are the file's; a notebook's stretch has no numbers of its own, so its lines count from 1.
    private var firstNumber: Int { row.segment == .lines ? Int(row.loc ?? 1) : 1 }

    private func number(_ offset: Int) -> String { "\(firstNumber + offset)" }

    private var gutter: CGFloat { CGFloat(String(firstNumber + max(lines.count, 1)).count) * 7 + 2 }

    /// The line it opens at, in the stretch.
    private var focusOffset: Int? {
        guard row.segment == .lines, let focus = row.focus else { return nil }
        return Int(focus) - firstNumber
    }

    private func isFocus(_ offset: Int) -> Bool { offset == focusOffset }

    private var words: [String] {
        Array(Set((row.foundWords + row.terms).filter { $0.count >= 2 }))
    }

    private var firstMarked: Int? {
        lines.firstIndex { line in words.contains { !SearchText.matches(of: $0, in: line).isEmpty } }
    }

    private func marked(_ line: String) -> AttributedString {
        var result = AttributedString(line.isEmpty ? " " : line)
        for word in words {
            for found in SearchText.matches(of: word, in: line) {
                guard let range = Range(found, in: result) else { continue }
                result[range].backgroundColor = Color(red: 1, green: 0.86, blue: 0.2)
                result[range].foregroundColor = .black
            }
        }
        return result
    }
}
