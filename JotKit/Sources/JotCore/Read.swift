import Foundation

/// One transcript and everything known about where it came from. Saved as `read.json` in its own folder.
public struct Read: Codable, Sendable, Equatable {
    public struct Segment: Codable, Sendable, Equatable {
        public var start: Double  // seconds
        public var end: Double
        public var text: String
        /// What Whisper actually wrote, when the cleanup pass fixed a misheard word in this line.
        public var heard: String?
        public init(start: Double, end: Double, text: String, heard: String? = nil) {
            self.start = start; self.end = end; self.text = text; self.heard = heard
        }
    }

    public enum Kind: String, Codable, Sendable { case link, file }

    public var id: String
    public var kind: Kind
    public var source: String          // the link, or the original file name
    public var site: String?           // "Instagram", "YouTube", …
    public var title: String
    public var creator: String?        // display name
    public var handle: String?         // @handle
    public var caption: String?
    public var duration: Double?       // seconds
    public var posted: Date?
    public var created: Date
    public var language: String?
    public var engine: String          // e.g. "whisper.cpp"
    public var model: String           // e.g. "ggml-small"
    public var audioFile: String?      // relative to the Read's folder
    public var segments: [Segment]
    /// A short headline written on-device (Apple's Foundation Models) from the caption and transcript.
    /// Nil where the model isn't available; `title` is then the caption title or the first words said.
    public var summary: String?
    /// The model that proofread the transcript (see Cleanup), or nil if Whisper's words stand as they are.
    public var cleanedBy: String? = nil

    public var displayTitle: String { summary ?? title }

    /// What kind of thing this came from, for the row's icon.
    public enum Medium: Sendable { case reel, post, short, video, voiceMemo, audio, videoFile, link }

    public var medium: Medium {
        let ext = (source as NSString).pathExtension.lowercased()
        if kind == .file {
            if ["mov", "mp4", "m4v"].contains(ext) { return .videoFile }
            return ["m4a", "caf", "aac"].contains(ext) ? .voiceMemo : .audio
        }
        let s = source.lowercased()
        if s.contains("instagram.com/reel") || s.contains("instagram.com/reels") { return .reel }
        if s.contains("instagram.com/p/") { return .post }
        if s.contains("youtube.com/shorts") { return .short }
        if ["YouTube", "TikTok", "X", "Vimeo", "Facebook"].contains(site ?? "") { return .video }
        return .link
    }

    /// The transcript minus any words the title already shows.
    public var preview: String {
        var t = text.trimmingCharacters(in: .whitespaces)
        let lead = displayTitle.trimmingCharacters(in: CharacterSet(charactersIn: " …."))
        if !lead.isEmpty, t.lowercased().hasPrefix(lead.lowercased()) {
            t = String(t.dropFirst(lead.count)).trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:!?…"))
        }
        return t
    }

    public var text: String {
        segments.map(\.text).joined(separator: " ")
    }

    /// A title from the first words said: "Felt texture, fluted glass, thermal gradients…"
    public static func title(fromOpening segments: [Segment], maxLength: Int = 60) -> String? {
        let text = segments.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        if text.count <= maxLength { return text }
        let window = String(text.prefix(maxLength + 1))
        // Prefer ending on a sentence, then on a comma, then on a word, as long as it keeps at least ~20 characters.
        for marks in [".!?", ",;:"] {
            if let i = window.lastIndex(where: { marks.contains($0) }), window.distance(from: window.startIndex, to: i) >= 20 {
                let cut = String(window[...i])
                return marks == ".!?" ? cut : cut.dropLast() + "…"
            }
        }
        var cut = String(text.prefix(maxLength))
        if let space = cut.lastIndex(of: " ") { cut = String(cut[..<space]) }
        return cut.trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:-")) + "…"
    }

    public var wordCount: Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    /// The text that goes to Claude: a short header, then the transcript.
    public func markdown(timestamps: Bool = true) -> String {
        var lines = ["# \(displayTitle)", ""]
        var meta: [String] = []
        if let handle { meta.append(handle) } else if let creator { meta.append(creator) }
        if let site { meta.append(site) }
        if let duration { meta.append(Read.clock(duration)) }
        if kind == .link { meta.append(source) }
        if !meta.isEmpty { lines += [meta.joined(separator: " · "), ""] }
        if timestamps {
            lines += segments.map { "[\(Read.clock($0.start))] \($0.text)" }
        } else {
            lines.append(text)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// 0:09, 4:05, 1:02:47
    public static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        let h = s / 3600, m = (s % 3600) / 60, r = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, r) : String(format: "%d:%02d", m, r)
    }
}

extension Read {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public func write(to folder: URL) throws {
        try Read.encoder.encode(self).write(to: folder.appending(path: "read.json"), options: .atomic)
        try markdown().write(to: folder.appending(path: "transcript.md"), atomically: true, encoding: .utf8)
    }

    public static func load(from folder: URL) throws -> Read {
        try decoder.decode(Read.self, from: Data(contentsOf: folder.appending(path: "read.json")))
    }
}
