import Foundation

public enum IndexerError: Error, CustomStringConvertible {
    case fingerprintMismatch(index: String, now: String)

    public var description: String {
        switch self {
        case .fingerprintMismatch(let index, let now):
            "this index was built with different settings or model:\n  index: \(index)\n  now:   \(now)\n"
                + "re-run with --reindex (vectors from different settings can't be compared)"
        }
    }
}

/// Keeps the index in step with the chosen folders, then extracts and embeds whatever is pending.
///
/// Model work goes to an `Embedder` (made on first use, freed by `closeWorker`). Extraction (ImageIO, Vision, PDFKit,
/// AVFoundation) runs on a second thread one batch ahead, so reading files and embedding them overlap (see `run`).
/// Given a `FaceReader`, a picture read is read for its faces there too (`faces`), and pictures read before get theirs
/// from the faces pass (`readFaces`).
public final class Indexer {
    public struct SyncSummary: Sendable {
        public var added = 0, changed = 0, moved = 0, removed = 0, unchanged = 0
        /// Photos library files whose facts (what Photos says about them) were written or rewritten.
        public var described = 0
        public var crawl: CrawlReport
        /// Files this sync queued for embedding (new or changed), so a watcher can index exactly those first.
        public var queued: [Int64] = []
    }

    public struct Event: Sendable {
        public let done: Int
        public let total: Int
        public let path: String
        public let kind: FileKind
        public let state: String
        public let seconds: Double
        public let note: String?
    }

    let store: IndexStore
    let options: IndexOptions
    private let makeEmbedder: () throws -> any Embedder
    private var worker: (any Embedder)?
    private let scratch: URL
    /// What reads the faces in pictures (`Faces.reader`), when there's one.
    private let faces: (any FaceReader)?
    /// The faces Photos names in each library picture, as the last sync's listing has them, each with its person's
    /// row: what reading the picture prints, and what the faces pass holds the index's named faces to (`readFaces`).
    /// Every file of a library the sync listed has an entry, empty when Photos names no face in it.
    private var namedFaces: [Int64: [NamedFace]] = [:]
    /// The library pictures the faces pass read in this process, with the named faces it read them for: one whose named
    /// faces couldn't all be read waits for the next helper, or for Photos to name them otherwise.
    private var triedNamed: [Int64: [NamedFace]] = [:]
    /// The pictures outside Photos the faces pass found away in this process: they wait for the next helper.
    private var triedAway = Set<Int64>()
    /// How faces just read outside Photos are matched (`IndexStore.faceMatching`: the named faces and the corrections),
    /// loaded once a run: named faces read in the same run join at its end, when `face_matches` is made again.
    private var matching: FaceMatching?

    /// When set, an index built with another model or other settings is emptied and embedded again (the app: a new
    /// version may bring a new model), and this hears about it. When nil, indexing stops with `fingerprintMismatch`.
    public var resetOnModelChange: ((_ indexed: String, _ now: String) -> Void)?

    /// The vector source of the embedders `makeEmbedder` makes, when it's known without starting one (llama.cpp's is):
    /// then `checkModel()` can notice a new model before anything needs embedding.
    public var embedderSource: String?
    /// The index folder, where what indexing costs on this Mac is kept (`MeasuredCosts`) for estimates. Unset: nothing
    /// is kept.
    public var costsFolder: URL?
    private var measured = MeasuredCosts()

