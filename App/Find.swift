import JotCore
import SwiftUI

/// Search helpers: where a query lands in a transcript, and text with the matches marked.
enum Find {
    static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    static func trimmed(_ query: String) -> String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Where the query lands in the text. Matches start at a word, so "the" never hits "other".
    /// When the text has the query as a whole word, only whole words count ("the" skips "then");
    /// otherwise word starts count, so a half-typed "coff" still finds "coffee".
    static func ranges(in text: String, for query: String) -> [Range<String.Index>] {
        let q = trimmed(query)
        guard !q.isEmpty else { return [] }
        var starts: [Range<String.Index>] = []
        var from = text.startIndex
        while let r = text.range(of: q, options: options, range: from..<text.endIndex) {
            if r.lowerBound == text.startIndex || !isWordChar(text[text.index(before: r.lowerBound)]) { starts.append(r) }
            from = r.upperBound
        }
        let whole = starts.filter { $0.upperBound == text.endIndex || !isWordChar(text[$0.upperBound]) }
        return whole.isEmpty ? starts : whole
    }

    static func matches(_ text: String, _ query: String) -> Bool { !ranges(in: text, for: query).isEmpty }

    private static func isWordChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "'" || c == "’" }

    /// The words around the first match, cut at word edges, so a result shows why it matched.
    static func snippet(in text: String, for query: String, before: Int = 36, after: Int = 140) -> String? {
        guard let hit = ranges(in: text, for: query).first else { return nil }
        var start = text.index(hit.lowerBound, offsetBy: -before, limitedBy: text.startIndex) ?? text.startIndex
        var end = text.index(hit.upperBound, offsetBy: after, limitedBy: text.endIndex) ?? text.endIndex
        if start > text.startIndex, let space = text[start..<hit.lowerBound].firstIndex(of: " ") { start = text.index(after: space) }
        if end < text.endIndex, let space = text[hit.upperBound..<end].lastIndex(of: " ") { end = space }
        let body = text[start..<end].trimmingCharacters(in: .whitespacesAndNewlines)
        return (start > text.startIndex ? "…" : "") + body + (end < text.endIndex ? "…" : "")
    }

    static func count(in text: String, for query: String) -> Int { ranges(in: text, for: query).count }

    /// The text with every match tinted and bold.
    static func marked(_ text: String, _ query: String) -> AttributedString {
        var out = AttributedString(text)
        for r in ranges(in: text, for: query) {
            if let lower = AttributedString.Index(r.lowerBound, within: out), let upper = AttributedString.Index(r.upperBound, within: out) {
                out[lower..<upper].backgroundColor = Color.jCyan.opacity(0.28)
                out[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
            }
        }
        return out
    }
}

/// A search result opens the transcript at the match.
struct FoundRead: Hashable {
    var read: Read
    var query: String
}

/// The words the cleanup pass changed in a line, so the transcript can mark them.
enum Fixed {
    /// Ranges in `text` of words that weren't in what Whisper heard.
    static func ranges(in text: String, heard: String) -> [Range<String.Index>] {
        func tokens(_ s: String) -> [(Range<String.Index>, String)] {
            var out: [(Range<String.Index>, String)] = []
            var i = s.startIndex
            while i < s.endIndex {
                guard !s[i].isWhitespace else { i = s.index(after: i); continue }
                let start = i
                while i < s.endIndex, !s[i].isWhitespace { i = s.index(after: i) }
                let word = s[start..<i].lowercased().trimmingCharacters(in: .punctuationCharacters)
                out.append((start..<i, word))
            }
            return out
        }
        let a = tokens(heard).map(\.1), b = tokens(text)
        // Longest common subsequence; whatever in `text` falls outside it is a fixed word.
        var dp = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                dp[i][j] = a[i] == b[j].1 ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var kept = Set<Int>(), i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j].1 { kept.insert(j); i += 1; j += 1 }
            else if dp[i + 1][j] >= dp[i][j + 1] { i += 1 } else { j += 1 }
        }
        return b.indices.filter { !kept.contains($0) }.map { b[$0].0 }
    }

    /// Fixed words get a dotted cyan underline.
    static func mark(_ out: inout AttributedString, text: String, heard: String?) {
        guard let heard else { return }
        for r in ranges(in: text, heard: heard) {
            if let lower = AttributedString.Index(r.lowerBound, within: out), let upper = AttributedString.Index(r.upperBound, within: out) {
                out[lower..<upper].underlineStyle = Text.LineStyle(pattern: .dot, color: Color.jCyanText)
            }
        }
    }
}

extension Fixed {
    /// Listen again: the words in the new lines that weren't in the old transcript at that point,
    /// by line. Compared as one stream of words, so lines that were only re-split don't count.
    static func changed(from old: [String], to new: [String]) -> [Int: [Range<String.Index>]] {
        func key(_ w: Substring) -> String { w.lowercased().trimmingCharacters(in: .punctuationCharacters) }
        let a = old.flatMap { $0.split(whereSeparator: \.isWhitespace).map(key) }
        var b: [(line: Int, range: Range<String.Index>, word: String)] = []
        for (i, line) in new.enumerated() {
            var j = line.startIndex
            while j < line.endIndex {
                guard !line[j].isWhitespace else { j = line.index(after: j); continue }
                let start = j
                while j < line.endIndex, !line[j].isWhitespace { j = line.index(after: j) }
                b.append((i, start..<j, key(line[start..<j])))
            }
        }
        guard !a.isEmpty, !b.isEmpty else { return [:] }
        var dp = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                dp[i][j] = a[i] == b[j].word ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var kept = Set<Int>(), i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j].word { kept.insert(j); i += 1; j += 1 }
            else if dp[i + 1][j] >= dp[i][j + 1] { i += 1 } else { j += 1 }
        }
        var out: [Int: [Range<String.Index>]] = [:]
        for k in b.indices where !kept.contains(k) && !b[k].word.isEmpty { out[b[k].line, default: []].append(b[k].range) }
        return out
    }
}
