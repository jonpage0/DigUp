import Foundation

/// Timestamped lines in `<index folder>/app.log` and on stderr. This is how the app gets measured during
/// development (launch, sync, search and indexing timings), so lines say what happened and how long it took.
nonisolated final class AppLog: @unchecked Sendable {
    static let shared = AppLog()
    private let lock = NSLock()
    private var file: FileHandle?

    func open(in folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("app.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        handle.seekToEndOfFile()
        lock.withLock { file = handle }
    }

    func write(_ message: String) {
        let data = Data("\(Self.timestamp()) \(message)\n".utf8)
        lock.withLock { file?.write(data) }
        FileHandle.standardError.write(data)
    }

    /// Local wall-clock time with milliseconds, e.g. "03:41:07.218".
    static func timestamp() -> String {
        var now = timeval()
        gettimeofday(&now, nil)
        var seconds = now.tv_sec
        var parts = tm()
        localtime_r(&seconds, &parts)
        return String(format: "%02d:%02d:%02d.%03d", parts.tm_hour, parts.tm_min, parts.tm_sec, now.tv_usec / 1000)
    }
}

nonisolated func log(_ message: String) {
    AppLog.shared.write(message)
}

/// A search, as a log line names it. The installed app never writes what someone searched for, only its length: the
/// log sits in the index folder in plain text, and what people look for is theirs. A dev run (its own -defaultsSuite)
/// writes the words, which are test queries there and what its checks read.
nonisolated func searchWords(_ text: String) -> String {
    devRun ? "\"\(text)\"" : "(\(text.count) characters)"
}

private nonisolated let devRun = UserDefaults.standard.string(forKey: "defaultsSuite") != nil

/// Milliseconds from `start` to `end` (default: now), for log lines.
nonisolated func ms(since start: Date, until end: Date = Date()) -> String {
    String(format: "%.0f ms", end.timeIntervalSince(start) * 1000)
}