    /// `faces`: what reads the faces in pictures; the faces already in the index are another recognizer's, or nobody's,
    /// and go (`IndexStore.adoptFaceRecognizer`). Without one, no faces are read and the index's stay as they are.
    public init(store: IndexStore, options: IndexOptions, faces: (any FaceReader)? = nil,
                makeEmbedder: @escaping () throws -> any Embedder) throws {
        self.store = store
        self.options = options
        self.faces = faces
        self.makeEmbedder = makeEmbedder
        if let faces { try store.adoptFaceRecognizer(faces.identity) }
        // One folder per process ($TMPDIR/DigUp-<pid>, which the helper clears up after a process that died), and one
        // in it per indexer: the helper runs two (the main index and the code index), and each clears its own away.
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("DigUp-\(ProcessInfo.processInfo.processIdentifier)")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    deinit {
        worker?.close()
        try? FileManager.default.removeItem(at: scratch)
    }

    /// Frees the embedding model (about 1 GB) until the next file needs it.
    public func closeWorker() {
        worker?.close()
        worker = nil
    }

    /// Stops the worker and removes the scratch folder, for a process that's about to exit (deinit won't run then).
    public func finish() {
        closeWorker()
        try? FileManager.default.removeItem(at: scratch)
    }

    public var workerIsRunning: Bool { worker != nil }

    // MARK: Sync

    /// Crawls `roots` and reconciles the index: new files are queued, changed ones re-queued, moved ones re-pathed
    /// (no re-embedding), and files that are gone or newly excluded are removed. A Photos library's asset stays one row
    /// while its file changes (downloaded, edited, re-rendered, back to Photos' stills): a file of a library at a new
    /// path is the row of the same library and asset uuid, if there's one, re-pathed and read again, keeping its id and
    /// with it its people, albums, favorite and place. That row is the asset's before any file is matched by its inode,
    /// and a move by inode never crosses a library's edge (`staysOnItsSide`). What Photos says about a Photos library's
    /// files (its words, favorites, places, people and albums) is brought up to date too, without reading them again,
    /// and a person or album no file is linked to any more is deleted. Where Photos named faces is kept for reading the
    /// pictures (`readFaces`); named faces that went with their pictures or people take their matches with them.
    public func sync(_ roots: [URL]) throws -> SyncSummary {
        let crawl = Crawler.crawl(roots, options: options)
        let existing = try store.files(under: roots.map { $0.standardizedFileURL.path })
        var byPath: [String: FileRecord] = [:]
        var byInode: [String: FileRecord] = [:]
        var byAsset: [String: FileRecord] = [:]   // a Photos library's files, by `assetKey`
        for file in existing {
            byPath[file.path] = file
            byInode["\(file.device):\(file.inode)"] = file
            if let key = Self.assetKey(file.path) { byAsset[key] = file }
        }
        let seen = Set(crawl.candidates.map(\.path))
        // A library's file at a new path takes its asset's row first, whatever order the crawl found the files in: a
        // file elsewhere that shares the old file's inode (a hard link) must not take it by inode before it.
        var assetRows: [String: FileRecord] = [:]   // candidate path → its asset's row
        var reserved = Set<Int64>()
        for file in crawl.candidates where byPath[file.path] == nil && crawl.photos[file.path] != nil {
            guard let row = Self.assetKey(file.path).flatMap({ byAsset[$0] }), !seen.contains(row.path),
                  reserved.insert(row.id).inserted else { continue }
            assetRows[file.path] = row
        }
        var movedFrom = Set<String>()
        var ids: [String: Int64] = [:]   // the Photos library files' rows, for their facts
        var summary = SyncSummary(crawl: crawl)
        try store.db.transaction {
            for file in crawl.candidates {
                let id: Int64
                if let row = byPath[file.path] {
                    id = row.id
                    if row.size != file.size || abs(row.mtime - file.mtime) > 0.001 || row.kind != file.kind {
                        try store.requeue(row.id, as: file)
                        summary.changed += 1
                        summary.queued.append(row.id)
                    } else {
                        summary.unchanged += 1
                    }
                } else if let row = assetRows[file.path] {
                    // Another file of an asset the index has: the asset's row, read again from its new file.
                    id = row.id
                    try store.move(row.id, to: file.path)
                    try store.requeue(row.id, as: file)
                    movedFrom.insert(row.path)
                    summary.changed += 1
                    summary.queued.append(row.id)
                } else if let row = byInode["\(file.device):\(file.inode)"], !reserved.contains(row.id),
                          !seen.contains(row.path), !movedFrom.contains(row.path), row.size == file.size,
                          abs(row.mtime - file.mtime) < 0.001, Self.staysOnItsSide(row.path, file.path) {
                    id = row.id
                    try store.move(row.id, to: file.path)
                    movedFrom.insert(row.path)
                    summary.moved += 1
                } else {
                    id = try store.insert(file)
                    summary.queued.append(id)
                    summary.added += 1
                }
                if crawl.photos[file.path] != nil { ids[file.path] = id }
            }
            // A root that went away while it was being walked (a drive ejected mid-crawl) looked emptier than it is:
            // keep its rows rather than take that for "deleted". So does a Photos library that couldn't be read.
            let vanished = roots.map { $0.standardizedFileURL.path }
                .filter { !FileManager.default.fileExists(atPath: $0) }.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
            for row in existing where !seen.contains(row.path) && !movedFrom.contains(row.path)
                && !vanished.contains(where: { row.path.hasPrefix($0) })
                && !crawl.unlisted.contains(where: { FolderSelection.isInside(row.path, $0) }) {
                try store.delete(row.id)
                namedFaces[row.id] = nil
                summary.removed += 1
            }
            try describe(ids, from: crawl, summary: &summary)
            try store.deleteUnlinkedPeopleAndAlbums()
        }
        // Named faces gone with their pictures or people: the matches made with them go too.
        if faces != nil { try store.rebuildFaceMatchesIfChanged() }
        return summary
    }

    /// A Photos library's file as its asset: the library, as the path spells it, and the asset's uuid. Nil for any other
    /// file.
    private static func assetKey(_ path: String) -> String? {
        PhotosLibrary.asset(ofFile: path).map { $0.library + "/" + $0.uuid }
    }

    /// Whether a file found at `new` with the inode of the row at `old` is that row moved: only on one side of a Photos
    /// library's edge. A library's file stands for its asset, with Photos' facts and place, and any other file only for
    /// itself, with its own place: one moved, or hard-linked, across the edge is a new file to read, and the old row
    /// goes with what it had (a library renamed or moved keeps its files' rows: both paths are in a library).
    private static func staysOnItsSide(_ old: String, _ new: String) -> Bool {
        (PhotosLibrary.library(containing: old) == nil) == (PhotosLibrary.library(containing: new) == nil)
    }

    /// Writes what Photos says about the library files a sync found (`ids`, by path) where it differs from what's
    /// stored: each library's people and albums first (the ones its files show), then each file's facts, linked to
    /// its own library's rows (a file whose library was renamed or moved is linked to the new one's). The faces Photos
    /// names in each are kept for reading the picture (`namedFaces`).
    private func describe(_ ids: [String: Int64], from crawl: CrawlReport, summary: inout SyncSummary) throws {
        guard !ids.isEmpty else { return }
        let stored = try store.photosFacts()
        var byLibrary: [String: [(path: String, id: Int64)]] = [:]
        for (path, id) in ids {
            guard let library = PhotosLibrary.library(containing: path) else { continue }
            byLibrary[library, default: []].append((path, id))
        }
        for (library, files) in byLibrary {
            let assets = files.compactMap { crawl.photos[$0.path] }
            let shown = Set(assets.flatMap(\.people)), filed = Set(assets.flatMap(\.albums))
            let people = try store.setPhotosPeople((crawl.photosPeople[library] ?? []).filter {
                shown.contains($0.uuid) && !$0.name.isEmpty
            }, of: library)
            let albums = try store.setPhotosAlbums((crawl.photosAlbums[library] ?? []).filter {
                filed.contains($0.uuid)
            }, of: library)
            for (path, id) in files {
                guard let asset = crawl.photos[path] else { continue }
                let facts = IndexStore.PhotosFacts(asset, people: people, albums: albums)
                if stored[id] != facts {
                    try store.setPhotosFacts(facts, replacing: stored[id], of: id)
                    summary.described += 1
                }
                // A listing from before faces were listed says nothing of them: what's kept stays as it is.
                if let named = asset.faces {
                    namedFaces[id] = named.compactMap { face in
                        face.person.flatMap { people[$0.uuid] }.map { NamedFace(person: $0, box: face) }
                    }
                }
            }
        }
    }

    // MARK: Run

    /// Processes pending files, screenshots first, newest first (`only`: just these files). Long PDFs and documents get
    /// their first step (`IndexOptions.pdfStep` pages, `docStep` chunks) and stay `partial` for `finishLongFiles`.
    /// Per-file problems are recorded on the file; a dead worker or a settings mismatch stops the run (pending files stay
    /// pending, so the next run resumes). `shouldStop` is asked between batches: pausing, or new files that should go
    /// first. With a face reader, the faces of each picture read are kept, those outside Photos matched as they come,
    /// and `face_matches` is made again at the end when named faces were read.
    @discardableResult
    public func run(limit: Int? = nil, only ids: Set<Int64>? = nil, shouldStop: () -> Bool = { false },
                    onEvent: (Event) -> Void = { _ in }) throws -> [String: Int] {
        let queue = try store.pending(limit: limit, only: ids)
        // A library's video in iCloud is read from what Photos keeps of it (`PhotosLibrary.Reading`).
        let standIns = queue.contains { $0.kind == .video } ? try store.photosStandIns() : [:]
        var states: [String: Int] = [:]
        var done = 0
        let jobs = Self.batches(queue).map { files in
            Job(files: files, reading: standIns[files[0].id], named: Dictionary(uniqueKeysWithValues: files.compactMap {
                file in namedFaces[file.id].map { (file.id, $0) }
            }))
        }
        defer { matching = nil }
        try process(jobs, shouldStop: shouldStop) { _, job, results, seconds in
            for (offset, file) in job.files.enumerated() {
                let (state, note) = results[offset]
                states[state, default: 0] += 1
                onEvent(Event(done: done + offset + 1, total: queue.count, path: file.path, kind: file.kind,
                              state: state, seconds: seconds, note: note))
            }
            done += job.files.count
        }
        if faces != nil { try store.rebuildFaceMatchesIfChanged() }
        return states
    }

    /// One step of the later pass: how far it has got (`done` of the `total` pages and chunks it set out to read, in
    /// `files` files), and the file it just read more of.
    public struct Step: Sendable {
        public let done: Int
        public let total: Int
        public let files: Int        // long files not finished yet, this one included until its last step
        public let path: String
        public let kind: FileKind
        public let state: String     // "partial" until the file's last step, then "done"
        public let seconds: Double
        public let note: String?
    }

    /// The later pass: reads the rest of long PDFs and documents (`partial` after their first step), in indexing order,
    /// a step at a time. Each step is saved as one transaction, so stopping between steps (pausing, new files going
    /// first) loses nothing, and the next pass goes on from there. It runs once nothing is pending: a book's last
    /// pages matter less than everything else's first ones, and they take a while (0.04–0.2 s a page, 2026-10-09).
    @discardableResult
    public func finishLongFiles(shouldStop: () -> Bool = { false }, onStep: (Step) -> Void = { _ in }) throws
        -> [String: Int] {
        var jobs: [Job] = []
        for file in try store.unfinished() {
            let info = try store.info(of: file.id)
            let size = file.kind == .pdf ? options.pdfStep : options.docStep
            // Where it stopped (after the last page or chunk stored, should its info not say; nothing stored: the start).
            var start = try info["read_to"].flatMap(Int.init) ?? store.lastPlace(of: file.id) ?? 0
            // At least one step, which settles a file whose length was only guessed (documents cut before schema 5).
            let end = max(info["read_end"].flatMap(Int.init) ?? 0, start + 1)
            while start < end {
                jobs.append(Job(files: [file], step: start..<min(start + size, end)))
                start += size
            }
        }
        // Progress counts pages and chunks: what's read once each job is through.
        var through: [Int] = []
        for job in jobs { through.append((through.last ?? 0) + (job.step?.count ?? 0)) }
        var files = Set(jobs.map { $0.files[0].id }).count
        var states: [String: Int] = [:]
        var finished = Set<Int64>()
        try process(jobs, shouldStop: shouldStop) { index, job, results, seconds in
            let file = job.files[0]
            let (state, note) = results[0]
            if state != "partial", finished.insert(file.id).inserted {
                states[state, default: 0] += 1
                files -= 1
            }
            onStep(Step(done: through[index], total: through.last ?? 0, files: files, path: file.path, kind: file.kind,
                        state: state, seconds: seconds, note: note))
        } skip: { job in
            // Finished sooner than its steps said: a document whose length was guessed, or a file that went unreadable.
            finished.contains(job.files[0].id)
        }
        return states
    }

    /// Runs `jobs` in order until `shouldStop` (asked between jobs), passing each one's results to `committed` (with
    /// its place in `jobs`). Jobs that `skip` turns down when their turn comes are left out.
    ///
    /// Two stages overlap: while the model embeds one job, the next one is read and decoded on another thread
    /// (images scaled, screenshots OCR'd, PDF pages rendered, audio and video decoded). OCR alone is ~0.24 s per Retina
    /// screenshot, about as long as embedding it.
    private func process(_ jobs: [Job], shouldStop: () -> Bool,
                         committed: (Int, Job, [(String, String?)], Double) -> Void,
                         skip: (Job) -> Bool = { _ in false }) throws {
        var ahead: PendingBatch?
        defer {
            // A job prepared for a run that stopped early: throw its files away.
            if let ahead { try? FileManager.default.removeItem(at: ahead.wait().folder) }
            if let costsFolder, !measured.tallies.isEmpty {
                MeasuredCosts.merge(measured, into: costsFolder)
                measured = MeasuredCosts()
            }
        }
        for (index, job) in jobs.enumerated() {
            guard !shouldStop() else { break }
            let started = Date()
            let prepared = (ahead ?? prepare(job)).wait()
            ahead = index + 1 < jobs.count ? prepare(jobs[index + 1]) : nil
            defer { try? FileManager.default.removeItem(at: prepared.folder) }
            guard !skip(job) else { continue }
            // The helper's and the CLI's main thread has no run loop to drain what Foundation autoreleases while a job
            // commits: without a pool per job it all stayed until the process exited (~30 KB a text chunk).
            let modelWasRunning = worker != nil
            let results = try autoreleasepool { try commit(prepared) }
            let seconds = Date().timeIntervalSince(started)
            if modelWasRunning { measure(prepared, seconds: seconds) }   // else it's seconds of the model starting
            committed(index, job, results, seconds / Double(job.files.count))
        }
    }

    /// What a job read and how long it took (its reading and its model's work, which overlap), for `MeasuredCosts`.
    private func measure(_ prepared: Prepared, seconds: Double) {
        switch prepared.payload {
        case .images(let screenshot, let ready):
            measured.add(screenshot ? "screenshot" : "image", units: Double(ready.count), seconds: seconds)
        case .pdf(let pages, _, _, _): measured.add("pdfPage", units: Double(pages.count), seconds: seconds)
        case .doc(let chunks, _, _, _):
            // Chunks with a vector: a data dump's go to keyword search only and take next to nothing, which isn't
            // what a chunk of prose costs (the estimate can't tell them apart from a file's size).
            let worded = chunks.filter(SearchText.hasWords).count
            if worded > 0 { measured.add("docChunk", units: Double(worded), seconds: seconds) }
        case .audio(_, let duration): measured.add("audioSecond", units: duration, seconds: seconds)
        case .video(_, _, let duration, _): measured.add("videoSecond", units: duration, seconds: seconds)
        case .code(let file): measured.add("codeStretch", units: Double(file.pieces.count), seconds: seconds)
        // A video in iCloud's stills are pictures, not seconds of video, which is what the estimate counts of one.
        case .nothing, .stills: break
        }
    }

    /// Files read and embedded together (images 8 at a time, other files one by one), or one step of a long file
    /// (`step`: the pages of a PDF or the chunks of a document to read, from 0). The first step comes with the file.
    /// `reading`: a library's video in iCloud, read from what Photos keeps of it (`PhotosLibrary.Reading.isStandIn`).
    /// `named`: the faces Photos names in its library pictures, by file (`namedFaces`).
    struct Job: Sendable {
        let files: [FileRecord]
        var step: Range<Int>?
        var reading: PhotosLibrary.Reading?
        var named: [Int64: [NamedFace]] = [:]
    }

    /// A face Photos named in a library picture: its person's row, and where it is.
    struct NamedFace: Sendable, Equatable {
        let person: Int64
        let box: PhotosLibrary.FaceBox

        /// How far each edge of a kept box may be from the box Photos' face converts to (`Faces.Box(_:width:height:)`)
        /// and still be that box, in fractions of the picture's sides: what rounding leaves. The kept box was converted
        /// from Photos' numbers too, in the picture as read for faces; the picture's shape here is the one a kept box
        /// gives exactly, else its pixels as indexed, which can differ from the picture read for faces (scaled to 2048
        /// pixels at most) by the rounding of its short side to whole pixels: half a pixel of 250 or more.
        static let sameBox = 0.002

        /// The index has these faces as Photos names them now: as many, and each one's person on a face kept whose box
        /// is the one Photos' converts to (`sameBox`), one face apiece. So Photos naming someone else in a picture,
        /// the same people on each other's faces, or a face's box moved, grown or shrunk, reads it again.
        static func areKept(_ named: [NamedFace], in kept: IndexStore.NamedFacesKept) -> Bool {
            guard named.count == kept.faces.count else { return false }
            // The picture's shape, width over height, as it was read upright: the one a kept box not cut at an edge
            // gives (Photos' face is a square, so its box's height over its width), else its pixels either way up.
            var shapes = kept.faces.compactMap { face -> Double? in
                let box = face.box
                return box.x > 0 && box.y > 0 && box.x + box.width < 1 && box.y + box.height < 1
                    ? box.height / box.width : nil
            }
            if let pixels = kept.pixels { shapes += [pixels.width / pixels.height, pixels.height / pixels.width] }
            func same(_ a: Faces.Box, _ b: Faces.Box) -> Bool {
                abs(a.x - b.x) <= sameBox && abs(a.y - b.y) <= sameBox
                    && abs(a.x + a.width - b.x - b.width) <= sameBox && abs(a.y + a.height - b.y - b.height) <= sameBox
            }
            var left = kept.faces
            for face in named {
                let boxes = shapes.compactMap { Faces.Box(face.box, width: $0, height: 1) }
                guard let found = left.firstIndex(where: { kept in
                    kept.person == face.person && boxes.contains { same($0, kept.box) }
                }) else { return false }
                left.remove(at: found)
            }
            return true
        }
    }

    /// Images and screenshots go to the model 8 at a time; other files one by one.
    static func batches(_ queue: [FileRecord]) -> [[FileRecord]] {
        var batches: [[FileRecord]] = []
        var index = 0
        while index < queue.count {
            var batch = [queue[index]]
            if batch[0].kind == .image || batch[0].kind == .screenshot {
                while index + batch.count < queue.count, batch.count < 8,
                      queue[index + batch.count].kind == batch[0].kind {
                    batch.append(queue[index + batch.count])
                }
            }
            batches.append(batch)
            index += batch.count
        }
        return batches
    }

    /// Compares the index with the current model and settings (`embedderSource`), without starting the model; a
    /// change empties the index (see `resetOnModelChange`) or throws `fingerprintMismatch`. Without a known source the
    /// check waits for the first file to embed.
    public func checkModel() throws {
        guard let embedderSource else { return }
        try adopt("\(embedderSource) | \(options.fingerprint)")
    }

    private func adopt(_ fingerprint: String) throws {
        guard let indexed = try store.meta("fingerprint"), indexed != fingerprint else { return }
        guard let resetOnModelChange else { throw IndexerError.fingerprintMismatch(index: indexed, now: fingerprint) }
        // Everything is queued again: a run that's under way goes on with its batch, and later runs take the rest.
        try store.resetAll()
        resetOnModelChange(indexed, fingerprint)
    }

    private func fullWorker() throws -> any Embedder {
        if let worker { return worker }
        let started = try makeEmbedder()
        let fingerprint = "\(started.info.vectorSource) | \(options.fingerprint)"
        do {
            try adopt(fingerprint)
        } catch {
            started.close()
            throw error
        }
        try store.setMeta("fingerprint", fingerprint)
        try store.setMeta("vector_source", started.info.vectorSource)
        worker = started
        return started
    }

    // MARK: Prepare (any thread: files only, no database, no model)

    /// A job read from disk and decoded, ready for the model. Its scratch files live in `folder`.
    struct Prepared: Sendable {
        let batch: [FileRecord]
        let step: Range<Int>?                // a long file's later step (`Job.step`)
        let folder: URL
        var outcomes: [Int: Outcome] = [:]   // files already settled (skipped or failed while reading)
        var payload = Payload.nothing
    }

    struct Outcome: Sendable {
        let state: String
        let detail: String?
    }

    enum Payload: Sendable {
        case nothing
        case images(screenshot: Bool, ready: [ReadyImage])
        /// `read`: the pages read (from 0) of the PDF's `total`.
        case pdf(pages: [PDFExtractor.Page], read: Range<Int>, total: Int, title: String?)
        /// `chunks`: the ones in `read` (from 0) of the document's `total` (counted up to `IndexOptions.maxChunks` + 1).
        case doc(chunks: [String], read: Range<Int>, total: Int, characters: Int)
        case audio(pieces: [MediaPiece], duration: Double)
        /// `location`: where it was taken, from its own metadata (none read for a Photos library's video).
        case video(frames: [MediaPiece], sound: [MediaPiece], duration: Double, location: Location?)
        /// A library's video in iCloud: Photos' stills of it, or its poster (`PhotosLibrary.Reading.isStandIn`), as
        /// pictures for the model.
        case stills([String])
        case code(CodeExtractor.File)
    }

    struct ReadyImage: Sendable {
        let slot: Int
        let image: ImageExtractor.Prepared
        /// An animated GIF's frames besides its first (`ImageExtractor.animationFrames`), each at its moment.
        let frames: [MediaPiece]
        let ocr: String
        /// `ocr` is what Photos read in the picture (`PhotosLibrary.RecognizedText`), not DigUp's OCR.
        var fromPhotos = false
        /// Its faces (`faces`), and how long reading them took; nil when they weren't read.
        var faces: (rows: [IndexStore.FaceRow], seconds: Double)? = nil
    }

    /// A batch being prepared on the preparation queue.
    final class PendingBatch: @unchecked Sendable {
        private let ready = DispatchSemaphore(value: 0)
        private var value: Prepared?

        fileprivate func fulfill(_ prepared: Prepared) {
            value = prepared
            ready.signal()
        }

        /// Blocks until it's ready. Call once.
        func wait() -> Prepared {
            ready.wait()
            return value!
        }
    }

    private let preparing = DispatchQueue(label: "DigUp.prepare", qos: .utility)
    private var jobsPrepared = 0   // names the scratch folders

    /// The file being read (extracted) right now, and since when: for a watchdog. Apple's frameworks have run away on
    /// some files (PDF text extraction growing by gigabytes a minute, never returning), and nothing stops them from
    /// outside but ending the process, so it has to know which file that was. One value for the whole process, since
    /// files are read one at a time.
    public static var nowReading: (path: String, since: Date)? { readingLock.withLock { reading } }
    nonisolated(unsafe) private static var reading: (path: String, since: Date)?
    private static let readingLock = NSLock()

    private static func startReading(_ path: String) {
        readingLock.withLock { reading = (path, Date()) }
    }

    private func prepare(_ job: Job) -> PendingBatch {
        let pending = PendingBatch()
        jobsPrepared += 1
        let (options, faces, folder) = (options, faces, scratch.appendingPathComponent("batch-\(jobsPrepared)"))
        preparing.async {
            pending.fulfill(Self.prepare(job, options: options, faces: faces, into: folder))
        }
        return pending
    }

    static func prepare(_ job: Job, options: IndexOptions, faces: (any FaceReader)?, into folder: URL) -> Prepared {
        let batch = job.files
        var prepared = Prepared(batch: batch, step: job.step, folder: folder)
        let url = URL(fileURLWithPath: batch[0].path)
        startReading(batch[0].path)
        defer { readingLock.withLock { reading = nil } }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            switch batch[0].kind {
            case .image, .screenshot:
                let screenshot = batch[0].kind == .screenshot
                var ready: [ReadyImage] = []
                var readings: [String: PhotosLibrary.RecognizedText] = [:]   // by library
                for (slot, file) in batch.enumerated() {
                    let url = URL(fileURLWithPath: file.path)
                    startReading(file.path)
                    do {
                        let maxPixel = screenshot ? 1536 : 1024
                        let image = try ImageExtractor.prepare(url, maxPixel: maxPixel, minSide: options.minImageSide,
                                                               to: folder, png: screenshot)
                        // An animated GIF: a few of its later frames too, each at the moment it's shown.
                        let frames = ImageExtractor.animationFrames(of: url, maxPixel: maxPixel, to: folder)
                        // A Photos library's picture has the words Photos read in it: a screenshot's are used instead
                        // of reading it again, and a photo gets them too. A screenshot Photos hasn't read is read here.
                        var read: String?
                        if let asset = PhotosLibrary.asset(ofFile: file.path) {
                            let reading = readings[asset.library] ?? PhotosLibrary.RecognizedText(library: asset.library)
                            readings[asset.library] = reading
                            read = reading.text(of: asset.uuid)
                        }
                        let ocr = read ?? (screenshot ? OCR.text(ofImageAt: url) : "")
                        var item = ReadyImage(slot: slot, image: image, frames: frames, ocr: ocr, fromPhotos: read != nil)
                        item.faces = faces.flatMap { Self.faces(of: file, named: job.named[file.id], with: $0) }
                        ready.append(item)
                    } catch let error as ExtractError {
                        if case .tooSmall = error {
                            prepared.outcomes[slot] = Outcome(state: "skipped", detail: "\(error)")
                        } else {
                            prepared.outcomes[slot] = Outcome(state: "failed", detail: "\(error)")
                        }
                    }
                }
                prepared.payload = .images(screenshot: screenshot, ready: ready)
            case .pdf:
                // Long PDFs (books) get their first pages now and the rest after everything else.
                var wanted = 0..<0
                let read = try PDFExtractor.pages(of: url, range: { total in
                    wanted = (job.step ?? (total > options.bigPDFPages ? 0..<options.pdfStep : 0..<options.maxPages))
                        .clamped(to: 0..<min(total, options.maxPages))
                    return wanted
                }, minText: options.minPageText, renderPixels: 1400, to: folder)
                prepared.payload = .pdf(pages: read.pages, read: wanted, total: read.total, title: read.title)
            case .doc:
                // The chunks are cut the same way every time, so a later step goes on where the last one stopped.
                let text = try DocExtractor.text(of: url)
                let chunks = DocExtractor.chunks(text, limit: options.maxChunks + 1)
                let read = (job.step ?? 0..<options.docStep).clamped(to: 0..<min(chunks.count, options.maxChunks))
                prepared.payload = .doc(chunks: Array(chunks[read]), read: read, total: chunks.count,
                                        characters: text.count)
            case .audio:
                let (window, hop) = (options.audioWindow, options.audioHop)
                let (pieces, duration) = try runBlocking {
                    try await AudioExtractor.windows(of: url, window: window, hop: hop, to: folder)
                }
                prepared.payload = .audio(pieces: pieces, duration: duration)
            case .video where job.reading?.isStandIn == true:
                // A library's video in iCloud: the stills of Photos' filmstrip of it, or its poster, each read whatever
                // its size (it's all this Mac has of the video).
                let stills = job.reading == .stills ? PhotosLibrary.filmstrip(startingAt: url.path) : [url.path]
                guard !stills.isEmpty else { throw ExtractError.unreadable("Photos' stills of it are gone") }
                prepared.payload = .stills(try stills.map {
                    try ImageExtractor.prepare(URL(fileURLWithPath: $0), maxPixel: 1024, minSide: 0, to: folder,
                                               png: false).path
                })
            case .video:
                let (interval, window, hop) = (options.frameInterval, options.audioWindow, options.audioHop)
                let (frames, duration, hasAudio) = try runBlocking {
                    try await VideoExtractor.keyframes(of: url, every: interval, maxPixel: 1024, to: folder)
                }
                let sound = hasAudio
                    ? try runBlocking { try await AudioExtractor.windows(of: url, window: window, hop: hop, to: folder) }
                        .pieces
                    : []
                // A library's video has Photos' location (the sync's), the one the user sees and can correct.
                let location = PhotosLibrary.library(containing: url.path) == nil
                    ? VideoExtractor.location(of: url) : nil
                prepared.payload = .video(frames: frames, sound: sound, duration: duration, location: location)
            case .code:
                prepared.payload = .code(try CodeExtractor.read(url, options: options))
            }
        } catch let error as ExtractError {
            if case .leftOut = error {
                prepared.outcomes[0] = Outcome(state: "skipped", detail: "\(error)")
            } else {
                for slot in batch.indices where prepared.outcomes[slot] == nil {
                    prepared.outcomes[slot] = Outcome(state: "failed", detail: "\(error)")
                }
            }
            prepared.payload = .nothing
        } catch {
            for slot in batch.indices where prepared.outcomes[slot] == nil {
                prepared.outcomes[slot] = Outcome(state: "failed", detail: "\(error)")
            }
            prepared.payload = .nothing
        }
        return prepared
    }

