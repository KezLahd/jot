import Foundation

/// Where Jot keeps its tools, models and Reads on this Mac.
/// The apps will move Reads into the iCloud container; the CLI uses Application Support.
public enum Paths {
    public static var root: URL {
        if let override = ProcessInfo.processInfo.environment["JOT_HOME"] {
            return URL(filePath: override, directoryHint: .isDirectory)
        }
        return URL.applicationSupportDirectory.appending(path: "Jot", directoryHint: .isDirectory)
    }
    public static var bin: URL { root.appending(path: "bin", directoryHint: .isDirectory) }
    public static var models: URL { root.appending(path: "Models", directoryHint: .isDirectory) }
    public static var reads: URL { root.appending(path: "Reads", directoryHint: .isDirectory) }

    public static var ytDLP: URL { bin.appending(path: "yt-dlp") }
    /// The Mac runs full-precision small; the iPhone the 5-bit quantised small (190 MB, near-identical words).
    public static var whisperModel: URL {
        #if os(macOS)
        models.appending(path: "ggml-small.bin")
        #else
        models.appending(path: "ggml-small-q5_1.bin")
        #endif
    }
    public static var vadModel: URL { models.appending(path: "ggml-silero-v6.2.0.bin") }

    static func ensure(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
