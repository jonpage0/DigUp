import DigUpKit
import Foundation
import Observation

/// What you told DigUp about faces in pictures outside Photos ("this is Tati", "not Tati": `FaceCorrections`), kept in
/// `face-corrections.json` beside the index folder, which the index's matches are made from (`IndexStore.faceMatching`).
/// The app is its only writer: read once and written whole on each change (to a temporary file, then renamed over the
/// old one). A file DigUp can't read as that shape (a newer version, or damaged) is left as it is and never written
/// over: nothing can be said until it's fixed.
@MainActor @Observable
final class FaceCorrectionsFile {
    private(set) var corrections = FaceCorrections()
    /// The file is there but isn't the shape: it's never written over.
    private(set) var unreadable = false
    @ObservationIgnored let url: URL

    /// Beside the index folder (`~/Library/Application Support/DigUp/face-corrections.json` for the default one).
    convenience init(beside indexDirectory: URL) {
        self.init(url: FaceCorrections.url(beside: indexDirectory))
    }

    init(url: URL) {
        self.url = url
        load()
    }

    /// Says who the face at `face` in `row`'s picture is, or isn't: saved at once, in place of what was said of that
    /// face and person before (and of who else it is, for `is`). Whether it was saved: not while the file can't be read,
    /// for a picture in Photos (its names are Photos'), or without a bookmark for the file.
    func say(_ says: FaceCorrections.Says, face: Faces.Box, in row: ResultRow, person: FaceCorrections.Person) -> Bool {
        guard !unreadable, row.photos == nil else { return false }
        guard let bookmark = try? row.url.bookmarkData() else {
            log("face corrections: no bookmark for a file, so nothing is said of it")
            return false
        }
        _ = corrections.followMoves()   // so the same face of a picture moved since is found
        corrections.add(.init(file: .init(bookmark: bookmark, path: row.url.path), face: face, person: person,
                              says: says))
        return save()
    }

    private func load() {
        do {
            corrections = try FaceCorrections(contentsOf: url)
            if corrections.followMoves() { save() }
            log("face corrections: \(corrections.corrections.count)")
        } catch {
            unreadable = true
            log("face corrections: \(url.lastPathComponent) can't be read (\(error)); it's left as it is")
        }
    }

    @discardableResult
    private func save() -> Bool {
        guard !unreadable else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try corrections.data().write(to: url, options: .atomic)
            return true
        } catch {
            log("face corrections: can't save \(url.lastPathComponent): \(error)")
            return false
        }
    }
}