    // MARK: Commit (the indexing thread: the model and the database)

    private func commit(_ prepared: Prepared) throws -> [(String, String?)] {
        let batch = prepared.batch
        let later = prepared.step != nil
        if let step = prepared.step, let outcome = prepared.outcomes[0] {
            return [try stopReading(batch[0], at: step.lowerBound, because: outcome.detail ?? outcome.state)]
        }
        var results = [(String, String?)](repeating: ("failed", nil), count: batch.count)
        for (slot, outcome) in prepared.outcomes {
            try store.finish(batch[slot].id, state: outcome.state, detail: outcome.detail)
            results[slot] = (outcome.state, outcome.detail)
        }
        do {
            switch prepared.payload {
            case .nothing:
                break
            case .images(let screenshot, let ready):
                try images(batch, screenshot: screenshot, ready: ready, results: &results)
            case .pdf(let pages, let read, let total, let title):
                results[0] = try pdf(batch[0], pages: pages, read: read, total: total, title: title, later: later)
            case .doc(let chunks, let read, let total, let characters):
                results[0] = try doc(batch[0], chunks: chunks, read: read, total: total, characters: characters,
                                     later: later)
            case .audio(let pieces, let duration):
                results[0] = try audio(batch[0], pieces: pieces, duration: duration)
            case .video(let frames, let sound, let duration, let location):
                results[0] = try video(batch[0], frames: frames, sound: sound, duration: duration, location: location)
            case .stills(let stills):
                results[0] = try self.stills(batch[0], stills)
            case .code(let code):
                results[0] = try self.code(batch[0], code)
            }
        } catch let error as WorkerError {
            throw error
        } catch let error as IndexerError {
            throw error
        } catch {
            if let step = prepared.step { return [try stopReading(batch[0], at: step.lowerBound, because: "\(error)")] }
            for (slot, file) in batch.enumerated() where prepared.outcomes[slot] == nil {
                try store.finish(file.id, state: "failed", detail: "\(error)")
                results[slot] = ("failed", "\(error)")
            }
        }
        return results
    }

