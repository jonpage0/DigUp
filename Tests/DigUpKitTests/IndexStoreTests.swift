#if canImport(CryptoKit)
import CryptoKit
#endif
import Foundation
import Testing
@testable import DigUpKit
#if os(Windows)
import WinSDK
#endif

@Suite struct IndexStoreTests {
    let folder: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DigUpTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    func file(_ path: String, inode: UInt64) -> Candidate {
        Candidate(path: path, kind: .image, size: 10, mtime: 1, inode: inode, device: 1)
    }

    @Test func pruneKeepsOnlyChosenFolders() throws {
        let store = try IndexStore(directory: folder)
        try store.insert(file("/a/x.png", inode: 1))
        try store.insert(file("/a/sub/y.png", inode: 2))
        try store.insert(file("/ab/z.png", inode: 3))   // a sibling whose name starts like "/a", not inside it
        try store.insert(file("/b/w.png", inode: 4))
        #expect(try store.prune(keepingUnder: ["/a"]) == 2)
        #expect(try store.files(under: ["/a"]).count == 2)
        #expect(try store.files(under: ["/ab", "/b"]).isEmpty)
        var keywordRows = 0
        try store.db.query("SELECT COUNT(*) FROM fts") { keywordRows = Int($0.int(0)) }
        #expect(keywordRows == 2)   // the pruned files' names left keyword search too
        #expect(try store.prune(keepingUnder: []) == 2)
    }

    @Test func scopeLimitsWhatIsWaiting() throws {
        let store = try IndexStore(directory: folder)
        try store.insert(file("/a/x.png", inode: 1))
        try store.insert(file("/drive/y.png", inode: 2))   // on a drive that's unplugged
        store.scope = ["/a"]
        #expect(try store.pendingCount() == 1)
        #expect(try store.pending(limit: nil).map(\.path) == ["/a/x.png"])
        #expect(try store.counts().byKindAndState["image"]?["pending"] == 1)
        store.scope = []
        #expect(try store.pendingCount() == 0)
        store.scope = nil
        #expect(try store.pendingCount() == 2)
    }

    @Test func aFileTheHelperStoppedOnIsNotReadAgain() throws {
        let store = try IndexStore(directory: folder)
        try store.insert(file("/a/stuck.pdf", inode: 1))
        let book = try store.insert(file("/a/book.pdf", inode: 2))
        try store.finish(book, state: "partial", info: ["read_to": "30", "read_end": "463"])
        #expect(try store.markStopped("/a/stuck.pdf", why: "took more than 15 minutes to read"))
        #expect(try store.markStopped("/a/book.pdf", why: "took more than 15 minutes to read"))
        #expect(try !store.markStopped("/a/gone.pdf", why: "took more than 15 minutes to read"))
        #expect(try store.pendingCount() == 0)
        #expect(try store.unfinishedCount().files == 0)   // the book keeps its first pages and isn't finished again
        let states = Dictionary(uniqueKeysWithValues: try store.files(under: ["/a"]).map { ($0.path, $0.state) })
        #expect(states == ["/a/stuck.pdf": "failed", "/a/book.pdf": "done"])
    }

    #if canImport(AppKit)
    @Test func picturesThatCouldntBeReadAreReadOnceMore() throws {
        // An SVG skipped by an older DigUp as "small image 0×0" (ImageIO couldn't open it): AppKit draws it now.
        let store = try IndexStore(directory: folder)
        let svg = try store.insert(file("/a/chart.svg", inode: 1))
        try store.finish(svg, state: "skipped", detail: "small image 0×0")
        let icon = try store.insert(file("/a/icon.png", inode: 2))
        try store.finish(icon, state: "skipped", detail: "small image 160×160")   // small, and rightly skipped
        #expect(try store.readAgainOnce(readsSpeech: false) == 1)
        #expect(try store.pending(limit: nil).map(\.path) == ["/a/chart.svg"])
        #expect(try store.readAgainOnce(readsSpeech: false) == 0)
    }

