import Foundation

/// How revealing a picture is, as the detector said (`SensitiveModel`, Freepik's nsfw_image_detector): the probability
/// of each of its levels above neutral, which is what's left (1 − low − medium − high). What they mean, as its card says:
/// from "low" (swimwear, lingerie, implied nudity) to "high" (explicit). The index keeps them as they are
/// (`sensitive_scores`), not a threshold's verdict, so the setting's positions can move without rating anything again.
public struct SensitiveLevels: Sendable, Equatable {
    public let low: Double
    public let medium: Double
    public let high: Double

    public init(low: Double, medium: Double, high: Double) {
        (self.low, self.medium, self.high) = (low, medium, high)
    }

    /// How likely it's at least low: what "Anything revealing" and "Revealing" go by.
    public var lowOrHigher: Double { low + medium + high }
    /// How likely it's at least medium: what "Nudity only" goes by.
    public var mediumOrHigher: Double { medium + high }

    /// The most revealing of several pictures as the positions read them: each level-or-higher at its highest among
    /// them, so a position flags it when it flags any of them (a video whose cell shows a frame nobody knows, Quick
    /// Look's, goes by its most revealing frame). Nil for none.
    public static func most(of all: some Sequence<SensitiveLevels>) -> SensitiveLevels? {
        var most: (lowOrHigher: Double, mediumOrHigher: Double, high: Double)?
        for levels in all {
            most = (max(most?.lowOrHigher ?? 0, levels.lowOrHigher), max(most?.mediumOrHigher ?? 0, levels.mediumOrHigher),
                    max(most?.high ?? 0, levels.high))
        }
        // Each at its highest is still at least the one above it: the highest low-or-higher is at least the low-or-higher
        // of the picture with the highest medium-or-higher, which is at least that.
        return most.map { SensitiveLevels(low: $0.lowOrHigher - $0.mediumOrHigher, medium: $0.mediumOrHigher - $0.high,
                                          high: $0.high) }
    }
}

/// Where "Blur sensitive pictures" is set (Settings → General), and so what counts as sensitive: what's blurred, what
/// the Sensitive filter keeps (at Revealing while blurring is off: `filterPosition`), and what AI apps are kept from
/// (`AIAccess.sensitive`). The thresholds are ADULT-CONTENT-EVAL.md's (2026-10-22, Jon's library): they catch an
/// estimated 100, 93 and 87 % of nude or explicit pictures, and blur about 14, 11 and 9 % of the library (some 2,200,
/// 1,100 and 900 ordinary pictures with them).
public enum SensitivePosition: String, CaseIterable, Sendable {
    case off
    /// Low or higher, 0.2 or more.
    case anythingRevealing
    /// Low or higher, 0.5 or more.
    case revealing
    /// Medium or higher, 0.5 or more.
    case nudityOnly

    /// As the app's settings keep it (`AppDefaults.blurSensitive`); never set, or a value this DigUp doesn't know: off.
    public init(_ defaults: UserDefaults) {
        self = defaults.string(forKey: AppDefaults.blurSensitive).flatMap(Self.init(rawValue:)) ?? .off
    }

    public var title: String {
        switch self {
        case .off: "Off"
        case .anythingRevealing: "Anything revealing"
        case .revealing: "Revealing"
        case .nudityOnly: "Nudity only"
        }
    }

    /// What the Sensitive filter and AI apps go by with blurring set here: the same position, Revealing while it's off.
    public var filterPosition: SensitivePosition { self == .off ? .revealing : self }

    /// Whether a picture of these levels counts as sensitive here (never, off).
    public func flags(_ levels: SensitiveLevels) -> Bool {
        switch self {
        case .off: false
        case .anythingRevealing: levels.lowOrHigher >= 0.2
        case .revealing: levels.lowOrHigher >= 0.5
        case .nudityOnly: levels.mediumOrHigher >= 0.5
        }
    }

    /// `flags` over a `sensitive_scores` row's columns, in SQL.
    var condition: String {
        switch self {
        case .off: "0"
        case .anythingRevealing: "low + medium + high >= 0.2"
        case .revealing: "low + medium + high >= 0.5"
        case .nudityOnly: "medium + high >= 0.5"
        }
    }
}

/// Rates pictures for the index (`sensitive_scores`): the detector the app runs (`SensitiveModel.rater`), or a stand-in
/// in tests. The indexer asks it about the pictures it reads for the model, on its own thread.
public protocol PictureRater: AnyObject {
    /// The model that says so, as the index records it (`SensitiveModel.identity`): when it isn't the one recorded,
    /// every rating goes and each picture is rated again (`IndexStore.adoptSensitiveModel`).
    var model: String { get }
    /// The levels of the picture in the file at `url` (one the indexer wrote for the embedding model: a picture's
    /// thumbnail, a GIF's frame, a video's frame or one of Photos' stills of it).
    func levels(ofPictureAt url: URL) throws -> SensitiveLevels
}

