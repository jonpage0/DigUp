// Face recognition on macOS: Vision finds faces, their landmarks and its own faceprints; Core ML runs a face model.
// There's none off the Mac: Faces.swift has the part that needs neither.
#if canImport(Vision) && canImport(CoreML)
import CoreGraphics
import CoreML
import CoreVideo
import Foundation
import ImageIO
import Vision

/// Turns the faces of a picture into embeddings, their prints (`Faces`): Vision's own faceprints (`VisionFaceprints`),
/// or a Core ML model's (`CoreMLFaceEmbedder`).
public protocol FaceRecognizer {
    /// What a report calls it.
    var name: String { get }
    /// Which recognizer it is, and its version, as the index records it (`FaceReader.identity`).
    var identity: String { get }
    /// An embedding for each of the picture's faces (`FacePicture.faces`, in order); nil for one it couldn't read.
    func embeddings(of picture: FacePicture) -> [[Float]?]
    /// How alike two of its embeddings are: higher is more alike, 1 the most.
    func similarity(_ a: [Float], _ b: [Float]) -> Float
}

extension FaceRecognizer {
    /// The cosine of the angle between them (`Faces.cosine`).
    public func similarity(_ a: [Float], _ b: [Float]) -> Float { Faces.cosine(a, b) }
}

extension Faces {
    /// Where SFace is kept in DigUp's models folder (scripts/face-model.py convert sface puts it there).
    public static let sfaceModel = "faces/face_recognition_sface_2021dec.mlpackage"

    /// The faces indexing reads (`FaceReader`): Vision's faceprints where this macOS has them, else SFace when it's in
    /// `models` (`sfaceModel`), else none, and then no faces are read and the index's stay as they are.
    public static func reader(models: URL) -> (any FaceReader)? {
        if let vision = try? VisionFaceprints() { return RecognizedFaces(vision) }
        let sface = models.appendingPathComponent(sfaceModel)
        guard FileManager.default.fileExists(atPath: sface.path), let model = try? CoreMLFaceEmbedder(model: sface)
        else { return nil }
        return RecognizedFaces(model)
    }
}

extension Faces.Box {
    /// Vision's box of a face (from the picture's bottom-left corner, as fractions of its width and height).
    init?(vision box: CGRect) {
        self.init(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
    }
}

/// The faces of pictures as the index keeps them (`FaceReader`), printed by one recognizer.
///
/// Unchecked Sendable: a recognizer (Vision's request, a Core ML model) isn't made to be shared between threads, and it
/// isn't: the indexer reads one picture at a time, on its preparing queue while it runs, or in its faces pass, which
/// runs only between runs.
public final class RecognizedFaces: FaceReader, @unchecked Sendable {
    private let recognizer: any FaceRecognizer

    public init(_ recognizer: any FaceRecognizer) {
        self.recognizer = recognizer
    }

    public var identity: String { recognizer.identity }

    /// A named face's box is Photos' (`FacePicture.box(of:)`), whatever Vision makes of it; a face found here has
    /// Vision's.
    public func faces(inPictureAt url: URL, named: [PhotosLibrary.FaceBox]?) throws -> [Faces.Found] {
        let picture = try FacePicture(contentsOf: url, photosFaces: named)
        return zip(picture.faces.indices, recognizer.embeddings(of: picture)).compactMap { index, print in
            guard let print else { return nil }
            let box = if let named { picture.box(of: named[index]) }
                else { Faces.Box(vision: picture.faces[index].box) }
            return box.map { Faces.Found(box: $0, print: print, named: named == nil ? nil : index) }
        }
    }
}

extension Faces {
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    /// The face of `image` whose five points (`arcFaceTemplate`'s order, in pixels from its top-left corner) are
    /// `points`, aligned as a model of `side` × `side` pixels takes it: turned, scaled and moved so that the points
    /// land on the template's (`template(side:)`), in sRGB. What falls outside the picture is black, as OpenCV's
    /// alignment leaves it. Nil when the points don't make a face (all in one place) or it can't be drawn.
    public static func aligned(_ image: CGImage, points: [Point], side: Int) -> CGImage? {
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              align(image, points: points, into: context)
        else { return nil }
        return context.makeImage()
    }

