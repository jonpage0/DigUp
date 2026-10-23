import Foundation
import Testing
@testable import DigUpKit
#if canImport(ImageIO)
import CoreGraphics
import ImageIO
#endif

/// Pictures in the formats stb doesn't read, and a JPEG (Pictures/, from scripts/testbed/make_test_pictures.swift): a
/// 400×240 pattern of four colored quadrants (red, green above blue, yellow) with a DateTimeOriginal, stored turned
/// (orientation 6) except the AVIF. ImageIO reads them on macOS, stb or ffmpeg elsewhere: each must hand the model the
/// picture as it's shown, and the date.
@Suite struct ImageTests {
    static let pictures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Pictures")
    let folder: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DigUpTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    @Test(arguments: ["pattern-o6.jpg", "pattern-o6.heic", "pattern-o6.webp", "pattern-o6.tiff", "pattern.avif"])
    func preparedAsShown(_ name: String) throws {
        let prepared = try ImageExtractor.prepare(Self.pictures.appendingPathComponent(name), maxPixel: 1024,
                                                  minSide: 256, to: folder, png: true)
        #expect(Set([prepared.width, prepared.height]) == [400, 240])
        #expect(prepared.taken == "2024:05:17 10:30:00")
        let shown = try Self.decode(prepared.path)
        if name.contains("-o6") {   // turned 90° clockwise: blue and red on top, yellow and green below
            #expect(shown.width == 240 && shown.height == 400)
            #expect(shown.quadrants == ["B", "R", "Y", "G"])
        } else {
            #expect(shown.width == 400 && shown.height == 240)
            #expect(shown.quadrants == ["R", "G", "B", "Y"])
        }
    }