/// The detector DigUp rates pictures with: Freepik's nsfw_image_detector (EVA02-base at 448 × 448, MIT) at a pinned
/// commit, which ADULT-CONTENT-EVAL.md chose, converted to Core ML by scripts/sensitive-model.py (float32: at float16 a
/// level came out up to 0.014 from PyTorch's) and checked against PyTorch there. Where to download the converted model
/// from isn't decided: the app rates pictures when the model is in the models folder, and Settings says how to make it
/// when it isn't. Only on macOS (Core ML); elsewhere pictures aren't rated.
public enum SensitiveModel {
    public static let repository = "Freepik/nsfw_image_detector"
    public static let revision = "15b85477e4fd2000db76ae9aae0f89a72f95e2e3"
    /// scripts/sensitive-model.py's `CONVERSION`: a new way of making it that can move its numbers is a new one.
    public static let conversion = 1

    /// What the index records as the model (`meta` "fork_sensitive_model"): its name, its commit and the conversion.
    public static var identity: String { "\(repository)@\(revision) conversion \(conversion)" }

    /// A file the detector needs in the models folder's `sensitive/` (`folder`). Named for the commit and the
    /// conversion, so another one's file is never taken for it.
    public struct File: Sendable, Equatable {
        public let name: String
        /// Where a checked copy can be downloaded from: none yet (hosting the converted model isn't decided), so it's
        /// made with scripts/sensitive-model.py. A download, when there is one, gives its address, size and SHA-256
        /// here, as `ModelFiles.File` does for the embedding model.
        public let download: Download?
    }

    public struct Download: Sendable, Equatable {
        public let url: URL
        public let bytes: Int64
        public let sha256: String
    }

    /// The Core ML model, compiled (.mlmodelc, a folder): what scripts/sensitive-model.py's `NAME` names it.
    public static let model = File(name: "nsfw_image_detector-\(revision.prefix(7))-c\(conversion).mlmodelc",
                                   download: nil)
    public static let files = [model]

    /// The command that makes it, from the repository's folder (Settings shows it while the model isn't there).
    public static let makeCommand = "scripts/sensitive-model.py convert"

    /// Its folder in the models folder `models` (the app's `modelsDirectory`; the helpers', `$DIGUP_MODELS`).
    public static func folder(in models: URL) -> URL {
        models.appendingPathComponent("sensitive")
    }

    /// The helpers' models folder: `$DIGUP_MODELS` (the app sets it), else `ModelFiles.installed`.
    public static var models: URL {
        ProcessInfo.processInfo.environment["DIGUP_MODELS"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? ModelFiles.installed
    }

    /// Its files that aren't in the models folder `models`.
    public static func missing(in models: URL) -> [File] {
        files.filter { !FileManager.default.fileExists(atPath: folder(in: models).appendingPathComponent($0.name).path) }
    }

    /// Pictures are rated: the detector runs on this computer (`runsHere`) and its files are in `models`.
    public static func isInstalled(in models: URL) -> Bool {
        runsHere && missing(in: models).isEmpty
    }
}

/// What the detector said of a file's pictures, as the index keeps them: its `image` segment, and its `frame`
/// segments in the order they were written (a video's keyframes by time, Photos' stills of a video in iCloud in their
/// filmstrip's order, a GIF's later frames). Levels are nil for a picture not rated yet.
public struct SensitivePictures: Sendable, Equatable {
    public struct Picture: Sendable, Equatable {
        public let segment: Int64
        /// When it's shown, in seconds (a frame of a video or a GIF); nil for the picture itself and for a still.
        public let loc: Double?
        public let levels: SensitiveLevels?
    }

    public var image: Picture?
    public var frames: [Picture]

    public init(image: Picture? = nil, frames: [Picture] = []) {
        (self.image, self.frames) = (image, frames)
    }

    /// The picture of this segment.
    public func levels(ofSegment segment: Int64) -> SensitiveLevels? {
        image?.segment == segment ? image?.levels : frames.first { $0.segment == segment }?.levels
    }

    /// The frame at this place among them, from 0 (a stills video's: its filmstrip's still at that place).
    public func levels(ofFrame place: Int) -> SensitiveLevels? {
        frames.indices.contains(place) ? frames[place].levels : nil
    }

    /// The frame shown at `seconds`: the last one that starts by then (a kept keyframe stands for the stretch until the
    /// next), else the first.
    public func frame(at seconds: Double) -> Picture? {
        frames.last { ($0.loc ?? 0) <= seconds } ?? frames.first
    }

    /// Every picture's rating, the ones rated.
    public var rated: [SensitiveLevels] { ([image].compactMap { $0 } + frames).compactMap(\.levels) }
}