    /// A long file that can't be read any further: it keeps the pages or chunks read so far, which stay searchable,
    /// and counts as done rather than failed or waiting to be tried again and again.
    private func stopReading(_ file: FileRecord, at place: Int, because problem: String) throws -> (String, String?) {
        var info = try store.info(of: file.id)
        info["read_to"] = nil
        info["read_end"] = nil
        let unit = file.kind == .pdf ? "page" : "chunk"
        try store.finish(file.id, state: "done", detail: "read to \(unit) \(place), not after: \(problem)", info: info)
        return ("done", "stopped before \(unit) \(place + 1): \(problem)")
    }

    private func images(_ batch: [FileRecord], screenshot: Bool, ready: [ReadyImage],
                        results: inout [(String, String?)]) throws {
        guard !ready.isEmpty else { return }
        let worker = try fullWorker()
        let vectors = try worker.embedImages(ready.map(\.image.path),
                                             budget: screenshot ? options.screenshotBudget : options.photoBudget)
        // An animated GIF's later frames are frames, as a video's are: each its own vector, at its moment.
        let frames = ready.flatMap(\.frames)
        var frameVectors = frames.isEmpty ? []
            : try worker.embedImages(frames.map(\.path), budget: options.frameBudget)[...]
        try store.db.transaction {
            for (position, item) in ready.enumerated() {
                let file = batch[item.slot]
                let itsFrames = zip(item.frames, frameVectors.prefix(item.frames.count))
                frameVectors = frameVectors.dropFirst(item.frames.count)
                guard let vector = vectors[position].vector else {
                    try store.finish(file.id, state: "failed", detail: vectors[position].error)
                    results[item.slot] = ("failed", vectors[position].error)
                    continue
                }
                let picture = try store.addSegment(file: file.id, kind: .image, modality: .image, vector: vector)
                if let faces = item.faces { try keep(faces.rows, ofSegment: picture, of: file.id) }
                for (frame, embedding) in itsFrames {
                    try store.addSegment(file: file.id, kind: .frame, modality: .image, loc: frame.start,
                                         locEnd: frame.end, vector: embedding.vector)
                }
                // The words on screen, or the ones Photos read in a picture, are for keyword search: codes, names and
                // errors typed exactly. Meaning comes from the picture alone; a vector of the words made screenshots
                // outrank better matches (2026-10-08).
                if !item.ocr.isEmpty {
                    try store.addSegment(file: file.id, kind: .ocr, modality: .text, excerpt: excerpt(item.ocr),
                                         text: item.ocr)
                }
                var info = ["width": "\(item.image.width)", "height": "\(item.image.height)"]
                if let taken = item.image.taken { info["taken"] = taken }
                if screenshot { info["ocr_chars"] = "\(item.ocr.count)" }
                try store.finish(file.id, state: "done", info: info)
                // Where its GPS tags say it was taken. A library's picture has Photos' location instead (the sync's),
                // the one the user sees and can correct.
                if let location = item.image.location, PhotosLibrary.library(containing: file.path) == nil {
                    try store.setLocation(location, of: file.id)
                }
                let words = item.fromPhotos ? (screenshot || !item.ocr.isEmpty ? "Photos' text \(item.ocr.count) chars" : nil)
                    : screenshot ? "ocr \(item.ocr.count) chars" : nil
                let seen = item.faces.map { Self.facesNote($0.rows.count, seconds: $0.seconds) }
                let notes = [words, seen].compactMap { $0 }
                results[item.slot] = ("done", notes.isEmpty ? nil : notes.joined(separator: ", "))
            }
        }
    }