    @Test func gifsReadBeforeTheirFramesWereAreReadOnceMore() throws {
        // GIFs read by an older DigUp, which read only their first frame: read again for their later frames, once.
        let store = try IndexStore(directory: folder)
        let dance = try store.insert(file("/a/dance.GIF", inode: 1))
        try store.addSegment(file: dance, kind: .image, modality: .image, vector: FakeEmbedder.vector(for: "dance"))
        try store.finish(dance, state: "done")
        let framed = try store.insert(file("/a/framed.gif", inode: 2))   // read since: it has its frames
        try store.addSegment(file: framed, kind: .frame, modality: .image, loc: 0.1,
                             vector: FakeEmbedder.vector(for: "framed"))
        try store.finish(framed, state: "done")
        try store.finish(try store.insert(file("/a/icon.gif", inode: 3)), state: "skipped", detail: "small image 64×64")
        try store.finish(try store.insert(file("/a/photo.png", inode: 4)), state: "done")
        #expect(try store.readAgainOnce(readsSpeech: false) == 1)
        #expect(try store.pending(limit: nil).map(\.path) == ["/a/dance.GIF"])
        var images = 0
        try store.db.query("SELECT COUNT(*) FROM segments WHERE file = ? AND kind = 'image'", [.int(dance)]) {
            images = Int($0.int(0))
        }
        #expect(images == 0)   // what was read of it goes until it's read again
        try store.finish(dance, state: "done")
        #expect(try store.readAgainOnce(readsSpeech: false) == 0)
    }
    #endif

