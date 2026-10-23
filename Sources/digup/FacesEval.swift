import DigUpKit
import Foundation

/// `digup faces-eval --library <path> [--catalog <Photos.sqlite>] [--engine vision|sface] [--model <path>]...`: how well
/// each face recognizer (`FaceRecognizer`) knows the people named in a Photos library. Every face Photos found in its
/// photos is read from the photo, where Photos found it (`PhotosLibrary.photoFaces`, `FacePicture`): the named ones
/// are the people's, the others everyone else. Per recognizer, it reports the faces read per person; each named face's
/// nearest other face, leave-one-out (`Faces.Measure`): how often it's the same person's; at each threshold, the share
/// of named faces called the right person, the share called someone else, and the share of the other faces that would
/// wrongly be called a named person; and its time a face. Counts and rates only: never a file's name or a picture.
///
/// `--catalog` reads a copy of the library's catalog (its database/Photos.sqlite, with the -wal beside it) instead of
/// the library's own, which is otherwise opened read-only. `--engine` picks Vision's faceprints or the Core ML engine
/// (both by default, those available); `--model` is a Core ML engine's model, one engine a model given (comparing
/// models in one run reads each picture once), by default the SFace that scripts/face-model.py keeps in DigUp's models
/// folder ($DIGUP_MODELS, else ~/Library/Application Support/DigUp/Models), faces/.
#if canImport(Vision) && canImport(CoreML)
func facesEval(_ args: Arguments) throws {
    guard let chosen = args.values["--library"] else { throw CLIError("which library? --library <path>") }
    let library = Arguments.folderURL(chosen).path
    guard PhotosLibrary.isLibrary(library), Arguments.isFolder(URL(fileURLWithPath: library)) else {
        throw CLIError("not a Photos library: \(chosen)")
    }
    let catalog = args.values["--catalog"].map { (($0 as NSString).expandingTildeInPath as NSString).standardizingPath }
        ?? library + "/database/Photos.sqlite"
    let engines = try faceRecognizers(args)
    let (photos, left) = try PhotosLibrary.photoFaces(catalog: catalog)
    let faces = photos.map(\.faces.count).reduce(0, +)
    let named = photos.flatMap(\.faces).filter { $0.person != nil }.count
    print("library: \(tilde(library))" + (args.values["--catalog"] == nil ? "" : " (its catalog read from a copy)"))
    print("Photos' faces: \(number(faces)) in \(number(photos.count)) photos, \(number(named)) of them named, "
          + "\(number(faces - named)) not" + (left.isEmpty ? "" : "; left out: " + skippedLine(left)))

    // Each engine's embeddings: the named faces with their person, the others, and its time.
    var results = engines.map { _ in EngineRun() }
    var pictures = 0, unread = 0, reading = 0.0
    for photo in photos {
        guard let path = PhotosLibrary.facePicture(of: photo, in: library) else {
            unread += photo.faces.count
            continue
        }
        let started = Date()
        guard let picture = try? FacePicture(contentsOf: URL(fileURLWithPath: path), photosFaces: photo.faces) else {
            unread += photo.faces.count
            continue
        }
        reading += Date().timeIntervalSince(started)
        pictures += 1
        for (index, engine) in engines.enumerated() {
            let started = Date()
            let embeddings = engine.embeddings(of: picture)
            results[index].time(Date().timeIntervalSince(started), faces: photo.faces.count)
            for (face, embedding) in zip(photo.faces, embeddings) { results[index].add(embedding, person: face.person) }
        }
    }
    print("photos read: \(number(pictures)) of \(number(photos.count)) (the rest have no picture on this Mac, or none "
          + "that could be read: \(number(unread)) faces); reading one and Vision's landmarks on its faces: "
          + String(format: "%.1f ms", reading * 1000 / Double(max(pictures, 1))))
    let people = namedPeople(in: photos)
    for (engine, run) in zip(engines, results) {
        print("")
        report(engine, run, people: people, others: faces - named)
    }
}

/// The people named in the library's photos, told apart by Photos' id for them, most faces first: what a report calls
/// each (their name, and where people share it, a number after it by the same order: "Sam #2"; never the id), their
/// id, and their faces.
private func namedPeople(in photos: [PhotosLibrary.PhotoFaces]) -> [(label: String, uuid: String, faces: Int)] {
    let people = Dictionary(grouping: photos.flatMap(\.faces).compactMap(\.person), by: \.uuid).values
        .map { (person: $0[0], faces: $0.count) }
        .sorted { $0.faces != $1.faces ? $0.faces > $1.faces : $0.person.uuid < $1.person.uuid }
    let names = Dictionary(grouping: people, by: \.person.name).mapValues(\.count)
    var numbered: [String: Int] = [:]
    return people.map { person in
        let name = person.person.name
        guard names[name, default: 0] > 1 else { return (name, person.person.uuid, person.faces) }
        numbered[name, default: 0] += 1
        return ("\(name) #\(numbered[name, default: 0])", person.person.uuid, person.faces)
    }
}