    /// Writes the faces read in a picture (inside the caller's transaction), and matches the ones outside Photos as the
    /// run found the named faces when it first needed them, and the corrections as they are (`matching`, made again
    /// when they were saved since: `IndexStore.faceMatching(_:)`).
    private func keep(_ rows: [IndexStore.FaceRow], ofSegment segment: Int64, of file: Int64) throws {
        let outside = Self.outside(rows, written: try store.setFaces(rows, ofSegment: segment), of: file)
        guard !outside.isEmpty else { return }
        let matching = try store.faceMatching(self.matching)
        self.matching = matching
        try store.matchFaces(outside, with: matching)
    }

    /// The faces outside Photos among `rows`, just written as the rows `ids`, in the picture that's `file`: to match.
    private static func outside(_ rows: [IndexStore.FaceRow], written ids: [Int64], of file: Int64)
        -> [FaceMatching.Face] {
        zip(ids, rows).filter { $0.1.person == nil }.map { id, row in
            FaceMatching.Face(id: id, file: file, box: row.box, print: row.print)
        }
    }

    /// "2 faces in 31 ms": what reading a picture's faces found, and took.
    static func facesNote(_ count: Int, seconds: Double) -> String {
        "\(count) \(count == 1 ? "face" : "faces") in \(Int((seconds * 1000).rounded())) ms"
    }

