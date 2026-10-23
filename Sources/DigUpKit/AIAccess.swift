import Foundation

/// What AI apps may see through `digup mcp` (the app's Settings → AI apps), kept in the app's settings, where the server
/// reads it at every call: turning access off or narrowing it applies at once, mid-conversation. Everything is off
/// until the user turns it on; Photos stays off for AI apps until allowed (Jon, 2026-10-22).
public struct AIAccess: Sendable, Equatable {
    /// AI apps may search at all. Off: every call fails, saying where to turn it on.
    public var on: Bool
    /// Photos libraries' files. Off, they're never returned, counted or read.
    public var photos: Bool
    /// Photos' hidden items, which DigUp indexes only when asked (`IndexOptions.includeHiddenPhotos`).
    public var hiddenPhotos: Bool
    /// Code search (the code index).
    public var code: Bool
    /// Pictures themselves: a result's thumbnail, which goes to the AI app's model provider.
    public var pictures: Bool

    /// Pictures AI apps get are at most this big, on their long side (MCP-PLAN.md).
    public static let picturePixels = 768

    public init(on: Bool = false, photos: Bool = false, hiddenPhotos: Bool = false, code: Bool = false,
                pictures: Bool = false) {
        (self.on, self.photos, self.hiddenPhotos, self.code, self.pictures) = (on, photos, hiddenPhotos, code, pictures)
    }

    /// As the app's settings have it now; a switch never set is off.
    public init(_ defaults: UserDefaults) {
        self.init(on: defaults.bool(forKey: AppDefaults.aiAccessOn),
                  photos: defaults.bool(forKey: AppDefaults.aiAccessPhotos),
                  hiddenPhotos: defaults.bool(forKey: AppDefaults.aiAccessHiddenPhotos),
                  code: defaults.bool(forKey: AppDefaults.aiAccessCode),
                  pictures: defaults.bool(forKey: AppDefaults.aiAccessPictures))
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(on, forKey: AppDefaults.aiAccessOn)
        defaults.set(photos, forKey: AppDefaults.aiAccessPhotos)
        defaults.set(hiddenPhotos, forKey: AppDefaults.aiAccessHiddenPhotos)
        defaults.set(code, forKey: AppDefaults.aiAccessCode)
        defaults.set(pictures, forKey: AppDefaults.aiAccessPictures)
    }
}

/// The app's settings that `digup mcp` reads too, by key: the app saves them (`AppSettings`), in its defaults domain
/// (`domain`), or the one a dev run names with `-defaultsSuite`.
public enum AppDefaults {
    /// The installed app's defaults domain.
    public static let domain = "com.abdurrahim.DigUp"
    /// The index folder, when it isn't the default one (`AppPaths.defaultIndex`).
    public static let indexFolder = "indexDir"
    /// "Shot on my devices": the user's changes to the list (`IndexStore.PhotosCamera.mine`).
    public static let myDevicesAdded = "myDevicesAdded"
    public static let myDevicesRemoved = "myDevicesRemoved"
    /// `AIAccess`'s switches.
    public static let aiAccessOn = "aiAccessOn"
    public static let aiAccessPhotos = "aiAccessPhotos"
    public static let aiAccessHiddenPhotos = "aiAccessHiddenPhotos"
    public static let aiAccessCode = "aiAccessCode"
    public static let aiAccessPictures = "aiAccessPictures"
}

/// One call an AI app made through `digup mcp`, as `<index folder>/mcp.log` keeps it, a JSON line each: when, which app
/// (the name it gave), which tool, how many results, and why it was refused. Never what was searched for (Jon,
/// 2026-10-22: "The default should be not logging people's searches and queries"). Settings → AI apps shows the last
/// ones.
public struct AICall: Codable, Sendable, Equatable {
    public var time: Date
    /// The name the AI app gave (its MCP client info), or "unknown".
    public var client: String
    public var tool: String
    public var results: Int
    /// Why it was refused (access off, Photos off…); nil when it wasn't.
    public var refused: String?

    public init(time: Date = Date(), client: String, tool: String, results: Int, refused: String? = nil) {
        (self.time, self.client, self.tool, self.results, self.refused) = (time, client, tool, results, refused)
    }

    public static let fileName = "mcp.log"

    /// How much of the log's end `last` reads: far more than the lines Settings shows.
    static let tailBytes = 64 << 10

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// Adds the call to the end of the index folder's log.
    public static func append(_ call: AICall, in index: URL) throws {
        let url = index.appendingPathComponent(fileName)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: try encoder.encode(call) + Data("\n".utf8))
    }

    /// The last `count` calls in the index folder's log, oldest first; a line that can't be read is passed over.
    public static func last(_ count: Int, in index: URL) -> [AICall] {
        guard let handle = try? FileHandle(forReadingFrom: index.appendingPathComponent(fileName)) else { return [] }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: end > UInt64(tailBytes) ? end - UInt64(tailBytes) : 0)
        let data = (try? handle.readToEnd()) ?? Data()
        let calls = data.split(separator: UInt8(ascii: "\n")).compactMap { try? decoder.decode(AICall.self, from: $0) }
        return Array(calls.suffix(count))
    }
}
