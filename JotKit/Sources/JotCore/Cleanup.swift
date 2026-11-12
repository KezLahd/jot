import Foundation

/// A light proofread of a finished transcript by Claude Haiku. It fixes only words Whisper almost certainly
/// misheard ("These delete the contact form" → "Please delete…") and keeps the original in `Segment.heard`,
/// so the app can show what was actually transcribed. Timestamps and line breaks never change.
///
/// The key comes from ANTHROPIC_API_KEY, or on the Mac from the login keychain:
///     security add-generic-password -s com.kezlahd.jot.anthropic -a jot -w
/// With no key, or if the call fails, the transcript is kept as Whisper wrote it.
public enum Cleanup {
    public static let model = "claude-haiku-5-5"
    public static let keychainService = "com.kezlahd.jot.anthropic"

    /// The same instructions the cloud runner sends (server/cleanup.py), so every transcript is treated alike.
    static let instructions = """
    You proofread speech-to-text transcripts made by Whisper. Whisper sometimes mishears a word, \
    most often at the very start of a clip or on names and jargon: "These delete the contact form" \
    for "Please delete the contact form", "fluted glass" heard as "fluted class".

    Fix a word only when you are confident it was misheard: the written word makes little sense where \
    it is and a similar-sounding word clearly fits, or a name or term is misspelled and the caption \
    shows the right spelling. Leave everything else exactly as it is: slang, swearing, filler, \
    repetition, run-ons, bad grammar, and anything that already makes sense. When unsure, leave it.

    Keep each line's wording apart from the fixed words. Never merge, split, reorder, summarise or \
    rephrase lines, and never add punctuation that wasn't needed for the fix. Return only the lines \
    you changed, each in full with its number. Return an empty list when nothing needs fixing.
    """

    static var schema: [String: Any] { [
        "type": "object",
        "properties": [
            "fixes": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": ["line": ["type": "integer"], "text": ["type": "string"]],
                    "required": ["line", "text"],
                    "additionalProperties": false,
                ],
            ],
        ],
        "required": ["fixes"],
        "additionalProperties": false,
    ] }

    public static var key: String? {
        let env = ProcessInfo.processInfo.environment
        if let k = env["ANTHROPIC_API_KEY"], !k.isEmpty { return k }
        #if os(macOS)
        let p = Process()
        p.executableURL = URL(filePath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", keychainService, "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let k = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return k.isEmpty ? nil : k
        #else
        return nil
        #endif
    }

    /// Returns the Read with fixes applied (and marked), or unchanged when there's no key or nothing to fix.
    public static func apply(to read: Read) async -> Read {
        guard read.cleanedBy == nil, !read.segments.isEmpty, let key else { return read }
        do {
            let fixes = try await ask(read, key: key)
            var out = read
            out.segments = merge(read.segments, fixes)
            out.cleanedBy = model
            return out
        } catch {
            FileHandle.standardError.write(Data("Cleanup skipped: \(error.localizedDescription)\n".utf8))
            return read
        }
    }

    static func ask(_ read: Read, key: String) async throws -> [Int: String] {
        var prompt = ""
        if let who = read.handle ?? read.creator { prompt += "Speaker: \(who)\n" }
        if let caption = read.caption?.trimmingCharacters(in: .whitespacesAndNewlines), !caption.isEmpty {
            prompt += "Caption: \(caption.prefix(1500))\n"
        }
        prompt += "\nTranscript:\n"
        for (i, seg) in read.segments.enumerated() { prompt += "\(i): \(seg.text)\n" }

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 8000,
            "system": instructions,
            "output_config": ["effort": "low", "format": ["type": "json_schema", "schema": schema]],
            "messages": [["role": "user", "content": prompt]],
        ]
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 90
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            let message = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String } ?? "HTTP \(code)"
            throw JotError.transcribeFailed("Claude: \(message)")
        }
        struct Reply: Decodable {
            struct Block: Decodable { var type: String; var text: String? }
            var content: [Block]
            var stop_reason: String?
        }
        struct Fixes: Decodable {
            struct Fix: Decodable { var line: Int; var text: String }
            var fixes: [Fix]
        }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        guard reply.stop_reason == "end_turn", let text = reply.content.first(where: { $0.type == "text" })?.text else {
            throw JotError.transcribeFailed("Claude stopped early (\(reply.stop_reason ?? "?"))")
        }
        let fixes = try JSONDecoder().decode(Fixes.self, from: Data(text.utf8))
        return Dictionary(fixes.fixes.map { ($0.line, $0.text) }, uniquingKeysWith: { a, _ in a })
    }

    /// Applies only small fixes to lines that exist; anything that looks like a rewrite is dropped.
    static func merge(_ segments: [Read.Segment], _ fixes: [Int: String]) -> [Read.Segment] {
        var out = segments
        for (i, text) in fixes where out.indices.contains(i) {
            let new = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let old = out[i].text
            guard new != old, isSmallFix(from: old, to: new) else { continue }
            out[i].heard = old
            out[i].text = new
        }
        return out
    }

    /// A fix swaps a word or two; it doesn't rewrite the line.
    static func isSmallFix(from old: String, to new: String) -> Bool {
        let a = words(old), b = words(new)
        guard !b.isEmpty, abs(a.count - b.count) <= 2 else { return false }
        let changed = max(a.count, b.count) - lcs(a, b)
        return changed >= 1 && changed <= max(2, a.count / 3)
    }

    static func words(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { $0.isWhitespace }).map { $0.trimmingCharacters(in: .punctuationCharacters) }.filter { !$0.isEmpty }
    }

    static func lcs(_ a: [String], _ b: [String]) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var prev = [Int](repeating: 0, count: b.count + 1)
        for x in a {
            var cur = [Int](repeating: 0, count: b.count + 1)
            for (j, y) in b.enumerated() { cur[j + 1] = x == y ? prev[j] + 1 : max(prev[j + 1], cur[j]) }
            prev = cur
        }
        return prev[b.count]
    }
}
