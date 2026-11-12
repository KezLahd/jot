import Foundation

/// What Jot makes of a pasted link before you add it: where it's from, and whether a logged-out fetch can
/// get it. Jot never signs in, so stories, profiles and channels are refused here rather than failing later.
public enum LinkCheck: Equatable, Sendable {
    case empty
    case ok(link: URL, what: String)
    case no(String)

    public var link: URL? { if case .ok(let url, _) = self { url } else { nil } }

    public static func check(_ text: String) -> LinkCheck {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        guard let url = firstLink(in: trimmed) else { return .no("That isn't a link.") }
        var host = (url.host() ?? "").lowercased()
        for prefix in ["www.", "m.", "mobile."] where host.hasPrefix(prefix) { host.removeFirst(prefix.count) }
        let parts = url.pathComponents.filter { $0 != "/" }.map { $0.lowercased() }
        let first = parts.first ?? ""
        let ok = { (what: String) in LinkCheck.ok(link: url, what: what) }

        switch host {
        case "instagram.com":
            switch first {
            case "reel", "reels": return parts.count > 1 ? ok("Instagram reel") : .no("That's the Reels tab. Share one reel.")
            case "p": return ok("Instagram post")
            case "tv": return ok("Instagram video")
            case "stories": return .no("Instagram stories need a login, so Jot can't open them.")
            default: return .no("That's an Instagram profile. Share a single reel or post.")
            }
        case "tiktok.com":
            if parts.contains("video") { return ok("TikTok video") }
            if parts.contains("photo") { return .no("That's a TikTok photo post. There's nothing to transcribe.") }
            if first == "t" { return ok("TikTok video") }
            return .no("That's a TikTok profile. Share a single video.")
        case "vm.tiktok.com", "vt.tiktok.com":
            return ok("TikTok video")
        case "youtube.com", "music.youtube.com":
            switch first {
            case "watch": return url.query()?.contains("v=") == true ? ok("YouTube video") : .no("That YouTube link has no video in it.")
            case "shorts": return ok("YouTube Short")
            case "live": return ok("YouTube live video")
            default: return .no("Share a single YouTube video, not a channel or playlist.")
            }
        case "youtu.be":
            return ok("YouTube video")
        case "x.com", "twitter.com":
            return parts.contains("status") ? ok("X post") : .no("That's an X profile. Share a single post.")
        case "vimeo.com", "player.vimeo.com":
            return parts.contains(where: { $0.allSatisfy(\.isNumber) }) ? ok("Vimeo video") : .no("Share a single Vimeo video.")
        case "loom.com":
            return first == "share" ? ok("Loom video") : .no("Share a Loom video link.")
        case "soundcloud.com":
            return parts.count >= 2 ? ok("SoundCloud track") : .no("Share a single SoundCloud track.")
        default:
            let ext = url.pathExtension.lowercased()
            if ["mp3", "m4a", "wav", "aac", "ogg", "opus", "flac"].contains(ext) { return ok("Audio file") }
            if ["mp4", "mov", "m4v", "webm", "mkv"].contains(ext) { return ok("Video file") }
            return .no("Jot can't read links from \(host.isEmpty ? "there" : host) yet.")
        }
    }

    /// The first web link in the text, so a pasted caption with a link in it still works.
    static func firstLink(in text: String) -> URL? {
        if let url = URL(string: text), let s = url.scheme?.lowercased(), s == "http" || s == "https", url.host() != nil { return url }
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        for match in detector?.matches(in: text, range: range) ?? [] {
            if let url = match.url, let s = url.scheme?.lowercased(), s == "http" || s == "https" { return url }
        }
        return nil
    }
}
