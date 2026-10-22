import Foundation

public struct SearchHit: Sendable {
    public let path: String
    public let kind: FileKind
    public let score: Double          // fused rank score, for ordering only
    public let z: Double?             // how far the best segment stands out for this query (`Searcher.meaning`)
    public let cosine: Double?
    public let keywordRank: Int?      // 1-based rank among keyword matches
    public let segment: SegmentKind
    /// The segment the hit points at (its text is `Searcher.text(ofSegment:)`).
    public let segmentID: Int64
    public let loc: Double?           // PDF page, or seconds into audio/video
    public let locEnd: Double?
    public let excerpt: String?
    /// The file's modification date (seconds since 1970), and what indexing learned about it: "width", "height",
    /// "taken", "pages", "duration"… (see `Indexer`).
    public let modified: Double
    public let size: Int64
    public let info: [String: String]
    /// Code: the line to open at, in the stretch (`loc`…`locEnd`): where the name looked up is defined, or the first
    /// line with the query's words. Nil: the stretch's first line.
    public var focus: Double? = nil
    /// A picture or video of a Photos library: where it is in Photos, and what Photos calls it.
    public var photos: PhotosHit? = nil
    /// A video or audio file: how many moments of it match the query (`Searcher.moments(of:queryVector:zGate:)`),
    /// counted from the scores the search has anyway. 0 when none does (it's here by its name, say).
    public var momentCount = 0
}

/// A stretch of a recording that matches a query (`Searcher.moments(of:queryVector:zGate:)`): its segments that stand
/// out on the query's scale, neighbours of the same kind merged into one.
public struct Moment: Sendable, Equatable {
    public enum Kind: String, Sendable {
        /// A frame of the video, or one of Photos' stills of a video in iCloud.
        case seen
        /// A window of its sound (an audio file, or a video's soundtrack).
        case heard
    }

    public let kind: Kind
    /// Seconds into the recording, from where its first segment starts to where its last one ends. Nil for a still,
    /// which carries no time.
    public let start: Double?
    public let end: Double?
    /// A video in iCloud read from Photos' filmstrip: the still's place in it, from 0 (the indexer writes a stills
    /// video's frames in the filmstrip's order, `PhotosLibrary.filmstrip(startingAt:)`).
    public let still: Int?
    /// How far its best segment stands out for the query (`Searcher.meaning`): the moments of a file go best first.
    public let score: Double
    /// Its best segment.
    public let segmentID: Int64
}

/// A hit from a Photos library (`PhotosLibrary`): the asset it shows, its title and date in Photos (from its
/// `photosInfo` segment), and what DigUp read of it.
public struct PhotosHit: Sendable, Equatable {
    /// The library, as the index spells it (a real path).
    public let library: String
    public let uuid: String
    /// Its title in Photos, else the name of the file it came in as ("" if the crawl hasn't said yet).
    public let title: String
    /// When it was taken, in seconds since 1970.
    public let date: Double?
    /// The file read of it (nil if the crawl hasn't said yet): a video in iCloud was read from Photos' stills of it or
    /// its poster (`PhotosLibrary.Reading.isStandIn`), a photo in iCloud from its preview.
    public var reading: PhotosLibrary.Reading? = nil
    /// A video in iCloud: the still to show for it. The one that matched when the hit is one of its stills (a stills
    /// video's frame segments are its filmstrip's stills, in order), else its first still or its poster.
    public var still: String? = nil
}

/// What a search keeps besides its kinds: Photos' facts about a library's files, and where files were taken. The
/// parts combine with AND; an empty filter keeps every file.
public struct SearchFilter: Sendable, Equatable {
    /// People a file must show, every one of them (ids of `IndexStore.photosPeople`). An entry is one person, or the
    /// people who share a name, any of whom counts for it.
    public var people: [Set<Int64>]
    /// Albums a file must be in, any of them (ids of `IndexStore.photosAlbums`).
    public var albums: Set<Int64>
    /// Only Photos' favorites.
    public var favorites: Bool
    /// How a file came into its library, any of these (`PhotosLibrary.Origin`'s raw values).
    public var origins: Set<String>
    /// The device that took a file, any of these (`IndexStore.photosCameras`' models).
    public var cameras: Set<String>
    /// Shot on one of these devices (`IndexStore.photosCameras`' models), the app's "Shot on my devices": a camera
    /// took it into the library (origin camera) on one of them, or with no device recorded (Photos says a camera took
    /// it, which is the user's: 234 of 21,165 in a real library had no device name); or an older item, which Photos
    /// says nothing about (origin unknown), whose device is one of them. Nil doesn't filter; an empty set (every
    /// device taken off the user's list) keeps only what a camera saved with no device named.
    public var shotOn: Set<String>?
    /// Only these files, by path (the app's own favorites, `IndexStore.paths(ofAssets:)` for a Photos item's current
    /// file). Nil keeps every file; an empty set keeps none.
    public var paths: Set<String>?
    /// Only files taken inside this box (`IndexStore.locations`).
    public var area: Area?

    /// A box on the map, in degrees: south to north, west to east.
    public struct Area: Sendable, Equatable {
        public var latitudes: ClosedRange<Double>
        public var longitudes: ClosedRange<Double>

        public init(latitudes: ClosedRange<Double>, longitudes: ClosedRange<Double>) {
            (self.latitudes, self.longitudes) = (latitudes, longitudes)
        }
    }