    /// Draws the face `aligned` makes into `context`, a square of the model's side; false when the points don't make
    /// a face.
    static func align(_ image: CGImage, points: [Point], into context: CGContext) -> Bool {
        let side = Double(context.width)
        guard let move = Similarity(taking: points, to: template(side: side)) else { return false }
        context.setFillColor(CGColor.black)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.interpolationQuality = .high
        // `move` works from the top-left corner down, Core Graphics from the bottom-left up: the picture's point
        // (x, height − y) has to land on the face's (u, side − v), where (u, v) is `move` of (x, y).
        let height = Double(image.height)
        context.concatenate(CGAffineTransform(a: move.a, b: -move.b, c: move.b, d: move.a,
                                              tx: move.tx - move.b * height, ty: side - move.a * height - move.ty))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return true
    }
}

/// A picture read for its faces: upright, as it's shown, and its faces, each with the landmarks Vision found on it.
public final class FacePicture {
    public struct Face {
        /// Where it is in the picture, as fractions of its width and height from its bottom-left corner (Vision's, and
        /// Photos': `PhotosLibrary.FaceBox`).
        public let box: CGRect
        /// The five points a face is aligned by (`Faces.arcFaceTemplate`'s order), in pixels from the picture's
        /// top-left corner: the centers of Vision's outlines of the eyes and the nose, and the ends of its outline of
        /// the lips along the line between the eyes. Nil when Vision found no landmarks on it. Of the ways tried (the
        /// pupils for the eyes, the nose's lowest point or the end of its crest, the lips' inner outline), these came
        /// nearest to the five points OpenCV's YuNet detector gives SFace, on 253 faces of a real library: off by a
        /// median 11–14% of the distance between the eyes.
        public let points: [Faces.Point]?
        /// Vision's observation of it, what its faceprint request is given.
        let observation: VNFaceObservation
    }

    public let image: CGImage
    public let faces: [Face]
    /// The picture's own size in pixels, upright (its stored width and height, turned by its orientation), whatever
    /// size `image` was read at: what Photos' boxes are converted with (`box(of:)`).
    public let pixels: (width: Int, height: Int)
    /// The picture's requests share one handler: Vision keeps what it made of the picture for the next.
    let handler: VNImageRequestHandler

    /// The picture's long side is read at most this long: a face takes up enough of it to be read, and a 48 MP photo
    /// isn't decoded whole.
    public static let maxPixel = 2048

    /// The picture at `url`, upright, at most `maxPixel` on its long side, with the faces Vision finds in it; or, given
    /// `photosFaces` (where Photos found faces in it), with those faces, Vision only finding their landmarks. Throws
    /// when the picture can't be read.
    public init(contentsOf url: URL, photosFaces: [PhotosLibrary.FaceBox]? = nil) throws {
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                       kCGImageSourceThumbnailMaxPixelSize: Self.maxPixel,
                       kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options)
        else { throw Faces.Failure(description: "can't read \(url.lastPathComponent)") }
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        (self.image, self.handler) = (image, handler)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        if let stored = properties[kCGImagePropertyPixelWidth] as? Int,
           let storedHeight = properties[kCGImagePropertyPixelHeight] as? Int, stored > 0, storedHeight > 0 {
            // Orientations 5 to 8 turn the picture a quarter: its sides swap.
            let turned = (5...8).contains(properties[kCGImagePropertyOrientation] as? Int ?? 1)
            pixels = turned ? (storedHeight, stored) : (stored, storedHeight)
        } else {
            pixels = (image.width, image.height)
        }
        let (width, height) = (Double(image.width), Double(image.height))
        let found: [VNFaceObservation]
        if let photosFaces {
            // One face a request: Vision may answer for several faces in another order, with boxes of its own.
            found = photosFaces.map { face in
                let side = face.size * max(width, height)
                let box = CGRect(x: face.x - side / width / 2, y: face.y - side / height / 2, width: side / width,
                                 height: side / height)
                let given = VNFaceObservation(boundingBox: box)
                let request = VNDetectFaceLandmarksRequest()
                request.inputFaceObservations = [given]
                try? handler.perform([request])
                return request.results?.first ?? given
            }
        } else {
            let request = VNDetectFaceLandmarksRequest()
            try? handler.perform([request])
            found = request.results ?? []
        }
        faces = found.map { Face(box: $0.boundingBox, points: Self.points(of: $0, width: width, height: height),
                                 observation: $0) }
    }

