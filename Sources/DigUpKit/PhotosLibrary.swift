import Foundation

/// An Apple Photos library (a `.photoslibrary` package): a folder DigUp reads through the library's own catalog instead
/// of a walk. The catalog says which pictures and videos are the library's (not those in the trash, a burst's shots
/// nobody picked, or what's hidden), which file shows each one as Photos does (the edited version, else the original),
/// and what Photos knows about it that no picture shows: who is in it, where it was taken, its title, caption, keywords
/// and albums, and the labels Photos' own analysis gave it. osxphotos (https://github.com/RhetTbull/osxphotos) reads the
/// catalog, run as a program of its own (`osxphotosReader`), so it has to be installed (`uv tool install osxphotos`);
/// without it a library is skipped like any other bundle (`IndexOptions.photos`).
///
/// To the rest of DigUp a library is a folder like any other: chosen on its own or inside a chosen folder (Pictures),
/// skipped like a folder, its files under its path in the index. What differs:
/// - every file read from a library is named after its asset's uuid: an original (originals/F/<uuid>.heic), an edited
///   version (resources/renders/F/<uuid>_1_201_a.heic) or a preview (resources/derivatives/F/<uuid>_1_105_c.jpeg).
///   That's how a result finds its way back to Photos (`asset(ofFile:)`), and the crawl keeps only files named so.
/// - what Photos knows goes to keyword search in a segment of its own (`SegmentKind.photosInfo`), which the crawl keeps
///   up to date without reading the picture again.
/// - the words in a picture are the ones Photos read in it (`RecognizedText`): a screenshot isn't read again, and a
///   photo is found by the words in it too (a sign, a label, a saved post).
/// - a photo whose original is only in iCloud ("Optimize Mac Storage") is read from Photos' own preview: 1,024 pixels on
///   its long side, as many as `Indexer` gives the model for a photo, and an iPhone screenshot's 602 × 1304
///   (measured 2026-10-21). A video only in iCloud has no stand-in here and is left out. DigUp never downloads anything.
/// - a library that can't be read (osxphotos failed, or macOS didn't allow it) keeps what's indexed from it
///   (`CrawlReport.unlisted`), as a drive that's unplugged does.
///
/// DigUp only reads a library, through osxphotos, the files it names and the readings in the catalog: no picture and
/// nothing Photos knows is ever changed. (osxphotos and `RecognizedText` open Photos' databases read-only; SQLite still
/// keeps the shared-memory file beside each one, as it does for any reader, Photos included.)
public enum PhotosLibrary {
    public static let fileExtension = "photoslibrary"

    /// Whether `path` is a Photos library (by name: the package Photos makes ends in .photoslibrary).
    public static func isLibrary(_ path: String) -> Bool {
        (path as NSString).pathExtension.lowercased() == fileExtension
    }

    /// The library that `path` is inside of (as `path` spells it), or nil.
    public static func library(containing path: String) -> String? {
        guard let end = path.range(of: "." + fileExtension + "/", options: .caseInsensitive) else { return nil }
        return String(path[..<end.upperBound].dropLast())
    }

    /// The Photos asset a file of a library shows: the library, and the asset's uuid from the file's name. Nil for any
    /// other file.
    public static func asset(ofFile path: String) -> (library: String, uuid: String)? {
        guard let library = library(containing: path) else { return nil }
        let name = (path as NSString).lastPathComponent
        guard name.range(of: uuidPattern, options: .regularExpression) != nil else { return nil }
        return (library, String(name.prefix(36)))
    }

    private static let uuidPattern = "^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"

    /// Where in a library new, edited and downloaded pictures land: the only changes in it the folder watcher counts.
    /// Photos writes its database all the time (its analysis, iCloud), which never needs a crawl by itself; a change
    /// that's only in the database (a keyword, a name given to a face) is picked up by the next crawl that happens for
    /// any reason, once the listing it would replace is `listingLifetime` old.
    static let pictureFolders = ["originals", "resources/renders", "resources/derivatives"]

    /// Whether a change at `path`, inside `library`, can change what DigUp reads of it.
    public static func isPictureChange(_ path: String, in library: String) -> Bool {
        let prefix = library.hasSuffix("/") ? library : library + "/"
        guard path.hasPrefix(prefix) else { return false }
        let rest = path.dropFirst(prefix.count)
        return pictureFolders.contains { rest == $0 || rest.hasPrefix($0 + "/") }
    }