    /// Pages `read` of a PDF (all of a short one, a step of a long one). A long one stays `partial` with `read_to` and
    /// `read_end` (pages, from 0) in its info until its last step.
    private func pdf(_ file: FileRecord, pages: [PDFExtractor.Page], read: Range<Int>, total: Int, title: String?,
                     later: Bool) throws -> (String, String?) {
        let end = min(total, options.maxPages)
        let unread = read.upperBound < end
        guard !pages.isEmpty || later || unread else {
            try store.finish(file.id, state: "skipped", detail: "no pages")
            return ("skipped", "no pages")
        }
        let title = title ?? URL(fileURLWithPath: file.path).deletingPathExtension().lastPathComponent
        let textPages = pages.filter { $0.imagePath == nil }
        // A page that's mostly digits (a table, a data listing) gets keyword search only.
        let wordPages = textPages.filter { SearchText.hasWords($0.text) }
        let imagePages = pages.filter { $0.imagePath != nil }
        let garbledPages = pages.filter { $0.garbled != nil }   // rendered too: among `imagePages`
        var textVectors: [Int: [Float]] = [:]   // by page number
        var imageVectors: [Embedding] = []
        var garbledVectors: [[Float]] = []
        if !wordPages.isEmpty || !imagePages.isEmpty {
            let worker = try fullWorker()
            let vectors = try worker.embedTexts(wordPages.map {
                Prompts.document(title: title, text: String($0.text.prefix(4000)))
            })
            textVectors = Dictionary(uniqueKeysWithValues: zip(wordPages.map(\.number), vectors))
            imageVectors = try worker.embedImages(imagePages.compactMap(\.imagePath), budget: options.pageBudget)
            garbledVectors = try worker.embedTexts(garbledPages.map {
                Prompts.document(title: title, text: String($0.garbled!.prefix(4000)))
            })
        }
        try store.db.transaction {
            // Meaning only: the garbled words are never shown or matched against what you type.
            for (page, vector) in zip(garbledPages, garbledVectors) {
                try store.addSegment(file: file.id, kind: .page, modality: .text, loc: Double(page.number), vector: vector)
            }
            for page in textPages {
                try store.addSegment(file: file.id, kind: .page, modality: .text, loc: Double(page.number),
                                     excerpt: excerpt(page.text), text: page.text, vector: textVectors[page.number])
            }
            for (page, embedding) in zip(imagePages, imageVectors) {
                try store.addSegment(file: file.id, kind: .pageImage, modality: .image, loc: Double(page.number),
                                     excerpt: page.text.isEmpty ? nil : excerpt(page.text), text: page.text,
                                     vector: embedding.vector)
            }
            var info = later ? try store.info(of: file.id) : [:]
            info["pages"] = "\(total)"
            info["scanned_pages"] = "\((info["scanned_pages"].flatMap(Int.init) ?? 0) + imagePages.count)"
            info["read_to"] = unread ? "\(read.upperBound)" : nil
            info["read_end"] = unread ? "\(end)" : nil
            let detail = unread ? "read to page \(read.upperBound) of \(total)"
                : end < total ? "the first \(end) of \(total) pages" : nil
            try store.finish(file.id, state: unread ? "partial" : "done", detail: detail, info: info)
        }
        let ocr = pages.filter(\.ocr).count
        let span = later ? "pages \(read.lowerBound + 1)–\(read.upperBound) of \(total)" : "\(pages.count)/\(total) pages"
        return (unread ? "partial" : "done", "\(span), \(imagePages.count) as images" + (ocr > 0 ? ", \(ocr) read by OCR" : ""))
    }

