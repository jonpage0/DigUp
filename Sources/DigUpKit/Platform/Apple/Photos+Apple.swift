// Photos' readings of its pictures on macOS: Vision's archived document observations. Platform/Portable has the same
// names for Linux and Windows, where there's no Photos.
#if canImport(Vision)
import Foundation
import Vision

extension PhotosLibrary {
    /// Photos' readings can be unpacked here (Vision).
    static let readsRecognizedText = true

    /// The words in a reading Photos keeps (`RecognizedText`): an archived `VNDocumentObservation`, unpacked with secure
    /// coding. Vision doesn't publish that class or its transcript (all the words, in reading order: `getTranscript`),
    /// so both are looked up by name and the method is asked for first: a macOS without them gives nil, and DigUp
    /// reads screenshots itself again. Seen on macOS 27 (2026-10-21).
    static func recognizedText(inArchive archive: Data) -> String? {
        guard let type = NSClassFromString("VNDocumentObservation") else { return nil }
        let transcript = NSSelectorFromString("getTranscript")
        return autoreleasepool {
            guard let reading = (try? NSKeyedUnarchiver.unarchivedObject(ofClasses: [type], from: archive)) as? NSObject,
                  reading.responds(to: transcript)
            else { return nil }
            return reading.perform(transcript)?.takeUnretainedValue() as? String
        }
    }
}
#endif