    public init(people: [Set<Int64>] = [], albums: Set<Int64> = [], favorites: Bool = false, origins: Set<String> = [],
                cameras: Set<String> = [], shotOn: Set<String>? = nil, paths: Set<String>? = nil, area: Area? = nil) {
        (self.people, self.albums, self.favorites, self.area) = (people, albums, favorites, area)
        (self.origins, self.cameras, self.shotOn, self.paths) = (origins, cameras, shotOn, paths)
    }

    public var isEmpty: Bool {
        people.isEmpty && albums.isEmpty && !favorites && origins.isEmpty && cameras.isEmpty && shotOn == nil
            && paths == nil && area == nil
    }

    /// The files it keeps, as a query of their ids and the values it takes; nil when it keeps every file.
    var query: (sql: String, values: [SQLValue])? {
        func list(_ ids: Set<Int64>) -> String { ids.map(String.init).joined(separator: ",") }
        func placeholders(_ words: Set<String>) -> String { words.map { _ in "?" }.joined(separator: ",") }
        var parts: [String] = [], values: [SQLValue] = []
        for group in people {
            parts.append("SELECT file FROM photos_person_files WHERE person IN (\(list(group)))")
        }
        if !albums.isEmpty { parts.append("SELECT file FROM photos_album_files WHERE album IN (\(list(albums)))") }
        if favorites { parts.append("SELECT file FROM photos_assets WHERE favorite = 1") }
        if !origins.isEmpty {
            parts.append("SELECT file FROM photos_assets WHERE origin IN (\(placeholders(origins)))")
            values += origins.map { .text($0) }
        }
        if !cameras.isEmpty {
            parts.append("SELECT file FROM photos_assets WHERE camera IN (\(placeholders(cameras)))")
            values += cameras.map { .text($0) }
        }
        if let shotOn {
            if shotOn.isEmpty {
                parts.append("SELECT file FROM photos_assets WHERE origin = 'camera' AND camera IS NULL")
            } else {
                let devices = placeholders(shotOn)
                parts.append("""
                    SELECT file FROM photos_assets
                    WHERE (origin = 'camera' AND (camera IS NULL OR camera IN (\(devices))))
                        OR (origin = 'unknown' AND camera IN (\(devices)))
                    """)
                values += shotOn.map { .text($0) } + shotOn.map { .text($0) }
            }
        }
        if let paths {
            parts.append(paths.isEmpty ? "SELECT id FROM files WHERE 0"
                                       : "SELECT id FROM files WHERE path IN (\(placeholders(paths)))")
            values += paths.map { .text($0) }
        }
        if let area {
            parts.append("SELECT file FROM locations WHERE latitude BETWEEN ? AND ? AND longitude BETWEEN ? AND ?")
            values += [.double(area.latitudes.lowerBound), .double(area.latitudes.upperBound),
                       .double(area.longitudes.lowerBound), .double(area.longitudes.upperBound)]
        }
        return parts.isEmpty ? nil : (parts.joined(separator: " INTERSECT "), values)
    }
}

/// Hybrid search: meaning (EmbeddingGemma's vectors) + words (FTS5).
///
/// Meaning is the model's cosine similarity, put on one scale per query (`meaning`): every vector is scored anyway, so
/// the distribution comes for free, and only segments that stand out (`zGate`) count as meaning matches. That also
/// gives an honest "nothing found". Words rescue what a vector can't hold exactly: codes, IDs and names.
public final class Searcher {
    let store: IndexStore
    private var matrix: VectorStorage?   // rows × 768 float16, row-major
    private var rowFile: [Int64] = []
    private var rowSegment: [Int64] = []
    private var rowModality: [Modality] = []
    /// False for the vectors the later pass adds (`Indexer.finishLongFiles`): scored, but they don't set the scale.
    private var rowSetsScale: [Bool] = []
    private var fileKind: [Int64: FileKind] = [:]
    public private(set) var vectorSource: String?
    /// False after `releaseVectors()` (or `loadVectors: false`): keyword search still works, and the next search with
    /// a query vector loads them again.
    public private(set) var vectorsLoaded = false

    public var vectorCount: Int { rowFile.count }

    /// This is the code index's searcher (`IndexStore.codeFile`): names are looked up as names (`CodeLookup`).
    public var isCode: Bool { store.file.lastPathComponent == IndexStore.codeFile }

    /// With `loadVectors: false` only keyword search is ready; vectors load on the first meaning search. The app
    /// uses that to stay small while idle: 20k vectors are ~30 MB.
    public init(store: IndexStore, loadVectors: Bool = true) throws {
        self.store = store
        if loadVectors { try reload() } else { try reloadFiles() }
    }

