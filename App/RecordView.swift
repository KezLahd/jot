#if os(iOS)
import AVFoundation
import JotCore
import JotInbox
import SwiftUI

/// Record a voice note straight into Jot: no Voice Memos round trip. Keeps recording with the screen locked.
/// On Stop the file goes through the same queue as a shared voice memo and is transcribed on this iPhone.
@MainActor @Observable
final class VoiceRecorder {
    enum State: Equatable { case idle, recording, denied, failed(String) }
    private(set) var state: State = .idle
    private(set) var elapsed: TimeInterval = 0
    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var started = Date.now

    func start() async {
        guard await AVAudioApplication.requestRecordPermission() else { state = .denied; return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .spokenAudio)
            try session.setActive(true)
            let url = URL.temporaryDirectory.appending(path: "Voice note \(Self.stamp()).m4a")
            let r = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ])
            guard r.record() else { state = .failed("The microphone didn't start."); return }
            recorder = r
            started = .now
            state = .recording
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in if let self { self.elapsed = Date.now.timeIntervalSince(self.started) } }
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Stops and returns the file, or nil if nothing worth keeping was recorded.
    func stop() -> URL? {
        timer?.invalidate()
        guard let r = recorder else { return nil }
        r.stop()
        recorder = nil
        state = .idle
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return elapsed >= 1 ? r.url : nil
    }

    func cancel() {
        if let url = stop() { try? FileManager.default.removeItem(at: url) }
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f.string(from: .now)
    }
}

struct RecordView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var recorder = VoiceRecorder()

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            OrbView(kind: .listening, size: 210)
                .opacity(recorder.state == .recording ? 1 : 0.35)
            Text(headline).font(.onest(26, .bold)).foregroundStyle(Color.jInk).padding(.top, 18)
            Text(Read.clock(recorder.elapsed)).font(.mono(17)).foregroundStyle(Color.jMute).padding(.top, 6)
            if let detail {
                Text(detail).font(.onest(14.5)).foregroundStyle(Color.jMute).multilineTextAlignment(.center)
                    .padding(.horizontal, 40).padding(.top, 12)
            }
            Spacer()
            HStack(spacing: 12) {
                Button("Cancel") { recorder.cancel(); dismiss() }
                    .buttonStyle(SecondaryButtonStyle(height: 54))
                Button {
                    if let url = recorder.stop() { save(url) }
                    dismiss()
                } label: {
                    Label("Stop and transcribe", systemImage: "stop.fill").font(.onest(16, .bold))
                }
                .buttonStyle(PrimaryButtonStyle(height: 54))
                .disabled(recorder.state != .recording)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 14)
            Text("Keeps recording with the screen locked.").font(.onest(12.5)).foregroundStyle(Color.jMute).padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity)
        .background(Color.jBg)
        .task { await recorder.start() }
        .interactiveDismissDisabled(recorder.state == .recording)
    }

    private var headline: String {
        switch recorder.state {
        case .recording: "Listening"
        case .idle: "Starting…"
        case .denied: "Jot can't hear you"
        case .failed: "Couldn't record"
        }
    }

    private var detail: String? {
        switch recorder.state {
        case .denied: "Turn on the microphone for Jot in Settings › Privacy & Security › Microphone."
        case .failed(let why): why
        default: nil
        }
    }

    /// Same path as a voice memo shared from another app.
    private func save(_ url: URL) {
        guard let inbox = Inbox.shared() else { store.message = "Jot's shared folder isn't available."; return }
        do {
            try inbox.add(fileAt: url, title: "Voice note")
            try? FileManager.default.removeItem(at: url)
            store.reload()
        } catch {
            store.message = "Couldn't save the recording: \(error.localizedDescription)"
        }
    }
}
#endif
