import AVFoundation
import Foundation

/// Link or file in, Read folder out: `<reads>/<id>/` with read.json, transcript.md and the source audio.
public struct Pipeline: Sendable {
    public enum Stage: Sendable, Equatable {
        case fetching           // searching orb
        case decoding
        case listening(Double)  // listening orb, 0…1
        case done
    }

    public var readsFolder: URL
    public var fetcher: Fetcher
    public var language: String?
    /// When set, links are fetched by the GitHub workflow instead of a local yt-dlp (the iPhone has none).
    public var cloud: CloudFetcher?

    public init(readsFolder: URL = Paths.reads, fetcher: Fetcher = Fetcher(), language: String? = "en", cloud: CloudFetcher? = nil) {
        self.readsFolder = readsFolder
        self.fetcher = fetcher
        self.language = language
        self.cloud = cloud
    }

    /// `input` is an http(s) link or a path to an audio/video file.
    @discardableResult
    public func run(_ input: String, id: String = Pipeline.makeID(), title: String? = nil, transcriber: any Transcriber,
                    stage: @escaping @Sendable (Stage) -> Void = { _ in }) async throws -> (Read, URL) {
        let folder = readsFolder.appending(path: id, directoryHint: .isDirectory)
        try Paths.ensure(folder)
        do {
            var read: Read
            let media: URL
            if let link = URL(string: input), let scheme = link.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                stage(.fetching)
                let r = if let cloud { try await cloud.fetch(link, id: id, into: folder) } else { try fetcher.fetch(link, into: folder) }
                media = r.mediaFile
                read = Read(id: id, kind: .link, source: r.canonicalURL, site: r.site, title: r.title ?? "", creator: r.creator,
                            handle: r.handle, caption: r.caption, duration: r.duration, posted: r.posted, created: .now,
                            language: nil, engine: transcriber.engine, model: transcriber.modelName,
                            audioFile: r.mediaFile.lastPathComponent, segments: [])
            } else {
                let src = URL(filePath: (input as NSString).expandingTildeInPath)
                guard FileManager.default.fileExists(atPath: src.path) else { throw JotError.decodeFailed("no file at \(src.path)") }
                media = folder.appending(path: "source." + (src.pathExtension.isEmpty ? "m4a" : src.pathExtension.lowercased()))
                try FileManager.default.copyItem(at: src, to: media)
                read = Read(id: id, kind: .file, source: src.lastPathComponent, site: nil,
                            title: title ?? src.deletingPathExtension().lastPathComponent, creator: nil, handle: nil, caption: nil,
                            duration: nil, posted: nil, created: .now, language: nil, engine: transcriber.engine,
                            model: transcriber.modelName, audioFile: media.lastPathComponent, segments: [])
            }

            stage(.decoding)
            let mediaFile = media
            let box = DurationBox()
            stage(.listening(0))
            let result = try await WhisperHint.$prompt.withValue(WhisperHint.from(caption: read.caption)) {
                try await transcriber.transcribe(file: media, samples: {
                    let s = try await AudioDecoder.samples(from: mediaFile)
                    box.seconds = Double(s.count) / AudioDecoder.sampleRate
                    return s
                }, language: language) { stage(.listening($0)) }
            }
            if read.duration == nil { read.duration = box.seconds }
            read.segments = result.segments
            read.language = result.language
            if read.title.isEmpty { read.title = Read.title(fromOpening: result.segments) ?? "\(read.site ?? "Untitled") post" }
            read = await Cleanup.apply(to: read)
            read.summary = await Headline.make(for: read)
            try read.write(to: folder)
            stage(.done)
            return (read, folder)
        } catch {
            // Keep the folder only if something useful was saved; a failed fetch leaves nothing behind.
            if !FileManager.default.fileExists(atPath: folder.appending(path: "read.json").path) {
                try? FileManager.default.removeItem(at: folder)
            }
            throw error
        }
    }

    /// Saves a link the cloud runner fetched and transcribed. The media is already in the Read's folder.
    public func save(_ c: CloudFetcher.Collected, id: String) async throws -> Read {
        guard let segments = c.segments else { throw JotError.transcribeFailed("the cloud didn't transcribe it") }
        let r = c.result
        var read = Read(id: id, kind: .link, source: r.canonicalURL, site: r.site, title: r.title ?? "", creator: r.creator,
                        handle: r.handle, caption: r.caption, duration: r.duration, posted: r.posted, created: .now,
                        language: c.language, engine: "faster-whisper", model: c.model ?? "faster-whisper-small",
                        audioFile: r.mediaFile.lastPathComponent, segments: segments)
        if read.duration == nil { read.duration = segments.last?.end }
        if read.title.isEmpty { read.title = Read.title(fromOpening: segments) ?? "\(read.site ?? "Untitled") post" }
        read.cleanedBy = c.cleaned
        read = await Cleanup.apply(to: read)
        read.summary = await Headline.make(for: read)
        try read.write(to: readsFolder.appending(path: id, directoryHint: .isDirectory))
        return read
    }

    /// Listen again: swaps a Read's lines for the careful model's, keeping its id, title, headline and audio.
    public func relisten(_ read: Read, with c: CloudFetcher.Collected) async throws -> Read {
        guard let segments = c.segments, !segments.isEmpty else { throw JotError.transcribeFailed("the cloud didn't transcribe it") }
        var out = read
        out.segments = segments
        out.engine = "faster-whisper"
        out.model = c.model ?? "faster-whisper-\(CloudFetcher.carefulModel)"
        out.language = c.language ?? read.language
        out.cleanedBy = c.cleaned
        out = await Cleanup.apply(to: out)
        try out.write(to: readsFolder.appending(path: read.id, directoryHint: .isDirectory))
        return out
    }

    /// Sortable and unique: 20261111-153012-a1b2
    public static func makeID(now: Date = .now) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: now) + "-" + String(UUID().uuidString.prefix(4)).lowercased()
    }
}

private final class DurationBox: @unchecked Sendable {
    var seconds: Double?
}