    /// Where Photos says `face` is, as the index keeps it: converted with the picture's own size (`pixels`), not the
    /// size it was read at, which is rounded to whole pixels (10000 × 253 is read at 2048 × 52). The faces pass works
    /// it out again from the size the index has of the file (`Indexer.NamedFace.areKept`), the same numbers.
    public func box(of face: PhotosLibrary.FaceBox) -> Faces.Box? {
        Faces.Box(face, width: Double(pixels.width), height: Double(pixels.height))
    }

    /// The face's five points (`Face.points`), or nil.
    private static func points(of face: VNFaceObservation, width: Double, height: Double) -> [Faces.Point]? {
        let size = CGSize(width: width, height: height)
        func outline(_ region: VNFaceLandmarkRegion2D?) -> [Faces.Point] {
            (region?.pointsInImage(imageSize: size) ?? []).map { Faces.Point(x: Double($0.x), y: height - Double($0.y)) }
        }
        func center(_ points: [Faces.Point]) -> Faces.Point {
            Faces.Point(x: points.map(\.x).reduce(0, +) / Double(points.count),
                        y: points.map(\.y).reduce(0, +) / Double(points.count))
        }
        let (left, right, nose, lips) = (outline(face.landmarks?.leftEye), outline(face.landmarks?.rightEye),
                                         outline(face.landmarks?.nose), outline(face.landmarks?.outerLips))
        guard !left.isEmpty, !right.isEmpty, !nose.isEmpty, !lips.isEmpty else { return nil }
        // The lips' ends: their outline's points farthest along the line from one eye to the other.
        let (from, to) = (center(left), center(right))
        let across = { (point: Faces.Point) in
            (point.x - from.x) * (to.x - from.x) + (point.y - from.y) * (to.y - from.y)
        }
        guard let leftEnd = lips.min(by: { across($0) < across($1) }),
              let rightEnd = lips.max(by: { across($0) < across($1) }) else { return nil }
        return [from, to, center(nose), leftEnd, rightEnd]
    }
}

/// Vision's own faceprints: 128 numbers a face, made by a request Vision doesn't publish (VNCreateFaceprintRequest,
/// given the faces to print; seen on macOS 27, 2026-10-22: one person's faces about 0.87 alike, two people's
/// 0.55–0.69, on the osxphotos test library). The request, its input and its result's faceprint are looked up by name
/// and asked for first: on a macOS without them it's unavailable (`init` throws), never a crash.
public final class VisionFaceprints: FaceRecognizer {
    public let name = "Vision faceprint"
    /// The request's revision, Vision's version and macOS's ("Vision faceprint, revision 3737841669, Vision 10.0.44,
    /// macOS 27.0.1" on 2026-10-22): an update of macOS may change what Vision prints, and the index's prints are all
    /// made again then.
    public let identity: String
    private let request: VNImageBasedRequest.Type

    private static let input = "inputFaceObservations"
    private static let faceprint = "faceprint"
    private static let descriptor = "descriptorData"

    public init() throws {
        guard let request = NSClassFromString("VNCreateFaceprintRequest") as? VNImageBasedRequest.Type,
              request.instancesRespond(to: NSSelectorFromString("setInputFaceObservations:")),
              VNFaceObservation.instancesRespond(to: NSSelectorFromString(Self.faceprint))
        else { throw Faces.Failure(description: "Vision's faceprints aren't available on this macOS") }
        self.request = request
        let vision = Bundle(for: VNRequest.self).infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        identity = "\(name), revision \(request.init().revision), Vision \(vision), "
            + "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
    }