/// The Core ML engine's model when no `--model` names one: SFace, where scripts/face-model.py keeps it.
private let sfaceModel = "faces/face_recognition_sface_2021dec.mlpackage"

/// What `--engine` and `--model` ask for: the recognizers to measure. Without `--engine`, every one available here
/// (saying why one isn't).
private func faceRecognizers(_ args: Arguments) throws -> [any FaceRecognizer] {
    let folder = ProcessInfo.processInfo.environment["DIGUP_MODELS"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        ?? ModelFiles.installed
    let models = args.lists["--model"]?.map(Arguments.folderURL) ?? [folder.appendingPathComponent(sfaceModel)]
    func coreML(_ model: URL) throws -> any FaceRecognizer {
        guard FileManager.default.fileExists(atPath: model.path) else {
            throw CLIError("no face model at \(tilde(model.path)) (scripts/face-model.py convert makes it)")
        }
        return try CoreMLFaceEmbedder(model: model)
    }
    switch args.values["--engine"] {
    case "vision": return [try VisionFaceprints()]
    case "sface": return try models.map(coreML)
    case nil:
        let makers = [{ try VisionFaceprints() as any FaceRecognizer }] + models.map { model in { try coreML(model) } }
        var engines: [any FaceRecognizer] = []
        for make in makers {
            do { engines.append(try make()) } catch { print("left out: \(error)") }
        }
        guard !engines.isEmpty else { throw CLIError("no face recognizer is available here") }
        return engines
    case let other?: throw CLIError("unknown engine \(other); use vision or sface")
    }
}

/// One engine's embeddings and time over a library's faces.
private struct EngineRun {
    var named: [(person: PhotosLibrary.Person, embedding: [Float])] = []
    var others: [[Float]] = []
    /// Faces read, by Photos' id for their person (nil: the others).
    var read: [String?: Int] = [:]
    var seconds = 0.0
    var faces = 0
    /// The first picture's time a face: the engine getting ready (Vision loading its model, Core ML its model onto the
    /// device).
    var first: Double?

    mutating func add(_ embedding: [Float]?, person: PhotosLibrary.Person?) {
        guard let embedding else { return }
        read[person?.uuid, default: 0] += 1
        if let person { named.append((person, embedding)) } else { others.append(embedding) }
    }

    mutating func time(_ seconds: Double, faces: Int) {
        guard first != nil else {
            first = seconds / Double(max(faces, 1))
            return
        }
        self.seconds += seconds
        self.faces += faces
    }
}

/// The thresholds a report goes through: from far apart to nearly the same (LVFace's vectors call the same person at
/// lower similarities than SFace's and Vision's).
private let faceThresholds = stride(from: 0.05, through: 0.951, by: 0.05).map { Float($0) }

private func report(_ engine: any FaceRecognizer, _ run: EngineRun, people: [(label: String, uuid: String, faces: Int)],
                    others: Int) {
    print(engine.name)
    print("  faces read: " + people.map { "\($0.label) \(number(run.read[$0.uuid] ?? 0)) of \(number($0.faces))" }
        .joined(separator: " · ") + " · not named \(number(run.read[nil] ?? 0)) of \(number(others))")
    print(String(format: "  %.1f ms a face (the first picture's: %.0f ms a face)",
                 run.seconds * 1000 / Double(max(run.faces, 1)), (run.first ?? 0) * 1000))
    let measure = Faces.Measure(named: run.named, others: run.others, similarity: engine.similarity)
    print(String(format: "  nearest other named face is the same person's: %.1f%% of %@", measure.nearestRight * 100,
                 number(measure.calls.count))
          + (measure.alone > 0 ? " (\(number(measure.alone)) left out: no other face of their person)" : ""))
    print("  threshold   right   wrong   not called   not named but called someone")
    for threshold in faceThresholds {
        let rates = measure.rates(at: threshold)
        print(String(format: "  %9.2f  %5.1f%%  %5.1f%%       %5.1f%%   %5.1f%%", threshold, rates.right * 100,
                     rates.wrong * 100, rates.uncalled * 100, rates.others * 100))
    }
}
#else
func facesEval(_ args: Arguments) throws {
    throw CLIError("faces-eval needs macOS: Vision and Core ML")
}
#endif
