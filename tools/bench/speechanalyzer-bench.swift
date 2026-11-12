import Foundation
import Speech
import AVFoundation

@main struct Bench {
    static func main() async throws {
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let t0 = Date()
        let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-AU")) ?? Locale(identifier: "en-US")
        let tr = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        if let req = try await AssetInventory.assetInstallationRequest(supporting: [tr]) { try await req.downloadAndInstall() }
        let t1 = Date()
        let analyzer = SpeechAnalyzer(modules: [tr])
        let file = try AVAudioFile(forReading: url)
        let collect = Task { () -> [(Double, Double, String)] in
            var out: [(Double, Double, String)] = []
            for try await r in tr.results {
                let s = String(r.text.characters)
                var a = 0.0, b = 0.0
                if let rng = r.text.runs.first?.audioTimeRange { a = rng.start.seconds }
                if let rng = r.text.runs.last?.audioTimeRange { b = rng.end.seconds }
                out.append((a, b, s))
            }
            return out
        }
        try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
        let segs = try await collect.value
        let t2 = Date()
        let j: [String: Any] = ["locale": locale.identifier, "setup_s": t1.timeIntervalSince(t0), "transcribe_s": t2.timeIntervalSince(t1),
                                "segments": segs.map { [($0.0 * 10).rounded() / 10, ($0.1 * 10).rounded() / 10, $0.2] }]
        print(String(data: try JSONSerialization.data(withJSONObject: j), encoding: .utf8)!)
    }
}
