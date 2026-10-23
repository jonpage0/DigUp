import Foundation

/// Programs the user installs once, in Terminal, for DigUp to run: osxphotos (`PhotosLibrary.osxphotos`), and
/// parakeet-mlx with the ffmpeg it needs (`Speech`).
public enum InstalledPrograms {
    /// The program `name`: $`variable` when that's set (empty: none), else where `uv tool install`, pipx,
    /// `pip install --user`, Homebrew or MacPorts put it, else on PATH. The app's helpers run with launchd's PATH, which
    /// has none of those. Nil where it isn't installed, and off the Mac. Looked for each time (a few file checks):
    /// installed while the app runs, it's found without a relaunch.
    public static func path(of name: String, chosenBy variable: String? = nil) -> String? {
        #if os(macOS)
        let environment = ProcessInfo.processInfo.environment
        let fm = FileManager.default
        if let variable, let chosen = environment[variable] {
            return !chosen.isEmpty && fm.isExecutableFile(atPath: chosen) ? chosen : nil
        }
        let folders = [fm.homeDirectoryForCurrentUser.path + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin",
                       "/opt/local/bin"] + (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return folders.map { $0 + "/" + name }.first { fm.isExecutableFile(atPath: $0) }
        #else
        return nil
        #endif
    }
}
