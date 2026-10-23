// No face recognizer off the Mac (Vision and Core ML are its): no faces are read, and the index's stay as they are.
#if !(canImport(Vision) && canImport(CoreML))
import Foundation

extension Faces {
    public static func reader(models: URL) -> (any FaceReader)? { nil }
}
#endif