    @Test func recordingsReadBeforeWhatsSaidInThemWasAreReadOnceMore() throws {
        // Read by a DigUp without parakeet-mlx: an audio file and a video, read again once it's here, once. Not one read
        // with it (nothing said in it, or why it couldn't be read), a Photos video in iCloud (read from Photos' stills:
        // its sound isn't here), or a picture.
        let store = try IndexStore(directory: folder)
        func recording(_ path: String, _ kind: FileKind, inode: UInt64, info: [String: String]) throws -> Int64 {
            let id = try store.insert(Candidate(path: path, kind: kind, size: 10, mtime: 1, inode: inode, device: 1))
            try store.finish(id, state: "done", info: info)
            return id
        }
        let talk = try recording("/a/talk.m4a", .audio, inode: 1, info: ["duration": "61.0"])
        let clip = try recording("/a/clip.mov", .video, inode: 2, info: ["duration": "12.5", "frames": "4"])
        _ = try recording("/a/song.m4a", .audio, inode: 3, info: ["duration": "200.0", IndexStore.speechInfo: "0"])
        _ = try recording("/a/hum.m4a", .audio, inode: 4,
                          info: ["duration": "9.0", IndexStore.speechProblemInfo: "parakeet-mlx took too long"])
        let inCloud = try recording("/a/L.photoslibrary/resources/derivatives/cvt/F/FC37DBA6-CF22-4E3E-AB70-755587454608"
                                    + "_cvt_t0000.jpeg", .video, inode: 5, info: ["frames": "6"])
        try store.db.run("INSERT INTO photos_assets(file, favorite, reading, origin) VALUES(?, 0, 'stills', 'camera')",
                         [.int(inCloud)])
        try store.finish(try store.insert(file("/a/photo.png", inode: 6)), state: "done")
        #expect(Dictionary(uniqueKeysWithValues: try store.recordingsWithoutSpeech().map { ($0.id, $0.seconds) })
                == [talk: 61, clip: 12.5])
        #expect(try store.readAgainOnce(readsSpeech: false) == 0)   // no parakeet-mlx yet: nothing, and no mark
        #expect(try store.meta(IndexStore.speechReadKey) == nil)
        #expect(try store.readAgainOnce(readsSpeech: true) == 2)
        #expect(Set(try store.pending(limit: nil).map(\.id)) == [talk, clip])
        try store.finish(talk, state: "done")   // read again, as if parakeet-mlx had gone meanwhile
        #expect(try store.readAgainOnce(readsSpeech: true) == 0)
    }

    @Test func theForksTablesAreAddedOnceAndTheSchemaStaysUpstreams() throws {
        let fork: Set = ["locations", "photos_people", "photos_person_files", "photos_person_files_file",
                         "photos_albums", "photos_album_files", "photos_album_files_file", "photos_assets",
                         "sensitive_scores", "media_dimensions", "faces", "faces_segment", "faces_person",
                         "face_matches"]
        func check(_ store: IndexStore) throws {
            var names = Set<String>(), version: Int64 = 0
            try store.db.query("SELECT name FROM sqlite_master") { names.insert($0.text(0) ?? "") }
            try store.db.query("PRAGMA user_version") { version = $0.int(0) }
            #expect(fork.isSubset(of: names))
            #expect(try store.meta("fork_photos_facts") == "\(IndexStore.forkFactsVersion)")
            #expect(version == 5)
        }
        try check(try IndexStore(directory: folder))
        // An index upstream's DigUp made, or kept on with: schema 5 without the fork's tables. They're added.
        let upstream = try IndexStore(directory: folder)
        try upstream.db.execute("""
            DROP TABLE locations; DROP TABLE photos_person_files; DROP TABLE photos_people;
            DROP TABLE photos_album_files; DROP TABLE photos_albums; DROP TABLE photos_assets;
            DROP TABLE sensitive_scores; DROP TABLE media_dimensions; DROP TABLE face_matches; DROP TABLE faces;
            DELETE FROM meta WHERE key = 'fork_photos_facts';
            """)
        let reopened = try IndexStore(directory: folder)
        try check(reopened)
        // Opened again: nothing made again, nothing lost.
        let id = try reopened.insert(file("/a/x.jpg", inode: 1))
        try reopened.setLocation(try #require(Location(latitude: 25.79, longitude: -80.13, source: .exif)), of: id)
        let again = try IndexStore(directory: folder)
        try check(again)
        #expect(try again.locations(of: ["/a/x.jpg"]).count == 1)
    }

    /// An index the fork stepped to 3 (sensitive_scores: the installed app's) or to 4 (media_dimensions) gets the faces
    /// tables at step 5, keeping what it had; and what the faces step makes is what an index made now has.
    @Test func indexesAtForkSteps3And4GetTheFacesTables() throws {
        func schema(_ store: IndexStore, of tables: [String]) throws -> [String] {
            var sql: [String] = []
            let names = tables.map { "'\($0)'" }.joined(separator: ",")
            try store.db.query("SELECT sql FROM sqlite_master WHERE name IN (\(names)) ORDER BY name") {
                sql.append($0.text(0) ?? "")
            }
            return sql
        }
        let faces = ["faces", "faces_segment", "faces_person", "face_matches"]
        let made = try schema(try IndexStore(directory: folder.appendingPathComponent("now")), of: faces)
        #expect(made.count == 4 && made.contains { $0.contains("confirmed INTEGER NOT NULL DEFAULT 0") })
        for step in [3, 4] {
            let index = folder.appendingPathComponent("step\(step)")
            let first = try IndexStore(directory: index)
            let id = try first.insert(file("/a/x\(step).jpg", inode: UInt64(step)))
            try first.setLocation(try #require(Location(latitude: 25.79, longitude: -80.13, source: .exif)), of: id)
            try first.db.execute("""
                DROP TABLE face_matches; DROP TABLE faces;\(step == 3 ? " DROP TABLE media_dimensions;" : "")
                UPDATE meta SET value = '\(step)' WHERE key = 'fork_photos_facts';
                """)
            #expect(try schema(first, of: faces).isEmpty)
            let stepped = try IndexStore(directory: index)
            #expect(try stepped.meta("fork_photos_facts") == "5" && IndexStore.forkFactsVersion == 5)
            #expect(try schema(stepped, of: faces) == made)
            #expect(try schema(stepped, of: ["media_dimensions", "sensitive_scores"]).count == 2)
            #expect(try stepped.locations(of: ["/a/x\(step).jpg"]).count == 1)
        }
    }

    #if canImport(ImageIO)
    @Test func aPicturesOwnLocationGoesWhenItsReadAgain() throws {
        let base = URL(fileURLWithPath: FolderSelection.realPath(folder.path))
        let pictures = base.appendingPathComponent("pictures")
        try FileManager.default.createDirectory(at: pictures, withIntermediateDirectories: true)
        let beach = pictures.appendingPathComponent("beach.jpg")
        try ImageTests.writeJPEG(beach, at: (25.7907, -80.13))
        let store = try IndexStore(directory: base.appendingPathComponent("index"))
        let indexer = try Indexer(store: store, options: IndexOptions(), makeEmbedder: { FakeEmbedder() })
        _ = try indexer.sync([pictures])
        _ = try indexer.run()
        let miami = try #require(try store.locations(of: [beach.path])[beach.path])
        #expect(miami.source == .exif && abs(miami.latitude - 25.7907) < 1e-4 && abs(miami.longitude + 80.13) < 1e-4)
        // The picture changed: what was read from it goes, its location with it, until it's read again.
        try ImageTests.writeJPEG(beach, at: (40.7128, -74.006))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: beach.path)
        #expect(try indexer.sync([pictures]).changed == 1)
        #expect(try store.locations(of: [beach.path]).isEmpty)
        _ = try indexer.run()
        #expect(try abs((store.locations(of: [beach.path])[beach.path]?.latitude ?? 0) - 40.7128) < 1e-4)
    }

    @Test func picturesReadBeforeGetTheirLocationOnce() throws {
        // As an index from before locations were kept has them: read, with no location.
        let store = try IndexStore(directory: folder.appendingPathComponent("index"))
        let photo = folder.appendingPathComponent("photo.jpg")
        let library = folder.appendingPathComponent("L.photoslibrary/originals/F")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let asset = library.appendingPathComponent("FC37DBA6-CF22-4E3E-AB70-755587454608.jpeg")
        for (inode, url) in [photo, asset].enumerated() {
            try ImageTests.writeJPEG(url, at: (25.79, -80.13))
            try store.finish(try store.insert(file(url.path, inode: UInt64(inode))), state: "done")
        }
        #expect(try store.locateOnce() == 1)   // a library's picture has Photos' location, from the sync
        #expect(try store.locations(of: [photo.path, asset.path]).keys.sorted() == [photo.path])
        #expect(try store.locateOnce() == 0)
    }

    @Test func aPictureAwayWhenLocationsAreReadGetsItsLocationOnceItsBack() throws {
        // Read before locations were kept: one picture here, one away for now (on a drive that's unplugged, say), and
        // one away that leaves the index.
        let store = try IndexStore(directory: folder.appendingPathComponent("index"))
        let pictures = folder.appendingPathComponent("pictures"), aside = folder.appendingPathComponent("aside")
        for url in [pictures, aside] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        var ids: [Int64] = []
        for (inode, name) in ["here.jpg", "away.jpg", "gone.jpg"].enumerated() {
            let url = pictures.appendingPathComponent(name)
            try ImageTests.writeJPEG(url, at: (25.79, -80.13))
            ids.append(try store.insert(file(url.path, inode: UInt64(inode))))
            try store.finish(ids[inode], state: "done")
        }
        for name in ["away.jpg", "gone.jpg"] {
            try FileManager.default.moveItem(at: pictures.appendingPathComponent(name),
                                             to: aside.appendingPathComponent(name))
        }
        #expect(try store.locateOnce() == 1)
        let waiting = try #require(try store.meta("locations_read"))
        #expect(Set(try JSONDecoder().decode([Int64].self, from: Data(waiting.utf8))) == [ids[1], ids[2]])
        // Still away, and the other one's row gone: only the one away waits.
        try store.delete(ids[2])
        #expect(try store.locateOnce() == 0)
        #expect(try store.meta("locations_read") == "[\(ids[1])]")
        // Back as it was, so not read again: it gets its location now, and nothing waits any more.
        try FileManager.default.moveItem(at: aside.appendingPathComponent("away.jpg"),
                                         to: pictures.appendingPathComponent("away.jpg"))
        #expect(try store.locateOnce() == 1)
        let paths = ["here.jpg", "away.jpg"].map { pictures.appendingPathComponent($0).path }
        #expect(try store.locations(of: paths).keys.sorted() == paths.sorted())
        #expect(try store.meta("locations_read") == "1")
        #expect(try store.locateOnce() == 0)
    }
    #endif

    @Test func modelFileHashesStreamInPieces() throws {
        let small = folder.appendingPathComponent("abc")
        try Data("abc".utf8).write(to: small)
        #expect(try ModelFiles.sha256(of: small) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        // Bigger than one 8 MB piece.
        let bytes = Data((0..<(9 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let big = folder.appendingPathComponent("big")
        try bytes.write(to: big)
        let expected = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        #expect(try ModelFiles.sha256(of: big) == expected)
    }

    @Test func missingModelFilesInDownloadOrder() throws {
        #expect(ModelFiles.missing(in: folder) == [ModelFiles.text, ModelFiles.media])
        FileManager.default.createFile(atPath: folder.appendingPathComponent(ModelFiles.text.name).path, contents: nil)
        #expect(ModelFiles.missing(in: folder) == [ModelFiles.media])
        #expect(ModelFiles.totalBytes == 864_676_480)
    }

    @Test func modelFilesComeFromTheHuggingFaceCacheWhenThere() throws {
        // As `hf download` leaves them: snapshots/<revision>/<name> → a blob. Sparse, so no disk is used.
        let hub = folder.appendingPathComponent("hub")
        let snapshot = hub.appendingPathComponent("models--ggml-org--embeddinggemma-2-GGUF/snapshots/\(ModelFiles.revision)")
        let blobs = hub.appendingPathComponent("models--ggml-org--embeddinggemma-2-GGUF/blobs")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        let blob = blobs.appendingPathComponent("2188ac1d")
        FileManager.default.createFile(atPath: blob.path, contents: nil)
        try FileHandle(forWritingTo: blob).truncate(atOffset: UInt64(ModelFiles.text.bytes))
        try FileManager.default.createSymbolicLink(at: snapshot.appendingPathComponent(ModelFiles.text.name),
                                                   withDestinationURL: blob)
        setEnvironment("HF_HUB_CACHE", hub.path)
        defer { setEnvironment("HF_HUB_CACHE", nil) }
        #expect(ModelFiles.cachedCopy(of: ModelFiles.text)?.lastPathComponent == "2188ac1d")
        #expect(ModelFiles.cachedCopy(of: ModelFiles.media) == nil)   // not there
        try FileHandle(forWritingTo: blob).truncate(atOffset: 10)
        #expect(ModelFiles.cachedCopy(of: ModelFiles.text) == nil)    // not whole
    }

    @Test func syncKeepsTheRowsOfAFolderThatWentAway() throws {
        // The real path (/private/var/…), as the crawler reports it; resolvingSymlinksInPath() would drop "/private".
        let base = URL(fileURLWithPath: FolderSelection.realPath(folder.path))
        let drive = base.appendingPathComponent("drive")
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        try Data("notes from the trip".utf8).write(to: drive.appendingPathComponent("notes.txt"))
        let store = try IndexStore(directory: base.appendingPathComponent("index"))
        let indexer = try Indexer(store: store, options: IndexOptions(),
                                  makeEmbedder: { throw WorkerError.notFound("no model needed to sync") })
        #expect(try indexer.sync([drive]).added == 1)
        try FileManager.default.moveItem(at: drive, to: base.appendingPathComponent("ejected"))
        #expect(try indexer.sync([drive]).removed == 0)   // an ejected drive is not "everything deleted"
        #expect(try store.files(under: [drive.path]).count == 1)
    }

    @Test func syncFindsTheRowsOfAFolderSpelledAnotherWay() throws {
        // The walk stores paths as the disk spells them, and on a Mac these folders are chosen spelled otherwise twice
        // over: under /var where the disk says /private/var (the temporary folder), and with a name the disk keeps
        // precomposed that `standardizedFileURL` decomposes (Google Drive's "내 드라이브", "Café"). Looking their rows up
        // by that spelling found none, so the second sync took every file for new: "UNIQUE constraint failed".
        let store = try IndexStore(directory: folder.appendingPathComponent("index"))
        let indexer = try Indexer(store: store, options: IndexOptions(),
                                  makeEmbedder: { throw WorkerError.notFound("no model needed to sync") })
        var chosen: [URL] = []
        for name in ["내 드라이브", "Café"] {
            let onDisk = folder.path + "/" + name.precomposedStringWithCanonicalMapping
            #if os(Windows)
            try FileManager.default.createDirectory(atPath: onDisk, withIntermediateDirectories: false)
            #else
            #expect(mkdir(onDisk, 0o755) == 0)   // FileManager would decompose the name
            #endif
            try Data("notes from the trip".utf8).write(to: URL(fileURLWithPath: onDisk + "/notes.txt"))
            chosen.append(URL(fileURLWithPath: onDisk).standardizedFileURL)
        }
        #expect(try indexer.sync(chosen).added == 2)
        let again = try indexer.sync(chosen)
        #expect(again.added == 0 && again.unchanged == 2)
        #expect(try store.files(under: chosen.map(\.path)).count == 2)
        store.scope = chosen.map(\.path)
        #expect(try store.pendingCount() == 2)
        #expect(try store.prune(keepingUnder: chosen.map(\.path)) == 0)
    }
}

/// Sets an environment variable of this process, or removes it (nil).
private func setEnvironment(_ name: String, _ value: String?) {
    #if os(Windows)
    _ = name.withCString(encodedAs: UTF16.self) { name in
        guard let value else { return SetEnvironmentVariableW(name, nil) }
        return value.withCString(encodedAs: UTF16.self) { SetEnvironmentVariableW(name, $0) }
    }
    #else
    if let value { setenv(name, value, 1) } else { unsetenv(name) }
    #endif
}