    /// Chunks `read` of a document (all of a short one, a step of a long one), the way `pdf` reads pages.
    private func doc(_ file: FileRecord, chunks: [String], read: Range<Int>, total: Int, characters: Int, later: Bool)
        throws -> (String, String?) {
        guard total > 0 else {
            try store.finish(file.id, state: "skipped", detail: "no text")
            return ("skipped", "no text")
        }
        let title = URL(fileURLWithPath: file.path).deletingPathExtension().lastPathComponent
        // Text that's mostly digits (a data dump saved as .txt) gets keyword search only.
        let worded = chunks.indices.filter { SearchText.hasWords(chunks[$0]) }
        let vectors = worded.isEmpty ? [] : try fullWorker().embedTexts(worded.map {
            Prompts.document(title: title, text: chunks[$0])
        })
        let vector = Dictionary(uniqueKeysWithValues: zip(worded, vectors))
        let end = min(total, options.maxChunks)
        let unread = read.upperBound < end
        try store.db.transaction {
            for (offset, chunk) in chunks.enumerated() {
                try store.addSegment(file: file.id, kind: .chunk, modality: .text,
                                     loc: Double(read.lowerBound + offset + 1), excerpt: excerpt(chunk), text: chunk,
                                     vector: vector[offset])
            }
            var info = ["chunks": "\(end)", "chars": "\(characters)"]
            info["read_to"] = unread ? "\(read.upperBound)" : nil
            info["read_end"] = unread ? "\(end)" : nil
            let detail = unread ? "read to chunk \(read.upperBound) of \(end)" : end < total ? "the first \(end) chunks" : nil
            try store.finish(file.id, state: unread ? "partial" : "done", detail: detail, info: info)
        }
        let span = later ? "chunks \(read.lowerBound + 1)–\(read.upperBound) of \(end)"
            : unread ? "\(chunks.count) of \(end) chunks" : "\(chunks.count) chunks"
        return (unread ? "partial" : "done",
                span + (worded.count < chunks.count ? ", \(chunks.count - worded.count) for keywords only" : ""))
    }

    /// A code file's stretches of lines (a notebook's of cells), each embedded with the file's path in its repo as its
    /// title, and kept with its lines for keyword search and for opening at the place.
    private func code(_ file: FileRecord, _ code: CodeExtractor.File) throws -> (String, String?) {
        guard !code.pieces.isEmpty else {
            try store.finish(file.id, state: "skipped", detail: "no code")
            return ("skipped", "no code")
        }
        // Lines that are mostly numbers and symbols (a table of constants) get keyword search only.
        let worded = code.pieces.indices.filter { SearchText.hasWords(code.pieces[$0].text) }
        let vectors = worded.isEmpty ? [] : try fullWorker().embedTexts(worded.map {
            Prompts.document(title: code.title, text: code.pieces[$0].text)
        })
        let vector = Dictionary(uniqueKeysWithValues: zip(worded, vectors))
        try store.db.transaction {
            for (offset, piece) in code.pieces.enumerated() {
                try store.addSegment(file: file.id, kind: code.cells == nil ? .lines : .cells, modality: .text,
                                     loc: Double(piece.first), locEnd: Double(piece.last),
                                     excerpt: CodeExtractor.summary(piece.text), text: piece.text, vector: vector[offset])
            }
            var info = ["lines": "\(code.lines)"]
            info["cells"] = code.cells.map(String.init)
            info["repo"] = code.repo
            try store.finish(file.id, state: "done", info: info)
        }
        return ("done", "\(code.pieces.count) stretches, \(code.cells.map { "\($0) cells" } ?? "\(code.lines) lines")"
                + (worded.count < code.pieces.count ? ", \(code.pieces.count - worded.count) for keywords only" : ""))
    }

    private func audio(_ file: FileRecord, pieces: [MediaPiece], duration: Double) throws -> (String, String?) {
        guard !pieces.isEmpty else {
            try store.finish(file.id, state: "skipped", detail: "silent or shorter than 2 s")
            return ("skipped", "silent or too short")
        }
        let vectors = try fullWorker().embedAudio(pieces.map(\.path))
        try store.db.transaction {
            for (piece, embedding) in zip(pieces, vectors) {
                try store.addSegment(file: file.id, kind: .audio, modality: .audio, loc: piece.start, locEnd: piece.end,
                                     vector: embedding.vector)
            }
            try store.finish(file.id, state: "done", info: ["duration": String(format: "%.1f", duration)])
        }
        return ("done", "\(pieces.count) windows, \(Int(duration)) s")
    }

    private func video(_ file: FileRecord, frames: [MediaPiece], sound: [MediaPiece], duration: Double,
                       location: Location?) throws -> (String, String?) {
        guard !frames.isEmpty || !sound.isEmpty else {
            try store.finish(file.id, state: "skipped", detail: "no frames or sound")
            return ("skipped", "no frames or sound")
        }
        let worker = try fullWorker()
        let frameVectors = try worker.embedImages(frames.map(\.path), budget: options.frameBudget)
        let soundVectors = try worker.embedAudio(sound.map(\.path))
        try store.db.transaction {
            for (frame, embedding) in zip(frames, frameVectors) {
                try store.addSegment(file: file.id, kind: .frame, modality: .image, loc: frame.start,
                                     locEnd: frame.end, vector: embedding.vector)
            }
            for (piece, embedding) in zip(sound, soundVectors) {
                try store.addSegment(file: file.id, kind: .audio, modality: .audio, loc: piece.start,
                                     locEnd: piece.end, vector: embedding.vector)
            }
            try store.finish(file.id, state: "done", info: ["duration": String(format: "%.1f", duration),
                                                            "frames": "\(frames.count)", "sound_windows": "\(sound.count)"])
            if let location { try store.setLocation(location, of: file.id) }
        }
        return ("done", "\(frames.count) frames, \(sound.count) sound windows, \(Int(duration)) s")
    }

