import Foundation

/// A file as the index knows it.
public struct FileRecord: Sendable {
    public let id: Int64
    public let path: String
    public let kind: FileKind
    public let size: Int64
    public let mtime: Double
    public let inode: UInt64
    public let device: UInt64
    public let state: String
}

/// The on-disk index: one SQLite file with files, their segments (with fp16 vectors), and an FTS5 table.
///
/// Vectors live in the same database as everything else, so a crash can never leave them out of step with the
/// rows that describe them. At this scale (~20k vectors, ~30 MB) brute-force search over an in-memory copy is a
/// few milliseconds; no vector database needed.
public final class IndexStore {
    public let directory: URL
    public let db: Database
    static let schemaVersion: Int64 = 5

    /// Keyword search's tokenizer. Marks (M*) count as letters, so Bengali vowel signs and Arabic harakat stay inside
    /// their words: by default SQLite splits on them ("কলকাতায়" became "কলক", "ত", "য").
    static let tokenizer = "porter unicode61 remove_diacritics 2 categories 'L* N* Co M*'"
    /// Keyword search's table: words are matched in `body`, normalized (`SearchText`); `original` keeps the text as it's
    /// written when normalizing changed it (Arabic with hamza or harakat, Bengali with joiners), for showing it.
    static let ftsColumns = "name, body, original UNINDEXED, tokenize = \"\(tokenizer)\""

    /// When set, `pending`, `pendingCount` and `counts` see only files under these folders: the app's helper sets the
    /// folders that are connected right now, so files on an unplugged drive neither fail nor count as waiting.
    public var scope: [String]? {
        didSet {
            guard let scope else { (scopeSQL, scopeValues) = ("", []); return }
            let ranges = scope.flatMap(Self.pathRanges(under:))
            scopeSQL = ranges.isEmpty ? " AND 0"
                : " AND (" + ranges.map { _ in "(path >= ? AND path < ?)" }.joined(separator: " OR ") + ")"
            scopeValues = ranges.flatMap { [SQLValue.text($0.from), .text($0.to)] }
        }
    }
    private var scopeSQL = ""
    private var scopeValues: [SQLValue] = []

    /// The ranges of the UNIQUE path index that hold the files under `folder`. Paths are stored as a walk reports them,
    /// which isn't always how the folder is spelled here: `standardizedFileURL` says /var where the walk says
    /// /private/var, and decomposes a name with accents or Hangul that the disk keeps precomposed ("Café", Google
    /// Drive's "내 드라이브"). Swift's `==` takes those for the same folder; SQLite compares bytes. So: a range for the
    /// folder as given, and one for its real path when that's spelled differently.
    static func pathRanges(under folder: String) -> [(from: String, to: String)] {
        var spellings = [folder]
        let real = FolderSelection.realPath(folder)
        if !real.utf8.elementsEqual(folder.utf8) { spellings.append(real) }
        return spellings.map { path in
            let prefix = path.hasSuffix("/") ? path : path + "/"
            return (prefix, prefix + "\u{10FFFF}")
        }
    }

    /// The main index's file in the index folder.
    public static let mainFile = "index.sqlite"
    /// The code index (`IndexOptions.code`) is a file of its own beside it: code search never moves the rest (its
    /// meaning scale, its keyword results, the vectors search keeps in memory), and turning it off deletes one file.
    public static let codeFile = "code.sqlite"

    public let file: URL

