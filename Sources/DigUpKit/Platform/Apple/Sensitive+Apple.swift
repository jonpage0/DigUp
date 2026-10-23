// The sensitive-picture detector on macOS: Core ML runs the model scripts/sensitive-model.py makes. Platform/Portable has
// the same names for Linux and Windows, where pictures aren't rated.
#if canImport(CoreML)
import CoreGraphics
import CoreML
import CoreVideo
import Foundation
import ImageIO

extension SensitiveModel {
    /// Pictures are rated here (Core ML).
    public static let runsHere = true

    /// The detector, when it's in the models folder `models`; nil when it isn't. Throws when a file of that name is
    /// there but isn't this conversion of this commit (its metadata says which), or Core ML can't load it.
    public static func rater(in models: URL) throws -> (any PictureRater)? {
        let url = folder(in: models).appendingPathComponent(model.name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try CoreMLSensitiveRater(model: url)
    }
}

/// The converted model (`SensitiveModel.model`): a picture squashed to 448 × 448 pixels, as RGB, to the probability of
/// each of its four levels (neutral, low, medium, high). The model normalizes the picture itself; this only scales it,
/// as the model's own preprocessing does (squashed, its proportions not kept).
final class CoreMLSensitiveRater: PictureRater {
    let model = SensitiveModel.identity
    private let network: MLModel
    private let input: String
    private let output: String
    private let side: Int

    /// The model's metadata keys scripts/sensitive-model.py writes: what it is, and its four levels' order.
    private enum Written {
        static let repository = "digup.model"
        static let revision = "digup.revision"
        static let conversion = "digup.conversion"
        static let levels = "digup.levels"
        static let order = "neutral,low,medium,high"
    }

    /// The GPU (or the processor): 62 ms a prediction on an M3 Max against 75 ms when Core ML may choose any processor,
    /// 200 ms on the processor alone and 280 ms with the Neural Engine, which runs float32 poorly (2026-10-22).
    static let computeUnits = MLComputeUnits.cpuAndGPU

    init(model url: URL) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = Self.computeUnits
        network = try MLModel(contentsOf: url, configuration: configuration)
        let description = network.modelDescription
        let written = description.metadata[.creatorDefinedKey] as? [String: String] ?? [:]
        guard written[Written.repository] == SensitiveModel.repository,
              written[Written.revision] == SensitiveModel.revision,
              written[Written.conversion] == "\(SensitiveModel.conversion)", written[Written.levels] == Written.order
        else {
            throw ExtractError.unreadable("\(url.lastPathComponent) isn't conversion \(SensitiveModel.conversion) of "
                                          + "\(SensitiveModel.repository) at \(SensitiveModel.revision.prefix(7)): "
                                          + "make it again with \(SensitiveModel.makeCommand)")
        }
        guard description.inputDescriptionsByName.count == 1, let (input, picture) = description.inputDescriptionsByName.first,
              let constraint = picture.imageConstraint, constraint.pixelsWide == constraint.pixelsHigh,
              let output = description.outputDescriptionsByName.values.first(where: { $0.type == .multiArray })?.name
        else { throw ExtractError.unreadable("\(url.lastPathComponent) doesn't take a square picture and give levels") }
        (self.input, self.output, side) = (input, output, constraint.pixelsWide)
    }

    func levels(ofPictureAt url: URL) throws -> SensitiveLevels {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let picture = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw ExtractError.unreadable("can't decode \(url.lastPathComponent)") }
        return try levels(of: picture)
    }

    /// The picture is drawn straight into the pixel buffer the model reads, squashed to its side (BGRA, which Core ML
    /// turns into the model's RGB itself).
    private func levels(of picture: CGImage) throws -> SensitiveLevels {
        var made: CVPixelBuffer?
        let attributes = [kCVPixelBufferCGBitmapContextCompatibilityKey: true,
                          kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()] as CFDictionary
        guard CVPixelBufferCreate(nil, side, side, kCVPixelFormatType_32BGRA, attributes, &made) == kCVReturnSuccess,
              let buffer = made else { throw ExtractError.unreadable("no room for a picture") }
        CVPixelBufferLockBaseAddress(buffer, [])
        let bgra = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: side, height: side, bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: bgra)
        context?.interpolationQuality = .high
        context?.draw(picture, in: CGRect(x: 0, y: 0, width: side, height: side))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        guard context != nil else { throw ExtractError.unreadable("can't draw the picture") }
        let result = try network.prediction(from: MLDictionaryFeatureProvider(
            dictionary: [input: MLFeatureValue(pixelBuffer: buffer)]))
        guard let levels = result.featureValue(for: output)?.multiArrayValue, levels.count == 4 else {
            throw ExtractError.unreadable("the model gave no levels")
        }
        return SensitiveLevels(low: levels[1].doubleValue, medium: levels[2].doubleValue, high: levels[3].doubleValue)
    }
}
#endif
