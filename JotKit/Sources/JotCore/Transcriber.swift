import AVFoundation
import Foundation
import Speech

/// Something that turns audio into timestamped segments.
public protocol Transcriber: AnyObject, Sendable {
    var engine: String { get }
    var modelName: String { get }
    /// `samples` decodes the file to 16 kHz mono on demand (Whisper wants samples; Apple's model reads a file).
    func transcribe(file: URL, samples: @Sendable () async throws -> [Float], language: String?,
                    progress: (@Sendable (Double) -> Void)?) async throws -> (segments: [Read.Segment], language: String)
}

extension WhisperTranscriber: Transcriber {
    public var engine: String { "whisper.cpp" }

    public func transcribe(file: URL, samples: @Sendable () async throws -> [Float], language: String?,
                           progress: (@Sendable (Double) -> Void)?) async throws -> (segments: [Read.Segment], language: String) {
        let s = try await samples()
        return try transcribe(s, language: language, progress: progress)
    }
}

/// Apple's on-device SpeechTranscriber: no download, used on iPhone for shared files.
/// Benchmarked at 1.6 s for a 26 s reel, slightly less accurate on names than Whisper (DECISIONS.md §3).
public final class AppleTranscriber: Transcriber, @unchecked Sendable {
    public let engine = "SpeechAnalyzer"
    public let modelName = "SpeechTranscriber"

    public init() {}

    public func transcribe(file: URL, samples: @Sendable () async throws -> [Float], language: String?,
                           progress: (@Sendable (Double) -> Void)?) async throws -> (segments: [Read.Segment], language: String) {
        guard SpeechTranscriber.isAvailable else { throw JotError.speechUnavailable }
        let wanted = Locale(identifier: language == nil || language == "en" ? "en-AU" : language!)
        let locale = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) ?? Locale(identifier: "en-US")
        let module = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }

        // AVAudioFile can't open every container (fragmented MP4, some videos), so decode first and hand it a plain CAF.
        let pcm = try await samples()
        let duration = Double(pcm.count) / AudioDecoder.sampleRate
        let temp = FileManager.default.temporaryDirectory.appending(path: "jot-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: temp) }
        try AppleTranscriber.writeCAF(pcm, to: temp)

        let analyzer = SpeechAnalyzer(modules: [module])
        let collect = Task { () -> [Read.Segment] in
            var out: [Read.Segment] = []
            for try await result in module.results {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let start = result.text.runs.first?.audioTimeRange?.start.seconds ?? 0
                let end = result.text.runs.last?.audioTimeRange?.end.seconds ?? start
                out.append(Read.Segment(start: start, end: end, text: text))
                if duration > 0 { progress?(min(0.99, end / duration)) }
            }
            return out
        }
        let audio = try AVAudioFile(forReading: temp)
        try await analyzer.start(inputAudioFile: audio, finishAfterFile: true)
        let segments = try await collect.value
        progress?(1)
        return (segments, locale.language.languageCode?.identifier ?? "en")
    }

    static func writeCAF(_ samples: [Float], to url: URL) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioDecoder.sampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw JotError.decodeFailed("couldn't prepare audio")
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }
}
