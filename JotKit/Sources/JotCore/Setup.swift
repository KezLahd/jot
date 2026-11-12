import Foundation

/// Downloads the tools and models Jot needs into Paths.root. Each item is skipped if already present.
public enum Setup {
    public struct Item: Sendable {
        public var name: String
        public var url: URL
        public var destination: URL
        public var executable: Bool
    }

    #if os(macOS)
    public static let items: [Item] = [
        Item(name: "yt-dlp", url: URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos")!,
             destination: Paths.ytDLP, executable: true),
        Item(name: "Whisper small model (~490 MB)", url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin")!,
             destination: Paths.whisperModel, executable: false),
        vad,
    ]
    #else
    public static let items: [Item] = [
        Item(name: "Whisper small model (190 MB)", url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small-q5_1.bin")!,
             destination: Paths.whisperModel, executable: false),
        vad,
    ]
    #endif

    static let vad = Item(name: "Silero VAD model", url: URL(string: "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v6.2.0.bin")!,
                          destination: Paths.vadModel, executable: false)

    /// True when every model and tool is on disk.
    public static var isInstalled: Bool { items.allSatisfy { FileManager.default.fileExists(atPath: $0.destination.path) } }

    /// - Parameter wifiOnly: on iPhone, wait for Wi-Fi rather than use mobile data.
    public static func run(wifiOnly: Bool = false, log: @Sendable (String) -> Void) async throws {
        #if os(macOS)
        try Paths.ensure(Paths.bin)
        #endif
        try Paths.ensure(Paths.models)
        let config = URLSessionConfiguration.default
        config.allowsExpensiveNetworkAccess = !wifiOnly
        config.allowsConstrainedNetworkAccess = !wifiOnly
        config.waitsForConnectivity = true
        config.timeoutIntervalForResource = 6 * 3600
        let session = URLSession(configuration: config)
        for item in items {
            if FileManager.default.fileExists(atPath: item.destination.path) {
                log("✓ \(item.name) already installed")
                continue
            }
            log("↓ \(item.name)")
            let (tmp, response) = try await session.download(from: item.url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw JotError.fetchFailed("\(item.name): HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
            }
            try? FileManager.default.removeItem(at: item.destination)
            try FileManager.default.moveItem(at: tmp, to: item.destination)
            if item.executable {
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: item.destination.path)
            }
            log("✓ \(item.name)")
        }
    }
}