    /// A library's video in iCloud, from what Photos keeps of it (`PhotosLibrary.Reading.isStandIn`): each still a frame
    /// with its own vector and no time, which the stills don't carry (a guessed one would be a made-up fact). The frames
    /// are written in the filmstrip's order, which is how a hit knows the still it's on (`PhotosHit.still`). Its place
    /// is Photos' (the sync's).
    private func stills(_ file: FileRecord, _ stills: [String]) throws -> (String, String?) {
        let vectors = try fullWorker().embedImages(stills, budget: options.frameBudget)
        try store.db.transaction {
            for embedding in vectors {
                try store.addSegment(file: file.id, kind: .frame, modality: .image, vector: embedding.vector)
            }
            try store.finish(file.id, state: "done", info: ["frames": "\(stills.count)"])
        }
        return ("done", "\(stills.count) of Photos' stills (the video is in iCloud)")
    }

    // MARK: Faces

    /// The faces of a picture to keep, read with `reader`, and how long that took: in a Photos library the ones Photos
    /// names in it (`named`), each with its person, elsewhere every one found. Nil for a library picture in which Photos
    /// names none, or whose listing doesn't say: there's nothing to read. A picture that can't be read has no faces.
    static func faces(of file: FileRecord, named: [NamedFace]?, with reader: any FaceReader)
        -> (rows: [IndexStore.FaceRow], seconds: Double)? {
        let given = PhotosLibrary.library(containing: file.path) == nil ? nil : named ?? []
        guard given?.isEmpty != true else { return nil }
        let started = Date()
        let found = (try? reader.faces(inPictureAt: URL(fileURLWithPath: file.path), named: given?.map(\.box))) ?? []
        let rows = found.map { face in
            IndexStore.FaceRow(box: face.box, print: face.print, person: face.named.flatMap { given?[$0].person })
        }
        return (rows, Date().timeIntervalSince(started))
    }

    /// A picture's faces as the faces pass reads them (`faces(of:named:with:)`; none for a library picture in which
    /// Photos names none now), the watchdog told which file is being read. Nil when it's away: gone, on a drive that's
    /// unplugged, or only in iCloud, where reading it would download it.
    private static func facesHere(of file: FileRecord, named: [NamedFace]?, with reader: any FaceReader)
        -> [IndexStore.FaceRow]? {
        guard let info = FileSystem.info(of: file.path), info.isRegular, !info.dataless else { return nil }
        startReading(file.path)
        defer { readingLock.withLock { reading = nil } }
        return autoreleasepool { faces(of: file, named: named, with: reader)?.rows ?? [] }
    }

    /// One step of the faces pass: `done` of the `total` pictures it set out to read, and the one it just read: how
    /// many faces it kept of it (nil: it was away, and waits for a later pass).
    public struct FacesStep: Sendable {
        public let done: Int
        public let total: Int
        public let path: String
        public let kind: FileKind
        public let faces: Int?
        public let seconds: Double
    }

    /// What the faces pass has to read: the library pictures whose named faces in the index aren't the ones Photos
    /// names now (as the last sync listed them: who, and on which face), unless it read them for those in this process
    /// already; and the pictures outside Photos it hasn't come to, or that were away when it did
    /// (`IndexStore.FacesRead`), unless it found them away in this process. Nil without a face reader.
    private func facesToRead() throws
        -> (named: [IndexStore.FacesToRead], outside: [IndexStore.FacesToRead], read: IndexStore.FacesRead)? {
        guard faces != nil else { return nil }
        let stored = try store.namedFaces()
        let differ = namedFaces.compactMap { file, named -> Int64? in
            !NamedFace.areKept(named, in: stored[file] ?? IndexStore.NamedFacesKept()) && triedNamed[file] != named
                ? file : nil
        }
        let read = try store.facesRead()
        let outside = try store.picturesOutsideWithoutFaces(read).filter { !triedAway.contains($0.file.id) }
        return (try store.readPictures(differ), outside, read)
    }

    /// How many pictures the faces pass has to read now (`readFaces`): none without a face reader.
    public func facesWaiting() throws -> Int {
        guard let work = try facesToRead() else { return 0 }
        return work.named.count + work.outside.count
    }

    /// The faces pass: the faces of pictures read before DigUp kept faces, or before the recognizer changed (which took
    /// them all), read again from the pictures with nothing embedded. First the library pictures whose named faces
    /// aren't the ones Photos names now (the last sync's listing: someone named in Photos since, or no longer, or on
    /// another face), then `face_matches` made again if they changed, then the pictures outside Photos it hasn't come
    /// to, each matched as it's read, and `face_matches` made again at the end if a face you said is someone was among
    /// them (it teaches: the faces read before it weren't compared with it). A picture that's away (gone, on a drive
    /// that's unplugged, or only in iCloud, where reading it would download it) waits for a later pass. Each picture is
    /// one transaction, so stopping between them (`shouldStop`) loses nothing. Returns how many pictures it read.
    @discardableResult
    public func readFaces(shouldStop: () -> Bool = { false }, onStep: (FacesStep) -> Void = { _ in }) throws -> Int {
        guard let reader = faces, let work = try facesToRead() else { return 0 }
        let total = work.named.count + work.outside.count
        var (done, count) = (0, 0)
        func report(_ picture: IndexStore.FacesToRead, _ rows: [IndexStore.FaceRow]?, since started: Date) {
            done += 1
            if rows != nil { count += 1 }
            onStep(FacesStep(done: done, total: total, path: picture.file.path, kind: picture.file.kind,
                             faces: rows?.count, seconds: Date().timeIntervalSince(started)))
        }
        for picture in work.named {
            guard !shouldStop() else { break }
            let named = namedFaces[picture.file.id] ?? []
            triedNamed[picture.file.id] = named
            let started = Date()
            let rows = Self.facesHere(of: picture.file, named: named, with: reader)
            if let rows { try store.db.transaction { try store.setFaces(rows, ofSegment: picture.segment) } }
            report(picture, rows, since: started)
        }
        try store.rebuildFaceMatchesIfChanged()
        var matching = try store.faceMatching()
        var read = work.read, finished = true
        for picture in work.outside {
            guard !shouldStop() else {
                finished = false
                break
            }
            let started = Date()
            let rows = Self.facesHere(of: picture.file, named: nil, with: reader)
            let id = picture.file.id
            read.after = max(read.after, id)
            read.away.removeAll { $0 == id }
            if rows == nil {
                read.away.append(id)
                triedAway.insert(id)
            }
            try store.db.transaction {
                if let rows {
                    let ids = try store.setFaces(rows, ofSegment: picture.segment)
                    matching = try store.faceMatching(matching)   // corrections saved since: as they are now
                    try store.matchFaces(Self.outside(rows, written: ids, of: id), with: matching)
                }
                try store.setFacesRead(read)
            }
            report(picture, rows, since: started)
        }
        // Every picture up to `to` was come to: the ones not on the list had faces, or weren't read yet (they're read
        // with their faces).
        if finished, read.after < read.to {
            read.after = read.to
            try store.setFacesRead(read)
        }
        try store.rebuildFaceMatchesIfChanged()
        return count
    }
}