    /// Reads the files and all vectors again (after indexing added some).
    public func reload() throws {
        releaseVectors()
        try reloadFiles()
        var rows = 0
        try store.db.query("SELECT COUNT(*) FROM segments WHERE vec IS NOT NULL") { rows = Int($0.int(0)) }
        guard let matrix = VectorStorage(rows: rows) else {
            vectorsLoaded = true   // nothing to load
            return
        }
        let rowBytes = Vectors.dimension * MemoryLayout<Float16>.stride
        let steps = IndexOptions()
        try store.db.query("""
            SELECT s.id, s.file, s.modality, s.vec, s.kind, s.loc, f.kind, CAST(json_extract(f.info, '$.pages') AS INTEGER)
            FROM segments s JOIN files f ON f.id = s.file WHERE s.vec IS NOT NULL ORDER BY s.id
            """) { row in
            guard let blob = row.blob(3), blob.count == rowBytes, rowFile.count < rows else { return }
            blob.copyBytes(to: UnsafeMutableRawBufferPointer(start: matrix.halves + rowFile.count * Vectors.dimension,
                                                             count: rowBytes))
            rowSegment.append(row.int(0))
            rowFile.append(row.int(1))
            rowModality.append(Modality(rawValue: row.text(2) ?? "") ?? .none)
            // Past the first step of a long PDF (its pages) or document (its chunks).
            let (kind, place) = (row.text(4), row.isNull(5) ? 0 : Int(row.double(5)))
            let later = row.text(6) == "pdf"
                ? kind != SegmentKind.chunk.rawValue && Int(row.int(7)) > steps.bigPDFPages && place > steps.pdfStep
                : kind == SegmentKind.chunk.rawValue && place > steps.docStep
            rowSetsScale.append(!later)
        }
        self.matrix = matrix
        vectorsLoaded = true
    }

    /// Frees the vectors' memory; keyword search keeps working.
    public func releaseVectors() {
        matrix = nil
        rowFile = []
        rowSegment = []
        rowModality = []
        rowSetsScale = []
        vectorsLoaded = false
    }

    private func reloadFiles() throws {
        fileKind.removeAll(keepingCapacity: true)
        try store.db.query("SELECT id, kind FROM files") { row in
            fileKind[row.int(0)] = FileKind(rawValue: row.text(1) ?? "")
        }
        vectorSource = try store.meta("vector_source")
    }

    /// How much finding the query's words counts against meaning (`search`). Code's words count for less: they're
    /// everywhere in code ("app", "running", "location"), and a stretch that shares a few of them beat the one that
    /// does what the query says (2026-10-09, the real-code eval of 27 queries over DigUp, Sparkle and llama.cpp: 18 → 20
    /// found first, the top 5 unchanged; the synthetic code eval 40 → 41 of 41; 1.5 changed nothing, 0.5 lost the top 5).
    public static let wordWeight = 2.0
    public static let codeWordWeight = 1.0

    /// `filter` narrows the files as `kinds` does. With no words (`text` blank) and a filter, the search lists what the
    /// filter keeps instead, newest first (`browse`).
    public func search(_ text: String, queryVector: [Float]?, kinds: Set<FileKind>? = nil,
                       filter: SearchFilter = SearchFilter(), limit: Int = 20, zGate: Double = 2.0,
                       wordWeight: Double? = nil, prefixLast: Bool = false) throws -> [SearchHit] {
        if !filter.isEmpty, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return try browse(filter, kinds: kinds, limit: limit)
        }
        let wordWeight = wordWeight ?? (isCode ? Self.codeWordWeight : Self.wordWeight)
        if queryVector != nil, !vectorsLoaded { try reload() }
        let fileKind = self.fileKind
        let narrowing = filter.query
        let kept = try narrowing.map { query -> Set<Int64> in
            var files = Set<Int64>()
            try store.db.query(query.sql, query.values) { files.insert($0.int(0)) }
            return files
        }
        let allowed = { (file: Int64) -> Bool in
            (kinds == nil || fileKind[file].map { kinds!.contains($0) } ?? false) && (kept?.contains(file) ?? true)
        }

        // Meaning: score every vector on this query's scale (`meaning`), keep each file's best segment, and a
        // recording's segments that stand out (its moments, counted for the hits it makes).
        var best: [Int64: (z: Double, cosine: Double, row: Int)] = [:]
        var standouts: [Int64: [(segment: Int64, z: Double)]] = [:]
        if let query = queryVector, query.count == Vectors.dimension, !rowFile.isEmpty {
            let scores = score(query)
            let meaning = Self.meaning(scores, rowModality, setsScale: rowSetsScale)
            for row in 0..<scores.count where allowed(rowFile[row]) {
                let (file, z) = (rowFile[row], meaning[row])
                if z > (best[file]?.z ?? -.infinity) { best[file] = (z, Double(scores[row]), row) }
                if z >= zGate, let kind = fileKind[file], Self.recordings.contains(kind) {
                    standouts[file, default: []].append((rowSegment[row], z))
                }
            }
        }

