import Foundation

/// An Apple Photos library (a `.photoslibrary` package): a folder DigUp reads through the library's own catalog instead
/// of a walk. The catalog says which pictures and videos are the library's (not those in the trash, a burst's shots
/// nobody picked, or what's hidden, unless `IndexOptions.includeHiddenPhotos`), which file shows each one as Photos does
/// (the edited version, else the original), and what Photos knows about it that no picture shows: who is in it, where it
/// was taken, its title, caption, keywords and albums, the labels Photos' own analysis gave it, how it came into the
/// library and the device that took it. osxphotos (https://github.com/RhetTbull/osxphotos) reads the catalog, run as a
/// program of its own (`osxphotosReader`), so it has to be installed (`uv tool install osxphotos`); without it a library
/// is skipped like any other bundle (`IndexOptions.photos`).
///
/// To the rest of DigUp a library is a folder like any other: chosen on its own or inside a chosen folder (Pictures),
/// skipped like a folder, its files under its path in the index. What differs:
/// - every file read from a library is named after its asset's uuid: an original (originals/F/<uuid>.heic), an edited
///   version (resources/renders/F/<uuid>_1_201_a.heic), a preview (resources/derivatives/F/<uuid>_1_105_c.jpeg) or a
///   video's filmstrip still (resources/derivatives/cvt/F/<uuid>/<uuid>_cvt_t0000.jpeg). That's how a result finds its
///   way back to Photos (`asset(ofFile:)`), and the crawl keeps only files named so. It's also how an asset stays one
///   row of the index while its file changes (downloaded, edited, back to Photos' stills): `Indexer.sync`.
/// - what Photos knows goes to keyword search in a segment of its own (`SegmentKind.photosInfo`), and what can be
///   filtered on (who is in it, its albums, favorites, where it was taken, how it came in, the device that took it) to
///   tables of its own (`IndexStore.PhotosFacts`). The crawl keeps both up to date without reading the picture again.
/// - the words in a picture are the ones Photos read in it (`RecognizedText`): a screenshot isn't read again, and a
///   photo is found by the words in it too (a sign, a label, a saved post).
/// - an asset whose original is only in iCloud ("Optimize Mac Storage") is read from what Photos keeps of it here, and
///   the listing says which (`Reading`): a photo from Photos' own preview, 1,024 pixels on its long side, as many as
///   `Indexer` gives the model for a photo, and an iPhone screenshot's 602 × 1304 (measured 2026-10-21); a video from
///   the stills of Photos' filmstrip of it, else one poster still. A video with neither is left out. DigUp never
///   downloads anything.
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

    /// Any file inside a library, as an SQL `LIKE` pattern (case-insensitive, as `library(containing:)`).
    public static let filesPattern = "%." + fileExtension + "/%"

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

    /// What DigUp read of an asset (`Asset.reading`, kept as `photos_assets.reading`). The listing says which file it
    /// chose, rather than DigUp guessing later from how a path is spelled: Photos' folder layout is private, and can
    /// change with a macOS release.
    public enum Reading: String, Codable, Sendable, CaseIterable {
        /// Its original, on this Mac.
        case original
        /// Photos' render of an edit.
        case edited
        /// A photo whose original is only in iCloud: Photos' largest still preview of it.
        case preview
        /// A video whose original is only in iCloud: the stills of Photos' filmstrip of it (`filmstrip(startingAt:)`),
        /// each read as a frame with no time. The asset's file is the first.
        case stills
        /// A video only in iCloud that has no filmstrip: one still of it, its poster, else Photos' small thumbnail.
        case poster

        /// A video in iCloud read from what Photos keeps of it: pictures, not a video (`Indexer`).
        public var isStandIn: Bool { self == .stills || self == .poster }
    }

    /// How an asset came into the library (`Asset.origin`, kept as `photos_assets.origin`), from what Photos' catalog
    /// records: whether it's a screenshot, the app that saved it (since about iOS 13: `Asset.originApp`) and a number
    /// (ZADDITIONALASSETATTRIBUTES.ZIMPORTEDBY: `Asset.importedBy`).
    public enum Origin: String, Sendable, CaseIterable {
        /// Shot with a device's camera into this library.
        case camera
        /// Photos says it's a screenshot.
        case screenshot
        /// Another app or the system saved it: Messages, AirDrop, Safari, any other app.
        case saved
        /// Imported through Photos, from a Mac's folder or a camera's card.
        case imported
        /// Nothing recorded (older items).
        case unknown

        /// The apps whose saving a picture means a device's camera took it: the Camera app, and Messages' camera.
        static let cameraApps: Set<String> = ["com.apple.camera", "com.apple.camera.CameraMessagesApp"]
        /// Photos itself: an import.
        static let photosApp = "com.apple.Photos"
        /// ZIMPORTEDBY's numbers, which Apple doesn't document: their meaning is inferred from a real library (56,302
        /// items, read 2026-10-21), by the lens each item's EXIF names and the apps Photos recorded beside the
        /// number. 1 is the back camera (17,180 of its 17,946 items name a back-camera lens, 1 a front one), 2 the front
        /// one (3,112 of 3,138 name a front-camera lens). 5 comes with Photos as the app (3,636 of 4,040): an import. 3
        /// and 6 come with other apps (Reddit and X clients, ChatGPT, Instagram…); 7 with no app (164 items); 8 with
        /// the system's (screenshots, Messages' camera, AirDrop, Messages, Safari); 9 with Messages, Safari and Files;
        /// 12 with Messages. 0 is nothing recorded (4,628 items).
        static let cameraNumbers: Set<Int> = [1, 2]
        static let importedNumber = 5
        static let savedNumbers: Set<Int> = [3, 6, 7, 8, 9, 12]

        /// The origin Photos' records mean, in this order: a screenshot is one whoever saved it; then the camera, by
        /// its number or its app; an import, by Photos as the app or its number; saved, by any other app or a number
        /// that means another app or the system; else unknown.
        public init(screenshot: Bool, importedBy number: Int?, app: String?) {
            if screenshot {
                self = .screenshot
            } else if number.map(Self.cameraNumbers.contains) == true || app.map(Self.cameraApps.contains) == true {
                self = .camera
            } else if app == Self.photosApp || number == Self.importedNumber {
                self = .imported
            } else if app != nil || number.map(Self.savedNumbers.contains) == true {
                self = .saved
            } else {
                self = .unknown
            }
        }
    }

    /// A picture or video of the library, as DigUp reads it.
    public struct Asset: Codable, Sendable, Equatable {
        public let uuid: String
        /// The file read (a real path, inside the library), as `reading` says: the edited version, else the original,
        /// else (its original only in iCloud) a photo's largest still preview, or a video's first filmstrip still or
        /// its poster.
        public let path: String
        public let reading: Reading
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
        /// A favorite in Photos.
        public let favorite: Bool
        /// Where it was taken, as Photos shows it (nil, nil: Photos has no location for it), and Photos' name for the
        /// place.
        public let latitude: Double?
        public let longitude: Double?
        public let place: String?
        /// The uuids of the people and pets named in it (`Listing.people`), and of its albums (`Listing.albums`).
        public let people: [String]
        public let albums: [String]
        /// How it came into the library, as Photos' catalog records it (`origin` reads them): its ZIMPORTEDBY number
        /// (nil where the catalog keeps none), and the app that saved it, by its bundle id (nil when Photos recorded
        /// none).
        public let importedBy: Int?
        public let originApp: String?
        /// The device that took it, from the EXIF Photos kept ("iPhone 15 Pro"); nil when there's none.
        public let camera: String?
        /// Hidden in Photos (its Hidden album: listed only with `IndexOptions.includeHiddenPhotos`); nil in a listing
        /// kept from before DigUp recorded it. What AI apps don't see until they're allowed (`visibleAssets`).
        public let hidden: Bool?

        public init(uuid: String, path: String, movie: Bool, screenshot: Bool, title: String, date: Double,
                    words: [String], favorite: Bool = false, latitude: Double? = nil, longitude: Double? = nil,
                    place: String? = nil, people: [String] = [], albums: [String] = [], reading: Reading = .original,
                    importedBy: Int? = nil, originApp: String? = nil, camera: String? = nil, hidden: Bool? = false) {
            (self.uuid, self.path, self.reading, self.movie, self.screenshot) = (uuid, path, reading, movie, screenshot)
            (self.title, self.date, self.words) = (title, date, words)
            (self.favorite, self.latitude, self.longitude, self.place) = (favorite, latitude, longitude, place)
            (self.people, self.albums) = (people, albums)
            (self.importedBy, self.originApp, self.camera, self.hidden) = (importedBy, originApp, camera, hidden)
        }

        /// A video stays one, whichever file of it is read (`reading`).
        public var kind: FileKind { movie ? .video : screenshot ? .screenshot : .image }

        public var origin: Origin { Origin(screenshot: screenshot, importedBy: importedBy, app: originApp) }

        /// Photos' words as keyword search keeps them, one a line.
        public var text: String { words.joined(separator: "\n") }

        /// Where Photos says it was taken.
        public var location: Location? {
            guard let latitude, let longitude else { return nil }
            return Location(latitude: latitude, longitude: longitude, source: .photos, place: place)
        }
    }

    /// The stills of Photos' filmstrip of a video, in order, from the first (`Reading.stills`): the files of its folder
    /// (resources/derivatives/cvt/F/<uuid>/) named <uuid>_cvt_tNNNN.jpeg, NNNN from 0000 up. Photos keeps them for a
    /// video whose original is only in iCloud: 6.4 a video on average in a real library, 360 × 640, with no times.
    public static func filmstrip(startingAt first: String) -> [String] {
        let folder = (first as NSString).deletingLastPathComponent
        guard let uuid = asset(ofFile: first)?.uuid,
              let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return [] }
        let prefix = uuid + filmstripMark
        return names.filter { $0.hasPrefix(prefix) && $0.lowercased().hasSuffix(".jpeg") }.sorted()
            .map { (folder as NSString).appendingPathComponent($0) }
    }

    /// What follows the uuid in a filmstrip still's name, before its number (`filmstrip(startingAt:)`).
    static let filmstripMark = "_cvt_t"

    /// A person or pet someone named in Photos. Faces nobody named aren't listed: there's nothing to find them by.
    public struct Person: Codable, Sendable, Equatable {
        /// Photos' id for them: a rename in Photos keeps it, and two people of the same name have one each.
        public let uuid: String
        public let name: String

        public init(uuid: String, name: String) {
            (self.uuid, self.name) = (uuid, name)
        }
    }

    /// An album someone made in Photos, as osxphotos' `album_info` lists them: not smart albums, Photos' own
    /// collections ("Recents", "Favorites") or projects.
    public struct Album: Codable, Sendable, Equatable {
        /// Photos' id for it: a rename or a move to another folder keeps it.
        public let uuid: String
        public let title: String
        /// The names of the folders it's in, outermost first.
        public let folders: [String]

        public init(uuid: String, title: String, folders: [String] = []) {
            (self.uuid, self.title, self.folders) = (uuid, title, folders)
        }
    }

    /// What a library holds for DigUp, and what was left out of it and why (reason → assets); the people and pets
    /// named in it and its albums, which its assets refer to by uuid.
    public struct Listing: Codable, Sendable, Equatable {
        public var assets: [Asset]
        public var skipped: [String: Int]
        public var people: [Person]
        public var albums: [Album]

        public init(assets: [Asset], skipped: [String: Int] = [:], people: [Person] = [], albums: [Album] = []) {
            self.assets = assets
            self.skipped = skipped
            self.people = people
            self.albums = albums
        }
    }

    /// How a library is read: its path in, and whether what's hidden in Photos is listed too
    /// (`IndexOptions.includeHiddenPhotos`); its listing out. It throws when the library can't be read at all.
    public struct Reader: Sendable {
        public let list: @Sendable (_ library: String, _ hidden: Bool) throws -> Listing

        public init(list: @escaping @Sendable (_ library: String, _ hidden: Bool) throws -> Listing) {
            self.list = list
        }
    }

    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    // MARK: osxphotos

    /// The osxphotos program, where `InstalledPrograms` finds it: $DIGUP_OSXPHOTOS names one (empty: none). Nil where it
    /// isn't installed, and off the Mac.
    public static var osxphotos: String? { InstalledPrograms.path(of: "osxphotos", chosenBy: "DIGUP_OSXPHOTOS") }

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

    /// Where a library's last listing is kept in the index folder (`osxphotosReader`).
    public static func keptListing(of library: String, keptIn index: URL) -> URL {
        index.appendingPathComponent("photos").appendingPathComponent(keptName(of: library))
    }

    public static func lastListing(of library: String, keptIn index: URL) -> ListingSummary? {
        let file = keptListing(of: library, keptIn: index)
        guard let data = try? Data(contentsOf: file), let kept = try? JSONDecoder().decode(Kept.self, from: data),
              kept.library == library else { return nil }
        return ListingSummary(listedAt: Date(timeIntervalSince1970: kept.listedAt), assets: kept.listing.assets.count,
                              skipped: kept.listing.skipped)
    }

    /// The assets a library's last listing (kept in the index folder) says aren't hidden in Photos, by uuid: each one
    /// listed when it was listed without hidden items, else each one marked not hidden. None when no listing is kept.
    /// `digup mcp` lets AI apps see only these until hidden items are allowed: an asset the listing doesn't vouch for
    /// stays out, even while the index still has it (hidden items just left out of indexing, the sync that takes them
    /// out not done yet), as does each one of a listing with hidden items from before DigUp marked which they are (made
    /// again at the next sync, `Kept.isCurrent`).
    public static func visibleAssets(of library: String, keptIn index: URL) -> Set<String> {
        let file = keptListing(of: library, keptIn: index)
        guard let data = try? Data(contentsOf: file), let kept = try? JSONDecoder().decode(Kept.self, from: data),
              kept.library == library else { return [] }
        return Set(kept.listing.assets.filter { !kept.hidden || $0.hidden == false }.map(\.uuid))
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
        return Reader { library, hidden in try listing(of: library, hidden: hidden, program: program, keptIn: listings) }
    }

    /// The library's listing, with what's hidden in Photos or without (`hidden`): the one kept from before while it's
    /// current (`Kept.isCurrent`), else a new one.
    static func listing(of library: String, hidden: Bool, program: String, keptIn folder: URL?, now: Date = Date())
        throws -> Listing {
        // Looked at before osxphotos reads it, so that a change while it reads is caught by the next crawl.
        let state = State(of: library)
        let file = folder?.appendingPathComponent(keptName(of: library))
        if let file, let data = try? Data(contentsOf: file), let kept = try? JSONDecoder().decode(Kept.self, from: data),
           kept.isCurrent(library: library, hidden: hidden, state: state, now: now.timeIntervalSince1970) {
            return kept.listing
        }
        let listing = try run(program, library: library, hidden: hidden)
        if let file, let folder {
            let kept = Kept(library: library, hidden: hidden, listedAt: now.timeIntervalSince1970, state: state,
                            listing: listing)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? JSONEncoder().encode(kept).write(to: file, options: .atomic)
        }
        return listing
    }

    /// What a kept listing is checked against: the folders where pictures land (a new, edited or downloaded picture
    /// changes one of them, one level down; a video's new filmstrip changes one of cvt's) and the databases osxphotos
    /// reads: the catalog, and the search database that holds Photos' labels and places (search/psi.sqlite in
    /// libraries from macOS 13 to 26, search/leo.sqlite in macOS 27's, as seen 2026-10-21).
    struct State: Codable, Equatable {
        var pictures: String
        var database: String

        init(pictures: String, database: String) {
            self.pictures = pictures
            self.database = database
        }

        init(of library: String) {
            var pictures: [String] = []
            for folder in PhotosLibrary.pictureFolders + ["resources/derivatives/masters", "resources/derivatives/cvt"] {
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
        /// Whether what's hidden in Photos is in it (`IndexOptions.includeHiddenPhotos`): a listing made the other way
        /// is made again.
        var hidden: Bool
        var listedAt: Double
        var state: State
        var listing: Listing

        /// Made by this script, with what's hidden or without as asked, the pictures are as they were, and so are the
        /// databases, or the listing is younger than `listingLifetime`.
        func isCurrent(library: String, hidden: Bool, state: State, now: Double) -> Bool {
            let age = now - listedAt
            return version == Self.currentVersion && reader == PhotosLibrary.hash(PhotosLibrary.script)
                && self.library == library && self.hidden == hidden && self.state.pictures == state.pictures
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

    /// Runs osxphotos on the library (`script`), with what's hidden in Photos or without, for up to `timeout` seconds:
    /// macOS may first ask whether DigUp can see the photos (the read waits for the answer), and a big library takes
    /// osxphotos a while by itself.
    static func run(_ program: String, library: String, hidden: Bool, timeout: Double = 1800) throws -> Listing {
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
        process.arguments = ["run", code.path, library, output.path, hidden ? "include-hidden" : "skip-hidden"]
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

    /// What osxphotos runs (`osxphotos run list.py <library> <output> include-hidden|skip-hidden`): the listing, as
    /// JSON, written to <output>.
    static let script = #"""
        # DigUp's reader of a Photos library (Sources/DigUpKit/PhotosLibrary.swift):
        #   osxphotos run list.py <library> <output.json> include-hidden|skip-hidden
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


        def plain(value):
            """Photos wraps place names in direction marks ("\u2068Adelaide\u2069"): not part of the words."""
            return value.replace("\u2068", "").replace("\u2069", "").strip() if isinstance(value, str) else ""


        def named(name):
            """The name of a person or pet, or None for a face nobody named."""
            name = plain(name)
            return name if name and name != "_UNKNOWN_" else None


        def words(photo):
            found, seen = [], set()

            def add(values):
                for value in [values] if isinstance(values, str) else values or []:
                    value = plain(value)
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


        def place(photo):
            """Photos' name for where it was taken, or None."""
            info = quietly(lambda: photo.place)
            return (plain(quietly(lambda: info.name)) or None) if info else None


        def filmstrip(photo, root):
            """The stills of Photos' filmstrip of a video, in order: resources/derivatives/cvt/<the uuid's first
            character>/<uuid>/<uuid>_cvt_tNNNN.jpeg, NNNN from 0000 up. Photos keeps them for a video whose original is
            only in iCloud; osxphotos' path_derivatives doesn't list them."""
            folder = os.path.join(root, "resources", "derivatives", "cvt", photo.uuid[0], photo.uuid)
            try:
                names = os.listdir(folder)
            except OSError:
                return []
            mark = photo.uuid + "_cvt_t"
            return sorted(os.path.join(folder, name) for name in names
                          if name.startswith(mark) and name.lower().endswith(".jpeg"))


        def picture(photo, root):
            """The file that shows it as Photos does, and what it is of the asset (PhotosLibrary.Reading), or None, None
            when there's none on this Mac."""
            if photo.path_edited:
                return photo.path_edited, "edited"
            if photo.path:
                return photo.path, "original"
            if photo.ismovie:
                stills = filmstrip(photo, root)
                if stills:
                    return stills[0], "stills"
            # Largest first, and last Photos' small thumbnail (resources/derivatives/masters/F/<uuid>_4_5005_c.jpeg).
            for path in quietly(lambda: photo.path_derivatives):
                if path.lower().endswith(STILLS):
                    return path, "poster" if photo.ismovie else "preview"
            return None, None


        def imported_by(db):
            """How each asset came into the library, by uuid: the number Photos' catalog keeps for it
            (ZADDITIONALASSETATTRIBUTES.ZIMPORTEDBY, PhotosLibrary.Origin), read through osxphotos' own connection to the
            catalog. None for all of them where the catalog doesn't keep it (an older Photos)."""
            connection, cursor = db.get_db_connection()
            try:
                for assets in ("ZASSET", "ZGENERICASSET"):  # the table's name from macOS 11 on, and in macOS 10.15
                    try:
                        return dict(cursor.execute(
                            f"SELECT a.ZUUID, x.ZIMPORTEDBY FROM {assets} a "
                            "JOIN ZADDITIONALASSETATTRIBUTES x ON x.ZASSET = a.Z_PK").fetchall())
                    except Exception:
                        continue
                return {}
            finally:
                connection.close()


        def origin_app(photo):
            """The app that put it in the library, as Photos recorded it (its bundle id), or None."""
            app = quietly(lambda: photo.imported_by)  # (display name, bundle id)
            return (app[1] or None) if app else None


        def camera(photo):
            """The device that took it, from the EXIF Photos kept ("iPhone 15 Pro"), or None."""
            info = quietly(lambda: photo.exif_info)
            return (plain(quietly(lambda: info.camera_model)) or None) if info else None


        def main():
            library, output, hidden = sys.argv[1], sys.argv[2], sys.argv[3] == "include-hidden"
            db = osxphotos.PhotosDB(dbfile=library)
            root = os.path.realpath(library) + os.sep
            numbers = imported_by(db)
            assets, skipped = [], {}

            def skip(reason):
                skipped[reason] = skipped.get(reason, 0) + 1

            for photo in db.photos():  # not those in the trash, and of a burst only the shots picked
                if photo.hidden and not hidden:
                    skip("hidden in Photos")
                    continue
                if photo.shared:
                    skip("in a shared album")
                    continue
                if quietly(lambda: photo.syndicated) and not quietly(lambda: photo.saved_to_library):
                    skip("shared with you, not saved")
                    continue
                path, reading = (None, None) if photo.isreference else picture(photo, root)
                if photo.isreference or (path and not os.path.realpath(path).startswith(root)):
                    skip("kept outside the library")
                    continue
                if path is None:
                    skip("in iCloud, not downloaded")
                    continue
                assets.append({
                    "uuid": photo.uuid,
                    "path": os.path.realpath(path),
                    "reading": reading,
                    "movie": bool(photo.ismovie),
                    "screenshot": bool(quietly(lambda: photo.screenshot)),
                    "title": photo.title or photo.original_filename or "",
                    "date": photo.date.timestamp(),
                    "words": words(photo),
                    "favorite": bool(photo.favorite),
                    # None, None: Photos has no location for it (its catalog says -180, -180).
                    "latitude": photo.latitude,
                    "longitude": photo.longitude,
                    "place": place(photo),
                    "people": sorted({p.uuid for p in quietly(lambda: photo.person_info) if named(p.name)}),
                    # A shared album too, but a shared album's pictures are left out above.
                    "albums": sorted({a.uuid for a in quietly(lambda: photo.album_info)}),
                    "importedBy": numbers.get(photo.uuid),
                    "originApp": origin_app(photo),
                    "camera": camera(photo),
                    "hidden": bool(photo.hidden),
                })
            people = [{"uuid": p.uuid, "name": named(p.name)}
                      for p in quietly(lambda: db.person_info) if named(p.name)]
            # The albums someone made: not smart albums, Photos' own ("Recents", "Favorites"), projects or shared ones.
            albums = [{"uuid": a.uuid, "title": a.title or "", "folders": list(quietly(lambda: a.folder_names))}
                      for a in quietly(lambda: db.album_info)]
            with open(output + ".partial", "w", encoding="utf-8") as file:
                json.dump({"assets": assets, "skipped": skipped, "people": people, "albums": albums}, file,
                          ensure_ascii=False)
            os.replace(output + ".partial", output)


        main()
        """#
}
