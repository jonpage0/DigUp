// No sensitive-picture detector off the Mac yet (it's a Core ML model): pictures aren't rated, and nothing is blurred.
#if !canImport(CoreML)
import Foundation

extension SensitiveModel {
    public static let runsHere = false

    public static func rater(in models: URL) throws -> (any PictureRater)? { nil }
}
#endif