    public func embeddings(of picture: FacePicture) -> [[Float]?] {
        picture.faces.map { face in
            // One face a request: its answer comes back as a new observation, not in the order given.
            let printing = request.init()
            printing.setValue([face.observation], forKey: Self.input)
            guard (try? picture.handler.perform([printing])) != nil,
                  let printed = printing.results?.first as? VNFaceObservation,
                  let faceprint = printed.value(forKey: Self.faceprint) as? NSObject,
                  faceprint.responds(to: NSSelectorFromString(Self.descriptor)),
                  let data = faceprint.value(forKey: Self.descriptor) as? Data
            else { return nil }
            return Faces.floats(fromBytes: data)
        }
    }
}

/// A Core ML face model, given by its file (a .mlpackage, .mlmodel or compiled .mlmodelc): one that takes a face
/// aligned to ArcFace's template (`Faces.aligned`) as a square picture, its size read from the model, and gives one
/// vector. SFace, from OpenCV Zoo, is one (scripts/face-model.py makes it); another is taken the same way.
public final class CoreMLFaceEmbedder: FaceRecognizer {
    public let name: String
    /// The side of the faces the model takes, in pixels.
    let side: Int
    private let model: MLModel
    private let input: String
    private let output: String
    /// The model compiled for this run, in a temporary folder (removed with it), when it wasn't given compiled.
    private let compiled: URL?

    public init(model url: URL) throws {
        let compiled = url.pathExtension == "mlmodelc" ? nil : try MLModel.compileModel(at: url)
        do {
            model = try MLModel(contentsOf: compiled ?? url)
        } catch {
            if let compiled { try? FileManager.default.removeItem(at: compiled) }
            throw error
        }
        self.compiled = compiled
        let description = model.modelDescription
        guard description.inputDescriptionsByName.count == 1,
              let (input, picture) = description.inputDescriptionsByName.first,
              let constraint = picture.imageConstraint, constraint.pixelsWide == constraint.pixelsHigh,
              let output = description.outputDescriptionsByName.values.first(where: { $0.type == .multiArray })?.name
        else {
            throw Faces.Failure(description: "\(url.lastPathComponent) doesn't take one square picture and give a vector")
        }
        (self.input, self.output, side) = (input, output, constraint.pixelsWide)
        name = "Core ML " + url.deletingPathExtension().lastPathComponent
    }

    public var identity: String { name }

    deinit {
        if let compiled { try? FileManager.default.removeItem(at: compiled) }
    }

    public func embeddings(of picture: FacePicture) -> [[Float]?] {
        picture.faces.map { face in face.points.flatMap { try? embedding(of: $0, in: picture.image) } }
    }

    /// The model's vector for the face at `points` of `image`, nil when they don't make a face. The face is aligned
    /// straight into the pixel buffer the model reads (BGRA, which Core ML turns into the model's colors itself):
    /// handing Core ML a picture to convert took 8 ms a face, six times the model's own time (M3 Max, 2026-10-22).
    private func embedding(of points: [Faces.Point], in image: CGImage) throws -> [Float]? {
        var made: CVPixelBuffer?
        let attributes = [kCVPixelBufferCGBitmapContextCompatibilityKey: true,
                          kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()] as CFDictionary
        guard CVPixelBufferCreate(nil, side, side, kCVPixelFormatType_32BGRA, attributes, &made) == kCVReturnSuccess,
              let buffer = made else { throw Faces.Failure(description: "no room for a face") }
        CVPixelBufferLockBaseAddress(buffer, [])
        let bgra = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let drawn = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: side, height: side, bitsPerComponent: 8,
                              bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                              space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: bgra)
            .map { Faces.align(image, points: points, into: $0) } ?? false
        CVPixelBufferUnlockBaseAddress(buffer, [])
        guard drawn else { return nil }
        let result = try model.prediction(from: MLDictionaryFeatureProvider(
            dictionary: [input: MLFeatureValue(pixelBuffer: buffer)]))
        guard let vector = result.featureValue(for: output)?.multiArrayValue else {
            throw Faces.Failure(description: "\(name) gave no vector")
        }
        return (0..<vector.count).map { vector[$0].floatValue }
    }
}
#endif
