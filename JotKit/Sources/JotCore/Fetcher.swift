import Foundation

/// Downloads a post's audio and metadata with yt-dlp, logged out. Never passes cookies or credentials.
public struct Fetcher: Sendable {
    public struct Result: Sendable {
        public var mediaFile: URL
        public var site: String?
        /// nil when the site gives only a generic title ("Video by …"); the pipeline then titles it from the transcript.
        public var title: String?
        public var creator: String?
        public var handle: String?
        public var caption: String?
        public var duration: Double?
        public var posted: Date?
        public var canonicalURL: String
    }

    public var ytDLP: URL

    public init(ytDLP: URL = Paths.ytDLP) {
        self.ytDLP = ytDLP
    }

    public func fetch(_ link: URL, into folder: URL) throws -> Result {
        #if os(macOS)
        guard FileManager.default.isExecutableFile(atPath: ytDLP.path) else { throw JotError.missingTool("yt-dlp") }
        let process = Process()
        process.executableURL = ytDLP
        process.arguments = [
            "--no-playlist", "--no-progress", "--no-warnings",
            "--ignore-config", "--no-cookies", "--no-cookies-from-browser",
            "-f", "bestaudio[ext=m4a]/bestaudio[ext=mp4]/best[ext=mp4]/bestaudio/best",
            "-o", folder.appending(path: "source.%(ext)s").path,
            "--dump-single-json", "--no-simulate",
            link.absoluteString,
        ]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        // Read both pipes before waiting so a large JSON can't block the child.
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let stderr = String(decoding: errData, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw Fetcher.classify(stderr: stderr, site: Fetcher.siteName(for: link))
        }
        guard let info = try JSONSerialization.jsonObject(with: outData) as? [String: Any] else {
            throw JotError.fetchFailed("yt-dlp returned no metadata")
        }
        return try Fetcher.result(from: info, folder: folder, link: link)
        #else
        // iOS can't run yt-dlp; links are queued for the Mac instead (see Library.addRequest).
        throw JotError.fetchFailed("links are fetched by Jot on your Mac")
        #endif
    }

    static func result(from info: [String: Any], folder: URL, link: URL) throws -> Result {
        let downloads = info["requested_downloads"] as? [[String: Any]]
        let path = (downloads?.first?["filepath"] as? String) ?? (info["_filename"] as? String)
        guard let path, FileManager.default.fileExists(atPath: path) else {
            throw JotError.fetchFailed("the download didn't produce a file")
        }
        let site = (info["extractor_key"] as? String).map(Fetcher.prettySite) ?? Fetcher.siteName(for: link)
        let caption = (info["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawTitle = (info["title"] as? String) ?? ""
        let creator = (info["uploader"] as? String) ?? (info["channel"] as? String)
        // Instagram's uploader_id is numeric; channel is the @handle.
        let handleRaw = (info["channel"] as? String) ?? (info["uploader_id"] as? String).flatMap { $0.allSatisfy(\.isNumber) ? nil : $0 }
        var posted: Date?
        if let ts = info["timestamp"] as? Double { posted = Date(timeIntervalSince1970: ts) }
        return Result(
            mediaFile: URL(filePath: path),
            site: site,
            title: Fetcher.title(raw: rawTitle),
            creator: creator,
            handle: handleRaw.map { $0.hasPrefix("@") ? $0 : "@\($0)" },
            caption: caption?.isEmpty == true ? nil : caption,
            duration: info["duration"] as? Double,
            posted: posted,
            canonicalURL: (info["webpage_url"] as? String) ?? link.absoluteString
        )
    }

    /// Instagram and TikTok titles are just "Video by <handle>", and captions are often a call to action,
    /// so a generic title returns nil and the Read is titled from what was said.
    static func title(raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let generic = t.isEmpty || ["Video by ", "Reel by ", "Post by ", "TikTok video #"].contains { t.hasPrefix($0) }
        return generic ? nil : t
    }

    static func classify(stderr: String, site: String) -> JotError {
        let s = stderr.lowercased()
        if s.contains("login") || s.contains("log in") || s.contains("cookies") || s.contains("rate-limit") || s.contains("sign in") {
            return .needsLogin(site: site)
        }
        if s.contains("not available") || s.contains("private") || s.contains("removed") || s.contains("404") {
            return .unavailable(Fetcher.lastErrorLine(stderr) ?? "it may be private or deleted")
        }
        return .fetchFailed(Fetcher.lastErrorLine(stderr) ?? "yt-dlp failed")
    }

    static func lastErrorLine(_ stderr: String) -> String? {
        stderr.split(whereSeparator: \.isNewline).last { $0.contains("ERROR") }
            .map { $0.replacingOccurrences(of: "ERROR: ", with: "").trimmingCharacters(in: .whitespaces) }
    }

    static func siteName(for url: URL) -> String {
        let host = (url.host() ?? "").lowercased()
        if host.contains("instagram") { return "Instagram" }
        if host.contains("tiktok") { return "TikTok" }
        if host.contains("youtu") { return "YouTube" }
        if host.contains("x.com") || host.contains("twitter") { return "X" }
        return host.replacingOccurrences(of: "www.", with: "")
    }

    static func prettySite(_ key: String) -> String {
        switch key.lowercased() {
        case "instagram": "Instagram"
        case "tiktok": "TikTok"
        case "youtube", "youtubetab": "YouTube"
        case "twitter": "X"
        default: key
        }
    }
}