    // MARK: Listing

    /// A picture or video of the library, as DigUp reads it.
    public struct Asset: Codable, Sendable, Equatable {
        public let uuid: String
        /// The file read (a real path, inside the library): the edited version, else the original, else (a photo whose
        /// original is only in iCloud) Photos' largest still preview.
        public let path: String
        public let movie: Bool
        /// Photos says it's a screenshot: one has its words searched too, as screenshots elsewhere do. They're the ones
        /// Photos read in it (`RecognizedText`), else DigUp's own reading (`OCR`).
        public let screenshot: Bool
        /// What a result calls it: its title in Photos, else the name of the file it came in as.
        public let title: String
        /// When it was taken, in seconds since 1970.
        public let date: Double
        /// What Photos knows about it, for keyword search: its title, caption and original name, keywords, the people
        /// and pets named in it, its albums, Photos' labels (what's in it, what's happening, holidays, landmarks, sounds)
        /// and its places (from the street to the country). Not dates, cameras, file types or the broad regions around
        /// a place ("Sun Belt"), which would match thousands of pictures at once, nor the words Photos read in the
        /// picture, which come with the picture when it's read (`RecognizedText`).
        public let words: [String]

        public init(uuid: String, path: String, movie: Bool, screenshot: Bool, title: String, date: Double,
                    words: [String]) {
            (self.uuid, self.path, self.movie, self.screenshot) = (uuid, path, movie, screenshot)
            (self.title, self.date, self.words) = (title, date, words)
        }

        public var kind: FileKind { movie ? .video : screenshot ? .screenshot : .image }

        /// Photos' words as keyword search keeps them, one a line.
        public var text: String { words.joined(separator: "\n") }
    }

    /// What a library holds for DigUp, and what was left out of it and why (reason → assets).
    public struct Listing: Codable, Sendable, Equatable {
        public var assets: [Asset]
        public var skipped: [String: Int]

        public init(assets: [Asset], skipped: [String: Int] = [:]) {
            self.assets = assets
            self.skipped = skipped
        }
    }

    /// How a library is read: its path in, its listing out. It throws when the library can't be read at all.
    public struct Reader: Sendable {
        public let list: @Sendable (_ library: String) throws -> Listing

        public init(list: @escaping @Sendable (_ library: String) throws -> Listing) {
            self.list = list
        }
    }

    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    // MARK: osxphotos

    /// The osxphotos program: $DIGUP_OSXPHOTOS (empty: none), else where `uv tool install`, pipx, `pip install --user`,
    /// Homebrew or MacPorts put it, else on PATH. The app's helpers run with launchd's PATH, which has none of those.
    /// Nil where it isn't installed, and off the Mac. Looked for each time (a few file checks): installed while the app
    /// runs, it's found without a relaunch.
    public static var osxphotos: String? {
        #if os(macOS)
        let environment = ProcessInfo.processInfo.environment
        let fm = FileManager.default
        if let chosen = environment["DIGUP_OSXPHOTOS"] {
            return !chosen.isEmpty && fm.isExecutableFile(atPath: chosen) ? chosen : nil
        }
        let folders = [fm.homeDirectoryForCurrentUser.path + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin",
                       "/opt/local/bin"] + (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return folders.map { $0 + "/osxphotos" }.first { fm.isExecutableFile(atPath: $0) }
        #else
        return nil
        #endif
    }

    /// The command that installs osxphotos, as the app shows it.
    public static let installCommand = "uv tool install osxphotos"

    /// The Photos libraries right inside `folder`, by name (Pictures holds the one Photos makes).
    public static func libraries(in folder: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).filter(isLibrary).sorted()
            .map { (folder as NSString).appendingPathComponent($0) }
    }

    /// Whether macOS lets DigUp into a library. Asking can bring up macOS's question, and waits for the answer: never on
    /// the main thread.
    public enum Access: Sendable {
        case allowed, denied, missing
    }