        // Words: FTS5 with Porter stemming over file names, folder names, OCR, page and document text. A name from code
        // ("quantize_row_q8_0_ref") is matched as one phrase, as it's written.
        let terms = Self.terms(text)
        let identifier = isCode ? CodeLookup.identifier(text) : nil
        var words: [(file: Int64, segment: Int64, snippet: String?)] = []
        var coverage: [Int64: Double] = [:]   // share of the query's words found anywhere in the file
        var patterns = identifier.map { [CodeLookup.phrase($0)] } ?? Self.patterns(terms, prefixLast: prefixLast)
        // A word that's in no file as typed matches as the start of longer words, as the last word does while it's
        // being typed: "grok" finds "Grok4" and "Grokipedia" (stemming only covers endings, as in "grokking").
        // Otherwise a file the panel showed while you typed dropped out once you stopped. A word that is in the index
        // as typed stays whole, so "cat" doesn't bring in "category"; so does a word of two letters, the start of too
        // many words to stand for one.
        if identifier == nil {
            for index in terms.indices where terms[index].count >= 3 && !patterns[index].hasSuffix("*") {
                if try !isIndexed(patterns[index]) { patterns[index] += "*" }
            }
        }
        if !patterns.isEmpty {
            var seen = Set<Int64>()
            // The filter narrows the matches before they're cut to the best 1,000: else a file it keeps could be
            // outranked by that many matches it doesn't, and never be seen.
            let onlyKept = narrowing.map { " AND s.file IN (\($0.sql))" } ?? ""
            try store.db.query("""
                SELECT s.file, s.id, snippet(fts, 1, '«', '»', '…', 12), fts.original FROM fts
                JOIN segments s ON s.id = fts.rowid
                WHERE fts MATCH ?\(onlyKept) ORDER BY bm25(fts, 3.0, 1.0) LIMIT 1000
                """, [.text(patterns.joined(separator: " OR "))] + (narrowing?.values ?? [])) { row in
                let file = row.int(0)
                guard words.count < 100, allowed(file), seen.insert(file).inserted else { return }
                // Text that normalizing changed is quoted as it's written (with its hamza, harakat, joiners).
                let snippet = row.text(3).flatMap { SearchText.snippet($0, terms: terms) } ?? row.text(2)
                words.append((file, row.int(1), snippet))
            }
            if !words.isEmpty {
                let files = words.map { String($0.file) }.joined(separator: ",")
                for pattern in patterns {
                    try store.db.query("""
                        SELECT DISTINCT s.file FROM fts JOIN segments s ON s.id = fts.rowid
                        WHERE fts MATCH ? AND s.file IN (\(files))
                        """, [.text(pattern)]) { coverage[$0.int(0), default: 0] += 1 / Double(patterns.count) }
                }
            }
        }

        // A file qualifies by standing out in meaning, or by containing at least half of the query's words.
        // Score: meaning z + a bonus that grows with word coverage, + 1 for the kind the query asks for.
        // One common word can't beat a strong meaning match; all the words of an exact lookup usually do.
        // (This beat reciprocal-rank fusion on both evals, 2026-10-07: R@1 0.88 vs 0.73 synthetic, 0.86 vs 0.82 real.)
        let lookup = Self.isLookup(terms) || identifier != nil
        let (meaningWeight, wordsWeight) = lookup ? (0.5, wordWeight * 2) : (1, wordWeight)
        let hinted = Self.kindHints(text)
        var candidates = Set(best.filter { $0.value.z >= zGate }.keys)
        for (file, share) in coverage where share >= 0.5 { candidates.insert(file) }
        var scored: [Int64: Double] = [:]
        for file in candidates {
            var score = meaningWeight * max(best[file]?.z ?? 0, 0) + wordsWeight * pow(coverage[file] ?? 0, 1.5)
            if let kind = fileKind[file], hinted.contains(kind) { score += 1 }
            scored[file] = score
        }