    public init(directory: URL, file name: String = IndexStore.mainFile) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        file = directory.appendingPathComponent(name)
        db = try Database(path: file.path)
        try migrate()
        try migrateForkFacts()
    }

    /// Opens an index only to read it (`digup mcp`): nothing is created, migrated or written. An index that isn't
    /// there, or that the app hasn't brought up to this DigUp's schema yet (it does when it opens it), is refused, not
    /// changed.
    public init(readingOnly directory: URL, file name: String = IndexStore.mainFile) throws {
        self.directory = directory
        file = directory.appendingPathComponent(name)
        db = try Database(readingOnly: file.path)
        var version: Int64 = 0
        try db.query("PRAGMA user_version") { version = $0.int(0) }
        guard version == Self.schemaVersion, try forkFactsStepped() >= Self.forkFactsVersion else {
            throw Database.Failure(message: "\(file.path) isn't an index this DigUp can read as it is (open DigUp to "
                                   + "bring it up to date)")
        }
    }

    /// Bytes on disk: the database and its write-ahead log.
    public static func size(of file: URL) -> Int64 {
        [file.path, file.path + "-wal"].reduce(0) { total, path in
            total + ((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0)
        }
    }

    /// Schema changes ship as one migration each, and the layout below was designed to need as few as possible
    /// (every forced migration is paid for by every user).
    private func migrate() throws {
        var version: Int64 = 0
        try db.query("PRAGMA user_version") { version = $0.int(0) }
        guard version <= Self.schemaVersion else {
            throw Database.Failure(message: "this index was made by a newer DigUp (schema \(version))")
        }
        guard version < Self.schemaVersion else { return }
        // The app and its helper can open the index at the same moment: one migrates while the other waits for it (up
        // to a minute, not the usual 5 s), then sees it done.
        try db.execute("PRAGMA busy_timeout = 60000")
        defer { try? db.execute("PRAGMA busy_timeout = 5000") }
        try db.transaction {
            try db.query("PRAGMA user_version") { version = $0.int(0) }
            if version == 0 { try create() }
            // The fork's tables before upstream's steps, which read files again (`requeue`): that clears the fork's
            // rows of them too.
            try stepForkFacts()
            if version == 1 { try migrateKeywordSearch() }
            if (1...2).contains(version) { try migrateScreenshotText() }
            if (1...3).contains(version) { try migrateVectorNames() }
            if (1...4).contains(version) { try migrateLongFiles() }
        }
    }

    private func create() throws {
        try db.execute("""
            CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE files(
                id INTEGER PRIMARY KEY,
                path TEXT NOT NULL UNIQUE,
                kind TEXT NOT NULL,
                size INTEGER NOT NULL,
                mtime REAL NOT NULL,
                inode INTEGER NOT NULL,
                device INTEGER NOT NULL,
                state TEXT NOT NULL DEFAULT 'pending',   -- pending | done | partial | skipped | failed
                detail TEXT,                              -- why skipped/failed, or how far a long file has been read
                info TEXT,                                -- JSON: pixels, pages, duration, date taken; read_to/read_end
                indexed_at REAL
            );
            CREATE INDEX files_inode ON files(device, inode);
            CREATE INDEX files_state ON files(state, kind);
            CREATE TABLE segments(
                id INTEGER PRIMARY KEY,
                file INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
                kind TEXT NOT NULL,       -- SegmentKind
                modality TEXT NOT NULL,   -- Modality of the vector ('none' when there is no vector)
                loc REAL,                 -- PDF page number, or start second for audio/video
                loc_end REAL,
                excerpt TEXT,
                vec BLOB                  -- 768 × float16, L2-normalized
            );
            CREATE INDEX segments_file ON segments(file);
            CREATE VIRTUAL TABLE fts USING fts5(\(Self.ftsColumns));
            PRAGMA user_version = \(Self.schemaVersion);
            """)
    }

    /// Schema 1 → 2: keyword search with whole Bengali and Arabic words (`tokenizer`) over normalized text
    /// (`SearchText`). The words are rebuilt from what's stored, without reading any file. PDFs whose text layer came
    /// out garbled (`PageTextProblem`) are queued again, to be read as pictures or by OCR.
    private func migrateKeywordSearch() throws {
        try db.execute("CREATE VIRTUAL TABLE fts_new USING fts5(\(Self.ftsColumns))")
        // Row by row: an index can hold tens of megabytes of text, and the app may be the one migrating.
        try db.query("SELECT rowid, name, body FROM fts") { row in
            let body = row.text(2) ?? ""
            try db.run("INSERT INTO fts_new(rowid, name, body, original) VALUES(?, ?, ?, ?)",
                       [.int(row.int(0)), .text(SearchText.normalized(row.text(1) ?? ""))] + Self.keywordText(body))
        }
        var garbled = Set<Int64>()
        try db.query("""
            SELECT s.file, fts.body FROM fts JOIN segments s ON s.id = fts.rowid JOIN files f ON f.id = s.file
            WHERE f.kind = 'pdf' AND s.kind IN ('page', 'page_image')
            """) { row in
            if PageTextProblem.check(row.text(1) ?? "") != nil { garbled.insert(row.int(0)) }
        }
        try db.execute("DROP TABLE fts; ALTER TABLE fts_new RENAME TO fts; PRAGMA user_version = 2;")
        for file in garbled { try requeue(file) }
    }

    /// Schema 2 → 3: a screenshot's OCR text is for keyword search only, and its meaning comes from the picture. The
    /// text vectors made screenshots outrank better matches in the evals; they go, nothing is read again.
    private func migrateScreenshotText() throws {
        try db.execute("UPDATE segments SET vec = NULL, modality = 'none' WHERE kind = 'ocr'; PRAGMA user_version = 3;")
    }

    /// Schema 3 → 4: indexes name their vectors by a vector version, not by the llama.cpp build that made them, so a
    /// llama.cpp update that leaves the vectors alone keeps the index (`LlamaEmbedder.vectorVersion`). Every index so
    /// far comes from b11461, which made version 1. Nothing is embedded again.
    private func migrateVectorNames() throws {
        try db.execute("""
            UPDATE meta SET value = replace(value, ' llama.cpp-b11461-metal ', ' llama.cpp-vectors1 ')
            WHERE key IN ('fingerprint', 'vector_source');
            PRAGMA user_version = 4;
            """)
    }

    /// Schema 4 → 5: long files are finished after the first pass (`Indexer.finishLongFiles`), from where they stopped,
    /// which until now was always page 30 of a PDF over 50 pages (already `partial`) and chunk 40 of a document (`done`,
    /// with 40 chunks). Those documents become `partial`; how many chunks they have is guessed from their length until
    /// the later pass counts them. And text that's mostly digits loses its vectors (`SearchText.hasWords`), as it
    /// would if it were indexed now. Nothing is read or embedded here.
    private func migrateLongFiles() throws {
        var digits: [Int64] = []
        try db.query("""
            SELECT s.id, coalesce(fts.original, fts.body) FROM segments s JOIN fts ON fts.rowid = s.id
            WHERE s.kind IN ('page', 'chunk') AND s.vec IS NOT NULL
            """) { row in
            if !SearchText.hasWords(row.text(1) ?? "") { digits.append(row.int(0)) }
        }
        for id in digits { try db.run("UPDATE segments SET vec = NULL, modality = 'none' WHERE id = ?", [.int(id)]) }
        let limits = IndexOptions()
        try db.execute("""
            UPDATE files SET detail = 'read to page 30', info = json_set(info, '$.read_to', '30', '$.read_end',
                CAST(MIN(CAST(json_extract(info, '$.pages') AS INTEGER), \(limits.maxPages)) AS TEXT))
            WHERE kind = 'pdf' AND state = 'partial' AND info IS NOT NULL;
            UPDATE files SET state = 'partial', detail = 'read to chunk 40', info = json_set(info, '$.read_to', '40',
                '$.read_end', CAST(MIN(MAX(41, (CAST(json_extract(info, '$.chars') AS INTEGER) + 1599) / 1600),
                                       \(limits.maxChunks)) AS TEXT))
            WHERE kind = 'doc' AND state = 'done' AND json_extract(info, '$.chunks') = '40';
            PRAGMA user_version = 5;
            """)
    }

    // MARK: The fork's tables

    /// The fork's own tables, for what Photos says about a library's files and where files were taken
    /// (`createForkFacts`) and for the faces in pictures (`createFaces`), are versioned apart from upstream's schema:
    /// `meta` "fork_photos_facts" says how many of the fork's steps an index has had, each run once and in order, and
    /// `PRAGMA user_version` stays upstream's.
    /// Upstream owns those numbers: a fork's 6 would claim upstream's migration 6 had run when it hadn't. An upstream
    /// DigUp still opens the index; it doesn't read Photos libraries, so it removes their files, and the foreign keys
    /// take their facts with them. An index a later fork stepped further (a column added) is left as it is.
    static let forkFactsKey = "fork_photos_facts"
    static let forkFactsVersion = 3

    /// An index already at upstream's current schema that hasn't had the fork's steps (made by upstream's DigUp, or by
    /// the fork before these tables): `migrate` gives an older one theirs, before upstream's own steps.
    private func migrateForkFacts() throws {
        guard try forkFactsStepped() < Self.forkFactsVersion else { return }
        // Opened by the app and its helper at once: as `migrate`.
        try db.execute("PRAGMA busy_timeout = 60000")
        defer { try? db.execute("PRAGMA busy_timeout = 5000") }
        try db.transaction { try stepForkFacts() }
    }

    private func forkFactsStepped() throws -> Int { Int(try meta(Self.forkFactsKey) ?? "") ?? 0 }

    /// The fork's steps the index hasn't had, in order (in a transaction).
    private func stepForkFacts() throws {
        let from = try forkFactsStepped()
        guard from < Self.forkFactsVersion else { return }
        if from < 1 { try createForkFacts() }
        if from < 2 { try recreatePhotosAssets() }
        if from < 3 { try createFaces() }
        try setMeta(Self.forkFactsKey, "\(Self.forkFactsVersion)")
    }

    /// Fork step 1. Every row is rebuilt from Photos (the sync, from the listing) or from the file (the indexer)
    /// whenever it's lost: nothing to fill in here. "File" is a row of `files`; a library's file is one Photos asset.
    /// - `locations`: where a file was taken, one row at most (`Location`); `source` is 'photos' exactly when the file
    ///   is in a Photos library. The sync writes those; the indexer writes the others when it reads a file, and
    ///   reading it again drops them first, as it does its segments.
    /// - `photos_people`, `photos_albums`: a library's named people and pets and its albums, each under Photos' uuid
    ///   (a rename in Photos changes the row, not its id), with their files (`photos_person_files`,
    ///   `photos_album_files`). One no file is linked to is deleted at the end of a sync.
    /// - `photos_assets`: Photos' flags of a library's file; one row each (its columns since step 2).
    private func createForkFacts() throws {
        try db.execute("""
            CREATE TABLE IF NOT EXISTS locations(
                file INTEGER PRIMARY KEY REFERENCES files(id) ON DELETE CASCADE,
                latitude REAL NOT NULL CHECK (latitude BETWEEN -90 AND 90),     -- WGS 84 degrees
                longitude REAL NOT NULL CHECK (longitude BETWEEN -180 AND 180),
                source TEXT NOT NULL CHECK (source IN ('photos', 'exif', 'quicktime')),
                place TEXT                                                       -- Photos' name for it, for showing
            );
            CREATE TABLE IF NOT EXISTS photos_people(
                id INTEGER PRIMARY KEY,
                library TEXT NOT NULL,        -- the library's path, as the index spells it
                uuid TEXT NOT NULL,           -- Photos' id for the person or pet
                name TEXT NOT NULL CHECK (name != ''),
                UNIQUE (library, uuid)
            );
            CREATE TABLE IF NOT EXISTS photos_person_files(
                person INTEGER NOT NULL REFERENCES photos_people(id) ON DELETE CASCADE,
                file INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
                PRIMARY KEY (person, file)
            ) WITHOUT ROWID;
            CREATE INDEX IF NOT EXISTS photos_person_files_file ON photos_person_files(file);
            CREATE TABLE IF NOT EXISTS photos_albums(
                id INTEGER PRIMARY KEY,
                library TEXT NOT NULL,
                uuid TEXT NOT NULL,           -- Photos' id for the album
                title TEXT NOT NULL,
                folders TEXT NOT NULL DEFAULT '[]',   -- JSON array of the folder names above it, outermost first
                UNIQUE (library, uuid)
            );
            CREATE TABLE IF NOT EXISTS photos_album_files(
                album INTEGER NOT NULL REFERENCES photos_albums(id) ON DELETE CASCADE,
                file INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
                PRIMARY KEY (album, file)
            ) WITHOUT ROWID;
            CREATE INDEX IF NOT EXISTS photos_album_files_file ON photos_album_files(file);
            CREATE TABLE IF NOT EXISTS photos_assets(
                file INTEGER PRIMARY KEY REFERENCES files(id) ON DELETE CASCADE,
                favorite INTEGER NOT NULL CHECK (favorite IN (0, 1))
            );
            """)
    }

    /// Fork step 2: `photos_assets` says what DigUp read of each asset, how it came into its library and the device
    /// that took it. Every row is the sync's, made from the listing, so the table is made again rather than given
    /// columns with a default that would be a made-up fact: the first sync after this writes each library file's row
    /// again (`photosFacts` counts a file without one as having no facts).
    /// - `reading` (`PhotosLibrary.Reading`): the file read, as the listing chose it. A video in iCloud is read from
    ///   Photos' stills of it, or a poster still, and stays a video (`files.kind`).
    /// - `origin` (`PhotosLibrary.Origin`), from what Photos' catalog records; `origin_app` the app that put it in the
    ///   library, by its bundle id, NULL when Photos recorded none.
    /// - `camera`: the device that took it, from the EXIF Photos kept ("iPhone 15 Pro"), NULL when there's none.
    private func recreatePhotosAssets() throws {
        try db.execute("""
            DROP TABLE IF EXISTS photos_assets;
            CREATE TABLE photos_assets(
                file INTEGER PRIMARY KEY REFERENCES files(id) ON DELETE CASCADE,
                favorite INTEGER NOT NULL CHECK (favorite IN (0, 1)),
                reading TEXT NOT NULL CHECK (reading IN ('original', 'edited', 'preview', 'stills', 'poster')),
                origin TEXT NOT NULL CHECK (origin IN ('camera', 'screenshot', 'saved', 'imported', 'unknown')),
                origin_app TEXT,   -- the app that put it in the library, as Photos recorded it (bundle id); NULL when it didn't
                camera TEXT        -- the device that took it, from the EXIF Photos kept ("iPhone 15 Pro"); NULL when none
            );
            """)
    }

    /// Fork step 3 (approved 2026-10-22, "faces outside Photos"): the faces in pictures, to find the people named in
    /// Photos in pictures outside it (`Faces`).
    /// - `faces`: one row a face DigUp keeps, in the picture segment it's in (an `image` segment, for now): in a Photos
    ///   library the faces Photos named, with their person (`photos_people`), and outside every face found, with none.
    ///   The box is in the picture as it's shown, in fractions from its top-left corner; `print` is the recognizer's
    ///   description of the face, whose recognizer is `meta` "fork_faces_model" (`adoptFaceRecognizer`). Reading a
    ///   picture again replaces its segments, and the foreign key takes their faces with them.
    /// - `face_matches`: one row a face outside Photos whose nearest named face is at least `Faces.matchFloor` alike, or
    ///   that you said is someone (`confirmed`, from `face-corrections.json`: `FaceCorrections`): that face's person,
    ///   and how alike. DigUp's guess, apart from Photos' word (`faces.person`), and made again rather than edited
    ///   (`matchFaces`, `rebuildFaceMatches`).
    /// Indexing writes both when it reads a picture; an index made before this gets its faces once, from the faces
    /// pass (`Indexer.readFaces`).
    private func createFaces() throws {
        try db.execute("""
            CREATE TABLE IF NOT EXISTS faces(
                id INTEGER PRIMARY KEY,
                segment INTEGER NOT NULL REFERENCES segments(id) ON DELETE CASCADE,  -- the picture: an image segment
                x REAL NOT NULL CHECK (x BETWEEN 0 AND 1),           -- the box in the upright picture, as fractions of its
                y REAL NOT NULL CHECK (y BETWEEN 0 AND 1),           -- width and height, from the top-left corner
                width REAL NOT NULL CHECK (width > 0 AND x + width <= 1.0001),
                height REAL NOT NULL CHECK (height > 0 AND y + height <= 1.0001),
                print BLOB NOT NULL,                                 -- the recognizer's description of the face
                person INTEGER REFERENCES photos_people(id) ON DELETE CASCADE   -- who Photos says it is; NULL outside Photos
            );
            CREATE INDEX IF NOT EXISTS faces_segment ON faces(segment);
            CREATE INDEX IF NOT EXISTS faces_person ON faces(person);
            CREATE TABLE IF NOT EXISTS face_matches(
                face INTEGER PRIMARY KEY REFERENCES faces(id) ON DELETE CASCADE,
                person INTEGER NOT NULL REFERENCES photos_people(id) ON DELETE CASCADE,
                similarity REAL NOT NULL CHECK (similarity BETWEEN -1 AND 1),
                confirmed INTEGER NOT NULL DEFAULT 0 CHECK (confirmed IN (0, 1))   -- 1: you said so (FaceCorrections)
            );
            """)
    }

    // MARK: Meta

    public func meta(_ key: String) throws -> String? {
        var value: String?
        try db.query("SELECT value FROM meta WHERE key = ?", [.text(key)]) { value = $0.text(0) }
        return value
    }

    public func setMeta(_ key: String, _ value: String?) throws {
        if let value {
            try db.run("INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                       [.text(key), .text(value)])
        } else {
            try db.run("DELETE FROM meta WHERE key = ?", [.text(key)])
        }
    }

    // MARK: Files

    static let fileColumns = "id, path, kind, size, mtime, inode, device, state"

    /// `fileColumns` of the files table as `alias` (in a join, where segments has an id and a kind too).
    static func fileColumns(of alias: String) -> String {
        fileColumns.split(separator: ",").map { "\(alias).\($0.trimmingCharacters(in: .whitespaces))" }
            .joined(separator: ", ")
    }

    static func record(_ row: Statement) -> FileRecord {
        FileRecord(id: row.int(0), path: row.text(1) ?? "", kind: FileKind(rawValue: row.text(2) ?? "") ?? .doc,
                   size: row.int(3), mtime: row.double(4), inode: UInt64(bitPattern: row.int(5)),
                   device: UInt64(bitPattern: row.int(6)), state: row.text(7) ?? "pending")
    }

    /// Every file under one of `roots`.
    public func files(under roots: [String]) throws -> [FileRecord] {
        var out: [FileRecord] = []
        var seen = Set<Int64>()   // each file once, also where two spellings of a folder meet
        // A folder inside another one listed is already covered.
        for root in roots where !roots.contains(where: { FolderSelection.isInside(root, $0) }) {
            for range in Self.pathRanges(under: root) {
                try db.query("SELECT \(Self.fileColumns) FROM files WHERE path >= ? AND path < ?",
                             [.text(range.from), .text(range.to)]) { row in
                    let record = Self.record(row)
                    if seen.insert(record.id).inserted { out.append(record) }
                }
            }
        }
        return out
    }

    /// The indexed file at `path` when the filter keeps it (`digup mcp`: one an AI app may see), else nil, as for a
    /// file the index doesn't have.
    public func file(at path: String, keptBy filter: SearchFilter) throws -> FileRecord? {
        let kept = filter.query
        var found: FileRecord?
        try db.query("SELECT \(Self.fileColumns) FROM files WHERE path = ?" + (kept.map { " AND id IN (\($0.sql))" } ?? ""),
                     [.text(path)] + (kept?.values ?? [])) { found = Self.record($0) }
        return found
    }

    /// One part of a file's words as indexing read them: a page, a passage, the text in a picture, what Photos knows
    /// about it, a stretch of code.
    public struct Words: Sendable, Equatable {
        public let segment: SegmentKind
        /// The page, the passage's number, or a stretch of code's first line (or cell); nil for a picture's text and
        /// Photos' words.
        public let loc: Double?
        public let locEnd: Double?
        public let text: String
    }

    /// The segments that hold a file's words, as an SQL list.
    private static let wordSegments = [SegmentKind.page, .pageImage, .chunk, .ocr, .photosInfo, .lines, .cells]
        .map { "'\($0.rawValue)'" }.joined(separator: ",")

    /// The words read from the file at `path`, in order, when the filter keeps it (`digup mcp`'s `read_text`); nil for
    /// a file the index doesn't have or the filter leaves out.
    public func words(of path: String, keptBy filter: SearchFilter) throws -> [Words]? {
        guard let file = try file(at: path, keptBy: filter) else { return nil }
        var words: [Words] = []
        try db.query("""
            SELECT s.kind, s.loc, s.loc_end, coalesce(fts.original, fts.body) FROM segments s JOIN fts ON fts.rowid = s.id
            WHERE s.file = ? AND s.kind IN (\(Self.wordSegments))
            ORDER BY s.kind != '\(SegmentKind.photosInfo.rawValue)', s.loc IS NOT NULL, s.loc, s.id
            """, [.int(file.id)]) { row in
            guard let segment = SegmentKind(rawValue: row.text(0) ?? ""), let text = row.text(3), !text.isEmpty else {
                return
            }
            // Photos' words keep the date taken as their loc: not a place in the file.
            let placed = segment != .photosInfo
            words.append(Words(segment: segment, loc: placed && !row.isNull(1) ? row.double(1) : nil,
                               locEnd: placed && !row.isNull(2) ? row.double(2) : nil, text: text))
        }
        return words
    }

    /// The indexed files a filter keeps, by kind and state ("done", "pending"…): what `digup mcp` says of the index,
    /// only what AI apps may see.
    public func counts(keeping filter: SearchFilter) throws -> [FileKind: [String: Int]] {
        let kept = filter.query
        var counts: [FileKind: [String: Int]] = [:]
        try db.query("SELECT kind, state, COUNT(*) FROM files" + (kept.map { " WHERE id IN (\($0.sql))" } ?? "")
                     + " GROUP BY kind, state", kept?.values ?? []) { row in
            guard let kind = FileKind(rawValue: row.text(0) ?? "") else { return }
            counts[kind, default: [:]][row.text(1) ?? "", default: 0] += Int(row.int(2))
        }
        return counts
    }

    /// Adds a file (pending) and returns its id.
    @discardableResult
    public func insert(_ file: Candidate) throws -> Int64 {
        try db.run("INSERT INTO files(path, kind, size, mtime, inode, device) VALUES(?, ?, ?, ?, ?, ?)",
                   [.text(file.path), .text(file.kind.rawValue), .int(file.size), .double(file.mtime),
                    .int(Int64(bitPattern: file.inode)), .int(Int64(bitPattern: file.device))])
        let id = db.lastInsertID
        try addNameRow(file: id, path: file.path)
        return id
    }

    /// The file changed on disk: drop what was extracted from it and queue it again.
    public func requeue(_ id: Int64, as file: Candidate) throws {
        try deleteSegments(of: id, keepingCrawled: true)
        try db.run("""
            UPDATE files SET kind = ?, size = ?, mtime = ?, inode = ?, device = ?, state = 'pending', detail = NULL,
                info = NULL, indexed_at = NULL WHERE id = ?
            """, [.text(file.kind.rawValue), .int(file.size), .double(file.mtime), .int(Int64(bitPattern: file.inode)),
                  .int(Int64(bitPattern: file.device)), .int(id)])
    }

    /// Extract and embed the file again, as it is (after a better way to read it arrived).
    func requeue(_ id: Int64) throws {
        try deleteSegments(of: id, keepingCrawled: true)
        try db.run("UPDATE files SET state = 'pending', detail = NULL, info = NULL, indexed_at = NULL WHERE id = ?",
                   [.int(id)])
    }

    /// Same inode, size and date at a new path: a move or rename. Only the path changes; nothing is re-embedded.
    /// (Screenshot tools move screenshots into project folders all the time.)
    public func move(_ id: Int64, to path: String) throws {
        try db.run("UPDATE files SET path = ? WHERE id = ?", [.text(path), .int(id)])
        try db.run("""
            UPDATE fts SET name = ?, body = ? WHERE rowid IN (SELECT id FROM segments WHERE file = ? AND kind = 'name')
            """, [.text(SearchText.normalized(Self.nameText(path))), .text(SearchText.normalized(Self.folderText(path))),
                  .int(id)])
    }

    public func delete(_ id: Int64) throws {
        try db.run("DELETE FROM fts WHERE rowid IN (SELECT id FROM segments WHERE file = ?)", [.int(id)])
        try db.run("DELETE FROM files WHERE id = ?", [.int(id)])
    }

    /// Removes every file that isn't under one of `roots` (folders taken out of the app). Returns how many went.
    @discardableResult
    public func prune(keepingUnder roots: [String]) throws -> Int {
        let prefixes = roots.flatMap { Self.pathRanges(under: $0).map(\.from) }   // a folder under /var: /private/var too
        var gone: [Int64] = []
        try db.query("SELECT id, path FROM files") { row in
            let path = row.text(1) ?? ""
            if !prefixes.contains(where: { path.hasPrefix($0) }) { gone.append(row.int(0)) }
        }
        guard !gone.isEmpty else { return 0 }
        try db.transaction {
            for id in gone { try delete(id) }
        }
        return gone.count
    }

    /// Queues every file again and forgets the fingerprint (after the model or settings changed).
    public func resetAll() throws {
        try db.transaction {
            try db.run("DELETE FROM fts WHERE rowid IN (SELECT id FROM segments WHERE kind NOT IN \(Self.crawlKinds))")
            try db.run("DELETE FROM segments WHERE kind NOT IN \(Self.crawlKinds)")
            try db.run("DELETE FROM locations WHERE NOT \(Self.crawlLocation)")
            try db.run("UPDATE files SET state = 'pending', detail = NULL, info = NULL, indexed_at = NULL")
            try setMeta("fingerprint", nil)
        }
    }

    /// Files waiting to be embedded, in indexing order; `only` narrows it to some files (just-added ones).
    public func pending(limit: Int?, only ids: Set<Int64>? = nil) throws -> [FileRecord] {
        var out: [FileRecord] = []
        if let ids, ids.isEmpty { return out }
        let filter = ids.map { " AND id IN (\($0.map(String.init).joined(separator: ",")))" } ?? ""
        try db.query("""
            SELECT \(Self.fileColumns) FROM files WHERE state = 'pending'\(filter)\(scopeSQL)
            ORDER BY \(FileKind.indexingOrderSQL), mtime DESC LIMIT ?
            """, scopeValues + [.int(Int64(limit ?? -1))]) { out.append(Self.record($0)) }
        return out
    }

    public func pendingCount() throws -> Int {
        var count = 0
        try db.query("SELECT COUNT(*) FROM files WHERE state = 'pending'\(scopeSQL)", scopeValues) {
            count = Int($0.int(0))
        }
        return count
    }

    /// Long files with pages or chunks still to read after their first step, in indexing order (`pending`'s).
    public func unfinished() throws -> [FileRecord] {
        var out: [FileRecord] = []
        try db.query("""
            SELECT \(Self.fileColumns) FROM files WHERE state = 'partial'\(scopeSQL)
            ORDER BY \(FileKind.indexingOrderSQL), mtime DESC
            """, scopeValues) { out.append(Self.record($0)) }
        return out
    }

    /// How many long files are unfinished, and how many of their pages and chunks are left to read.
    public func unfinishedCount() throws -> (files: Int, left: Int) {
        var count = (files: 0, left: 0)
        try db.query("""
            SELECT COUNT(*), SUM(MAX(0, CAST(json_extract(info, '$.read_end') AS INTEGER)
                                      - CAST(json_extract(info, '$.read_to') AS INTEGER)))
            FROM files WHERE state = 'partial'\(scopeSQL)
            """, scopeValues) { count = (Int($0.int(0)), Int($0.int(1))) }
        return count
    }

    /// What indexing learned about a file (`finish`'s `info`).
    public func info(of id: Int64) throws -> [String: String] {
        var info: [String: String] = [:]
        try db.query("SELECT info FROM files WHERE id = ?", [.int(id)]) { row in
            if let json = row.text(0)?.data(using: .utf8) {
                info = (try? JSONSerialization.jsonObject(with: json) as? [String: String]) ?? [:]
            }
        }
        return info
    }

    /// The last page or chunk stored for a file (where a long file's reading got to, when its info doesn't say).
    func lastPlace(of id: Int64) throws -> Int? {
        var last: Int?
        try db.query("SELECT MAX(loc) FROM segments WHERE file = ? AND kind IN ('page', 'page_image', 'chunk')",
                     [.int(id)]) { last = $0.isNull(0) ? nil : Int($0.double(0)) }
        return last
    }

    public func finish(_ id: Int64, state: String, detail: String? = nil, info: [String: String] = [:]) throws {
        let json = info.isEmpty ? nil : (try? JSONSerialization.data(withJSONObject: info, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) }
        try db.run("UPDATE files SET state = ?, detail = ?, info = ?, indexed_at = ? WHERE id = ?",
                   [.text(state), .optional(detail), .optional(json), .double(Date().timeIntervalSince1970), .int(id)])
    }

    /// Files read once more because DigUp reads them better now, each kind once per index (the schema stays as it was,
    /// so an older DigUp still opens the index): PDFs with pages read as pictures, whose words come from OCR now
    /// (`meta` "scans_ocr"), pictures that couldn't be read at all, like SVGs, which AppKit draws now
    /// ("pictures_drawn"), and GIFs read before an animated one's later frames were read too (`animationFrames`), each
    /// read again unless it has frames already ("gifs_framed"; a GIF that isn't animated is read again once as well, as
    /// telling them apart would mean reading every one). Only where this machine does each. Returns how many files.
    @discardableResult
    public func readAgainOnce() throws -> Int {
        var files = Set<Int64>(), flags: [String] = []
        if OCR.isAvailable, try meta("scans_ocr") == nil {
            try db.query("SELECT DISTINCT file FROM segments WHERE kind = 'page_image'") { files.insert($0.int(0)) }
            flags.append("scans_ocr")
        }
        if ImageExtractor.drawsVectorPictures, try meta("pictures_drawn") == nil {
            try db.query("SELECT id FROM files WHERE kind = 'image' AND state = 'skipped' AND detail = ?",
                         [.text(ExtractError.tooSmall(0, 0).description)]) { files.insert($0.int(0)) }
            flags.append("pictures_drawn")
        }
        if ImageExtractor.readsAnimations, try meta("gifs_framed") == nil {
            try db.query("""
                SELECT id FROM files WHERE kind = 'image' AND state = 'done' AND lower(path) LIKE '%.gif'
                AND id NOT IN (SELECT file FROM segments WHERE kind = '\(SegmentKind.frame.rawValue)')
                """) { files.insert($0.int(0)) }
            flags.append("gifs_framed")
        }
        guard !flags.isEmpty else { return 0 }
        try db.transaction {
            for file in files { try requeue(file) }
            for flag in flags { try setMeta(flag, "1") }
        }
        return files.count
    }

    /// `meta` "locations_read": "1" once every picture and video read before DigUp kept locations has had its look
    /// (`locateOnce`), else the ids of the ones still waiting for it, as a JSON array.
    static let locationsReadKey = "locations_read"
    static let locationsAllRead = "1"

    /// Pictures and videos read before DigUp kept where they were taken get it once per index, from their metadata
    /// alone: a picture's GPS tags, a video's location, milliseconds a file, and nothing read for the model again. Not
    /// a Photos library's files, whose location is Photos' (the sync's). A file that's away now (gone, on a drive
    /// that's unplugged, or in the cloud, where reading it would download it) waits for a later call
    /// (`locationsReadKey`), which looks at the waiting files alone; one whose row went, or that was read again since
    /// (which reads its location), stops waiting. Only where this machine reads locations. Returns how many files got
    /// one.
    @discardableResult
    public func locateOnce() throws -> Int {
        var kinds: [FileKind] = []
        if ImageExtractor.readsLocations { kinds += [.image, .screenshot] }
        if VideoExtractor.readsLocations { kinds.append(.video) }
        guard !kinds.isEmpty else { return 0 }
        let waiting = try meta(Self.locationsReadKey)   // nil: the first look, at every file
        guard waiting != Self.locationsAllRead else { return 0 }
        let onlyWaiting = waiting == nil ? "" : " AND id IN (SELECT value FROM json_each(?))"
        var files: [(id: Int64, path: String, kind: FileKind)] = []
        try db.query("""
            SELECT id, path, kind FROM files WHERE state = 'done' AND kind IN (\(Self.sqlList(kinds)))
            AND id NOT IN (SELECT file FROM locations)\(onlyWaiting)
            """, waiting.map { [.text($0)] } ?? []) { row in
            let path = row.text(1) ?? ""
            guard PhotosLibrary.library(containing: path) == nil, let kind = FileKind(rawValue: row.text(2) ?? "")
            else { return }
            files.append((row.int(0), path, kind))
        }
        // Every file looked at before anything is written: the index isn't held while they're read.
        var found: [(file: Int64, location: Location)] = [], away: [Int64] = []
        for file in files {
            guard let info = FileSystem.info(of: file.path), info.isRegular, !info.dataless else {
                away.append(file.id)
                continue
            }
            let url = URL(fileURLWithPath: file.path)
            let location = autoreleasepool {
                file.kind == .video ? VideoExtractor.location(of: url) : ImageExtractor.location(of: url)
            }
            if let location { found.append((file.id, location)) }
        }
        try db.transaction {
            for (file, location) in found { try setLocation(location, of: file) }
            try setMeta(Self.locationsReadKey, away.isEmpty ? Self.locationsAllRead
                        : String(decoding: try JSONEncoder().encode(away), as: UTF8.self))
        }
        return found.count
    }

    /// Kinds as an SQL list ("'image','video'").
    static func sqlList(_ kinds: some Sequence<FileKind>) -> String {
        kinds.map { "'\($0.rawValue)'" }.joined(separator: ",")
    }

    /// A file the indexing helper had to stop on (reading it ran away): it isn't read again until it changes. A long
    /// file that was being finished keeps what was read of it. False when no file has that path.
    @discardableResult
    public func markStopped(_ path: String, why: String) throws -> Bool {
        var found: (id: Int64, state: String)?
        try db.query("SELECT id, state FROM files WHERE path = ?", [.text(path)]) { found = ($0.int(0), $0.text(1) ?? "") }
        guard let found else { return false }
        if found.state == "partial" {
            try finish(found.id, state: "done", detail: "The rest couldn't be read: it \(why)")
        } else {
            try finish(found.id, state: "failed", detail: "It \(why)")
        }
        return true
    }

    // MARK: Segments

    /// Adds a segment; `text` goes into keyword search (normalized, see `SearchText`), `vector` into meaning search.
    /// Returns its id.
    @discardableResult
    public func addSegment(file: Int64, kind: SegmentKind, modality: Modality, loc: Double? = nil, locEnd: Double? = nil,
                           excerpt: String? = nil, text: String? = nil, vector: [Float]? = nil) throws -> Int64 {
        try db.run("INSERT INTO segments(file, kind, modality, loc, loc_end, excerpt, vec) VALUES(?, ?, ?, ?, ?, ?, ?)",
                   [.int(file), .text(kind.rawValue), .text(vector == nil ? Modality.none.rawValue : modality.rawValue),
                    .optional(loc), .optional(locEnd), .optional(excerpt),
                    vector.map { .blob(Vectors.half($0)) } ?? .null])
        let id = db.lastInsertID
        if let text, !text.isEmpty {
            try db.run("INSERT INTO fts(rowid, name, body, original) VALUES(?, '', ?, ?)",
                       [.int(id)] + Self.keywordText(text))
        }
        return id
    }

    /// `body` and `original` for keyword search: the normalized text, and the text as written if that differs.
    static func keywordText(_ text: String) -> [SQLValue] {
        let normalized = SearchText.normalized(text)
        return [.text(normalized), normalized == text ? .null : .text(text)]
    }

    private func addNameRow(file: Int64, path: String) throws {
        try db.run("INSERT INTO segments(file, kind, modality) VALUES(?, 'name', 'none')", [.int(file)])
        try db.run("INSERT INTO fts(rowid, name, body) VALUES(?, ?, ?)",
                   [.int(db.lastInsertID), .text(SearchText.normalized(Self.nameText(path))),
                    .text(SearchText.normalized(Self.folderText(path)))])
    }

    /// The segments the crawl writes: the name row, and what Photos says about a Photos library's picture. Reading
    /// the file again (it changed, or the model did) keeps them.
    static let crawlKinds = "('\(SegmentKind.name.rawValue)', '\(SegmentKind.photosInfo.rawValue)')"

    /// The locations the crawl writes: Photos', from the listing. The others come from reading the file, and go when
    /// it's read again, as its segments do.
    static let crawlLocation = "source = '\(Location.Source.photos.rawValue)'"

    private func deleteSegments(of file: Int64, keepingCrawled: Bool) throws {
        let filter = keepingCrawled ? "AND kind NOT IN \(Self.crawlKinds)" : ""
        try db.run("DELETE FROM fts WHERE rowid IN (SELECT id FROM segments WHERE file = ? \(filter))", [.int(file)])
        try db.run("DELETE FROM segments WHERE file = ? \(filter)", [.int(file)])
        let located = keepingCrawled ? "AND NOT \(Self.crawlLocation)" : ""
        try db.run("DELETE FROM locations WHERE file = ? \(located)", [.int(file)])
    }

    /// "Screenshot 2026-10-01 at 9.41.07 PM.png" → searchable words. A Photos library's file is named for its asset's
    /// uuid, which says nothing: its name in Photos is among what Photos says about it (`photosInfo`).
    static func nameText(_ path: String) -> String {
        PhotosLibrary.library(containing: path) == nil ? (path as NSString).lastPathComponent : ""
    }

    /// The folders a file sits in, relative to the home folder ("Downloads Invoices"), as low-weight keywords. For a
    /// Photos library's file, the folders down to the library and its name ("Pictures Photos Library"), not the
    /// library's own folders (originals, resources, derivatives).
    static func folderText(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var folder = PhotosLibrary.library(containing: path).map { ($0 as NSString).deletingPathExtension }
            ?? (path as NSString).deletingLastPathComponent
        if folder.hasPrefix(home) { folder = String(folder.dropFirst(home.count)) }
        return folder.split(separator: "/").joined(separator: " ")
    }

    // MARK: Photos

    /// What Photos says about a file from a Photos library: its words, title and date (its `photosInfo` segment),
    /// whether it's a favorite, what DigUp read of it, how it came into the library and the device that took it
    /// (`photos_assets`), where it was taken (its `photos` location), and who is in it and the albums it's in, as their
    /// rows of the file's library (`photos_people`, `photos_albums`). Rows, not Photos' uuids: a library renamed or
    /// moved is a new library to the index (its people and albums are spelled with its path), so its files are linked
    /// to its own rows again, and the old library's go.
    public struct PhotosFacts: Equatable, Sendable {
        public var title: String
        public var date: Double
        public var text: String
        public var favorite: Bool
        public var reading: PhotosLibrary.Reading
        public var origin: PhotosLibrary.Origin
        public var originApp: String?
        public var camera: String?
        public var location: Location?
        public var people: Set<Int64>
        public var albums: Set<Int64>

        /// An asset's facts, with its people and albums as the rows of its library (`setPhotosPeople`,
        /// `setPhotosAlbums`, by uuid): one the library's listing doesn't name has none, and isn't linked.
        public init(_ asset: PhotosLibrary.Asset, people: [String: Int64], albums: [String: Int64]) {
            (title, date, text) = (asset.title, asset.date, asset.text)
            (favorite, reading, origin, originApp, camera) = (asset.favorite, asset.reading, asset.origin,
                                                              asset.originApp, asset.camera)
            location = asset.location
            self.people = Set(asset.people.compactMap { people[$0] })
            self.albums = Set(asset.albums.compactMap { albums[$0] })
        }

        init(title: String, date: Double, text: String, favorite: Bool, reading: PhotosLibrary.Reading,
             origin: PhotosLibrary.Origin, originApp: String?, camera: String?, location: Location? = nil,
             people: Set<Int64> = [], albums: Set<Int64> = []) {
            (self.title, self.date, self.text, self.favorite) = (title, date, text, favorite)
            (self.reading, self.origin, self.originApp, self.camera) = (reading, origin, originApp, camera)
            (self.location, self.people, self.albums) = (location, people, albums)
        }

        /// What its `photos_assets` row holds.
        var assetRow: (Bool, PhotosLibrary.Reading, PhotosLibrary.Origin, String?, String?) {
            (favorite, reading, origin, originApp, camera)
        }
    }

    /// Every library file's Photos facts, by file id. A file has them once its segment and its `photos_assets` row
    /// are both written: an index from before the fork kept the rest has the segment alone, and one from before fork
    /// step 2 no `photos_assets` rows; the next sync writes them all.
    func photosFacts() throws -> [Int64: PhotosFacts] {
        var facts: [Int64: PhotosFacts] = [:]
        try db.query("""
            SELECT s.file, s.excerpt, s.loc, coalesce(fts.original, fts.body), a.favorite, a.reading, a.origin,
                a.origin_app, a.camera
            FROM segments s JOIN photos_assets a ON a.file = s.file LEFT JOIN fts ON fts.rowid = s.id
            WHERE s.kind = '\(SegmentKind.photosInfo.rawValue)'
            """) { row in
            // A value of a later fork's that this one doesn't know: no facts, and the sync writes its own.
            guard let reading = PhotosLibrary.Reading(rawValue: row.text(5) ?? ""),
                  let origin = PhotosLibrary.Origin(rawValue: row.text(6) ?? "") else { return }
            facts[row.int(0)] = PhotosFacts(title: row.text(1) ?? "", date: row.double(2), text: row.text(3) ?? "",
                                            favorite: row.int(4) == 1, reading: reading, origin: origin,
                                            originApp: row.text(7), camera: row.text(8))
        }
        try db.query("SELECT file, latitude, longitude, source, place FROM locations WHERE \(Self.crawlLocation)") {
            facts[$0.int(0)]?.location = Self.location($0, from: 1)
        }
        try db.query("SELECT file, person FROM photos_person_files") { facts[$0.int(0)]?.people.insert($0.int(1)) }
        try db.query("SELECT file, album FROM photos_album_files") { facts[$0.int(0)]?.albums.insert($0.int(1)) }
        return facts
    }

    /// Writes what differs between a library file's facts and the ones `stored` (nil: none written yet): keyword
    /// search finds Photos' words in it, a result shows its title and date, and the filters see its favorite, origin,
    /// camera, place, people and albums. Nothing is embedded.
    func setPhotosFacts(_ facts: PhotosFacts, replacing stored: PhotosFacts?, of file: Int64) throws {
        if stored.map({ ($0.title, $0.date, $0.text) != (facts.title, facts.date, facts.text) }) ?? true {
            let kind = SegmentKind.photosInfo.rawValue
            try db.run("DELETE FROM fts WHERE rowid IN (SELECT id FROM segments WHERE file = ? AND kind = '\(kind)')",
                       [.int(file)])
            try db.run("DELETE FROM segments WHERE file = ? AND kind = '\(kind)'", [.int(file)])
            try addSegment(file: file, kind: .photosInfo, modality: .none, loc: facts.date, excerpt: facts.title,
                           text: facts.text)
        }
        if stored.map({ $0.assetRow != facts.assetRow }) ?? true {
            try db.run("""
                INSERT INTO photos_assets(file, favorite, reading, origin, origin_app, camera) VALUES(?, ?, ?, ?, ?, ?)
                ON CONFLICT(file) DO UPDATE SET favorite = excluded.favorite, reading = excluded.reading,
                    origin = excluded.origin, origin_app = excluded.origin_app, camera = excluded.camera
                """, [.int(file), .int(facts.favorite ? 1 : 0), .text(facts.reading.rawValue),
                      .text(facts.origin.rawValue), .optional(facts.originApp), .optional(facts.camera)])
        }
        if stored?.location != facts.location {
            if let location = facts.location {
                try setLocation(location, of: file)
            } else {
                try db.run("DELETE FROM locations WHERE file = ?", [.int(file)])
            }
        }
        if stored?.people != facts.people {
            try db.run("DELETE FROM photos_person_files WHERE file = ?", [.int(file)])
            for person in facts.people {
                try db.run("INSERT INTO photos_person_files(person, file) VALUES(?, ?)", [.int(person), .int(file)])
            }
        }
        if stored?.albums != facts.albums {
            try db.run("DELETE FROM photos_album_files WHERE file = ?", [.int(file)])
            for album in facts.albums {
                try db.run("INSERT INTO photos_album_files(album, file) VALUES(?, ?)", [.int(album), .int(file)])
            }
        }
    }

    /// Brings a library's people and pets up to date with its listing, each under Photos' uuid: one new to the index
    /// is added, a renamed one keeps its row and takes the new name. Returns their ids, by uuid. The ones no file
    /// shows any more go in `deleteUnlinkedPeopleAndAlbums`.
    func setPhotosPeople(_ people: [PhotosLibrary.Person], of library: String) throws -> [String: Int64] {
        var stored: [String: (id: Int64, name: String)] = [:]
        try db.query("SELECT uuid, id, name FROM photos_people WHERE library = ?", [.text(library)]) {
            stored[$0.text(0) ?? ""] = ($0.int(1), $0.text(2) ?? "")
        }
        var ids: [String: Int64] = [:]
        for person in people where ids[person.uuid] == nil {
            if let row = stored[person.uuid] {
                if row.name != person.name {
                    try db.run("UPDATE photos_people SET name = ? WHERE id = ?", [.text(person.name), .int(row.id)])
                }
                ids[person.uuid] = row.id
            } else {
                try db.run("INSERT INTO photos_people(library, uuid, name) VALUES(?, ?, ?)",
                           [.text(library), .text(person.uuid), .text(person.name)])
                ids[person.uuid] = db.lastInsertID
            }
        }
        return ids
    }

    /// Brings a library's albums up to date with its listing, as `setPhotosPeople` does its people: an album renamed
    /// or moved to another folder keeps its row.
    func setPhotosAlbums(_ albums: [PhotosLibrary.Album], of library: String) throws -> [String: Int64] {
        var stored: [String: (id: Int64, title: String, folders: [String])] = [:]
        try db.query("SELECT uuid, id, title, folders FROM photos_albums WHERE library = ?", [.text(library)]) {
            stored[$0.text(0) ?? ""] = ($0.int(1), $0.text(2) ?? "", Self.folders(fromJSON: $0.text(3)))
        }
        var ids: [String: Int64] = [:]
        for album in albums where ids[album.uuid] == nil {
            if let row = stored[album.uuid] {
                if row.title != album.title || row.folders != album.folders {
                    try db.run("UPDATE photos_albums SET title = ?, folders = ? WHERE id = ?",
                               [.text(album.title), .text(try Self.json(folders: album.folders)), .int(row.id)])
                }
                ids[album.uuid] = row.id
            } else {
                try db.run("INSERT INTO photos_albums(library, uuid, title, folders) VALUES(?, ?, ?, ?)",
                           [.text(library), .text(album.uuid), .text(album.title),
                            .text(try Self.json(folders: album.folders))])
                ids[album.uuid] = db.lastInsertID
            }
        }
        return ids
    }

    /// Deletes the people and albums no file is linked to any more: no indexed picture shows them now (a name taken
    /// off, an album emptied or deleted in Photos), or their pictures left the index.
    func deleteUnlinkedPeopleAndAlbums() throws {
        try db.run("DELETE FROM photos_people WHERE id NOT IN (SELECT person FROM photos_person_files)")
        try db.run("DELETE FROM photos_albums WHERE id NOT IN (SELECT album FROM photos_album_files)")
    }

    /// An album's folders as its row keeps them: a JSON array of the names, outermost first (a name can hold any
    /// character).
    static func json(folders: [String]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return String(decoding: try encoder.encode(folders), as: UTF8.self)
    }

    static func folders(fromJSON json: String?) -> [String] {
        json.flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? []
    }

    /// A person or pet named in a Photos library, and how many indexed files show them.
    public struct PhotosPerson: Sendable, Equatable, Identifiable {
        public let id: Int64
        /// The library, as the index spells it (`PhotosHit.library`).
        public let library: String
        /// Photos' id for them, kept through a rename in Photos: what the app's saved searches find them by.
        public let uuid: String
        public let name: String
        public let files: Int
    }

    /// An album of a Photos library, and how many indexed files are in it.
    public struct PhotosAlbum: Sendable, Equatable, Identifiable {
        public let id: Int64
        public let library: String
        /// Photos' id for it, kept when it's renamed or moved to another folder (`PhotosPerson.uuid`).
        public let uuid: String
        public let title: String
        /// The folders it's in, outermost first.
        public let folders: [String]
        public let files: Int
    }

    /// The people and pets named in the indexed libraries, by name. Two of one name stay two, as Photos keeps them.
    /// With a filter, only those in a file it keeps, counted so (`digup mcp`: the ones in what an AI app may see).
    public func photosPeople(keptBy filter: SearchFilter = SearchFilter()) throws -> [PhotosPerson] {
        var people: [PhotosPerson] = []
        let kept = filter.query
        try db.query("""
            SELECT p.id, p.library, p.uuid, p.name, COUNT(l.file) FROM photos_people p
            LEFT JOIN photos_person_files l ON l.person = p.id\(kept.map { " AND l.file IN (\($0.sql))" } ?? "")
            GROUP BY p.id\(kept == nil ? "" : " HAVING COUNT(l.file) > 0") ORDER BY p.name COLLATE NOCASE, p.id
            """, kept?.values ?? []) {
            people.append(PhotosPerson(id: $0.int(0), library: $0.text(1) ?? "", uuid: $0.text(2) ?? "",
                                       name: $0.text(3) ?? "", files: Int($0.int(4))))
        }
        return people
    }

    /// The albums of the indexed libraries: the ones in no folder first, then folder by folder (by the folders' names,
    /// outermost first), each folder's by title. With a filter, only those with a file it keeps, counted so.
    public func photosAlbums(keptBy filter: SearchFilter = SearchFilter()) throws -> [PhotosAlbum] {
        var albums: [PhotosAlbum] = []
        let kept = filter.query
        try db.query("""
            SELECT a.id, a.library, a.uuid, a.title, a.folders, COUNT(l.file) FROM photos_albums a
            LEFT JOIN photos_album_files l ON l.album = a.id\(kept.map { " AND l.file IN (\($0.sql))" } ?? "")
            GROUP BY a.id\(kept == nil ? "" : " HAVING COUNT(l.file) > 0") ORDER BY a.id
            """, kept?.values ?? []) {
            albums.append(PhotosAlbum(id: $0.int(0), library: $0.text(1) ?? "", uuid: $0.text(2) ?? "",
                                      title: $0.text(3) ?? "", folders: Self.folders(fromJSON: $0.text(4)),
                                      files: Int($0.int(5))))
        }
        return albums.sorted {
            $0.folders != $1.folders ? $0.folders.lexicographicallyPrecedes($1.folders)
                : $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    /// A device that took pictures and videos of the indexed libraries (`photos_assets.camera`, as Photos kept its
    /// EXIF: "iPhone 15 Pro"), how many indexed files it took, how many of those its camera saved there (origin
    /// `camera`), and how many came in with nothing recorded (origin `unknown`: older items). The app's list of the
    /// user's own devices starts as the ones with any camera-saved item; one with only older items can be added, which
    /// is what "Shot on my devices" reads them by (`SearchFilter.shotOn`).
    public struct PhotosCamera: Sendable, Equatable, Identifiable {
        public var id: String { model }
        public let model: String
        public let files: Int
        public let fromCamera: Int
        public let unknownOrigin: Int

        public init(model: String, files: Int, fromCamera: Int, unknownOrigin: Int) {
            self.model = model
            self.files = files
            self.fromCamera = fromCamera
            self.unknownOrigin = unknownOrigin
        }

        /// The rule behind "Shot on my devices" (approved 2026-10-22): a device whose camera saved something is the
        /// user's unless they took it off (the app's `myDevicesRemoved`); any other is theirs only if they added it
        /// (`myDevicesAdded`).
        public func isMine(added: [String], removed: [String]) -> Bool {
            (fromCamera > 0 || added.contains(model)) && !removed.contains(model)
        }

        /// The user's devices by that rule (what `SearchFilter.shotOn` takes), most files first; one they added that no
        /// indexed picture names (yet, or any more) is on it too, last. Keeping their changes rather than the list lets
        /// next year's phone join by itself.
        public static func mine(of cameras: [PhotosCamera], added: [String], removed: [String]) -> [String] {
            cameras.filter { $0.isMine(added: added, removed: removed) }.map(\.model)
                + added.filter { name in !removed.contains(name) && !cameras.contains { $0.model == name } }
        }
    }

    /// The devices that took the indexed libraries' pictures and videos, the one with most files first.
    public func photosCameras() throws -> [PhotosCamera] {
        var cameras: [PhotosCamera] = []
        try db.query("""
            SELECT camera, COUNT(*), SUM(origin = '\(PhotosLibrary.Origin.camera.rawValue)'),
                   SUM(origin = '\(PhotosLibrary.Origin.unknown.rawValue)') FROM photos_assets
            WHERE camera IS NOT NULL GROUP BY camera ORDER BY COUNT(*) DESC, camera
            """) {
            cameras.append(PhotosCamera(model: $0.text(0) ?? "", files: Int($0.int(1)), fromCamera: Int($0.int(2)),
                                        unknownOrigin: Int($0.int(3))))
        }
        return cameras
    }

    /// The indexed file of each of these Photos assets (by uuid), wherever the crawl found it now (an asset's file
    /// changes when it's downloaded or edited, `Indexer.sync`): the app's own favorites keep an asset, not a file. An
    /// asset that isn't indexed has no entry.
    public func paths(ofAssets uuids: Set<String>) throws -> [String: String] {
        var paths: [String: String] = [:]
        guard !uuids.isEmpty else { return paths }
        try db.query("SELECT f.path FROM photos_assets a JOIN files f ON f.id = a.file") { row in
            guard let path = row.text(0), let asset = PhotosLibrary.asset(ofFile: path), uuids.contains(asset.uuid)
            else { return }
            paths[asset.uuid] = path
        }
        return paths
    }

    /// The indexed files of the Photos libraries whose asset `visible` vouches for, given each library (as the files
    /// spell it): `digup mcp`'s Photos files an AI app may see while hidden items are kept from it
    /// (`PhotosLibrary.visibleAssets`). Found by path, whatever the index knows of them yet (an index brought up to new
    /// Photos facts has none until its next sync); a file that's no asset's is never among them.
    public func photosFiles(shownBy visible: (String) -> Set<String>) throws -> Set<String> {
        var paths: [String] = []
        try db.query("SELECT path FROM files WHERE path LIKE ?", [.text(PhotosLibrary.filesPattern)]) {
            if let path = $0.text(0) { paths.append(path) }
        }
        var shown: [String: Set<String>] = [:]
        return Set(paths.filter { path in
            guard let asset = PhotosLibrary.asset(ofFile: path) else { return false }
            let assets = shown[asset.library] ?? visible(asset.library)
            shown[asset.library] = assets
            return assets.contains(asset.uuid)
        })
    }

    /// The library videos read from what Photos keeps of them while their originals are in iCloud, with what that is
    /// (`PhotosLibrary.Reading.isStandIn`), by file id: `Indexer` reads them as pictures.
    func photosStandIns() throws -> [Int64: PhotosLibrary.Reading] {
        var readings: [Int64: PhotosLibrary.Reading] = [:]
        let standIns = PhotosLibrary.Reading.allCases.filter(\.isStandIn).map { "'\($0.rawValue)'" }
            .joined(separator: ",")
        try db.query("SELECT file, reading FROM photos_assets WHERE reading IN (\(standIns))") {
            readings[$0.int(0)] = PhotosLibrary.Reading(rawValue: $0.text(1) ?? "")
        }
        return readings
    }

    // MARK: Faces

    /// `meta` "fork_faces_model": the recognizer whose prints `faces` holds (`FaceReader.identity`).
    public static let facesModelKey = "fork_faces_model"
    /// `meta` "fork_faces_read": how far the faces pass has got through the pictures outside Photos (`FacesRead`).
    static let facesReadKey = "fork_faces_read"
    /// `meta` "fork_faces_matched": what `face_matches` was last made from (`facesMark`).
    static let facesMatchedKey = "fork_faces_matched"

    /// A face read, as `setFaces` writes it: the row of the person Photos says it is, nil outside Photos.
    struct FaceRow: Sendable {
        let box: Faces.Box
        let print: [Float]
        let person: Int64?
    }

    /// Makes `identity` the recognizer whose prints the index holds: another one's (or prints no recognizer is recorded
    /// for) are all deleted first, their matches with them, and the faces pass starts over (`Indexer.readFaces`), through
    /// the files there are now: the ones added later are read with their faces. Two recognizers' prints are never
    /// compared. Returns how many faces went.
    @discardableResult
    public func adoptFaceRecognizer(_ identity: String) throws -> Int {
        guard try meta(Self.facesModelKey) != identity else { return 0 }
        return try db.transaction {
            var deleted = 0
            try db.query("SELECT COUNT(*) FROM faces") { deleted = Int($0.int(0)) }
            try db.run("DELETE FROM faces")
            try setFacesRead(FacesRead(to: try lastFile(), after: 0, away: []))
            try setMeta(Self.facesMatchedKey, nil)
            try setMeta(Self.facesModelKey, identity)
            return deleted
        }
    }

    /// The id of the file added last (0: none).
    private func lastFile() throws -> Int64 {
        var last: Int64 = 0
        try db.query("SELECT coalesce(MAX(id), 0) FROM files") { last = $0.int(0) }
        return last
    }

    /// Writes the faces read from a picture segment, in place of the ones it had. Returns the new rows, in order.
    @discardableResult
    func setFaces(_ faces: [FaceRow], ofSegment segment: Int64) throws -> [Int64] {
        try db.run("DELETE FROM faces WHERE segment = ?", [.int(segment)])
        var ids: [Int64] = []
        for face in faces {
            try db.run("INSERT INTO faces(segment, x, y, width, height, print, person) VALUES(?, ?, ?, ?, ?, ?, ?)",
                       [.int(segment), .double(face.box.x), .double(face.box.y), .double(face.box.width),
                        .double(face.box.height), .blob(Faces.bytes(of: face.print)),
                        face.person.map { .int($0) } ?? .null])
            ids.append(db.lastInsertID)
        }
        // Named faces written: `face_matches` was made from others (one deleted shows in `facesMark` by itself, but a
        // new one can take a deleted one's id).
        if faces.contains(where: { $0.person != nil }) { try setMeta(Self.facesMatchedKey, nil) }
        return ids
    }

    /// How the faces outside Photos are matched now (`FaceMatching`): with the faces Photos named and the corrections
    /// beside the index (`faceRulings`), only those of files `filter` keeps (`digup mcp`: the ones an AI app may see).
    func faceMatching(referencesKeptBy filter: SearchFilter = SearchFilter()) throws -> FaceMatching {
        let kept = filter.query
        var named: [(person: Int64, print: [Float])] = []
        try db.query("SELECT f.person, f.print FROM faces f JOIN segments s ON s.id = f.segment WHERE f.person IS NOT NULL"
                     + (kept.map { " AND s.file IN (\($0.sql))" } ?? ""), kept?.values ?? []) { row in
            if let print = row.blob(1).flatMap(Faces.floats(fromBytes:)) { named.append((row.int(0), print)) }
        }
        let rulings = try faceRulings(keptBy: filter)
        return FaceMatching(named: named, rulings: rulings, ruled: try outsideFaces(ofFiles: Set(rulings.keys)))
    }

    /// The corrections beside the index (`FaceCorrections`): none when there are none, or when the file isn't their
    /// shape (the app says so, and leaves it as it is).
    public func faceCorrections() -> FaceCorrections {
        (try? FaceCorrections(contentsOf: FaceCorrections.url(beside: directory))) ?? FaceCorrections()
    }

    /// The corrections as they apply to the index now, by the file they're of, in the order they were made: each file
    /// where its bookmark finds it (else where it last was) among the pictures outside Photos `filter` keeps, each
    /// person every row of their Photos ids. One whose file or person isn't indexed applies to nothing.
    func faceRulings(keptBy filter: SearchFilter = SearchFilter()) throws -> [Int64: [FaceMatching.Ruling]] {
        let corrections = faceCorrections().corrections
        guard !corrections.isEmpty else { return [:] }
        var rows: [String: Set<Int64>] = [:]
        try db.query("SELECT id, uuid FROM photos_people") { rows[$0.text(1) ?? "", default: []].insert($0.int(0)) }
        let kept = filter.query
        var files: [String: Int64?] = [:]
        func file(at path: String) throws -> Int64? {
            if let known = files[path] { return known }
            var found: Int64?
            try db.query("SELECT id FROM files WHERE path = ? AND path NOT LIKE ?"
                         + (kept.map { " AND id IN (\($0.sql))" } ?? ""),
                         [.text(path), .text(PhotosLibrary.filesPattern)] + (kept?.values ?? [])) { found = $0.int(0) }
            files[path] = found
            return found
        }
        var rulings: [Int64: [FaceMatching.Ruling]] = [:]
        for correction in corrections {
            let people = correction.person.photos.reduce(into: Set<Int64>()) { $0.formUnion(rows[$1.uuid] ?? []) }
            let now = correction.file.whereItIs
            guard !people.isEmpty,
                  let id = try file(at: now) ?? (now == correction.file.path ? nil : file(at: correction.file.path))
            else { continue }
            rulings[id, default: []].append(FaceMatching.Ruling(box: correction.face, people: people,
                                                                says: correction.says))
        }
        return rulings
    }

    /// The faces outside Photos (no person), with their files, boxes and prints: every one, or those of `files`.
    private func outsideFaces(ofFiles files: Set<Int64>? = nil) throws -> [FaceMatching.Face] {
        var values: [SQLValue] = []
        if let files {
            guard !files.isEmpty else { return [] }
            values.append(.text(String(decoding: try JSONEncoder().encode(Array(files)), as: UTF8.self)))
        }
        var faces: [FaceMatching.Face] = []
        try db.query("""
            SELECT f.id, s.file, f.x, f.y, f.width, f.height, f.print FROM faces f JOIN segments s ON s.id = f.segment
            WHERE f.person IS NULL\(files == nil ? "" : " AND s.file IN (SELECT value FROM json_each(?))")
            """, values) { row in
            guard let box = Faces.Box(x: row.double(2), y: row.double(3), width: row.double(4), height: row.double(5)),
                  let print = row.blob(6).flatMap(Faces.floats(fromBytes:)) else { return }
            faces.append(FaceMatching.Face(id: row.int(0), file: row.int(1), box: box, print: print))
        }
        return faces
    }

    /// Writes the matches of faces outside Photos just read (a picture's, all together), as `matching` finds them.
    func matchFaces(_ faces: [FaceMatching.Face], with matching: FaceMatching) throws {
        for (face, match) in zip(faces, matching.matches(faces)) {
            try db.run("DELETE FROM face_matches WHERE face = ?", [.int(face.id)])
            if let match { try insert(match, of: face.id) }
        }
    }

    private func insert(_ match: FaceMatcher.Match, of face: Int64) throws {
        try db.run("INSERT INTO face_matches(face, person, similarity, confirmed) VALUES(?, ?, ?, ?)",
                   [.int(face), .int(match.person), .double(match.similarity), .int(match.confirmed ? 1 : 0)])
    }

    /// `face_matches` made again: every face outside Photos matched as the faces Photos named and the corrections
    /// beside the index have it now (`faceMatching`). Returns how many faces it matched.
    @discardableResult
    public func rebuildFaceMatches() throws -> Int {
        let (matching, faces, mark) = (try faceMatching(), try outsideFaces(), try facesMark())
        let matches = matching.matches(faces)
        return try db.transaction {
            try db.run("DELETE FROM face_matches")
            var count = 0
            for case let (face, match?) in zip(faces, matches) {
                try insert(match, of: face.id)
                count += 1
            }
            try setMeta(Self.facesMatchedKey, mark)
            return count
        }
    }

    /// `rebuildFaceMatches`, when what `face_matches` was made from changed: the named faces (a sync took some away, or a
    /// picture's were read), the faces outside Photos you said are someone, which are compared against too (their
    /// picture indexed, read again, or gone), or the corrections (the app saved them). Returns whether it was made
    /// again.
    @discardableResult
    public func rebuildFaceMatchesIfChanged() throws -> Bool {
        guard try meta(Self.facesMatchedKey) != facesMark() else { return false }
        try rebuildFaceMatches()
        return true
    }

    /// What `face_matches` is made from, as a mark that changes with it: the named faces (how many there are and the
    /// sum of their ids; writing named faces forgets the mark kept, `setFaces`, since a new one can take a deleted one's
    /// id), when the corrections were last saved and how long their file is, and the faces they teach (`taughtMark`).
    private func facesMark() throws -> String {
        var named = ""
        try db.query("SELECT COUNT(*), coalesce(SUM(id), 0) FROM faces WHERE person IS NOT NULL") {
            named = "\($0.int(0)) \($0.int(1))"
        }
        let file = try? FileManager.default.attributesOfItem(atPath: FaceCorrections.url(beside: directory).path)
        let saved = (file?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(named) \(saved) \((file?[.size] as? NSNumber)?.intValue ?? 0) \(try taughtMark())"
    }

    /// The faces outside Photos you said are someone, as the index has them now (each one's row, file, people and
    /// print), as a number: it changes when one's picture is indexed, read again or gone. 0 for none.
    private func taughtMark() throws -> String {
        let rulings = try faceRulings()
        let ruled = try outsideFaces(ofFiles: Set(rulings.keys))
        let taught = FaceMatching.said(of: ruled, rulings).compactMap { place, said in
            said.is.map { (face: ruled[place], people: $0.sorted()) }
        }.sorted { $0.face.id < $1.face.id }
        // FNV-1a: the same every run (Swift's own hashing isn't).
        var mark: UInt64 = taught.isEmpty ? 0 : 0xcbf2_9ce4_8422_2325
        func add(_ bytes: some Sequence<UInt8>) {
            for byte in bytes { mark = (mark ^ UInt64(byte)) &* 0x100_0000_01b3 }
        }
        for (face, people) in taught {
            for number in [face.id, face.file] + people { withUnsafeBytes(of: number) { add($0) } }
            add(Faces.bytes(of: face.print))
        }
        return String(mark, radix: 16)
    }

    /// The faces outside Photos matched with only the named faces and the corrections of files `filter` keeps, at the
    /// floor, as `face_matches` would hold them were those all there are (`digup mcp`: a face an AI app may not see
    /// never decides a match it's told of); nil when they are all of them, and `face_matches` holds just that.
    public func faceMatches(referencesKeptBy filter: SearchFilter) throws -> [Int64: FaceMatcher.Match]? {
        guard let kept = filter.query else { return nil }
        var unseen = 0
        try db.query("""
            SELECT COUNT(*) FROM faces f JOIN segments s ON s.id = f.segment
            WHERE f.person IS NOT NULL AND s.file NOT IN (\(kept.sql))
            """, kept.values) { unseen = Int($0.int(0)) }
        let ruled = try faceRulings().count
        if unseen == 0, try ruled == 0 || faceRulings(keptBy: filter).count == ruled { return nil }
        let faces = try outsideFaces()
        var found: [Int64: FaceMatcher.Match] = [:]
        for (face, match) in zip(faces, try faceMatching(referencesKeptBy: filter).matches(faces)) {
            found[face.id] = match
        }
        return found
    }

    /// A face found in a picture outside Photos: where it is, and who it's taken for when the People filter would keep
    /// the picture for them (at `Faces.threshold`, or because you said so).
    public struct PictureFace: Sendable, Equatable {
        public let box: Faces.Box
        public let match: FaceMatch?
    }

    /// The faces found in the picture at `path` (the search window's preview, where you can say who they are), left to
    /// right; none for a picture in Photos.
    public func pictureFaces(ofPath path: String) throws -> [PictureFace] {
        var faces: [PictureFace] = []
        try db.query("""
            SELECT f.x, f.y, f.width, f.height, m.person, p.name, m.similarity, m.confirmed FROM files fi
            JOIN segments s ON s.file = fi.id JOIN faces f ON f.segment = s.id
            LEFT JOIN face_matches m ON m.face = f.id LEFT JOIN photos_people p ON p.id = m.person
            WHERE fi.path = ? AND f.person IS NULL ORDER BY f.x
            """, [.text(path)]) { row in
            guard let box = Faces.Box(x: row.double(0), y: row.double(1), width: row.double(2), height: row.double(3))
            else { return }
            let confirmed = row.int(7) == 1
            let kept = !row.isNull(4) && (row.double(6) >= Faces.threshold || confirmed)
            let match = kept ? FaceMatch(name: row.text(5) ?? "", person: row.int(4), box: box,
                                         similarity: row.double(6), confirmed: confirmed) : nil
            faces.append(PictureFace(box: box, match: match))
        }
        return faces
    }

    /// How far the faces pass has got through the pictures outside Photos that were read before their faces were
    /// (`facesReadKey`, `Indexer.readFaces`): the files up to `to` (the last one when it started), in the order of their
    /// ids; `after`, the last it came to; `away`, those that weren't here to read then (gone, on a drive that's
    /// unplugged, or only in iCloud), which wait for a later pass.
    struct FacesRead: Codable, Equatable {
        var to: Int64
        var after: Int64
        var away: [Int64]
    }

    /// Where the faces pass is (`adoptFaceRecognizer` started it); one kept by another DigUp that can't be read starts
    /// over, through the files there are now.
    func facesRead() throws -> FacesRead {
        if let kept = try meta(Self.facesReadKey),
           let read = try? JSONDecoder().decode(FacesRead.self, from: Data(kept.utf8)) { return read }
        return FacesRead(to: try lastFile(), after: 0, away: [])
    }

    func setFacesRead(_ read: FacesRead) throws {
        try setMeta(Self.facesReadKey, String(decoding: try JSONEncoder().encode(read), as: UTF8.self))
    }

    /// A picture whose faces the pass reads: its file, and its picture segment.
    struct FacesToRead {
        let file: FileRecord
        let segment: Int64
    }

    /// The pictures outside Photos the faces pass hasn't come to (`FacesRead`), or that were away when it did: read,
    /// with a picture segment that has no faces, in the order of their files' ids.
    func picturesOutsideWithoutFaces(_ read: FacesRead) throws -> [FacesToRead] {
        var found: [FacesToRead] = []
        try db.query("""
            SELECT \(Self.fileColumns(of: "f")), s.id FROM files f
            JOIN segments s ON s.file = f.id AND s.kind = '\(SegmentKind.image.rawValue)'
            WHERE f.kind IN (\(Self.sqlList([FileKind.image, .screenshot]))) AND f.state = 'done' AND f.path NOT LIKE ?
            AND ((f.id > ? AND f.id <= ?) OR f.id IN (SELECT value FROM json_each(?)))
            AND NOT EXISTS (SELECT 1 FROM faces WHERE segment = s.id)
            ORDER BY f.id
            """, [.text(PhotosLibrary.filesPattern), .int(read.after), .int(read.to),
                  .text(String(decoding: try JSONEncoder().encode(read.away), as: UTF8.self))]) { row in
            found.append(FacesToRead(file: Self.record(row), segment: row.int(8)))
        }
        return found
    }

    /// The named faces the index has, by file: each one's person and box. What the faces pass compares with the faces
    /// Photos names now (`Indexer.NamedFace.areKept`).
    func namedFaces() throws -> [Int64: [(person: Int64, box: Faces.Box)]] {
        var faces: [Int64: [(person: Int64, box: Faces.Box)]] = [:]
        try db.query("""
            SELECT s.file, f.person, f.x, f.y, f.width, f.height FROM faces f JOIN segments s ON s.id = f.segment
            WHERE f.person IS NOT NULL
            """) { row in
            guard let box = Faces.Box(x: row.double(2), y: row.double(3), width: row.double(4), height: row.double(5))
            else { return }
            faces[row.int(0), default: []].append((row.int(1), box))
        }
        return faces
    }

    /// The pictures among `files` that were read, with their picture segment, in the order of their ids.
    func readPictures(_ files: some Sequence<Int64>) throws -> [FacesToRead] {
        var found: [FacesToRead] = []
        try db.query("""
            SELECT \(Self.fileColumns(of: "f")), s.id FROM files f
            JOIN segments s ON s.file = f.id AND s.kind = '\(SegmentKind.image.rawValue)'
            WHERE f.state = 'done' AND f.id IN (SELECT value FROM json_each(?)) ORDER BY f.id
            """, [.text(String(decoding: try JSONEncoder().encode(Array(files)), as: UTF8.self))]) { row in
            found.append(FacesToRead(file: Self.record(row), segment: row.int(8)))
        }
        return found
    }

    /// What the index knows of faces (Settings → Photos, `digup status`): the recognizer its prints are from (nil: none
    /// yet), the faces Photos named that it compares with, the faces found outside Photos and the pictures they're in,
    /// the pictures outside Photos with a face that matches someone at `Faces.threshold` or that you said is someone
    /// (what the People filter keeps), and the faces you said are someone (`FaceCorrections`).
    public struct FaceCounts: Sendable, Equatable {
        public var recognizer: String?
        public var named = 0
        public var outside = 0
        public var outsidePictures = 0
        public var matchedPictures = 0
        public var confirmed = 0
    }

    public func faceCounts() throws -> FaceCounts {
        var counts = FaceCounts(recognizer: try meta(Self.facesModelKey))
        try db.query("""
            SELECT COUNT(f.person), COUNT(*) - COUNT(f.person),
                   COUNT(DISTINCT CASE WHEN f.person IS NULL THEN f.segment END) FROM faces f
            """) {
            (counts.named, counts.outside, counts.outsidePictures) = (Int($0.int(0)), Int($0.int(1)), Int($0.int(2)))
        }
        try db.query("""
            SELECT COUNT(DISTINCT f.segment), coalesce(SUM(m.confirmed), 0) FROM face_matches m
            JOIN faces f ON f.id = m.face WHERE m.similarity >= \(Faces.threshold) OR m.confirmed = 1
            """) { (counts.matchedPictures, counts.confirmed) = (Int($0.int(0)), Int($0.int(1))) }
        return counts
    }

    // MARK: Locations

    /// Sets where a file was taken, in place of what it had.
    func setLocation(_ location: Location, of file: Int64) throws {
        try db.run("""
            INSERT INTO locations(file, latitude, longitude, source, place) VALUES(?, ?, ?, ?, ?)
            ON CONFLICT(file) DO UPDATE SET latitude = excluded.latitude, longitude = excluded.longitude,
                source = excluded.source, place = excluded.place
            """, [.int(file), .double(location.latitude), .double(location.longitude), .text(location.source.rawValue),
                  .optional(location.place)])
    }

    /// Where the files at `paths` were taken (pins on a map), by path; a file without a location isn't in it.
    public func locations(of paths: [String]) throws -> [String: Location] {
        var found: [String: Location] = [:]
        // A few hundred paths a query: SQLite limits the values one statement takes (999 before 3.32).
        for start in stride(from: 0, to: paths.count, by: 500) {
            let some = paths[start..<min(start + 500, paths.count)]
            try db.query("""
                SELECT f.path, l.latitude, l.longitude, l.source, l.place FROM locations l JOIN files f ON f.id = l.file
                WHERE f.path IN (\(some.map { _ in "?" }.joined(separator: ",")))
                """, some.map { .text($0) }) { row in
                found[row.text(0) ?? ""] = Self.location(row, from: 1)
            }
        }
        return found
    }

    /// A location from its row's latitude, longitude, source and place, starting at `column`.
    static func location(_ row: Statement, from column: Int32) -> Location? {
        guard let source = Location.Source(rawValue: row.text(column + 2) ?? "") else { return nil }
        return Location(latitude: row.double(column), longitude: row.double(column + 1), source: source,
                        place: row.text(column + 3))
    }

    // MARK: Stats

    public struct Counts: Sendable {
        public var byKindAndState: [String: [String: Int]] = [:]
        public var vectors = 0
        public var segments = 0
        /// Long files still being read (`unfinishedCount`), and their pages and chunks left.
        public var unfinished = 0
        public var left = 0
    }

    public func counts() throws -> Counts {
        var counts = Counts()
        try db.query("SELECT kind, state, COUNT(*) FROM files WHERE 1\(scopeSQL) GROUP BY kind, state", scopeValues) {
            counts.byKindAndState[$0.text(0) ?? "?", default: [:]][$0.text(1) ?? "?"] = Int($0.int(2))
        }
        (counts.unfinished, counts.left) = try unfinishedCount()
        let inScope = scope == nil ? "" : " AND file IN (SELECT id FROM files WHERE 1\(scopeSQL))"
        try db.query("SELECT COUNT(*), COUNT(vec) FROM segments WHERE kind NOT IN \(Self.crawlKinds)\(inScope)",
                     scopeValues) {
            counts.segments = Int($0.int(0))
            counts.vectors = Int($0.int(1))
        }
        return counts
    }
}
