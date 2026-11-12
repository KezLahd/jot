import Foundation
import whisper

/// whisper.cpp with Metal and Silero VAD. Benchmarked on the M6 Mac: a 26 s reel in about 1 s warm,
/// 10:33 of audio in about 19 s (see DECISIONS.md §3). Not thread-safe: one transcription at a time per instance.
public final class WhisperTranscriber: @unchecked Sendable {
    public let modelName: String
    private let context: OpaquePointer
    private let vadPath: String?

    /// whisper.cpp and ggml log every step to stderr; keep the CLI quiet unless JOT_DEBUG is set.
    private static let silenceLogs: Void = {
        guard ProcessInfo.processInfo.environment["JOT_DEBUG"] == nil else { return }
        whisper_log_set({ _, _, _ in }, nil)
        ggml_log_set({ _, _, _ in }, nil)
    }()

    /// `gpu: false` runs on the CPU only: iOS stops GPU work from apps in the background.
    public init(model: URL = Paths.whisperModel, vad: URL? = Paths.vadModel, gpu: Bool = true) throws {
        _ = WhisperTranscriber.silenceLogs
        guard FileManager.default.fileExists(atPath: model.path) else { throw JotError.missingModel(model.lastPathComponent) }
        var cparams = whisper_context_default_params()
        #if targetEnvironment(simulator)
        cparams.use_gpu = false  // the simulator's Metal driver can't map the model's buffers
        #else
        cparams.use_gpu = gpu
        cparams.flash_attn = true
        #endif
        guard let ctx = whisper_init_from_file_with_params(model.path, cparams) else {
            throw JotError.transcribeFailed("couldn't load \(model.lastPathComponent)")
        }
        context = ctx
        modelName = model.deletingPathExtension().lastPathComponent
        vadPath = vad.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0.path : nil }
    }

    deinit { whisper_free(context) }

    /// - Parameters:
    ///   - language: an ISO code like "en", or nil to auto-detect.
    ///   - progress: 0…1, called on whisper's thread.
    public func transcribe(_ samples: [Float], language: String? = "en", progress: (@Sendable (Double) -> Void)? = nil) throws -> (segments: [Read.Segment], language: String) {
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = Int32(min(8, max(1, ProcessInfo.processInfo.activeProcessorCount - 2)))
        params.print_progress = false
        params.print_realtime = false
        params.print_special = false
        params.print_timestamps = false
        params.no_context = true
        params.suppress_blank = true
        // VAD merges speech into long segments; cap them so each line gets its own timestamp.
        params.token_timestamps = true
        params.split_on_word = true
        params.max_len = 64

        let box = progress.map { ProgressBox($0) }
        if let box {
            params.progress_callback = { _, _, pct, user in
                guard let user else { return }
                Unmanaged<ProgressBox>.fromOpaque(user).takeUnretainedValue().report(Double(pct) / 100)
            }
            params.progress_callback_user_data = Unmanaged.passUnretained(box).toOpaque()
        }

        let lang = strdup(language ?? "auto")
        let vad = vadPath.map { strdup($0) }
        // The post's caption names what's said (people, places, design terms), so Whisper spells them right.
        let hint = WhisperHint.prompt.map { strdup($0) }
        defer { free(lang); vad.map { free($0) }; hint.map { free($0) } }
        if let hint { params.initial_prompt = UnsafePointer(hint) }
        params.language = UnsafePointer(lang)
        params.detect_language = false
        if let vad {
            params.vad = true
            params.vad_model_path = UnsafePointer(vad)
            params.vad_params = whisper_vad_default_params()
        }

        let status = samples.withUnsafeBufferPointer { buf in
            withExtendedLifetime(box) { whisper_full(context, params, buf.baseAddress, Int32(buf.count)) }
        }
        guard status == 0 else { throw JotError.transcribeFailed("whisper_full returned \(status)") }

        var segments: [Read.Segment] = []
        for i in 0..<whisper_full_n_segments(context) {
            let text = String(cString: whisper_full_get_segment_text(context, i)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            // t0/t1 are in 10 ms units.
            segments.append(.init(start: Double(whisper_full_get_segment_t0(context, i)) / 100,
                                  end: Double(whisper_full_get_segment_t1(context, i)) / 100,
                                  text: text))
        }
        let detected = String(cString: whisper_lang_str(whisper_full_lang_id(context)))
        progress?(1)
        return (segments, detected)
    }
}

/// Words Whisper should expect, set around a transcribe call: `WhisperHint.$prompt.withValue(caption) { … }`.
public enum WhisperHint {
    @TaskLocal public static var prompt: String?

    /// The caption, tidied and cut like the cloud runner's (server/transcribe.py).
    public static func from(caption: String?) -> String? {
        guard let caption else { return nil }
        let flat = caption.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return flat.isEmpty ? nil : String(flat.prefix(400))
    }
}

private final class ProgressBox: @unchecked Sendable {
    let report: @Sendable (Double) -> Void
    init(_ report: @escaping @Sendable (Double) -> Void) { self.report = report }
}