    public static func access(_ library: String) -> Access {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: library, isDirectory: &isFolder), isFolder.boolValue else {
            return .missing
        }
        return (try? FileManager.default.contentsOfDirectory(atPath: library + "/originals")) == nil ? .denied : .allowed
    }

    // MARK: The words Photos read

    /// The words Photos found in a library's pictures (Live Text: macOS and iOS read every picture; a picture whose
    /// original is only in iCloud has its reading too). They're used instead of DigUp's own reading, which has only the
    /// preview when the original is in iCloud. Photos keeps a picture's reading in its catalog (database/Photos.sqlite)
    /// as Vision made it, an archived `VNDocumentObservation`, read out with `recognizedText(inArchive:)` (on the Mac).
    ///
    /// Measured on 60 iPhone screenshots of a real library (2026-10-21; previews of 602 × 1304, about half the
    /// original): Photos' reading and DigUp's OCR of the preview found as many words (70 and 68 a screenshot, 65 of
    /// them the same), and each found 91–94% of the other's exact-lookup strings (codes, URLs, prices). Each read words
    /// the other got wrong, Photos more often right where the preview is small or a word is broken over two lines.
    /// Photos' reading takes 3 ms to unpack; DigUp's OCR took 1.4 s a screenshot there (an M3 Max on battery). 17,009 of
    /// the library's 18,276 screenshots had one, and 794 more were marked read with no words found (the OCR found none
    /// in 15 of them either).
    ///
    /// One per library and thread: it keeps the catalog open (read-only) between pictures.
    public final class RecognizedText {
        private let library: String
        private var catalog: Database?
        private var unreadable = false

        public init(library: String) {
            self.library = library
        }

        /// The words Photos read in the asset's picture, in reading order; "" when Photos read it and found none; nil
        /// when Photos hasn't read it (yet, or it couldn't: its reading version is then 32767, seen with words DigUp's
        /// OCR did find), when the catalog has no readings (Photos before macOS 13) or can't be opened, and off the
        /// Mac.
        public func text(of uuid: String) -> String? {
            guard PhotosLibrary.readsRecognizedText, !unreadable else { return nil }
            do {
                if catalog == nil { catalog = try Database(readingOnly: library + "/database/Photos.sqlite") }
                var text: String?
                try catalog?.query("""
                    SELECT m.ZCHARACTERRECOGNITIONVERSION, c.ZCHARACTERRECOGNITIONDATA FROM ZASSET a
                    JOIN ZMEDIAANALYSISASSETATTRIBUTES m ON m.ZASSET = a.Z_PK
                    LEFT JOIN ZCHARACTERRECOGNITIONATTRIBUTES c ON c.Z_PK = m.ZCHARACTERRECOGNITIONATTRIBUTES
                    WHERE a.ZUUID = ?
                    """, [.text(uuid)]) { row in
                    if let archive = row.blob(1) {
                        text = PhotosLibrary.recognizedText(inArchive: archive)
                    } else if (1..<32767).contains(row.int(0)) {
                        text = ""
                    }
                }
                return text
            } catch {
                // A catalog without these tables, or one that can't be opened: DigUp reads screenshots itself.
                unreadable = true
                return nil
            }
        }
    }

    /// What the last listing of a library found (kept in the index folder by `osxphotosReader`), or nil before one.
    public struct ListingSummary: Sendable, Equatable {
        public let listedAt: Date
        public let assets: Int
        /// Reason → assets left out ("in iCloud, not downloaded", "in a shared album"…).
        public let skipped: [String: Int]
    }

    public static func lastListing(of library: String, keptIn index: URL) -> ListingSummary? {
        let file = index.appendingPathComponent("photos").appendingPathComponent(keptName(of: library))
        guard let data = try? Data(contentsOf: file), let kept = try? JSONDecoder().decode(Kept.self, from: data),
              kept.library == library else { return nil }
        return ListingSummary(listedAt: Date(timeIntervalSince1970: kept.listedAt), assets: kept.listing.assets.count,
                              skipped: kept.listing.skipped)
    }

    /// A listing is used again while the library's pictures are as they were, and while it's younger than this when the
    /// database alone changed (Photos writes it all the time). A big library takes osxphotos a while to read, and a
    /// crawl happens whenever anything changes in any chosen folder.
    static let listingLifetime = 300.0

    /// Reads libraries with osxphotos, keeping each one's listing in `folder` (the index folder: photos/), or nil when
    /// osxphotos isn't installed.
    public static func osxphotosReader(keepingListingsIn folder: URL?) -> Reader? {
        guard let program = osxphotos else { return nil }
        let listings = folder?.appendingPathComponent("photos", isDirectory: true)
        return Reader { library in try listing(of: library, program: program, keptIn: listings) }
    }

    /// The library's listing: the one kept from before while it's current (`Kept.isCurrent`), else a new one.
    static func listing(of library: String, program: String, keptIn folder: URL?, now: Date = Date()) throws
        -> Listing {
        // Looked at before osxphotos reads it, so that a change while it reads is caught by the next crawl.
        let state = State(of: library)
        let file = folder?.appendingPathComponent(keptName(of: library))
        if let file, let data = try? Data(contentsOf: file), let kept = try? JSONDecoder().decode(Kept.self, from: data),
           kept.isCurrent(library: library, state: state, now: now.timeIntervalSince1970) {
            return kept.listing
        }
        let listing = try run(program, library: library)
        if let file, let folder {
            let kept = Kept(library: library, listedAt: now.timeIntervalSince1970, state: state, listing: listing)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? JSONEncoder().encode(kept).write(to: file, options: .atomic)
        }
        return listing
    }

    /// What a kept listing is checked against: the folders where pictures land (a new, edited or downloaded picture
    /// changes one of them, one level down) and the databases osxphotos reads: the catalog, and the search database
    /// that holds Photos' labels and places (search/psi.sqlite in libraries from macOS 13 to 26, search/leo.sqlite in
    /// macOS 27's, as seen 2026-10-21).
    struct State: Codable, Equatable {
        var pictures: String
        var database: String

        init(pictures: String, database: String) {
            self.pictures = pictures
            self.database = database
        }

        init(of library: String) {
            var pictures: [String] = []
            for folder in PhotosLibrary.pictureFolders + ["resources/derivatives/masters"] {
                let path = library + "/" + folder
                pictures.append("\(folder) \(Self.stamp(path))")
                for name in ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).sorted()
                    where !name.hasPrefix(".") {
                    pictures.append("\(folder)/\(name) \(Self.stamp(path + "/" + name))")
                }
            }
            self.pictures = pictures.joined(separator: "\n")
            database = ["Photos.sqlite", "search/psi.sqlite", "search/leo.sqlite"]
                .flatMap { [$0, $0 + "-wal"] }.map { Self.stamp(library + "/database/" + $0) }.joined(separator: " ")
        }

        private static func stamp(_ path: String) -> String {
            guard let info = FileSystem.info(of: path) else { return "-" }
            return "\(info.size):\(info.mtime)"
        }
    }

    /// A listing kept in the index folder, with what it was made from.
    struct Kept: Codable {
        static let currentVersion = 1
        var version = Kept.currentVersion
        /// The script that listed it (`script`, hashed): a listing made another way is made again.
        var reader = PhotosLibrary.hash(PhotosLibrary.script)
        var library: String
        var listedAt: Double
        var state: State
        var listing: Listing

        /// Made by this script, the pictures are as they were, and so are the databases, or the listing is younger
        /// than `listingLifetime`.
        func isCurrent(library: String, state: State, now: Double) -> Bool {
            let age = now - listedAt
            return version == Self.currentVersion && reader == PhotosLibrary.hash(PhotosLibrary.script)
                && self.library == library && self.state.pictures == state.pictures
                && (self.state.database == state.database || (0..<PhotosLibrary.listingLifetime).contains(age))
        }
    }

    /// The kept listing's file name: the library's path, hashed.
    static func keptName(of library: String) -> String {
        hash(library) + ".json"
    }

    /// FNV-1a, as 16 hex digits: a name for a path, a check of a script.
    static func hash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return String(format: "%016llx", hash)
    }

    /// Runs osxphotos on the library (`script`), for up to `timeout` seconds: macOS may first ask whether DigUp can see
    /// the photos (the read waits for the answer), and a big library takes osxphotos a while by itself.
    static func run(_ program: String, library: String, timeout: Double = 1800) throws -> Listing {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("DigUp-photos-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let code = work.appendingPathComponent("list.py")
        let output = work.appendingPathComponent("listing.json")
        let errors = work.appendingPathComponent("errors.txt")
        try Data(script.utf8).write(to: code)
        fm.createFile(atPath: errors.path, contents: nil)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: program)
        process.arguments = ["run", code.path, library, output.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = try FileHandle(forWritingTo: errors)
        let ended = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in ended.signal() }
        try process.run()
        if ended.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            #if !os(Windows)
            if ended.wait(timeout: .now() + 5) == .timedOut { kill(process.processIdentifier, SIGKILL) }
            #endif
            throw Failure(description: "osxphotos took more than \(Int(timeout / 60)) minutes to read \(library)")
        }
        guard process.terminationStatus == 0, let data = try? Data(contentsOf: output) else {
            let said = (try? String(contentsOf: errors, encoding: .utf8)) ?? ""
            let last = said.split(separator: "\n").last.map(String.init) ?? "it stopped (\(process.terminationStatus))"
            throw Failure(description: "osxphotos couldn't read \(library): \(last)")
        }
        return try JSONDecoder().decode(Listing.self, from: data)
    }

    /// What osxphotos runs (`osxphotos run list.py <library> <output>`): the listing, as JSON, written to <output>.
    static let script = #"""
        # DigUp's reader of a Photos library (Sources/DigUpKit/PhotosLibrary.swift):
        #   osxphotos run list.py <library> <output.json>
        import json
        import os
        import sys

        import osxphotos

        STILLS = (".jpeg", ".jpg", ".heic", ".png", ".tif", ".tiff")
        # SearchInfo's lists that say what a picture shows, where it was taken, and who and what is in it. Not its
        # "locality names": the broad regions around a place ("Sun Belt", "Gulf South", "Continental United States"),
        # shared by every picture taken within hundreds of miles, so a word of them matches all of those at once.
        SEARCH_INFO = ("pets", "labels", "activities", "human_actions", "holidays", "events", "event_performers",
                       "event_types", "landmarks", "sounds", "document_types", "place_names", "streets", "neighborhoods",
                       "bodies_of_water", "venues", "venue_types", "areas_of_interest", "city", "state", "country")


        def quietly(read):
            """What osxphotos can't say for this library's version of Photos is nothing."""
            try:
                return read() or []
            except Exception:
                return []


        def words(photo):
            found, seen = [], set()

            def add(values):
                for value in [values] if isinstance(values, str) else values or []:
                    # Photos wraps place names in direction marks ("\u2068Adelaide\u2069"): not part of the words.
                    value = value.replace("\u2068", "").replace("\u2069", "").strip() if isinstance(value, str) else ""
                    if value and value != "_UNKNOWN_" and value.casefold() not in seen:
                        seen.add(value.casefold())
                        found.append(value)

            add([photo.title, photo.description, photo.original_filename])
            add(quietly(lambda: photo.keywords))
            add(quietly(lambda: photo.persons))
            add(quietly(lambda: photo.albums))
            info = quietly(lambda: photo.search_info)
            if info:
                for name in SEARCH_INFO:
                    add(quietly(lambda: getattr(info, name)))
            return found


        def picture(photo):
            """The file that shows it as Photos does, or None when there's none on this Mac."""
            for path in (photo.path_edited, photo.path):
                if path:
                    return path
            if photo.ismovie:
                return None
            for path in quietly(lambda: photo.path_derivatives):  # largest first
                if path.lower().endswith(STILLS):
                    return path
            return None


        def main():
            library, output = sys.argv[1], sys.argv[2]
            db = osxphotos.PhotosDB(dbfile=library)
            root = os.path.realpath(library) + os.sep
            assets, skipped = [], {}

            def skip(reason):
                skipped[reason] = skipped.get(reason, 0) + 1

            for photo in db.photos():  # not those in the trash, and of a burst only the shots picked
                if photo.hidden:
                    skip("hidden in Photos")
                    continue
                if photo.shared:
                    skip("in a shared album")
                    continue
                if quietly(lambda: photo.syndicated) and not quietly(lambda: photo.saved_to_library):
                    skip("shared with you, not saved")
                    continue
                path = None if photo.isreference else picture(photo)
                if photo.isreference or (path and not os.path.realpath(path).startswith(root)):
                    skip("kept outside the library")
                    continue
                if path is None:
                    skip("in iCloud, not downloaded")
                    continue
                assets.append({
                    "uuid": photo.uuid,
                    "path": os.path.realpath(path),
                    "movie": bool(photo.ismovie),
                    "screenshot": bool(quietly(lambda: photo.screenshot)),
                    "title": photo.title or photo.original_filename or "",
                    "date": photo.date.timestamp(),
                    "words": words(photo),
                })
            with open(output + ".partial", "w", encoding="utf-8") as file:
                json.dump({"assets": assets, "skipped": skipped}, file, ensure_ascii=False)
            os.replace(output + ".partial", output)


        main()
        """#
}
