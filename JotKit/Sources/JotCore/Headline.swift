import Foundation
import FoundationModels

/// A short headline for a Read, written by Apple's on-device model (Apple Intelligence): free, private,
/// nothing to download. Returns nil where it isn't available or declines, and the Read keeps its old title.
public enum Headline {
    public static var available: Bool { SystemLanguageModel.default.isAvailable }

    public static func make(for read: Read) async -> String? {
        guard available else { return nil }
        let transcript = String(read.text.prefix(2500))
        guard transcript.split(whereSeparator: \.isWhitespace).count >= 4 else { return nil }
        let session = LanguageModelSession(instructions: """
            You title transcripts of short videos and voice memos. Write one headline of 3 to 8 words that says \
            what the clip is about: its topic or main point, not the sign-off or call to action at the end. If it \
            is mostly a list, say what the list is of. Be specific: name the actual subject, never vague words like "elements" or "things" on their own. Plain words: no quotes, emoji, \
            hashtags or full stop. Reply with the headline only.
            """)
        var prompt = ""
        if let caption = read.caption?.trimmingCharacters(in: .whitespacesAndNewlines), !caption.isEmpty {
            prompt += "Caption: \(caption.prefix(600))\n\n"
        }
        prompt += "Transcript: \(transcript)"
        do {
            let response = try await session.respond(to: prompt, options: GenerationOptions(temperature: 0.3))
            return clean(response.content)
        } catch {
            return nil
        }
    }

    static func clean(_ raw: String) -> String? {
        var s = raw.split(separator: "\n").first.map(String.init) ?? ""
        for prefix in ["Headline:", "Title:"] where s.hasPrefix(prefix) { s = String(s.dropFirst(prefix.count)) }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " \"'“”‘’*#.").union(.whitespaces))
        guard s.count >= 3, s.count <= 90 else { return nil }
        return s
    }
}
