import Foundation
import Observation

/// What's marked ♥ in DigUp (never in Photos). The user makes these, so they're kept out of the index, which DigUp
/// rebuilds and which Settings → Storage can delete: `favorites.json` beside the index folder, read once and written
/// whole on each change (to a temporary file, then renamed over the old one).
///
/// The shape (approved 2026-10-22):
///
///     { "version": 1,
///       "favorites": [ { "photos": { "asset": "<uuid>", "library": "<path>" }, "added": "<ISO 8601>" },
///                      { "file": { "bookmark": "<base64>", "path": "<path>" }, "added": "<ISO 8601>" } ] }
///
/// A Photos item is its asset uuid, which a download or an edit keeps while its file changes; `library` is where it
/// was, for showing. A file is its bookmark, which follows it when it's moved or renamed on its disk; `path` is where
/// it last was, rewritten when the bookmark finds it somewhere new. A favorite that's gone stays one: nothing is
/// dropped behind the user's back, and the filter just doesn't find it. A file DigUp can't read as this shape (a newer
/// version, or damaged) is left as it is and never written over.
@MainActor @Observable
final class Favorites {
    struct Entry: Codable, Equatable {
        struct Photos: Codable, Equatable {
            var asset: String
            var library: String
        }

        struct File: Codable, Equatable {
            var bookmark: Data
            var path: String
        }

        var photos: Photos?
        var file: File?
        var added: Date
    }

    private struct Stored: Codable {
        var version: Int
        var favorites: [Entry]
    }

    private(set) var entries: [Entry] = []
    /// The file is there but isn't this shape: nothing can be marked until it's fixed, so it's never written over.
    private(set) var unreadable = false
    @ObservationIgnored let url: URL

    /// Beside the index folder (`~/Library/Application Support/DigUp/favorites.json` for the default one).
    convenience init(beside indexDirectory: URL) {
        self.init(url: indexDirectory.deletingLastPathComponent().appendingPathComponent("favorites.json"))
    }

    init(url: URL) {
        self.url = url
        load()
    }

    var count: Int { entries.count }

    /// Marked ♥, as last looked up: a file moved since then is found again at the next `followMoves` (each search,
    /// each change of a mark).
    func contains(_ row: ResultRow) -> Bool {
        if let photos = row.photos { return entries.contains { $0.photos?.asset == photos.uuid } }
        return entries.contains { $0.file?.path == row.url.path }
    }

    /// Marks it, or takes the mark off. Nothing changes while the file can't be read.
    func toggle(_ row: ResultRow) {
        guard !unreadable else { return }
        followMoves()
        if contains(row) {
            entries.removeAll { entry in
                if let photos = row.photos { return entry.photos?.asset == photos.uuid }
                return entry.file?.path == row.url.path
            }
        } else if let photos = row.photos {
            entries.append(Entry(photos: .init(asset: photos.uuid, library: photos.library), added: Date()))
        } else {
            guard let bookmark = try? row.url.bookmarkData() else {
                log("favorites: no bookmark for a file, so it isn't marked")
                return
            }
            entries.append(Entry(file: .init(bookmark: bookmark, path: row.url.path), added: Date()))
        }
        save()
    }

    /// Each file favorite looked up by its bookmark again, so one moved or renamed while DigUp runs is found where it
    /// is now (and saved so); a search does it before showing its results.
    func followMoves() {
        if followMovedFiles() { save() }
    }

    /// The files the ♥ DigUp filter keeps: each file favorite where it is now, and each Photos favorite's indexed file.
    func paths(using engine: Engine) async -> Set<String> {
        followMoves()
        let files = entries.compactMap(\.file?.path)
        let assets = Set(entries.compactMap(\.photos?.asset))
        return Set(files).union(await engine.paths(ofAssets: assets).values)
    }

    // MARK: The file

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private func load() {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let stored = try Self.decoder.decode(Stored.self, from: Data(contentsOf: url))
            guard stored.version == 1 else {
                unreadable = true
                log("favorites: \(url.lastPathComponent) is version \(stored.version); this DigUp reads 1, so it's left alone")
                return
            }
            // Each entry is a Photos item or a file, never both or neither; one that isn't means the file isn't this
            // shape, and it's left as it is.
            guard stored.favorites.allSatisfy({ ($0.photos == nil) != ($0.file == nil) }) else {
                unreadable = true
                log("favorites: \(url.lastPathComponent) has an entry that's neither one Photos item nor one file; "
                    + "it's left as it is")
                return
            }
            entries = stored.favorites
            followMoves()
            log("favorites: \(entries.count)")
        } catch {
            unreadable = true
            log("favorites: \(url.lastPathComponent) can't be read (\(error)); it's left as it is")
        }
    }

    /// A file favorite whose bookmark now finds it elsewhere (moved or renamed) gets its new path, and a fresh bookmark
    /// when macOS says the old one is stale. Whether anything changed.
    private func followMovedFiles() -> Bool {
        var changed = false
        for index in entries.indices {
            guard let file = entries[index].file else { continue }
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: file.bookmark, options: [.withoutUI, .withoutMounting],
                                     relativeTo: nil, bookmarkDataIsStale: &stale) else { continue }
            if url.path != file.path {
                entries[index].file?.path = url.path
                changed = true
            }
            if stale, let fresh = try? url.bookmarkData() {
                entries[index].file?.bookmark = fresh
                changed = true
            }
        }
        return changed
    }

    private func save() {
        guard !unreadable else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.encoder.encode(Stored(version: 1, favorites: entries)).write(to: url, options: .atomic)
        } catch {
            log("favorites: can't save \(url.lastPathComponent): \(error)")
        }
    }
}
