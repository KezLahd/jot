import Foundation
import JotCore

// jot setup                         download yt-dlp and the models
// jot read <link|file> [options]    transcribe, print the transcript, save the Read folder
//   --language <code|auto>          default en
//   --no-timestamps                 print plain text
//   --json                          print read.json instead
// jot list                          list saved Reads
// jot find <words>                  search every transcript, print the lines that match
// jot show <id|link>                print a saved transcript
//
// Reads go into Jot's iCloud library when this Mac has it, so they show up in the app on every device.
// JOT_LIBRARY overrides that folder. Tools and models stay in Application Support (JOT_HOME).

let usage = """
usage:
  jot setup
  jot read <link or file> [--language en|auto] [--no-timestamps] [--json] [--apple] [--cloud owner/repo] [--fresh]  (cloud reads JOT_GITHUB_TOKEN)
  jot list
  jot find <words>
  jot show <id or link>
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func err(_ message: String) {
    FileHandle.standardError.write(Data(message.utf8))
}

/// The apps' shared library: the iCloud container's Documents when it's on this Mac, else the CLI's own folder.
let library: Library = {
    if let override = ProcessInfo.processInfo.environment["JOT_LIBRARY"] {
        return Library(root: URL(filePath: override, directoryHint: .isDirectory))
    }
    let icloud = URL.homeDirectory.appending(path: "Library/Mobile Documents/iCloud~com~kezlahd~jot/Documents", directoryHint: .isDirectory)
    if FileManager.default.fileExists(atPath: icloud.path) { return Library(root: icloud) }
    return Library(root: Paths.root)
}()

/// Links compare without tracking junk, so a reshared reel finds its earlier transcript.
func sameLink(_ a: String, _ b: String) -> Bool {
    func key(_ s: String) -> String {
        guard var c = URLComponents(string: s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return s }
        c.query = nil; c.fragment = nil; c.scheme = "https"
        c.host = c.host?.lowercased().replacingOccurrences(of: "www.", with: "")
        var out = c.string ?? s
        while out.hasSuffix("/") { out.removeLast() }
        return out
    }
    return key(a) == key(b)
}

func output(_ read: Read, folder: URL, json: Bool, timestamps: Bool) throws {
    if json {
        print(String(decoding: try Data(contentsOf: folder.appending(path: "read.json")), as: UTF8.self))
    } else {
        print(read.markdown(timestamps: timestamps), terminator: "")
    }
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { fail(usage) }
args.removeFirst()

switch command {
case "setup":
    do {
        try await Setup.run { print($0) }
        print("Jot is ready. Files are in \(Paths.root.path)")
    } catch { fail(error.localizedDescription) }

case "read":
    var input: String?
    var language: String? = "en"
    var timestamps = true
    var json = false
    var apple = false
    var cloudRepo: String?
    var fresh = false
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--language":
            i += 1
            guard i < args.count else { fail(usage) }
            language = args[i] == "auto" ? nil : args[i]
        case "--no-timestamps": timestamps = false
        case "--json": json = true
        case "--apple": apple = true
        case "--fresh": fresh = true
        case "--cloud":
            i += 1
            guard i < args.count else { fail(usage) }
            cloudRepo = args[i]
        default:
            if input == nil { input = args[i] } else { fail(usage) }
        }
        i += 1
    }
    guard let input else { fail(usage) }
    if !fresh, input.contains("://"), let done = library.loadReads().first(where: { sameLink($0.source, input) }) {
        do { try output(done, folder: library.folder(for: done), json: json, timestamps: timestamps) } catch { fail(error.localizedDescription) }
        err("Already in Jot (\(done.id)); --fresh to transcribe again\n")
        exit(0)
    }
    do {
        try library.prepare()
        let started = Date()
        let transcriber: any Transcriber = apple ? AppleTranscriber() : try WhisperTranscriber()
        var pipeline = Pipeline(readsFolder: library.reads, language: language)
        if let cloudRepo {
            guard let token = ProcessInfo.processInfo.environment["JOT_GITHUB_TOKEN"] else {
                throw JotError.fetchFailed("set JOT_GITHUB_TOKEN to use --cloud")
            }
            pipeline.cloud = CloudFetcher(repo: cloudRepo, token: token)
        }
        let (read, folder) = try await pipeline.run(input, transcriber: transcriber) { stage in
            switch stage {
            case .fetching: err("Fetching…\n")
            case .decoding: err("Decoding audio…\n")
            case .listening(let p): err(String(format: "\rListening %3.0f%%", p * 100))
            case .done: err("\n")
            }
        }
        try output(read, folder: folder, json: json, timestamps: timestamps)
        err(String(format: "Saved %@ (%d words, %.1fs)\n", folder.path, read.wordCount, Date().timeIntervalSince(started)))
    } catch { fail(error.localizedDescription) }

case "list":
    for read in library.loadReads() {
        let who = read.handle ?? read.site ?? "file"
        print("\(read.id)  \(read.displayTitle)  ·  \(who)  ·  \(read.duration.map(Read.clock) ?? "?")  ·  \(read.source)")
    }

case "find":
    let q = args.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    guard !q.isEmpty else { fail(usage) }
    var any = false
    for read in library.loadReads() {
        let lines = read.segments.filter { $0.text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        let inTitle = read.displayTitle.range(of: q, options: .caseInsensitive) != nil
        guard inTitle || !lines.isEmpty else { continue }
        any = true
        print("## \(read.displayTitle)  (\(read.id) · \(read.handle ?? read.site ?? "file"))")
        for seg in lines { print("[\(Read.clock(seg.start))] \(seg.text)") }
        print("")
    }
    if !any { fail("Nothing in Jot matches “\(q)”.") }

case "show":
    guard let key = args.first else { fail(usage) }
    let reads = library.loadReads()
    guard let read = reads.first(where: { $0.id == key }) ?? reads.first(where: { sameLink($0.source, key) }) else {
        fail("No transcript with id or link \(key). Try jot list.")
    }
    do { try output(read, folder: library.folder(for: read), json: args.contains("--json"), timestamps: !args.contains("--no-timestamps")) }
    catch { fail(error.localizedDescription) }

default:
    fail(usage)
}