    @Test(arguments: ["pattern-o6.jpg", "pattern-o6.heic", "pattern-o6.webp"])
    func smallPicturesAreSkipped(_ name: String) {
        #expect(throws: ExtractError.self) {
            try ImageExtractor.prepare(Self.pictures.appendingPathComponent(name), maxPixel: 1024, minSide: 401,
                                       to: folder, png: true)
        }
    }

    /// The size `media_dimensions` keeps: the picture as it's shown, turned by its orientation, from its properties
    /// alone (`dimensions(of:)`, where they're read without decoding it: off the Mac, only what stb reads), and as
    /// indexing reads it for the model.
    @Test(arguments: ["pattern-o6.jpg", "pattern-o6.heic", "pattern-o6.webp", "pattern-o6.tiff", "pattern.avif"])
    func sizeAsShown(_ name: String) throws {
        let url = Self.pictures.appendingPathComponent(name)
        let shown = name.contains("-o6") ? MediaDimensions(width: 240, height: 400, duration: nil, source: .file)
            : MediaDimensions(width: 400, height: 240, duration: nil, source: .file)
        #expect(try ImageExtractor.prepare(url, maxPixel: 1024, minSide: 256, to: folder, png: true).dimensions == shown)
        #if canImport(ImageIO)
        #expect(ImageExtractor.dimensions(of: url) == shown)
        #else
        #expect(ImageExtractor.dimensions(of: url) == (name.hasSuffix(".jpg") ? shown : nil))
        #endif
    }

    #if !canImport(ImageIO)
    @Test func malformedHeifExtentsAreIgnored() throws {
        func bigEndian(_ value: UInt64, width: Int) -> [UInt8] {
            (0..<width).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
        }
        func box(_ type: String, _ body: [UInt8]) -> [UInt8] {
            bigEndian(UInt64(body.count + 8), width: 4) + Array(type.utf8) + body
        }
        let infe = box("infe", [2, 0, 0, 0] + bigEndian(1, width: 2) + [0, 0] + Array("Exif".utf8) + [0])
        let iinf = box("iinf", [0, 0, 0, 0] + bigEndian(1, width: 2) + infe)
        let ftyp = box("ftyp", Array("heic".utf8) + [0, 0, 0, 0])

        let extents: [(UInt64, UInt64, UInt64)] = [(UInt64(Int.max), 1, 4), (12, 0, UInt64(Int.max))]
        for (base, offset, length) in extents {
            let iloc = box("iloc", [0, 0, 0, 0, 0x88, 0x80] + bigEndian(1, width: 2)
                + bigEndian(1, width: 2) + [0, 0] + bigEndian(base, width: 8)
                + bigEndian(1, width: 2) + bigEndian(offset, width: 8) + bigEndian(length, width: 8))
            let file = folder.appendingPathComponent("bad-extent-\(base).heic")
            try Data(ftyp + box("meta", [0, 0, 0, 0] + iinf + iloc)).write(to: file)
            #expect(EXIF.read(file)?.orientation == nil)
        }
    }
    #endif

    #if canImport(AppKit)
    @Test func vectorPicturesAreDrawn() throws {
        // An SVG, which ImageIO doesn't open: red on the left, blue on the right, 800×400 points.
        let chart = folder.appendingPathComponent("chart.svg")
        try ##"<svg xmlns="http://www.w3.org/2000/svg" width="800" height="400"><rect width="400" height="400" fill="#f00"/><rect x="400" width="400" height="400" fill="#00f"/></svg>"##
            .write(to: chart, atomically: true, encoding: .utf8)
        let prepared = try ImageExtractor.prepare(chart, maxPixel: 1024, minSide: 256, to: folder, png: true)
        #expect(prepared.width == 800 && prepared.height == 400)
        let shown = try Self.decode(prepared.path)
        #expect(shown.width == 1024 && shown.height == 512)
        #expect(shown.quadrants == ["R", "B", "R", "B"])
        // An icon is still too small to say much.
        let icon = folder.appendingPathComponent("icon.svg")
        try ##"<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24"><rect width="24" height="24" fill="#0f0"/></svg>"##
            .write(to: icon, atomically: true, encoding: .utf8)
        do {
            _ = try ImageExtractor.prepare(icon, maxPixel: 1024, minSide: 256, to: folder, png: true)
            Issue.record("a 24-point icon was read")
        } catch {
            #expect("\(error)" == "small image 24×24")
        }
    }
    #endif

    /// A picture's size and the color in the middle of each quadrant (top left, top right, bottom left, bottom right),
    /// as R, G, B or Y.
    static func decode(_ path: String) throws -> (width: Int, height: Int, quadrants: [String]) {
        let (width, height, rgb) = try pixels(path)
        let quadrants = [(1, 1), (3, 1), (1, 3), (3, 3)].map { (qx, qy) -> String in
            let i = ((qy * height / 4) * width + qx * width / 4) * 3
            let high = (rgb[i] > 128, rgb[i + 1] > 128, rgb[i + 2] > 128)
            switch high {
            case (true, false, false): return "R"
            case (false, true, false): return "G"
            case (false, false, true): return "B"
            case (true, true, false): return "Y"
            default: return "(\(rgb[i]),\(rgb[i + 1]),\(rgb[i + 2]))"
            }
        }
        return (width, height, quadrants)
    }

    /// Packed 8-bit RGB, decoded by the system's own reader.
    static func pixels(_ path: String) throws -> (Int, Int, [UInt8]) {
        #if canImport(ImageIO)
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ExtractError.unreadable(path) }
        let (width, height) = (image.width, image.height)
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &rgba, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw ExtractError.unreadable(path) }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var rgb = [UInt8]()
        rgb.reserveCapacity(width * height * 3)
        for i in stride(from: 0, to: rgba.count, by: 4) { rgb += rgba[i..<(i + 3)] }
        return (width, height, rgb)
        #else
        guard let image = RGBImage.load(path) else { throw ExtractError.unreadable(path) }
        return (image.width, image.height, image.pixels)
        #endif
    }

    #if canImport(ImageIO)
    /// Writes a JPEG of `size` (400×300 unless said), with GPS tags when `point` is given (degrees, south and west
    /// below zero), written as a camera writes them: unsigned degrees, and the hemisphere apart; and an EXIF
    /// `orientation` when given (6: stored turned, shown a quarter turn clockwise).
    static func writeJPEG(_ url: URL, at point: (latitude: Double, longitude: Double)? = nil,
                          size: (width: Int, height: Int) = (400, 300), orientation: Int? = nil) throws {
        guard let context = CGContext(data: nil, width: size.width, height: size.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw ExtractError.unreadable("no context") }
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)
        else { throw ExtractError.unreadable(url.path) }
        var properties: [CFString: Any] = [:]
        if let point {
            properties[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: abs(point.latitude),
                kCGImagePropertyGPSLatitudeRef: point.latitude < 0 ? "S" : "N",
                kCGImagePropertyGPSLongitude: abs(point.longitude),
                kCGImagePropertyGPSLongitudeRef: point.longitude < 0 ? "W" : "E",
            ] as [CFString: Any]
        }
        if let orientation { properties[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ExtractError.unreadable(url.path) }
    }

    /// Writes a GIF of `side` × `side`, a frame of another color for each of `delays` (seconds each is shown).
    static func writeGIF(_ url: URL, side: Int, delays: [Double]) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "com.compuserve.gif" as CFString,
                                                                delays.count, nil)
        else { throw ExtractError.unreadable(url.path) }
        for (number, delay) in delays.enumerated() {
            guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { throw ExtractError.unreadable("no context") }
            context.setFillColor(CGColor(red: CGFloat(number) / CGFloat(delays.count), green: 0.5, blue: 0.2, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            guard let frame = context.makeImage() else { throw ExtractError.unreadable(url.path) }
            CGImageDestinationAddImage(destination, frame, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay],
            ] as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw ExtractError.unreadable(url.path) }
    }

    @Test func anAnimatedGIFIsReadByAFewOfItsFramesToo() throws {
        #expect(ImageExtractor.framesRead(ofAnimation: 1).isEmpty)
        #expect(ImageExtractor.framesRead(ofAnimation: 2) == [1])
        #expect(ImageExtractor.framesRead(ofAnimation: 100) == [16, 33, 50, 66, 83])
        let base = URL(fileURLWithPath: FolderSelection.realPath(folder.path))
        let pictures = base.appendingPathComponent("pictures")
        try FileManager.default.createDirectory(at: pictures, withIntermediateDirectories: true)
        // Eight frames shown 0.1, 0.2… 0.8 s: the ones read besides the first are 1, 2, 4, 5 and 6, and each starts
        // when the ones before it are done.
        let dance = pictures.appendingPathComponent("dance.gif")
        try Self.writeGIF(dance, side: 300, delays: [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8])
        try Self.writeGIF(pictures.appendingPathComponent("still.gif"), side: 300, delays: [0.5])   // not animated
        try Self.writeGIF(pictures.appendingPathComponent("icon.gif"), side: 100, delays: [0.1, 0.1])   // too small
        let store = try IndexStore(directory: base.appendingPathComponent("index"))
        let indexer = try Indexer(store: store, options: IndexOptions(), makeEmbedder: { FakeEmbedder() })
        _ = try indexer.sync([pictures])
        #expect(try indexer.run() == ["done": 2, "skipped": 1])
        var segments: [String: [(kind: String, loc: Double?, end: Double?)]] = [:]
        try store.db.query("""
            SELECT f.path, s.kind, s.loc, s.loc_end FROM segments s JOIN files f ON f.id = s.file
            WHERE s.kind NOT IN \(IndexStore.crawlKinds) AND s.vec IS NOT NULL ORDER BY s.id
            """) { row in
            segments[(row.text(0)! as NSString).lastPathComponent, default: []]
                .append((row.text(1)!, row.isNull(2) ? nil : row.double(2), row.isNull(3) ? nil : row.double(3)))
        }
        #expect(segments["still.gif"]?.map(\.kind) == ["image"])
        let read = try #require(segments["dance.gif"])
        #expect(read.map(\.kind) == ["image"] + Array(repeating: "frame", count: 5))
        let moments: [(Double, Double)] = [(0.1, 0.3), (0.3, 0.6), (1.0, 1.5), (1.5, 2.1), (2.1, 2.8)]
        for (frame, moment) in zip(read.dropFirst(), moments) {
            #expect(abs((frame.loc ?? -1) - moment.0) < 1e-6 && abs((frame.end ?? -1) - moment.1) < 1e-6,
                    "\(frame) at \(moment)")
        }
        #expect(try store.files(under: [pictures.path]).map(\.kind) == [.image, .image, .image])
    }
    #endif
}
