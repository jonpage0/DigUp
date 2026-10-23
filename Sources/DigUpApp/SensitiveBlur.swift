import AppKit
import DigUpKit
import SwiftUI

/// "Blur sensitive pictures" (Settings → General) as the results show it ("Keep it discreet", Jon, 2026-10-21): a
/// picture rated sensitive at the setting's position (`SensitivePosition.flags`) is blurred in the window's grid, the
/// panel's rows, the preview and the moments' strips until it's clicked, and then that picture shows, for as long as the
/// app runs; another of its file's (a video's other stills) stays blurred until it's clicked too (`SensitiveReveal`).
/// Quick Look shows the file as it is: opening it is the click. A picture not rated yet isn't blurred (Settings says how
/// many wait for the rating pass).
@Observable
final class SensitiveBlur {
    static let shared = SensitiveBlur()

    var position = SensitivePosition.off
    /// The pictures clicked to show, this run of the app.
    private(set) var reveal = SensitiveReveal()

    /// Whether `picture` is blurred now (nil: there's no picture to blur).
    func hides(_ picture: SensitiveReveal.Shown?) -> Bool {
        picture.map { reveal.hides($0, at: position) } ?? false
    }

    /// Whether the picture `row` shows is blurred now (`ResultRow.shownPicture`).
    func hides(_ row: ResultRow) -> Bool { hides(row.shownPicture) }

    /// A click on `picture`: it shows from now on (when it's blurred).
    func show(_ picture: SensitiveReveal.Shown?) {
        guard let picture, reveal.reveal(picture, at: position) else { return }
        log("blur: a sensitive picture shown on a click")
    }

    /// A click on the picture `row` shows.
    func show(_ row: ResultRow) { show(row.shownPicture) }

    /// Pictures as `veil` made them, by the picture: a grid redrawn doesn't make them again.
    @ObservationIgnored private let veils = NSCache<NSImage, NSImage>()
    /// How many pixels a veiled picture keeps on its long side, and how many it's drawn back up to (smooth there, so
    /// it shows as a blur rather than as squares).
    private static let veilPixels = 8
    private static let veilDrawn = 64

    /// `image` past recognizing: shrunk to a few pixels and drawn back up, a blur. The blur is in the pixels, so it's
    /// the same on screen, in a screenshot and in a recording (a blur effect the window server draws isn't in every one
    /// of those).
    func veil(_ image: NSImage) -> NSImage {
        if let veiled = veils.object(forKey: image) { return veiled }
        let veiled = NSImage(size: image.size)
        if let few = Self.redrawn(image, longSide: Self.veilPixels) {
            let small = NSImage(size: NSSize(width: few.pixelsWide, height: few.pixelsHigh))
            small.addRepresentation(few)
            if let smooth = Self.redrawn(small, longSide: Self.veilDrawn) { veiled.addRepresentation(smooth) }
        }
        veils.setObject(veiled, forKey: image)
        return veiled
    }

    /// `image` drawn into a bitmap `longSide` pixels on its long side, smoothly.
    private static func redrawn(_ image: NSImage, longSide: Int) -> NSBitmapImageRep? {
        let scale = Double(longSide) / max(image.size.width, image.size.height, 1)
        let (width, height) = (max(1, Int((image.size.width * scale).rounded())),
                               max(1, Int((image.size.height * scale).rounded())))
        guard let pixels = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: pixels) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        return pixels
    }
}

extension NSImage {
    /// This picture, or while `hidden` its veil (`SensitiveBlur.veil`).
    func veiled(_ hidden: Bool) -> NSImage { hidden ? SensitiveBlur.shared.veil(self) : self }
}

extension ResultRow {
    /// The picture this result shows (as `Previews.load` draws it), as blurring goes by it: the frame or the still it's
    /// at, else the picture itself; a video shown by Quick Look's picture of it, which could be any of its frames, by its
    /// most revealing one. Nil when there's none.
    var shownPicture: SensitiveReveal.Shown? {
        guard let pictures else { return nil }
        if let stillIndex { return pictures.shown(pictures.frame(atPlace: stillIndex)) }
        switch kind {
        case .video where photos?.still != nil:
            // Photos' stills or poster of a video in iCloud: the one that matched, else the first.
            return pictures.shown(segment == .frame ? pictures.picture(ofSegment: segmentID) : pictures.frames.first)
        case .video:
            guard let loc else { return pictures.anyFrame }
            return pictures.shown(segment == .frame ? pictures.picture(ofSegment: segmentID) : pictures.frame(at: loc))
        default:
            // A GIF's later frame that matched, else the picture.
            return pictures.shown(segment == .frame && loc != nil ? pictures.picture(ofSegment: segmentID)
                                                                  : pictures.image)
        }
    }

    /// Quick Look's own picture of the file, which the panel's rows show: the picture itself; of a video read from
    /// Photos' stills or poster, the first of them (its file); of any other video, which frame it is isn't known, so it
    /// goes by its most revealing one.
    var filePicture: SensitiveReveal.Shown? {
        guard let pictures else { return nil }
        guard kind == .video else { return pictures.shown(pictures.image) }
        return photos?.reading?.isStandIn == true ? pictures.shown(pictures.frame(atPlace: 0)) : pictures.anyFrame
    }
}

extension View {
    /// Over a picture drawn veiled while `hidden` (`NSImage.veiled`): a shade and a closed eye, which say why.
    /// `iconSize`: the eye's. `show`: what a click on it does, where nothing else takes the click (the preview); a grid
    /// cell's or a row's click shows it through their own.
    func sensitiveCover(_ hidden: Bool, iconSize: CGFloat, show: (() -> Void)? = nil) -> some View {
        overlay {
            if hidden {
                ZStack {
                    Color.black.opacity(0.2)
                    Image(systemName: "eye.slash.fill")
                        .font(.system(size: iconSize, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .shadow(color: .black.opacity(0.4), radius: 2)
                }
                .contentShape(Rectangle())
                .onTapGesture { show?() }
                .allowsHitTesting(show != nil)
                .accessibilityElement()
                .accessibilityLabel("Sensitive picture, blurred: click to show it")
                .help("Rated sensitive: click to show it")
            }
        }
    }
}
