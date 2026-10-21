// No Photos libraries off the Mac: nothing Photos read to unpack.
#if !canImport(Vision)
import Foundation

extension PhotosLibrary {
    static let readsRecognizedText = false

    static func recognizedText(inArchive archive: Data) -> String? { nil }
}
#endif