        let wordRank = Dictionary(words.enumerated().map { ($0.element.file, ($0.offset + 1, $0.element)) },
                                  uniquingKeysWith: { first, _ in first })
        var hits: [SearchHit] = []
        for (file, score) in scored.sorted(by: { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) })
            .prefix(limit) {
            let rank = hits.count
            let semantic = best[file]
            let keyword = wordRank[file]
            // Point at the best meaning segment if it stands out; else at the segment the words matched.
            let useMeaning = semantic.map { $0.z >= zGate || keyword == nil } ?? false
            guard var segmentID = useMeaning ? semantic.map({ rowSegment[$0.row] }) : keyword?.1.segment else { continue }
            var focus: Double?
            if isCode {
                // Where a name is defined is looked for in the first 10 results only: a name used all over a big repo
                // (ggml_tensor) is in hundreds of stretches of every file that has it (2026-10-09, llama.cpp and two
                // more repos: 560 → 100 ms a search; the others take 10–50 ms).
                (segmentID, focus) = try codePlace(file: file, segment: segmentID,
                                                   identifier: rank < 10 ? identifier : nil, query: text, terms: terms,
                                                   wordsHere: keyword?.1.segment == segmentID || identifier != nil)
            }
            let row = try fileRow(file)
            var segment = SegmentKind.name, loc: Double?, locEnd: Double?, storedExcerpt: String?
            try store.db.query("SELECT kind, loc, loc_end, excerpt FROM segments WHERE id = ?", [.int(segmentID)]) {
                segment = SegmentKind(rawValue: $0.text(0) ?? "") ?? .name
                loc = $0.isNull(1) ? nil : $0.double(1)
                locEnd = $0.isNull(2) ? nil : $0.double(2)
                storedExcerpt = $0.text(3)
            }
            // Photos' facts keep the title and the date where other segments keep an excerpt and a place.
            if segment == .photosInfo { (loc, locEnd, storedExcerpt) = (nil, nil, nil) }
            // Quote the matched words only when they come from the segment we point at, so a PDF hit on page 5
            // never shows page 2's words. A segment with no place and no text of its own (a screenshot's image
            // vector) can borrow them from its file's OCR text, which describes the same picture.
            var snippet = keyword.flatMap { $0.1.segment == segmentID ? $0.1.snippet : nil }
                .flatMap { $0.contains("«") ? excerpt($0, limit: 400) : nil }
            if snippet == nil, storedExcerpt == nil, loc == nil, let match = keyword?.1,
               let text = match.snippet, text.contains("«") {
                var matchedKind: String?
                try store.db.query("SELECT kind FROM segments WHERE id = ?", [.int(match.segment)]) {
                    matchedKind = $0.text(0)
                }
                if matchedKind != SegmentKind.name.rawValue { snippet = excerpt(text, limit: 400) }
            }
            hits.append(SearchHit(path: row.path, kind: row.kind, score: score, z: semantic?.z,
                                  cosine: semantic?.cosine, keywordRank: keyword?.0, segment: segment,
                                  segmentID: segmentID, loc: loc, locEnd: locEnd, excerpt: snippet ?? storedExcerpt,
                                  modified: row.modified, size: row.size, info: row.info, focus: focus,
                                  photos: try photosHit(file: file, path: row.path, segment: segmentID, kind: segment),
                                  momentCount: try moments(ofFile: file, standouts[file] ?? []).count))
        }
        return hits
    }

    /// A search with no words and a filter: the newest files the filter keeps (of `kinds`), by when Photos says a
    /// library's picture was taken, else by the file's modification date. Each points at its Photos facts, else at
    /// its name.
    private func browse(_ filter: SearchFilter, kinds: Set<FileKind>?, limit: Int) throws -> [SearchHit] {
        guard let query = filter.query else { return [] }
        let ofKinds = kinds.map { " AND f.kind IN (\(IndexStore.sqlList($0)))" } ?? ""
        var files: [Int64] = []
        try store.db.query("""
            SELECT f.id FROM files f
            LEFT JOIN segments s ON s.file = f.id AND s.kind = '\(SegmentKind.photosInfo.rawValue)'
            WHERE f.id IN (\(query.sql))\(ofKinds) ORDER BY coalesce(s.loc, f.mtime) DESC, f.id DESC LIMIT ?
            """, query.values + [.int(Int64(limit))]) { files.append($0.int(0)) }
        return try files.map { file in
            let row = try fileRow(file)
            var segment = (id: Int64(0), kind: SegmentKind.name)
            try store.db.query("""
                SELECT id, kind FROM segments WHERE file = ? AND kind IN \(IndexStore.crawlKinds)
                ORDER BY kind = '\(SegmentKind.name.rawValue)' LIMIT 1
                """, [.int(file)]) { segment = ($0.int(0), SegmentKind(rawValue: $0.text(1) ?? "") ?? .name) }
            return SearchHit(path: row.path, kind: row.kind, score: 0, z: nil, cosine: nil, keywordRank: nil,
                             segment: segment.kind, segmentID: segment.id, loc: nil, locEnd: nil, excerpt: nil,
                             modified: row.modified, size: row.size, info: row.info,
                             photos: try photosHit(file: file, path: row.path, segment: segment.id, kind: segment.kind))
        }
    }

    /// A file's row, as a hit shows it.
    private func fileRow(_ file: Int64) throws
        -> (path: String, kind: FileKind, modified: Double, size: Int64, info: [String: String]) {
        var row = (path: "", kind: FileKind.doc, modified: 0.0, size: Int64(0), info: [String: String]())
        try store.db.query("SELECT path, kind, mtime, size, info FROM files WHERE id = ?", [.int(file)]) {
            row.path = $0.text(0) ?? ""
            row.kind = FileKind(rawValue: $0.text(1) ?? "") ?? .doc
            row.modified = $0.double(2)
            row.size = $0.int(3)
            if let json = $0.text(4)?.data(using: .utf8) {
                row.info = (try? JSONSerialization.jsonObject(with: json) as? [String: String]) ?? [:]
            }
        }
        return row
    }

    /// A Photos library's file: the asset it shows, its title and date in Photos (its `photosInfo` segment), what was
    /// read of it (`photos_assets`), and for a video in iCloud the still the hit is on. Nil for any other file.
    private func photosHit(file: Int64, path: String, segment: Int64, kind: SegmentKind) throws -> PhotosHit? {
        guard let asset = PhotosLibrary.asset(ofFile: path) else { return nil }
        var title = "", date: Double?, reading: PhotosLibrary.Reading?
        try store.db.query("SELECT excerpt, loc FROM segments WHERE file = ? AND kind = ? LIMIT 1",
                           [.int(file), .text(SegmentKind.photosInfo.rawValue)]) {
            title = $0.text(0) ?? ""
            date = $0.isNull(1) ? nil : $0.double(1)
        }
        try store.db.query("SELECT reading FROM photos_assets WHERE file = ?", [.int(file)]) {
            reading = PhotosLibrary.Reading(rawValue: $0.text(0) ?? "")
        }
        var still: String?
        if reading?.isStandIn == true { still = path }
        if reading == .stills, kind == .frame {
            // The indexer writes a stills video's frames in its filmstrip's order (`Indexer.stills`), so a frame's place
            // among the file's frames is its still's.
            var place = 0
            try store.db.query("SELECT COUNT(*) FROM segments WHERE file = ? AND kind = ? AND id < ?",
                               [.int(file), .text(SegmentKind.frame.rawValue), .int(segment)]) { place = Int($0.int(0)) }
            let stills = PhotosLibrary.filmstrip(startingAt: path)
            if stills.indices.contains(place) { still = stills[place] }
        }
        return PhotosHit(library: asset.library, uuid: asset.uuid, title: title, date: date, reading: reading,
                         still: still)
    }

    // MARK: Moments

    /// The files read as recordings, a frame every few seconds and a window of sound at a time: the ones with moments.
    private static let recordings: Set<FileKind> = [.video, .audio]

    /// Every moment of the recording at `path` that matches the query, best first: its frames (or Photos' stills of it)
    /// and windows of sound that stand out on the query's scale as `search` puts it (`meaning`, at least `zGate`), with
    /// neighbours of the same kind merged (`merged`). A search's hits count theirs the same way (`momentCount`). None
    /// for a file that isn't a video or audio, or without a query vector: frames and sound windows carry no words, so
    /// only meaning finds them.
    public func moments(of path: String, queryVector: [Float]?, zGate: Double = 2.0) throws -> [Moment] {
        guard let query = queryVector, query.count == Vectors.dimension else { return [] }
        var file: (id: Int64, kind: FileKind?)?
        try store.db.query("SELECT id, kind FROM files WHERE path = ?", [.text(path)]) {
            file = ($0.int(0), FileKind(rawValue: $0.text(1) ?? ""))
        }
        guard let file, let kind = file.kind, Self.recordings.contains(kind) else { return [] }
        if !vectorsLoaded { try reload() }
        guard !rowFile.isEmpty else { return [] }
        let meaning = Self.meaning(score(query), rowModality, setsScale: rowSetsScale)
        let standouts = rowFile.indices.filter { rowFile[$0] == file.id && meaning[$0] >= zGate }
            .map { (segment: rowSegment[$0], z: meaning[$0]) }
        return try moments(ofFile: file.id, standouts)
    }

    /// A recording's moments, from its segments that stand out (with their scores) and where the index has them.
    private func moments(ofFile file: Int64, _ standouts: [(segment: Int64, z: Double)]) throws -> [Moment] {
        guard !standouts.isEmpty else { return [] }
        let scores = Dictionary(uniqueKeysWithValues: standouts.map { ($0.segment, $0.z) })
        let ids = scores.keys.map(String.init).joined(separator: ",")
        var placed: [(segment: Int64, kind: Moment.Kind, start: Double?, end: Double?)] = []
        try store.db.query("SELECT id, kind, loc, loc_end FROM segments WHERE id IN (\(ids))") { row in
            let kind: Moment.Kind? = switch SegmentKind(rawValue: row.text(1) ?? "") {
            case .frame: .seen
            case .audio: .heard
            default: nil
            }
            guard let kind else { return }
            placed.append((row.int(0), kind, row.isNull(2) ? nil : row.double(2), row.isNull(3) ? nil : row.double(3)))
        }
        // A frame with no time is one of Photos' stills of a video in iCloud: the indexer writes them in the
        // filmstrip's order (`Indexer.stills`), so its place among the file's frames is its place in the filmstrip.
        var filmstrip: [Int64: Int] = [:]
        if placed.contains(where: { $0.kind == .seen && $0.start == nil }) {
            try store.db.query("SELECT id FROM segments WHERE file = ? AND kind = ? ORDER BY id",
                               [.int(file), .text(SegmentKind.frame.rawValue)]) { filmstrip[$0.int(0)] = filmstrip.count }
        }
        return Self.merged(placed.map {
            MomentPiece(segment: $0.segment, kind: $0.kind, start: $0.start, end: $0.end,
                        still: $0.start == nil ? filmstrip[$0.segment] : nil, score: scores[$0.segment] ?? 0)
        })
    }

    /// A segment of a recording that stands out for a query, and where it is: what a moment is made of (`merged`).
    private struct MomentPiece {
        let segment: Int64
        let kind: Moment.Kind
        /// Seconds into the recording; nil for a still.
        let start: Double?
        let end: Double?
        /// A still's place in its filmstrip.
        let still: Int?
        let score: Double
    }

    /// Moments from pieces, best first. Timed pieces of one kind merge while each starts where the moment so far ends,
    /// or sooner: a video's kept frame stands for the stretch until the next one (`VideoExtractor.keyframes`), so two
    /// frames that match one after the other touch, and windows of sound overlap (30 s long, 25 s apart); a frame or
    /// window between them that doesn't match leaves a gap, and two moments. A piece spans at least its own stretch:
    /// to its end as the index has it, else a frame step or a sound window on from its start. A still is a moment of
    /// its own: stills carry no time, so none is known to be next to another.
    private static func merged(_ pieces: [MomentPiece]) -> [Moment] {
        let defaults = IndexOptions()
        func moment(_ best: MomentPiece, from start: Double?, to end: Double?) -> Moment {
            Moment(kind: best.kind, start: start, end: end, still: best.still, score: best.score,
                   segmentID: best.segment)
        }
        var moments: [Moment] = []
        for kind in [Moment.Kind.seen, .heard] {
            let step = kind == .seen ? defaults.frameInterval : defaults.audioWindow
            let timed = pieces.compactMap { piece in piece.start.map { (piece: piece, start: $0) } }
                .filter { $0.piece.kind == kind }
                .sorted { $0.start < $1.start }
            var open: (start: Double, end: Double, best: MomentPiece)?
            for (piece, start) in timed {
                let end = max(piece.end ?? start + step, start)
                if let current = open, start <= current.end {
                    open = (current.start, max(current.end, end), piece.score > current.best.score ? piece : current.best)
                } else {
                    if let done = open { moments.append(moment(done.best, from: done.start, to: done.end)) }
                    open = (start, end, piece)
                }
            }
            if let done = open { moments.append(moment(done.best, from: done.start, to: done.end)) }
        }
        moments += pieces.filter { $0.start == nil }.map { moment($0, from: nil, to: nil) }
        return moments.sorted { first, second in
            first.score != second.score ? first.score > second.score
                : (first.start ?? Double(first.still ?? 0)) < (second.start ?? Double(second.still ?? 0))
        }
    }

    /// Code: the stretch to point at, and the line in it to open at. A name looked up points at the stretch that
    /// defines it, when one does (not the ones that call it). Otherwise the line is the first with the query's words,
    /// when they matched in this stretch; a match by meaning alone opens at the stretch's first line.
    private func codePlace(file: Int64, segment: Int64, identifier: [String]?, query: String, terms: [String],
                           wordsHere: Bool) throws -> (Int64, Double?) {
        let name = query.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "()", with: "")
        if let identifier {
            var best: (segment: Int64, line: Int, strength: Int)?
            try store.db.query("""
                SELECT s.id, s.loc, coalesce(fts.original, fts.body) FROM fts JOIN segments s ON s.id = fts.rowid
                WHERE fts MATCH ? AND s.file = ? ORDER BY s.loc LIMIT 300
                """, [.text(CodeLookup.phrase(identifier)), .int(file)]) { row in
                guard best?.strength ?? 0 < 2, let text = row.text(2),
                      let found = CodeLookup.definition(of: name, in: text, first: Int(row.double(1))) else { return }
                if found.strength > (best?.strength ?? 0) { best = (row.int(0), found.line, found.strength) }
            }
            if let best { return (best.segment, Double(best.line)) }
        }
        guard wordsHere || identifier != nil, let text = try text(ofSegment: segment) else { return (segment, nil) }
        var first = 1
        try store.db.query("SELECT loc FROM segments WHERE id = ?", [.int(segment)]) { first = Int($0.double(0)) }
        let words = identifier == nil ? terms : [name.lowercased()]
        return (segment, CodeLookup.firstLine(with: words, in: text, first: first).map(Double.init))
    }

    /// Codes and IDs ("K7Q2LM", "TRX50") and long numbers ("4815162342": an order, a phone number) mean nothing to an
    /// embedding but everything to keyword search: a query made of them weighs words double and meaning half. Numbers
    /// count since 2026-10-09, when text of digits lost its vectors (`SearchText.hasWords`): a number in a data dump fell
    /// below unrelated meaning matches.
    static func isLookup(_ terms: [String]) -> Bool {
        !terms.isEmpty && terms.allSatisfy {
            $0.contains(where: \.isNumber) && ($0.contains(where: \.isLetter) || $0.count >= 4)
        }
    }

    /// How many of `hits` (best first) are strong: scoring at least `ratio` × the top hit. The rest pass the gates but
    /// trail far behind, and the app folds them under "weaker matches". On both evals (2026-10-07), 0.5 cut the list
    /// from 26.2 to 5.7 results per query and never folded an expected answer.
    public static func strongCount(_ hits: [SearchHit], ratio: Double = 0.5) -> Int {
        guard let top = hits.first?.score, top > 0 else { return hits.count }
        return hits.prefix { $0.score >= top * ratio }.count
    }

    /// Cosine similarity of `query` with every stored vector (all are L2-normalized): a matrix-vector product, done a
    /// block of rows at a time, each block turned into float32 first.
    private func score(_ query: [Float]) -> [Float] {
        let rows = rowFile.count
        var scores = [Float](repeating: 0, count: rows)
        guard let matrix, rows > 0 else { return scores }
        query.withUnsafeBufferPointer { query in
            scores.withUnsafeMutableBufferPointer { scores in
                var row = 0
                while row < rows {
                    let count = min(VectorStorage.blockRows, rows - row)
                    Vectors.floats(fromHalf: matrix.halves + row * Vectors.dimension, count: count * Vectors.dimension,
                                   to: matrix.block)
                    // (count × 768) · (768 × 1)
                    Vectors.scores(of: matrix.block, count: count, query: query.baseAddress!,
                                   into: scores.baseAddress! + row)
                    row += count
                }
            }
        }
        return scores
    }

    /// This query's meaning scores: each vector's cosine similarity minus the average of its modality (text, image and
    /// audio vectors can sit at slightly different levels for the same query), in standard deviations of all of them
    /// together. Within a modality that's the model's own order. Scaling each modality by its own deviation instead
    /// inflated the narrow ones and buried PDF pages under pictures (2026-10-08, on the three evals: 91 → 94 of 105
    /// queries with the right answer first).
    ///
    /// The scale (the averages and the deviation) comes from the vectors in `setsScale` (all by default): `search` leaves
    /// out the later pages of long files, which are scored on it but don't move it. A book's hundreds of pages pulled the
    /// text average down for every query, and documents rose over screenshots everywhere (2026-10-09, the testbed's long
    /// files finished: real eval 24 → 22 of 26 first; 24 with the scale kept).
    static func meaning(_ scores: [Float], _ modality: [Modality], setsScale: [Bool]? = nil) -> [Double] {
        let means = modalityMeans(scores, modality, setsScale: setsScale)
        let centered = zip(scores, modality).map { Double($0) - means[$1, default: 0] }
        var count = 0.0, sum = 0.0
        for row in centered.indices where setsScale?[row] ?? true {
            count += 1
            sum += centered[row]
        }
        let mean = sum / max(count, 1)
        var squares = 0.0
        for row in centered.indices where setsScale?[row] ?? true {
            squares += (centered[row] - mean) * (centered[row] - mean)
        }
        let deviation = max((squares / max(count, 1)).squareRoot(), 0.02)
        return centered.map { ($0 - mean) / deviation }
    }

    /// The average score of each modality for this query. Small groups (< 20 vectors) take the average of all.
    static func modalityMeans(_ scores: [Float], _ modality: [Modality], setsScale: [Bool]? = nil) -> [Modality: Double] {
        var sum: [Modality: Double] = [:], count: [Modality: Int] = [:]
        for row in scores.indices where setsScale?[row] ?? true {
            sum[modality[row], default: 0] += Double(scores[row])
            count[modality[row], default: 0] += 1
        }
        let all = sum.values.reduce(0, +) / Double(max(count.values.reduce(0, +), 1))
        var out: [Modality: Double] = [:]
        for modality in Modality.allCases {
            if let n = count[modality], n >= 20 {
                out[modality] = sum[modality]! / Double(n)
            } else {
                out[modality] = all
            }
        }
        return out
    }

    /// The text of a page, a document's passage or a screenshot's OCR, as it's written: the preview shows the part of a
    /// document that matched.
    public func text(ofSegment id: Int64) throws -> String? {
        var text: String?
        try store.db.query("SELECT coalesce(original, body) FROM fts WHERE rowid = ?", [.int(id)]) { text = $0.text(0) }
        return text
    }

    /// (The Windows and Linux app's previews keep the same list in shell/ui/results.js.)
    static let stopwords: Set<String> = [
        "a", "an", "the", "of", "in", "on", "at", "to", "for", "with", "and", "or", "my", "me", "that", "this",
        "these", "those", "from", "about", "where", "what", "which", "who", "when", "is", "was", "are", "were", "be",
        "it", "its", "some", "any", "find", "show", "file", "files", "photo", "photos", "picture", "image", "images",
        "screenshot", "screenshots", "video", "videos", "pdf", "document", "documents", "recording",
        // Bengali and Arabic (normalized, as `terms` sees them)
        "এবং", "ও", "এই", "সেই", "একটি", "আমার", "থেকে", "জন্য", "সাথে", "মধ্যে", "কোথায়", "কোন", "কী", "কি", "যে",
        "ছবি", "স্ক্রিনশট", "ভিডিও", "ফাইল", "পিডিএফ",
        "في", "من", "على", "الى", "عن", "مع", "هذا", "هذه", "ذلك", "التي", "الذي", "اين", "ما",
        "صورة", "صور", "لقطة", "شاشة", "فيديو", "ملف", "مستند",
    ]

    /// The content words of a query, normalized as keyword search keeps its text (`SearchText`). Kind words
    /// ("screenshot", "video") and stopwords are dropped: they describe what to look for, not what's in it. Words of
    /// two letters or more count; a Bengali letter with its vowel sign ("মা") is two.
    public static func terms(_ text: String) -> [String] {
        var seen = Set<String>()
        return SearchText.normalized(text).lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.unicodeScalars.count >= 2 && !stopwords.contains($0) && seen.insert($0).inserted }
    }

    /// FTS5 patterns for the query's words: quoted, and as prefixes for the last word while it's being typed and for
    /// words of languages that attach endings (`SearchText.inflects`). `search` makes a word that's in no file a
    /// prefix too.
    static func patterns(_ terms: [String], prefixLast: Bool) -> [String] {
        terms.enumerated().map { index, term in
            let prefix = (prefixLast && index == terms.count - 1) || SearchText.inflects(term)
            return "\"\(term)\"" + (prefix ? "*" : "")
        }
    }

    /// Whether keyword search finds `pattern` in any file.
    private func isIndexed(_ pattern: String) throws -> Bool {
        var found = false
        try store.db.query("SELECT 1 FROM fts WHERE fts MATCH ? LIMIT 1", [.text(pattern)]) { _ in found = true }
        return found
    }

    /// The query's words as an FTS5 OR-query.
    public static func ftsQuery(_ text: String, prefixLast: Bool = false) -> String? {
        let words = terms(text)
        guard !words.isEmpty else { return nil }
        return patterns(words, prefixLast: prefixLast).joined(separator: " OR ")
    }

    static let kindWords: [String: FileKind] = [
        "screenshot": .screenshot, "screenshots": .screenshot, "photo": .image, "photos": .image, "picture": .image,
        "pictures": .image, "image": .image, "images": .image, "pdf": .pdf, "pdfs": .pdf, "paper": .pdf,
        "papers": .pdf, "document": .doc, "documents": .doc, "note": .doc, "notes": .doc, "video": .video,
        "videos": .video, "clip": .video, "movie": .video, "audio": .audio, "song": .audio, "podcast": .audio,
        "voice": .audio, "sound": .audio,
        "স্ক্রিনশট": .screenshot, "ছবি": .image, "পিডিএফ": .pdf, "নোট": .doc, "ভিডিও": .video, "অডিও": .audio,
        "গান": .audio, "রেকর্ডিং": .audio,
        "لقطة": .screenshot, "صورة": .image, "صور": .image, "مستند": .doc, "ملاحظات": .doc, "فيديو": .video,
        "مقطع": .video, "صوت": .audio, "تسجيل": .audio, "اغنية": .audio,
    ]

    /// Kinds the query asks for ("…in a video", "screenshot of…", "ভিডিওতে"): a soft boost, not a filter. Bengali
    /// attaches case endings, so a Bengali kind word also counts at the start of a longer word.
    static func kindHints(_ text: String) -> Set<FileKind> {
        Set(SearchText.normalized(text).lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .compactMap { word in
                kindWords[word] ?? kindWords.first { key, _ in
                    SearchText.inflects(key) && key.unicodeScalars.count >= 3 && word.hasPrefix(key)
                }?.value
            })
    }
}
